import XCTest
@testable import RAWViewer

final class ResolveExportTests: XCTestCase {

    // MARK: - Job file

    func testJobFileContentsFormat() {
        let a = URL(fileURLWithPath: "/Volumes/CARD1/DCIM/a.RAF")
        let b = URL(fileURLWithPath: "/Volumes/CARD2/DCIM/a.RAF")
        let c = URL(fileURLWithPath: "/tmp/c.mov")
        let contents = ResolveExport.jobFileContents(
            files: [a, b, c],
            ratings: [a: 5, c: 2])

        XCTAssertEqual(contents, """
        5\t/Volumes/CARD1/DCIM/a.RAF
        0\t/Volumes/CARD2/DCIM/a.RAF
        2\t/tmp/c.mov

        """)
    }

    func testJobFileContentsPreservesOrderAndDefaultsToZero() {
        let files = (1...3).map { URL(fileURLWithPath: "/tmp/\($0).raf") }
        let lines = ResolveExport.jobFileContents(files: files, ratings: [:])
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines, ["0\t/tmp/1.raf", "0\t/tmp/2.raf", "0\t/tmp/3.raf"])
    }

    func testWriteJobFileRoundTrips() throws {
        let files = [URL(fileURLWithPath: "/tmp/x.raf")]
        let url = try ResolveExport.writeJobFile(files: files, ratings: [files[0]: 4])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "4\t/tmp/x.raf\n")
    }

    // MARK: - stdout protocol

    func testParseStatusLine() {
        XCTAssertEqual(ResolveExport.parseLine("STATUS\tImporting 12 files..."),
                       .status("Importing 12 files..."))
    }

    func testParseResultOK() {
        XCTAssertEqual(ResolveExport.parseLine("RESULT\tOK\t12\t7"), .ok(clips: 12, rated: 7))
    }

    func testParseResultError() {
        XCTAssertEqual(ResolveExport.parseLine("RESULT\tERR\tCould not access Project Manager."),
                       .error("Could not access Project Manager."))
    }

    func testParseNotRunning() {
        XCTAssertEqual(ResolveExport.parseLine("NOTRUNNING"), .notRunning)
        XCTAssertEqual(ResolveExport.parseLine("NOTRUNNING\r"), .notRunning)
    }

    func testParseIgnoresBannerAndMalformedLines() {
        XCTAssertNil(ResolveExport.parseLine("DaVinci Resolve Script Interpreter"))
        XCTAssertNil(ResolveExport.parseLine(""))
        XCTAssertNil(ResolveExport.parseLine("STATUS"))
        XCTAssertNil(ResolveExport.parseLine("RESULT\tOK\t12"))
        XCTAssertNil(ResolveExport.parseLine("RESULT\tOK\tmany\tsome"))
        XCTAssertNil(ResolveExport.parseLine("RESULT\tWAT\tx"))
    }

    func testParseTranscriptProducesEventSequence() {
        let transcript = """
        DaVinci Resolve Script Interpreter
        Copyright (C) 2005 - 2026 Blackmagic Design Pty. Ltd.

        STATUS\tCreating project...
        STATUS\tImporting 4 files...
        STATUS\tSetting metadata on 4 clips...
        RESULT\tOK\t4\t3
        """
        let events = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { ResolveExport.parseLine(String($0)) }
        XCTAssertEqual(events, [
            .status("Creating project..."),
            .status("Importing 4 files..."),
            .status("Setting metadata on 4 clips..."),
            .ok(clips: 4, rated: 3)
        ])
    }

    // MARK: - Rating mapping (spec 06 section 4)

    func testRatingMappingTable() {
        let expected: [Int: (String, String, Bool, String, String)] = [
            1: ("Blue", "1star", false, "Rating: 1/5", "★☆☆☆☆"),
            2: ("Teal", "2stars", false, "Rating: 2/5", "★★☆☆☆"),
            3: ("Yellow", "3stars", false, "Rating: 3/5", "★★★☆☆"),
            4: ("Orange", "4stars", true, "Rating: 4/5", "★★★★☆"),
            5: ("Green", "5stars,keeper", true, "Rating: 5/5", "★★★★★")
        ]
        for (rating, row) in expected {
            guard let mapping = ResolveExport.ratingMapping(for: rating) else {
                return XCTFail("no mapping for \(rating)")
            }
            XCTAssertEqual(mapping.color, row.0)
            XCTAssertEqual(mapping.keywords, row.1)
            XCTAssertEqual(mapping.goodTake, row.2)
            XCTAssertEqual(mapping.comments, row.3)
            XCTAssertEqual(mapping.description, row.4)
        }
    }

    func testUnratedAndRejectedAreUntouched() {
        XCTAssertNil(ResolveExport.ratingMapping(for: 0))
        XCTAssertNil(ResolveExport.ratingMapping(for: -1))
        XCTAssertNil(ResolveExport.ratingMapping(for: 6))
    }

    // MARK: - Messages

    func testProjectName() {
        XCTAssertEqual(ResolveExport.projectName(folderName: "2026.09.19 - shoot"),
                       "RV - 2026.09.19 - shoot")
    }

    func testMessages() {
        XCTAssertEqual(ResolveExport.Message.notInstalled,
                       "DaVinci Resolve not found.\nRequires Resolve Studio (paid) for scripting.")
        XCTAssertEqual(ResolveExport.Message.couldNotConnect,
                       "Could not connect to DaVinci Resolve.\nMake sure Resolve Studio is running.")
        XCTAssertEqual(ResolveExport.Message.waiting(seconds: 7),
                       "Waiting for Resolve to start... (7s)")
        XCTAssertEqual(ResolveExport.Message.success(projectName: "RV - Shoot", clips: 12, rated: 7),
                       "Exported to Resolve project 'RV - Shoot'\n12 clips imported, 7 with ratings")
        XCTAssertEqual(ResolveExport.startupRetryCount, 30)
    }

    func testExportFailsWithNotInstalledMessageWhenResolveIsMissing() async {
        let result = await ResolveExport.export(
            files: [URL(fileURLWithPath: "/tmp/x.raf")], ratings: [:],
            folderName: "Untitled", fuscript: nil, script: nil, onStatus: { _ in })
        XCTAssertEqual(result, .failure(ResolveExport.Message.notInstalled))
    }

    func testExportFailsWithNotInstalledMessageWhenLuaScriptIsMissing() async {
        let result = await ResolveExport.export(
            files: [URL(fileURLWithPath: "/tmp/x.raf")], ratings: [:],
            folderName: "Untitled", fuscript: "/bin/echo", script: nil, onStatus: { _ in })
        XCTAssertEqual(result, .failure(ResolveExport.Message.notInstalled))
    }

    func testLuaScriptIsBundledAndMirrorsTheRatingTable() throws {
        let bundled = Bundle.main.url(forResource: "resolve_export", withExtension: "lua")
            ?? Bundle(for: Self.self).url(forResource: "resolve_export", withExtension: "lua")
        try XCTSkipIf(bundled == nil, "resolve_export.lua is not reachable from this test bundle")
        let url = try XCTUnwrap(bundled)
        let source = try String(contentsOf: url, encoding: .utf8)
        for rating in 1...5 {
            let mapping = try XCTUnwrap(ResolveExport.ratingMapping(for: rating))
            XCTAssertTrue(source.contains("[\(rating)] = { color = \"\(mapping.color)\""),
                          "Lua table is out of sync for rating \(rating)")
            XCTAssertTrue(source.contains("\"\(mapping.keywords)\""))
            XCTAssertTrue(source.contains("\"\(mapping.description)\""))
        }
    }
}
