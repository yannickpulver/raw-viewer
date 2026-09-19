import XCTest
@testable import RAWViewer

/// Ported from `tests/test_rating.py`, plus an exact-bytes assertion on the template.
final class XMPSidecarTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    func testSidecarPathReplacesExtension() {
        XCTAssertEqual(XMPSidecar.path(for: URL(fileURLWithPath: "/x/IMG_0001.CR3")).lastPathComponent,
                       "IMG_0001.xmp")
        XCTAssertEqual(XMPSidecar.path(for: URL(fileURLWithPath: "/x/a.b.cr2")).lastPathComponent,
                       "a.b.xmp")
        XCTAssertEqual(XMPSidecar.path(for: URL(fileURLWithPath: "/x/clip.MOV")).lastPathComponent,
                       "clip.xmp")
    }

    func testWriteReadRoundtripStars() {
        let raw = makeFile("IMG_0001.cr3")
        for rating in 0...5 {
            XCTAssertTrue(XMPSidecar.write(raw, rating: rating))
            XCTAssertEqual(XMPSidecar.read(raw), rating)
        }
    }

    func testWriteReadReject() throws {
        let raw = makeFile("IMG_0002.cr3")
        XCTAssertTrue(XMPSidecar.write(raw, rating: -1))
        XCTAssertEqual(XMPSidecar.read(raw), -1)
        let content = try String(contentsOf: directory.appendingPathComponent("IMG_0002.xmp"), encoding: .utf8)
        XCTAssertTrue(content.contains("xmp:Rating=\"-1\""))
    }

    func testUpdateExistingSidecarStarToRejectAndBack() {
        let raw = makeFile("IMG_0003.cr3")
        XMPSidecar.write(raw, rating: 3)
        XMPSidecar.write(raw, rating: -1)
        XCTAssertEqual(XMPSidecar.read(raw), -1)
        XMPSidecar.write(raw, rating: 4)
        XCTAssertEqual(XMPSidecar.read(raw), 4)
    }

    func testClamping() {
        let raw = makeFile("IMG_0004.cr3")
        XMPSidecar.write(raw, rating: -5)
        XCTAssertEqual(XMPSidecar.read(raw), -1)
        XMPSidecar.write(raw, rating: 9)
        XCTAssertEqual(XMPSidecar.read(raw), 5)
    }

    func testNoSidecarReadsNil() {
        let raw = makeFile("IMG_0005.cr3")
        XCTAssertNil(XMPSidecar.read(raw))
    }

    /// Spec 05 §3: the template is byte-identical, UTF-8, `\n`, and has no trailing newline.
    func testTemplateBytesForRatingThree() throws {
        let raw = makeFile("IMG_0006.cr3")
        XCTAssertTrue(XMPSidecar.write(raw, rating: 3))
        let data = try Data(contentsOf: directory.appendingPathComponent("IMG_0006.xmp"))
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="3"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        XCTAssertEqual(data, Data(expected.utf8))
        XCTAssertFalse(expected.hasSuffix("\n"))
    }

    /// Spec 05 §5 branch 2: no rating attribute but an `rdf:Description` element.
    func testInsertsAttributeIntoDescriptionWithoutRating() throws {
        let raw = makeFile("IMG_0007.cr3")
        let sidecar = XMPSidecar.path(for: raw)
        try """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF><rdf:Description rdf:about="" dc:title="keep"/></rdf:RDF>
        </x:xmpmeta>
        """.write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertTrue(XMPSidecar.write(raw, rating: 2))
        let content = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(XMPSidecar.read(raw), 2)
        XCTAssertTrue(content.contains("dc:title=\"keep\""), "existing attributes must survive")
    }

    /// Spec 05 §5 branch 3: a malformed sidecar is replaced by the template.
    func testMalformedSidecarIsOverwritten() throws {
        let raw = makeFile("IMG_0008.cr3")
        let sidecar = XMPSidecar.path(for: raw)
        try "total garbage".write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertTrue(XMPSidecar.write(raw, rating: 5))
        let content = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(content, XMPSidecar.template(rating: 5))
    }

    func testStarsRendering() {
        XCTAssertEqual(Rating.stars(-1), "✕ rejected")
        XCTAssertEqual(Rating.stars(0), "☆☆☆☆☆")
        XCTAssertEqual(Rating.stars(3), "★★★☆☆")
        XCTAssertEqual(Rating.stars(5), "★★★★★")
    }

    /// A sidecar that exists but is not UTF-8 belongs to something else: refuse, touch nothing.
    func testWriteRefusesAnExistingNonUTF8Sidecar() throws {
        let file = makeFile("IMG_9001.cr3")
        let sidecar = XMPSidecar.path(for: file)
        let original = Data("<?xml version=\"1.0\"?><x/>".utf16.map { $0 }
            .flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        // A UTF-16LE payload with a BOM: valid XMP for other tools, unreadable as UTF-8 here.
        var bytes = Data([0xFF, 0xFE])
        bytes.append(original)
        try bytes.write(to: sidecar)

        XCTAssertFalse(XMPSidecar.write(file, rating: 3))
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        XCTAssertNil(XMPSidecar.read(file))
    }

    /// The other branch of the same guard: no sidecar at all still writes the template.
    func testWriteCreatesTheTemplateWhenNoSidecarExists() throws {
        let file = makeFile("IMG_9002.cr3")
        let sidecar = XMPSidecar.path(for: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        XCTAssertTrue(XMPSidecar.write(file, rating: 4))
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8),
                       XMPSidecar.template(rating: 4))
    }
}
