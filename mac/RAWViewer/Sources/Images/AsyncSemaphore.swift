import Foundation

/// Minimal counting semaphore for bounding concurrent decode tasks without blocking a thread.
///
/// `wait()` is cancellation-aware: a task cancelled while queued resumes immediately and does
/// *not* consume a permit, and a task cancelled after it was already handed a permit still owns
/// it (so it must still `signal()`). `withPermit` handles both cases.
public actor AsyncSemaphore {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []
    private var nextID = 0

    public init(value: Int) {
        self.available = value
    }

    /// Returns `true` when a permit was acquired (the caller must `signal()`), `false` when the
    /// call was cancelled while queued (no permit, nothing to release).
    @discardableResult
    public func wait() async -> Bool {
        if Task.isCancelled { return false }
        if available > 0 {
            available -= 1
            return true
        }
        nextID &+= 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    public func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Runs `body` while holding a permit. When the caller is cancelled before a permit is
    /// granted, `body` still runs (its own `Task.isCancelled` checks decide what to do) but no
    /// permit is held and none is released — the counter can never drift.
    public func withPermit<T>(_ body: @Sendable () async -> T) async -> T {
        let acquired = await wait()
        let result = await body()
        if acquired { signal() }
        return result
    }

    /// Test hook.
    var availablePermits: Int { available }
    var waiterCount: Int { waiters.count }
}
