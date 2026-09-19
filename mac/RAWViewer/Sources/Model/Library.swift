import Foundation
import Observation

/// A transient message for the bottom-centre snackbar. Spec 01 §4.
public struct SnackbarEvent: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let durationMs: Int

    public init(text: String, durationMs: Int = 2000) {
        self.text = text
        self.durationMs = durationMs
    }
}

/// An available GitHub release. Spec 01 §20.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// The single source of truth the UI binds to.
@MainActor
@Observable
public final class Library {

    // MARK: - State

    public private(set) var folder: URL?
    public private(set) var viewMode: MediaKind = .raw
    public private(set) var displayMode: DisplayMode = .single
    public private(set) var modeStates: [MediaKind: ModeState] = [
        .raw: ModeState(), .jpeg: ModeState(), .video: ModeState(),
    ]
    /// Shared across all three modes and keyed by URL (deliberate deviation from spec 03 §9,
    /// where ratings were keyed by index into the per-mode unfiltered list).
    public private(set) var ratings: [URL: Int] = [:]
    /// Bumped on every ratings mutation so views that draw rating badges repaint even when
    /// neither the selection nor `ratings.count` changes (re-rating the same file).
    public private(set) var ratingsRevision: Int = 0

    public private(set) var pinnedFile: MediaFile?
    public var focusedPane: ComparePane = .right
    public var showInfo: Bool { didSet { preferences.showInfo = showInfo } }
    public var filmstripVisible: Bool { didSet { preferences.filmstripVisible = filmstripVisible } }

    public private(set) var isScanning = false
    public private(set) var scanProgressText: String?
    public private(set) var snackbar: SnackbarEvent?
    public var resolveStatus: String?
    public var updateAvailable: UpdateInfo?
    /// Guard for spec 06 §6: a second export is refused while one runs.
    public private(set) var isExportingToResolve = false

    /// Column count of the grid, set by the UI on layout so `gridMove` can use `GridLayout`.
    public var gridColumns: Int = 1

    public let scheduler: PreloadScheduler

    // MARK: - Dependencies

    private let scanner = FolderScanner()
    private let ratingWriter = RatingWriter()
    private let recents: RecentFolders
    private let preferences: Preferences
    private let summaryStore: FolderSummaryStore

    private var scanTask: Task<Void, Never>?
    /// Bumped on every `openFolder` / `closeFolder`; a scan task only mutates state while its
    /// own generation is still current, so a superseded scan can never write back.
    private var scanGeneration = 0
    private var writeChain: Task<Void, Never>?
    private var ratingsFullyLoaded = false
    private var pendingMoveSet: [URL] = []

    /// Read from `body` on the empty state, so it must not participate in observation.
    @ObservationIgnored private var summaryCache: [String: FolderSummary]?
    @ObservationIgnored private var summarySaveTask: Task<Void, Never>?

    // MARK: - Shoot timer (spec 05 §11)

    private var shootPersistedElapsed: Double = 0
    private var shootSessionStart: Date?
    private var shootRatedCount: Int = 0
    private var shootLastRatingElapsed: Double?

    /// The whole shoot timer as one value, so `openFolder` can put it back when the scan of the
    /// new folder turns out to be empty (spec 01 §10: nothing changes).
    struct ShootTimerState {
        var persistedElapsed: Double
        var sessionStart: Date?
        var ratedCount: Int
        var lastRatingElapsed: Double?
    }

    var shootTimerState: ShootTimerState {
        get {
            ShootTimerState(persistedElapsed: shootPersistedElapsed,
                            sessionStart: shootSessionStart,
                            ratedCount: shootRatedCount,
                            lastRatingElapsed: shootLastRatingElapsed)
        }
        set {
            shootPersistedElapsed = newValue.persistedElapsed
            shootSessionStart = newValue.sessionStart
            shootRatedCount = newValue.ratedCount
            shootLastRatingElapsed = newValue.lastRatingElapsed
        }
    }

