import Foundation

/// Serial off-main executor for sidecar writes. Spec 05 §8: one worker guarantees ordering.
public actor RatingWriter {
    public init() {}

    /// Writes the XMP sidecar and, for JPEG/video, the green Finder tag.
    /// Returns `false` when the sidecar write failed.
    public func write(url: URL, rating: Int, setGreenTag: Bool) -> Bool {
        let ok = XMPSidecar.write(url, rating: rating)
        if setGreenTag {
            FinderTags.setGreen(url, on: rating > 0)
        }
        return ok
    }

    /// Reads ratings for many files off the main thread, in batches. Spec 05 §7.
    public func readRatings(for urls: [URL]) -> [URL: Int] {
        var result: [URL: Int] = [:]
        result.reserveCapacity(urls.count)
        for url in urls {
            result[url] = XMPSidecar.read(url) ?? 0
        }
        return result
    }
}
