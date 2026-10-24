import Foundation
import GRDB
import NeedletailCore
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif

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
    /// v3 (B3-B): byte accounting — `byte_usage` (per-session LOGICAL
    /// bytes: committed record payload bytes + distinct referenced artifact
    /// sizes for that session) and `artifact_physical` (global distinct
    /// physical bytes: one row per digest with at least one committed
    /// reference, plus reconciled orphans). Migration backfills both via
    /// recompute-to-expected (see migrateIfNeeded).
    public static let schemaVersion: Int32 = 3

    /// B3-B byte quotas (SPEC §9.2): 1 GiB per-session logical,
    /// 5 GiB global physical, 256 MiB free-space reserve. Configurable at
    /// init for deterministic tests (same pattern as the record-count
    /// quotas); production uses these defaults.
    public static let defaultSessionByteLimit: Int64 = 1 * 1024 * 1024 * 1024
    public static let defaultGlobalByteLimit: Int64 = 5 * 1024 * 1024 * 1024
    public static let defaultFreeSpaceReserve: Int64 = 256 * 1024 * 1024

    private let queue: DatabaseQueue
    /// The opened file path (public for reopen-test legibility).
    public let path: String
    /// STORE-09 quotas, enforced INSIDE each fenced append transaction.
    public let sessionRecordLimit: Int
    public let globalRecordLimit: Int
    /// A4-1 per-artifact byte cap (SPEC §9.2 default: 32 MiB per exec
    /// artifact). Publication above the cap fails closed before touching
    /// the filesystem.
    public let artifactByteLimit: Int
    /// B3-B byte quotas (see static defaults).
    public let sessionByteLimit: Int64
    public let globalByteLimit: Int64
    public let freeSpaceReserve: Int64
    private var closed = false
    /// Serializes every operation against `close` so the typed
    /// closed-store contract holds atomically (A1 stabilization).
    private let gate = NSRecursiveLock()

    public init(path: String, sessionRecordLimit: Int = 10_000, globalRecordLimit: Int = 100_000, artifactByteLimit: Int = 32 * 1024 * 1024, sessionByteLimit: Int64? = nil, globalByteLimit: Int64? = nil, freeSpaceReserve: Int64? = nil) throws {
        self.path = path
        self.sessionRecordLimit = sessionRecordLimit
        self.globalRecordLimit = globalRecordLimit
        self.artifactByteLimit = artifactByteLimit
        self.sessionByteLimit = sessionByteLimit ?? Self.defaultSessionByteLimit
        self.globalByteLimit = globalByteLimit ?? Self.defaultGlobalByteLimit
        self.freeSpaceReserve = freeSpaceReserve ?? Self.defaultFreeSpaceReserve
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
                // (only OUR tables, correct shape → resume through the
                // versioned migrations below) or a FOREIGN database
                // (anything else → reject before we touch it). Both the
                // current shape and the exact v2 shape (pre-fold resume
                // case) are accepted; anything else is foreign.
                let userTables = try Set(String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
                let v2Shape: Set<String> = ["records", "writer"]
                if !userTables.isEmpty && userTables != Set(Self.declaredShape.keys) && userTables != v2Shape {
                    throw StoreError.integrity(
                        "foreign unversioned store: tables [\(userTables.sorted().joined(separator: ", "))] are not a needletail schema")
                }
                if !userTables.isEmpty && userTables == Set(Self.declaredShape.keys) {
                    // Unversioned file that already has the full current
                    // shape: validate it, ensure the session index (a v0
                    // file may predate it), and stamp it — without dropping
                    // any writer claims through the versioned path.
                    try Self.assertSchemaShape(db)
                    try db.execute(sql: """
                        CREATE INDEX IF NOT EXISTS records_session ON records(session, seq)
                        """)
                    try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
                    return
                }
            }
        guard version < Self.schemaVersion else {
            // Already at our version: the shapes must still MATCH. A file
            // stamped with our version but carrying foreign or missing
            // tables is not a needletail store.
            try Self.assertSchemaShape(db)
            // The session index must exist on EVERY v2+ file — including
            // ones stamped v2 before the index landed (pre-fold A2) — and
            // ONLY after the fail-closed checks above passed. (The v3 byte
            // tables are covered by assertSchemaShape above: a v3-stamped
            // file missing them is foreign, not repaired.)
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
            if version < 3 {
                // v3: byte accounting. New tables (with non-negative CHECKs)
                // plus a recompute-to-expected backfill (same routine as
                // reconcileByteUsage). Idempotent; a v0 file with v2 tables
                // takes the v2 path above first, then lands here.
                try db.execute(sql: Self.byteUsageDDL)
                try db.execute(sql: Self.artifactPhysicalDDL)
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS records_session ON records(session, seq)
                    """)
                _ = try Self.reconcileByteUsageInTxn(db, artifactsRoot: Self.artifactsRoot(for: path))
                try db.execute(sql: "PRAGMA user_version = 3")
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
        "byte_usage": [
            ColumnSpec("session", "TEXT", pk: true),
            ColumnSpec("bytes", "INTEGER"),
        ],
        "artifact_physical": [
            ColumnSpec("digest", "TEXT", pk: true),
            ColumnSpec("size", "INTEGER"),
        ],
    ]

    // Non-negative byte accounting, enforced by the schema as well as the
    // pre-insert checks (negative values would subtract from quotas).
    static let byteUsageDDL = "CREATE TABLE IF NOT EXISTS byte_usage(session TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK (bytes >= 0))"
    static let artifactPhysicalDDL = "CREATE TABLE IF NOT EXISTS artifact_physical(digest TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK (size >= 0))"

    /// Declared shape check: exact column set, declared type (SQLite type
    /// affinity is case-insensitive) and primary-key membership must all
    /// match — a `records.seq TEXT PRIMARY KEY` impostor fails here
    /// instead of corrupting ordering later (STORE-05). Internal so the
    /// read-only export path can apply the identical contract without
    /// opening a migrating handle.
    static func assertSchemaShape(_ db: Database) throws {
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
    /// Shared busy mapping for every DB access (writes, reads, pragmaValue):
    /// a bounded-timeout exhaustion surfaces as typed `.contention` so a
    /// healthy-but-locked database is distinguishable from corruption
    /// (`.integrity`). Non-busy errors pass through untouched. Internal for
    /// direct unit coverage (a WAL reader cannot be forced into contention
    /// by a peer writer holding locks — reads use shared snapshots — so the
    /// mapping itself is pinned by unit, the timeout by the write test).
    static func translate(_ error: Error) -> Error {
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
        // B3-B lock order: artifact lock BEFORE the in-process gate, on
        // every mutating path (same order as publish/reconcile — no deadlock).
        try withArtifactLock {
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
                // STORE-09 count quotas, same transaction as the fencing
                // check and the insert — a breached quota can never slip
                // between checks and write, and a failed append rolls back
                // whole.
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
                // B3-B byte quotas + accounting, same transaction.
                try insertRecordWithQuota(db, session: identity.session.raw, payload: payload)
            } } catch { throw Self.translate(error) }
        }
    }

    /// Single-transaction bulk append (import/migration tooling and scale
    /// fixtures): ONE fencing + quota check for the whole batch, committed
    /// ONCE. A failing batch rolls back whole (GRDB transaction
    /// semantics), leaving no partial rows. The batch is attributed to
    /// `identity.session`.
    public func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
        try withArtifactLock {
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
                // B3-B byte accounting for the whole batch (single snapshot,
                // in-memory running totals), same transaction as fencing and
                // count quotas — the batch still commits or rolls back
                // atomically.
                try insertRecordsBatchWithQuota(db, session: identity.session.raw, payloads: payloads)
            } } catch { throw Self.translate(error) }
        }
    }

    public func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        guard limit > 0 else {
            throw StoreError.integrity("invalid page limit \(limit); must be > 0")
        }
        let rows: [Row]
        do {
            rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records
                WHERE session = ? AND seq > ? ORDER BY seq LIMIT ?
                """, arguments: [session.raw, since, limit])
        }
        } catch { throw Self.translate(error) }
        let batch = try Self.decodeBatch(rows)
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// B5-B read-only session enumeration: every session with at least one
    /// durable record (`SELECT DISTINCT session`, no row data), sorted for
    /// deterministic gate output. A record-less claimed session holds no
    /// operations and reconciles clean, so it cannot trip the gate.
    public func sessions() throws -> [SessionID] {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        do {
            let raws = try queue.read { db in
                try String.fetchAll(db, sql: "SELECT DISTINCT session FROM records ORDER BY session")
            }
            return raws.map(SessionID.init)
        } catch { throw Self.translate(error) }
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
        let rows: [Row]
        do {
            rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records WHERE seq > ? ORDER BY seq LIMIT ?
                """, arguments: [since, limit])
        }
        } catch { throw Self.translate(error) }
        let batch = try Self.decodeBatch(rows)
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// A3-2 reopen reconciliation: reads the session's whole durable
    /// record stream through the SESSION-SCOPED paged read (never the
    /// unscoped diagnostic — cross-session content is unrepresentable in
    /// the report) and runs the pure `reconcileOperations` classifier.
    /// Call on a FRESH handle after reopen; duplicates, contradictions and
    /// namespace collisions throw `.integrity` (fail closed).
    /// An empty stream reconciles clean: a fresh session and a mistyped ID
    /// are indistinguishable at the ledger level — session existence is
    /// the caller's contract (a typo surfaces on the first fenced append
    /// via `.notWriter`).
    public func reconcile(session: SessionID) throws -> OperationReconciliation {
        var stream: [DurableRecord] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try records(session: session, since: cursor, limit: 500)
            stream += page.map(\.record)
            guard let advanced = next else { break }
            cursor = advanced
        }
        return try reconcileOperations(stream)
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

    /// A3-3 EXPLICIT ownership recovery, ONE guarded SQLite transaction:
    /// expected-holder match → session-ledger reconcile → quota check →
    /// conditional ownership update → audit insert. Any failure rolls back
    /// the WHOLE transaction: no takeover without its audit row, no audit
    /// row without its takeover, and an invalid ledger prevents recovery.
    /// Reads use raw SQL inside the transaction — never the locking public
    /// `records` (which would re-enter the gate). No PID, timeout, absence,
    /// or unconditional-replace authority anywhere in this path.
    public func recoverWriterOwnership(
        session: SessionID, expectedWriter: String, newWriter: String,
        authorization: RecoveryAuthorization
    ) throws {
        try withArtifactLock {
            gate.lock()
            defer { gate.unlock() }
            try assertOpenLocked()
            // Pure authorization validation BEFORE any I/O: shape, genuine
            // transition, and exact scope binding.
            try authorization.validated(
                for: session, expectedWriter: expectedWriter, newWriter: newWriter)
            do { try queue.write { db in
            // Guarded match: the expected writer must be the CURRENT
            // holder. No row (never claimed) or a different holder fails
            // closed with the identity that actually (doesn't) hold(s) it.
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [session.raw])
            guard let current = holder else {
                throw StoreError.notWriter(session: session.raw, writer: expectedWriter)
            }
            guard current == expectedWriter else {
                throw StoreError.alreadyOwned(session: session.raw, writer: current)
            }
            // Reconcile the session's operation evidence CONSISTENTLY with
            // the takeover (same snapshot): an invalid ledger aborts the
            // transaction before any write.
            let payloads = try String.fetchAll(
                db, sql: "SELECT payload FROM records WHERE session = ? ORDER BY seq",
                arguments: [session.raw])
            let stream = try payloads.map { payload in
                guard let data = payload.data(using: .utf8) else {
                    throw StoreError.integrity("record row payload is not UTF-8")
                }
                return try RecordCodec.decode(data)
            }
            let report = try reconcileOperations(stream)
            // Quota for the audit row, same transaction: exhaustion fails
            // the takeover whole (no partial recovery).
            let global = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records") ?? 0
            guard global + 1 <= globalRecordLimit else {
                throw StoreError.quotaExceeded(limit: globalRecordLimit)
            }
            let sessionRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records WHERE session = ?",
                arguments: [session.raw]) ?? 0
            guard sessionRows + 1 <= sessionRecordLimit else {
                throw StoreError.quotaExceeded(limit: sessionRecordLimit)
            }
            // Conditional ownership update: the WHERE clause re-asserts the
            // guard, so the swap lands exactly once on the expected row.
            try db.execute(
                sql: "UPDATE writer SET writer = ? WHERE session = ? AND writer = ?",
                arguments: [newWriter, session.raw, expectedWriter])
            guard db.changesCount == 1 else {
                throw StoreError.integrity("takeover update affected no row; ownership unchanged")
            }
            // Durable audit WITH the update: session, both writers,
            // operator authorization, and the preserved unresolved
            // evidence. Holds are NOT cleared — recovery establishes
            // nothing about external operations.
            let audit = DurableRecord.writerRecovered(WriterRecovery(
                previousWriter: expectedWriter, newWriter: newWriter,
                operatorID: authorization.operatorID, reference: authorization.reference,
                reason: authorization.reason, atMillis: authorization.atMillis,
                unresolvedOperations: report.heldOperations))
            let encoded = try RecordCodec.encode(audit)
            // B3-B: the audit row counts toward byte quotas like any insert.
            try insertRecordWithQuota(db, session: session.raw, payload: encoded)
        } } catch { throw Self.translate(error) }
        }
    }

    /// A4-1 publication, read-back and orphan-scan for immutable
    /// artifacts (SPEC §9.1). Bytes live content-addressed under a
    /// private managed root beside the database (`<dbfile>-artifacts`,
    /// mode 0700; files 0600); the database stores only the reference.
    /// The root derives from the FULL database filename, so distinct
    /// stores never share a root (and an orphan scan never misreports
    /// another store's referenced artifacts as orphans).
    static func artifactsRoot(for dbPath: String) -> String {
        let url = URL(fileURLWithPath: dbPath)
        return url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + "-artifacts").path
    }

    private var artifactsRoot: String { Self.artifactsRoot(for: path) }

    /// Fail-closed snapshot read of a final artifact file: fd-based
    /// (`O_NOFOLLOW`, `fstat` regular-file, bounded in-memory copy), then
    /// size and digest verification. Absence, symlinks, non-regular
    /// files, unreadable files, size drift and digest mismatches all fail
    /// typed `.integrity` — partial or substituted bytes are never
    /// returned, and mmaps (SIGBUS on truncation) are never used.
    private func readVerifiedArtifact(
        atPath filePath: String, digest: String, expectedSize: Int
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= artifactByteLimit else {
            throw StoreError.integrity("artifact size out of bounds for digest \(digest)")
        }
        let fd = try openRegularFile(atPath: filePath)
        defer { closeArtifactFD(fd) }
        let bytes = try readBoundedFD(fd, bound: min(expectedSize, artifactByteLimit))
        guard bytes.count == expectedSize else {
            throw StoreError.integrity("artifact size mismatch for digest \(digest)")
        }
        guard artifactSHA256Hex(bytes) == digest else {
            throw StoreError.integrity("artifact digest mismatch for \(digest): stored bytes do not match")
        }
        return bytes
    }

    /// A4-1 publication with ordering: private tmp file → write → flush +
    /// fsync → atomic rename on the same filesystem → directory sync →
    /// post-rename re-verification → ONLY THEN the fenced database
    /// reference commit. Fencing is checked BEFORE any filesystem work (a
    /// stale writer creates nothing) and re-checked inside the reference
    /// transaction. A crash between rename and commit leaves a file with
    /// no reference — an orphan, reported by `detectArtifactOrphans`,
    /// never auto-attached.
    /// Free bytes available on the filesystem holding `path` (unprivileged
    /// `f_bavail`). Unknown (unlistable path) is treated as sufficient —
    /// the reserve gate must never brick publication on unmeasurable hosts.
    static func freeBytesAvailable(atPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return free.uint64Value
    }

    public func publishArtifact(
        session: SessionID, as identity: WriterIdentity,
        kind: String, operationID: OperationID?, bytes: Data
    ) throws -> ArtifactRef {
        // B3-B lock order: artifact lock BEFORE the in-process gate (same
        // order as reconcile — no deadlock). Held for the whole publish:
        // preflight, tmp, commit and conditional cleanup all serialize
        // against other publishers and reconcilers.
        try withArtifactLock {
            gate.lock()
            defer { gate.unlock() }
            try assertOpenLocked()
            guard !kind.isEmpty else {
                throw StoreError.integrity("artifact kind must not be empty")
            }
            guard !bytes.isEmpty else {
                throw StoreError.integrity("artifact bytes must not be empty")
            }
            guard bytes.count <= artifactByteLimit else {
                throw StoreError.quotaExceeded(limit: artifactByteLimit)
            }
            // One source of truth: the session comes from the fenced identity.
            // A caller passing a different session alongside the identity is a
            // programming error — fail closed before any I/O.
            guard session == identity.session else {
                throw StoreError.integrity("publish session/identity mismatch")
            }
            // Fencing BEFORE any filesystem work (A4-1 req 6): a stale writer
            // creates no files and commits no reference. Translated like every
            // other DB access (typed contention, never raw GRDB errors).
            let preHolder: String?
            do {
                preHolder = try queue.read { db in
                    try String.fetchOne(
                        db, sql: "SELECT writer FROM writer WHERE session = ?",
                        arguments: [identity.session.raw])
                }
            } catch { throw Self.translate(error) }
            guard preHolder == identity.writer else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
        let digest = artifactSHA256Hex(bytes)
        let root = artifactsRoot
        // Free-space preflight FIRST (256 MiB reserve): refuse before writing
        // anything — not even the managed root directory. Never crashes on
        // a full disk. The artifacts root lives beside the database file, so
        // the database directory's filesystem is the volume to measure.
        // Unknown free space is treated as sufficient (the tmp write itself
        // still fails closed).
        do {
            let fsPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard freeSpaceReserve >= 0 else {
                throw StoreError.integrity("negative free-space reserve")
            }
            if let free = Self.freeBytesAvailable(atPath: fsPath), free < UInt64(bitPattern: freeSpaceReserve) {
                throw StoreError.quotaExceeded(limit: Int(freeSpaceReserve))
            }
        }
        do {
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            // createDirectory throws when the root exists AND when it
            // cannot be created — a pre-existing root is fine (verified
            // below); anything else fails closed.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
                  isDir.boolValue else {
                throw StoreError.integrity("artifact root is not a directory: \(root)")
            }
        }
        // lstat never follows symlinks: a symlinked or non-directory root
        // (planted to escape the managed tree or redirect writes) fails
        // closed here instead of being chmodded and used.
        var rootStatus = stat()
        guard lstat(root, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw StoreError.integrity("artifact root is not a real directory: \(root)")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        } catch {
            throw StoreError.integrity("artifact root is not private: \(root): \(error)")
        }
        let finalPath = try resolveArtifactPath(root: root, name: digest)
        // Hold the validated root open for descriptor-relative tmp
        // creation and rename (no pathname TOCTOU between validation and
        // use; a swapped root fails closed at open).
        let rootFD: Int32 = root.withCString { cstr in
            open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootFD >= 0 else {
            throw StoreError.integrity("artifact root cannot be opened: \(String(cString: strerror(errno)))")
        }
        defer { closeArtifactFD(rootFD) }
        // Preflight final-file check: a verifying final file means adoption
        // (no new physical bytes), so skip its size (the orphan scan still
        // counts it — exactly once either way). Advisory only — the
        // authoritative check re-verifies inside the commit transaction
        // under the same lock.
        var preAdopted = false
        if FileManager.default.fileExists(atPath: finalPath) {
            let pfd: Int32 = digest.withCString { name in
                openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            if pfd >= 0 {
                defer { closeArtifactFD(pfd) }
                var pst = stat()
                if fstat(pfd, &pst) == 0, (pst.st_mode & S_IFMT) == S_IFREG,
                   let pdata = try? readBoundedFD(pfd, bound: bytes.count + 1),
                   pdata.count == bytes.count, artifactSHA256Hex(pdata) == digest {
                    preAdopted = true
                }
            }
        }
        // Byte-quota preflight (advisory, fail fast, nothing written): same
        // math as the authoritative check MINUS the reference-row overhead,
        // so it can only under-count — never a false reject. The exact
        // authoritative check runs inside the commit transaction.
        let ref = ArtifactRef(digest: digest, size: bytes.count, kind: kind, operationID: operationID)
        let payload = try RecordCodec.encode(DurableRecord.artifactPublished(ref))
        do {
            let preSnap = try queue.read { db in try Self.snapshotByteQuotas(db, artifactsRoot: root, session: identity.session.raw, digest: digest) }
            try checkByteQuotas(preSnap, session: identity.session.raw, payloadBytes: 0, digest: digest, size: Int64(bytes.count), globalSizeAlreadyCounted: preAdopted)
        } catch { throw Self.translate(error) }
        // Tmp file, created OUTSIDE the commit transaction but UNDER the
        // artifact lock (no other publisher can race the filesystem), with
        // O_NOFOLLOW so a planted symlink can never redirect it. The commit
        // transaction below decides whether it is renamed or cleaned.
        let tmpName = artifactTmpPrefix + UUID().uuidString
        let tmpPath = try resolveArtifactPath(root: root, name: tmpName)
        do {
            let tmpFD: Int32 = tmpName.withCString { name in
                openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            guard tmpFD >= 0 else {
                throw StoreError.integrity("artifact tmp file creation failed: \(String(cString: strerror(errno)))")
            }
            defer { closeArtifactFD(tmpFD) }
            var offset = 0
            let total = bytes.count
            while offset < total {
                let n = bytes.withUnsafeBytes { raw -> Int in
                    Glibc.write(tmpFD, raw.baseAddress!.advanced(by: offset), total - offset)
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.integrity("artifact tmp write failed: \(String(cString: strerror(errno)))")
                }
                if n == 0 {
                    throw StoreError.integrity("artifact tmp short write")
                }
                offset += n
            }
            guard fsync(tmpFD) == 0 else {
                throw StoreError.integrity("artifact tmp fsync failed: \(String(cString: strerror(errno)))")
            }
            guard fchmod(tmpFD, mode_t(0o600)) == 0 else {
                    throw StoreError.integrity("artifact tmp fchmod failed: \(String(cString: strerror(errno)))")
                }
            } catch {
                _ = tmpName.withCString { unlinkat(rootFD, $0, 0) }
                throw error
            }
        // ATOMIC commit inside ONE queue.write under the same artifact
        // lock + gate: (1) fencing re-check, (2) count quotas, (3) fresh
        // snapshot + authoritative byte quotas, (4) tmp re-verify,
        // (5) dedup re-check against committed state, (6) rename (only
        // when this publisher's bytes are needed) + dirsync, (7) reference
        // insert + physical upsert + byte_usage bump. Rollback leaves no
        // row; the cleanup below removes unreferenced files.
        var didRename = false
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
            guard global + 1 <= globalRecordLimit else {
                throw StoreError.quotaExceeded(limit: globalRecordLimit)
            }
            let sessionRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM records WHERE session = ?",
                arguments: [identity.session.raw]) ?? 0
            guard sessionRows + 1 <= sessionRecordLimit else {
                throw StoreError.quotaExceeded(limit: sessionRecordLimit)
            }
            // Final-file check FIRST (before the quota snapshot): a verifying
            // final file means the bytes are already durable — adopt it (no
            // rename, no second file, no destructive overwrite). The quota
            // check then skips its size (globalSizeAlreadyCounted) while the
            // snapshot still counts it as an orphan if unreferenced, so the
            // bytes are counted exactly once either way. A missing file means
            // this call's tmp provides the bytes; a present-but-wrong file
            // fails closed without touching it. All opens are
            // descriptor-relative with O_NOFOLLOW.
            var adoptedFinal = false
            if FileManager.default.fileExists(atPath: finalPath) {
                let fd: Int32 = digest.withCString { name in
                    openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard fd >= 0 else {
                    throw StoreError.integrity("artifact file cannot be opened (symlink?): \(digest)")
                }
                defer { closeArtifactFD(fd) }
                var fileStatus = stat()
                guard fstat(fd, &fileStatus) == 0,
                      (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                    throw StoreError.integrity("artifact path is not a regular file: \(digest)")
                }
                let existing: Data
                do {
                    existing = try readBoundedFD(fd, bound: bytes.count + 1)
                } catch let error as StoreError {
                    throw error
                } catch {
                    throw StoreError.integrity("artifact verification failed for digest \(digest): \(error)")
                }
                guard existing.count == bytes.count,
                      artifactSHA256Hex(existing) == digest else {
                    throw StoreError.integrity("artifact collision at digest \(digest): stored bytes differ")
                }
                guard fchmod(fd, mode_t(0o600)) == 0 else {
                    throw StoreError.integrity("artifact file mode cannot be repaired: \(digest)")
                }
                guard fsync(fd) == 0 else {
                    throw StoreError.integrity("artifact file sync failed: \(digest)")
                }
                try syncArtifactDirectory(atPath: root)
                adoptedFinal = true
            }
            let snap = try Self.snapshotByteQuotas(db, artifactsRoot: root, session: identity.session.raw, digest: digest)
            try checkByteQuotas(snap, session: identity.session.raw, payloadBytes: Int64(payload.count), digest: digest, size: Int64(bytes.count), globalSizeAlreadyCounted: adoptedFinal)
            let sessionHasD = snap.sessionHasDigest
            // Re-verify the tmp we wrote (fresh open relative to the held
            // root FD, no-follow, digest). The held root FD pins the
            // directory: a swapped root or planted symlink fails here.
            let tmpVerified: Bool = {
                let fd: Int32 = tmpName.withCString { name in
                    openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard fd >= 0 else { return false }
                defer { closeArtifactFD(fd) }
                guard let data = try? readBoundedFD(fd, bound: bytes.count + 1),
                      data.count == bytes.count,
                      artifactSHA256Hex(data) == digest else { return false }
                return true
            }()
            guard tmpVerified else {
                throw StoreError.integrity("artifact tmp failed verification for digest \(digest)")
            }
            // Adopt-or-provide: the final file was already verified
            // above (adoptedFinal). If adopted, skip the rename entirely.
            // Otherwise this call's tmp provides the bytes.
            if !adoptedFinal {
                let renameOK: Bool = digest.withCString { newName in
                    tmpName.withCString { tmpC in
                        renameat(rootFD, tmpC, rootFD, newName) == 0
                    }
                }
                guard renameOK else {
                    throw StoreError.integrity("artifact rename failed: \(String(cString: strerror(errno)))")
                }
                // Mark immediately after a successful rename so that even a
                // subsequent dirsync failure still cleans up this call's file.
                didRename = true
                try syncArtifactDirectory(atPath: root)
            }
            try commitRecordBytes(db, session: identity.session.raw, payload: payload, digest: digest, size: Int64(bytes.count), sessionHasDigest: sessionHasD)
        } } catch {
            // Conditional cleanup in a SECOND queue.write under the SAME
            // artifact lock (held across the rollback-to-cleanup boundary,
            // so no third publisher can commit in between): delete the tmp
            // always (it is ours and unreferenced by definition — tmp names
            // are UUIDs, never reference targets), and delete the final file
            // ONLY when this call renamed it AND no committed reference for
            // this digest exists AND no committed physical row for it is
            // live — never a pre-existing file this call merely observed.
            try? queue.write { db in
                guard didRename else { return }
                // Exact checks (LIKE pre-filter + decode-confirm for refs; a
                // direct physical-row lookup) — never substring matching
                // alone. On any check failure we keep the final file
                // (fail closed: never delete what we cannot verify as ours).
                let refExists: Bool
                do {
                    refExists = try Self.hasCommittedReference(db, digest: digest)
                } catch {
                    return
                }
                let physCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_physical WHERE digest = ?", arguments: [digest])) ?? 1
                if !refExists && physCount == 0 {
                    _ = digest.withCString { unlinkat(rootFD, $0, 0) }
                }
            }
            _ = tmpName.withCString { unlinkat(rootFD, $0, 0) }
            throw Self.translate(error)
        }
        if !didRename {
            // Dedup path: our tmp was never needed.
            _ = tmpName.withCString { unlinkat(rootFD, $0, 0) }
        }
        return ref
    }
}

    /// Reads a published artifact by reference. The digest, not the
    /// database, is the authority: absent files, symlinks, non-regular
    /// files, unreadable files, size drift and digest mismatches all fail
    /// typed `.integrity` — partial or substituted bytes are never
    /// returned. The read is a fail-closed fd snapshot (`O_NOFOLLOW`,
    /// `fstat` regular-file, bounded in-memory copy — no mmaps), so a
    /// concurrent swap or truncation races into an error, never into
    /// wrong bytes.
    public func readArtifact(_ ref: ArtifactRef) throws -> Data {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        guard ref.digest.count == 64,
              ref.digest.allSatisfy({ $0.isHexDigit }),
              ref.digest == ref.digest.lowercased() else {
            throw StoreError.integrity("artifact digest is not a lowercase SHA-256 hex string")
        }
        guard ref.size >= 0 else {
            throw StoreError.integrity("artifact size is negative")
        }
        let filePath = try resolveArtifactPath(root: artifactsRoot, name: ref.digest)
        return try readVerifiedArtifact(atPath: filePath, digest: ref.digest, expectedSize: ref.size)
    }

    /// Orphan scan (recovery tooling, never fed to a model): final-named
    /// files with no committed reference are orphans; tmp leftovers are
    /// interrupted publications. Reported, never deleted, never attached.
    /// References are enumerated store-wide (unscoped diagnostic read —
    /// a session-scoped scan would misreport every other session's
    /// artifacts as orphans). No gate across the paging loop (precedent:
    /// `reconcile`); each page is atomic and close interleaves typed.
    /// Point-in-time tooling: a publication racing the scan (reference
    /// committed after the last page, or file renamed after the listing)
    /// can be transiently reported — run it offline for decisions.
    public func detectArtifactOrphans() throws -> ArtifactOrphans {
        var referenced = Set<String>()
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try records(since: cursor, limit: 500)
            for row in page {
                if case .artifactPublished(let ref) = row.record {
                    referenced.insert(ref.digest)
                }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        let root = artifactsRoot
        guard FileManager.default.fileExists(atPath: root) else {
            return ArtifactOrphans(orphaned: [], interrupted: [])
        }
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            throw StoreError.integrity("artifact root is not listable: \(root): \(error)")
        }
        var orphaned: [String] = []
        var interrupted: [String] = []
        for entry in entries {
            if entry.hasPrefix(artifactTmpPrefix) {
                interrupted.append(entry)
            } else if !referenced.contains(entry) {
                orphaned.append(entry)
            }
        }
        return ArtifactOrphans(orphaned: orphaned.sorted(), interrupted: interrupted.sorted())
    }

    // MARK: - B3-B cross-process artifact lock + byte accounting

    /// Cross-process artifact lock file: `<db>-artifacts.lock`, a sibling of
    /// the managed artifacts root (never inside it, so orphan scans never
    /// see it). Acquired BEFORE the in-process gate on every mutating path
    /// that touches artifacts or byte accounting, held for the whole
    /// operation (including across the rollback-to-cleanup boundary), and
    /// released after. Total order (lock → gate → queue) is the same
    /// everywhere, so no deadlock. flock is per-open-description: each
    /// acquisition opens its own FD, so there is no close-while-blocked
    /// hazard and no interaction with `close()`.
    static func artifactLockPath(for dbPath: String) -> String {
        dbPath + "-artifacts.lock"
    }

    private func withArtifactLock<T>(_ body: () throws -> T) throws -> T {
        let lockPath = Self.artifactLockPath(for: path)
        let fd: Int32 = lockPath.withCString { cstr in
            open(cstr, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            throw StoreError.integrity("artifact lock unavailable: \(String(cString: strerror(errno)))")
        }
        defer { closeArtifactFD(fd) }
        var lst = stat()
        guard fstat(fd, &lst) == 0, (lst.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.integrity("artifact lock is not a regular file")
        }
        var tries = 0
        while true {
            if flock(fd, LOCK_EX) == 0 { break }
            let e = errno
            if e == EINTR, tries < 5 {
                tries += 1
                continue
            }
            throw StoreError.integrity("artifact lock failed: \(String(cString: strerror(e)))")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Committed-state byte ledger snapshot (B3-B ground truth). Reads
    /// committed rows via raw SQL inside the caller's transaction (never the
    /// re-entrant locking `records` helpers, which would deadlock inside a
    /// write), decodes every `artifactPublished` reference, joins the
    /// on-disk artifact files, and reports per-session record bytes,
    /// per-session distinct artifact digests, and the physical table.
    /// A digest referenced with inconsistent sizes across rows fails closed
    /// (corrupt ledger, never averaged or guessed).
    struct ByteLedgerSnapshot {
        /// session -> committed record payload bytes (UTF-8 bytes, via
        /// length(CAST(payload AS BLOB)); SQL length() on TEXT counts
        /// characters, which undercounts non-ASCII).
        var perSessionRecordBytes: [String: Int64] = [:]
        /// session -> distinct referenced digest set (row-level session
        /// attribution, never ArtifactRef fields).
        var sessionDigests: [String: Set<String>] = [:]
        /// digest -> size from committed references (consistency-checked).
        var digestSize: [String: Int64] = [:]
        /// SUM(length(CAST(payload AS BLOB))) over all committed rows.
        var globalRecordBytes: Int64 = 0
        /// SUM(size) over committed artifact_physical rows.
        var physicalSum: Int64 = 0
        /// Final (non-tmp) on-disk files with no committed reference.
        var orphanBytes: Int64 = 0
        var orphanSizes: [String: Int64] = [:]
        /// Existing committed artifact_physical rows (digest -> size).
        var physicalRows: [String: Int64] = [:]
    }

    static func snapshotByteLedger(_ db: Database, artifactsRoot root: String) throws -> ByteLedgerSnapshot {
        var snap = ByteLedgerSnapshot()
        let rows = try Row.fetchAll(db, sql: "SELECT session, payload, length(CAST(payload AS BLOB)) AS nbytes FROM records ORDER BY seq")
        for row in rows {
            guard let session: String = row["session"],
                  let payload: String = row["payload"],
                  let nbytes: Int64 = row["nbytes"] else {
                throw StoreError.integrity("byte ledger hit an unreadable record row")
            }
            let (gr1, go1) = snap.globalRecordBytes.addingReportingOverflow(nbytes)
            guard !go1 else {
                throw StoreError.integrity("byte ledger totals overflowed")
            }
            snap.globalRecordBytes = gr1
            let (pr1, po1) = (snap.perSessionRecordBytes[session] ?? 0).addingReportingOverflow(nbytes)
            guard !po1 else {
                throw StoreError.integrity("byte ledger totals overflowed")
            }
            snap.perSessionRecordBytes[session] = pr1
            guard let data = payload.data(using: .utf8) else {
                throw StoreError.integrity("byte ledger hit a non-UTF-8 record row")
            }
            let record: DurableRecord
            do {
                record = try RecordCodec.decode(data)
            } catch {
                throw StoreError.integrity("byte ledger hit an undecodable record row: \(error)")
            }
            if case .artifactPublished(let ref) = record {
                guard ref.size >= 0 else {
                    throw StoreError.integrity("byte ledger hit a negative artifact size for digest \(ref.digest)")
                }
                if let known = snap.digestSize[ref.digest] {
                    guard known == Int64(ref.size) else {
                        throw StoreError.integrity("byte ledger hit inconsistent artifact sizes for digest \(ref.digest)")
                    }
                } else {
                    snap.digestSize[ref.digest] = Int64(ref.size)
                }
                snap.sessionDigests[session, default: []].insert(ref.digest)
            }
        }
        let physRows = try Row.fetchAll(db, sql: "SELECT digest, size FROM artifact_physical")
        for row in physRows {
            guard let digest: String = row["digest"], let size: Int64 = row["size"] else {
                throw StoreError.integrity("byte ledger hit an unreadable artifact_physical row")
            }
            guard size >= 0 else {
                throw StoreError.integrity("byte ledger hit a negative artifact_physical size")
            }
            snap.physicalRows[digest] = size
            let (ps, po) = snap.physicalSum.addingReportingOverflow(size)
            guard !po else {
                throw StoreError.integrity("byte ledger totals overflowed")
            }
            snap.physicalSum = ps
        }
        if FileManager.default.fileExists(atPath: root) {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: root)
            } catch {
                throw StoreError.integrity("byte ledger cannot list artifact root: \(root): \(error)")
            }
            for entry in entries {
                if entry.hasPrefix(artifactTmpPrefix) { continue }
                if snap.digestSize[entry] != nil { continue }
                // Only regular files carry attributable bytes; lstat (never
                // follows symlinks — a symlink must not inherit its target's
                // size into the quota) plus S_ISREG, else skipped.
                if let size = Self.regularFileSize(root: root, entry: entry) {
                    let (ob, oo) = snap.orphanBytes.addingReportingOverflow(size)
                    guard !oo else {
                        throw StoreError.integrity("byte ledger totals overflowed")
                    }
                    snap.orphanBytes = ob
                    snap.orphanSizes[entry] = size
                }
            }
        }
        return snap
    }

    /// Size of a regular file by name inside a directory, or nil for
    /// anything else (missing, symlink, dir, special). Uses lstat so a
    /// symlink never donates its target's bytes.
    static func regularFileSize(root: String, entry: String) -> Int64? {
        var lst = stat()
        let path = root + "/" + entry
        guard lstat(path, &lst) == 0, (lst.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(lst.st_size)
    }

    /// Authoritative byte-quota check against a committed-state snapshot.
    /// `payloadBytes` is the new row's UTF-8 size; `digest`/`size` describe
    /// a referenced artifact (nil when the row is not a reference).
    /// Session logical grows by the payload plus the artifact size iff this
    /// session has not referenced the digest; global physical grows by the
    /// payload plus the artifact size iff no committed physical row exists.
    /// Physical rows with a mismatched size for the same digest are corrupt
    /// (fail closed, never averaged).
    ///
    /// Lightweight by design: the hot path (every append/publication) must
    /// not decode the whole ledger. Committed totals come from the
    /// accumulator tables (`byte_usage` PK lookup, `SUM`s) plus an on-disk
    /// orphan scan; only the session in question is examined for prior
    /// references (LIKE pre-filter + decode-confirm, exact — the substring
    /// alone never decides).
    struct ByteQuotaView {
        var logicalCurrent: Int64
        var physicalSum: Int64
        var globalRecordBytes: Int64
        var orphanBytes: Int64
        var physicalRows: [String: Int64]
        var sessionHasDigest: Bool
    }

    static func snapshotByteQuotas(_ db: Database, artifactsRoot root: String, session: String, digest: String?) throws -> ByteQuotaView {
        let logical: Int64? = try Int64.fetchOne(db, sql: "SELECT bytes FROM byte_usage WHERE session = ?", arguments: [session])
        let physicalSum = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM artifact_physical") ?? 0
        let recordBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(CAST(payload AS BLOB))), 0) FROM records") ?? 0
        var physicalRows: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT digest, size FROM artifact_physical") {
            guard let d: String = row["digest"], let s: Int64 = row["size"] else {
                throw StoreError.integrity("byte quota hit an unreadable artifact_physical row")
            }
            if s < 0 {
                throw StoreError.integrity("byte quota hit a negative artifact_physical size for digest \(d)")
            }
            physicalRows[d] = s
        }
        var orphanBytes: Int64 = 0
        if FileManager.default.fileExists(atPath: root) {
            let entries = try FileManager.default.contentsOfDirectory(atPath: root)
            for entry in entries {
                if entry.hasPrefix(artifactTmpPrefix) { continue }
                if physicalRows[entry] != nil { continue }
                if let size = Self.regularFileSize(root: root, entry: entry) {
                    let (nb, no) = orphanBytes.addingReportingOverflow(size)
                    guard !no else {
                        throw StoreError.integrity("byte ledger totals overflowed")
                    }
                    orphanBytes = nb
                }
            }
        }
        var sessionHasDigest = false
        if let d = digest {
            sessionHasDigest = try sessionReferencesDigest(db, session: session, digest: d)
        }
        var current = logical ?? 0
        if logical == nil {
            // No accumulator row: normally impossible (every insert path
            // bumps), so recompute this session exactly rather than
            // under-count (fail-closed direction is wrong here — an
            // under-count would admit over-quota writes).
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records WHERE session = ?", arguments: [session]) ?? 0
            if n > 0 {
                current = try recomputeSessionLogical(db, session: session)
            }
        }
        return ByteQuotaView(logicalCurrent: current, physicalSum: physicalSum, globalRecordBytes: recordBytes, orphanBytes: orphanBytes, physicalRows: physicalRows, sessionHasDigest: sessionHasDigest)
    }

    /// Exact session logical total by decoding only that session's rows.
    /// Slow path: used only when the accumulator row is missing (corrupt or
    /// manually edited tables), and by tests.
    static func recomputeSessionLogical(_ db: Database, session: String) throws -> Int64 {
        var total: Int64 = 0
        var seen: Set<String> = []
        let rows = try Row.fetchAll(db, sql: "SELECT payload, length(CAST(payload AS BLOB)) AS n FROM records WHERE session = ?", arguments: [session])
        for row in rows {
            guard let payload: String = row["payload"], let n: Int64 = row["n"] else {
                throw StoreError.integrity("byte quota hit an unreadable record row")
            }
            let (t1, o1) = total.addingReportingOverflow(n)
            guard !o1 else {
                throw StoreError.integrity("byte quota totals overflowed")
            }
            total = t1
            guard let data = payload.data(using: .utf8) else {
                throw StoreError.integrity("byte quota hit a non-UTF-8 record row")
            }
            let record: DurableRecord
            do {
                record = try RecordCodec.decode(data)
            } catch {
                throw StoreError.integrity("byte quota hit an undecodable record row: \(error)")
            }
            if case .artifactPublished(let ref) = record, !seen.contains(ref.digest) {
                seen.insert(ref.digest)
                let (t2, o2) = total.addingReportingOverflow(Int64(ref.size))
                guard !o2 else {
                    throw StoreError.integrity("byte quota totals overflowed")
                }
                total = t2
            }
        }
        return total
    }

    /// Exact session-scoped reference check: LIKE pre-filter, then decode
    /// each candidate and compare the digest. A substring match alone never
    /// counts (a transcript could contain the hex).
    static func sessionReferencesDigest(_ db: Database, session: String, digest: String) throws -> Bool {
        let candidates = try String.fetchAll(db, sql: "SELECT payload FROM records WHERE session = ? AND payload LIKE ?", arguments: [session, "%\(digest)%"])
        for payload in candidates {
            guard let data = payload.data(using: .utf8) else {
                throw StoreError.integrity("byte quota hit a non-UTF-8 record row")
            }
            let record: DurableRecord
            do {
                record = try RecordCodec.decode(data)
            } catch {
                throw StoreError.integrity("byte quota hit an undecodable record row: \(error)")
            }
            if case .artifactPublished(let ref) = record, ref.digest == digest {
                return true
            }
        }
        return false
    }

    /// Exact store-wide reference check (same LIKE + decode-confirm discipline).
    static func hasCommittedReference(_ db: Database, digest: String) throws -> Bool {
        let candidates = try String.fetchAll(db, sql: "SELECT payload FROM records WHERE payload LIKE ?", arguments: ["%\(digest)%"])
        for payload in candidates {
            guard let data = payload.data(using: .utf8) else {
                throw StoreError.integrity("byte quota hit a non-UTF-8 record row")
            }
            let record: DurableRecord
            do {
                record = try RecordCodec.decode(data)
            } catch {
                throw StoreError.integrity("byte quota hit an undecodable record row: \(error)")
            }
            if case .artifactPublished(let ref) = record, ref.digest == digest {
                return true
            }
        }
        return false
    }

    func checkByteQuotas(_ view: ByteQuotaView, session: String, payloadBytes: Int64, digest: String?, size: Int64, globalSizeAlreadyCounted: Bool = false) throws {
        // Caller-supplied sizes are untrusted: reject negatives (which
        // would subtract from quotas) before any arithmetic, and use
        // overflow-checked addition so huge values fail closed as quota
        // errors instead of trapping.
    // `globalSizeAlreadyCounted` covers the verified-adopt case: the
    // digest's bytes are already durable on disk (and still counted by the
    // orphan scan when unreferenced), so the global check must not add
    // them again — exactly-once counting either way.
        guard size >= 0, payloadBytes >= 0 else {
            throw StoreError.integrity("negative artifact size or payload")
        }
        if let d = digest, let existing = view.physicalRows[d], existing != size {
            throw StoreError.integrity("artifact physical size mismatch for digest \(d)")
        }
        let (inc, incOverflow) = (digest != nil && !view.sessionHasDigest) ? Int64(0).addingReportingOverflow(size) : (Int64(0), false)
        guard !incOverflow else {
            throw StoreError.quotaExceeded(limit: Int(sessionByteLimit))
        }
        let (logicalAdd, logicalAddOverflow) = payloadBytes.addingReportingOverflow(inc)
        guard !logicalAddOverflow else {
            throw StoreError.quotaExceeded(limit: Int(sessionByteLimit))
        }
        let (logicalTotal, logicalOverflow) = view.logicalCurrent.addingReportingOverflow(logicalAdd)
        guard !logicalOverflow, logicalTotal <= sessionByteLimit else {
            throw StoreError.quotaExceeded(limit: Int(sessionByteLimit))
        }
        var globalAdd = payloadBytes
        if let d = digest, !globalSizeAlreadyCounted, view.physicalRows[d] == nil {
            let (g2, go) = globalAdd.addingReportingOverflow(size)
            guard !go else {
                throw StoreError.quotaExceeded(limit: Int(globalByteLimit))
            }
            globalAdd = g2
        }
        let (partialGlobal, overflow1) = view.physicalSum.addingReportingOverflow(view.globalRecordBytes)
        let (partialGlobal2, overflow2) = partialGlobal.addingReportingOverflow(view.orphanBytes)
        let (globalTotal, overflow3) = partialGlobal2.addingReportingOverflow(globalAdd)
        guard !overflow1, !overflow2, !overflow3, globalTotal <= globalByteLimit else {
            throw StoreError.quotaExceeded(limit: Int(globalByteLimit))
        }
    }

    /// Commit one records row plus its byte accounting, inside the caller's
    /// transaction (artifact lock + gate already held). Inserts the row,
    /// bumps `byte_usage` (payload plus distinct artifact size for this
    /// session), and upserts `artifact_physical` (insert-or-ignore; a size
    /// mismatch fails closed in `checkByteQuotas` before any write).
    /// MUST be preceded by `checkByteQuotas` on a snapshot from the same
    /// transaction (no committed state can change in between: the lock
    /// serializes publishers and GRDB serializes write transactions).
    func commitRecordBytes(_ db: Database, session: String, payload: Data, digest: String?, size: Int64, sessionHasDigest: Bool) throws {
        guard size >= 0, payload.count >= 0 else {
            throw StoreError.integrity("negative artifact size or payload in commit path")
        }
        let last = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM records") ?? 0
        let (nextSeq, seqOverflow) = last.addingReportingOverflow(1)
        guard !seqOverflow else {
            throw StoreError.integrity("record sequence exhausted")
        }
        try db.execute(
            sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
            arguments: [nextSeq, session, String(decoding: payload, as: UTF8.self)])
        var bump = Int64(payload.count)
        if digest != nil, !sessionHasDigest {
            let (nb, no) = bump.addingReportingOverflow(size)
            guard !no else {
                throw StoreError.quotaExceeded(limit: Int(globalByteLimit))
            }
            bump = nb
        }
        try db.execute(
            sql: "INSERT INTO byte_usage (session, bytes) VALUES (?, ?) ON CONFLICT(session) DO UPDATE SET bytes = bytes + excluded.bytes",
            arguments: [session, bump])
        if let d = digest {
            try db.execute(
                sql: "INSERT INTO artifact_physical (digest, size) VALUES (?, ?) ON CONFLICT(digest) DO NOTHING",
                arguments: [d, size])
        }
    }

    /// Full quota-checked insert for a single record (append, recovery
    /// audit): light snapshot → check → commit, atomically. Decodes the
    /// payload once to discover artifact references (direct
    /// `.artifactPublished` appends get the same dedup-aware accounting
    /// as publications).
    func insertRecordWithQuota(_ db: Database, session: String, payload: Data) throws {
        let record: DurableRecord
        do {
            record = try RecordCodec.decode(payload)
        } catch {
            throw StoreError.integrity("undecodable record payload in quota path: \(error)")
        }
        var digest: String? = nil
        var size = 0
        if case .artifactPublished(let ref) = record {
            digest = ref.digest
            size = ref.size
        }
        let view = try Self.snapshotByteQuotas(db, artifactsRoot: artifactsRoot, session: session, digest: digest)
        try checkByteQuotas(view, session: session, payloadBytes: Int64(payload.count), digest: digest, size: Int64(size))
        try commitRecordBytes(db, session: session, payload: payload, digest: digest, size: Int64(size), sessionHasDigest: view.sessionHasDigest)
    }

    /// Batched quota-checked insert (appendBatch): ONE light snapshot for
    /// the whole batch (no per-record re-scan), then in-memory running
    /// totals across the batch. Commits or rolls back atomically.
    func insertRecordsBatchWithQuota(_ db: Database, session: String, payloads: [Data]) throws {
        struct Item { let payload: Data; let digest: String?; let size: Int64 }
        var items: [Item] = []
        items.reserveCapacity(payloads.count)
        var distinctDigests: [String] = []
        var seenNew: Set<String> = []
        for payload in payloads {
            let record: DurableRecord
            do {
                record = try RecordCodec.decode(payload)
            } catch {
                throw StoreError.integrity("undecodable record payload in quota path: \(error)")
            }
            if case .artifactPublished(let ref) = record {
                guard ref.size >= 0 else {
                    throw StoreError.integrity("negative artifact size for digest \(ref.digest)")
                }
                items.append(Item(payload: payload, digest: ref.digest, size: Int64(ref.size)))
                if !seenNew.contains(ref.digest) {
                    seenNew.insert(ref.digest)
                    distinctDigests.append(ref.digest)
                }
            } else {
                items.append(Item(payload: payload, digest: nil, size: 0))
            }
        }
        // One snapshot; sessionHasDigest per distinct digest only.
        let view = try Self.snapshotByteQuotas(db, artifactsRoot: artifactsRoot, session: session, digest: nil)
        var sessionHas: Set<String> = []
        for d in distinctDigests {
            if try Self.sessionReferencesDigest(db, session: session, digest: d) {
                sessionHas.insert(d)
            }
        }
        // Batch-internal consistency plus committed-row mismatch, both fail
        // closed before any insert (the per-item loop below only sees the
        // already-validated sizes).
        var batchSizes: [String: Int64] = [:]
        for item in items {
            guard let d = item.digest else { continue }
            if let prev = batchSizes[d] {
                guard prev == item.size else {
                    throw StoreError.integrity("artifact batch has inconsistent sizes for digest \(d)")
                }
            } else {
                batchSizes[d] = item.size
            }
            if let existing = view.physicalRows[d], existing != item.size {
                throw StoreError.integrity("artifact physical size mismatch for digest \(d)")
            }
        }
        var logicalRunning = view.logicalCurrent
        let (g1, go1) = view.physicalSum.addingReportingOverflow(view.globalRecordBytes)
        let (g2, go2) = g1.addingReportingOverflow(view.orphanBytes)
        guard !go1, !go2 else {
            throw StoreError.integrity("byte quota totals overflowed")
        }
        var globalRunning = g2
        var physicalKnown = view.physicalRows
        for item in items {
            var logicalAdd = Int64(item.payload.count)
            if let d = item.digest, !sessionHas.contains(d) {
                let (la, lo) = logicalAdd.addingReportingOverflow(item.size)
                guard !lo else {
                    throw StoreError.quotaExceeded(limit: Int(sessionByteLimit))
                }
                logicalAdd = la
            }
            let (newLogical, logicalOverflow) = logicalRunning.addingReportingOverflow(logicalAdd)
            guard !logicalOverflow, newLogical <= sessionByteLimit else {
                throw StoreError.quotaExceeded(limit: Int(sessionByteLimit))
            }
            var globalAdd = Int64(item.payload.count)
            if let d = item.digest, physicalKnown[d] == nil {
                let (ga, go) = globalAdd.addingReportingOverflow(item.size)
                guard !go else {
                    throw StoreError.quotaExceeded(limit: Int(globalByteLimit))
                }
                globalAdd = ga
            }
            let (newGlobal, globalOverflow) = globalRunning.addingReportingOverflow(globalAdd)
            guard !globalOverflow, newGlobal <= globalByteLimit else {
                throw StoreError.quotaExceeded(limit: Int(globalByteLimit))
            }
            let itemHasD: Bool = item.digest.map { sessionHas.contains($0) } ?? true
            try commitRecordBytes(db, session: session, payload: item.payload, digest: item.digest, size: item.size, sessionHasDigest: itemHasD)
            logicalRunning = newLogical
            globalRunning = newGlobal
            if let d = item.digest {
                sessionHas.insert(d)
                physicalKnown[d] = item.size
            }
        }
    }

    /// Reconcile-to-expected byte accounting (B3-B). Runs raw SQL inside one
    /// queue.write under the cross-process artifact lock — never the
    /// re-entrant `records()` helpers or `detectArtifactOrphans` (both would
    /// deadlock: re-entered gate + queue.read inside queue.write). Sets both
    /// tables to the computed expected totals, INCLUDING removals: stale
    /// physical rows (no reference and no file), overcounted usage rows, and
    /// byte_usage rows for sessions with no committed content are all
    /// lowered/removed, never merely bumped. Idempotent: a second run
    /// changes nothing. Crash-orphans stay under-counted by design (they
    /// gain a physical row here but no session ever claims them).
    public struct ByteReconciliation: Sendable, Equatable {
        public var orphanFilesAttributed: Int
        public var physicalRowsAdded: Int
        public var physicalRowsRemoved: Int
        public var sessionsSet: Int
        public var sessionsRemoved: Int
        public init(orphanFilesAttributed: Int, physicalRowsAdded: Int, physicalRowsRemoved: Int, sessionsSet: Int, sessionsRemoved: Int) {
            self.orphanFilesAttributed = orphanFilesAttributed
            self.physicalRowsAdded = physicalRowsAdded
            self.physicalRowsRemoved = physicalRowsRemoved
            self.sessionsSet = sessionsSet
            self.sessionsRemoved = sessionsRemoved
        }
    }

    public func reconcileByteUsage() throws -> ByteReconciliation {
        try withArtifactLock {
            gate.lock()
            defer { gate.unlock() }
            try assertOpenLocked()
            do {
                return try queue.write { db in
                    try Self.reconcileByteUsageInTxn(db, artifactsRoot: artifactsRoot)
                }
            } catch { throw Self.translate(error) }
        }
    }

    static func reconcileByteUsageInTxn(_ db: Database, artifactsRoot root: String) throws -> ByteReconciliation {
        let snap = try snapshotByteLedger(db, artifactsRoot: root)
        // Expected physical: every committed reference (ref size is ground
        // truth) plus every orphan file on disk (disk size).
        var expectedPhysical: [String: Int64] = [:]
        for (d, s) in snap.digestSize { expectedPhysical[d] = s }
        for (f, s) in snap.orphanSizes { expectedPhysical[f] = s }
        // Expected usage: record bytes plus per-session distinct artifacts.
        var expectedUsage: [String: Int64] = [:]
        for (sess, recBytes) in snap.perSessionRecordBytes {
            var total = recBytes
            for d in snap.sessionDigests[sess] ?? [] {
                guard let s = snap.digestSize[d] else {
                    throw StoreError.integrity("reconcile found reference without size for digest \(d)")
                }
                let (nt, no) = total.addingReportingOverflow(s)
                guard !no else {
                    throw StoreError.integrity("byte ledger totals overflowed")
                }
                total = nt
            }
            expectedUsage[sess] = total
        }
        var added = 0
        for (d, s) in expectedPhysical where snap.physicalRows[d] != s { added += 1 }
        var removed = 0
        for d in snap.physicalRows.keys where expectedPhysical[d] == nil { removed += 1 }
        let existingUsage = try Set(String.fetchAll(db, sql: "SELECT session FROM byte_usage"))
        var sessionsRemoved = 0
        for s in existingUsage where expectedUsage[s] == nil { sessionsRemoved += 1 }
        try db.execute(sql: "DELETE FROM artifact_physical")
        for (d, s) in expectedPhysical {
            try db.execute(sql: "INSERT INTO artifact_physical (digest, size) VALUES (?, ?)", arguments: [d, s])
        }
        try db.execute(sql: "DELETE FROM byte_usage")
        for (s, b) in expectedUsage {
            try db.execute(sql: "INSERT INTO byte_usage (session, bytes) VALUES (?, ?)", arguments: [s, b])
        }
        return ByteReconciliation(orphanFilesAttributed: snap.orphanSizes.count,
                                  physicalRowsAdded: added,
                                  physicalRowsRemoved: removed,
                                  sessionsSet: expectedUsage.count,
                                  sessionsRemoved: sessionsRemoved)
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

    // MARK: - Test inspection (B3-B byte accounting)

    /// Committed byte_usage rows (session -> bytes). Test-only introspection;
    /// production reads go through reconcile or the quota path.
    func byteUsageForTesting() throws -> [String: Int64] {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        var out: [String: Int64] = [:]
        do {
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT session, bytes FROM byte_usage")
            }
            for row in rows {
                guard let s: String = row["session"], let b: Int64 = row["bytes"] else {
                    throw StoreError.integrity("unreadable byte_usage row")
                }
                out[s] = b
            }
        } catch { throw Self.translate(error) }
        return out
    }

    /// Committed artifact_physical rows (digest -> size). Test-only.
    func artifactPhysicalForTesting() throws -> [String: Int64] {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        var out: [String: Int64] = [:]
        do {
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT digest, size FROM artifact_physical")
            }
            for row in rows {
                guard let d: String = row["digest"], let s: Int64 = row["size"] else {
                    throw StoreError.integrity("unreadable artifact_physical row")
                }
                out[d] = s
            }
        } catch { throw Self.translate(error) }
        return out
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

    public func artifactRecord(session: SessionID, digest: String) throws -> Data? {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        // Check if there's an artifactPublished for this session with this digest
        let payloads: [String]
        do {
            payloads = try queue.read { db in
                try String.fetchAll(db, sql: "SELECT payload FROM records WHERE session = ? ORDER BY seq", arguments: [session.raw])
            }
        } catch { throw Self.translate(error) }
        var found: ArtifactRef?
        for payload in payloads {
            guard let data = payload.data(using: .utf8),
                  let rec = try? RecordCodec.decode(data),
                  case .artifactPublished(let ref) = rec, ref.digest == digest else { continue }
            found = ref
            break
        }
        guard let ref = found else { return nil }
        return try readArtifact(ref)
    }

    /// Reads a PRAGMA on THIS store's connection (per-connection settings
    /// such as `synchronous` cannot be observed from another handle).
    /// Internal: durability assertions use it via `@testable import`.
    func pragmaValue(_ name: String) throws -> String? {
        gate.lock()
        defer { gate.unlock() }
        try assertOpenLocked()
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA " + name)
            }
        } catch { throw Self.translate(error) }
    }
}
