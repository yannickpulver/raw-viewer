import AppKit
import SwiftUI

struct GridModel {
    var files: [MediaFile]
    var index: Int
    var ratings: [URL: Int]
    /// `nil` while scenes are not grouped.
    var scenes: Scenes?
    /// `nil` under Best Faces: then the grid is one plain list (scenes are off there too).
    var days: Scenes?
    /// The sections drawn: days and scenes merged (`ModeState.gridGroups`).
    var groups: Scenes
    /// `Library.dayJumpRevision`: a change scrolls the current day's header to the top.
    var dayJumpRevision: Int
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

extension GridModel {
    func startsDay(_ group: Int) -> Bool { days?.starts(at: groups.starts[group]) ?? false }
    func startsScene(_ group: Int) -> Bool { scenes?.starts(at: groups.starts[group]) ?? false }

    /// A day band, a scene band, or both stacked when a day opens with a new scene.
    var headers: [Int] {
        (0..<groups.count).map {
            (startsDay($0) ? GridLayout.dayHeader : 0) + (startsScene($0) ? GridLayout.sceneHeader : 0)
        }
    }
}

/// Custom-drawn grid. Spec 01 §8; all geometry comes from `GridLayout`.
final class GridCanvasView: NSView {

    var model: GridModel?
    var geometry = GridGeometry(scenes: Scenes(total: 0), columns: 1)
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

        let cell = geometry.cell
        let range = geometry.visibleIndexRange(top: Int(dirtyRect.minY), bottom: Int(dirtyRect.maxY))
        guard range.first <= range.last else { return }
        drawSceneCaptions(model, first: range.first, last: range.last, dirtyRect: dirtyRect)

        for i in range.first...range.last {
            let file = model.files[i]
            let origin = geometry.cellOrigin(index: i)
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

    /// Above each visible group: the day band (`Wednesday, 4 November  ·  312 frames  ·
    /// 12 picked`), then the scene band (`15:27  ·  6 frames  ·  2 picked`) when scenes are
    /// grouped. The group after the last visible cell is included, since its band can show
    /// before its row.
    private func drawSceneCaptions(_ model: GridModel, first: Int, last: Int, dirtyRect: NSRect) {
        let groups = model.groups
        guard !groups.starts.isEmpty else { return }
        for group in groups.scene(of: first)...min(groups.count - 1, groups.scene(of: last) + 1) {
            var top = CGFloat(geometry.headerTop(scene: group))
            guard geometry.headers[group] > 0, top < dirtyRect.maxY,
                  top + CGFloat(geometry.headers[group]) > dirtyRect.minY else { continue }
            let start = groups.starts[group]
            if model.startsDay(group), let days = model.days {
                let range = days.range(of: days.scene(of: start))
                drawCaption(title: Self.formatDay(model.files[start].captureDate),
                            detail: counts(model, range), top: top, height: GridLayout.dayHeader,
                            titleFont: .systemFont(ofSize: 15, weight: .semibold), titleWhite: 1)
                top += CGFloat(GridLayout.dayHeader)
            }
            if model.startsScene(group), let scenes = model.scenes {
                let range = scenes.range(of: scenes.scene(of: start))
                let time = model.files[start].captureDate.formatted(date: .omitted, time: .shortened)
                drawCaption(title: time, detail: counts(model, range), top: top, height: GridLayout.sceneHeader,
                            titleFont: .systemFont(ofSize: 11, weight: .medium), titleWhite: 170.0 / 255.0)
            }
        }
    }

    private func counts(_ model: GridModel, _ range: Range<Int>) -> String {
        let picked = model.files[range].filter { (model.ratings[$0.url] ?? 0) > 0 }.count
        var parts = [range.count == 1 ? "1 frame" : "\(range.count) frames"]
        if picked > 0 { parts.append("\(picked) picked") }
        return parts.joined(separator: "  ·  ")
    }

    private func drawCaption(title: String, detail: String, top: CGFloat, height: Int,
                             titleFont: NSFont, titleWhite: CGFloat) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: NSColor(white: titleWhite, alpha: 1),
        ])
        text.append(NSAttributedString(string: "  ·  " + detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 140.0 / 255.0, alpha: 1),
        ]))
        let inset: CGFloat = (CGFloat(height) - text.size().height) / 2 + 2
        text.draw(at: NSPoint(x: CGFloat(geometry.spacing + 2), y: top + inset))
    }

    /// `Wednesday, 4 November`, with the year when it is not this year.
    static func formatDay(_ date: Date, now: Date = Date()) -> String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    override func mouseDown(with event: NSEvent) {
        guard model != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = geometry.index(atX: point.x, y: point.y)
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
        guard model != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = geometry.index(atX: point.x, y: point.y)
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

        let origin = geometry.cellOrigin(index: index)
        let rect = NSRect(x: CGFloat(origin.x), y: CGFloat(origin.y),
                          width: CGFloat(geometry.cell), height: CGFloat(geometry.cell))
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
        var geometry = GridGeometry(scenes: Scenes(total: 0), columns: 1)
        var debounce: Timer?
        var lastIndex = -1
        var lastRevision = -1
        var lastCount = -1
        var lastRatingsRevision = -1
        var lastSelectionRevision = -1
        var lastDayJump = -1
        var pushedInitialRange = false

        @objc func boundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            schedule(visible: clip.documentVisibleRect)
        }

        func schedule(visible: NSRect) {
            debounce?.invalidate()
            let geometry = self.geometry
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                let range = geometry.visibleIndexRange(top: Int(visible.minY), bottom: Int(visible.maxY))
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
        // Always visible, so the scroll position (and how far the days run) shows at a glance.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
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
        let geometry = GridGeometry(scenes: model.groups, headers: model.headers, columns: columns, cell: cell)
        let height = geometry.contentHeight

        canvas.model = model
        canvas.geometry = geometry
        canvas.onClick = onClick
        canvas.onActivate = onActivate

        coordinator.geometry = geometry

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
        if coordinator.lastDayJump != model.dayJumpRevision {
            // A day jump puts that day's header at the top. The grid's first appearance only
            // takes the revision over and scrolls the current cell into view below.
            if coordinator.lastDayJump >= 0, !model.groups.starts.isEmpty {
                coordinator.lastIndex = model.index
                let top = CGFloat(geometry.headerTop(scene: model.groups.scene(of: model.index)))
                let clip = scroll.contentView
                let origin = NSPoint(x: 0, y: top - CGFloat(geometry.spacing) - scroll.contentInsets.top)
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                scroll.reflectScrolledClipView(clip)
            }
            coordinator.lastDayJump = model.dayJumpRevision
        }
        if coordinator.lastIndex != model.index, !model.groups.starts.isEmpty {
            coordinator.lastIndex = model.index
            // The first row of a group brings its captions into view with it.
            let origin = geometry.cellOrigin(index: model.index)
            let group = model.groups.scene(of: model.index)
            let header = model.index - model.groups.starts[group] < columns ? geometry.headers[group] : 0
            canvas.scrollToVisible(NSRect(x: CGFloat(origin.x) - 2, y: CGFloat(origin.y - header) - 2,
                                          width: CGFloat(cell) + 4, height: CGFloat(cell + header) + 4))
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
