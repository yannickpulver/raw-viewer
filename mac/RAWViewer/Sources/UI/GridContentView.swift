import AppKit
import SwiftUI

struct GridModel {
    var files: [MediaFile]
    var index: Int
    var ratings: [URL: Int]
    var thumbRevision: Int
    /// See `FilmstripModel.ratingsRevision`: a value change is invisible to `ratings.count`.
    var ratingsRevision: Int
    /// See `ratingsRevision`: a closure alone is invisible to change detection, hence the
    /// paired `selectionRevision`.
    var isSelected: (Int) -> Bool
    var selectionRevision: Int
    /// The current multi-selection, resolved into `files` order — what a right-click on an
    /// already-selected cell acts on. A closure, not a snapshot array: `isSelected` already
    /// calls live into `Library`, and a `selectedURLs` array frozen at the last SwiftUI body
    /// pass would go stale between clicks within the same body (cmd-click then immediately
    /// right-click the same cell) — both need to see the same live selection.
    var selectedURLs: () -> [URL]
    var thumb200: (URL) -> CGImage?
    var thumb80: (URL) -> CGImage?
}

/// Custom-drawn grid. Spec 01 §8; all geometry comes from `GridLayout`.
final class GridCanvasView: NSView {

    var model: GridModel?
    var columns: Int = 1
    var cellSize: Int = GridLayout.cell
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onActivate: ((Int) -> Void)?
    /// Kept alive across the popup and any share sheet it opens. See `SelectionMenuController`.
    private var selectionMenuController: SelectionMenuController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor(white: 20.0 / 255.0, alpha: 1).cgColor)
        context.fill(dirtyRect)

        let cell = cellSize
        let range = GridLayout.visibleIndexRange(top: Int(dirtyRect.minY), bottom: Int(dirtyRect.maxY),
                                                 columns: columns, total: model.files.count, cell: cell)
        guard range.first <= range.last else { return }

        for i in range.first...range.last {
            let file = model.files[i]
            let origin = GridLayout.cellOrigin(index: i, columns: columns, cell: cell)
            let x = CGFloat(origin.x), y = CGFloat(origin.y), side = CGFloat(cell)

            context.setFillColor(NSColor(white: 40.0 / 255.0, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: y, width: side, height: side))

            if let image = model.thumb200(file.url) ?? model.thumb80(file.url) {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let scale = min(side / iw, side / ih)
                let w = iw * scale, h = ih * scale
                let rect = CGRect(x: x + (side - w) / 2, y: y + (side - h) / 2, width: w, height: h)
                context.saveGState()
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                context.restoreGState()
            }

            // Selection border first, current-file border last, so white always wins when a
            // cell is both.
            if model.isSelected(i) {
                context.setStrokeColor(Theme.amberBorderCGColor)
                context.setLineWidth(2)
                context.stroke(CGRect(x: x - 2, y: y - 2, width: side + 4, height: side + 4).insetBy(dx: 1, dy: 1))
            }
            if i == model.index {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(CGRect(x: x - 2, y: y - 2, width: side + 4, height: side + 4).insetBy(dx: 1.5, dy: 1.5))
            }

            let rating = model.ratings[file.url] ?? 0
            if rating > 0 {
                context.setFillColor(NSColor(red: 1, green: 200.0 / 255.0, blue: 50.0 / 255.0, alpha: 1).cgColor)
                let dotY = y + side - 14
                let startX = x + (side - CGFloat(rating) * 10) / 2
                for dot in 0..<rating {
                    context.fillEllipse(in: CGRect(x: startX + CGFloat(dot) * 10, y: dotY, width: 6, height: 6))
                }
            } else if rating == -1 {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: NSColor(red: 230.0 / 255.0, green: 70.0 / 255.0, blue: 70.0 / 255.0, alpha: 1),
                ]
                let text = NSAttributedString(string: "✕", attributes: attributes)
                let size = text.size()
                text.draw(at: NSPoint(x: x + (side - size.width) / 2, y: y + side - 26 + (20 - size.height) / 2))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = GridLayout.index(atX: point.x, y: point.y, columns: columns,
                                     total: model.files.count, cell: cellSize)
        guard index >= 0 else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // AppKit delivers a control-click as `mouseDown` with `.control` set, not as
        // `rightMouseDown` — that is the standard right-click on a one-button mouse or
        // trackpad, so it opens the same menu instead of falling through to a plain select.
        if modifiers.contains(.control) {
            openMenu(at: index, point: point)
            return
        }
        if event.clickCount == 2 {
            onActivate?(index)
        } else {
            onClick?(index, modifiers)
        }
    }

    /// Right-click on an already-selected cell acts on the whole selection; otherwise the
    /// click first collapses the selection to that cell. Spec: mac app addition.
    override func rightMouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = GridLayout.index(atX: point.x, y: point.y, columns: columns,
                                     total: model.files.count, cell: cellSize)
        guard index >= 0 else { return }
        openMenu(at: index, point: point)
    }

    private func openMenu(at index: Int, point: NSPoint) {
        guard let model else { return }
        let urls: [URL]
        if model.isSelected(index) {
            urls = model.selectedURLs()
        } else {
            onClick?(index, [])
            urls = [model.files[index].url]
        }

        let origin = GridLayout.cellOrigin(index: index, columns: columns, cell: cellSize)
        let rect = NSRect(x: CGFloat(origin.x), y: CGFloat(origin.y),
                          width: CGFloat(cellSize), height: CGFloat(cellSize))
        let controller = SelectionMenuController(urls: urls, view: self, rect: rect)
        selectionMenuController = controller
        controller.makeMenu().popUp(positioning: nil, at: point, in: self)
    }
}

