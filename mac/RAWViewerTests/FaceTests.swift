import CoreGraphics
import XCTest
@testable import RAWViewer

final class FaceDetectorTests: XCTestCase {
    /// An eye contour `width` wide and `height` tall, the way Vision draws it: a closed ring.
    private func eye(width: CGFloat, height: CGFloat) -> [CGPoint] {
        (0..<8).map { step in
            let angle = CGFloat(step) / 8 * 2 * .pi
            return CGPoint(x: 100 + cos(angle) * width / 2, y: 50 + sin(angle) * height / 2)
        }
    }

    func testOpenEyeIsAboveThreshold() throws {
        let ratio = try XCTUnwrap(FaceDetector.openness(eye(width: 30, height: 12)))
        XCTAssertEqual(ratio, 0.4, accuracy: 0.01)
        XCTAssertGreaterThan(ratio, FaceDetector.closedEyeRatio)
    }

    func testClosedEyeIsBelowThreshold() throws {
        let ratio = try XCTUnwrap(FaceDetector.openness(eye(width: 30, height: 3)))
        XCTAssertLessThan(ratio, FaceDetector.closedEyeRatio)
    }

    func testDegenerateContourHasNoOpenness() {
        XCTAssertNil(FaceDetector.openness([]))
        XCTAssertNil(FaceDetector.openness([CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 2), CGPoint(x: 1, y: 3)]))
    }

    func testOverlapIsIntersectionOverUnion() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        XCTAssertEqual(FaceDetector.overlap(a, a), 1, accuracy: 0.0001)
        XCTAssertEqual(FaceDetector.overlap(a, CGRect(x: 0.1, y: 0, width: 0.2, height: 0.2)), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(FaceDetector.overlap(a, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)), 0)
    }

    func testTilesOverlapAndCoverTheImage() {
        let size = CGSize(width: 1000, height: 500)
        XCTAssertEqual(FaceDetector.tiles(for: size, count: 2, share: 0.6), [
            CGRect(x: 0, y: 0, width: 600, height: 300), CGRect(x: 400, y: 0, width: 600, height: 300),
            CGRect(x: 0, y: 200, width: 600, height: 300), CGRect(x: 400, y: 200, width: 600, height: 300),
        ])
        let three = FaceDetector.tiles(for: size, count: 3, share: 0.4)
        XCTAssertEqual(three.count, 9)
        XCTAssertEqual(three[1], CGRect(x: 300, y: 0, width: 400, height: 200))
        XCTAssertEqual(three[8], CGRect(x: 600, y: 300, width: 400, height: 200))
    }

    func testTileRectMapsBackToTheImage() {
        // Bottom-right tile (top-left origin y 200), a face in its top-left quarter.
        let tile = CGRect(x: 400, y: 200, width: 600, height: 300)
        let mapped = FaceDetector.map(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), from: tile,
                                      in: CGSize(width: 1000, height: 500))
        // Pixels x 400...700, top-left y 200...350, i.e. bottom-left y 150...300.
        XCTAssertEqual(mapped.minX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(mapped.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(mapped.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(mapped.height, 0.3, accuracy: 0.0001)
    }

    func testHalfAFaceAtATileEdgeIsTheSameFace() {
        let whole = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        XCTAssertTrue(FaceDetector.isSameFace(whole, CGRect(x: 0.5, y: 0.5, width: 0.06, height: 0.1)))
        XCTAssertFalse(FaceDetector.isSameFace(whole, CGRect(x: 0.58, y: 0.5, width: 0.1, height: 0.1)))
        XCTAssertFalse(FaceDetector.isSameFace(whole, CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))
    }

    func testBlankImageHasNoFaces() {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        XCTAssertEqual(FaceDetector().detect(in: context.makeImage()!), [])
    }
}

final class FacePanelTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testCropIsASquareAroundTheFace() throws {
        let crop = try XCTUnwrap(FacePanel.crop(image(width: 1000, height: 500),
                                                to: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)))
        // 100 x 100 px face, padded by 1.6.
        XCTAssertEqual(crop.width, 160)
        XCTAssertEqual(crop.height, 160)
    }

    func testRowsRunLeftToRightFourAtATime() {
        let faces = [0.9, 0.1, 0.5, 0.3, 0.7, 0.2].map {
            Face(rect: CGRect(x: $0, y: 0.5, width: 0.05, height: 0.05), quality: nil, eyesClosed: false)
        }
        let rows = FacePanel.rows(faces).map { $0.map(\.rect.minX) }
        XCTAssertEqual(rows, [[0.1, 0.2, 0.3, 0.5], [0.7, 0.9]])
    }

    func testCropIsClampedAtTheEdge() throws {
        let crop = try XCTUnwrap(FacePanel.crop(image(width: 1000, height: 500),
                                                to: CGRect(x: 0, y: 0, width: 0.1, height: 0.2)))
        XCTAssertEqual(crop.width, 130)
        XCTAssertEqual(crop.height, 130)
    }
}

final class FaceCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("faces-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripPerFolder() {
        let cache = FaceCache(directory: directory)
        let face = Face(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), quality: 0.5, eyesClosed: true)
        let entries = ["/shoot/a.cr3": FaceCache.Entry(mtime: 42, faces: [face])]
        cache.save(entries, folder: URL(fileURLWithPath: "/shoot"))

        XCTAssertEqual(cache.load(folder: URL(fileURLWithPath: "/shoot")), entries)
        XCTAssertEqual(cache.load(folder: URL(fileURLWithPath: "/other")), [:])
    }
}

@MainActor
final class FaceIndexTests: XCTestCase {
    private var root: URL!
    private var cacheDirectory: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("face-index-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) -> MediaFile {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return MediaFile(url: url, kind: .raw, captureDate: Date(), subfolder: "")
    }

    func testCachedEntryWithMatchingMtimeIsReusedAndStaleOneIsAnalysedAgain() async throws {
        let fresh = file("fresh.cr3")
        let stale = file("stale.cr3")
        let face = Face(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), quality: 0.7, eyesClosed: false)
        let cache = FaceCache(directory: cacheDirectory)
        let freshMtime = try XCTUnwrap(FaceCache.mtime(of: fresh.url))
        cache.save([
            fresh.url.path: .init(mtime: freshMtime, faces: [face]),
            stale.url.path: .init(mtime: freshMtime - 100, faces: [face]),
        ], folder: root)

        let index = FaceIndex(cache: cache)
        index.start(folder: root, files: [fresh, stale], current: nil)
        await index.waitForSweep()

        XCTAssertEqual(index.faces(for: fresh.url), [face])
        // The empty file decodes to nothing, so a re-analysis finds no faces.
        XCTAssertEqual(index.faces(for: stale.url), [])
        XCTAssertEqual(index.remaining, 0)
    }

    func testVideoIsSkipped() async {
        let url = root.appendingPathComponent("clip.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let index = FaceIndex(cache: FaceCache(directory: cacheDirectory))
        index.start(folder: root, files: [MediaFile(url: url, kind: .video, captureDate: Date(), subfolder: "")],
                    current: nil)
        await index.waitForSweep()
        XCTAssertNil(index.faces(for: url))
    }

    func testStopForgetsTheFolder() async {
        let image = file("a.cr3")
        let index = FaceIndex(cache: FaceCache(directory: cacheDirectory))
        index.start(folder: root, files: [image], current: nil)
        await index.waitForSweep()
        XCTAssertNotNil(index.faces(for: image.url))

        index.stop()
        XCTAssertNil(index.faces(for: image.url))
    }
}
