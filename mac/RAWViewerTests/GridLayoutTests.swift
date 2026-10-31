import XCTest
@testable import RAWViewer

/// Ported from `tests/test_grid_view.py`, on `GridGeometry` with one scene and no header,
/// which is the plain grid.
final class GridLayoutTests: XCTestCase {
    let cell = GridLayout.cell
    let spacing = GridLayout.spacing
    var stride: Int { cell + spacing }  // 206

    private func plain(_ total: Int, columns: Int = 4) -> GridGeometry {
        GridGeometry(scenes: Scenes(total: total), columns: columns)
    }

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
        XCTAssertTrue(plain(10).cellOrigin(index: 0) == (spacing, spacing))
        XCTAssertTrue(plain(10).cellOrigin(index: 3) == (spacing + 3 * stride, spacing))
        XCTAssertTrue(plain(10).cellOrigin(index: 5) == (spacing + stride, spacing + stride))
    }

    func testContentHeight() {
        XCTAssertEqual(plain(0).contentHeight, 0)
        XCTAssertEqual(plain(1).contentHeight, spacing + stride)
        XCTAssertEqual(plain(4).contentHeight, spacing + stride)
        XCTAssertEqual(plain(5).contentHeight, spacing + 2 * stride)
        XCTAssertEqual(plain(9).contentHeight, spacing + 3 * stride)
    }

    func testIndexAt() {
        XCTAssertEqual(plain(10).index(atX: 10, y: 10), 0)
        XCTAssertEqual(plain(10).index(atX: Double(spacing + stride + 10), y: 10), 1)
        XCTAssertEqual(plain(10).index(atX: 10, y: Double(spacing + stride + 10)), 4)
        // x beyond the last column
        XCTAssertEqual(plain(10).index(atX: Double(spacing + 4 * stride + 10), y: 10), -1)
        // y below the last occupied row
        XCTAssertEqual(plain(5).index(atX: 10, y: Double(spacing + 2 * stride + 10)), -1)
        // index past the total
        XCTAssertEqual(plain(5).index(atX: Double(spacing + stride + 10), y: Double(spacing + stride + 10)), -1)
        // the top spacing belongs to the first row, as in the Python grid
        XCTAssertEqual(plain(5).index(atX: 10, y: 2), 0)
    }

    func testVisibleIndexRange() {
        XCTAssertTrue(plain(100).visibleIndexRange(top: 0, bottom: 400) == (0, 7))
        XCTAssertTrue(plain(5).visibleIndexRange(top: 0, bottom: 400) == (0, 4))
        XCTAssertTrue(plain(100).visibleIndexRange(top: spacing + stride, bottom: spacing + stride + 400) == (4, 11))
        XCTAssertTrue(plain(0).visibleIndexRange(top: 0, bottom: 400) == (0, -1))
    }

    func testMoveVerticalDown() {
        XCTAssertEqual(plain(10).moveVertical(index: 0, deltaRows: 1), 4)
        XCTAssertEqual(plain(10).moveVertical(index: 6, deltaRows: 1), 9)
        XCTAssertEqual(plain(10).moveVertical(index: 8, deltaRows: 1), 8)
        XCTAssertEqual(plain(10).moveVertical(index: 9, deltaRows: 1), 9)
    }

    func testMoveVerticalUp() {
        XCTAssertEqual(plain(10).moveVertical(index: 5, deltaRows: -1), 1)
        XCTAssertEqual(plain(10).moveVertical(index: 2, deltaRows: -1), 2)
        XCTAssertEqual(plain(0).moveVertical(index: 0, deltaRows: 1), 0)
    }

    // MARK: - Scenes

    let header = GridLayout.sceneHeader

    /// Scenes of 6 and 3 files, 4 columns: rows start at 0, 4 (scene 0) and 6 (scene 1).
    private var grouped: GridGeometry {
        GridGeometry(scenes: SceneFixtures.scenes([6, 3]), columns: 4, header: header)
    }

    func testScenesStartOnANewRowBelowTheirHeader() {
        XCTAssertTrue(grouped.cellOrigin(index: 0) == (spacing, spacing + header))
        XCTAssertTrue(grouped.cellOrigin(index: 5) == (spacing + stride, spacing + header + stride))
        XCTAssertTrue(grouped.cellOrigin(index: 6) == (spacing, spacing + 2 * header + 2 * stride))
        XCTAssertEqual(grouped.headerTop(scene: 0), spacing)
        XCTAssertEqual(grouped.headerTop(scene: 1), spacing + header + 2 * stride)
        XCTAssertEqual(grouped.contentHeight, spacing + 2 * header + 3 * stride)
    }

    func testIndexAtSkipsHeadersAndShortRows() {
        let sceneOneTop = Double(spacing + 2 * header + 2 * stride)
        XCTAssertEqual(grouped.index(atX: 10, y: sceneOneTop + 10), 6)
        XCTAssertEqual(grouped.index(atX: 10, y: sceneOneTop - 10), -1)   // scene 1's header
        XCTAssertEqual(grouped.index(atX: 10, y: 10), -1)                 // scene 0's header
        XCTAssertEqual(grouped.index(atX: Double(spacing + 2 * stride + 10), y: Double(spacing + header + stride + 10)), -1)
        XCTAssertEqual(grouped.index(atX: Double(spacing + 3 * stride + 10), y: sceneOneTop + 10), -1)
    }

    func testVisibleRangeCoversWholeRows() {
        XCTAssertTrue(grouped.visibleIndexRange(top: 0, bottom: spacing + header + stride) == (0, 5))
        XCTAssertTrue(grouped.visibleIndexRange(top: 0, bottom: 10_000) == (0, 8))
    }

    func testMoveVerticalCrossesScenesAndClampsToShortRows() {
        XCTAssertEqual(grouped.moveVertical(index: 5, deltaRows: 1), 7)
        XCTAssertEqual(grouped.moveVertical(index: 7, deltaRows: -1), 5)
        XCTAssertEqual(grouped.moveVertical(index: 3, deltaRows: 1), 5)
        XCTAssertEqual(grouped.moveVertical(index: 8, deltaRows: -1), 5)
        XCTAssertEqual(grouped.moveVertical(index: 8, deltaRows: 1), 8)
    }

    // MARK: - Filmstrip

    /// Scenes of 2 and 3 files, 84 px stride, 16 px gap: scene 1 starts at 2 * 84 + 16 = 184.
    private let strip = StripLayout(scenes: SceneFixtures.scenes([2, 3]), stride: 84, gap: 16)

    func testStripPositionsAddTheGap() {
        XCTAssertEqual(strip.x(of: 1), 84)
        XCTAssertEqual(strip.x(of: 2), 184)
        XCTAssertEqual(strip.x(of: 4), 352)
        XCTAssertEqual(strip.width, 5 * 84 + 16)
    }

    func testStripIndexAt() {
        XCTAssertEqual(strip.index(atX: 10), 0)
        XCTAssertEqual(strip.index(atX: 170), -1)   // the gap
        XCTAssertEqual(strip.index(atX: 185), 2)
        XCTAssertEqual(strip.index(atX: 500), -1)   // past the end
        XCTAssertEqual(strip.index(atX: -5), -1)
    }

    func testStripRange() {
        XCTAssertEqual(strip.range(minX: 0, maxX: 200), 0..<3)
        XCTAssertEqual(strip.range(minX: 170, maxX: 1000), 1..<5)
        XCTAssertEqual(StripLayout(scenes: Scenes(total: 0), stride: 84).range(minX: 0, maxX: 100), 0..<0)
    }

    func testPlainStripMatchesFixedStride() {
        let plain = StripLayout(scenes: Scenes(total: 10), stride: 84)
        XCTAssertEqual(plain.x(of: 7), 7 * 84)
        XCTAssertEqual(plain.index(atX: 7 * 84 + 3), 7)
        XCTAssertEqual(plain.width, 840)
    }
}

/// Files whose capture times make scenes of the given sizes: frames 1 s apart, scenes 2 min apart.
enum SceneFixtures {
    static func files(_ sizes: [Int], start: TimeInterval = 1_700_000_000) -> [MediaFile] {
        var files: [MediaFile] = []
        var time = start
        for (scene, size) in sizes.enumerated() {
            for frame in 0..<size {
                files.append(MediaFile(url: URL(fileURLWithPath: "/shoot/s\(scene)_\(frame).raf"), kind: .raw,
                                       captureDate: Date(timeIntervalSince1970: time), subfolder: ""))
                time += 1
            }
            time += 120
        }
        return files
    }

    static func scenes(_ sizes: [Int]) -> Scenes { Scenes(files: files(sizes)) }
}
