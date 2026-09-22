import XCTest
@testable import RAWViewer

final class ModeStateTests: XCTestCase {
    private func file(_ name: String, subfolder: String, offset: TimeInterval = 0) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/root/\(subfolder)/\(name)"),
                  kind: .raw,
                  captureDate: Date(timeIntervalSince1970: 1_700_000_000 + offset),
                  subfolder: subfolder)
    }

    private func sampleState() -> ModeState {
        var state = ModeState()
        state.allFiles = [
            file("a.cr3", subfolder: "A", offset: 0),
            file("b.cr3", subfolder: "A", offset: 1),
            file("c.cr3", subfolder: "B", offset: 2),
            file("d.cr3", subfolder: "B", offset: 3),
        ]
        return state
    }

    /// Spec 01 §13: the `All` bucket (`0`) hides rejected files — kept as shipped.
    func testAllFilterHidesRejected() {
        var state = sampleState()
        let ratings = [state.allFiles[1].url: -1]
        state.applyFilters(ratings: ratings)
        XCTAssertEqual(state.files.map(\.name), ["a.cr3", "c.cr3", "d.cr3"])
    }

    func testRejectedOnlyFilter() {
        var state = sampleState()
        state.ratingFilter = .rejectedOnly
        state.applyFilters(ratings: [state.allFiles[1].url: -1, state.allFiles[2].url: 3])
        XCTAssertEqual(state.files.map(\.name), ["b.cr3"])
    }

    func testMinimumRatingFilter() {
        var state = sampleState()
        state.ratingFilter = RatingFilter(3)
        state.applyFilters(ratings: [
            state.allFiles[0].url: 2,
            state.allFiles[1].url: 3,
            state.allFiles[2].url: 5,
        ])
        XCTAssertEqual(state.files.map(\.name), ["b.cr3", "c.cr3"])
    }

    func testFolderFilterWinsOverExclusions() {
        var state = sampleState()
        state.excludedFolders = ["B"]
        state.folderFilter = "B"
        state.applyFilters(ratings: [:])
        XCTAssertEqual(state.files.map(\.name), ["c.cr3", "d.cr3"])
    }

    func testExclusionsApplyOnlyWithoutFolderFilter() {
        var state = sampleState()
        state.excludedFolders = ["B"]
        state.applyFilters(ratings: [:])
        XCTAssertEqual(state.files.map(\.name), ["a.cr3", "b.cr3"])
        XCTAssertEqual(state.allChipCount, 2)
    }

    func testSelectionSurvivesFilterWhenFileRemains() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.index = 2  // c.cr3
        state.ratingFilter = RatingFilter(1)
        state.applyFilters(ratings: [state.allFiles[2].url: 4, state.allFiles[3].url: 4])
        XCTAssertEqual(state.currentFile?.name, "c.cr3")
        XCTAssertEqual(state.index, 0)
    }

    func testSelectionResetsWhenFileFilteredOut() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.index = 3
        state.ratingFilter = RatingFilter(1)
        state.applyFilters(ratings: [state.allFiles[0].url: 5])
        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.currentFile?.name, "a.cr3")
    }

    func testSubfolderCountsSortedByName() {
        var state = sampleState()
        let counts = state.subfolderCounts
        XCTAssertEqual(counts.map(\.name), ["A", "B"])
        XCTAssertEqual(counts.map(\.count), [2, 2])
        state.excludedFolders = ["A"]
        XCTAssertEqual(state.allChipCount, 2)
    }

    /// Mac app addition: the "unrated only" bucket. Spec 01 §13.
    func testUnratedOnlyFilter() {
        var state = sampleState()
        state.ratingFilter = RatingFilter(RatingFilter.unratedValue)
        state.applyFilters(ratings: [
            state.allFiles[1].url: -1,
            state.allFiles[2].url: 3,
        ])
        XCTAssertEqual(state.files.map(\.name), ["a.cr3", "d.cr3"])
    }

    func testRatingFilterBadgeText() {
        XCTAssertNil(RatingFilter(0).badgeText)
        XCTAssertEqual(RatingFilter(3).badgeText, "≥3★")
        XCTAssertEqual(RatingFilter(-1).badgeText, "✕")
        XCTAssertEqual(RatingFilter(RatingFilter.unratedValue).badgeText, "0★")
    }

    /// Mac app addition: newest-first reverses the timeline and keeps the same file selected.
    func testNewestFirstReversesOrderAndKeepsSelection() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.index = 1  // b.cr3
        state.newestFirst = true
        state.applyFilters(ratings: [:])
        XCTAssertEqual(state.files.map(\.name), ["d.cr3", "c.cr3", "b.cr3", "a.cr3"])
        XCTAssertEqual(state.currentFile?.name, "b.cr3")
        XCTAssertEqual(state.index, 2)
    }

    func testRatingClamp() {
        XCTAssertEqual(Rating.clamp(-5), -1)
        XCTAssertEqual(Rating.clamp(9), 5)
        XCTAssertEqual(Rating.clamp(3), 3)
    }

    // MARK: - Multi-select

    func testSelectOnlySetsSelectionAndAnchor() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 2)
        XCTAssertEqual(state.selectedURLs, [state.files[2].url])
        XCTAssertEqual(state.anchorIndex, 2)
    }

    func testExtendSelectionCoversRangeFromAnchor() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 1)
        state.extendSelection(to: 3)
        XCTAssertEqual(state.selectedURLs, Set(state.files[1...3].map(\.url)))
        XCTAssertEqual(state.anchorIndex, 1, "the anchor does not move")

        // Extending backwards past the anchor still covers the inclusive range.
        state.extendSelection(to: 0)
        XCTAssertEqual(state.selectedURLs, Set(state.files[0...1].map(\.url)))
        XCTAssertEqual(state.anchorIndex, 1)
    }

    func testToggleSelectionAddsAndRemoves() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 0)
        state.toggleSelection(at: 2)
        XCTAssertEqual(state.selectedURLs, Set(state.files[[0, 2]].map(\.url)))
        XCTAssertEqual(state.anchorIndex, 2)

        state.toggleSelection(at: 0)
        XCTAssertEqual(state.selectedURLs, [state.files[2].url])
    }

    func testSelectAllSelectsEveryFile() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 3)
        state.selectAll()
        XCTAssertEqual(state.selectedURLs, Set(state.files.map(\.url)))
        XCTAssertEqual(state.anchorIndex, state.index, "select-all anchors at the current file, like Finder")
    }

    /// The anchor is stored by URL, not index, so it survives `applyFilters` reordering
    /// `files` — a raw index would silently point at the mirrored file after a reversal.
    func testAnchorSurvivesNewestFirstReversal() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 1)   // b.cr3, the anchor
        XCTAssertEqual(state.anchorIndex, 1)

        state.newestFirst = true
        state.applyFilters(ratings: [:])
        // Reversed order: d, c, b, a — b.cr3 is now at index 2.
        XCTAssertEqual(state.files.map(\.name), ["d.cr3", "c.cr3", "b.cr3", "a.cr3"])
        XCTAssertEqual(state.anchorIndex, 2, "the anchor follows b.cr3, not the old numeric index")

        // A shift-click now extends from b.cr3's new position, not the stale index 1.
        state.extendSelection(to: 0)
        XCTAssertEqual(state.selectedURLs, Set(state.files[0...2].map(\.url)))
    }

    /// Spec: `applyFilters` prunes the selection to survivors and falls back to the current
    /// file when nothing survives.
    func testApplyFiltersPrunesSelectionToSurvivors() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 0)
        state.toggleSelection(at: 2)   // a.cr3, c.cr3
        XCTAssertEqual(state.selectedURLs.count, 2)

        state.ratingFilter = RatingFilter(3)
        state.applyFilters(ratings: [state.allFiles[2].url: 3])   // only c.cr3 survives
        XCTAssertEqual(state.selectedURLs, [state.allFiles[2].url])
    }

    func testApplyFiltersFallsBackToCurrentFileWhenSelectionIsWipedOut() {
        var state = sampleState()
        state.applyFilters(ratings: [:])
        state.selectOnly(index: 1)   // b.cr3
        state.ratingFilter = RatingFilter(3)
        state.applyFilters(ratings: [state.allFiles[2].url: 3])   // b.cr3 filtered out
        XCTAssertEqual(state.currentFile?.name, "c.cr3")
        XCTAssertEqual(state.selectedURLs, Set([state.currentFile?.url].compactMap { $0 }))
    }
}

private extension Array {
    subscript(indices: [Int]) -> [Element] { indices.map { self[$0] } }
}
