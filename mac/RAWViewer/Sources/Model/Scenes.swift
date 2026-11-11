import Foundation

/// A timeline cut into scenes: runs of consecutive files shot at most `maxGap` apart.
/// Mac app addition, no Python-app equivalent. Measured on 13k rated images, capture time
/// alone groups the same scenes as capture time plus Vision's image fingerprint (adjusted
/// Rand index 0.90), so nothing here needs to look at pixels.
public struct Scenes: Equatable, Sendable {
    public static let maxGap: TimeInterval = 60

    /// Index of each scene's first file, ascending, starting at 0. Empty when there are no files.
    public let starts: [Int]
    public let total: Int

    /// The whole timeline as one scene: what every layout draws while grouping is off.
    public init(total: Int) {
        self.total = total
        self.starts = total > 0 ? [0] : []
    }

    /// Cuts wherever two neighbours are more than `maxGap` apart. Works on either date order,
    /// so newest-first gets the same scenes, reversed.
    public init(files: [MediaFile], maxGap: TimeInterval = Scenes.maxGap) {
        total = files.count
        guard !files.isEmpty else {
            starts = []
            return
        }
        var starts = [0]
        for index in files.indices.dropFirst()
        where abs(files[index].captureDate.timeIntervalSince(files[index - 1].captureDate)) > maxGap {
            starts.append(index)
        }
        self.starts = starts
    }

    /// Cuts wherever the calendar day changes: the grid's day sections. Either date order.
    public init(days files: [MediaFile], calendar: Calendar = .current) {
        total = files.count
        guard !files.isEmpty else {
            starts = []
            return
        }
        var starts = [0]
        for index in files.indices.dropFirst()
        where !calendar.isDate(files[index].captureDate, inSameDayAs: files[index - 1].captureDate) {
            starts.append(index)
        }
        self.starts = starts
    }

    /// Every cut of both, so a scene running past midnight splits at the day.
    public init(merging first: Scenes, _ second: Scenes) {
        total = max(first.total, second.total)
        starts = Array(Set(first.starts).union(second.starts)).sorted()
    }

    public var count: Int { starts.count }

    /// Whether a group starts at `index`.
    public func starts(at index: Int) -> Bool {
        guard !starts.isEmpty else { return false }
        return starts[scene(of: index)] == index
    }

    /// The scene holding `index`, by binary search over `starts`.
    public func scene(of index: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func range(of scene: Int) -> Range<Int> {
        starts[scene]..<(scene + 1 < starts.count ? starts[scene + 1] : total)
    }
}
