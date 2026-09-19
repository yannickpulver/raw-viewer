import CoreGraphics
import Foundation

/// Owns every decode task and every in-memory image. Spec 04 §7.
///
/// Concurrency budget: 1 current image, 6 nearby previews, 4 thumbnails, 1 full develop.
/// Everything is a cancellable `Task` keyed by (url, size); `size == 0` means "full preview".
@MainActor
@Observable
public final class PreloadScheduler {
    /// Single shared preview cache budget — a deliberate deviation from the Python app's
    /// 1.5 GB *per mode* (spec 01 §2 flags that as likely unintended).
    public static let previewCacheBudget = 1_500_000_000

    struct TaskKey: Hashable {
        let url: URL
        let size: Int
    }

    /// Nearby preview offsets, in the spec's exact priority order. Spec 04 §7.
    public static let nearbyOffsets = [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]

    // MARK: Observable outputs

    public private(set) var thumbs80: [URL: CGImage] = [:]
    public private(set) var thumbs200: [URL: CGImage] = [:]
    /// Bumped whenever a preview lands, so `preview(for:)` participates in observation.
    public private(set) var previewRevision: Int = 0
    public private(set) var loadedThumbCount: Int = 0
    public private(set) var failedThumbCount: Int = 0
    public private(set) var totalFileCount: Int = 0

    /// Called (on the main actor) with a rating read off disk while a thumbnail loaded.
    /// Spec 04 §7: this is how ratings get populated during normal browsing.
    public var onRatingDiscovered: ((URL, Int) -> Void)?

    // MARK: Internals

    private let previews = ByteLRUCache<URL, CGImage>(maxBytes: PreloadScheduler.previewCacheBudget)
    private let decoder = PreviewDecoder()
    private let diskCache: DiskThumbnailCache

    private var tasks: [TaskKey: Task<Void, Never>] = [:]
    /// Identity of the task currently stored under each key, so a completion handler only
    /// clears its own entry and never a newer task that reused the key.
    private var taskIDs: [TaskKey: Int] = [:]
    private var nextTaskID = 0
    private var currentKey: TaskKey?
    private var thumbAttempted: Set<URL> = []
    /// Keys whose decode already failed once — re-queuing them only burns the thumb gate.
    private var thumbFailed: Set<TaskKey> = []

    private let currentGate = AsyncSemaphore(value: 1)
    private let previewGate = AsyncSemaphore(value: 6)
    private let thumbGate = AsyncSemaphore(value: 4)
    private let developGate = AsyncSemaphore(value: 1)

    private var sweepTask: Task<Void, Never>?
    private var sweepStart: Int = 0

    public init(diskCache: DiskThumbnailCache = .shared) {
        self.diskCache = diskCache
    }

    // MARK: - Reads

    /// A *peek*: read from a SwiftUI `body`, so it must not mutate LRU recency. The recency
    /// refresh happens in `setCurrent(_:)`, which is the only read that means "in use now".
    public func preview(for url: URL) -> CGImage? {
        _ = previewRevision
        return previews.peek(url)
    }

    public func hasPreview(_ url: URL) -> Bool {
        previews.contains(url)
    }

    public func thumb80(for url: URL) -> CGImage? { thumbs80[url] }
    public func thumb200(for url: URL) -> CGImage? { thumbs200[url] }

    /// "Loading: N%" fraction. Failed thumbnails count as loaded so it can reach 100 %.
    public var progressFraction: Double {
        guard totalFileCount > 0 else { return 1 }
        return min(1, Double(loadedThumbCount + failedThumbCount) / Double(totalFileCount))
    }

    // MARK: - Task bookkeeping

    private func newTaskID() -> Int {
        nextTaskID &+= 1
        return nextTaskID
    }

    private func store(task: Task<Void, Never>, key: TaskKey, id: Int) {
        tasks[key] = task
        taskIDs[key] = id
    }

    /// Clears the slot only when it still holds *this* task. Spec 04 §7.
    private func clearTask(_ key: TaskKey, id: Int) {
        guard taskIDs[key] == id else { return }
        taskIDs[key] = nil
        tasks[key] = nil
    }

    private func cancelTask(_ key: TaskKey) {
        tasks[key]?.cancel()
        tasks[key] = nil
        taskIDs[key] = nil
    }

    // MARK: - Lifecycle

    /// Called when a new list becomes active (folder load, mode switch, filter change).
    public func reset(totalFileCount: Int) {
        cancelAll()
        self.totalFileCount = totalFileCount
        loadedThumbCount = 0
        failedThumbCount = 0
        thumbAttempted.removeAll()
        thumbFailed.removeAll()
        thumbs80.removeAll()
        thumbs200.removeAll()
    }