    public init(preferences: Preferences = .shared,
                recents: RecentFolders = .shared,
                scheduler: PreloadScheduler? = nil,
                summaryStore: FolderSummaryStore = .shared) {
        self.preferences = preferences
        self.recents = recents
        self.summaryStore = summaryStore
        self.scheduler = scheduler ?? PreloadScheduler()
        self.showInfo = preferences.showInfo
        self.filmstripVisible = preferences.filmstripVisible
        recents.importLegacyIfNeeded(preferences: preferences)
        self.scheduler.onRatingDiscovered = { [weak self] url, rating in
            guard let self, self.ratings[url] == nil else { return }
            self.ratings[url] = rating
            self.ratingsRevision &+= 1
        }
    }

    // MARK: - Derived accessors

    public var state: ModeState {
        get { modeStates[viewMode] ?? ModeState() }
        set { modeStates[viewMode] = newValue }
    }

    public var files: [MediaFile] { state.files }
    public var allFiles: [MediaFile] { state.allFiles }
    public var index: Int { state.index }
    public var currentFile: MediaFile? { state.currentFile }
    public var ratingFilter: RatingFilter { state.ratingFilter }
    public var folderFilter: String? { state.folderFilter }
    public var excludedFolders: Set<String> { state.excludedFolders }
    public var isEmpty: Bool { files.isEmpty }
    /// True while a folder with at least one file in any mode is open, even if the active filter hides everything.
    public var hasLoadedFolder: Bool { modeStates.values.contains { !$0.allFiles.isEmpty } }
    public var isCompareActive: Bool { pinnedFile != nil }
    public var recentFolders: [URL] { recents.load() }

    /// `0` when absent, matching spec 05 §1 (no sidecar and rating 0 are indistinguishable).
    public func rating(for url: URL) -> Int { ratings[url] ?? 0 }
    public var currentRating: Int { currentFile.map { rating(for: $0.url) } ?? 0 }

    // MARK: - Opening and closing

    public func openFolder(_ url: URL) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        // The previous folder's shoot stats are persisted under the *previous* folder key and
        // the timer is reset immediately, so a quit mid-scan can never attribute them to `url`.
        let previousTimer = shootTimerState
        persistShootStats()
        resetShootTimer()

        // Spec 01 §10: an empty result changes nothing, so the previous folder (and its
        // `modeStates`, scheduler contents and shoot timer) has to survive until we know.
        let previousFolder = folder
        folder = url
        isScanning = true
        scanProgressText = "Scanning folder..."

