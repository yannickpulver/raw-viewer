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
}
