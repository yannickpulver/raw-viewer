import XCTest
@testable import RAWViewer

final class RatingCountsTests: XCTestCase {
    private func file(_ name: String, subfolder: String = "") -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/root/\(subfolder)/\(name)"), kind: .raw,
                  captureDate: Date(timeIntervalSince1970: 1_700_000_000), subfolder: subfolder)
    }

    private let values = Library.ratingFilterValues

    /// Ratings: unrated, unrated, 1, 3, 5, rejected.
    private func sample() -> (ModeState, [URL: Int]) {
        var state = ModeState()
        state.allFiles = ["a", "b", "c", "d", "e", "f"].map { file("\($0).raf", subfolder: $0 < "d" ? "A" : "B") }
        let ratings = [state.allFiles[2].url: 1, state.allFiles[3].url: 3,
                       state.allFiles[4].url: 5, state.allFiles[5].url: -1]
        return (state, ratings)
    }

    func testCountsMatchWhatEachRatingFilterKeeps() {
        let (state, ratings) = sample()
        let counts = state.ratingCounts(values: values, ratings: ratings)
        // `All` hides rejected files, as the filter does.
        XCTAssertEqual(counts[0], 5)
        XCTAssertEqual(counts[RatingFilter.unratedValue], 2)
        XCTAssertEqual(counts[1], 3)
        XCTAssertEqual(counts[2], 2)
        XCTAssertEqual(counts[3], 2)
        XCTAssertEqual(counts[4], 1)
        XCTAssertEqual(counts[5], 1)
        XCTAssertEqual(counts[-1], 1)

        for value in values {
            var filtered = state
            filtered.ratingFilter = RatingFilter(value)
            filtered.applyFilters(ratings: ratings)
            XCTAssertEqual(filtered.files.count, counts[value], "filter \(value)")
        }
    }

    func testCountsIgnoreTheActiveRatingFilter() {
        var (state, ratings) = sample()
        state.ratingFilter = RatingFilter(5)
        state.applyFilters(ratings: ratings)
        XCTAssertEqual(state.ratingCounts(values: values, ratings: ratings)[0], 5)
    }

    func testCountsFollowFolderAndUnviewedFilters() {
        var (state, ratings) = sample()
        state.folderFilter = "B"
        XCTAssertEqual(state.ratingCounts(values: values, ratings: ratings)[0], 2)
        XCTAssertEqual(state.ratingCounts(values: values, ratings: ratings)[-1], 1)

        state.folderFilter = nil
        state.unviewedOnly = true
        let viewed: Set<String> = [ViewedStore.key(state.allFiles[0].url), ViewedStore.key(state.allFiles[4].url)]
        let counts = state.ratingCounts(values: values, ratings: ratings, viewedBefore: viewed)
        XCTAssertEqual(counts[0], 3)
        XCTAssertEqual(counts[RatingFilter.unratedValue], 1)
        XCTAssertEqual(counts[5], 0)
        ratings.removeAll()
        XCTAssertEqual(state.ratingCounts(values: values, ratings: ratings, viewedBefore: viewed)[0], 4)
    }
}
