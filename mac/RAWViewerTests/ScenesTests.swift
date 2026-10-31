import XCTest
@testable import RAWViewer

final class ScenesTests: XCTestCase {
    private func files(at offsets: [TimeInterval]) -> [MediaFile] {
        offsets.enumerated().map { index, offset in
            MediaFile(url: URL(fileURLWithPath: "/shoot/\(index).raf"), kind: .raw,
                      captureDate: Date(timeIntervalSince1970: 1_700_000_000 + offset), subfolder: "")
        }
    }

    func testCutsOnlyWherePauseExceedsMaxGap() {
        // Pauses of 30, 60, 61 and 1 s: only the 61 s one starts a scene.
        XCTAssertEqual(Scenes(files: files(at: [0, 30, 90, 151, 152])).starts, [0, 3])
    }

    func testNewestFirstFindsTheSameScenesReversed() {
        XCTAssertEqual(Scenes(files: files(at: [152, 151, 90, 30, 0])).starts, [0, 2])
    }

    func testSceneOfAndRange() {
        let scenes = SceneFixtures.scenes([2, 3, 1])
        XCTAssertEqual(scenes.starts, [0, 2, 5])
        XCTAssertEqual([0, 1, 2, 4, 5].map(scenes.scene(of:)), [0, 0, 1, 1, 2])
        XCTAssertEqual(scenes.range(of: 1), 2..<5)
        XCTAssertEqual(scenes.range(of: 2), 5..<6)
    }

    func testEmptyAndUngrouped() {
        XCTAssertEqual(Scenes(files: []).count, 0)
        XCTAssertEqual(Scenes(total: 0).count, 0)
        XCTAssertEqual(Scenes(total: 5).starts, [0])
        XCTAssertEqual(Scenes(total: 5).range(of: 0), 0..<5)
    }

    func testTileLayoutPicksTheLargestSplit() {
        XCTAssertTrue(TileLayout.grid(count: 1, width: 2000, height: 1000, aspect: 1.5) == (1, 1))
        XCTAssertTrue(TileLayout.grid(count: 2, width: 2000, height: 1000, aspect: 1.5) == (2, 1))
        XCTAssertTrue(TileLayout.grid(count: 2, width: 1000, height: 1400, aspect: 1.5) == (1, 2))
        XCTAssertTrue(TileLayout.grid(count: 2, width: 2000, height: 1200, aspect: 0.67) == (2, 1),
                      "portrait frames sit side by side")
        XCTAssertTrue(TileLayout.grid(count: 4, width: 2000, height: 1200, aspect: 1.5) == (2, 2))
    }
}
