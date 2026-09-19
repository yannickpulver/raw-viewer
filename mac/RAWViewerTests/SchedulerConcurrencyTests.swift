import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RAWViewer

/// Covers the concurrency / bookkeeping fixes in `AsyncSemaphore` and `PreloadScheduler`.
final class AsyncSemaphoreTests: XCTestCase {

    /// A waiter cancelled while queued must not consume a permit.
    func testCancelledWaiterDoesNotConsumeAPermit() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        let acquired = await semaphore.wait()
        XCTAssertTrue(acquired)

        let waiter = Task { await semaphore.wait() }
        var spins = 0
        while await semaphore.waiterCount == 0 {
            spins += 1
            XCTAssertLessThan(spins, 1000, "waiter never enqueued")
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        waiter.cancel()
        let granted = await waiter.value
        XCTAssertFalse(granted, "a cancelled waiter must not be handed a permit")
        let remaining = await semaphore.waiterCount
        XCTAssertEqual(remaining, 0)

        await semaphore.signal()
        let available = await semaphore.availablePermits
        XCTAssertEqual(available, 1, "the permit released by the holder must come back")
    }

    /// `wait()` on an already-cancelled task returns immediately without taking a permit.
    func testWaitOnACancelledTaskTakesNoPermit() async throws {
        let semaphore = AsyncSemaphore(value: 2)
        let task = Task { () -> Bool in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return await semaphore.wait()
        }
        task.cancel()
        let granted = await task.value
        XCTAssertFalse(granted)
        let available = await semaphore.availablePermits
        XCTAssertEqual(available, 2)
    }

    /// The counter never drifts, however many callers pile up.
    func testWithPermitBalancesTheCounter() async throws {
        let semaphore = AsyncSemaphore(value: 2)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await semaphore.withPermit { () -> Bool in
                        try? await Task.sleep(nanoseconds: 500_000)
                        return true
                    }
                }
            }
        }
        let available = await semaphore.availablePermits
        let waiting = await semaphore.waiterCount
        XCTAssertEqual(available, 2)
        XCTAssertEqual(waiting, 0)
    }
}

@MainActor
final class PreloadSchedulerTests: XCTestCase {
    private var directory: URL!
    private var scheduler: PreloadScheduler!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scheduler = PreloadScheduler(
            diskCache: DiskThumbnailCache(directory: directory.appendingPathComponent("cache")))
    }

    override func tearDown() async throws {
        scheduler.closeFolder()
        scheduler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func jpeg(_ name: String) throws -> MediaFile {
        let url = directory.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = context.makeImage()!
        let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(sink))
        return MediaFile(url: url, kind: .jpeg, captureDate: Date(), subfolder: "x")
    }

    private func broken(_ name: String) -> MediaFile {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("not an image".utf8))
        return MediaFile(url: url, kind: .raw, captureDate: Date(), subfolder: "x")
    }

    private func settle() async throws {
        for _ in 0..<300 {
            if scheduler.liveTaskCount == 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("tasks did not settle")
    }

    /// Fix 10: a thumbnail decode that failed once is memoised and never re-queued.
    func testFailedThumbnailsAreMemoised() async throws {
        let file = broken("broken.cr3")
        let size = PreviewDecoder.filmstripThumbnailSize

        scheduler.preloadFilmstrip(range: 0..<1, in: [file])
        try await settle()
        XCTAssertTrue(scheduler.hasFailedThumbnail(file.url, size: size))
        XCTAssertEqual(scheduler.failedThumbCount, 1)

        // A second request must not spawn anything.
        scheduler.preloadFilmstrip(range: 0..<1, in: [file])
        XCTAssertEqual(scheduler.liveTaskCount, 0)

        scheduler.reset(totalFileCount: 1)
        XCTAssertFalse(scheduler.hasFailedThumbnail(file.url, size: size))
    }

    /// Fix 16: `currentKey` is set before the cache-hit early return, so a cached current image
    /// still counts as "current" for the nearby-preview cancellation pass.
    func testSetCurrentTracksTheKeyEvenOnACacheHit() async throws {
        let file = try jpeg("current.jpg")

        scheduler.setCurrent(file)
        XCTAssertEqual(scheduler.currentPreviewURL, file.url)
        try await settle()
        XCTAssertNotNil(scheduler.preview(for: file.url))

        scheduler.setCurrent(nil)
        XCTAssertNil(scheduler.currentPreviewURL)

        // Now a pure cache hit: the early return must still have recorded the key.
        scheduler.setCurrent(file)
        XCTAssertEqual(scheduler.currentPreviewURL, file.url)
        XCTAssertEqual(scheduler.liveTaskCount, 0)
    }

    /// Fix 13: grid eviction rebuilds `thumbs200` once and keeps the live window.
    func testGridEvictionKeepsTheVisibleWindow() async throws {
        var files: [MediaFile] = []
        for index in 0..<3 { files.append(try jpeg("grid-\(index).jpg")) }
        scheduler.gridVisibleRange(0..<3, in: files)
        try await settle()
        XCTAssertEqual(scheduler.thumbs200.count, 3)

        scheduler.gridVisibleRange(0..<1, in: [files[0]])
        try await settle()
        XCTAssertEqual(Set(scheduler.thumbs200.keys), [files[0].url])
    }
}
