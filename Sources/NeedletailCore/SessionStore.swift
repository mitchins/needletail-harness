/// M1-B durability shapes + store seams (SPEC §9, ARCH §§1/7). The row
/// shapes mirror the normative tables (sessions/epochs/events/operations/
//// queue) as values; SQL lives in M2-A. M1-B appends to the seam and proves
/// the ORDER (intent before dispatch) — crash durability is M2's proof.

public enum DurableRecord: Sendable, Equatable {
    case sessionOpened(session: SessionID, atMillis: UInt64)
    case epochOpened(EpochDescriptor)
    case eventAppended(seq: SequenceNumber, kind: String, digest: String)
    case operationIntent(OperationRef)
    case operationResult(OperationRef, outcome: String)
    case queueAdmitted(QueueEntry)
    case queueUpdated(QueueEntry)
    case checkpointCommitted(EpochDescriptor)
    /// Authoritative conversation element (M1-D transcript, ARCH §1).
    case transcriptAppended(TranscriptEntry)
}

public struct SequencedRecord: Sendable, Equatable {
    public let sequence: SequenceNumber
    public let record: DurableRecord

    public init(sequence: SequenceNumber, record: DurableRecord) {
        self.sequence = sequence
        self.record = record
    }
}

public enum StoreError: Error, Sendable, Equatable {
    case alreadyOwned(session: String)
    case notOwner(session: String)
    case quotaExceeded(limit: Int)
    case integrity(String)
}

public protocol SessionStore: Sendable {
    func append(_ record: DurableRecord) throws
    /// Paged read (R15): bounded batches with an explicit cursor — history
    /// is never loaded wholesale (SPEC §9.2, ARCH §1).
    func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?)
    /// Single-writer ownership (kept for M2 STORE-06; the single M1-B actor
    /// never contends — documented seam, not dead abstraction).
    func claimWriterOwnership(session: SessionID) throws
    func releaseWriterOwnership(session: SessionID)
}

/// Bounded intake/spool channel as a VALUE (STATE-04, R6/R12): pure
/// offer/poll over scripted sequences — liveness becomes finite folds, so
/// "no hang" is terminable-by-construction within an explicit step cap.
/// Authoritative payloads are never silently dropped (overflow is a typed,
/// visible outcome); only replaceable display deltas may coalesce (ARCH §6).
public struct BoundedChannelState<Item: Sendable & Equatable>: Sendable, Equatable {
    public var items: [Item]
    public var sizes: [Int]
    public let itemCap: Int
    public let byteCap: Int

    public init(itemCap: Int, byteCap: Int) {
        self.items = []
        self.sizes = []
        self.itemCap = itemCap
        self.byteCap = byteCap
    }

    public enum OfferResult: Sendable, Equatable {
        case accepted(depth: Int)
        case overflow(itemCount: Int, byteCount: Int)
    }

    public var usedBytes: Int { sizes.reduce(0, +) }

    public mutating func offer(_ item: Item, bytes: Int) -> OfferResult {
        guard items.count < itemCap, usedBytes + bytes <= byteCap else {
            return .overflow(itemCount: items.count, byteCount: usedBytes)
        }
        items.append(item)
        sizes.append(bytes)
        return .accepted(depth: items.count)
    }

    public mutating func poll() -> Item? {
        guard !items.isEmpty else { return nil }
        sizes.removeFirst()
        return items.removeFirst()
    }
}

/// Intake budgets (R6): provider-event intake 512 items / 4 MiB.
public func providerIntakeChannel<Item: Sendable & Equatable>() -> BoundedChannelState<Item> {
    BoundedChannelState(itemCap: 512, byteCap: 4 << 20)
}

/// UI-bound spool budgets: 128 items / 512 KiB.
public func uiSpoolChannel<Item: Sendable & Equatable>() -> BoundedChannelState<Item> {
    BoundedChannelState(itemCap: 128, byteCap: 512 << 10)
}
