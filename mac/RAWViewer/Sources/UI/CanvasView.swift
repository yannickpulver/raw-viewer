import AppKit
import CoreGraphics
import SwiftUI

/// Zoom / pan / rotate canvas. Spec 01 §15-16, 02 §3-5.
///
/// `zoom` 1.0 means fit-to-window; it is a multiplier on top of the fit scale.
/// Zoom and pan survive navigation so the same region can be inspected across a burst;
/// only rotation resets per image. Zooming out stops at fit.
final class CanvasNSView: NSView {

    static let minZoom = 1.0
    static let maxZoom = 10.0

    private let imageLayer = CALayer()
    /// Face boxes live inside `imageLayer`, in its pixel coordinates, so they rotate and zoom
    /// with the image for free.
    private let faceLayer = CALayer()
    private(set) var faces: [Face] = []

    /// Identity of what is displayed, so `updateNSView` stays idempotent.
    private(set) var displayedImage: CGImage?
    private(set) var displayedURL: URL?

    private(set) var zoom: Double = 1.0
    private var rotationSteps: Int = 0
    private(set) var offset: CGPoint = .zero
    private var panOrigin: NSPoint?
    private var lastSwipe: Date = .distantPast

    var onNavigate: ((Int) -> Void)?
    var onFocus: (() -> Void)?
    /// Kept alive across the popup and any share sheet it opens. See `SelectionMenuController`.
    private var selectionMenuController: SelectionMenuController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        imageLayer.isHidden = true
        imageLayer.addSublayer(faceLayer)
        layer?.addSublayer(imageLayer)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError("unavailable") }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Content

    /// Idempotent: nothing happens when the same CGImage for the same URL is set again.
    func set(image: CGImage?, url: URL?) {
        let sameImage = displayedImage === image
        let sameURL = displayedURL == url
        guard !(sameImage && sameURL) else { return }

        if !sameURL {
            // Spec 01 §15: a new image clears rotation. Zoom and pan are kept (spec 01 §16).
            rotationSteps = 0
        }
        displayedImage = image
        displayedURL = url

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            imageLayer.isHidden = false
            imageLayer.contents = image
            imageLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        } else {
            imageLayer.isHidden = true
            imageLayer.contents = nil
        }
        layoutFaceBoxes()
        CATransaction.commit()
        applyTransform()
    }

    /// Idempotent like `set(image:url:)`. An empty list hides every box.
    func set(faces: [Face]) {
        guard faces != self.faces else { return }
        self.faces = faces
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceLayer.sublayers = faces.map { face in
            let box = CALayer()
            box.borderColor = face.eyesClosed ? Self.closedEyesColor : Self.faceBoxColor
            box.shadowColor = NSColor.black.cgColor
            box.shadowOpacity = 0.6
            box.shadowRadius = 1
            box.shadowOffset = .zero
            return box
        }
        layoutFaceBoxes()
        CATransaction.commit()
        applyTransform()
    }

    private static let faceBoxColor = NSColor(white: 1, alpha: 0.85).cgColor
    private static let closedEyesColor = NSColor(srgbRed: 230 / 255, green: 70 / 255, blue: 70 / 255, alpha: 1).cgColor

    /// Face rects are normalised with a bottom-left origin, which is also the layer's origin.
    private func layoutFaceBoxes() {
        let bounds = imageLayer.bounds
        faceLayer.frame = bounds
        for (box, face) in zip(faceLayer.sublayers ?? [], faces) {
            box.frame = CGRect(x: face.rect.minX * bounds.width, y: face.rect.minY * bounds.height,
                               width: face.rect.width * bounds.width, height: face.rect.height * bounds.height)
        }
    }

    /// Zooms so the face fills about 40 % of the view and centres it. A face that is already
    /// that big at fit just resets to fit.
    func focus(face rect: CGRect) {
        guard let image = displayedImage, bounds.width > 0, bounds.height > 0 else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let faceSize = CGSize(width: rect.width * w, height: rect.height * h)
        let onScreen = rotationSteps % 2 == 0 ? faceSize : CGSize(width: faceSize.height, height: faceSize.width)
        let share = max(onScreen.width / bounds.width, onScreen.height / bounds.height)
        guard share > 0 else { return }
        let target = min(max(Double(0.4 / share / fitScale), Self.minZoom), Self.maxZoom)
        guard target > Self.minZoom else {
            resetZoom()
            return
        }
        zoom = target
        // The face centre relative to the layer's anchor, pushed through the layer's own
        // rotation and scale, is where it lands relative to the layer position.
        let fromAnchor = CGPoint(x: (rect.midX - 0.5) * w, y: (rect.midY - 0.5) * h)
        let moved = fromAnchor.applying(CATransform3DGetAffineTransform(layerTransform()))
        offset = CGPoint(x: -moved.x, y: -moved.y)
        applyTransform()
    }

    func rotate() {
        guard displayedImage != nil else { return }
        rotationSteps = (rotationSteps + 1) % 4
        // Spec 01 §15: rotating re-fits.
        zoom = 1.0
        offset = .zero
        applyTransform()
    }

    /// Spec 02 §1: at fit → 2.0x, otherwise back to fit.
    func toggleDoubleZoom() {
        guard displayedImage != nil else { return }
        if isAtFit {
            applyZoom(target: 2.0, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
        } else {
            resetZoom()
        }
    }

    func resetZoom() {
        zoom = 1.0
        offset = .zero
        applyTransform()
    }

    var isAtFit: Bool { abs(zoom - 1.0) < 0.01 }

    // MARK: - Geometry

    private var rotatedSize: CGSize {
        guard let image = displayedImage else { return .zero }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return rotationSteps % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }

    private var fitScale: CGFloat {
        let size = rotatedSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height)
    }

    private func layerTransform() -> CATransform3D {
        let scale = fitScale * CGFloat(zoom)
        let transform = CATransform3DMakeRotation(CGFloat(rotationSteps) * .pi / 2, 0, 0, 1)
        return CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
    }

    private func applyTransform() {
        guard displayedImage != nil else { return }
        let scale = fitScale * CGFloat(zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.transform = layerTransform()
        // The boxes scale with the image, so their stroke is set in screen points.
        for box in faceLayer.sublayers ?? [] { box.borderWidth = 1.5 / max(scale, 0.0001) }
        imageLayer.position = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Spec 01 §16: re-fit on resize while at fit.
        if isAtFit { offset = .zero }
        applyTransform()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransform()
    }

    /// Spec 01 §16: clamp to `[minZoom, maxZoom]`; anchor at `anchor` (view coords).
    /// Landing on fit also re-centres, so swipe navigation works again right away.
    func applyZoom(target: Double, anchor: CGPoint) {
        let target = min(max(target, Self.minZoom), Self.maxZoom)
        let previous = zoom
        guard previous > 0, target != previous else { return }
        if target == Self.minZoom {
            resetZoom()
            return
        }
        let k = CGFloat(target / previous)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let position = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
        let moved = CGPoint(x: anchor.x + (position.x - anchor.x) * k,
                            y: anchor.y + (position.y - anchor.y) * k)
        zoom = target
        offset = CGPoint(x: moved.x - centre.x, y: moved.y - centre.y)
        applyTransform()
    }

    // MARK: - Mouse

    /// The image runs under the transparent toolbar, so clicks in that row land here. They
    /// belong to the window: dragging there moves the window, not the image.
    func isInToolbarRow(_ locationInWindow: NSPoint) -> Bool {
        guard let window else { return false }
        return locationInWindow.y > window.contentLayoutRect.maxY
    }

    override func mouseDown(with event: NSEvent) {
        if isInToolbarRow(event.locationInWindow) {
            window?.performDrag(with: event)
            return
        }
        onFocus?()
        // Control-click is the right-click of a one-button mouse or trackpad.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control) {
            openMenu(at: convert(event.locationInWindow, from: nil))
            return
        }
        if event.clickCount == 2 {
            resetZoom()
            return
        }
        // At fit the image stays put; there is nothing to pan to.
        guard !isAtFit else { return }
        panOrigin = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        openMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// The same menu as a grid cell, for the image on screen.
    private func openMenu(at point: NSPoint) {
        guard let url = displayedURL, displayedImage != nil else { return }
        let controller = SelectionMenuController(urls: [url], view: self,
                                                 rect: NSRect(x: point.x, y: point.y, width: 1, height: 1))
        selectionMenuController = controller
        controller.makeMenu().popUp(positioning: nil, at: point, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard panOrigin != nil else { return }
        offset.x += event.deltaX
        offset.y -= event.deltaY   // AppKit view coords are bottom-up
        applyTransform()
    }

    override func mouseUp(with event: NSEvent) {
        if panOrigin != nil {
            panOrigin = nil
            NSCursor.pop()
        }
    }

    // MARK: - Trackpad

    override func scrollWheel(with event: NSEvent) {
        guard displayedImage != nil else { return }
        if isAtFit {
            // Spec 02 §4: horizontal only, above a 30 px threshold, 200 ms debounce.
            let dx = event.scrollingDeltaX
            guard abs(dx) > 30 else { return }           // everything else is consumed
            guard Date().timeIntervalSince(lastSwipe) > 0.2 else { return }
            lastSwipe = Date()
            onNavigate?(dx > 0 ? -1 : 1)
        } else {
            offset.x += event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            applyTransform()
        }
    }

    override func magnify(with event: NSEvent) {
        guard displayedImage != nil else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        applyZoom(target: zoom * (1.0 + Double(event.magnification)), anchor: anchor)
    }
}

/// SwiftUI wrapper. Every command is delivered through `CanvasCommands`, a token the
/// parent bumps; `updateNSView` only touches the layer when something actually changed.
struct CanvasView: NSViewRepresentable {
    var image: CGImage?
    var url: URL?
    /// Incremented by the owner to request a rotation.
    var rotationToken: Int
    /// Incremented by the owner to request a 2x/fit toggle.
    var zoomToken: Int
    /// Empty hides the face boxes.
    var faces: [Face] = []
    /// Incremented by the owner to zoom onto `faceFocus`.
    var faceFocusToken: Int = 0
    var faceFocus: CGRect?
    var onNavigate: (Int) -> Void
    var onFocus: () -> Void

    final class Coordinator {
        var rotationToken = 0
        var zoomToken = 0
        var faceFocusToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(frame: .zero)
        context.coordinator.rotationToken = rotationToken
        context.coordinator.zoomToken = zoomToken
        context.coordinator.faceFocusToken = faceFocusToken
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.onNavigate = onNavigate
        view.onFocus = onFocus
        view.set(image: image, url: url)
        view.set(faces: faces)
        if context.coordinator.rotationToken != rotationToken {
            context.coordinator.rotationToken = rotationToken
            view.rotate()
        }
        if context.coordinator.zoomToken != zoomToken {
            context.coordinator.zoomToken = zoomToken
            view.toggleDoubleZoom()
        }
        if context.coordinator.faceFocusToken != faceFocusToken {
            context.coordinator.faceFocusToken = faceFocusToken
            if let faceFocus { view.focus(face: faceFocus) }
        }
    }
}
