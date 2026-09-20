import XCTest
@testable import RAWViewer

/// Mac app addition (no Python-app equivalent). Modelled on `MoveRejectedTests`.
final class MoveFilesTests: XCTestCase {
    private var root: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("move-shown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        destination = root.appendingPathComponent("picked", isDirectory: true)
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

    func testFilesFromTwoSubfoldersLandFlat() {
        let a = make("day1/IMG_0001.cr3")
        let b = make("day2/IMG_0002.cr3")
        let result = MoveFiles.moveToFolder([a, b], destination: destination)
        XCTAssertEqual(result.moved, 2)
        XCTAssertNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("IMG_0001.cr3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("IMG_0002.cr3").path))
    }

    func testSidecarMovesAlong() {
        let raw = make("IMG_0001.cr3")
        make("IMG_0001.xmp", contents: "rating")
        let result = MoveFiles.moveToFolder([raw], destination: destination)
        XCTAssertEqual(result.moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("IMG_0001.xmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("IMG_0001.xmp").path))
    }

    func testJPEGSiblingNotInListStays() {
        let raw = make("IMG_0001.cr3")
        let jpg = make("IMG_0001.jpg")
        let result = MoveFiles.moveToFolder([raw], destination: destination)
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpg.path), "sibling not in the moved list is untouched")
    }

    /// Collision at the destination renumbers the media file, and the sidecar gets the same
    /// renumbered stem so the rating stays attached.
    func testCollisionNumbersMediaAndSidecarIdentically() {
        make("first/IMG_0001.cr3", contents: "first")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.appendingPathComponent("IMG_0001.cr3").path,
                                       contents: Data("existing".utf8))

        let raw = make("second/IMG_0001.cr3", contents: "second")
        make("second/IMG_0001.xmp", contents: "rating")
        let result = MoveFiles.moveToFolder([raw], destination: destination)
        XCTAssertEqual(result.moved, 1)
        XCTAssertNil(result.error)

        let media = destination.appendingPathComponent("IMG_0001 2.cr3")
        let sidecar = destination.appendingPathComponent("IMG_0001 2.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testFileAlreadyInDestinationIsSkipped() {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let already = destination.appendingPathComponent("IMG_0009.cr3")
        FileManager.default.createFile(atPath: already.path, contents: Data("x".utf8))

        let result = MoveFiles.moveToFolder([already], destination: destination)
        XCTAssertEqual(result.moved, 0)
        XCTAssertNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: already.path))
    }

    func testRawJPEGPairSharesOneSidecarMove() {
        let raw = make("IMG_0001.cr3")
        let jpg = make("IMG_0001.jpg")
        make("IMG_0001.xmp", contents: "rating")
        let result = MoveFiles.moveToFolder([raw, jpg], destination: destination)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("IMG_0001.xmp").path))
    }
}
