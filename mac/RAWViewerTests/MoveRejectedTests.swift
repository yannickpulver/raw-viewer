import XCTest
@testable import RAWViewer

/// Ported from `tests/test_move_rejected.py`, plus a destination-collision test.
final class MoveRejectedTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rejected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ relative: String, contents: String = "") -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    func testFindSiblingsSameStem() {
        let raw = make("IMG_0001.CR3")
        let jpg = make("IMG_0001.jpg")
        let xmp = make("IMG_0001.xmp")
        make("IMG_0002.CR3")
        let siblings = Set(MoveRejected.findSiblings(of: raw).map(\.lastPathComponent))
        XCTAssertEqual(siblings, Set([jpg, xmp].map(\.lastPathComponent)))
    }

    func testCollectMoveSetDedupesPairs() {
        let raw = make("a.cr3")
        let jpg = make("a.jpg")
        let result = MoveRejected.collectMoveSet([raw, jpg]).map(\.lastPathComponent).sorted()
        XCTAssertEqual(result, [raw, jpg].map(\.lastPathComponent).sorted())
    }

    func testMovePreservesSubpath() {
        let file = make("day1/IMG_0001.cr3")
        let result = MoveRejected.moveToRejected([file], root: root)
        XCTAssertEqual(result.moved, 1)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("_rejected/day1/IMG_0001.cr3").path))
    }

    func testMoveStopsOnMissingFile() {
        let a = make("a.cr3")
        let ghost = root.appendingPathComponent("ghost.cr3")
        let b = make("b.cr3")
        let result = MoveRejected.moveToRejected([a, ghost, b], root: root)
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(result.error?.contains("ghost.cr3") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "untouched after an error")
    }

    /// Deliberate deviation: a colliding destination gets a ` 2` suffix instead of being overwritten.
    func testCollisionGetsNumberedSuffix() throws {
        let first = make("IMG_0001.cr3", contents: "first")
        XCTAssertEqual(MoveRejected.moveToRejected([first], root: root).moved, 1)
        let second = make("IMG_0001.cr3", contents: "second")
        XCTAssertEqual(MoveRejected.moveToRejected([second], root: root).moved, 1)

        let original = root.appendingPathComponent("_rejected/IMG_0001.cr3")
        let renamed = root.appendingPathComponent("_rejected/IMG_0001 2.cr3")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "second")
    }

    func testScannerSkipsRejectedDirectory() async throws {
        make("keep.cr3")
        make("_rejected/gone.cr3")
        let result = try await FolderScanner().scan(root: root)
        XCTAssertEqual(result.raw.map(\.name), ["keep.cr3"])
    }
}
