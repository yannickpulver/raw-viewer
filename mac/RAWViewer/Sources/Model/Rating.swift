import Foundation

/// Rating helpers. Values are plain `Int` in `-1...5`; `-1` is rejected, `0` unrated. Spec 05 §1.
public enum Rating {
    public static let rejected = -1
    public static let unrated = 0
    public static let range: ClosedRange<Int> = -1...5

    public static func clamp(_ value: Int) -> Int {
        min(5, max(-1, value))
    }

    /// Info-line stars rendering. Spec 01 §4.
    public static func stars(_ rating: Int) -> String {
        if rating == -1 { return "✕ rejected" }
        let r = max(0, min(5, rating))
        return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
    }
}

/// 0 = all, 1...5 = minimum rating, -1 = rejected only, -2 = unrated only. Spec 01 §13.
public struct RatingFilter: Equatable, Sendable {
    public var value: Int

    public init(_ value: Int = 0) { self.value = value }

    public static let all = RatingFilter(0)
    public static let rejectedOnly = RatingFilter(-1)
    /// Mac app addition: exactly `rating == 0`, i.e. never rated (and not rejected).
    public static let unratedValue = -2
    public static let unratedOnly = RatingFilter(unratedValue)

    public var isActive: Bool { value != 0 }

    /// Spec 01 §13: `-1` matches only rejected; otherwise `rating >= value`.
    /// Consequence (kept as shipped): the `All` bucket hides rejected files.
    /// Mac app addition: `-2` matches only unrated (`rating == 0`).
    public func matches(rating: Int) -> Bool {
        if value == -1 { return rating == -1 }
        if value == RatingFilter.unratedValue { return rating == 0 }
        return rating >= value
    }

    /// Suffix used by the position counter and the filter banner. Spec 01 §4.
    public var badgeText: String? {
        if value == 0 { return nil }
        if value == -1 { return "✕" }
        if value == RatingFilter.unratedValue { return "0★" }
        return "≥\(value)★"
    }
}
