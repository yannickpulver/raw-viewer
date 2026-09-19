import AppKit
import SwiftUI

/// Everything the filmstrip needs for one paint, pushed in from `body`.
struct FilmstripModel {
    var files: [MediaFile]
    var index: Int
    var ratings: [URL: Int]
    /// Bumped whenever a thumbnail lands, so the strip repaints.
    var thumbRevision: Int
    /// Bumped on every ratings mutation. `ratings.count` is not enough: re-rating the file that
    /// is already selected (last file, pinned pane) changes a value, never the count.
    var ratingsRevision: Int
    var thumb: (URL) -> CGImage?
}

/// Always-on 18 px horizontal scroller drawn to spec 01 §3: `#777` pill handle (radius 5,
/// min width 40, `#999` on hover) on a `#222` track (radius 5), margins 0 / 8 / 8 / 8.
final class FilmstripScroller: NSScroller {

    static let thickness: CGFloat = 18
    private static let margin: CGFloat = 8
    private static let minKnobWidth: CGFloat = 40

    private var hovering = false

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { thickness }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// Track geometry: the full width minus the 8 px side margins, the full height minus the
    /// 8 px bottom margin (the view is not flipped, so that is `minY`).
    private var trackRect: NSRect {
        NSRect(x: Self.margin,
               y: Self.margin,
               width: max(0, bounds.width - 2 * Self.margin),
               height: max(0, bounds.height - Self.margin))
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        let track = trackRect
        guard track.width > 0, track.height > 0 else { return }
        NSColor(white: 34.0 / 255.0, alpha: 1).setFill()   // #222
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
    }

    override func drawKnob() {
        let track = trackRect
        guard track.width > 0, track.height > 0 else { return }
        let proportion = CGFloat(knobProportion)
        let width = min(track.width, max(Self.minKnobWidth, track.width * proportion))
        let x = track.minX + (track.width - width) * CGFloat(doubleValue)
        let knob = NSRect(x: x, y: track.minY, width: width, height: track.height)
        let grey: CGFloat = hovering ? 153.0 / 255.0 : 119.0 / 255.0   // #999 / #777
        NSColor(white: grey, alpha: 1).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 5, yRadius: 5).fill()
    }
}

/// Custom-drawn filmstrip. Spec 01 §3.
final class FilmstripContentView: NSView {

