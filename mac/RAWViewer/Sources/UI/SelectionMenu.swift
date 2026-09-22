import AppKit

/// The grid/filmstrip right-click menu: Share, Reveal in Finder, Copy. Mac app addition, no
/// Python-app equivalent.
///
/// Owns the URLs and the `NSSharingServicePicker` for the lifetime of the menu interaction.
/// `NSMenuItem.target` is weak, so the caller must retain this controller (typically as a
/// property on the view that popped the menu) until the menu — and any share sheet it opens —
/// is done. `view` itself is held weakly: the view already retains this controller, so a
/// strong back-reference would be a cycle that keeps the canvas (and everything its `GridModel`
/// closures capture) alive forever.
final class SelectionMenuController: NSObject {
    private let urls: [URL]
    private weak var view: NSView?
    private let rect: NSRect
    /// Kept alive for the lifetime of the picker; otherwise it is deallocated before the share
    /// sheet appears.
    private var picker: NSSharingServicePicker?

    /// - Parameters:
    ///   - urls: The files the menu acts on.
    ///   - view: The view to anchor the share sheet to.
    ///   - rect: The clicked cell's frame in `view`'s coordinates.
    init(urls: [URL], view: NSView, rect: NSRect) {
        self.urls = urls
        self.view = view
        self.rect = rect
    }

    func makeMenu() -> NSMenu {
        let count = urls.count
        let plural = count > 1
        let menu = NSMenu()
        menu.addItem(item(plural ? "Share \(count) Photos" : "Share", action: #selector(share)))
        menu.addItem(item(plural ? "Reveal \(count) Photos in Finder" : "Reveal in Finder",
                          action: #selector(reveal)))
        menu.addItem(item(plural ? "Copy \(count) Photos" : "Copy", action: #selector(copyURLs)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func share() {
        // Showing the picker synchronously from the menu item action, while the NSMenu is
        // still tearing down, makes it silently fail to appear — dispatch it to the next
        // run loop turn instead.
        DispatchQueue.main.async { [self] in
            // The view may have left the window (or been torn down) between the menu action
            // and this dispatched turn; showing against a windowless view silently no-ops.
            guard let view, view.window != nil else { return }
            let picker = NSSharingServicePicker(items: urls)
            self.picker = picker
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    @objc private func reveal() {
        FinderReveal.reveal(urls)
    }

    @objc private func copyURLs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Plain-text paths alongside the file URLs, so pasting into a text field (Mail
        // compose, a chat, a shell) yields something instead of nothing.
        let paths = urls.map(\.path).joined(separator: "\n")
        pasteboard.writeObjects(urls.map { $0 as NSURL } + [paths as NSString])
    }
}
