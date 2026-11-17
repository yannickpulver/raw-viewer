import Foundation

/// Recent folder list: max 5, newest first, deduplicated. Folders that are gone stay in the
/// list: a shoot on an unplugged drive shows as offline until the drive is back. Spec 07 §4.
public final class RecentFolders {
    public static let maximum = 5
    public static let shared = RecentFolders(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> [URL] {
        let stored = defaults.stringArray(forKey: Preferences.Keys.recentFolders) ?? []
        var seen = Set<String>()
        var result: [URL] = []
        for path in stored where !seen.contains(path) {
            seen.insert(path)
            result.append(URL(fileURLWithPath: path, isDirectory: true))
            if result.count == Self.maximum { break }
        }
        return result
    }

    @discardableResult
    public func add(_ folder: URL) -> [URL] {
        let path = folder.standardizedFileURL.path
        var list = load().map(\.path).filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > Self.maximum { list = Array(list.prefix(Self.maximum)) }
        defaults.set(list, forKey: Preferences.Keys.recentFolders)
        return list.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func remove(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        let list = (defaults.stringArray(forKey: Preferences.Keys.recentFolders) ?? []).filter { $0 != path }
        defaults.set(list, forKey: Preferences.Keys.recentFolders)
    }

    /// The folder exists right now, as a directory.
    public static func isReachable(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The drive a folder lives on, read from its path so it also works while the drive is
    /// unplugged: `/Volumes/Samsung T7/…` is "Samsung T7", anything else "This Mac".
    public static func driveName(_ folder: URL) -> String {
        let parts = folder.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] }
        return "This Mac"
    }

    /// One-shot import of `~/.cache/raw-viewer/recent_folders.json`. Spec 07 §4.
    public func importLegacyIfNeeded(preferences: Preferences) {
        guard !preferences.didImportLegacyCache else { return }
        preferences.didImportLegacyCache = true

        let legacy = AppPaths.legacyCacheDirectory.appendingPathComponent("recent_folders.json")
        if let data = try? Data(contentsOf: legacy),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            let existing = defaults.stringArray(forKey: Preferences.Keys.recentFolders) ?? []
            let merged = Array((existing + paths).reduce(into: [String]()) { acc, p in
                if !acc.contains(p) { acc.append(p) }
            }.prefix(Self.maximum))
            defaults.set(merged, forKey: Preferences.Keys.recentFolders)
        }

        ShootStats.importLegacyIfPresent()
    }
}
