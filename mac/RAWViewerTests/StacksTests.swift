import XCTest
@testable import RAWViewer

final class StacksTests: XCTestCase {
    /// `(seconds after the start, EV)` per frame; shutter time follows the EV like a bracket.
    private func frames(_ shots: [(TimeInterval, Double)], folder: String = "DJI",
                        kind: MediaKind = .raw) -> [MediaFile] {
        shots.enumerated().map { index, shot in
            MediaFile(url: URL(fileURLWithPath: "/shoot/\(folder)/\(index).dng"), kind: kind,
                      captureDate: Date(timeIntervalSince1970: 1_700_000_000 + shot.0), subfolder: folder,
                      exposure: Exposure(time: 0.005 * pow(2, shot.1), bias: shot.1))
        }
    }

    func testDroneBracketsBecomeStacksOfThree() {
        // Two brackets 18 s apart, each 0 / −0.7 / +0.7 EV in the same second.
        let files = frames([(0, 0), (0, -0.7), (0, 0.7), (18, 0), (18, -0.7), (18, 0.7)])
        XCTAssertEqual(Stacks.ranges(in: files), [0..<3, 3..<6])
    }

    func testBackToBackBracketsSplitWhereTheExposureRepeats() {
        let files = frames([(0, 0), (0, -0.7), (0, 0.7), (1, 0), (1, -0.7), (1, 0.7)])
        XCTAssertEqual(Stacks.ranges(in: files), [0..<3, 3..<6])
    }

    func testBurstsAtOneExposureStaySingleFrames() {
        XCTAssertEqual(Stacks.ranges(in: frames([(0, 0), (0.3, 0), (0.6, 0)])), [])
    }

    func testGapsCamerasVideosAndMissingExposureBreakAStack() {
        XCTAssertEqual(Stacks.ranges(in: frames([(0, 0), (2, -1)])), [], "more than a second apart")
        let twoCameras = frames([(0, 0)], folder: "A") + frames([(0, -1)], folder: "B")
        XCTAssertEqual(Stacks.ranges(in: twoCameras), [])
        XCTAssertEqual(Stacks.ranges(in: frames([(0, 0), (0, -1)], kind: .video)), [])
        let bare = MediaFile(url: URL(fileURLWithPath: "/shoot/DJI/x.dng"), kind: .raw,
                             captureDate: Date(timeIntervalSince1970: 1_700_000_000), subfolder: "DJI")
        XCTAssertEqual(Stacks.ranges(in: [bare] + frames([(0, 0), (0, -1)])), [1..<3])
    }

    func testNewestFirstFindsTheSameStacks() {
        let files = frames([(0, 0), (0, -0.7), (0, 0.7), (18, 0), (18, -0.7), (18, 0.7)])
        XCTAssertEqual(Stacks.ranges(in: files.reversed()), [0..<3, 3..<6])
    }

    func testCoverIsTheFrameClosestToZeroEV() {
        let files = frames([(0, -0.7), (0, 0), (0, 0.7)])
        XCTAssertEqual(Stacks.cover(of: files).url, files[1].url)
        let noZero = frames([(0, -1), (0, 1)])
        XCTAssertEqual(Stacks.cover(of: noZero).url, noZero[0].url, "the earliest on a tie")
    }

    // MARK: - ModeState

    private func state(_ files: [MediaFile], scenes: Bool = true) -> ModeState {
        var state = ModeState()
        state.allFiles = files
        state.groupsScenes = scenes
        state.applyFilters(ratings: [:])
        return state
    }

    func testCollapsedStacksShowOnlyTheirCover() {
        let files = frames([(0, -0.7), (0, 0), (0, 0.7), (100, 0)])
        var mode = state(files)
        XCTAssertEqual(mode.files.map(\.url), [files[1].url, files[3].url])
        XCTAssertEqual(mode.members(of: files[1]).map(\.url), files[0...2].map(\.url))
        XCTAssertEqual(mode.expanded(mode.files).count, 4)

        mode.expandedStacks.insert(files[1].url)
        mode.applyFilters(ratings: [:])
        XCTAssertEqual(mode.files.count, 4)
        XCTAssertEqual(mode.members(of: files[1]).map(\.url), [files[1].url], "expanded frames stand for themselves")

        // Collapsing while on a hidden frame lands on its cover.
        mode.index = 2
        mode.expandedStacks = []
        mode.applyFilters(ratings: [:])
        XCTAssertEqual(mode.currentFile?.url, files[1].url)
    }

    func testStacksNeedGroupByScene() {
        let files = frames([(0, -0.7), (0, 0), (0, 0.7)])
        XCTAssertEqual(state(files, scenes: false).files.count, 3)
        XCTAssertTrue(state(files, scenes: false).stacks.isEmpty)
    }

    // MARK: - Date cache

    func testDateCacheKeepsTheExposureAndReReadsOldEntries() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: ["/old.raf": [1.0, 2.0]]).write(to: file)

        let cache = DateCache(file: file)
        XCTAssertNil(cache.info(forPath: "/old.raf", mtime: 1), "entries from before the exposure are read again")
        cache.store(path: "/a.dng", mtime: 5, date: Date(timeIntervalSince1970: 9),
                    exposure: Exposure(time: 0.004, bias: -0.7))
        cache.store(path: "/b.mov", mtime: 5, date: Date(timeIntervalSince1970: 9), exposure: nil)
        cache.save()

        let reloaded = DateCache(file: file)
        XCTAssertEqual(reloaded.info(forPath: "/a.dng", mtime: 5)?.exposure, Exposure(time: 0.004, bias: -0.7))
        XCTAssertNotNil(reloaded.info(forPath: "/b.mov", mtime: 5))
        XCTAssertNil(reloaded.info(forPath: "/b.mov", mtime: 5)?.exposure)
    }
}
