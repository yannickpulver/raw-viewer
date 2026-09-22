import XCTest
@testable import RAWViewer

@MainActor
final class LibraryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var library: Library!
    private var summaryFile: URL!
    private var summaryStore: FolderSummaryStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        suiteName = "RAWViewerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: Preferences.Keys.didImportLegacyCache)

        summaryFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summaries-\(UUID().uuidString).json")
        summaryStore = FolderSummaryStore(file: summaryFile)

        let preferences = Preferences(defaults: defaults)
        library = Library(preferences: preferences,
                          recents: RecentFolders(defaults: defaults),
                          summaryStore: summaryStore)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: summaryFile)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ relative: String) -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    private func openAndWait(_ folder: URL) async throws {
        library.openFolder(folder)
        for _ in 0..<600 {
            if !library.isScanning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("scan did not finish")
    }

    private func seedRawFolder(count: Int = 4) async throws {
        for index in 0..<count { touch(String(format: "IMG_%04d.cr3", index)) }
        try await openAndWait(root)
    }

    // MARK: - Opening

    func testOpenFolderPopulatesRawModeAndRecents() async throws {
        try await seedRawFolder()
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.files.count, 4)
        XCTAssertEqual(library.index, 0)
        XCTAssertEqual(library.recentFolders.first?.path, root.standardizedFileURL.path)
    }

    func testEmptyFolderIsNotAddedToRecents() async throws {
        touch("notes.txt")
        try await openAndWait(root)
        XCTAssertTrue(library.files.isEmpty)
        XCTAssertTrue(library.recentFolders.isEmpty)
    }

    /// Spec 01 §10: with no RAW, switch to whichever of JPEG/video has more files (JPEG wins ties).
    func testAutoSwitchesToVideoWhenItHasMoreFiles() async throws {
        touch("a.jpg")
        touch("b.mov")
        touch("c.mov")
        try await openAndWait(root)
        XCTAssertEqual(library.viewMode, .video)
    }

    func testAutoSwitchesToJPEGOnTies() async throws {
        touch("a.jpg")
        touch("b.mov")
        try await openAndWait(root)
        XCTAssertEqual(library.viewMode, .jpeg)
    }

    func testCloseFolderResetsEverything() async throws {
        try await seedRawFolder()
        library.closeFolder()
        XCTAssertNil(library.folder)
        XCTAssertTrue(library.files.isEmpty)
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.displayMode, .single)
    }

    // MARK: - Navigation

    func testNavigateDoesNotWrap() async throws {
        try await seedRawFolder()
        library.navigate(by: -1)
        XCTAssertEqual(library.index, 0)
        library.jumpToLast()
        XCTAssertEqual(library.index, 3)
        library.navigate(by: 1)
        XCTAssertEqual(library.index, 3)
        library.jumpToFirst()
        XCTAssertEqual(library.index, 0)
    }

    func testGridMoveUsesGridLayout() async throws {
        for index in 0..<10 { touch(String(format: "IMG_%04d.cr3", index)) }
        try await openAndWait(root)
        library.gridColumns = 4
        library.gridMove(dx: 0, dy: 1)
        XCTAssertEqual(library.index, 4)
        library.gridMove(dx: 1, dy: 0)
        XCTAssertEqual(library.index, 5)
        library.gridMove(dx: 0, dy: 1)
        XCTAssertEqual(library.index, 9)   // clamps into the partial last row
        library.gridMove(dx: 0, dy: 1)
        XCTAssertEqual(library.index, 9)   // already on the last row
    }


    // MARK: - Folder summary (empty-state dashboard)

    func testFolderSummaryCountsKindsAndRatings() async throws {
        touch("a.cr3"); touch("b.cr3"); touch("c.cr3")
        touch("d.jpg"); touch("e.jpg")
        touch("f.mov")
        try await openAndWait(root)

        library.rate(5)                     // a.cr3, advances to b
        library.rate(3)                     // b.cr3, advances to c
        library.toggleReject()              // c.cr3
        library.switchViewMode(.jpeg, toggle: false)
        library.rate(3)                     // d.jpg

        let summary = try XCTUnwrap(library.currentFolderSummary())
        XCTAssertEqual(summary.raw, 3)
        XCTAssertEqual(summary.jpeg, 2)
        XCTAssertEqual(summary.video, 1)
        XCTAssertEqual(summary.total, 6)
        XCTAssertEqual(summary.rated(stars: 5), 1)
        XCTAssertEqual(summary.rated(stars: 3), 2)
        XCTAssertEqual(summary.rated(stars: 4), 0)
        XCTAssertEqual(summary.rated(stars: Rating.rejected), 1)
        XCTAssertEqual(summary.rated(stars: Rating.unrated), 2)
    }

    func testFolderSummaryIsSavedOnCloseAndReadBack() async throws {
        touch("a.cr3"); touch("b.cr3"); touch("c.jpg")
        try await openAndWait(root)
        library.rate(4)
        await library.flushPendingWrites()

        library.closeFolder()

        let stored = try XCTUnwrap(summaryStore.load(folder: root))
        XCTAssertEqual(stored.raw, 2)
        XCTAssertEqual(stored.jpeg, 1)
        XCTAssertEqual(stored.rated(stars: 4), 1)

        library.reloadFolderSummaries()
        XCTAssertEqual(library.folderSummary(for: root), stored)
        XCTAssertNil(library.folderSummary(for: root.appendingPathComponent("nope")))
    }

    func testNoSummaryWithoutAnOpenFolder() async throws {
        XCTAssertNil(library.currentFolderSummary())
    }

    // MARK: - Rating

    func testRateAutoAdvancesExceptOnLast() async throws {
        try await seedRawFolder()
        library.rate(3)
        XCTAssertEqual(library.index, 1)
        XCTAssertEqual(library.rating(for: library.files[0].url), 3)

        library.jumpToLast()
        library.rate(5)
        XCTAssertEqual(library.index, 3, "no advance on the last file")
        await library.flushPendingWrites()
        XCTAssertEqual(XMPSidecar.read(library.files[3].url), 5)
    }

    func testToggleRejectRoundTrips() async throws {
        try await seedRawFolder()
        let first = library.files[0]
        library.toggleReject()
        XCTAssertEqual(library.rating(for: first.url), -1)
        library.select(index: 0)
        library.toggleReject()
        XCTAssertEqual(library.rating(for: first.url), 0)
    }

    func testRatingThePinnedPaneDoesNotAdvance() async throws {
        try await seedRawFolder()
        library.select(index: 1)
        library.toggleCompare()
        XCTAssertTrue(library.isCompareActive)
        library.focusPane(.left)
        library.rate(4)
        XCTAssertEqual(library.index, 1)
        XCTAssertEqual(library.rating(for: library.files[1].url), 4)
        library.exitCompare()
        XCTAssertFalse(library.isCompareActive)
    }

    func testCompareIsUnavailableInVideoMode() async throws {
        touch("a.mov")
        touch("b.mov")
        try await openAndWait(root)
        XCTAssertEqual(library.viewMode, .video)
        library.toggleCompare()
        XCTAssertFalse(library.isCompareActive)
    }

    // MARK: - Filters

    func testRatingFilterLoadsRatingsFromDiskAndFilters() async throws {
        // Sidecars are written before the scan: like the shipped app, ratings discovered in
        // memory win over disk, so a sidecar written behind the app's back is not re-read.
        for index in 0..<4 { touch(String(format: "IMG_%04d.cr3", index)) }
        XMPSidecar.write(root.appendingPathComponent("IMG_0002.cr3"), rating: 4)
        try await openAndWait(root)
        await library.setRatingFilter(3)
        XCTAssertEqual(library.files.map(\.name), ["IMG_0002.cr3"])
        XCTAssertEqual(library.filterBadgeText, "≥3★ · 1/4")
        await library.setRatingFilter(0)
        XCTAssertEqual(library.files.count, 4)
    }

    func testSubfolderFilterAndExclusion() async throws {
        touch("A/a.cr3")
        touch("A/b.cr3")
        touch("B/c.cr3")
        try await openAndWait(root)
        XCTAssertTrue(library.showsSubfolderChips)
        XCTAssertEqual(library.allChipCount, 3)

        library.toggleExcluded("B")
        XCTAssertEqual(library.files.count, 2)
        XCTAssertEqual(library.allChipCount, 2)
        XCTAssertTrue(library.subfolderChips().contains { $0.name == "B" && $0.excluded })
        XCTAssertTrue(library.positionText.hasSuffix("[excl. B]"))

        library.setFolderFilter("B")
        XCTAssertEqual(library.files.map(\.name), ["c.cr3"])
        XCTAssertTrue(library.positionText.hasSuffix("[B]"))

        library.setFolderFilter(nil)
        library.toggleExcluded("B")
        XCTAssertEqual(library.files.count, 3)
    }

    // MARK: - Modes

    func testJPEGToggleGuardPostsSnackbar() async throws {
        try await seedRawFolder()
        library.switchViewMode(.jpeg, toggle: true)
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.snackbar?.text, "No JPEG files found in this folder")
        XCTAssertEqual(library.snackbar?.durationMs, 2000)
    }

    func testJPEGToggleSwitchesAndTogglesBack() async throws {
        touch("a.cr3")
        touch("b.jpg")
        try await openAndWait(root)
        library.switchViewMode(.jpeg, toggle: true)
        XCTAssertEqual(library.viewMode, .jpeg)
        library.switchViewMode(.jpeg, toggle: true)
        XCTAssertEqual(library.viewMode, .raw)
    }

    func testModeButtonIgnoresEmptyMode() async throws {
        try await seedRawFolder()
        library.switchViewMode(.video, toggle: false)
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.modeButtonLabel(.raw), "RAW (4)")
        XCTAssertEqual(library.modeButtonLabel(.video), "MOV")
        XCTAssertFalse(library.modeButtonVisible(.video))
    }

    func testModeStateSurvivesRoundTrip() async throws {
        touch("a.cr3")
        touch("b.cr3")
        touch("c.jpg")
        touch("d.jpg")
        try await openAndWait(root)
        library.select(index: 1)
        library.switchViewMode(.jpeg, toggle: true)
        XCTAssertEqual(library.index, 0)
        library.select(index: 1)
        library.switchViewMode(.jpeg, toggle: true)
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.index, 1, "RAW selection survived the round trip")
    }

    func testToggleGridExitsCompare() async throws {
        try await seedRawFolder()
        library.toggleCompare()
        library.toggleGrid()
        XCTAssertEqual(library.displayMode, .grid)
        XCTAssertFalse(library.isCompareActive)
        library.toggleGrid()
        XCTAssertEqual(library.displayMode, .single)
    }

    // MARK: - Jump to last rated

    func testJumpToLastRatedIgnoresRejected() async throws {
        for index in 0..<4 { touch(String(format: "IMG_%04d.cr3", index)) }
        XMPSidecar.write(root.appendingPathComponent("IMG_0001.cr3"), rating: 2)
        XMPSidecar.write(root.appendingPathComponent("IMG_0003.cr3"), rating: -1)
        try await openAndWait(root)
        await library.jumpToLastRated()
        XCTAssertEqual(library.index, 1)
    }

    // MARK: - Move rejected

    func testMoveRejectedPromptAndExecution() async throws {
        touch("IMG_0001.cr3")
        touch("IMG_0001.jpg")
        touch("IMG_0002.cr3")
        XMPSidecar.write(root.appendingPathComponent("IMG_0001.cr3"), rating: -1)
        try await openAndWait(root)

        let prompt = await library.moveRejected()
        // The rejected .cr3 drags its .jpg sibling and its .xmp sidecar along.
        XCTAssertEqual(prompt, "Move 1 rejected files (+2 sidecars/pairs) to _rejected/?")

        await library.performMoveRejected()
        for _ in 0..<600 where library.isScanning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("_rejected/IMG_0001.cr3").path))
        XCTAssertEqual(library.files.map(\.name), ["IMG_0002.cr3"])
    }

    func testMoveRejectedWithNothingRejectedPostsSnackbar() async throws {
        try await seedRawFolder()
        let prompt = await library.moveRejected()
        XCTAssertNil(prompt)
        XCTAssertEqual(library.snackbar?.text, "No rejected files")
    }

    // MARK: - Overlay text

    func testPositionAndInfoText() async throws {
        try await seedRawFolder()
        XCTAssertEqual(library.positionText, "1/4")
        library.rate(3)
        XCTAssertEqual(library.positionText, "2/4")
        library.select(index: 0)
        XCTAssertTrue(library.infoText.hasPrefix("IMG_0000.cr3  |  "))
        XCTAssertTrue(library.infoText.hasSuffix("  |  ★★★☆☆"))
        XCTAssertNil(library.filterBadgeText)
        XCTAssertEqual(library.windowTitle, "RAW Viewer")
    }

    func testPreferencesPersistAcrossInstances() async throws {
        library.toggleInfo()
        XCTAssertFalse(library.showInfo)
        let second = Library(preferences: Preferences(defaults: defaults),
                             recents: RecentFolders(defaults: defaults))
        XCTAssertFalse(second.showInfo)
        XCTAssertTrue(second.filmstripVisible)
    }

    /// Mac app addition: newest-first reverses the timeline and persists across instances.
    func testToggleNewestFirstReversesFilesAndPersists() async throws {
        try await seedRawFolder()
        let original = library.files.map(\.name)
        library.toggleNewestFirst()
        XCTAssertTrue(library.newestFirst)
        XCTAssertEqual(library.files.map(\.name), original.reversed())

        let second = Library(preferences: Preferences(defaults: defaults),
                             recents: RecentFolders(defaults: defaults))
        XCTAssertTrue(second.newestFirst)
    }

    // MARK: - Shoot stats

    func testStatsLinesWithNoFolder() {
        XCTAssertEqual(library.statsLines(), ["No shoot active.", "Open a folder to start tracking."])
    }

    func testStatsLinesTrackRatedCount() async throws {
        try await seedRawFolder()
        var lines = library.statsLines()
        XCTAssertEqual(lines[0], "Folder:      \(root.lastPathComponent)")
        XCTAssertEqual(lines[2], "Rated:       0 / 4")
        XCTAssertEqual(lines[3], "To last rate: -")
        XCTAssertEqual(lines[4], "Avg/rate:    -")

        library.rate(4)
        lines = library.statsLines()
        XCTAssertEqual(lines[2], "Rated:       1 / 4")
        XCTAssertTrue(lines[3].hasPrefix("To last rate: "))
        XCTAssertTrue(lines[4].hasPrefix("Avg/rate:    "))

        // Rejecting counts as unrating.
        library.select(index: 0)
        library.toggleReject()
        XCTAssertEqual(library.statsLines()[2], "Rated:       0 / 4")
    }

    func testDurationFormatting() {
        XCTAssertEqual(Library.formatDuration(0), "0:00")
        XCTAssertEqual(Library.formatDuration(65.9), "1:05")
        XCTAssertEqual(Library.formatDuration(3600), "1:00:00")
        XCTAssertEqual(Library.formatDuration(3671), "1:01:11")
    }

    // MARK: - Review fixes

    /// Fix 1: the scheduler is armed when a scan lands, so the "Loading: N%" label and the
    /// background thumbnail sweep actually start.
    func testFinishScanArmsTheScheduler() async throws {
        try await seedRawFolder()
        XCTAssertEqual(library.scheduler.totalFileCount, 4)
        XCTAssertLessThan(library.scheduler.progressFraction, 1.0001)
    }

    /// Fix 2 / spec 01 §10: an empty scan changes nothing — not the folder, not the lists.
    func testEmptyScanLeavesThePreviousFolderIntact() async throws {
        try await seedRawFolder()
        library.rate(3)
        let ratedURL = library.files[0].url

        let empty = root.appendingPathComponent("empty-elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: empty.appendingPathComponent("notes.txt").path,
                                       contents: Data("x".utf8))

        try await openAndWait(empty)

        XCTAssertEqual(library.folder?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(library.files.count, 4)
        XCTAssertEqual(library.viewMode, .raw)
        XCTAssertEqual(library.rating(for: ratedURL), 3)
        XCTAssertEqual(library.statsLines()[0], "Folder:      \(root.lastPathComponent)")
        XCTAssertFalse(library.recentFolders.contains(empty.standardizedFileURL))
    }

    /// Fix 3: a superseded scan never writes back over the newer one.
    func testSupersededScanDoesNotClobberTheNewerOne() async throws {
        for index in 0..<6 { touch(String(format: "IMG_%04d.cr3", index)) }
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<2 {
            FileManager.default.createFile(
                atPath: second.appendingPathComponent(String(format: "B_%04d.jpg", index)).path,
                contents: Data("x".utf8))
        }

        library.openFolder(root)
        try await openAndWait(second)

        XCTAssertEqual(library.folder?.standardizedFileURL, second.standardizedFileURL)
        XCTAssertEqual(library.viewMode, .jpeg)
        XCTAssertEqual(library.files.count, 2)
        XCTAssertFalse(library.isScanning)
        XCTAssertNil(library.scanProgressText)
    }

    /// Fix 6: the shoot timer belongs to the folder it was started for. Opening another folder
    /// persists it under the old key and starts fresh, so a quit mid-scan cannot mis-attribute.
    func testOpeningAnotherFolderResetsTheShootTimer() async throws {
        try await seedRawFolder()
        library.rate(5)
        XCTAssertEqual(library.shootRated, 1)

        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: second.appendingPathComponent("B.cr3").path,
                                       contents: Data("x".utf8))
        try await openAndWait(second)

        XCTAssertEqual(library.shootRated, 0)
        XCTAssertEqual(library.statsLines()[0], "Folder:      second")
        XCTAssertEqual(ShootStats.load(folder: root)?.ratedCount, 1)
    }

    /// Fix 7: re-rating the file that is already selected has to be observable, even though
    /// neither the index nor `ratings.count` moves.
    func testRatingsRevisionBumpsWhenTheValueChangesInPlace() async throws {
        try await seedRawFolder()
        library.jumpToLast()
        let before = library.ratingsRevision
        let index = library.index

        library.rate(4)           // last file: no auto-advance
        let afterFirst = library.ratingsRevision
        let countAfterFirst = library.ratings.count
        XCTAssertGreaterThan(afterFirst, before)

        library.rate(2)           // same file, same ratings.count, different value
        XCTAssertGreaterThan(library.ratingsRevision, afterFirst)
        XCTAssertEqual(library.ratings.count, countAfterFirst,
                       "the count cannot see this change — only the revision can")
        XCTAssertEqual(library.index, index)
        XCTAssertEqual(library.currentRating, 2)
    }

    /// Fix 11 / spec 01 §6: `Avg/rate:` is always present, `-` when nothing is rated.
    func testStatsAlwaysEmitAnAverageLine() async throws {
        try await seedRawFolder()
        library.rate(4)
        library.select(index: 0)
        library.rate(0)           // back to zero rated, but `lastRatingElapsed` is now set

        let lines = library.statsLines()
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[2], "Rated:       0 / 4")
        XCTAssertTrue(lines[3].hasPrefix("To last rate: "))
        XCTAssertEqual(lines[4], "Avg/rate:    -")
    }
}
