import AppKit
import XCTest
@testable import RAWViewer

@MainActor
final class SelectionMenuTests: XCTestCase {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("RAWViewerTests-\(UUID().uuidString)"))

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func menu(_ urls: [URL]) -> (NSMenu, SelectionMenuController) {
        let controller = SelectionMenuController(urls: urls, view: NSView(), rect: .zero, pasteboard: pasteboard)
        return (controller.makeMenu(), controller)
    }

    func testCopyPathPutsPlainPathsOnThePasteboard() throws {
        let urls = [URL(fileURLWithPath: "/shoot/a.raf"), URL(fileURLWithPath: "/shoot/b.raf")]
        let (menu, controller) = menu(urls)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Copy 2 Paths" })
        _ = controller.perform(item.action)

        XCTAssertEqual(pasteboard.string(forType: .string), "/shoot/a.raf\n/shoot/b.raf")
        XCTAssertNil(pasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])?.first)
    }

    func testSingleFileTitle() {
        let (menu, _) = menu([URL(fileURLWithPath: "/shoot/a.raf")])
        XCTAssertEqual(menu.items.map(\.title), ["Share", "Reveal in Finder", "Copy", "Copy Path"])
    }
}
