import AVFoundation
import Foundation
import ImageIO

/// Result of one recursive scan: the three sorted lists. Spec 03 §3.
public struct ScanResult: Sendable {
    public var raw: [MediaFile] = []
    public var jpeg: [MediaFile] = []
    public var video: [MediaFile] = []

    public var isEmpty: Bool { raw.isEmpty && jpeg.isEmpty && video.isEmpty }

    public func files(for kind: MediaKind) -> [MediaFile] {
        switch kind {
        case .raw: return raw
        case .jpeg: return jpeg
        case .video: return video
        }
    }
}

/// Single recursive walk producing all three lists. Spec 03 §2–§5.
public struct FolderScanner: Sendable {
    public enum ScanError: Error, LocalizedError {
        case notADirectory(URL)
        public var errorDescription: String? {
            switch self {
            case .notADirectory(let url): return "Not a directory: \(url.path)"
            }
        }
    }

    /// Bounded parallelism for capture-date extraction.
    static let dateConcurrency = 8

    public init() {}

    /// Walks `root` once, computes capture dates, sorts each list by `(date, path)`.
    /// `progress` is called on every 5th file and on the last one, with a 0...1 fraction.
    public func scan(root: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ScanResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.notADirectory(root)
        }

        let candidates = Self.walk(root: root)
        guard !candidates.isEmpty else { return ScanResult() }

        let cache = DateCache()
        let total = candidates.count

        // Capture-date extraction is the expensive part (a RAF costs ~150 ms of ImageIO
        // property parsing), so it runs `Self.dateConcurrency` files at a time. Results are
        // written back by index, which keeps the input order — and therefore the sort — exactly
        // as deterministic as the sequential version was.
        var dates = [Date?](repeating: nil, count: total)
        var completed = 0
        var next = 0

        try await withThrowingTaskGroup(of: (Int, Date).self) { group in
            let initial = min(Self.dateConcurrency, total)
            while next < initial {
                let offset = next
                let candidate = candidates[offset]
                group.addTask {
                    try Task.checkCancellation()
                    return (offset, await Self.captureDate(for: candidate.url,
                                                           kind: candidate.kind, cache: cache))
                }
                next += 1
            }
            while let (offset, date) = try await group.next() {
                dates[offset] = date
                completed += 1
                if completed % 5 == 0 || completed == total {
                    progress?(Double(completed) / Double(total))
                }
                try Task.checkCancellation()
                if next < total {
                    let queued = next
                    let candidate = candidates[queued]
                    group.addTask {
                        try Task.checkCancellation()
                        return (queued, await Self.captureDate(for: candidate.url,
                                                               kind: candidate.kind, cache: cache))
                    }
                    next += 1
                }
            }
        }

        var raw: [MediaFile] = []
        var jpeg: [MediaFile] = []
        var video: [MediaFile] = []
        for (offset, candidate) in candidates.enumerated() {
            let file = MediaFile(url: candidate.url,
                                 kind: candidate.kind,
                                 captureDate: dates[offset] ?? Date(timeIntervalSince1970: 0),
                                 subfolder: Self.subfolderName(for: candidate.url, root: root))
            switch candidate.kind {
            case .raw: raw.append(file)
            case .jpeg: jpeg.append(file)
            case .video: video.append(file)
            }
        }
        cache.save()

        return ScanResult(raw: Self.sorted(raw), jpeg: Self.sorted(jpeg), video: Self.sorted(video))
    }

    /// Spec 03 §4: ascending by capture timestamp, tie-broken by path string.
    static func sorted(_ files: [MediaFile]) -> [MediaFile] {
        files.sorted {
            if $0.captureDate != $1.captureDate { return $0.captureDate < $1.captureDate }
            return $0.url.path < $1.url.path
        }
    }

    struct Candidate: Sendable {
        let url: URL
        let kind: MediaKind
    }

    /// One recursive walk: skips `._*`, prunes `_rejected` at any depth, does not follow symlinks.
    static func walk(root: URL) -> [Candidate] {
        let fm = FileManager.default
        var results: [Candidate] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if url.lastPathComponent == MoveRejected.directoryName {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let kind = MediaKind.of(url) else { continue }
            results.append(Candidate(url: url, kind: kind))
        }
        return results
    }

    // MARK: - Capture date

    static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Spec 03 §5: EXIF `DateTimeOriginal`, then birthtime, then mtime.
    static func captureDate(for url: URL, kind: MediaKind, cache: DateCache?) async -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let mtime = modified.timeIntervalSince1970

        if let cached = cache?.date(forPath: url.path, mtime: mtime) { return cached }

        var result: Date?
        if kind == .video {
            result = await videoCreationDate(url)
        } else {
            result = exifDate(url)
        }
        if result == nil {
            result = (attributes?[.creationDate] as? Date) ?? modified
        }
        let date = result ?? modified
        cache?.store(path: url.path, mtime: mtime, date: date)
        return date
    }

    /// EXIF `DateTimeOriginal` via ImageIO, parsed in the local time zone. Spec 03 §5.
    static func exifDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let date = exifFormatter.date(from: value) { return date }
            if let value = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
               let date = exifFormatter.date(from: value) { return date }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifFormatter.date(from: value) { return date }
        return nil
    }

    static func videoCreationDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    // MARK: - Subfolders

    /// Spec 03 §7: the first path component of the file's parent relative to the root, or the
    /// root's own basename when the file sits directly in the root, or the parent's basename
    /// when the file is not under the root at all.
    public static func subfolderName(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        if parent == rootPath {
            return root.standardizedFileURL.lastPathComponent
        }
        guard parent.hasPrefix(rootPath + "/") else {
            return url.standardizedFileURL.deletingLastPathComponent().lastPathComponent
        }
        let relative = String(parent.dropFirst(rootPath.count + 1))
        return relative.split(separator: "/").first.map(String.init)
            ?? root.standardizedFileURL.lastPathComponent
    }

    /// `[(name, count)]` sorted by name. Spec 03 §7.
    public static func subfolderCounts(_ urls: [URL], root: URL) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for url in urls { counts[subfolderName(for: url, root: root), default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
    }
}
