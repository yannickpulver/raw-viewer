import CoreGraphics
import XCTest
@testable import RAWViewer

@MainActor
final class CanvasZoomTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func canvas() -> CanvasNSView {
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.set(image: image(width: 40, height: 30), url: URL(fileURLWithPath: "/a.cr3"))
        return view
    }

    func testZoomAndPanSurviveNavigation() {
        let view = canvas()
        view.applyZoom(target: 2.0, anchor: CGPoint(x: 100, y: 100))
        let offset = view.offset
        XCTAssertNotEqual(offset, .zero)

        view.set(image: image(width: 30, height: 40), url: URL(fileURLWithPath: "/b.cr3"))
        XCTAssertEqual(view.zoom, 2.0)
        XCTAssertEqual(view.offset, offset)
    }

    func testCannotZoomOutBelowFit() {
        let view = canvas()
        view.applyZoom(target: 0.5, anchor: CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.zoom, 1.0)
        XCTAssertTrue(view.isAtFit)
    }

    func testZoomingBackToFitRecentres() {
        let view = canvas()
        view.applyZoom(target: 2.0, anchor: CGPoint(x: 50, y: 50))
        view.applyZoom(target: 0.9, anchor: CGPoint(x: 350, y: 250))
        XCTAssertEqual(view.zoom, 1.0)
        XCTAssertEqual(view.offset, .zero)
    }

    func testMaxZoomIsClamped() {
        let view = canvas()
        view.applyZoom(target: 50, anchor: CGPoint(x: 200, y: 150))
        XCTAssertEqual(view.zoom, CanvasNSView.maxZoom)
    }
}
