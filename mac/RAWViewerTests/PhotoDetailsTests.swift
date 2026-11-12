import CoreGraphics
import ImageIO
import XCTest
@testable import RAWViewer

final class PhotoDetailsTests: XCTestCase {

    func testReadsExifAndTiffProperties() {
        let details = PhotoDetails(properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.002,
                kCGImagePropertyExifFNumber: 8.0,
                kCGImagePropertyExifISOSpeedRatings: [125],
                kCGImagePropertyExifFocalLength: 23.0,
                kCGImagePropertyExifLensModel: "XF16-55mmF2.8 R LM WR",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "FUJIFILM",
                kCGImagePropertyTIFFModel: "X-T5",
            ] as [CFString: Any],
        ])
        XCTAssertEqual(details.shutterText, "1/500")
        XCTAssertEqual(details.apertureText, "f/8")
        XCTAssertEqual(details.isoText, "ISO 125")
        XCTAssertEqual(details.focalText, "23 mm")
        XCTAssertEqual(details.gearText, "Fujifilm X-T5 · XF16-55mmF2.8 R LM WR")
    }

    func testEmptyPropertiesHaveNoDetails() {
        XCTAssertTrue(PhotoDetails(properties: [:]).isEmpty)
        XCTAssertNil(PhotoDetails(properties: [:]).gearText)
    }

    func testShutterFormatting() {
        XCTAssertEqual(PhotoDetails(exposureTime: 1.0 / 4000).shutterText, "1/4000")
        XCTAssertEqual(PhotoDetails(exposureTime: 0.25).shutterText, "1/4")
        XCTAssertEqual(PhotoDetails(exposureTime: 0.8).shutterText, "0.8 s")
        XCTAssertEqual(PhotoDetails(exposureTime: 30).shutterText, "30 s")
    }

    func testApertureAndFocalRounding() {
        XCTAssertEqual(PhotoDetails(fNumber: 2.8).apertureText, "f/2.8")
        XCTAssertEqual(PhotoDetails(fNumber: 5.6000001).apertureText, "f/5.6")
        XCTAssertEqual(PhotoDetails(focalLength: 23.4).focalText, "23 mm")
    }

    func testCameraNames() {
        XCTAssertEqual(PhotoDetails.camera(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertEqual(PhotoDetails.camera(make: "NIKON CORPORATION", model: "NIKON Z 6_2"), "NIKON Z 6_2")
        XCTAssertEqual(PhotoDetails.camera(make: "SONY", model: "ILCE-7M4"), "Sony ILCE-7M4")
        XCTAssertEqual(PhotoDetails.camera(make: nil, model: "X100VI"), "X100VI")
        XCTAssertEqual(PhotoDetails.camera(make: "Apple", model: nil), "Apple")
    }

    // MARK: - Histogram

    /// Left half black, right half white: two spikes, nothing in between.
    func testHistogramCountsDarkAndBrightPixels() throws {
        let image = try XCTUnwrap(Self.twoToneImage(width: 64, height: 32))
        let bins = try XCTUnwrap(LumaHistogram.compute(image))
        XCTAssertEqual(bins.count, LumaHistogram.binCount)
        XCTAssertEqual(bins.reduce(0, +), 64 * 32)
        XCTAssertEqual(bins.first, 32 * 32)
        XCTAssertEqual(bins.last, 32 * 32)
        XCTAssertEqual(bins[1..<(bins.count - 1)].reduce(0, +), 0)
    }

    func testHistogramDownsamplesLargeImages() throws {
        let image = try XCTUnwrap(Self.twoToneImage(width: 1024, height: 512))
        let bins = try XCTUnwrap(LumaHistogram.compute(image))
        XCTAssertEqual(bins.reduce(0, +), 256 * 128)
    }

    func testNormalizedIgnoresClippedEnds() {
        let heights = LumaHistogram.normalized([1000, 10, 20, 5, 900])
        XCTAssertEqual(heights, [1, 0.5, 1, 0.25, 1])
        XCTAssertEqual(LumaHistogram.normalized([4, 0, 0, 0]), [1, 0, 0, 0])
    }

    private static func twoToneImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()
    }
}
