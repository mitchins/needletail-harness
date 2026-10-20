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
    /// A3-3 authorized ownership takeover (SPEC §9.1 recovery): the full
    /// audit of one writer transition, committed atomically WITH the
    /// ownership update. Reconstructible without any side channel: the
    /// session comes from the row's session attribution, everything else
    /// travels in `WriterRecovery` (previous/new writer, operator
    /// authorization reference, and the held-operation evidence).
    case writerRecovered(WriterRecovery)
    /// A4-1 artifact publication reference (SPEC §9.1): the database stores
    /// the relative path, digest, size and identity/metadata — NEVER the
    /// blob. The bytes live content-addressed under the managed artifacts
    /// root; this record is committed only AFTER the file is durable
    /// (write → fsync → atomic rename → dirsync → txn). Reads re-verify
    /// size and digest and fail typed `.integrity` on any mismatch.
    case artifactPublished(ArtifactRef)
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

/// A3-3 authorized takeover proof. This is NOT a boolean and NOT an
/// unverified caller string: it names the exact transition authorized
/// (session + expected current writer + new writer, binding the proof so
/// it cannot be replayed against a different takeover), WHO authorized it
/// (operator identity — never a credential or bearer token, which are not
/// representable here and must never be persisted), and the reviewable
/// trail (authorization reference such as a ticket/approval ID, the human
/// reason, and the decision time). The full value is persisted in the
/// `writerRecovered` audit record. In-process callers cannot forge
/// out-of-band operator identity — the guarantee is accountability (every
/// takeover names its authorizer and reference durably), scope binding
/// (replay against another session/writer fails closed), and fencing (a
/// stale or forged expected-writer fails closed).
public struct RecoveryAuthorization: Sendable, Equatable, Codable {
    public let session: SessionID
    public let expectedWriter: String
    public let newWriter: String
    public let operatorID: String
    public let reference: String
    public let reason: String
    public let atMillis: UInt64

    public init(
        session: SessionID, expectedWriter: String, newWriter: String,
        operatorID: String, reference: String, reason: String, atMillis: UInt64
    ) {
        self.session = session
        self.expectedWriter = expectedWriter
        self.newWriter = newWriter
        self.operatorID = operatorID
        self.reference = reference
        self.reason = reason
        self.atMillis = atMillis
    }

    /// Validates the proof against the requested takeover: every identity
    /// and trail field present, a genuine transition (new != expected),
    /// and exact scope binding (this proof authorizes THIS takeover, not
    /// another session or writer pair).
    public func validated(
        for session: SessionID, expectedWriter: String, newWriter: String
    ) throws {
        guard !expectedWriter.isEmpty, !newWriter.isEmpty else {
            throw StoreError.integrity("recovery requires non-empty writer identities")
        }
        guard newWriter != expectedWriter else {
            throw StoreError.integrity("recovery to the same identity is not a takeover")
        }
        guard !operatorID.isEmpty, !reference.isEmpty, !reason.isEmpty else {
            throw StoreError.integrity("recovery requires operator identity, authorization reference and reason")
        }
        guard self.session == session,
              self.expectedWriter == expectedWriter,
              self.newWriter == newWriter else {
            throw StoreError.integrity("recovery authorization does not bind this session/writer transition")
        }
    }
}

/// A3-3 durable takeover audit (SPEC §9.1 recovery): previous and new
/// writer IDs, the operator authorization (identity + reference + reason,
/// never credentials), the decision time, and the unresolved-operation
/// evidence that the takeover preserved (unknown-state refs — holds are
/// NOT cleared by recovery). Persisted as
/// `DurableRecord.writerRecovered`, attributed to the recovered session.
public struct WriterRecovery: Sendable, Equatable, Codable {
    public let previousWriter: String
    public let newWriter: String
    public let operatorID: String
    public let reference: String
    public let reason: String
    public let atMillis: UInt64
    public let unresolvedOperations: [OperationRef]

    public init(
        previousWriter: String, newWriter: String,
        operatorID: String, reference: String, reason: String, atMillis: UInt64,
        unresolvedOperations: [OperationRef]
    ) {
        self.previousWriter = previousWriter
        self.newWriter = newWriter
        self.operatorID = operatorID
        self.reference = reference
        self.reason = reason
        self.atMillis = atMillis
        self.unresolvedOperations = unresolvedOperations
    }
}

/// A4-1 artifact reference (SPEC §9.1): the database half of a published
/// artifact. `digest` is the lowercase hex SHA-256 of the EXACT bytes;
/// the file lives content-addressed at `relativePath` (== digest) under
/// the store's managed artifacts root. `size` is the byte count;
/// `kind` names the artifact class (non-empty, e.g. "exec-output");
/// `operationID` optionally binds the artifact to the operation that
/// produced it (metadata only — publication never infers operation
/// outcomes from it). No credentials, no absolute paths, no blobs.
public struct ArtifactRef: Sendable, Equatable, Codable {
    public let digest: String
    public let size: Int
    public let kind: String
    public let operationID: OperationID?

    public init(digest: String, size: Int, kind: String, operationID: OperationID? = nil) {
        self.digest = digest
        self.size = size
        self.kind = kind
        self.operationID = operationID
    }

    /// Content-addressed relative path inside the managed root.
    public var relativePath: String { digest }
}

public protocol SessionStore: Sendable {
    /// FENCED durable append: implementations validate, INSIDE the
    /// mutation's own transaction, that `identity.writer` currently owns
    /// `identity.session`. A stale writer (never claimed, superseded, or
    /// voided by recovery) fails closed with `.notWriter`.
    func append(_ record: DurableRecord, as identity: WriterIdentity) throws
    /// A3-1 ATOMIC batch commit: a transition's whole record group commits
    /// as ONE unit — no partially committed intent/result batch. The
    /// fencing check covers the whole group inside the same transaction.
    /// Production (GRDB) and scripted (InMemory) stores override with a
    /// real single-transaction implementation; the default sequential loop
    /// keeps diagnostic-only conformances compiling without claiming
    /// atomicity they do not provide.
    func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws
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
    /// A3-3 EXPLICIT ownership recovery: a trusted-operator-authorized
    /// takeover of `session` from `expectedWriter` to `newWriter`, with
    /// the audit committed IN THE SAME transaction as the ownership
    /// update. The expected writer must match the current holder — no
    /// unconditional replace, no PID/timeout/absence authority, no
    /// automatic recovery. An invalid operation ledger fails the whole
    /// transaction (no takeover, no audit row). Recovery preserves every
    /// unresolved-operation hold: it establishes NOTHING about external
    /// operations, clears no markers, retries nothing. Production (GRDB)
    /// and scripted (InMemory) stores implement this; other conformances
    /// inherit the fail-closed default.
    func recoverWriterOwnership(
        session: SessionID, expectedWriter: String, newWriter: String,
        authorization: RecoveryAuthorization
    ) throws
}

extension SessionStore {
    /// Default sequential batch (NO atomicity claim): diagnostic-only
    /// conformances inherit this. Durable paths must override.
    public func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
        for record in records {
            try append(record, as: identity)
        }
    }

    /// Default recovery refusal: stores without a fenced atomic takeover
    /// fail closed rather than half-recover.
    public func recoverWriterOwnership(
        session: SessionID, expectedWriter: String, newWriter: String,
        authorization: RecoveryAuthorization
    ) throws {
        _ = session; _ = expectedWriter; _ = newWriter; _ = authorization
        throw StoreError.integrity("writer recovery is not supported by this store")
    }
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