struct GridView: NSViewRepresentable {
    var model: GridModel
    var onClick: (Int, NSEvent.ModifierFlags) -> Void
    var onActivate: (Int) -> Void
    var onLayout: (Int) -> Void
    var onVisibleRange: (Range<Int>) -> Void

    final class Coordinator: NSObject {
        var onVisibleRange: ((Range<Int>) -> Void)?
        var columns = 1
        var cellSize = GridLayout.cell
        var total = 0
        var debounce: Timer?
        var lastIndex = -1
        var lastRevision = -1
        var lastCount = -1
        var lastRatingsRevision = -1
        var lastSelectionRevision = -1
        var pushedInitialRange = false

        @objc func boundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            schedule(visible: clip.documentVisibleRect)
        }

        func schedule(visible: NSRect) {
            debounce?.invalidate()
            let columns = self.columns, cell = self.cellSize, total = self.total
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                let range = GridLayout.visibleIndexRange(top: Int(visible.minY), bottom: Int(visible.maxY),
                                                         columns: columns, total: total, cell: cell)
                guard range.first <= range.last else { return }
                self?.onVisibleRange?(range.first..<(range.last + 1))
            }
            // `.common`, so a trackpad scroll keeps loading thumbnails while it runs.
            RunLoop.main.add(timer, forMode: .common)
            debounce = timer
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = GridCanvasView(frame: .zero)
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 20.0 / 255.0, alpha: 1)
        scroll.borderType = .noBorder
        // The grid runs full-bleed under the transparent toolbar, so AppKit keeps the top
        // content inset in step with the window's content layout rect (including fullscreen).
        scroll.automaticallyAdjustsContentInsets = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? GridCanvasView else { return }
        let coordinator = context.coordinator
        coordinator.onVisibleRange = onVisibleRange

        let width = Int(scroll.contentSize.width)
        let columns = GridLayout.columns(forWidth: width)
        let cell = GridLayout.cellSize(forWidth: width, columns: columns)
        let height = GridLayout.contentHeight(total: model.files.count, columns: columns, cell: cell)

        canvas.model = model
        canvas.columns = columns
        canvas.cellSize = cell
        canvas.onClick = onClick
        canvas.onActivate = onActivate

        coordinator.columns = columns
        coordinator.cellSize = cell
        coordinator.total = model.files.count

        let wanted = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(height))
        var layoutChanged = false
        if canvas.frame != wanted {
            canvas.frame = wanted
            layoutChanged = true
        }
        if layoutChanged || coordinator.lastRevision != model.thumbRevision
            || coordinator.lastCount != model.files.count
            || coordinator.lastRatingsRevision != model.ratingsRevision
            || coordinator.lastSelectionRevision != model.selectionRevision
            || coordinator.lastIndex != model.index {
            coordinator.lastRevision = model.thumbRevision
            coordinator.lastCount = model.files.count
            coordinator.lastRatingsRevision = model.ratingsRevision
            coordinator.lastSelectionRevision = model.selectionRevision
            canvas.needsDisplay = true
        }
        if coordinator.lastIndex != model.index {
            coordinator.lastIndex = model.index
            let origin = GridLayout.cellOrigin(index: model.index, columns: columns, cell: cell)
            canvas.scrollToVisible(NSRect(x: CGFloat(origin.x) - 2, y: CGFloat(origin.y) - 2,
                                          width: CGFloat(cell) + 4, height: CGFloat(cell) + 4))
        }
        // First real layout: no scroll has happened, so the visible range has never been
        // pushed and the first viewport would sit on 80 px thumbs until the user scrolls.
        if !coordinator.pushedInitialRange, scroll.contentSize.width > 0, !model.files.isEmpty {
            coordinator.pushedInitialRange = true
            coordinator.schedule(visible: scroll.contentView.documentVisibleRect)
        }
        DispatchQueue.main.async { onLayout(columns) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.debounce?.invalidate()
    }
}
