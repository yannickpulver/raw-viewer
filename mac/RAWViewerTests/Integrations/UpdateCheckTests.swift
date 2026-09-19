import XCTest
@testable import RAWViewer

/// Mutable box usable from a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class UpdateCheckTests: XCTestCase {

    private func payload(tag: String, url: String = "https://github.com/yannickpulver/raw-viewer/releases/tag/v1.2.3") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)","name":"whatever"}"#.utf8)
    }

    // MARK: - Parsing

    func testParseStripsLeadingV() throws {
        let release = try XCTUnwrap(UpdateCheck.parse(payload(tag: "v1.2.3")))
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(release.url.absoluteString,
                       "https://github.com/yannickpulver/raw-viewer/releases/tag/v1.2.3")
    }

    func testParseKeepsTagWithoutV() throws {
        XCTAssertEqual(try XCTUnwrap(UpdateCheck.parse(payload(tag: "0.4.5"))).version, "0.4.5")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"html_url":"https://x.test"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v1.0.0"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v","html_url":"https://x.test"}"#.utf8)))
    }

    // MARK: - Request

    func testRequestHeadersAndTimeout() {
        let request = UpdateCheck.request()
        XCTAssertEqual(request.url, UpdateCheck.releasesURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "RAW-Viewer")
        XCTAssertEqual(request.timeoutInterval, 5)
    }

    // MARK: - Comparison

    func testUpdateAvailableWhenVersionsDiffer() async throws {
        let data = payload(tag: "v0.5.0")
        let result = await UpdateCheck.check(currentVersion: "0.4.5") { _ in data }
        XCTAssertEqual(try XCTUnwrap(result).version, "0.5.0")
    }

    func testNoUpdateWhenVersionsMatch() async {
        let data = payload(tag: "v0.4.5")
        let result = await UpdateCheck.check(currentVersion: "0.4.5") { _ in data }
        XCTAssertNil(result)
    }

    func testStringInequalityReportsOlderPublishedRelease() async throws {
        // Documented quirk: plain string inequality, so a locally built newer
        // version also reports an update.
        let data = payload(tag: "v0.4.0")
        let result = await UpdateCheck.check(currentVersion: "0.4.5") { _ in data }
        XCTAssertEqual(try XCTUnwrap(result).version, "0.4.0")
    }

    func testSkippedForDevAndEmptyVersions() async {
        let data = payload(tag: "v9.9.9")
        let fetched = Flag()
        let fetch: UpdateCheck.DataProvider = { _ in fetched.value = true; return data }
        let dev = await UpdateCheck.check(currentVersion: "dev", fetch: fetch)
        let empty = await UpdateCheck.check(currentVersion: "", fetch: fetch)
        XCTAssertNil(dev)
        XCTAssertNil(empty)
        XCTAssertFalse(fetched.value, "no network request for dev builds")
    }

    func testNetworkErrorsReturnNil() async {
        struct Boom: Error {}
        let result = await UpdateCheck.check(currentVersion: "0.4.5") { _ in throw Boom() }
        XCTAssertNil(result)
    }
}
