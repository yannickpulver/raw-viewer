import CoreGraphics
import XCTest
@testable import RAWViewer

final class DiskThumbnailCacheTests: XCTestCase {
    private var directory: URL!
    private var sourceDirectory: URL!
    private var cache: DiskThumbnailCache!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true)
        directory = base.appendingPathComponent("cache", isDirectory: true)
        sourceDirectory = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        cache = DiskThumbnailCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func makeImage(width: Int = 16, height: Int = 16) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeSource(_ name: String) -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    func testDirectoryIsCreated() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSetThenGet() {
        let source = makeSource("a.cr3")
        XCTAssertNil(cache.get(source, size: 80))
        XCTAssertTrue(cache.set(makeImage(), for: source, size: 80))
        let loaded = cache.get(source, size: 80)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.width, 16)
    }

    func testSizesDoNotCollide() {
        let source = makeSource("b.cr3")
        XCTAssertTrue(cache.set(makeImage(width: 16, height: 16), for: source, size: 80))
        XCTAssertTrue(cache.set(makeImage(width: 32, height: 32), for: source, size: 200))
        XCTAssertEqual(cache.get(source, size: 80)?.width, 16)
        XCTAssertEqual(cache.get(source, size: 200)?.width, 32)
    }

    func testInvalidatesWhenSourceMtimeChanges() throws {
        let source = makeSource("c.cr3")
        XCTAssertTrue(cache.set(makeImage(), for: source, size: 80))
        XCTAssertNotNil(cache.get(source, size: 80))

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: source.path)
        XCTAssertNil(cache.get(source, size: 80), "a changed source must miss the cache")
    }

    func testInvalidateRemovesEntry() {
        let source = makeSource("d.cr3")
        XCTAssertTrue(cache.set(makeImage(), for: source, size: 80))
        cache.invalidate(source, size: 80)
        XCTAssertNil(cache.get(source, size: 80))
    }

    func testMissingSourceIsAMiss() {
        let ghost = sourceDirectory.appendingPathComponent("ghost.cr3")
        XCTAssertNil(cache.get(ghost, size: 80))
        XCTAssertFalse(cache.set(makeImage(), for: ghost, size: 80))
    }
}
