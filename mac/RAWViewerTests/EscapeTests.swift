import XCTest
@testable import RAWViewer

/// `Esc` goes up one level per press: single → grid → start screen.
@MainActor
final class EscapeTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var model: AppModel!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("IMG_000\(index).cr3").path,
                                           contents: Data("x".utf8))
        }
        suiteName = "RAWViewerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: Preferences.Keys.didImportLegacyCache)
        let library = Library(preferences: Preferences(defaults: defaults),
                              recents: RecentFolders(defaults: defaults),
                              summaryStore: FolderSummaryStore(file: root.appendingPathComponent("summaries.json")),
                              viewedStore: ViewedStore(directory: root.appendingPathComponent("viewed")))
        model = AppModel(library: library)
        library.openFolder(root)
        for _ in 0..<600 where library.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(library.files.count, 3)
    }

    override func tearDown() async throws {
        model = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testEscapeGoesFromSingleToGridToTheStartScreen() {
        let library = model.library
        XCTAssertEqual(library.displayMode, .single)
        model.escape()
        XCTAssertEqual(library.displayMode, .grid)
        XCTAssertNotNil(library.folder)
        model.escape()
        XCTAssertNil(library.folder)
    }

    func testEscapeLeavesCompareAndOverlaysFirst() {
        let library = model.library
        model.showHelp = true
        model.escape()
        XCTAssertFalse(model.showHelp)
        XCTAssertEqual(library.displayMode, .single)

        library.toggleCompare()
        XCTAssertTrue(library.isCompareActive)
        model.escape()
        XCTAssertFalse(library.isCompareActive)
        XCTAssertEqual(library.displayMode, .single)
    }
}
