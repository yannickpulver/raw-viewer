import AppKit
import CoreGraphics
import SwiftUI

/// Zoom / pan / rotate canvas. Spec 01 §15-16, 02 §3-5.
///
/// `zoom` 1.0 means fit-to-window; it is a multiplier on top of the fit scale.
final class CanvasNSView: NSView {

    static let minZoom = 0.1
    static let maxZoom = 10.0

    private let imageLayer = CALayer()

    /// Identity of what is displayed, so `updateNSView` stays idempotent.
    private(set) var displayedImage: CGImage?
    private(set) var displayedURL: URL?

    private var zoom: Double = 1.0
    private var rotationSteps: Int = 0
    private var offset: CGPoint = .zero
    private var panOrigin: NSPoint?
    private var lastSwipe: Date = .distantPast

    var onNavigate: ((Int) -> Void)?
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        imageLayer.isHidden = true
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
            // Spec 01 §15-16: a new image re-fits and clears rotation.
            zoom = 1.0
            rotationSteps = 0
            offset = .zero
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
        CATransaction.commit()
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

    private func applyTransform() {
        guard displayedImage != nil else { return }
        let scale = fitScale * CGFloat(zoom)
        var transform = CATransform3DMakeRotation(CGFloat(rotationSteps) * .pi / 2, 0, 0, 1)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.transform = transform
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

    /// Spec 01 §16: reject out of range instead of clamping; anchor at `anchor` (view coords).
    private func applyZoom(target: Double, anchor: CGPoint) {
        guard target >= Self.minZoom, target <= Self.maxZoom else { return }
        let previous = zoom
        guard previous > 0 else { return }
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

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        if event.clickCount == 2 {
            resetZoom()
            return
        }
        panOrigin = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
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
    var onNavigate: (Int) -> Void
    var onFocus: () -> Void

    final class Coordinator {
        var rotationToken = 0
        var zoomToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(frame: .zero)
        context.coordinator.rotationToken = rotationToken
        context.coordinator.zoomToken = zoomToken
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.onNavigate = onNavigate
        view.onFocus = onFocus
        view.set(image: image, url: url)
        if context.coordinator.rotationToken != rotationToken {
            context.coordinator.rotationToken = rotationToken
            view.rotate()
        }
        if context.coordinator.zoomToken != zoomToken {
            context.coordinator.zoomToken = zoomToken
            view.toggleDoubleZoom()
        }
    }
}
