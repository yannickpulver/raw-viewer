import Foundation

/// JSON date cache keyed by absolute path: `{path: [mtime, captureTimestamp]}`.
/// Spec 03 §6, with the unbounded-growth tech debt fixed by pruning vanished files on save.
final class DateCache: @unchecked Sendable {
    private struct Entry {
        var mtime: Double
        var timestamp: Double
    }

    private let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var dirty = false

    /// Above this many entries, a save also drops entries whose file no longer exists.
    private static let pruneThreshold = 20_000

    init(file: URL = AppPaths.dateCacheFile) {
        self.file = file
        load()
    }

    private func load() {
        // Called from `init` before the cache is shared; no lock needed.
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        for (path, pair) in raw where pair.count == 2 {
            entries[path] = Entry(mtime: pair[0], timestamp: pair[1])
        }
    }

    /// Cached capture date, valid only while the source mtime is unchanged.
    func date(forPath path: String, mtime: Double) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.mtime == mtime else { return nil }
        return Date(timeIntervalSince1970: entry.timestamp)
    }

    /// Safe to call concurrently: the scanner computes capture dates in parallel.
    func store(path: String, mtime: Double, date: Date) {
        lock.lock()
        entries[path] = Entry(mtime: mtime, timestamp: date.timeIntervalSince1970)
        dirty = true
        lock.unlock()
    }

    func save() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        dirty = false
        if entries.count > Self.pruneThreshold {
            entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        var raw: [String: [Double]] = [:]
        raw.reserveCapacity(entries.count)
        for (path, entry) in entries { raw[path] = [entry.mtime, entry.timestamp] }
        lock.unlock()
        AppPaths.ensureDirectory(file.deletingLastPathComponent())
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
