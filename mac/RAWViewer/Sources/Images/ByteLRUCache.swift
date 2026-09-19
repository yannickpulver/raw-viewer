import Foundation

/// Cost-bounded LRU. Exact semantics of spec 04 §8:
/// `get` refreshes recency, `contains` does not, re-putting a key replaces its cost,
/// and the last remaining entry is never evicted even if it alone exceeds the budget.
public final class ByteLRUCache<Key: Hashable, Value> {
    private struct Node {
        var value: Value
        var cost: Int
    }

    private var storage: [Key: Node] = [:]
    private var order: [Key] = []
    public private(set) var totalCost: Int = 0
    public var maxBytes: Int

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    public var count: Int { storage.count }

    public func get(_ key: Key) -> Value? {
        guard let node = storage[key] else { return nil }
        touch(key)
        return node.value
    }

    public func contains(_ key: Key) -> Bool {
        storage[key] != nil
    }

    public func put(_ key: Key, value: Value, cost: Int) {
        if let existing = storage[key] {
            totalCost -= existing.cost
            order.removeAll { $0 == key }
        }
        storage[key] = Node(value: value, cost: cost)
        order.append(key)
        totalCost += cost
        evictIfNeeded()
    }

    @discardableResult
    public func remove(_ key: Key) -> Value? {
        guard let node = storage.removeValue(forKey: key) else { return nil }
        totalCost -= node.cost
        order.removeAll { $0 == key }
        return node.value
    }

    public func clear() {
        storage.removeAll()
        order.removeAll()
        totalCost = 0
    }

    public var keys: [Key] { order }

    /// Non-mutating read: returns the value without refreshing recency. Spec 04 §8 keeps that
    /// behaviour in `get`; `peek` exists for reads made from a SwiftUI `body`.
    public func peek(_ key: Key) -> Value? { storage[key]?.value }

    /// Explicit recency refresh, for callers that read with `peek`.
    public func touchKey(_ key: Key) { touch(key) }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while totalCost > maxBytes && order.count > 1 {
            let oldest = order.removeFirst()
            if let node = storage.removeValue(forKey: oldest) {
                totalCost -= node.cost
            }
        }
    }
}
