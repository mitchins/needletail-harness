import Foundation
import GRDB
import NeedletailCore

/// M2-A A1/A2: the PRODUCTION durable session store (SPEC §9, M2-A line).
/// GRDB over a real SQLite file; WAL journal with `synchronous=FULL`
/// (power-loss durability decision, plans/m2-a-plan.md §7.2 — NOTE: the
/// kill-fault matrix proves application-crash durability, which is
/// SQLite's own guarantee under WAL regardless of sync mode; it does NOT
/// experimentally verify power-loss survival).
///
/// GRDB ORDERING HAZARD (A1 review): `DatabaseQueue.init` applies
/// `journalMode = .wal` AFTER running `prepareDatabase`, and its WAL setup
/// UNCONDITIONALLY executes `PRAGMA synchronous = NORMAL`. The FULL sync
/// is therefore set AFTER init via `writeWithoutTransaction` — never in
/// `prepareDatabase`.
///
/// Schema v1: `records(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL)`
/// with DENSE sequences assigned in-transaction from `max(seq)+1`; the
/// payload is the `RecordCodec` canonical JSON for one `DurableRecord`.
/// `schema_version` lives in SQLite's `user_version`.
///
/// STORE-05: opening a store whose `user_version` is NEWER than this
/// build, a v0 file containing FOREIGN tables, a database whose table
/// shapes (column names, declared types, primary keys) disagree with the
/// declared schema, or an unreadable/corrupt file fails closed with
/// `.integrity` — migrations are forward-only and never guess or silently
/// adopt a foreign schema.
///
/// CONCURRENCY: every operation (including `close`) serializes on one
/// gate lock, so the documented typed-error contract holds under
/// concurrency — an operation either completes before close, or fails
/// with `.integrity("store is closed")`; a closed `DatabaseQueue` is
/// never observable.
public final class GRDBSessionStore: SessionStore, @unchecked Sendable {

    /// Current schema version. Bump ONLY with a forward-only migration.
    /// Public: STORE-05 tests stamp a FUTURE version to prove fail-closed
    /// opening. v2 (A2): fenced writer ownership per session
    /// (`writer(session, writer)`) and per-row session attribution
    /// (`records.session`) for session quotas. v1 ownership claims are
    /// VOIDED by the upgrade (the old slot model had no writer identity):
    /// explicit re-claim is required — fail-closed recovery.
    public static let schemaVersion: Int32 = 2

    private let queue: DatabaseQueue
    /// The opened file path (public for reopen-test legibility).
    public let path: String
    /// STORE-09 quotas, enforced INSIDE each fenced append transaction.
    public let sessionRecordLimit: Int
    public let globalRecordLimit: Int
    private var closed = false
    /// Serializes every operation against `close` so the typed
    /// closed-store contract holds atomically (A1 stabilization).
    private let gate = NSLock()

    public init(path: String, sessionRecordLimit: Int = 10_000, globalRecordLimit: Int = 100_000) throws {
        self.path = path
        self.sessionRecordLimit = sessionRecordLimit
        self.globalRecordLimit = globalRecordLimit
        var configuration = Configuration()
        configuration.journalMode = .wal
        // A2 review: bound lock contention (typed failures, never raw
        // SQLITE_BUSY). Transaction KIND is auto-managed by GRDB 7.11
        // (write closures run IMMEDIATE where needed) — the comments in
        // this file say "BEGIN IMMEDIATE transaction" meaning the fenced
        // write transaction; GRDB guarantees its atomicity either way.
        configuration.busyMode = .timeout(5)
        do {
            self.queue = try DatabaseQueue(path: path, configuration: configuration)
        } catch {
            // GRDB validates the file format on first touch (SQLITE_NOTADB
            // for non-database bytes) — a corrupt/non-store file fails here.
            throw StoreError.integrity("store open failed: \(error)")
        }
        do {
            // GRDB's WAL setup ran INSIDE init and forced synchronous=NORMAL;
            // re-assert FULL outside any transaction (PRAGMA rejects sync
            // changes inside one).
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
            try migrateIfNeeded()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.integrity("store unreadable (corrupt or not a needletail store): \(error)")
        }
    }

