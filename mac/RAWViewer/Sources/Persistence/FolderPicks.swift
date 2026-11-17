import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A few small pictures of a folder's best photos, for its card on the launch screen. They are
/// copies, not cache lookups: the thumbnail cache checks the original file, and the card must
/// still show its photos while the folder's drive is unplugged.
public final class FolderPicks: @unchecked Sendable {
    public static let shared = FolderPicks()
    public static let count = 3

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.picksDirectory) {
        self.directory = directory
    }

    /// Highest stars first, ties in folder order. Too few rated: the first unrated photos fill
    /// up. Videos and rejected photos never show.
    static func choose(_ files: [MediaFile], rating: (URL) -> Int, count: Int = FolderPicks.count) -> [MediaFile] {
        let photos = files.filter { $0.kind != .video }
        let stars: [Int] = photos.map { rating($0.url) }
        let rated: [Int] = photos.indices
            .filter { stars[$0] > 0 }
            .sorted { stars[$0] != stars[$1] ? stars[$0] > stars[$1] : $0 < $1 }
        var picks: [MediaFile] = rated.prefix(count).map { photos[$0] }
        if picks.count < count {
            let unrated: [MediaFile] = photos.indices.filter { stars[$0] == 0 }.map { photos[$0] }
            picks.append(contentsOf: unrated.prefix(count - picks.count))
        }
        return picks
    }

    /// Replaces the folder's pictures. An empty list keeps the old ones.
    public func save(_ images: [CGImage], for folder: URL) {
        guard !images.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        AppPaths.ensureDirectory(directory)
        let key = Self.key(folder)
        for index in 0..<Self.count {
            try? FileManager.default.removeItem(at: file(key, index))
        }
        for (index, image) in images.prefix(Self.count).enumerated() {
            guard let sink = CGImageDestinationCreateWithURL(
                file(key, index) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(sink)
        }
    }

    public func load(folder: URL) -> [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(folder)
        return (0..<Self.count).compactMap { index in
            guard let source = CGImageSourceCreateWithURL(file(key, index) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    public func remove(folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(folder)
        for index in 0..<Self.count {
            try? FileManager.default.removeItem(at: file(key, index))
        }
    }

    private func file(_ key: String, _ index: Int) -> URL {
        directory.appendingPathComponent("\(key)-\(index).jpg")
    }

    static func key(_ folder: URL) -> String {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
