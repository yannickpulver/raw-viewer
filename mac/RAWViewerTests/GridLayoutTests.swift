import XCTest
@testable import RAWViewer

/// Ported from `tests/test_grid_view.py`.
final class GridLayoutTests: XCTestCase {
    let cell = GridLayout.cell
    let spacing = GridLayout.spacing
    var stride: Int { cell + spacing }  // 206

    func testColumnsForWidth() {
        XCTAssertEqual(GridLayout.columns(forWidth: spacing + 4 * stride + 10), 4)
        XCTAssertEqual(GridLayout.columns(forWidth: spacing + 4 * stride), 4)
        XCTAssertEqual(GridLayout.columns(forWidth: 100), 1)
        XCTAssertEqual(GridLayout.columns(forWidth: 0), 1)
    }

    func testCellSizeForWidth() {
        XCTAssertEqual(GridLayout.cellSize(forWidth: spacing + 4 * stride, columns: 4), cell)
        XCTAssertEqual(GridLayout.cellSize(forWidth: 1000, columns: 4), (1000 - 5 * spacing) / 4)
        XCTAssertEqual(GridLayout.cellSize(forWidth: 150, columns: 1), cell)
        XCTAssertEqual(GridLayout.cellSize(forWidth: 0, columns: 1), cell)
    }

    func testCellOrigin() {
        XCTAssertTrue(GridLayout.cellOrigin(index: 0, columns: 4) == (spacing, spacing))
        XCTAssertTrue(GridLayout.cellOrigin(index: 3, columns: 4) == (spacing + 3 * stride, spacing))
        XCTAssertTrue(GridLayout.cellOrigin(index: 5, columns: 4) == (spacing + stride, spacing + stride))
    }

    func testContentHeight() {
        XCTAssertEqual(GridLayout.contentHeight(total: 0, columns: 4), 0)
        XCTAssertEqual(GridLayout.contentHeight(total: 1, columns: 4), spacing + stride)
        XCTAssertEqual(GridLayout.contentHeight(total: 4, columns: 4), spacing + stride)
        XCTAssertEqual(GridLayout.contentHeight(total: 5, columns: 4), spacing + 2 * stride)
        XCTAssertEqual(GridLayout.contentHeight(total: 9, columns: 4), spacing + 3 * stride)
    }

    func testIndexAt() {
        XCTAssertEqual(GridLayout.index(atX: 10, y: 10, columns: 4, total: 10), 0)
        XCTAssertEqual(GridLayout.index(atX: Double(spacing + stride + 10), y: 10, columns: 4, total: 10), 1)
        XCTAssertEqual(GridLayout.index(atX: 10, y: Double(spacing + stride + 10), columns: 4, total: 10), 4)
        // x beyond the last column
        XCTAssertEqual(GridLayout.index(atX: Double(spacing + 4 * stride + 10), y: 10, columns: 4, total: 10), -1)
        // y below the last occupied row
        XCTAssertEqual(GridLayout.index(atX: 10, y: Double(spacing + 2 * stride + 10), columns: 4, total: 5), -1)
        // index past the total
        XCTAssertEqual(GridLayout.index(atX: Double(spacing + stride + 10),
                                        y: Double(spacing + stride + 10), columns: 4, total: 5), -1)
    }

    func testVisibleIndexRange() {
        XCTAssertTrue(GridLayout.visibleIndexRange(top: 0, bottom: 400, columns: 4, total: 100) == (0, 7))
        XCTAssertTrue(GridLayout.visibleIndexRange(top: 0, bottom: 400, columns: 4, total: 5) == (0, 4))
        XCTAssertTrue(GridLayout.visibleIndexRange(top: spacing + stride,
                                                   bottom: spacing + stride + 400,
                                                   columns: 4, total: 100) == (4, 11))
        XCTAssertTrue(GridLayout.visibleIndexRange(top: 0, bottom: 400, columns: 4, total: 0) == (0, -1))
    }

    func testMoveVerticalDown() {
        XCTAssertEqual(GridLayout.moveVertical(index: 0, columns: 4, total: 10, deltaRows: 1), 4)
        XCTAssertEqual(GridLayout.moveVertical(index: 6, columns: 4, total: 10, deltaRows: 1), 9)
        XCTAssertEqual(GridLayout.moveVertical(index: 8, columns: 4, total: 10, deltaRows: 1), 8)
        XCTAssertEqual(GridLayout.moveVertical(index: 9, columns: 4, total: 10, deltaRows: 1), 9)
    }

    func testMoveVerticalUp() {
        XCTAssertEqual(GridLayout.moveVertical(index: 5, columns: 4, total: 10, deltaRows: -1), 1)
        XCTAssertEqual(GridLayout.moveVertical(index: 2, columns: 4, total: 10, deltaRows: -1), 2)
        XCTAssertEqual(GridLayout.moveVertical(index: 0, columns: 4, total: 0, deltaRows: 1), 0)
    }
}
