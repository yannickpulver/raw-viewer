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

/// How the timeline is ordered. Mac app addition — no Python-app equivalent.
public enum SortOrder: String, Sendable {
    case oldestFirst
    case newestFirst
    /// Most open-eyed, sharp faces first (`FaceIndex.scores`).
    case bestFaces
}

/// Per-view-mode state bundle. Spec 01 §2.
public struct ModeState: Sendable {
    public var allFiles: [MediaFile] = []
    public var files: [MediaFile] = []
    public var index: Int = 0
    public var ratingFilter: RatingFilter = .all
    public var folderFilter: String?
    public var excludedFolders: Set<String> = []
    public var sortOrder: SortOrder = .oldestFirst

    /// Multi-select. Mac app addition — no Python-app equivalent. `index` stays the single
    /// current file; `selectedURLs` is the (possibly larger) set drawn with the amber border.
    public var selectedURLs: Set<URL> = []
    /// The file shift-click extends from, stored by URL rather than index so it survives
    /// `applyFilters` reordering `files` (e.g. newest-first reversing the whole list) — an
    /// index alone would silently point at the wrong file after a reversal.
    private var anchorURL: URL?

    public init() {}

    /// `anchorURL`'s current position in `files`, or `index` when the anchor was never set or
    /// no longer survives the filter.
    public var anchorIndex: Int {
        if let anchorURL, let found = files.firstIndex(where: { $0.url == anchorURL }) {
            return found
        }
        return files.isEmpty ? 0 : min(max(index, 0), files.count - 1)
    }

    public var currentFile: MediaFile? {
        guard index >= 0 && index < files.count else { return nil }
        return files[index]
    }

    /// Spec 01 §13: rating filter, then subfolder filter, then `sortOrder`. The previously
    /// selected file keeps the selection if it survives, otherwise the selection resets to 0.
    public mutating func applyFilters(ratings: [URL: Int], faceScores: [URL: Float] = [:]) {
        let previous = currentFile
        files = allFiles.filter { file in
            let rating = ratings[file.url] ?? 0
            guard ratingFilter.matches(rating: rating) else { return false }
            if let folderFilter { return file.subfolder == folderFilter }
            return !excludedFolders.contains(file.subfolder)
        }
        switch sortOrder {
        case .oldestFirst:
            break
        case .newestFirst:
            files.reverse()
        case .bestFaces:
            // Scored files first, then those without faces (0), then those not analysed yet.
            // `sorted` is not guaranteed stable, so ties fall back to the date order by position.
            files = files.enumerated().sorted { lhs, rhs in
                let left = faceScores[lhs.element.url] ?? -1
                let right = faceScores[rhs.element.url] ?? -1
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        if let previous, let kept = files.firstIndex(of: previous) {
            index = kept
        } else {
            index = 0
        }
        pruneSelection()
    }

    /// Drops selected URLs that no longer survive the filter. `anchorIndex` re-derives itself
    /// from `anchorURL` (or falls back to `index`), so it needs no clamping here. An empty
    /// result falls back to the current file, so there is always a selection.
    private mutating func pruneSelection() {
        let surviving = Set(files.map(\.url))
        selectedURLs.formIntersection(surviving)
        if selectedURLs.isEmpty, let current = currentFile {
            selectedURLs = [current.url]
        }
    }

    // MARK: - Multi-select mutators

    /// Plain click: selection collapses to the clicked file, anchor moves with it.
    public mutating func selectOnly(index: Int) {
        guard index >= 0, index < files.count else { return }
        selectedURLs = [files[index].url]
        anchorURL = files[index].url
    }

    /// Shift-click: selection becomes every file between the anchor and `index`, inclusive.
    /// The anchor itself does not move.
    public mutating func extendSelection(to index: Int) {
        guard index >= 0, index < files.count else { return }
        let lower = min(anchorIndex, index)
        let upper = max(anchorIndex, index)
        selectedURLs = Set(files[lower...upper].map(\.url))
    }

    /// Cmd-click: adds or removes just that file, anchor moves to it.
    public mutating func toggleSelection(at index: Int) {
        guard index >= 0, index < files.count else { return }
        let url = files[index].url
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
        } else {
            selectedURLs.insert(url)
        }
        anchorURL = url
    }

    /// `Cmd+A`: selects every file currently in the timeline. The anchor moves to the current
    /// file, matching Finder.
    public mutating func selectAll() {
        selectedURLs = Set(files.map(\.url))
        anchorURL = currentFile?.url
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