    /// Everything cancels on folder close.
    public func closeFolder() {
        cancelAll()
        previews.clear()
        previewRevision &+= 1
        thumbs80.removeAll()
        thumbs200.removeAll()
        thumbAttempted.removeAll()
        thumbFailed.removeAll()
        totalFileCount = 0
        loadedThumbCount = 0
        failedThumbCount = 0
    }

    public func cancelAll() {
        stopBackgroundSweep()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        taskIDs.removeAll()
        currentKey = nil
    }

    // MARK: - Current image

    /// Highest priority load for the image on screen. The 80 px thumbnail, if cached, is the
    /// instant placeholder the UI should draw until the preview lands. Spec 04 §7.
    public func setCurrent(_ file: MediaFile?) {
        guard let file, file.kind != .video else {
            // Clearing the current key matters: `preloadNearby` keeps whatever `currentKey`
            // points at alive, so a stale key would pin a preview that is no longer on screen.
            currentKey = nil
            return
        }

        let key = TaskKey(url: file.url, size: 0)
        currentKey = key

        guard !previews.contains(file.url) else {
            // Cache hit: this is the "in use now" read, so refresh LRU recency here.
            previews.touchKey(file.url)
            return
        }
        guard tasks[key] == nil else { return }

        // Instant placeholder: schedule the 80 px thumb if we do not have it yet.
        if thumbs80[file.url] == nil {
            loadThumbnail(file, size: PreviewDecoder.filmstripThumbnailSize)
        }
        schedulePreview(file, gate: currentGate, key: key)
    }

    // MARK: - Nearby previews

    /// Preloads ±6 around `index` in the spec's exact offset order. Skipped in video mode.
    public func preloadNearby(index: Int, in files: [MediaFile]) {
        guard let kind = files.first?.kind, kind != .video else { return }
        var wanted: Set<URL> = []
        if index >= 0 && index < files.count { wanted.insert(files[index].url) }
        for offset in Self.nearbyOffsets {
            let target = index + offset
            guard target >= 0, target < files.count else { continue }
            wanted.insert(files[target].url)
        }
        // Navigating away cancels queued previews that left the window; the current one stays.
        for key in tasks.keys where key.size == 0 {
            if key != currentKey && !wanted.contains(key.url) {
                cancelTask(key)
            }
        }
        for offset in Self.nearbyOffsets {
            let target = index + offset
            guard target >= 0, target < files.count else { continue }
            let file = files[target]
            guard !previews.contains(file.url) else { continue }
            let key = TaskKey(url: file.url, size: 0)
            guard tasks[key] == nil else { continue }
            schedulePreview(file, gate: previewGate, key: key)
        }
    }

    private func schedulePreview(_ file: MediaFile, gate: AsyncSemaphore, key: TaskKey) {
        let decoder = self.decoder
        let id = newTaskID()
        let task = Task { [weak self] in
            let image: CGImage? = await gate.withPermit {
                guard !Task.isCancelled else { return nil }
                return decoder.preview(url: file.url, kind: file.kind)
            }
            guard let self, !Task.isCancelled else { return }
            self.clearTask(key, id: id)
            guard let image else { return }
            self.store(preview: image, for: file.url)
            if file.kind == .raw, decoder.needsFullDevelop(image: image, url: file.url) {
                self.scheduleFullDevelop(file)
            }
        }
        store(task: task, key: key, id: id)
    }

    /// Low-priority full RAW develop, swapped in over a too-small embedded preview.
    private func scheduleFullDevelop(_ file: MediaFile) {
        let key = TaskKey(url: file.url, size: -1)
        guard tasks[key] == nil else { return }
        let decoder = self.decoder
        let gate = developGate
        let id = newTaskID()
        let task = Task(priority: .background) { [weak self] in
            let image: CGImage? = await gate.withPermit {
                guard !Task.isCancelled else { return nil }
                return decoder.fullDevelop(url: file.url)
            }
            guard let self, !Task.isCancelled else { return }
            self.clearTask(key, id: id)
            guard let image else { return }
            self.store(preview: image, for: file.url)
        }
        store(task: task, key: key, id: id)
    }

    private func store(preview image: CGImage, for url: URL) {
        previews.put(url, value: image, cost: image.width * image.height * 4)
        previewRevision &+= 1
        // Spec 04 §7: derive the filmstrip thumbnail from a landed preview when missing.
        if thumbs80[url] == nil,
           let derived = PreviewDecoder.downscale(image, maxPixelSize: PreviewDecoder.filmstripThumbnailSize) {
            thumbs80[url] = derived
            noteThumbLoaded(url)
        }
    }

    // MARK: - Thumbnails

