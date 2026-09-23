import CoreGraphics
import Foundation
import Observation

/// Face results for the open folder. While running it walks every still image of the active
/// mode, one at a time, decoding its own preview so the scheduler's cache is left alone.
/// The file on screen jumps the queue. Results persist through `FaceCache`.
@MainActor
@Observable
public final class FaceIndex {
    /// `nil` for a file not analysed yet, `[]` for one without faces.
    public private(set) var faces: [URL: [Face]] = [:]
    /// Files still queued in the current sweep.
    public private(set) var remaining = 0

    private let cache: FaceCache
    private let detector = FaceDetector()
    private let decoder = PreviewDecoder()

    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var entries: [String: FaceCache.Entry] = [:]
    @ObservationIgnored private var entriesLoaded = false
    @ObservationIgnored private var queue: [MediaFile] = []
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Bumped on every `start` / `stop`; a sweep only writes back while its generation is current.
    @ObservationIgnored private var generation = 0

    public init(cache: FaceCache = .shared) {
        self.cache = cache
    }

    public func faces(for url: URL) -> [Face]? { faces[url] }

    /// Starts (or restarts, after a mode switch) the sweep over `files`. Results for a folder
    /// stay in memory until another folder starts or `stop()` runs.
    public func start(folder: URL, files: [MediaFile], current: MediaFile?) {
        if folder != self.folder {
            stop()
            self.folder = folder
        }
        sweepTask?.cancel()
        generation &+= 1
        let generation = self.generation

        let candidates = files.filter { $0.kind != .video && faces[$0.url] == nil }
        let cache = self.cache
        let needsLoad = !entriesLoaded
        let known = entries
        sweepTask = Task { [weak self] in
            // Reading the cache and stat-ing every file stays off the main thread.
            let (stored, hits, misses) = await Task.detached(priority: .utility) {
                let stored = needsLoad ? cache.load(folder: folder) : known
                var hits: [URL: [Face]] = [:]
                var misses: [MediaFile] = []
                for file in candidates {
                    if let entry = stored[file.url.path], entry.mtime == FaceCache.mtime(of: file.url) {
                        hits[file.url] = entry.faces
                    } else {
                        misses.append(file)
                    }
                }
                return (stored, hits, misses)
            }.value
            guard let self, generation == self.generation else { return }
            if needsLoad {
                self.entries = stored
                self.entriesLoaded = true
            }
            self.faces.merge(hits) { _, new in new }
            self.queue = misses
            self.prioritise(current)
            await self.drain(generation: generation)
        }
    }

    /// Moves `file` to the front of the queue, so the image on screen is analysed next.
    public func prioritise(_ file: MediaFile?) {
        guard let file, let position = queue.firstIndex(of: file), position > 0 else { return }
        queue.remove(at: position)
        queue.insert(file, at: 0)
    }

    /// Cancels the sweep, writes what it found and forgets the folder.
    public func stop() {
        sweepTask?.cancel()
        sweepTask = nil
        generation &+= 1
        if let folder, entriesLoaded { save(folder: folder) }
        folder = nil
        entries = [:]
        entriesLoaded = false
        queue = []
        remaining = 0
        faces = [:]
    }

    /// Test hook: waits for the running sweep to finish.
    func waitForSweep() async {
        await sweepTask?.value
    }

    private func drain(generation: Int) async {
        remaining = queue.count
        let detector = self.detector
        let decoder = self.decoder
        while generation == self.generation, !Task.isCancelled, !queue.isEmpty {
            let file = queue.removeFirst()
            let (found, mtime) = await Task.detached(priority: .utility) { () -> ([Face], Double?) in
                let mtime = FaceCache.mtime(of: file.url)
                guard let image = decoder.preview(url: file.url, kind: file.kind) else { return ([], mtime) }
                return (detector.detect(in: image), mtime)
            }.value
            guard generation == self.generation else { return }
            faces[file.url] = found
            if let mtime { entries[file.url.path] = FaceCache.Entry(mtime: mtime, faces: found) }
            remaining = queue.count
            scheduleSave()
        }
        if generation == self.generation, let folder { save(folder: folder) }
    }

    /// At most one write every 5 s while the sweep runs.
    private func scheduleSave() {
        guard saveTask == nil, let folder else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            self.saveTask = nil
            self.save(folder: folder)
        }
    }

    private func save(folder: URL) {
        saveTask?.cancel()
        saveTask = nil
        let entries = self.entries
        let cache = self.cache
        Task.detached(priority: .utility) { cache.save(entries, folder: folder) }
    }
}
