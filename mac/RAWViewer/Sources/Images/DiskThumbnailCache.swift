import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEG-on-disk thumbnail cache. Spec 04 §9, with the tech debt fixed: one file per entry,
/// the source mtime encoded in the filename, atomic writes, and a size cap.
public final class DiskThumbnailCache: @unchecked Sendable {
    public static let shared = DiskThumbnailCache()

    /// Sweep trigger and target. Spec brief: over 2 GB, trim to 1.5 GB.
    public static let highWatermark = 2_000_000_000
    public static let lowWatermark = 1_500_000_000

    public let directory: URL
    private let quality: Double = 0.85

    public init(directory: URL = AppPaths.thumbnailCacheDirectory) {
        self.directory = directory
        AppPaths.ensureDirectory(directory)
    }

    static func key(path: String, size: Int) -> String {
        let digest = SHA256.hash(data: Data("\(path):\(size)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func filename(for url: URL, size: Int, mtime: Double) -> String {
        // The mtime lives in the filename, so a changed source simply misses the cache.
        "\(Self.key(path: url.path, size: size))-\(Int(mtime.rounded())).jpg"
    }

    private func mtime(of url: URL) -> Double? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }

    public func get(_ url: URL, size: Int) -> CGImage? {
        guard let mtime = mtime(of: url) else { return nil }
        let file = directory.appendingPathComponent(filename(for: url, size: size, mtime: mtime))
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        // Refresh access time so the size sweep evicts genuinely cold entries.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    @discardableResult
    public func set(_ image: CGImage, for url: URL, size: Int) -> Bool {
        guard let mtime = mtime(of: url) else { return false }
        // Drop any entry for the same (path, size) at a different mtime: it can never be hit
        // again, so leaving it behind is pure cache bloat.
        invalidate(url, size: size)
        let destination = directory.appendingPathComponent(filename(for: url, size: size, mtime: mtime))
        let temporary = directory.appendingPathComponent("tmp-\(UUID().uuidString).jpg")

        guard let sink = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(sink, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    public func invalidate(_ url: URL, size: Int) {
        let prefix = Self.key(path: url.path, size: size)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// Trims the directory to `lowWatermark` when it exceeds `highWatermark`, oldest first.
    public func enforceSizeCap() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        var total = 0
        var items: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            total += size
            items.append((entry, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > Self.highWatermark else { return }

        items.sort { $0.date < $1.date }
        for item in items {
            guard total > Self.lowWatermark else { break }
            if (try? fm.removeItem(at: item.url)) != nil { total -= item.size }
        }
    }
}