    /// Forward-only migration to `schemaVersion`. A NEWER database is a
    /// hard failure (the binary must never guess at future schema); a v0
    /// file containing FOREIGN tables is never adopted; an EXISTING
    /// database whose table shapes disagree with the declared schema is
    /// not a needletail store.
    private func migrateIfNeeded() throws {
        try queue.write { db in
            let version = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version > Self.schemaVersion {
                throw StoreError.integrity(
                    "future schema version \(version) > supported \(Self.schemaVersion); refusing to open")
            }
            if version == 0 {
                // A brand-new file has no user tables. A v0 file that DOES
                // have user tables is either a crashed mid-migration store
                // (only OUR tables, correct shape → resume) or a FOREIGN
                // database (anything else → reject before we touch it).
                let userTables = try Set(String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
                if !userTables.isEmpty && userTables != Set(Self.declaredShape.keys) {
                    throw StoreError.integrity(
                        "foreign unversioned store: tables [\(userTables.sorted().joined(separator: ", "))] are not a needletail schema")
                }
            }
            guard version < Self.schemaVersion else {
                // Already at our version: the shapes must still MATCH. A
                // file stamped with our version but carrying foreign or
                // missing tables is not a needletail store.
                try Self.assertSchemaShape(db)
                // The session index must exist on EVERY v2 file — including
                // ones stamped v2 before the index landed (pre-fold A2) —
                // and ONLY after the fail-closed checks above passed.
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS records_session ON records(session, seq)
                    """)
                return
            }
            if version < 1 {
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
                try db.execute(sql: "PRAGMA user_version = 1")
            }
            if version < 2 {
                // v2: per-row session attribution + per-session fenced
                // ownership. v1 rows had no session context — they backfill
                // to "" (counted toward the GLOBAL quota, attributable to no
                // session). v1 slot-based claims are VOID: the old model had
                // no writer identity, so explicit re-claim is required.
                // Consequence (documented): backfilled rows carry "" — they are
                // invisible to session-scoped reads, unattributable to any
                // session quota, and visible only through the unscoped
                // diagnostic read; they still count toward the GLOBAL quota.
                // v1 never shipped, so this is tested dev-history handling,
                // not a compatibility promise.
                // Idempotent against a crashed-migration v0 file that
                // already carries the v2 column set.
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(records)")
                    .compactMap { $0["name"] as String? }
                if !columns.contains("session") {
                    try db.execute(sql: "ALTER TABLE records ADD COLUMN session TEXT NOT NULL DEFAULT ''")
                }
                try db.execute(sql: "DROP TABLE writer")
                try db.execute(sql: """
                    CREATE TABLE writer(
                        session TEXT PRIMARY KEY,
                        writer TEXT NOT NULL)
                    """)
                // Session-count/pagination index (A2 review finding C):
                // supports session-quota COUNT and ordered session reads.
                // Created AFTER the v2 column exists (a v1 file gains the
                // column in this same migration).
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS records_session ON records(session, seq)
                    """)
                try db.execute(sql: "PRAGMA user_version = 2")
            }
            try Self.assertSchemaShape(db)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: - Declared schema shape (names, types, primary keys)

    struct ColumnSpec {
        let name: String
        let type: String
        let pk: Bool
        init(_ name: String, _ type: String, pk: Bool = false) {
            self.name = name
            self.type = type
            self.pk = pk
        }
    }

    static let declaredShape: [String: [ColumnSpec]] = [
        "records": [
            ColumnSpec("seq", "INTEGER", pk: true),
            ColumnSpec("session", "TEXT"),
            ColumnSpec("payload", "TEXT"),
        ],
        "writer": [
            ColumnSpec("session", "TEXT", pk: true),
            ColumnSpec("writer", "TEXT"),
        ],
    ]

    /// Declared shape check: exact column set, declared type (SQLite type
    /// affinity is case-insensitive) and primary-key membership must all
    /// match — a `records.seq TEXT PRIMARY KEY` impostor fails here
    /// instead of corrupting ordering later (STORE-05).
    private static func assertSchemaShape(_ db: Database) throws {
        for (table, specs) in declaredShape {
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            var byName: [String: Row] = [:]
            for row in rows {
                guard let name: String = row["name"] else { continue }
                byName[name] = row
            }
            guard Set(byName.keys) == Set(specs.map(\.name)) else {
                throw StoreError.integrity(
                    "foreign or incompatible schema: table \(table) has [\(byName.keys.sorted().joined(separator: ", "))], expected [\(specs.map { $0.name }.sorted().joined(separator: ", "))]")
            }
            for spec in specs {
                let row = byName[spec.name]!
                let declaredType = (row["type"] as String?).map { $0.uppercased() } ?? ""
                let pkPosition = (row["pk"] as Int64?) ?? 0
                guard declaredType == spec.type.uppercased(),
                      (pkPosition > 0) == spec.pk else {
                    throw StoreError.integrity(
                        "foreign or incompatible schema: table \(table).\(spec.name) has type [\(declaredType)] pk[\(pkPosition)], expected [\(spec.type.uppercased())] pk[\(spec.pk ? ">0" : "0")]")
                }
            }
        }
    }


    /// A2 review: translate exhausted bounded contention into the typed
    /// outcome — the database is healthy, another writer held the lock past
    /// the busy timeout. Corruption stays `.integrity`.
    private static func translate(_ error: Error) -> Error {
        if let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_BUSY {
            return StoreError.contention("database busy past the bounded timeout: \(dbError.message)")
        }
        return error
    }

    // MARK: - Closed-store contract

    private func assertOpenLocked() throws {
        if closed {
            throw StoreError.integrity("store is closed")
        }
    }

    public func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        // Encode BEFORE the transaction so a codec failure cannot leave a
        // half-written row.
        let payload = try RecordCodec.encode(record)
        do { try queue.write { db in
            // FENCING inside the mutation's own transaction (BEGIN
            // IMMEDIATE): the ownership row is the only authority.
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [identity.session.raw])
            guard holder == identity.writer else {
                throw StoreError.notWriter(
                    session: identity.session.raw, writer: identity.writer)
            }
            // STORE-09 quotas, same transaction as the fencing check and
            // the insert — a breached quota can never slip between checks
            // and write, and a failed append rolls back whole.
            let global = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records") ?? 0
            guard global < globalRecordLimit else {
                throw StoreError.quotaExceeded(limit: globalRecordLimit)
            }
            let sessionRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records WHERE session = ?",
                arguments: [identity.session.raw]) ?? 0
            guard sessionRows < sessionRecordLimit else {
                throw StoreError.quotaExceeded(limit: sessionRecordLimit)
            }
            let last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            try db.execute(
                sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
                arguments: [last + 1, identity.session.raw,
                            String(decoding: payload, as: UTF8.self)])
        } } catch { throw Self.translate(error) }
    }

    /// Single-transaction bulk append (import/migration tooling and scale
    /// fixtures): ONE fencing + quota check for the whole batch, committed
    /// ONCE. A failing batch rolls back whole (GRDB transaction
    /// semantics), leaving no partial rows. The batch is attributed to
    /// `identity.session`.
    public func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        let payloads = try records.map { try RecordCodec.encode($0) }
        do { try queue.write { db in
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [identity.session.raw])
            guard holder == identity.writer else {
                throw StoreError.notWriter(
                    session: identity.session.raw, writer: identity.writer)
            }
            let global = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records") ?? 0
            guard global + payloads.count <= globalRecordLimit else {
                throw StoreError.quotaExceeded(limit: globalRecordLimit)
            }
            let sessionRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records WHERE session = ?",
                arguments: [identity.session.raw]) ?? 0
            guard sessionRows + payloads.count <= sessionRecordLimit else {
                throw StoreError.quotaExceeded(limit: sessionRecordLimit)
            }
            var last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            for payload in payloads {
                last += 1
                try db.execute(
                    sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
                    arguments: [last, identity.session.raw,
                                String(decoding: payload, as: UTF8.self)])
            }
        } } catch { throw Self.translate(error) }
    }

    public func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        guard limit > 0 else {
            throw StoreError.integrity("invalid page limit \(limit); must be > 0")
        }
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records
                WHERE session = ? AND seq > ? ORDER BY seq LIMIT ?
                """, arguments: [session.raw, since, limit])
        }
        let batch = try Self.decodeBatch(rows)
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// UNSCOPED diagnostic read (support tooling/tests only): pages the
    /// WHOLE store across sessions. Never feed this to a model request.
    public func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        // Bounded paging is the contract (R15): a non-positive limit is an
        // integrity fault, never "everything".
        guard limit > 0 else {
            throw StoreError.integrity("invalid page limit \(limit); must be > 0")
        }
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records WHERE seq > ? ORDER BY seq LIMIT ?
                """, arguments: [since, limit])
        }
        let batch = try Self.decodeBatch(rows)
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// A2 STORE-06: per-session fenced ownership. `INSERT ... ON CONFLICT
    /// DO NOTHING` inside the write transaction makes the claim atomic —
    /// a competing writer either wins the row or reads exactly who does.
    /// Re-claim with the SAME identity is an idempotent no-op
    /// (crash-recovery re-acquire); a different writer learns both
    /// identities of the holder.
    public func claimWriterOwnership(session: SessionID, writer: String) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        do { try queue.write { db in
            try db.execute(
                sql: "INSERT INTO writer (session, writer) VALUES (?, ?) ON CONFLICT(session) DO NOTHING",
                arguments: [session.raw, writer])
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [session.raw])
            guard holder == writer else {
                throw StoreError.alreadyOwned(
                    session: session.raw, writer: holder ?? "?")
            }
        } } catch { throw Self.translate(error) }
    }

    /// Only the CURRENT writer of the session can release: the delete is
    /// filtered by BOTH identities, and a no-op delete (row absent or held
    /// by a newer writer) fails closed — an old writer can never remove a
    /// newer writer's claim.
    public func releaseWriterOwnership(session: SessionID, writer: String) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        do { try queue.write { db in
            try db.execute(
                sql: "DELETE FROM writer WHERE session = ? AND writer = ?",
                arguments: [session.raw, writer])
            let deleted = db.changesCount
            guard deleted == 1 else {
                throw StoreError.notWriter(session: session.raw, writer: writer)
            }
        } } catch { throw Self.translate(error) }
    }

    /// A1 test/receipt support: an explicit close hands the file to a
    /// FRESH handle deterministically. Under the gate, concurrent
    /// operations either finish before close or fail typed
    /// `.integrity("store is closed")`; a second close is a no-op.
    public func close() throws {
        gate.lock()
        defer { gate.unlock() }
        guard !closed else { return }
        closed = true
        try queue.close()
    }

    /// Every row decodes through the codec; a corrupted row is
    /// `.integrity` — never skipped, never substituted, never trapped on.
    private static func decodeBatch(_ rows: [Row]) throws -> [SequencedRecord] {
        try rows.map { row -> SequencedRecord in
            guard let seq: Int64 = row["seq"], seq >= 0,
                  let payload: String = row["payload"] else {
                throw StoreError.integrity("corrupt record row: unreadable seq/payload")
            }
            return try SequencedRecord(
                sequence: SequenceNumber(UInt64(seq)),
                record: RecordCodec.decode(Data(payload.utf8)))
        }
    }

    // MARK: - Diagnostics (test/receipt support)

    /// Reads a PRAGMA on THIS store's connection (per-connection settings
    /// such as `synchronous` cannot be observed from another handle).
    /// Internal: durability assertions use it via `@testable import`.
    func pragmaValue(_ name: String) throws -> String? {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        return try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA \(name)")
        }
    }
}