    var model: FilmstripModel?
    var onSelect: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }

        // Strip background behind the cells.
        context.setFillColor(NSColor(white: 20.0 / 255.0, alpha: 1).cgColor)
        context.fill(bounds)

        let stride = Theme.thumbStride
        let cell = Theme.thumbSize
        let first = max(0, Int(floor(dirtyRect.minX / stride)))
        let last = min(model.files.count - 1, Int(ceil(dirtyRect.maxX / stride)))
        guard first <= last else { return }

        for i in first...last {
            let file = model.files[i]
            let x = CGFloat(i) * stride
            let y: CGFloat = 4

            context.setFillColor(NSColor(white: 40.0 / 255.0, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: y, width: cell, height: cell))

            if let image = model.thumb(file.url) {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let scale = min(cell / iw, cell / ih)
                let w = iw * scale, h = ih * scale
                let rect = CGRect(x: x + (cell - w) / 2, y: y + (cell - h) / 2, width: w, height: h)
                context.saveGState()
                // The view is flipped; draw the image the right way up.
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                context.restoreGState()
            }

            if i == model.index {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(CGRect(x: x - 2, y: y - 2, width: 84, height: 84).insetBy(dx: 1.5, dy: 1.5))
            }

            let rating = model.ratings[file.url] ?? 0
            if rating > 0 {
                context.setFillColor(NSColor(red: 1, green: 200.0 / 255.0, blue: 50.0 / 255.0, alpha: 1).cgColor)
                let dotY: CGFloat = 89
                let startX = x + (cell - CGFloat(rating) * 8) / 2
                for dot in 0..<rating {
                    context.fillEllipse(in: CGRect(x: startX + CGFloat(dot) * 8, y: dotY, width: 5, height: 5))
                }
            } else if rating == -1 {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: NSColor(red: 230.0 / 255.0, green: 70.0 / 255.0, blue: 70.0 / 255.0, alpha: 1),
                ]
                let text = NSAttributedString(string: "✕", attributes: attributes)
                let size = text.size()
                text.draw(at: NSPoint(x: x + (cell - size.width) / 2, y: 86 + (14 - size.height) / 2))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor(point.x / Theme.thumbStride))
        guard index >= 0, index < model.files.count else { return }
        onSelect?(index)
    }

    /// Spec 02 §4: two-finger scroll uses `scrollingDeltaX`; a vertical wheel becomes horizontal.
    override func scrollWheel(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let dx: CGFloat = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard dx != 0 else { return }
        var origin = clip.bounds.origin
        let maxX = max(0, bounds.width - clip.bounds.width)
        origin.x = min(maxX, max(0, origin.x - dx))
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

struct FilmstripView: NSViewRepresentable {
    var model: FilmstripModel
    var onSelect: (Int) -> Void
    var onVisibleRange: (Range<Int>) -> Void

    final class Coordinator: NSObject {
        var onVisibleRange: ((Range<Int>) -> Void)?
        var debounce: Timer?
        var lastIndex: Int = -1
        var lastRevision: Int = -1
        var lastCount: Int = -1
        var lastRatingsRevision: Int = -1
        var pushedInitialRange = false

        @objc func boundsChanged(_ note: Notification) {
            debounce?.invalidate()
            guard let clip = note.object as? NSClipView else { return }
            schedule(visible: clip.documentVisibleRect)
        }

        func schedule(visible: NSRect) {
            debounce?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                let first = max(0, Int(floor(visible.minX / Theme.thumbStride)))
                let last = Int(ceil(visible.maxX / Theme.thumbStride))
                guard first < last else { return }
                self?.onVisibleRange?(first..<last)
            }
            // `.common` so the timer still fires while a trackpad scroll runs the event
            // tracking run loop mode — otherwise nothing loads until the scroll stops.
            RunLoop.main.add(timer, forMode: .common)
            debounce = timer
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let content = FilmstripContentView(frame: NSRect(x: 0, y: 0, width: 0, height: 100))
        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.horizontalScroller = FilmstripScroller()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 20.0 / 255.0, alpha: 1)
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let content = scroll.documentView as? FilmstripContentView else { return }
        context.coordinator.onVisibleRange = onVisibleRange
        content.model = model
        content.onSelect = onSelect

        let width = max(scroll.bounds.width, CGFloat(model.files.count) * Theme.thumbStride)
        let height = scroll.contentSize.height
        if content.frame.size != CGSize(width: width, height: height) {
            content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }

        let coordinator = context.coordinator
        let changed = coordinator.lastIndex != model.index
            || coordinator.lastRevision != model.thumbRevision
            || coordinator.lastCount != model.files.count
            || coordinator.lastRatingsRevision != model.ratingsRevision
        if changed {
            coordinator.lastRevision = model.thumbRevision
            coordinator.lastCount = model.files.count
            coordinator.lastRatingsRevision = model.ratingsRevision
            content.needsDisplay = true
        }

        // First real layout: nothing has scrolled yet, so push the initial viewport by hand.
        if !coordinator.pushedInitialRange, scroll.bounds.width > 0, !model.files.isEmpty {
            coordinator.pushedInitialRange = true
            coordinator.schedule(visible: scroll.contentView.documentVisibleRect)
        }
        if coordinator.lastIndex != model.index {
            coordinator.lastIndex = model.index
            let x = CGFloat(model.index) * Theme.thumbStride
            content.scrollToVisible(NSRect(x: x - 2, y: 0, width: Theme.thumbStride + 4, height: content.bounds.height))
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.debounce?.invalidate()
    }
}
