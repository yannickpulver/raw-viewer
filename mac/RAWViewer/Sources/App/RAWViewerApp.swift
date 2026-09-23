import AppKit
import SwiftUI

@main
struct RAWViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .background(WindowConfigurator())
                .frame(minWidth: 600, minHeight: 400)
        }
        // A unified toolbar over full-bleed content: the traffic lights sit in the same bar as
        // the chrome, so nothing can overlap them. The title itself stays hidden.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(model: model) }
    }
}

/// Black full-bleed window with a remembered frame. Spec 01 §1.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = .black
            // The image has to run all the way under the toolbar, and the window is always
            // black, so its chrome is pinned dark like the rest of the UI.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameAutosaveName("RAWViewerMainWindow")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var keyMonitor: Any?
    private var model: AppModel { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One dispatcher for every key, so menu items and keys can never disagree. Spec 02 §0.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard NSApp.modalWindow == nil, NSApp.keyWindow != nil else { return event }
            return MainActor.assumeIsolated { self.model.handleKey(event) ? nil : event }
        }

        // Spec 04 §9: trim the disk thumbnail cache back under its budget, once, off-main.
        Task.detached(priority: .background) {
            DiskThumbnailCache.shared.enforceSizeCap()
        }

        // A folder path as the first CLI argument opens exactly like the UI would.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = arguments.first {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            model.openFirstDirectory(in: [url])
            openInitialWindowIfSuppressed()
        }
    }

    /// AppKit turns a bare path argument into an "opened with a document" launch, and SwiftUI
    /// then skips creating the `WindowGroup`'s initial window — `RAWViewer <folder>` would load
    /// the folder into a windowless process. Asking the SwiftUI-provided delegate hook for the
    /// untitled window (the same one it opens on a plain launch) restores it.
    private func openInitialWindowIfSuppressed() {
        DispatchQueue.main.async {
            guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock-icon drop / "Open With". Directories only. Spec 01 §10.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.openFirstDirectory(in: urls)
    }

    /// Spec 01 §12: persist the shoot stats and flush pending sidecar writes before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.video.stop()
        model.library.persistShootStats()
        Task {
            await model.library.flushPendingWrites()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

