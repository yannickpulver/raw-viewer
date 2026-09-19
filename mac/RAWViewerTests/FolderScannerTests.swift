import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RAWViewer

/// Ported from `tests/test_scanner.py`, minus the RAF/CR3 binary-parser cases (ImageIO reads
/// those formats natively, so the hand-rolled blob extractors do not exist in the rewrite).
final class FolderScannerTests: XCTestCase {
    private var root: URL!

    static let dateString = "2026:05:23 10:38:44"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ relative: String) -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    /// Writes a 4x4 JPEG carrying `Exif/DateTimeOriginal`.
    @discardableResult
    private func writeJPEG(_ relative: String, date: String = dateString) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = context.makeImage()!

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private var expectedDate: Date {
        FolderScanner.exifFormatter.date(from: Self.dateString)!
    }

    // MARK: - Capture date

    func testJPEGExifDateIsRead() async throws {
        let url = try writeJPEG("IMG_0001.jpg")
        let date = await FolderScanner.captureDate(for: url, kind: .jpeg, cache: nil)
        XCTAssertEqual(date, expectedDate)
    }

    func testUnparseableFileFallsBackToFilesystemTime() async throws {
        let url = touch("broken.RAF")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let expected = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as! Date)
        let date = await FolderScanner.captureDate(for: url, kind: .raw, cache: nil)
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Subfolders

    func testSubfolderName() {
        XCTAssertEqual(FolderScanner.subfolderName(for: root.appendingPathComponent("X100VI/a.RAF"),
                                                   root: root), "X100VI")
        XCTAssertEqual(FolderScanner.subfolderName(for: root.appendingPathComponent("DJI/DCIM/d.DNG"),
                                                   root: root), "DJI")
        XCTAssertEqual(FolderScanner.subfolderName(for: root.appendingPathComponent("e.RAF"),
                                                   root: root), root.lastPathComponent)
    }

    func testSubfolderNameOutsideRoot() {
        let outside = URL(fileURLWithPath: "/tmp/elsewhere/x.RAF")
        XCTAssertEqual(FolderScanner.subfolderName(for: outside, root: root), "elsewhere")
    }

    func testSubfolderCountsGroupsByFirstLevelFolder() {
        let urls = [
            "X100VI/a.RAF", "X100VI/b.RAF", "R5/c.CR3", "DJI/DCIM/d.DNG", "e.RAF",
        ].map { root.appendingPathComponent($0) }
        let counts = FolderScanner.subfolderCounts(urls, root: root)
        XCTAssertEqual(counts.map(\.name), ["DJI", "R5", "X100VI", root.lastPathComponent])
        XCTAssertEqual(counts.map(\.count), [1, 1, 2, 1])
    }

    func testSubfolderCountsEmpty() {
        XCTAssertTrue(FolderScanner.subfolderCounts([], root: root).isEmpty)
    }

    // MARK: - Walking

    func testScanClassifiesAndSkipsResourceForks() async throws {
        touch("a.cr3")
        touch("b.JPG")
        touch("c.mov")
        touch("._d.cr3")
        touch("notes.txt")
        touch("nested/e.NEF")

        let result = try await FolderScanner().scan(root: root)
        XCTAssertEqual(Set(result.raw.map(\.name)), ["a.cr3", "e.NEF"])
        XCTAssertEqual(result.jpeg.map(\.name), ["b.JPG"])
        XCTAssertEqual(result.video.map(\.name), ["c.mov"])
    }

    func testScanSortsByDateThenPath() async throws {
        try writeJPEG("late.jpg", date: "2026:05:23 12:00:00")
        try writeJPEG("early.jpg", date: "2026:05:23 09:00:00")
        let result = try await FolderScanner().scan(root: root)
        XCTAssertEqual(result.jpeg.map(\.name), ["early.jpg", "late.jpg"])
    }

    func testScanReportsProgress() async throws {
        for index in 0..<12 { touch("file\(index).cr3") }
        let box = ProgressBox()
        _ = try await FolderScanner().scan(root: root) { box.append($0) }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertEqual(box.values.last!, 1.0, accuracy: 0.0001)
    }

    func testScanThrowsForNonDirectory() async {
        let file = touch("a.cr3")
        do {
            _ = try await FolderScanner().scan(root: file)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("Not a directory") || error is FolderScanner.ScanError)
        }
    }

    func testMediaKindClassification() {
        XCTAssertEqual(MediaKind.rawExtensions.count, 28)
        XCTAssertEqual(MediaKind.jpegExtensions.count, 2)
        XCTAssertEqual(MediaKind.videoExtensions.count, 3)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/x/a.CR3")), .raw)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/x/a.JpEg")), .jpeg)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/x/a.M4V")), .video)
        XCTAssertNil(MediaKind.of(URL(fileURLWithPath: "/x/a.heic")))
        XCTAssertNil(MediaKind.of(URL(fileURLWithPath: "/x/a.png")))
        XCTAssertNil(MediaKind.of(URL(fileURLWithPath: "/x/._a.cr3")))
    }

    /// Capture dates are extracted concurrently (8 at a time). The order of the result and the
    /// progress reporting must be exactly what the sequential version produced.
    func testConcurrentCaptureDatesStaySortedAndReportProgress() async throws {
        for index in 0..<40 {
            try writeJPEG(String(format: "IMG_%04d.jpg", index),
                          date: String(format: "2026:05:23 10:%02d:00", 39 - index))
        }

        let box = ProgressBox()
        let result = try await FolderScanner().scan(root: root) { box.append($0) }

        XCTAssertEqual(result.jpeg.count, 40)
        // Ascending by capture date: the files were written in descending date order.
        XCTAssertEqual(result.jpeg.map(\.url.lastPathComponent),
                       (0..<40).reversed().map { String(format: "IMG_%04d.jpg", $0) })
        for pair in zip(result.jpeg, result.jpeg.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.captureDate, pair.1.captureDate)
        }
        let reported = box.values
        XCTAssertEqual(reported.count, 8)          // every 5th of 40, the last one included
        XCTAssertEqual(reported.last, 1.0)
        XCTAssertEqual(reported, reported.sorted())
    }

    /// Two identical runs produce identical ordering, even though the work is parallel.
    func testConcurrentScanIsDeterministic() async throws {
        for index in 0..<24 { try writeJPEG(String(format: "IMG_%04d.jpg", index)) }
        let first = try await FolderScanner().scan(root: root)
        let second = try await FolderScanner().scan(root: root)
        XCTAssertEqual(first.jpeg.map(\.url), second.jpeg.map(\.url))
    }
}

/// Small thread-safe sink, since the progress callback fires off the main actor.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
