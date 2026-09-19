import Foundation

/// Canonical on-disk locations. Spec 07 §2 rewrite note: move to macOS-conventional paths.
public enum AppPaths {
    public static let bundleIdentifier = "dev.yannickpulver.rawviewer"

    public static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RAW Viewer", isDirectory: true)
    }

    public static var dateCacheFile: URL { cachesDirectory.appendingPathComponent("dates.json") }
    public static var thumbnailCacheDirectory: URL { cachesDirectory.appendingPathComponent("thumbs", isDirectory: true) }
    public static var shootStatsFile: URL { applicationSupportDirectory.appendingPathComponent("shoot_stats.json") }
    public static var folderSummariesFile: URL { applicationSupportDirectory.appendingPathComponent("folder_summaries.json") }

    /// Legacy Python locations, imported once on first launch. Spec 07 §11.
    public static var legacyCacheDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/raw-viewer", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }
}
