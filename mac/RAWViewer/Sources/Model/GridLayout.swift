import Foundation

/// Pure grid geometry, ported from `grid_view.py`. Spec 01 §8 and 02 §2.
public enum GridLayout {
    public static let cell: Int = 200
    public static let spacing: Int = 6

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

    public static func cellOrigin(index: Int, columns: Int, cell: Int = cell, spacing: Int = spacing) -> (x: Int, y: Int) {
        let row = index / columns
        let col = index % columns
        return (spacing + col * (cell + spacing), spacing + row * (cell + spacing))
    }

    public static func contentHeight(total: Int, columns: Int, cell: Int = cell, spacing: Int = spacing) -> Int {
        guard total > 0 else { return 0 }
        let rows = (total + columns - 1) / columns
        return spacing + rows * (cell + spacing)
    }

    /// Index under a point, or -1 when the point is past the last column / item.
    public static func index(atX x: Double, y: Double, columns: Int, total: Int,
                             cell: Int = cell, spacing: Int = spacing) -> Int {
        let stride = Double(cell + spacing)
        let col = Int((max(0.0, x - Double(spacing)) / stride).rounded(.down))
        let row = Int((max(0.0, y - Double(spacing)) / stride).rounded(.down))
        if col >= columns { return -1 }
        let idx = row * columns + col
        return (idx >= 0 && idx < total) ? idx : -1
    }

    /// Inclusive index range covering the vertical viewport `[top, bottom]`.
    /// Returns `(0, -1)` — an empty range — when there are no items.
    public static func visibleIndexRange(top: Int, bottom: Int, columns: Int, total: Int,
                                         cell: Int = cell, spacing: Int = spacing) -> (first: Int, last: Int) {
        guard total > 0 else { return (0, -1) }
        let stride = cell + spacing
        let firstRow = max(0, floorDiv(top - spacing, stride))
        let lastRow = max(0, floorDiv(bottom - spacing, stride))
        let first = min(total - 1, firstRow * columns)
        let last = min(total - 1, (lastRow + 1) * columns - 1)
        return (first, last)
    }

    /// Row move with the spec's clamp rules: clamp to the last item when moving down into a
    /// partial row, stay put when already on the first/last row. Spec 02 §2.
    public static func moveVertical(index: Int, columns: Int, total: Int, deltaRows: Int) -> Int {
        guard total > 0 else { return index }
        let target = index + deltaRows * columns
        if deltaRows > 0 {
            if index / columns >= (total - 1) / columns { return index }
            return min(target, total - 1)
        }
        return target < 0 ? index : target
    }
}
