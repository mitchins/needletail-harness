import Foundation
import NeedletailCore

/// M1-B in-memory session store (SPEC §9 shapes, TESTING §5 seams). Same
/// append/load/ownership SEMANTICS the M2 GRDB store will implement;
/// crash durability, WAL behavior and migrations are M2-A proofs, never
/// claimed here. Bounded at 10_000 records with a visible overflow error
/// (R19) — evidence is never silently dropped. Dev-only: never linked into
/// the shipped harness.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    public static let recordCap = 10_000

    private let lock = NSLock()
    private var log: [SequencedRecord] = []
    private var sequence: UInt64 = 0
    private var owner: String?

    public init() {}

    public func append(_ record: DurableRecord) throws {
        try lock.withLock {
            guard log.count < Self.recordCap else {
                throw StoreError.quotaExceeded(limit: Self.recordCap)
            }
            sequence += 1
            log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: record))
        }
    }

    public func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        try lock.withLock {
            let window = log.filter { $0.sequence.value > since }.prefix(limit)
            let batch = Array(window)
            let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
            return (batch, next)
        }
    }

    public func claimWriterOwnership(session: SessionID) throws {
        try lock.withLock {
            if let current = owner, current != session.raw {
                throw StoreError.alreadyOwned(session: current)
            }
            owner = session.raw
        }
    }

    public func releaseWriterOwnership(session: SessionID) {
        lock.withLock {
            if owner == session.raw {
                owner = nil
            }
        }
    }

    /// Test inspection only: total appended records.
    public var count: Int {
        lock.withLock { log.count }
    }
}
