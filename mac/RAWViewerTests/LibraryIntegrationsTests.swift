import XCTest
@testable import RAWViewer

/// Covers the `Library` methods the UI layer added: the Resolve export guards,
/// the Lightroom / Finder no-ops, and the update check. Spec 01 §20-22, 06 §6.
@MainActor
final class LibraryIntegrationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var library: Library!

    override func setUp() async throws {
        suiteName = "RAWViewerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: Preferences.Keys.didImportLegacyCache)
        library = Library(preferences: Preferences(defaults: defaults),
                          recents: RecentFolders(defaults: defaults))
    }

    override func tearDown() async throws {
        library = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testExportWithNoFilesPostsSnackbarAndStaysIdle() async {
        await library.exportToResolve()
        XCTAssertEqual(library.snackbar?.text, "No files to export")
        XCTAssertEqual(library.snackbar?.durationMs, 2000)
        XCTAssertFalse(library.isExportingToResolve)
    }

    func testExportBusyFlagIsClearedAfterTheGuardFires() async {
        await library.exportToResolve()
        library.clearSnackbar()
        await library.exportToResolve()
        // A second call reaches the same guard rather than "Export already in progress",
        // which proves the busy flag was cleared.
        XCTAssertEqual(library.snackbar?.text, "No files to export")
    }

    func testOpenInLightroomWithNoFilesIsANoOp() {
        library.openInLightroom()
        XCTAssertNil(library.snackbar)
    }

    func testRevealInFinderWithNoSelectionIsANoOp() {
        library.revealInFinder()
        XCTAssertNil(library.snackbar)
    }
}
