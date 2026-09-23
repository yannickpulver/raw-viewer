import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let model: AppModel
    var library: Library { model.library }

    var body: some View {
        let files = library.files
        let index = library.index
        let ratings = library.ratings
        let scheduler = library.scheduler
        let thumbRevision = scheduler.thumbs80.count &+ scheduler.thumbs200.count &+ scheduler.previewRevision
        let showFilmstrip = !files.isEmpty && library.filmstripVisible && library.displayMode == .single

        VStack(spacing: 0) {
            ZStack {
                // Only the image area runs under the transparent toolbar; the overlays stay
                // inside the safe area so nothing of theirs can hide behind a toolbar item.
                contentArea
                    .ignoresSafeArea(edges: .top)
                overlays
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showFilmstrip {
                FilmstripView(
                    model: FilmstripModel(files: files, index: index, ratings: ratings,
                                          thumbRevision: thumbRevision,
                                          ratingsRevision: library.ratingsRevision,
                                          isSelected: { library.isSelected(index: $0) },
                                          selectionRevision: library.selectionRevision,
                                          selectedURLs: { library.selectedFiles.map(\.url) },
                                          thumb: { scheduler.thumb80(for: $0) }),
                    onClick: { index, modifiers in library.click(index: index, modifiers: modifiers) },
                    onVisibleRange: { library.filmstripVisibleRange($0) })
                .frame(height: Theme.filmstripHeight)
                .background(Theme.stripArea)
            }
        }
        .background(Theme.windowBackground.ignoresSafeArea())
        .overlay { centredOverlays }
        .toolbar { MainToolbar(model: model) }
        // Spec 01 §1: the toolbar floats over the photo, so it gets no background of its own.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The title stays hidden in the window, but Mission Control and the Window menu use it.
        .navigationTitle(library.windowTitle)
        // The window is always black, so the chrome's system materials and controls are
        // pinned to the dark appearance regardless of the system setting.
        .colorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: library.currentFile?.url) { _, _ in syncVideo() }
        .onChange(of: library.viewMode) { _, _ in syncVideo() }
        .onChange(of: library.displayMode) { _, new in
            if new == .grid { model.video.pause() }
        }
        .onChange(of: library.folder) { _, new in
            if new == nil { model.video.stop() }
        }
        .task(id: library.snackbar?.id) {
            guard let event = library.snackbar else { return }
            try? await Task.sleep(nanoseconds: UInt64(event.durationMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            library.clearSnackbar()
        }
        .task(id: model.showStats) {
            // Spec 01 §6: refresh every second while the overlay is visible.
            while model.showStats && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                model.statsTick &+= 1
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        let files = library.files
        if library.displayMode == .grid, !files.isEmpty {
            gridPane
        } else if library.viewMode == .video, !files.isEmpty {
            VideoPane(controller: model.video)
        } else if files.isEmpty {
            if library.isScanning {
                Color.black
            } else if library.hasLoadedFolder {
                Color.black
                Text("No images match this filter")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dimText)
            } else {
                EmptyStateView(model: model)
            }
        } else if library.isCompareActive {
            comparePanes
        } else {
            singleCanvas
        }
    }

    private func image(for file: MediaFile?) -> CGImage? {
        guard let file else { return nil }
        // Spec 04 §7: the 80 px thumbnail is the placeholder until the preview lands.
        return library.scheduler.preview(for: file.url) ?? library.scheduler.thumb80(for: file.url)
    }

    private var singleCanvas: some View {
        SingleCanvasPane(model: model, image: image(for: library.currentFile))
    }

    /// Spec 01 §9: 50/50, left pinned, focused pane gets a 2 px amber border.
    private var comparePanes: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                CanvasView(image: image(for: library.pinnedFile),
                           url: library.pinnedFile?.url,
                           rotationToken: model.compareRotationToken,
                           zoomToken: 0,
                           onNavigate: { _ in },
                           onFocus: { library.focusPane(.left) })
                    .frame(width: geometry.size.width / 2)
                    .border(library.focusedPane == .left ? Theme.amberBorder : Color.clear, width: 2)
                CanvasView(image: image(for: library.currentFile),
                           url: library.currentFile?.url,
                           rotationToken: model.rotationToken,
                           zoomToken: model.zoomToken,
                           onNavigate: { library.navigate(by: $0) },
                           onFocus: { library.focusPane(.right) })
                    .frame(width: geometry.size.width / 2)
                    .border(library.focusedPane == .right ? Theme.amberBorder : Color.clear, width: 2)
            }
        }
    }

    private var gridPane: some View {
        let scheduler = library.scheduler
        return GridView(
            model: GridModel(files: library.files, index: library.index, ratings: library.ratings,
                             thumbRevision: scheduler.thumbs80.count &+ scheduler.thumbs200.count,
                             ratingsRevision: library.ratingsRevision,
                             isSelected: { library.isSelected(index: $0) },
                             selectionRevision: library.selectionRevision,
                             selectedURLs: { library.selectedFiles.map(\.url) },
                             thumb200: { scheduler.thumb200(for: $0) },
                             thumb80: { scheduler.thumb80(for: $0) }),
            onClick: { index, modifiers in library.click(index: index, modifiers: modifiers) },
            onActivate: { library.select(index: $0); library.toggleGrid() },
            onLayout: { columns in
                if library.gridColumns != columns { library.gridColumns = columns }
            },
            onVisibleRange: { library.gridVisibleRange($0) })
        .background(Theme.stripBackground)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var overlays: some View {
        // The info block reaches up into the toolbar row. The reader stays inside the safe area,
        // because only there does it report the toolbar height; the block itself then ignores
        // that area to climb into the row. Its text lets clicks and window drags through; only
        // the face crops below it take clicks.
        GeometryReader { geometry in
            InfoBlock(model: model, toolbarHeight: geometry.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea(edges: .top)
        }
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if library.hasLoadedFolder { FilterToolbar(model: model) }
        }
        ZStack(alignment: .bottomLeading) {
            Color.clear
            CornerButtons(model: model)
        }
        ZStack(alignment: .bottom) {
            Color.clear
            if let snackbar = library.snackbar { SnackbarView(text: snackbar.text) }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var centredOverlays: some View {
        ZStack {
            if let text = library.scanProgressText, library.isScanning {
                ScanningLabel(text: text)
            }
            if let status = library.resolveStatus, !status.isEmpty {
                ResolveStatusView(text: status)
            }
            if model.showStats {
                let _ = model.statsTick
                StatsOverlay(lines: library.statsLines()) { model.showStats = false }
            }
            if model.showHelp {
                HelpOverlay { model.showHelp = false }
            }
        }
    }

    // MARK: - Helpers

    private func syncVideo() {
        if library.viewMode == .video, let file = library.currentFile, file.kind == .video {
            model.video.open(file.url)
        } else {
            model.video.stop()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // The completion handlers fire on arbitrary queues, concurrently, so the results are
        // collected under a lock and slotted by index to keep the drop order stable.
        let lock = NSLock()
        var collected = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (offset, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    collected[offset] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.openFirstDirectory(in: collected.compactMap { $0 })
        }
        return true
    }
}

/// The single-image canvas. Its own view so the face results, which land several times a
/// second during a sweep, re-render only the canvas and `FacePanel`, not the whole window.
private struct SingleCanvasPane: View {
    let model: AppModel
    let image: CGImage?
    var library: Library { model.library }

    var body: some View {
        let file = library.currentFile
        CanvasView(image: image,
                   url: file?.url,
                   rotationToken: model.rotationToken,
                   zoomToken: model.zoomToken,
                   faces: library.showsFaces ? file.flatMap { library.faceIndex.faces(for: $0.url) } ?? [] : [],
                   faceFocusToken: model.faceFocusToken,
                   faceFocus: model.faceFocus,
                   onNavigate: { library.navigate(by: $0) },
                   onFocus: {})
    }
}
