import Foundation

/// What a folder looked like the last time it was open: how many files of each kind, and how
/// many files carried each rating. Written while the folder is open and read back on the
/// empty-state dashboard — recent folders are never rescanned in the background.
public struct FolderSummary: Codable, Equatable, Sendable {
    public var raw: Int
    public var jpeg: Int
    public var video: Int
    /// Keys are `-1...5`; `-1` is rejected, `0` unrated. Zero buckets are omitted.
    public var ratings: [Int: Int]
    public var updatedAt: Date

    public init(raw: Int = 0, jpeg: Int = 0, video: Int = 0,
                ratings: [Int: Int] = [:], updatedAt: Date = Date()) {
        self.raw = raw
        self.jpeg = jpeg
        self.video = video
        self.ratings = ratings.filter { $0.value > 0 }
        self.updatedAt = updatedAt
    }

    public var total: Int { raw + jpeg + video }

    /// `stars` is `-1...5`; `0` is the unrated bucket.
    public func rated(stars: Int) -> Int { ratings[stars] ?? 0 }

    public func count(for kind: MediaKind) -> Int {
        switch kind {
        case .raw: return raw
        case .jpeg: return jpeg
        case .video: return video
        }
    }

    // `[Int: Int]` would encode as a flat `[k, v, k, v]` array; string keys keep the file
    // readable and stable.
    enum CodingKeys: String, CodingKey {
        case raw, jpeg, video, ratings
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raw = try container.decodeIfPresent(Int.self, forKey: .raw) ?? 0
        jpeg = try container.decodeIfPresent(Int.self, forKey: .jpeg) ?? 0
        video = try container.decodeIfPresent(Int.self, forKey: .video) ?? 0
        let stringKeyed = try container.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
        var decoded: [Int: Int] = [:]
        for (key, value) in stringKeyed where value > 0 {
            if let intKey = Int(key) { decoded[intKey] = value }
        }
        ratings = decoded
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        try container.encode(jpeg, forKey: .jpeg)
        try container.encode(video, forKey: .video)
        var stringKeyed: [String: Int] = [:]
        for (key, value) in ratings where value > 0 { stringKeyed[String(key)] = value }
        try container.encode(stringKeyed, forKey: .ratings)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// JSON store keyed by absolute folder path, like `ShootStats`. Whole-file rewrite on every
/// save; every error is swallowed — a missing or corrupt cache just means "no summary".
public final class FolderSummaryStore: @unchecked Sendable {
    public static let shared = FolderSummaryStore()

    private let file: URL
    private let lock = NSLock()

    public init(file: URL = AppPaths.folderSummariesFile) {
        self.file = file
    }

    public func load(folder: URL) -> FolderSummary? {
        loadAll()[Self.key(folder)]
    }

    public func save(_ summary: FolderSummary, for folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        var all = decode()
        all[Self.key(folder)] = summary
        AppPaths.ensureDirectory(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public func loadAll() -> [String: FolderSummary] {
        lock.lock()
        defer { lock.unlock() }
        return decode()
    }

    private func decode() -> [String: FolderSummary] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: FolderSummary].self, from: data)) ?? [:]
    }

    static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }
}
