import Foundation

/// How the current list is presented. Spec 01 §2.
public enum DisplayMode: String, Sendable {
    case single
    case grid
}

/// Which compare pane has focus. Spec 01 §9.
public enum ComparePane: Sendable {
    case left
    case right
}

/// Per-view-mode state bundle. Spec 01 §2.
public struct ModeState: Sendable {
    public var allFiles: [MediaFile] = []
    public var files: [MediaFile] = []
    public var index: Int = 0
    public var ratingFilter: RatingFilter = .all
    public var folderFilter: String?
    public var excludedFolders: Set<String> = []
    public var newestFirst: Bool = false

    public init() {}

    public var currentFile: MediaFile? {
        guard index >= 0 && index < files.count else { return nil }
        return files[index]
    }

    /// Spec 01 §13: rating filter, then subfolder filter. The previously selected file keeps
    /// the selection if it survives, otherwise the selection resets to 0.
    public mutating func applyFilters(ratings: [URL: Int]) {
        let previous = currentFile
        files = allFiles.filter { file in
            let rating = ratings[file.url] ?? 0
            guard ratingFilter.matches(rating: rating) else { return false }
            if let folderFilter { return file.subfolder == folderFilter }
            return !excludedFolders.contains(file.subfolder)
        }
        if newestFirst { files.reverse() }
        if let previous, let kept = files.firstIndex(of: previous) {
            index = kept
        } else {
            index = 0
        }
    }

    /// `[(name, count)]` over the unfiltered list, sorted by name. Spec 03 §7.
    public var subfolderCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in allFiles { counts[file.subfolder, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
    }

    /// `All (N)` count: the unfiltered total minus everything in excluded subfolders. Spec 01 §4.
    public var allChipCount: Int {
        allFiles.reduce(0) { $0 + (excludedFolders.contains($1.subfolder) ? 0 : 1) }
    }
}
