import Foundation

/// Recent folder list: max 5, newest first, deduplicated, non-directories pruned on load.
/// Spec 07 §4.
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
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
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
