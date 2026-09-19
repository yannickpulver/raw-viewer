import Foundation

/// Green Finder tag for JPEG and video culls. Spec 05 §9.
public enum FinderTags {
    public static let green = "Green"

    private static func tags(of url: URL) -> [String] {
        guard let values = try? url.resourceValues(forKeys: [.tagNamesKey]),
              let names = values.tagNames else { return [] }
        return names
    }

    public static func hasGreen(_ url: URL) -> Bool {
        tags(of: url).contains { $0.localizedCaseInsensitiveContains(green) }
    }

    /// Adds or removes the green tag. Touches the file only when a change is needed.
    @discardableResult
    public static func setGreen(_ url: URL, on: Bool) -> Bool {
        let current = tags(of: url)
        let has = current.contains { $0.localizedCaseInsensitiveContains(green) }
        guard has != on else { return true }

        var updated = current.filter { !$0.localizedCaseInsensitiveContains(green) }
        if on { updated.append(green) }

        do {
            // The `URLResourceValues.tagNames` setter is macOS 26+, so go through NSURL,
            // which has carried the same key since 10.9.
            try (url as NSURL).setResourceValue(updated as NSArray, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }
}
