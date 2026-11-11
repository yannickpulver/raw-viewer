import Foundation

/// JSON date cache keyed by absolute path: `{path: [mtime, captureTimestamp, exposureTime,
/// exposureBias]}`, an exposure time of 0 meaning "no exposure". Spec 03 §6, with the
/// unbounded-growth tech debt fixed by pruning vanished files on save. Entries from before the
/// exposure (two values) count as missing, so each file is read once more.
final class DateCache: @unchecked Sendable {
    private struct Entry {
        var mtime: Double
        var timestamp: Double
        var exposure: Exposure?
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
        for (path, values) in raw where values.count == 4 {
            entries[path] = Entry(mtime: values[0], timestamp: values[1],
                                  exposure: values[2] > 0 ? Exposure(time: values[2], bias: values[3]) : nil)
        }
    }

    /// Cached capture date and exposure, valid only while the source mtime is unchanged.
    func info(forPath path: String, mtime: Double) -> (date: Date, exposure: Exposure?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.mtime == mtime else { return nil }
        return (Date(timeIntervalSince1970: entry.timestamp), entry.exposure)
    }

    /// Safe to call concurrently: the scanner computes capture dates in parallel.
    func store(path: String, mtime: Double, date: Date, exposure: Exposure?) {
        lock.lock()
        entries[path] = Entry(mtime: mtime, timestamp: date.timeIntervalSince1970, exposure: exposure)
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
        for (path, entry) in entries {
            raw[path] = [entry.mtime, entry.timestamp, entry.exposure?.time ?? 0, entry.exposure?.bias ?? 0]
        }
        lock.unlock()
        AppPaths.ensureDirectory(file.deletingLastPathComponent())
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
