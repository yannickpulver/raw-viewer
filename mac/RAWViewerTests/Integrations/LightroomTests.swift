import XCTest
@testable import RAWViewer

final class LightroomTests: XCTestCase {

    func testBundleIdentifier() {
        XCTAssertEqual(Lightroom.bundleIdentifier, "com.adobe.LightroomClassicCC7")
    }

    func testOpenReturnsFalseWhenLightroomIsNotInstalled() throws {
        try XCTSkipUnless(Lightroom.applicationURL == nil,
                          "Lightroom Classic is installed on this machine")
        XCTAssertFalse(Lightroom.open(files: [URL(fileURLWithPath: "/tmp/x.raf")]))
    }

    func testApplicationLookupDoesNotCrashAndMatchesCandidates() {
        guard let url = Lightroom.applicationURL else { return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
