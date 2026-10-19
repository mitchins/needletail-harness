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
    /// opening.
    public static let schemaVersion: Int32 = 1

    private let queue: DatabaseQueue
    /// The opened file path (public for reopen-test legibility).
    public let path: String
    private var closed = false
    /// Serializes every operation against `close` so the typed
    /// closed-store contract holds atomically (A1 stabilization).
    private let gate = NSLock()

    public init(path: String) throws {
        self.path = path
        var configuration = Configuration()
        configuration.journalMode = .wal
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
                return
            }
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
        "records": [ColumnSpec("seq", "INTEGER", pk: true), ColumnSpec("payload", "TEXT")],
        "writer": [ColumnSpec("slot", "INTEGER", pk: true), ColumnSpec("owner", "TEXT")],
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

    // MARK: - Closed-store contract

    private func assertOpenLocked() throws {
        if closed {
            throw StoreError.integrity("store is closed")
        }
    }

    public func append(_ record: DurableRecord) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
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
    /// the whole batch. A failing batch rolls back whole (GRDB transaction
    /// semantics), leaving no partial rows.
    public func appendBatch(_ records: [DurableRecord]) throws {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
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
        // Every row decodes through the codec; a corrupted row is
        // `.integrity` — never skipped, never substituted, never trapped on.
        let batch = try rows.map { row -> SequencedRecord in
            guard let seq: Int64 = row["seq"], seq >= 0,
                  let payload: String = row["payload"] else {
                throw StoreError.integrity("corrupt record row: unreadable seq/payload")
            }
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
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
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
    }

    public func releaseWriterOwnership(session: SessionID) {
        gate.lock()
        defer { gate.unlock() }
        guard !closed else { return }
        try? queue.write { db in
            try db.execute(
                sql: "DELETE FROM writer WHERE slot = 1 AND owner = ?",
                arguments: [session.raw])
        }
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
