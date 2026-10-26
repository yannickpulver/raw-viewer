import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RAWViewer

final class FullResolutionTests: XCTestCase {
    private func writeJPEG(width: Int, height: Int) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testJPEGLargerThanPreviewDecodesEveryPixel() throws {
        let url = try writeJPEG(width: 4000, height: 3000)
        let image = try XCTUnwrap(PreviewDecoder().fullResolution(url: url, kind: .jpeg, largerThan: 2560))
        XCTAssertEqual(image.width, 4000)
        XCTAssertEqual(image.height, 3000)
    }

    func testFileNoLargerThanPreviewIsSkipped() throws {
        let url = try writeJPEG(width: 2000, height: 1500)
        XCTAssertNil(PreviewDecoder().fullResolution(url: url, kind: .jpeg, largerThan: 2000))
    }
}
