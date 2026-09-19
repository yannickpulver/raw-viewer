import AppKit
import Foundation

public enum Lightroom {

    public static let bundleIdentifier = "com.adobe.LightroomClassicCC7"

    /// Candidate application bundles, checked when the bundle identifier lookup
    /// fails. More locations can simply be appended.
    public static let applicationCandidates: [String] = [
        "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
        "/Applications/Adobe Lightroom Classic.app"
    ]

    /// Location of Lightroom Classic, or `nil` when it is not installed.
    public static var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let fm = FileManager.default
        if let path = applicationCandidates.first(where: { fm.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// Opens every file in Lightroom Classic.
    /// Returns `false` when Lightroom is not installed, so the caller can show
    /// the "Adobe Lightroom Classic not found" snackbar.
    @discardableResult
    public static func open(files: [URL]) -> Bool {
        guard let app = applicationURL else { return false }
        guard !files.isEmpty else { return true }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
        return true
    }
}