    /// Filmstrip thumbnails: navigation uses ±10, a scroll uses the visible range ±5.
    public func preloadFilmstrip(range: Range<Int>, in files: [MediaFile]) {
        for index in range where index >= 0 && index < files.count {
            loadThumbnail(files[index], size: PreviewDecoder.filmstripThumbnailSize)
        }
    }

    /// Grid: load visible ±10, evict grid thumbnails more than 100 indices outside that range.
    public func gridVisibleRange(_ range: Range<Int>, in files: [MediaFile]) {
        let first = max(0, range.lowerBound - 10)
        let last = min(files.count, range.upperBound + 10)
        guard first < last else { return }
        for index in first..<last {
            loadThumbnail(files[index], size: PreviewDecoder.gridThumbnailSize)
        }
        let keepFirst = max(0, first - 100)
        let keepLast = min(files.count, last + 100)
        let keep = Set(files[keepFirst..<keepLast].map(\.url))
        // One rebuild rather than a mutation per evicted key: `thumbs200` is `@Observable`, so
        // per-key removal churns both the dictionary's storage and every observer.
        if thumbs200.contains(where: { !keep.contains($0.key) }) {
            thumbs200 = thumbs200.filter { keep.contains($0.key) }
        }
    }

    private func loadThumbnail(_ file: MediaFile, size: Int) {
        if size == PreviewDecoder.filmstripThumbnailSize, thumbs80[file.url] != nil { return }
        if size == PreviewDecoder.gridThumbnailSize, thumbs200[file.url] != nil { return }
        let key = TaskKey(url: file.url, size: size)
        guard tasks[key] == nil else { return }
        // A decode that already failed will fail again; re-queuing it only starves the gate.
        guard !thumbFailed.contains(key) else { return }

        let decoder = self.decoder
        let diskCache = self.diskCache
        let gate = thumbGate
        let wantsRating = size == PreviewDecoder.filmstripThumbnailSize
            || size == PreviewDecoder.gridThumbnailSize

        let id = newTaskID()
        let task = Task { [weak self] in
            let result: (image: CGImage?, rating: Int?) = await gate.withPermit {
                guard !Task.isCancelled else { return (nil, nil) }
                var image = diskCache.get(file.url, size: size)
                if image == nil {
                    image = decoder.thumbnail(url: file.url, kind: file.kind, maxPixelSize: size)
                    if let image { diskCache.set(image, for: file.url, size: size) }
                }
                let rating = wantsRating ? (XMPSidecar.read(file.url) ?? 0) : nil
                return (image, rating)
            }
            guard let self, !Task.isCancelled else { return }
            self.clearTask(key, id: id)
            if let rating = result.rating { self.onRatingDiscovered?(file.url, rating) }
            if let image = result.image {
                if size == PreviewDecoder.gridThumbnailSize {
                    self.thumbs200[file.url] = image
                } else {
                    self.thumbs80[file.url] = image
                }
                if size == PreviewDecoder.filmstripThumbnailSize { self.noteThumbLoaded(file.url) }
            } else {
                self.thumbFailed.insert(key)
                if size == PreviewDecoder.filmstripThumbnailSize {
                    self.noteThumbFailed(file.url)
                }
            }
        }
        store(task: task, key: key, id: id)
    }

    private func noteThumbLoaded(_ url: URL) {
        guard thumbAttempted.insert(url).inserted else { return }
        loadedThumbCount += 1
    }

    private func noteThumbFailed(_ url: URL) {
        guard thumbAttempted.insert(url).inserted else { return }
        failedThumbCount += 1
    }

    // MARK: - Background sweep

    /// Walks the whole list from `index`, 5 thumbnails per 100 ms, wrapping at the end and
    /// stopping when it reaches its starting point again. Spec 04 §7.
    public func startBackgroundSweep(from index: Int, in files: [MediaFile]) {
        stopBackgroundSweep()
        guard !files.isEmpty else { return }
        let start = min(max(0, index), files.count - 1)
        sweepStart = start
        sweepTask = Task { [weak self] in
            var cursor = start
            var wrapped = false
            while !Task.isCancelled {
                for _ in 0..<5 {
                    if wrapped && cursor >= start { return }
                    guard let self else { return }
                    self.loadThumbnail(files[cursor], size: PreviewDecoder.filmstripThumbnailSize)
                    cursor += 1
                    if cursor >= files.count {
                        cursor = 0
                        wrapped = true
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Test hook: has this (url, size) pair been memoised as a failure?
    func hasFailedThumbnail(_ url: URL, size: Int) -> Bool {
        thumbFailed.contains(TaskKey(url: url, size: size))
    }

    /// Test hook: number of live decode tasks.
    var liveTaskCount: Int { tasks.count }

    /// Test hook: the file `setCurrent(_:)` last pointed at.
    var currentPreviewURL: URL? { currentKey?.url }

    public func stopBackgroundSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }
}
