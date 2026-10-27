import Crypto
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
    private var sessionRows: [String] = []
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
            sessionRows.append(identity.session.raw)
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
                sessionRows.append(identity.session.raw)
            }
        }
    }

    public func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        guard limit > 0 else {
            throw StoreError.integrity("invalid page limit \(limit); must be > 0")
        }
        return try lock.withLock {
            let window = log.enumerated().filter {
                $0.element.sequence.value > since && sessionRows[$0.offset] == session.raw
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
                .filter { sessionRows[$0.offset] == session.raw }
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
            sessionRows.append(session.raw)
        }
    }

    /// B3-A scripted publication mirror: same contract as the GRDB publication
    /// (fencing, non-empty kind/bytes, 32 MiB cap, content-addressed dedup,
    /// per-session reference row). Bytes live in a dict (no filesystem).
    public static let artifactByteLimit = 32 * 1024 * 1024

    private var artifactBytes: [String: Data] = [:]

    public func publishArtifact(session: SessionID, as identity: WriterIdentity, kind: String, operationID: OperationID?, bytes: Data) throws -> ArtifactRef {
        try lock.withLock {
            guard session == identity.session else {
                throw StoreError.integrity("publish session/identity mismatch")
            }
            guard let owner = claims[identity.session.raw], owner == identity.writer else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
            guard !kind.isEmpty else {
                throw StoreError.integrity("artifact kind must not be empty")
            }
            guard !bytes.isEmpty else {
                throw StoreError.integrity("artifact bytes must not be empty")
            }
            guard bytes.count <= Self.artifactByteLimit else {
                throw StoreError.quotaExceeded(limit: Self.artifactByteLimit)
            }
            guard log.count + 1 <= Self.recordCap else {
                throw StoreError.quotaExceeded(limit: Self.recordCap)
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if artifactBytes[digest] == nil {
                artifactBytes[digest] = bytes
            }
            sequence += 1
            log.append(SequencedRecord(sequence: SequenceNumber(sequence),
                                       record: .artifactPublished(ArtifactRef(digest: digest, size: bytes.count, kind: kind, operationID: operationID))))
            sessionRows.append(identity.session.raw)
            return ArtifactRef(digest: digest, size: bytes.count, kind: kind, operationID: operationID)
        }
    }

    public func artifactRecord(session: SessionID, digest: String) throws -> Data? {
        return try lock.withLock {
            for (idx, rec) in log.enumerated() where sessionRows[idx] == session.raw {
                if case .artifactPublished(let ref) = rec.record, ref.digest == digest {
                    return artifactBytes[digest]
                }
            }
            return nil
        }
    }

    // MARK: - M2-C C2 spill-lease (in-memory mirror)

    private var spillLeases: [String: SpillHandle] = [:]

    public func openArtifactSpill(session: SessionID, as identity: WriterIdentity, kind: String, stream: String, requestedBytes: Int64) throws -> SpillHandle {
        try lock.withLock {
            guard session == identity.session else { throw StoreError.integrity("spill session/identity mismatch") }
            guard let owner = claims[identity.session.raw], owner == identity.writer else { throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer) }
            guard !kind.isEmpty, !stream.isEmpty else { throw StoreError.integrity("spill kind/stream empty") }
            guard requestedBytes >= 0 && requestedBytes <= 32*1024*1024 else { throw StoreError.quotaExceeded(limit: 32*1024*1024) }
            let leaseID = UUID()
            let path = NSTemporaryDirectory() + ".tmp-lease-\(leaseID.uuidString)-\(stream)"
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = SpillHandle(leaseID: leaseID, session: session, stream: stream, kind: kind, path: path, bytes: requestedBytes)
            spillLeases[leaseID.uuidString] = handle
            return handle
        }
    }

    public func publishArtifactFromFile(session: SessionID, as identity: WriterIdentity, kind: String, spill: SpillHandle) throws -> ArtifactRef {
        try lock.withLock {
            guard session == identity.session && session == spill.session else { throw StoreError.integrity("publish session mismatch") }
            guard kind == spill.kind else { throw StoreError.integrity("publish kind mismatch") }
            guard let owner = claims[identity.session.raw], owner == identity.writer else { throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer) }
            guard spillLeases[spill.leaseID.uuidString] != nil else { throw StoreError.integrity("lease not found") }
            let data = try Data(contentsOf: URL(fileURLWithPath: spill.path))
            guard data.count <= Self.artifactByteLimit else { throw StoreError.quotaExceeded(limit: Self.artifactByteLimit) }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if artifactBytes[digest] == nil { artifactBytes[digest] = data }
            sequence += 1
            let ref = ArtifactRef(digest: digest, size: data.count, kind: kind, operationID: nil)
            log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: .artifactPublished(ref)))
            sessionRows.append(identity.session.raw)
            spillLeases.removeValue(forKey: spill.leaseID.uuidString)
            try? FileManager.default.removeItem(atPath: spill.path)
            return ref
        }
    }

    public func releaseArtifactSpill(as identity: WriterIdentity, handle: SpillHandle) throws {
        try lock.withLock {
            guard let owner = claims[handle.session.raw], owner == identity.writer else { throw StoreError.notWriter(session: handle.session.raw, writer: identity.writer) }
            spillLeases.removeValue(forKey: handle.leaseID.uuidString)
            try? FileManager.default.removeItem(atPath: handle.path)
        }
    }

    /// B5-B read-only session enumeration: every session with at least
    /// one appended record, sorted for deterministic gate output.
    public func sessions() throws -> [SessionID] {
        lock.withLock {
            Array(Set(sessionRows)).sorted().map(SessionID.init)
        }
    }

    /// Test inspection only: total appended records.
    public var count: Int {
        lock.withLock { log.count }
    }
}
