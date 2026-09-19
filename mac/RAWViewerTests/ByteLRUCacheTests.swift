import XCTest
@testable import RAWViewer

/// Ported from `tests/test_pixmap_cache.py`.
final class ByteLRUCacheTests: XCTestCase {
    func testPutGetAndContains() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 10)
        XCTAssertEqual(cache.get("a"), "va")
        XCTAssertTrue(cache.contains("a"))
        XCTAssertNil(cache.get("missing"))
        XCTAssertFalse(cache.contains("missing"))
    }

    func testEvictsLeastRecentlyUsedWhenOverCap() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 40)
        cache.put("b", value: "vb", cost: 40)
        cache.put("c", value: "vc", cost: 40)
        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func testGetRefreshesRecency() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 40)
        cache.put("b", value: "vb", cost: 40)
        _ = cache.get("a")
        cache.put("c", value: "vc", cost: 40)
        XCTAssertTrue(cache.contains("a"))
        XCTAssertFalse(cache.contains("b"))
    }

    func testContainsDoesNotRefreshRecency() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 40)
        cache.put("b", value: "vb", cost: 40)
        XCTAssertTrue(cache.contains("a"))
        cache.put("c", value: "vc", cost: 40)
        XCTAssertFalse(cache.contains("a"))
    }

    func testReputUpdatesCost() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 90)
        cache.put("a", value: "va2", cost: 10)
        cache.put("b", value: "vb", cost: 80)
        XCTAssertEqual(cache.get("a"), "va2")
        XCTAssertTrue(cache.contains("b"))
    }

    func testNeverEvictsLastItem() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("huge", value: "v", cost: 500)
        XCTAssertTrue(cache.contains("huge"))
    }

    func testClear() {
        let cache = ByteLRUCache<String, String>(maxBytes: 100)
        cache.put("a", value: "va", cost: 10)
        cache.clear()
        XCTAssertFalse(cache.contains("a"))
        XCTAssertEqual(cache.totalCost, 0)
    }
}
