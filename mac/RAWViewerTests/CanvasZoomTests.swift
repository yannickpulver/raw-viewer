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

@MainActor
final class CanvasFaceFocusTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// 400 x 300 view, 40 x 30 image: fit scale 10.
    private func canvas() -> CanvasNSView {
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.set(image: image(width: 40, height: 30), url: URL(fileURLWithPath: "/a.cr3"))
        return view
    }

    private let face = CGRect(x: 0.75, y: 0.75, width: 0.1, height: 0.1)

    func testFocusZoomsAndCentresTheFace() {
        let view = canvas()
        view.focus(face: face)
        // 4 x 3 px face should cover 40 % of the view: scale 40, i.e. zoom 4.
        XCTAssertEqual(view.zoom, 4, accuracy: 0.0001)
        // Face centre is (12, 9) px from the image centre; times 40 pushed back to the middle.
        XCTAssertEqual(view.offset.x, -480, accuracy: 0.001)
        XCTAssertEqual(view.offset.y, -360, accuracy: 0.001)
    }

    func testFocusFollowsRotation() {
        let view = canvas()
        view.rotate()
        view.focus(face: face)
        // Fit scale is now 7.5 and the zoom 4 (scale 30). A quarter turn counter-clockwise maps
        // (12, 9) to (-9, 12).
        XCTAssertEqual(view.zoom, 4, accuracy: 0.0001)
        XCTAssertEqual(view.offset.x, 270, accuracy: 0.001)
        XCTAssertEqual(view.offset.y, -360, accuracy: 0.001)
    }

    func testFocusOnAHugeFaceStaysAtFit() {
        let view = canvas()
        view.focus(face: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(view.isAtFit)
        XCTAssertEqual(view.offset, .zero)
    }

    func testTheToolbarRowBelongsToTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = canvas()
        window.contentView = view
        let top = window.contentLayoutRect.maxY
        XCTAssertLessThan(top, view.frame.height, "the titlebar overlaps the full-size content")
        XCTAssertTrue(view.isInToolbarRow(NSPoint(x: 200, y: top + 5)))
        XCTAssertFalse(view.isInToolbarRow(NSPoint(x: 200, y: top - 5)))
    }

    func testFaceBoxesAreIdempotent() {
        let view = canvas()
        let boxes = [Face(rect: face, quality: nil, eyesClosed: false)]
        view.set(faces: boxes)
        XCTAssertEqual(view.faces, boxes)
        view.set(faces: [])
        XCTAssertEqual(view.faces, [])
    }
}