        scanTask = Task { [weak self] in
            guard let self else { return }
            let scanner = self.scanner
            let result: ScanResult
            do {
                result = try await scanner.scan(root: url) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.scanGeneration else { return }
                        self.scanProgressText = "Sorting by date... \(Int(fraction * 100))%"
                    }
                }
            } catch {
                guard generation == self.scanGeneration else { return }
                self.isScanning = false
                self.scanProgressText = nil
                self.folder = previousFolder
                self.shootTimerState = previousTimer
                return
            }
            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            self.finishScan(result, folder: url,
                            previousFolder: previousFolder, previousTimer: previousTimer)
        }
    }

    private func finishScan(_ result: ScanResult, folder url: URL,
                           previousFolder: URL?, previousTimer: ShootTimerState) {
        isScanning = false
        scanProgressText = nil

        guard !result.isEmpty else {
            // Spec 01 §10: nothing changes and the folder is not added to recents. The previous
            // folder, its lists, its loaded images and its shoot timer all stay exactly as they
            // were — the teardown below only runs once we know the scan found something.
            folder = previousFolder
            shootTimerState = previousTimer
            return
        }

        scheduler.closeFolder()
        recents.add(url)
        ratings.removeAll()
        ratingsRevision &+= 1
        ratingsFullyLoaded = false
        pinnedFile = nil
        focusedPane = .right

        var states: [MediaKind: ModeState] = [:]
        for kind in MediaKind.allCases {
            var modeState = ModeState()
            modeState.allFiles = result.files(for: kind)
            modeState.applyFilters(ratings: ratings)
            states[kind] = modeState
        }
        modeStates = states
        viewMode = .raw

        // Spec 01 §10: with no RAW, switch to whichever of JPEG/video has more files, JPEG wins ties.
        if result.raw.isEmpty {
            if !result.jpeg.isEmpty || !result.video.isEmpty {
                viewMode = result.video.count > result.jpeg.count ? .video : .jpeg
            }
        }

        startShootTimer(for: url)
        scheduler.reset(totalFileCount: files.count)
        refreshPreloading()
        restartBackgroundSweep()

        // Deliberate addition (see README): sweep every rating in the background right after a
        // scan so the cached dashboard histogram is complete, not just the files that were
        // rated in this session.
        let generation = scanGeneration
        Task { [weak self] in
            await self?.loadAllRatings()
            guard let self, generation == self.scanGeneration else { return }
            self.saveFolderSummary()
        }
    }

    public func closeFolder() {
        guard modeStates.values.contains(where: { !$0.allFiles.isEmpty }) else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        persistShootStats()   // shoot timer + dashboard summary
        resetShootTimer()
        scheduler.closeFolder()
        pinnedFile = nil
        focusedPane = .right
        modeStates = [.raw: ModeState(), .jpeg: ModeState(), .video: ModeState()]
        ratings.removeAll()
        ratingsRevision &+= 1
        ratingsFullyLoaded = false
        folder = nil
        viewMode = .raw
        displayMode = .single
        isScanning = false
        scanProgressText = nil
    }

    // MARK: - Navigation

    public func navigate(by delta: Int) {
        guard !files.isEmpty else { return }
        let target = state.index + delta
        guard target >= 0, target < files.count else { return }
        select(index: target)
    }

    public func jumpToFirst() {
        guard !files.isEmpty else { return }
        select(index: 0)
    }

    public func jumpToLast() {
        guard !files.isEmpty else { return }
        select(index: files.count - 1)
    }

    /// Spec 01 §17: loads every rating from disk, then jumps to the last file rated above 0.
    public func jumpToLastRated() async {
        await loadAllRatings()
        guard let target = files.lastIndex(where: { rating(for: $0.url) > 0 }) else { return }
        select(index: target)
    }

    public func select(index newIndex: Int) {
        guard newIndex >= 0, newIndex < files.count else { return }
        state.index = newIndex
        refreshPreloading()
        // Spec 04 §7: the background thumbnail sweep restarts from the new position.
        restartBackgroundSweep()
    }

    /// Grid arrow navigation. Horizontal moves clamp; vertical uses `GridLayout`. Spec 02 §2.
    public func gridMove(dx: Int, dy: Int) {
        guard !files.isEmpty else { return }
        var target = state.index
        if dx != 0 {
            target = min(files.count - 1, max(0, target + dx))
        }
        if dy != 0 {
            target = GridLayout.moveVertical(index: target,
                                             columns: max(1, gridColumns),
                                             total: files.count,
                                             deltaRows: dy)
        }
        guard target != state.index else { return }
        state.index = target
        // Spec 02 §2: grid arrow navigation deliberately does not preload previews.
    }

    private func refreshPreloading() {
        guard !files.isEmpty else { return }
        scheduler.setCurrent(currentFile)
        scheduler.preloadNearby(index: state.index, in: files)
        let first = max(0, state.index - 10)
        let last = min(files.count, state.index + 11)
        scheduler.preloadFilmstrip(range: first..<last, in: files)
    }

    /// Called by the filmstrip when it scrolls: visible range ±5. Spec 04 §7.
    public func filmstripVisibleRange(_ range: Range<Int>) {
        let first = max(0, range.lowerBound - 5)
        let last = min(files.count, range.upperBound + 5)
        guard first < last else { return }
        scheduler.preloadFilmstrip(range: first..<last, in: files)
    }

    public func gridVisibleRange(_ range: Range<Int>) {
        scheduler.gridVisibleRange(range, in: files)
    }

    public func restartBackgroundSweep() {
        scheduler.startBackgroundSweep(from: state.index, in: files)
    }

    // MARK: - Rating

    /// Spec 01 §14. Auto-advances unless already on the last file, and never advances when the
    /// pinned compare pane is the one being rated.
    public func rate(_ value: Int) {
        let clamped = Rating.clamp(value)
        if isCompareActive, focusedPane == .left, let pinned = pinnedFile {
            apply(rating: clamped, to: pinned)
            return
        }
        guard let current = currentFile else { return }
        apply(rating: clamped, to: current)
        if state.index < files.count - 1 {
            select(index: state.index + 1)
        }
    }

    /// Spec 01 §14: `-1` if not already rejected, otherwise `0`.
    public func toggleReject() {
        let target: MediaFile?
        if isCompareActive, focusedPane == .left { target = pinnedFile } else { target = currentFile }
        guard let target else { return }
        rate(rating(for: target.url) == Rating.rejected ? 0 : Rating.rejected)
    }

    private func apply(rating value: Int, to file: MediaFile) {
        let previous = rating(for: file.url)
        ratings[file.url] = value
        ratingsRevision &+= 1
        updateShootStats(previous: previous, new: value)
        scheduleFolderSummarySave()
        enqueueWrite(url: file.url, rating: value, kind: file.kind)
    }

    private func enqueueWrite(url: URL, rating value: Int, kind: MediaKind) {
        let writer = ratingWriter
        let previous = writeChain
        let needsTag = kind == .jpeg || kind == .video
        writeChain = Task { [weak self] in
            await previous?.value
            let ok = await writer.write(url: url, rating: value, setGreenTag: needsTag)
            if !ok {
                self?.post(SnackbarEvent(text: "Failed to save rating for \(url.lastPathComponent)",
                                         durationMs: 4000))
            }
        }
    }

    /// Awaits every queued sidecar write. Used before move-rejected and on quit. Spec 05 §8.
    public func flushPendingWrites() async {
        await writeChain?.value
    }

    /// Whole-folder rating sweep, off the main thread, batched. Spec 05 §7.
    public func loadAllRatings() async {
        guard !ratingsFullyLoaded else { return }
        let urls = MediaKind.allCases.flatMap { modeStates[$0]?.allFiles.map(\.url) ?? [] }
        guard !urls.isEmpty else {
            ratingsFullyLoaded = true
            return
        }
        let writer = ratingWriter
        for batch in stride(from: 0, to: urls.count, by: 200) {
            let slice = Array(urls[batch..<min(batch + 200, urls.count)])
            let loaded = await writer.readRatings(for: slice)
            var changed = false
            for (url, value) in loaded where ratings[url] == nil {
                ratings[url] = value
                changed = true
            }
            if changed { ratingsRevision &+= 1 }
        }
        ratingsFullyLoaded = true
    }

    // MARK: - Filters

    /// Spec 01 §13: every rating is read from disk before a non-zero filter is applied.
    public func setRatingFilter(_ value: Int) async {
        if value != 0 { await loadAllRatings() }
        scheduler.stopBackgroundSweep()
        state.ratingFilter = RatingFilter(value)
        state.applyFilters(ratings: ratings)
        afterFilterChange()
    }

    public func setFolderFilter(_ name: String?) {
        scheduler.stopBackgroundSweep()
        state.folderFilter = name
        state.applyFilters(ratings: ratings)
        afterFilterChange()
    }

    /// Right-click on a subfolder chip. Spec 01 §4 / 03 §8.
    public func toggleExcluded(_ folderName: String) {
        var excluded = state.excludedFolders
        if excluded.contains(folderName) { excluded.remove(folderName) } else { excluded.insert(folderName) }
        state.excludedFolders = excluded
        state.applyFilters(ratings: ratings)
        afterFilterChange()
    }

    private func afterFilterChange() {
        scheduler.reset(totalFileCount: files.count)
        refreshPreloading()
        restartBackgroundSweep()
    }

    // MARK: - Modes

    /// `toggle: true` is the `J` / `M` key semantics (pressing it again returns to RAW).
    /// `toggle: false` is the mode-button semantics: a direct switch that is ignored when the
    /// target mode is empty. Spec 01 §4, §19.
    public func switchViewMode(_ kind: MediaKind, toggle: Bool) {
        var target = kind
        if toggle {
            if viewMode == kind {
                target = .raw
            } else if kind == .jpeg, viewMode == .raw,
                      modeStates[.jpeg]?.allFiles.isEmpty ?? true {
                // Spec 01 §19: the guard only fires when leaving RAW — kept as shipped.
                post(SnackbarEvent(text: "No JPEG files found in this folder", durationMs: 2000))
                return
            }
        } else {
            guard !(modeStates[kind]?.files.isEmpty ?? true) else { return }
        }
        guard target != viewMode else { return }
        exitCompare()
        viewMode = target
        scheduler.reset(totalFileCount: files.count)
        refreshPreloading()
        restartBackgroundSweep()
    }

    public func toggleGrid() {
        guard !files.isEmpty || displayMode == .grid else { return }
        if displayMode == .grid {
            displayMode = .single
            refreshPreloading()
        } else {
            exitCompare()
            displayMode = .grid
        }
    }

    // MARK: - Compare

    /// Spec 01 §9: unavailable in video mode and with no files.
    public func toggleCompare() {
        if isCompareActive {
            exitCompare()
            return
        }
        guard viewMode != .video, let current = currentFile else { return }
        pinnedFile = current
        focusedPane = .right
    }

    public func focusPane(_ pane: ComparePane) {
        guard isCompareActive else { return }
        focusedPane = pane
    }

    public func exitCompare() {
        pinnedFile = nil
        focusedPane = .right
    }

    // MARK: - Overlays

    public func toggleInfo() { showInfo.toggle() }
    public func toggleFilmstrip() {
        guard !files.isEmpty else { return }
        filmstripVisible.toggle()
    }

    public func post(_ event: SnackbarEvent) { snackbar = event }
    public func clearSnackbar() { snackbar = nil }

    // MARK: - Move rejected

    /// Spec 01 §23. Returns the confirmation prompt for the UI to show, or `nil` when there is
    /// nothing to move (in which case the snackbar has already been posted).
    public func moveRejected() async -> String? {
        guard folder != nil, !allFiles.isEmpty else { return nil }
        await loadAllRatings()
        await flushPendingWrites()

        let rejected = allFiles.filter { rating(for: $0.url) == Rating.rejected }.map(\.url)
        guard !rejected.isEmpty else {
            post(SnackbarEvent(text: "No rejected files", durationMs: 2000))
            pendingMoveSet = []
            return nil
        }
        pendingMoveSet = MoveRejected.collectMoveSet(rejected)
        let extras = pendingMoveSet.count - rejected.count
        return "Move \(rejected.count) rejected files (+\(extras) sidecars/pairs) to _rejected/?"
    }

    /// Performs the move confirmed by `moveRejected()`, then rescans the folder.
    public func performMoveRejected() async {
        guard let root = folder, !pendingMoveSet.isEmpty else { return }
        let files = pendingMoveSet
        pendingMoveSet = []
        let result = await Task.detached { MoveRejected.moveToRejected(files, root: root) }.value

        if let error = result.error {
            post(SnackbarEvent(text: "Moved \(result.moved), then failed at \(error)", durationMs: 5000))
        } else {
            post(SnackbarEvent(text: "Moved \(result.moved) files to _rejected/", durationMs: 2000))
        }
        exitCompare()
        openFolder(root)
    }

    // MARK: - Integrations (spec 01 §4, §20-22, 06 §5-6)

    /// `O` — reveal the current file in Finder. Spec 01 §21.
    public func revealInFinder() {
        guard let file = currentFile else { return }
        FinderReveal.reveal(file.url)
    }

    /// `Cmd+L` — hand the whole visible list to Lightroom Classic. Spec 01 §22.
    public func openInLightroom() {
        guard !files.isEmpty else { return }
        if !Lightroom.open(files: files.map(\.url)) {
            post(SnackbarEvent(text: "Adobe Lightroom Classic not found", durationMs: 4000))
        }
    }

    /// `Cmd+D` — export the currently filtered list to DaVinci Resolve. Spec 06 §5-6.
    /// The busy flag is always cleared, unlike the Python original.
    public func exportToResolve() async {
        guard !files.isEmpty else {
            post(SnackbarEvent(text: "No files to export", durationMs: 2000))
            return
        }
        guard !isExportingToResolve else {
            post(SnackbarEvent(text: "Export already in progress", durationMs: 2000))
            return
        }
        isExportingToResolve = true
        defer {
            isExportingToResolve = false
            resolveStatus = nil
        }

        await loadAllRatings()
        let snapshot = files.map(\.url)
        let ratingSnapshot = ratings
        let name = folder?.lastPathComponent ?? "Untitled"

        let result = await ResolveExport.export(
            files: snapshot,
            ratings: ratingSnapshot,
            folderName: name,
            onStatus: { status in
                Task { @MainActor [weak self] in
                    self?.resolveStatus = status.isEmpty ? nil : status
                }
            })

        switch result {
        case .success(let message):
            post(SnackbarEvent(text: message, durationMs: 4000))
        case .failure(let message):
            post(SnackbarEvent(text: message, durationMs: 5000))
        }
    }

    /// Runs once at launch. Spec 01 §20.
    public func checkForUpdates(currentVersion: String) async {
        guard let release = await UpdateCheck.check(currentVersion: currentVersion) else { return }
        updateAvailable = UpdateInfo(version: release.version, url: release.url)
    }

    // MARK: - Shoot timer (spec 05 §11)

    private func startShootTimer(for url: URL) {
        let persisted = ShootStats.load(folder: url)
        shootPersistedElapsed = persisted?.elapsed ?? 0
        shootRatedCount = persisted?.ratedCount ?? 0
        shootLastRatingElapsed = persisted?.lastRatingElapsed
        shootSessionStart = Date()
    }

    private func resetShootTimer() {
        shootPersistedElapsed = 0
        shootRatedCount = 0
        shootLastRatingElapsed = nil
        shootSessionStart = nil
    }

    public var shootElapsed: Double {
        guard let start = shootSessionStart else { return shootPersistedElapsed }
        return shootPersistedElapsed + Date().timeIntervalSince(start)
    }

    public var shootRated: Int { shootRatedCount }

    private func updateShootStats(previous: Int, new: Int) {
        guard shootSessionStart != nil else { return }
        if previous <= 0 && new > 0 {
            shootRatedCount += 1
        } else if previous > 0 && new <= 0 {
            shootRatedCount = max(0, shootRatedCount - 1)
        } else {
            return
        }
        shootLastRatingElapsed = shootElapsed
        writeShootStats()
    }

    private func writeShootStats() {
        guard let folder, shootSessionStart != nil else { return }
        ShootStats.save(ShootStatsEntry(elapsed: shootElapsed,
                                        ratedCount: shootRatedCount,
                                        lastRatingElapsed: shootLastRatingElapsed),
                        folder: folder)
    }

    /// Quit / open / close path: the shoot timer *and* the dashboard summary.
    public func persistShootStats() {
        writeShootStats()
        saveFolderSummary()
    }

    // MARK: - Folder summary (empty-state dashboard)

    /// Counts and rating histogram of the folder that is open right now, or `nil` when there
    /// is none. Ratings come from `rating(for:)`, so the histogram is only as complete as the
    /// ratings loaded so far — `finishScan` kicks off a full sweep for exactly that reason.
    public func currentFolderSummary() -> FolderSummary? {
        guard folder != nil, hasLoadedFolder else { return nil }
        var histogram: [Int: Int] = [:]
        for kind in MediaKind.allCases {
            for file in modeStates[kind]?.allFiles ?? [] {
                histogram[rating(for: file.url), default: 0] += 1
            }
        }
        return FolderSummary(raw: modeStates[.raw]?.allFiles.count ?? 0,
                             jpeg: modeStates[.jpeg]?.allFiles.count ?? 0,
                             video: modeStates[.video]?.allFiles.count ?? 0,
                             ratings: histogram,
                             updatedAt: Date())
    }

    /// Writes the current folder's summary through to disk and refreshes the in-memory cache.
    public func saveFolderSummary() {
        summarySaveTask?.cancel()
        summarySaveTask = nil
        guard let folder, let summary = currentFolderSummary() else { return }
        summaryStore.save(summary, for: folder)
        summaryCache?[folder.standardizedFileURL.path] = summary
    }

    /// Rating keys arrive in bursts while culling; one write a second is plenty.
    private func scheduleFolderSummarySave() {
        summarySaveTask?.cancel()
        summarySaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveFolderSummary()
        }
    }

    /// The cached summary for a recent folder, or `nil` when it was never open in this app.
    public func folderSummary(for url: URL) -> FolderSummary? {
        if summaryCache == nil { summaryCache = summaryStore.loadAll() }
        return summaryCache?[url.standardizedFileURL.path]
    }

    /// Drops the in-memory cache so the next read picks the file up again. The empty state
    /// calls this when it appears.
    public func reloadFolderSummaries() {
        summaryCache = summaryStore.loadAll()
    }

    /// `H:MM:SS` when there is at least an hour, otherwise `M:SS`, seconds truncated. Spec 01 §6.
    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Body of the shoot stats overlay. Spec 01 §6.
    public func statsLines() -> [String] {
        guard shootSessionStart != nil else {
            return ["No shoot active.", "Open a folder to start tracking."]
        }
        var lines = [
            "Folder:      \(folder?.lastPathComponent ?? "-")",
            "Elapsed:     \(Self.formatDuration(shootElapsed))",
            "Rated:       \(shootRatedCount) / \(allFiles.count)",
        ]
        // Spec 01 §6: both lines are always present; `-` stands in for "not computable yet".
        if let last = shootLastRatingElapsed {
            lines.append("To last rate: \(Self.formatDuration(last))")
            if shootRatedCount > 0 {
                lines.append(String(format: "Avg/rate:    %.1fs", last / Double(shootRatedCount)))
            } else {
                lines.append("Avg/rate:    -")
            }
        } else {
            lines.append("To last rate: -")
            lines.append("Avg/rate:    -")
        }
        return lines
    }

    // MARK: - Overlay text (spec 01 §4)

    /// `"7/137  (≥3★)  [X100VI]"` / `"  [excl. DJI, R5]"`.
    public var positionText: String {
        guard !files.isEmpty else { return "" }
        var text = "\(state.index + 1)/\(files.count)"
        if let badge = state.ratingFilter.badgeText { text += "  (\(badge))" }
        if let folderFilter = state.folderFilter {
            text += "  [\(folderFilter)]"
        } else if !state.excludedFolders.isEmpty {
            text += "  [excl. \(state.excludedFolders.sorted().joined(separator: ", "))]"
        }
        return text
    }

    /// `"{filename}  |  {YYYY-MM-DD HH:MM}  |  {stars}"`.
    public var infoText: String {
        guard let file = currentFile else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(file.name)  |  \(formatter.string(from: file.captureDate))  |  \(Rating.stars(rating(for: file.url)))"
    }

    /// `"≥3★ · 42/137"` for the toolbar's filter badge, or `nil` when no rating filter is active.
    public var filterBadgeText: String? {
        guard let badge = state.ratingFilter.badgeText else { return nil }
        return "\(badge) · \(files.count)/\(allFiles.count)"
    }

    /// `"RAW (137)"`, or the bare label when that mode has no files (the button is then hidden).
    public func modeButtonLabel(_ kind: MediaKind) -> String {
        let count = modeStates[kind]?.files.count ?? 0
        return count > 0 ? "\(kind.buttonLabel) (\(count))" : kind.buttonLabel
    }

    public func modeButtonVisible(_ kind: MediaKind) -> Bool {
        (modeStates[kind]?.files.count ?? 0) > 0
    }

    /// Chips render only when there is more than one distinct subfolder. Spec 03 §7.
    public var showsSubfolderChips: Bool { state.subfolderCounts.count > 1 }

    /// Named chips, sorted by name, with their raw scan counts (which deliberately ignore the
    /// rating filter, as shipped) and their exclusion state. Spec 01 §4.
    public func subfolderChips() -> [(name: String, count: Int, excluded: Bool)] {
        state.subfolderCounts.map {
            (name: $0.name, count: $0.count, excluded: state.excludedFolders.contains($0.name))
        }
    }

    /// The `All (N)` count: unfiltered total minus everything in excluded subfolders.
    public var allChipCount: Int { state.allChipCount }

    public var windowTitle: String { folder == nil ? "RAW Viewer" : viewMode.windowTitle }
}
