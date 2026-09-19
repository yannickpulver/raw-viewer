import XCTest
@testable import RAWViewer

final class PersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "RAWViewerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRecentFoldersNewestFirstDedupedAndCapped() throws {
        let recents = RecentFolders(defaults: defaults)
        var folders: [URL] = []
        for index in 0..<7 {
            let url = try folder("shoot\(index)")
            folders.append(url)
            recents.add(url)
        }
        let loaded = recents.load()
        XCTAssertEqual(loaded.count, RecentFolders.maximum)
        XCTAssertEqual(loaded.first?.lastPathComponent, "shoot6")

        recents.add(folders[3])
        XCTAssertEqual(recents.load().first?.lastPathComponent, "shoot3")
        XCTAssertEqual(recents.load().count, RecentFolders.maximum)
        XCTAssertEqual(Set(recents.load().map(\.lastPathComponent)).count, RecentFolders.maximum)
    }

    func testRecentFoldersPrunesNonDirectories() throws {
        let recents = RecentFolders(defaults: defaults)
        let good = try folder("good")
        let gone = try folder("gone")
        recents.add(good)
        recents.add(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(recents.load().map(\.lastPathComponent), ["good"])
    }

    func testFolderSummaryStoreRoundTrip() throws {
        let file = root.appendingPathComponent("folder_summaries.json")
        let store = FolderSummaryStore(file: file)
        let shoot = try folder("wedding")
        let other = try folder("portraits")
        XCTAssertNil(store.load(folder: shoot))

        let summary = FolderSummary(raw: 24, jpeg: 12, video: 3,
                                    ratings: [5: 3, 4: 7, 0: 12, -1: 4, 2: 0],
                                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(summary, for: shoot)
        store.save(FolderSummary(raw: 1), for: other)

        let loaded = try XCTUnwrap(FolderSummaryStore(file: file).load(folder: shoot))
        XCTAssertEqual(loaded, summary)
        XCTAssertEqual(loaded.total, 39)
        XCTAssertEqual(loaded.rated(stars: 4), 7)
        XCTAssertEqual(loaded.rated(stars: 2), 0, "zero buckets are dropped")
        XCTAssertEqual(loaded.count(for: .jpeg), 12)
        XCTAssertEqual(store.loadAll().count, 2, "a save keeps the other folders")

        // A later save for the same folder replaces the entry.
        store.save(FolderSummary(raw: 2, ratings: [1: 2]), for: shoot)
        XCTAssertEqual(store.load(folder: shoot)?.raw, 2)
        XCTAssertEqual(store.loadAll().count, 2)
    }

    func testFolderSummaryStoreSurvivesGarbage() throws {
        let file = root.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: file)
        let store = FolderSummaryStore(file: file)
        XCTAssertNil(store.load(folder: try folder("wedding")))
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testShootStatsRoundTrip() throws {
        let file = root.appendingPathComponent("shoot_stats.json")
        let shoot = try folder("wedding")
        XCTAssertNil(ShootStats.load(folder: shoot, file: file))

        ShootStats.save(ShootStatsEntry(elapsed: 1842.3, ratedCount: 63, lastRatingElapsed: 1790.1),
                        folder: shoot, file: file)
        let loaded = ShootStats.load(folder: shoot, file: file)
        XCTAssertEqual(loaded?.elapsed, 1842.3)
        XCTAssertEqual(loaded?.ratedCount, 63)
        XCTAssertEqual(loaded?.lastRatingElapsed, 1790.1)

        // Spec 07 §5 key/field names.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let entry = json?[shoot.standardizedFileURL.path] as? [String: Any]
        XCTAssertNotNil(entry?["elapsed"])
        XCTAssertNotNil(entry?["rated_count"])
        XCTAssertNotNil(entry?["last_rating_elapsed"])
    }

    func testPreferencesDefaults() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.showInfo)
        XCTAssertTrue(preferences.filmstripVisible)
        XCTAssertFalse(preferences.didImportLegacyCache)
        preferences.filmstripVisible = false
        XCTAssertFalse(Preferences(defaults: defaults).filmstripVisible)
    }
}
