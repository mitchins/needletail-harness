import Foundation
import GRDB
import NeedletailCore

/// M2-A A1: the PRODUCTION durable session store (SPEC §9, M2-A line).
/// GRDB over a real SQLite file; WAL journal with `synchronous=FULL`
/// (power-loss durability decision, plans/m2-a-plan.md §7.2 — NOTE: the
/// kill-fault matrix proves application-crash durability, which is
/// SQLite's own guarantee under WAL regardless of sync mode; it does NOT
/// experimentally verify power-loss survival).
///
/// Schema (v1): `records(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL)`
/// with DENSE sequences assigned in-transaction from `max(seq)+1`; the
/// payload is the `RecordCodec` canonical JSON for one `DurableRecord`.
/// `schema_version` lives in SQLite's `user_version`.
///
/// STORE-05: opening a store whose `user_version` is NEWER than this
/// build, or an unreadable/corrupt file, fails closed with
/// `.integrity` — migrations are forward-only and never guess.
///
/// No transaction is held over an await: every API is synchronous; async
/// callers collect work, then commit.
public final class GRDBSessionStore: SessionStore, @unchecked Sendable {

    /// Current schema version. Bump ONLY with a forward-only migration.
    /// Current schema version (public: STORE-05 tests stamp a FUTURE
    /// version to prove fail-closed opening).
    public static let schemaVersion: Int32 = 1

    private let queue: DatabaseQueue
    /// The opened file path (public for reopen-test legibility).
    public let path: String
    /// Writer slot cache mirror (single-handle fast path); SQL is the
    /// authority — the cache only avoids a read before each claim.
    private let lock = NSLock()
    private var ownerCache: String?

    public init(path: String) throws {
        self.path = path
        var configuration = Configuration()
        configuration.journalMode = .wal
        // synchronous must be set OUTSIDE any transaction (prepareDatabase
        // runs at connection setup); journalMode is applied by GRDB itself.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        do {
            self.queue = try DatabaseQueue(path: path, configuration: configuration)
        } catch {
            throw StoreError.integrity("store open failed: \(error)")
        }
        do {
            try migrateIfNeeded()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.integrity("store unreadable (corrupt or not a needletail store): \(error)")
        }
    }

    /// Forward-only migration to `schemaVersion`. A NEWER database is a
    /// hard failure (the binary must never guess at future schema).
    private func migrateIfNeeded() throws {
        try queue.write { db in
            let version = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version > Self.schemaVersion {
                throw StoreError.integrity(
                    "future schema version \(version) > supported \(Self.schemaVersion); refusing to open")
            }
            guard version < Self.schemaVersion else { return }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records(
                    seq INTEGER PRIMARY KEY,
                    payload TEXT NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS writer(
                    slot INTEGER PRIMARY KEY CHECK (slot = 1),
                    owner TEXT NOT NULL)
                """)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    public func append(_ record: DurableRecord) throws {
        // The codec throws .integrity for nothing today (all shapes
        // encodable); encode BEFORE the transaction so a failure cannot
        // leave a half-written row.
        let payload = try RecordCodec.encode(record)
        try queue.write { db in
            let last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            try db.execute(
                sql: "INSERT INTO records (seq, payload) VALUES (?, ?)",
                arguments: [last + 1, String(decoding: payload, as: UTF8.self)])
        }
    }

    /// Single-transaction bulk append (import/migration tooling and scale
    /// fixtures). Protocol `append` remains the durability path — one
    /// commit per record; this convenience deliberately commits ONCE for
    /// the whole batch.
    public func appendBatch(_ records: [DurableRecord]) throws {
        let payloads = try records.map { try RecordCodec.encode($0) }
        try queue.write { db in
            var last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            for payload in payloads {
                last += 1
                try db.execute(
                    sql: "INSERT INTO records (seq, payload) VALUES (?, ?)",
                    arguments: [last, String(decoding: payload, as: UTF8.self)])
            }
        }
    }

    public func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records WHERE seq > ? ORDER BY seq LIMIT ?
                """, arguments: [since, limit])
        }
        // Every row decodes through the codec; a corrupted row is
        // `.integrity` — never skipped, never substituted.
        let batch = try rows.map { row -> SequencedRecord in
            let seq: Int64 = row["seq"]
            let payload: String = row["payload"]
            return try SequencedRecord(
                sequence: SequenceNumber(UInt64(seq)),
                record: RecordCodec.decode(Data(payload.utf8)))
        }
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// Global writer slot (A1 semantics — same as the M2-0 probes):
    /// a DIFFERENT session contending fails with the current owner;
    /// same-session reclaim is an idempotent no-op. Writer-identity
    /// FENCING for one session is A2 (STORE-06).
    public func claimWriterOwnership(session: SessionID) throws {
        try queue.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT owner FROM writer WHERE slot = 1")
            if let current, current != session.raw {
                throw StoreError.alreadyOwned(session: current)
            }
            if current == nil {
                try db.execute(
                    sql: "INSERT INTO writer (slot, owner) VALUES (1, ?)",
                    arguments: [session.raw])
            }
        }
        lock.withLock { ownerCache = session.raw }
    }

    public func releaseWriterOwnership(session: SessionID) {
        try? queue.write { db in
            try db.execute(
                sql: "DELETE FROM writer WHERE slot = 1 AND owner = ?",
                arguments: [session.raw])
        }
        lock.withLock {
            if ownerCache == session.raw { ownerCache = nil }
        }
    }

    /// A1 test/receipt support: GRDB reaps the connection on deinit; an
    /// explicit close lets the reopen tests hand the file to a FRESH
    /// handle deterministically.
    public func close() throws {
        try queue.close()
    }
}
