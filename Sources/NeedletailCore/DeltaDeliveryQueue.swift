import Foundation

/// Bounded delivery queue for incremental display deltas (M1-D H1). The
/// NIO delegate is synchronous, so deltas are enqueued here without waiting;
/// a single consumer drains the queue in arrival order and emits each
/// projection through the `UISink`. Overflow surfaces as `UISinkError` so
/// backpressure is explicit instead of spawning an unbounded task per
/// fragment.
public final class DeltaDeliveryQueue: @unchecked Sendable {
    public struct Item: Sendable {
        public let outcome: RequestID
        public let text: String

        public init(requestID: RequestID, text: String) {
            self.outcome = requestID
            self.text = text
        }
    }

    private let lock = NSLock()
    private var buffer: [Item] = []
    private var pendingBytes: Int = 0
    private var itemCap: Int
    private var byteCap: Int
    private var itemBytes: [Int] = []
    private var waiters: [CheckedContinuation<Item?, Never>] = []
    private var consumer: Task<Void, Never>?
    private var startedConsumer: Bool = false
    private var finished: Bool = false
    private let itemSize: (Item) -> Int
    private let onDeliver: @Sendable (Item) async -> Void

    public init(
        itemCap: Int,
        byteCap: Int,
        itemSize: @escaping @Sendable (Item) -> Int = { item in item.text.utf8.count },
        onDeliver: @escaping @Sendable (Item) async -> Void
    ) {
        self.itemCap = itemCap
        self.byteCap = byteCap
        self.itemSize = itemSize
        self.onDeliver = onDeliver
    }

    public enum OfferResult: Equatable, Sendable {
        case accepted
        case overflow(itemCount: Int, byteCount: Int)
    }

    public func enqueue(_ item: Item) -> OfferResult {
        let bytes = itemSize(item)
        var waiter: CheckedContinuation<Item?, Never>?
        var startConsumer = false
        var accepted = false
        var overflowCounts: (Int, Int)?
        lock.lock()
        if finished {
            lock.unlock()
            return .overflow(itemCount: buffer.count, byteCount: pendingBytes)
        }
        if buffer.count < itemCap, pendingBytes + bytes <= byteCap {
            if !waiters.isEmpty {
                waiter = waiters.removeFirst()
            } else {
                buffer.append(item)
                itemBytes.append(bytes)
                pendingBytes += bytes
            }
            accepted = true
            accepted = true
        } else {
            overflowCounts = (buffer.count, pendingBytes)
        }
        lock.unlock()

        if let waiter = waiter {
            waiter.resume(returning: item)
        }
        if let counts = overflowCounts {
            return .overflow(itemCount: counts.0, byteCount: counts.1)
        }
        return .accepted
    }

    public func finish() {
        lock.lock()
        finished = true
        let drainPendingWaiters = buffer.isEmpty
        let pendingWaiters = (drainPendingWaiters ? waiters : [])
        if drainPendingWaiters {
            waiters.removeAll()
        }
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume(returning: nil)
        }

    }

    public func run() async {
        while let item = await receive() {
            await onDeliver(item)
        }
    }

    public func drain() async {
        finish()
        await consumer?.value
    }

    private func receive() async -> Item? {
        return await withCheckedContinuation { continuation in
            self.lock.lock()
            if !self.buffer.isEmpty {
                let item = self.buffer.removeFirst()
                self.pendingBytes -= self.itemBytes.removeFirst()
                self.lock.unlock()
                continuation.resume(returning: item)
            } else if self.finished {
                self.lock.unlock()
                continuation.resume(returning: nil)
            } else {
                self.waiters.append(continuation)
                self.lock.unlock()
            }
        }
    }

}
