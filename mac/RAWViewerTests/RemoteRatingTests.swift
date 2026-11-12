import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RAWViewer

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String) -> HTTPParser.Result { HTTPParser.parse(Data(text.utf8)) }

    func testGetWithQuery() {
        let raw = "GET /api/files?folder=%2FUsers%2Fme%2FShoot%201 HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .request(let request, let consumed) = parse(raw) else { return XCTFail() }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/files")
        XCTAssertEqual(request.query["folder"], "/Users/me/Shoot 1")
        XCTAssertEqual(request.headers["host"], "x")
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testWaitsForHeadersAndBody() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\r\n"), .incomplete)
        XCTAssertEqual(parse("POST /api/rate HTTP/1.1\r\nContent-Length: 5\r\n\r\nab"), .incomplete)
    }

    func testBodyAndPipelinedRequest() {
        let first = "POST /api/rate HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        guard case .request(let request, let consumed) = parse(first + "GET / HTTP/1.1\r\n\r\n") else {
            return XCTFail()
        }
        XCTAssertEqual(request.body, Data("hello".utf8))
        XCTAssertEqual(consumed, first.utf8.count)
    }

    func testRejectsGarbageAndHugeRequests() {
        XCTAssertEqual(parse("hello\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nContent-Length: -3\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"), .tooLarge)
        XCTAssertEqual(parse(String(repeating: "a", count: HTTPParser.maximumSize + 1)), .tooLarge)
    }

    func testTailscaleRange() {
        XCTAssertTrue(TailscaleAddress.isTailscale([100, 86, 86, 36]))
        XCTAssertTrue(TailscaleAddress.isTailscale([100, 64, 0, 1]))
        XCTAssertFalse(TailscaleAddress.isTailscale([100, 128, 0, 1]))
        XCTAssertFalse(TailscaleAddress.isTailscale([192, 168, 1, 2]))
    }
}

@MainActor
final class RemoteRatingTests: XCTestCase {
    private var root: URL!
    private var other: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var summaryFile: URL!
    private var library: Library!
    private var remote: RemoteRating!
    private var base: URL!

    override func setUp() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-\(UUID().uuidString)", isDirectory: true)
        root = temp.appendingPathComponent("Open Shoot", isDirectory: true)
        other = temp.appendingPathComponent("Other Shoot", isDirectory: true)
        try writeJPEG(root.appendingPathComponent("a.jpg"))
        try writeJPEG(root.appendingPathComponent("b.jpg"))
        try writeJPEG(other.appendingPathComponent("day 2/c.jpg"))

        suiteName = "RemoteRatingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: Preferences.Keys.didImportLegacyCache)
        summaryFile = temp.appendingPathComponent("summaries.json")
        let preferences = Preferences(defaults: defaults)
        library = Library(preferences: preferences,
                          recents: RecentFolders(defaults: defaults),
                          summaryStore: FolderSummaryStore(file: summaryFile),
                          viewedStore: ViewedStore(directory: temp.appendingPathComponent("viewed")))
        RecentFolders(defaults: defaults).add(other)

        remote = RemoteRating(library: library, preferences: preferences)
        remote.start(host: "127.0.0.1", port: 0)
        for _ in 0..<200 {
            if case .running(let url) = remote.status { base = url; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("server did not start: \(remote.status)")
    }

    override func tearDown() async throws {
        remote.stop()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func writeJPEG(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let sink = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sink, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(sink))
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        return (data, response as! HTTPURLResponse)
    }

    private func json(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        let (data, _) = try await get(path, query)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rate(_ folder: URL, _ file: String, _ rating: Int) async throws -> Int {
        var request = URLRequest(url: base.appendingPathComponent("api/rate"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "folder": RemoteRating.id(folder), "file": file, "rating": rating])
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    private func openAndWait(_ folder: URL) async throws {
        library.openFolder(folder)
        for _ in 0..<600 {
            if !library.isScanning, library.hasLoadedFolder { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("scan did not finish")
    }

    func testServesThePage() async throws {
        let (data, response) = try await get("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("RAW Viewer"))
        let (_, missing) = try await get("/nope")
        XCTAssertEqual(missing.statusCode, 404)
    }

    func testRatesAFolderThatIsNotOpen() async throws {
        let (folderData, _) = try await get("/api/folders")
        let folders = try XCTUnwrap(JSONSerialization.jsonObject(with: folderData) as? [[String: Any]])
        XCTAssertEqual(folders.map { $0["name"] as? String }, ["Other Shoot"])

        let list = try await json("/api/files", ["folder": RemoteRating.id(other)])
        let files = try XCTUnwrap(list["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["id"] as? String }, ["day 2/c.jpg"])
        XCTAssertEqual(files.first?["rating"] as? Int, 0)

        let (image, response) = try await get("/api/preview", ["folder": RemoteRating.id(other), "file": "day 2/c.jpg"])
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertNotNil(CGImageSourceCreateWithData(image as CFData, nil))

        let status = try await rate(other, "day 2/c.jpg", 4)
        XCTAssertEqual(status, 200)
        await library.flushPendingWrites()
        XCTAssertEqual(XMPSidecar.read(other.appendingPathComponent("day 2/c.jpg")), 4)

        // The dashboard numbers follow a second later.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let summary = FolderSummaryStore(file: summaryFile).load(folder: other)
        XCTAssertEqual(summary?.jpeg, 1)
        XCTAssertEqual(summary?.rated(stars: 4), 1)
    }

    func testRatingTheOpenFolderUpdatesTheWindow() async throws {
        try await openAndWait(root)
        let list = try await json("/api/files", ["folder": RemoteRating.id(root)])
        XCTAssertEqual(list["open"] as? Bool, true)
        XCTAssertEqual((list["files"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.sorted(),
                       ["a.jpg", "b.jpg"])
        let index = library.index

        let status = try await rate(root, "b.jpg", 3)
        XCTAssertEqual(status, 200)
        let b = try XCTUnwrap(library.modeStates[.all]?.allFiles.first { $0.name == "b.jpg" })
        XCTAssertEqual(library.rating(for: b.url), 3)
        XCTAssertEqual(library.index, index, "a phone rating does not move the window")
        await library.flushPendingWrites()
        XCTAssertEqual(XMPSidecar.read(root.appendingPathComponent("b.jpg")), 3)
    }

    func testRefusesFilesThatWereNotListed() async throws {
        let status = try await rate(other, "../Open Shoot/a.jpg", 5)
        XCTAssertEqual(status, 404)
        _ = try await json("/api/files", ["folder": RemoteRating.id(other)])
        let (_, response) = try await get("/api/thumb", ["folder": RemoteRating.id(other), "file": "../Open Shoot/a.jpg"])
        XCTAssertEqual(response.statusCode, 404)
        let (_, unknown) = try await get("/api/files", ["folder": "/etc"])
        XCTAssertEqual(unknown.statusCode, 404)
        XCTAssertNil(XMPSidecar.read(root.appendingPathComponent("a.jpg")))
    }
}
