import CryptoKit
import Foundation

/// Face results on disk: one JSON file per folder, keyed by absolute file path, each entry
/// stamped with the source mtime so an edited file is analysed again. The file name carries
/// `FaceDetector.version`, so a new detector starts from scratch. Every error is swallowed;
/// a missing or corrupt file just means "analyse again".
public final class FaceCache: @unchecked Sendable {
    public static let shared = FaceCache()

    public struct Entry: Codable, Equatable, Sendable {
        public var mtime: Double
        public var faces: [Face]
    }

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.faceCacheDirectory) {
        self.directory = directory
    }

    public func load(folder: URL) -> [String: Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(for: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    public func save(_ entries: [String: Entry], folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        AppPaths.ensureDirectory(directory)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file(for: folder), options: .atomic)
    }

    func file(for folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name)-v\(FaceDetector.version).json")
    }

    static func mtime(of url: URL) -> Double? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }
}
