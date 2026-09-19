import Foundation

/// One folder's persisted shoot timer. Spec 07 §5.
public struct ShootStatsEntry: Codable, Equatable, Sendable {
    public var elapsed: Double
    public var ratedCount: Int
    public var lastRatingElapsed: Double?

    public init(elapsed: Double = 0, ratedCount: Int = 0, lastRatingElapsed: Double? = nil) {
        self.elapsed = elapsed
        self.ratedCount = ratedCount
        self.lastRatingElapsed = lastRatingElapsed
    }

    enum CodingKeys: String, CodingKey {
        case elapsed
        case ratedCount = "rated_count"
        case lastRatingElapsed = "last_rating_elapsed"
    }
}

/// JSON store keyed by absolute folder path. Spec 07 §5.
public enum ShootStats {
    public static func load(folder: URL, file: URL = AppPaths.shootStatsFile) -> ShootStatsEntry? {
        loadAll(file: file)[folder.standardizedFileURL.path]
    }

    public static func save(_ entry: ShootStatsEntry, folder: URL, file: URL = AppPaths.shootStatsFile) {
        var all = loadAll(file: file)
        all[folder.standardizedFileURL.path] = entry
        AppPaths.ensureDirectory(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public static func loadAll(file: URL = AppPaths.shootStatsFile) -> [String: ShootStatsEntry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: ShootStatsEntry].self, from: data)) ?? [:]
    }

    static func importLegacyIfPresent() {
        let legacy = AppPaths.legacyCacheDirectory.appendingPathComponent("shoot_stats.json")
        guard FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: AppPaths.shootStatsFile.path),
              let data = try? Data(contentsOf: legacy),
              let decoded = try? JSONDecoder().decode([String: ShootStatsEntry].self, from: data) else { return }
        AppPaths.ensureDirectory(AppPaths.applicationSupportDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let out = try? encoder.encode(decoded) {
            try? out.write(to: AppPaths.shootStatsFile, options: .atomic)
        }
    }
}
