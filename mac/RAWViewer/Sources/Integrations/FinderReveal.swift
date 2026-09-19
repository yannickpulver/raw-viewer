import AppKit
import Foundation

public enum FinderReveal {

    /// Reveals and selects a single file in Finder (the `open -R` equivalent).
    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals and selects several files in Finder.
    public static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
