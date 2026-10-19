/// M1-B durability shapes + store seams (SPEC §9, ARCH §§1/7). The row
/// shapes mirror the normative tables (sessions/epochs/events/operations/
//// queue) as values; SQL lives in M2-A. M1-B appends to the seam and proves
/// the ORDER (intent before dispatch) — crash durability is M2's proof.

public enum DurableRecord: Sendable, Equatable, Codable {
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
    /// Another live writer holds the session; BOTH identities travel.
    case alreadyOwned(session: String, writer: String)
    /// The calling identity does not currently own the session (never
    /// claimed, superseded by another writer, or voided by recovery).
    /// Fenced mutations and releases refuse with this — never a silent
    /// success.
    case notWriter(session: String, writer: String)
    case quotaExceeded(limit: Int)
    /// Bounded lock contention exhausted (busy timeout): the database is
    /// healthy but another writer held it past the bound. DISTINCT from
    /// corruption (`.integrity`) — retrying later is meaningful.
    case contention(String)
    case integrity(String)
}

/// A live writer instance bound to exactly one session. `session` and
/// `writer` are DISTINCT identities: `writer` identifies one live writer
/// INSTANCE (unique among concurrent writers of the session; uniqueness
/// across processes is the caller's contract — a restarted process
/// re-claims explicitly with the SAME identity). Every durable mutation
/// is fenced inside the mutation's own transaction against the current
/// `(session, writer)` ownership row; a stale writer fails closed.
public struct WriterIdentity: Sendable, Equatable, Codable {
    public let session: SessionID
    public let writer: String

    public init(session: SessionID, writer: String) {
        self.session = session
        self.writer = writer
    }
}

public protocol SessionStore: Sendable {
    /// FENCED durable append: implementations validate, INSIDE the
    /// mutation's own transaction, that `identity.writer` currently owns
    /// `identity.session`. A stale writer (never claimed, superseded, or
    /// voided by recovery) fails closed with `.notWriter`.
    func append(_ record: DurableRecord, as identity: WriterIdentity) throws
    /// Paged read (R15): bounded batches with an explicit cursor — history
    /// is never loaded wholesale (SPEC §9.2, ARCH §1).
    /// SESSION-SCOPED paged read (R15 + A2 isolation): returns ONLY this
    /// session's records, in global-sequence order, with per-session cursor
    /// paging. Cross-session content is unrepresentable in the result.
    func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?)
    /// UNSCOPED diagnostic read (support tooling/tests only): pages the
    /// WHOLE store across sessions. Never feed this to a model request.
    func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?)
    /// Claim exclusive write ownership of `session` for `writer`. A
    /// different live writer holding the session fails with
    /// `.alreadyOwned(session:writer:)` (both identities travel);
    /// re-claiming with the SAME identity is an idempotent no-op
    /// (crash-recovery re-acquire).
    func claimWriterOwnership(session: SessionID, writer: String) throws
    /// Release ownership. Only the CURRENT writer of the session can
    /// release: a stale identity fails closed with `.notWriter` and never
    /// removes a newer writer's claim.
    func releaseWriterOwnership(session: SessionID, writer: String) throws
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
