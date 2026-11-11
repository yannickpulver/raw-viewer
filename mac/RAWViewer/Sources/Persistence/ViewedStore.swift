import CryptoKit
import Foundation

/// Per folder: which files were ever shown large (single view, duel, compare), and where the
/// last visit ended. One JSON file per folder holding paths relative to it, so it stays small.
/// Files are identified by `ViewedStore.key(_:)`. Every error is swallowed; a missing or
/// corrupt file just means "nothing viewed yet, start at the beginning".
public final class ViewedStore: @unchecked Sendable {
    public static let shared = ViewedStore()

    public struct Entry: Equatable, Sendable {
        /// `ViewedStore.key`s.
        public var viewed: Set<String> = []
        /// The current file when the folder was last left, as a `ViewedStore.key`.
        public var last: String?
        /// The mode it was shown in.
        public var mode: ViewMode?

        public init(viewed: Set<String> = [], last: String? = nil, mode: ViewMode? = nil) {
            self.viewed = viewed
            self.last = last
            self.mode = mode
        }
    }

    /// On disk, with paths relative to the folder.
    private struct Stored: Codable {
        var viewed: [String]
        var last: String?
        var mode: String?
    }

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.viewedDirectory) {
        self.directory = directory
    }

    /// The identity of a file in the store: its standardized absolute path.
    public static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    public func load(folder: URL) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(for: folder)) else { return Entry() }
        let prefix = Self.prefix(folder)
        func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : prefix + path }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return Entry(viewed: Set(stored.viewed.map(absolute)),
                         last: stored.last.map(absolute),
                         mode: stored.mode.flatMap(ViewMode.init(rawValue:)))
        }
        // The first builds wrote the viewed list alone.
        let paths = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return Entry(viewed: Set(paths.map(absolute)))
    }

    public func save(_ entry: Entry, folder: URL) {
        let prefix = Self.prefix(folder)
        func relative(_ key: String) -> String { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key }
        let stored = Stored(viewed: entry.viewed.map(relative).sorted(),
                            last: entry.last.map(relative),
                            mode: entry.mode?.rawValue)
        lock.lock()
        defer { lock.unlock() }
        AppPaths.ensureDirectory(directory)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file(for: folder), options: .atomic)
    }

    func file(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(Self.key(folder).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    private static func prefix(_ folder: URL) -> String { key(folder) + "/" }
}
