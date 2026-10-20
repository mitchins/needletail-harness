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
    public static let schemaVersion: Int32 = 2

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
    private var closed = false
    /// Serializes every operation against `close` so the typed
    /// closed-store contract holds atomically (A1 stabilization).
    private let gate = NSLock()

    public init(path: String, sessionRecordLimit: Int = 10_000, globalRecordLimit: Int = 100_000, artifactByteLimit: Int = 32 * 1024 * 1024) throws {
        self.path = path
        self.sessionRecordLimit = sessionRecordLimit
        self.globalRecordLimit = globalRecordLimit
        self.artifactByteLimit = artifactByteLimit
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
            let last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            try db.execute(
                sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
                arguments: [last + 1, session.raw,
                            String(decoding: encoded, as: UTF8.self)])
        } } catch { throw Self.translate(error) }
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
    public func publishArtifact(
        session: SessionID, as identity: WriterIdentity,
        kind: String, operationID: OperationID?, bytes: Data
    ) throws -> ArtifactRef {
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
        if FileManager.default.fileExists(atPath: finalPath) {
            // Dedup path: identical bytes may already be durable — but a
            // final-named file can exist WITHOUT established durability
            // (crash between a previous rename and its dirsync, or
            // out-of-band placement). Re-establish it now: open WITHOUT
            // following links, require a regular file, verify the digest,
            // repair private mode, fsync the file AND the root — only then
            // is the reference committable. A squatter with colliding
            // content fails closed and is never overwritten.
            let fd: Int32 = finalPath.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
            guard fd >= 0 else {
                throw StoreError.integrity("artifact file cannot be opened (symlink?): \(digest)")
            }
            defer { closeArtifactFD(fd) }
            var fileStatus = stat()
            guard fstat(fd, &fileStatus) == 0,
                  (fileStatus.st_mode & S_IFMT) == S_IFREG else {
                throw StoreError.integrity("artifact path is not a regular file: \(digest)")
            }
            let existing = try readBoundedFD(fd, bound: min(bytes.count, artifactByteLimit))
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
        } else {
            let tmpPath = try resolveArtifactPath(
                root: root, name: artifactTmpPrefix + UUID().uuidString)
            do {
                guard FileManager.default.createFile(
                    atPath: tmpPath, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else {
                    throw StoreError.integrity("artifact tmp file creation failed")
                }
                guard let handle = FileHandle(forWritingAtPath: tmpPath) else {
                    throw StoreError.integrity("artifact tmp file is not writable")
                }
                do {
                    try handle.write(contentsOf: bytes)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? FileManager.default.removeItem(atPath: tmpPath)
                    throw StoreError.integrity("artifact tmp write/fsync failed: \(error)")
                }
                try FileManager.default.moveItem(atPath: tmpPath, toPath: finalPath)
                try syncArtifactDirectory(atPath: root)
                // Verify what was actually published, before any reference
                // exists: the committed reference can never point at an
                // absent, incomplete or mismatched file.
                let published = try readVerifiedArtifact(
                    atPath: finalPath, digest: digest, expectedSize: bytes.count)
                guard published.count == bytes.count else {
                    throw StoreError.integrity("published artifact failed verification for digest \(digest)")
                }
            } catch let error as StoreError {
                throw error
            } catch {
                throw StoreError.integrity("artifact publication failed: \(error)")
            }
        }
        // Fenced reference commit: holder re-checked, record quotas
        // enforced, single insert — same transaction, same guarantees as
        // every other durable mutation.
        let ref = ArtifactRef(digest: digest, size: bytes.count, kind: kind, operationID: operationID)
        let payload = try RecordCodec.encode(DurableRecord.artifactPublished(ref))
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
            let last = try Int64.fetchOne(
                db, sql: "SELECT MAX(seq) FROM records") ?? 0
            try db.execute(
                sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
                arguments: [last + 1, identity.session.raw,
                            String(decoding: payload, as: UTF8.self)])
        } } catch { throw Self.translate(error) }
        return ref
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
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA " + name)
            }
        } catch { throw Self.translate(error) }
    }
}
