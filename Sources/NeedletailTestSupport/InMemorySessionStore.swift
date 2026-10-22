import Foundation
import NeedletailCore

/// M1-B in-memory session store (SPEC §9 shapes, TESTING §5 seams). Same
/// append/load/ownership SEMANTICS the M2 GRDB store implements; crash
/// durability, WAL behavior and migrations are M2-A proofs, never
/// claimed here. Bounded at 10_000 records with a visible overflow error
/// (R19) — evidence is never silently dropped. Dev-only: never linked into
/// the shipped harness.
///
/// A2 FENCING: `claims` maps session → owning writer. `append(as:)` is
/// fenced against the map inside the mutation; a stale writer fails
/// closed with `.notWriter`.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    public static let recordCap = 10_000

    private let lock = NSRecursiveLock()
    private var log: [SequencedRecord] = []
    /// Per-record session attribution, index-aligned with `log`.
    private var sessions: [String] = []
    private var sequence: UInt64 = 0
    /// session → owning writer (A2 fencing).
    private var claims: [String: String] = [:]

    public init() {}

    public func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
        try lock.withLock {
            guard let owner = claims[identity.session.raw] else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
            guard owner == identity.writer else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
            guard log.count < Self.recordCap else {
                throw StoreError.quotaExceeded(limit: Self.recordCap)
            }
            sequence += 1
            log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: record))
            sessions.append(identity.session.raw)
        }
    }

    public func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
        // A3-1 atomic override: validate EVERYTHING first (fencing, quota
        // for the whole group), then commit — a failing batch leaves the
        // log untouched, never partially committed.
        try lock.withLock {
            guard let owner = claims[identity.session.raw], owner == identity.writer else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
            guard log.count + records.count <= Self.recordCap else {
                throw StoreError.quotaExceeded(limit: Self.recordCap)
            }
            for record in records {
                sequence += 1
                log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: record))
                sessions.append(identity.session.raw)
            }
        }
    }

    public func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        guard limit > 0 else {
            throw StoreError.integrity("invalid page limit \(limit); must be > 0")
        }
        return try lock.withLock {
            let window = log.enumerated().filter {
                $0.element.sequence.value > since && sessions[$0.offset] == session.raw
            }.prefix(limit).map { $0.element }
            let next: UInt64? = window.count < limit ? nil : window.last?.sequence.value
            return (window, next)
        }
    }

    /// UNSCOPED diagnostic read (support tooling/tests only).
    public func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        try lock.withLock {
            let window = log.filter { $0.sequence.value > since }.prefix(limit)
            let batch = Array(window)
            let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
            return (batch, next)
        }
    }

    public func claimWriterOwnership(session: SessionID, writer: String) throws {
        try lock.withLock {
            if let current = claims[session.raw], current != writer {
                throw StoreError.alreadyOwned(session: session.raw, writer: current)
            }
            claims[session.raw] = writer
        }
    }

    public func releaseWriterOwnership(session: SessionID, writer: String) throws {
        try lock.withLock {
            // Only the CURRENT writer of the session can release: a stale
            // identity fails closed and never removes a newer claim.
            guard claims[session.raw] == writer else {
                throw StoreError.notWriter(session: session.raw, writer: writer)
            }
            claims[session.raw] = nil
        }
    }

    /// A3-3 scripted takeover mirror: same contract as the GRDB recovery
    /// (guarded match → reconcile → quota → swap + audit), atomic under
    /// the single lock. Holds are preserved, never cleared.
    public func recoverWriterOwnership(
        session: SessionID, expectedWriter: String, newWriter: String,
        authorization: RecoveryAuthorization
    ) throws {
        try lock.withLock {
            try authorization.validated(
                for: session, expectedWriter: expectedWriter, newWriter: newWriter)
            guard let current = claims[session.raw] else {
                throw StoreError.notWriter(session: session.raw, writer: expectedWriter)
            }
            guard current == expectedWriter else {
                throw StoreError.alreadyOwned(session: session.raw, writer: current)
            }
            let stream = log.enumerated()
                .filter { sessions[$0.offset] == session.raw }
                .map { $0.element.record }
            let report = try reconcileOperations(stream)
            guard log.count + 1 <= Self.recordCap else {
                throw StoreError.quotaExceeded(limit: Self.recordCap)
            }
            claims[session.raw] = newWriter
            sequence += 1
            log.append(SequencedRecord(
                sequence: SequenceNumber(sequence),
                record: .writerRecovered(WriterRecovery(
                    previousWriter: expectedWriter, newWriter: newWriter,
                    operatorID: authorization.operatorID, reference: authorization.reference,
                    reason: authorization.reason, atMillis: authorization.atMillis,
                    unresolvedOperations: report.heldOperations))))
            sessions.append(session.raw)
        }
    }

    public func artifactRecord(session: SessionID, digest: String) throws -> Data? {
        // For InMemory, check log for artifactPublished for this session with digest
        // Note: InMemory doesn't store artifact bytes, so we return nil (not found) for now
        // B2 tests using GRDB will use the real store; InMemory artifact reads are not covered
        return try lock.withLock {
            for (idx, rec) in log.enumerated() where sessions[idx] == session.raw {
                if case .artifactPublished(let ref) = rec.record, ref.digest == digest {
                    // InMemory doesn't have file storage, so we can't return bytes
                    // Return nil to indicate not found (will be denied)
                    return nil
                }
            }
            return nil
        }
    }

    /// Test inspection only: total appended records.
    public var count: Int {
        lock.withLock { log.count }
    }
}
