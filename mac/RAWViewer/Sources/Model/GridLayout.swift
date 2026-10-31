import Foundation

/// Pure grid geometry, ported from `grid_view.py`. Spec 01 §8 and 02 §2.
public enum GridLayout {
    public static let cell: Int = 200
    public static let spacing: Int = 6
    /// Band above each scene for its caption while scenes are grouped.
    public static let sceneHeader: Int = 26

    /// Python's floor division, which differs from Swift's truncating `/` for negatives.
    @inline(__always)
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b > 0)
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    public static func columns(forWidth width: Int, cell: Int = cell, spacing: Int = spacing) -> Int {
        max(1, floorDiv(width - spacing, cell + spacing))
    }

    /// Cells stretch to fill the width but never shrink below the base cell size.
    public static func cellSize(forWidth width: Int, columns: Int, cell: Int = cell, spacing: Int = spacing) -> Int {
        guard columns > 0 else { return cell }
        return max(cell, floorDiv(width - (columns + 1) * spacing, columns))
    }
}

/// Where every grid cell sits. Each scene starts on a new row, with a `header` band above it
/// for its caption. One scene and no header is the plain grid of spec 01 §8, with the
/// clamping rules of spec 02 §2.
public struct GridGeometry {
    public let columns: Int
    public let cell: Int
    public let spacing: Int
    public let header: Int
    public let scenes: Scenes
    public let contentHeight: Int
    /// First file index and top edge of every row, top to bottom.
    private let rowStarts: [Int]
    private let rowTops: [Int]
    /// The row each scene opens with.
    private let sceneRows: [Int]

    public init(scenes: Scenes, columns: Int, cell: Int = GridLayout.cell,
                spacing: Int = GridLayout.spacing, header: Int = 0) {
        self.columns = max(1, columns)
        self.cell = cell
        self.spacing = spacing
        self.header = header
        self.scenes = scenes
        var starts: [Int] = [], tops: [Int] = [], sceneRows: [Int] = []
        var y = spacing
        for scene in 0..<scenes.count {
            y += header
            sceneRows.append(starts.count)
            let range = scenes.range(of: scene)
            for start in Swift.stride(from: range.lowerBound, to: range.upperBound, by: self.columns) {
                starts.append(start)
                tops.append(y)
                y += cell + spacing
            }
        }
        rowStarts = starts
        rowTops = tops
        self.sceneRows = sceneRows
        contentHeight = starts.isEmpty ? 0 : y
    }

    private var stride: Int { cell + spacing }

    private func rowEnd(_ row: Int) -> Int {
        row + 1 < rowStarts.count ? rowStarts[row + 1] : scenes.total
    }

    private func row(of index: Int) -> Int {
        lastRow(where: { rowStarts[$0] <= index })
    }

    /// The last row whose top is at or above `y`, or 0 when `y` is above every row.
    private func row(atY y: Int) -> Int {
        lastRow(where: { rowTops[$0] <= y })
    }

    /// Binary search for the last row matching a predicate that holds for a prefix of rows.
    private func lastRow(where matches: (Int) -> Bool) -> Int {
        var low = 0, high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if matches(mid) { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func cellOrigin(index: Int) -> (x: Int, y: Int) {
        let row = row(of: index)
        return (spacing + (index - rowStarts[row]) * stride, rowTops[row])
    }

    /// Top edge of a scene's caption band.
    public func headerTop(scene: Int) -> Int {
        rowTops[sceneRows[scene]] - header
    }

    /// Index under a point, or -1 when the point is past the last column / item of its row,
    /// or on a caption band.
    public func index(atX x: Double, y: Double) -> Int {
        guard !rowStarts.isEmpty else { return -1 }
        let col = Int((max(0.0, x - Double(spacing)) / Double(stride)).rounded(.down))
        if col >= columns { return -1 }
        let row = row(atY: Int(y.rounded(.down)))
        // A row owns its cells plus the spacing below; anything further down is the next
        // scene's caption, anything further up is the first scene's.
        if y >= Double(rowTops[row] + stride) || y < Double(rowTops[row] - spacing) { return -1 }
        let index = rowStarts[row] + col
        return index < rowEnd(row) ? index : -1
    }

    /// Inclusive index range covering the vertical viewport `[top, bottom]`.
    /// Returns `(0, -1)` — an empty range — when there are no items.
    public func visibleIndexRange(top: Int, bottom: Int) -> (first: Int, last: Int) {
        guard !rowStarts.isEmpty else { return (0, -1) }
        return (rowStarts[row(atY: top)], rowEnd(row(atY: bottom)) - 1)
    }

    /// Row move with the spec's clamp rules: clamp to the last item when moving into a
    /// shorter row, stay put when already on the first/last row. Spec 02 §2.
    public func moveVertical(index: Int, deltaRows: Int) -> Int {
        guard !rowStarts.isEmpty else { return index }
        let row = row(of: index)
        let target = row + deltaRows
        guard target >= 0, target < rowStarts.count else { return index }
        return min(rowStarts[target] + index - rowStarts[row], rowEnd(target) - 1)
    }
}

/// Filmstrip positions: one stride per file, plus a `gap` between scenes.
public struct StripLayout {
    public let scenes: Scenes
    public let stride: CGFloat
    public let gap: CGFloat

    public init(scenes: Scenes, stride: CGFloat, gap: CGFloat = 0) {
        self.scenes = scenes
        self.stride = stride
        self.gap = gap
    }

    public var width: CGFloat {
        CGFloat(scenes.total) * stride + CGFloat(max(0, scenes.count - 1)) * gap
    }

    public func x(of index: Int) -> CGFloat {
        CGFloat(index) * stride + CGFloat(scenes.scene(of: index)) * gap
    }

    /// The file whose slot holds `x`, the last one before a gap when `x` falls in it,
    /// clamped to the strip.
    private func slot(atX position: CGFloat) -> (index: Int, inGap: Bool) {
        var low = 0, high = scenes.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if x(of: scenes.starts[mid]) <= position { low = mid } else { high = mid - 1 }
        }
        let range = scenes.range(of: low)
        let offset = Int(floor((position - x(of: range.lowerBound)) / stride))
        let index = range.lowerBound + max(0, offset)
        return index < range.upperBound ? (index, false) : (range.upperBound - 1, true)
    }

    /// File under `x`, or -1 outside the strip or in a gap.
    public func index(atX x: CGFloat) -> Int {
        guard scenes.total > 0, x >= 0 else { return -1 }
        let slot = slot(atX: x)
        return slot.inGap ? -1 : slot.index
    }

    /// Files overlapping `[minX, maxX]`.
    public func range(minX: CGFloat, maxX: CGFloat) -> Range<Int> {
        guard scenes.total > 0, maxX >= 0 else { return 0..<0 }
        return slot(atX: max(0, minX)).index..<(slot(atX: maxX).index + 1)
    }
}

/// Rows and columns for the scene view: the split that shows `count` images of `aspect`
/// (width / height) the largest in a `width` x `height` area.
public enum TileLayout {
    public static func grid(count: Int, width: Double, height: Double, aspect: Double) -> (columns: Int, rows: Int) {
        guard count > 1, width > 0, height > 0, aspect > 0 else { return (1, 1) }
        var best = (columns: 1, rows: count), bestArea = 0.0
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let imageWidth = min(width / Double(columns), height / Double(rows) * aspect)
            let area = imageWidth * imageWidth / aspect
            if area > bestArea + 0.5 {
                best = (columns, rows)
                bestArea = area
            }
        }
        return best
    }
}
