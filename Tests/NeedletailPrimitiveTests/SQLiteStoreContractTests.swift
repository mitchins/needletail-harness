import Testing
import GRDB
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Test-local SQLite `SessionStore` (NOT product code, NOT M2-A).
///
/// Exists only to execute the shared `StoreContractAssertions` against a
/// real database file, giving STORE-06/07/09 native-storage evidence.
/// Ordering, pagination, ownership and quota are enforced in SQL; record
/// PAYLOAD bytes ride a per-handle map keyed by rowid (SQL holds a
/// diagnostic fingerprint). A missing payload is `.integrity`, never a
/// silent substitution — but payload BYTE durability across reopen is proven
/// by the STORE-01/STORE-02 primitives, not here. The quota count cache is
/// exact under the single-writer contract runs (this handle is the sole
/// appender); the shared assertion's final SQL tally cross-checks it.
final class SQLiteProbeStore: SessionStore, @unchecked Sendable {
    private let queue: DatabaseQueue
    private let limit: Int
    private let lock = NSLock()
    private var recordCount: Int
    private var payloads: [Int64: DurableRecord] = [:]

    init(path: String, limit: Int) throws {
        // WAL is set via Configuration so the mode change happens at
        // connection setup, outside any transaction (a second handle on a
        // shared file cannot PRAGMA journal_mode from inside one).
        var configuration = Configuration()
        configuration.journalMode = .wal
        // NORMAL sync keeps the 10k-row quota fill fast; crash durability
        // is proven separately by the STORE-02 kill primitive, not here.
        // prepareDatabase runs outside any transaction, which both pragmas
        // require.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.queue = try DatabaseQueue(path: path, configuration: configuration)
        self.limit = limit
        var initial = 0
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    fingerprint TEXT NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS writer(
                    slot INTEGER PRIMARY KEY CHECK (slot = 1),
                    owner TEXT NOT NULL)
                """)
            initial = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records") ?? 0
        }
        self.recordCount = initial
    }

    func append(_ record: DurableRecord) throws {
        // Cached count: COUNT(*) per append is O(n) and makes the 10k fill
        // quadratic. The cache is exact — this handle is the sole writer in
        // every contract run — and the final row tally is verified in SQL.
        let count: Int = lock.withLock { recordCount }
        guard count < limit else { throw StoreError.quotaExceeded(limit: limit) }
        let rowID = try queue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO records (fingerprint) VALUES (?)",
                           arguments: [String(describing: record)])
            return db.lastInsertedRowID
        }
        lock.withLock {
            payloads[rowID] = record
            recordCount += 1
        }
    }

    func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq FROM records WHERE seq > ? ORDER BY seq LIMIT ?
                """, arguments: [since, limit])
        }
        let batch = try lock.withLock { () throws -> [SequencedRecord] in
            try rows.map { row in
                let seq: Int64 = row["seq"]
                guard let record = payloads[seq] else {
                    throw StoreError.integrity("payload missing for seq \(seq)")
                }
                return SequencedRecord(sequence: SequenceNumber(UInt64(seq)), record: record)
            }
        }
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    func claimWriterOwnership(session: SessionID) throws {
        // Atomic claim: the INSERT either wins the single row or loses it
        // in one statement — no read-then-write race between two handles.
        let won = try queue.write { db -> Bool in
            try db.execute(sql: """
                INSERT INTO writer (slot, owner) VALUES (1, ?)
                ON CONFLICT(slot) DO NOTHING
                """, arguments: [session.raw])
            return db.changesCount == 1
        }
        if won { return }
        // Row already held: re-claiming the same session is an idempotent
        // no-op, a different session learns the exact owner.
        let owner: String? = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT owner FROM writer WHERE slot = 1")
        }
        if owner != session.raw {
            throw StoreError.alreadyOwned(session: owner ?? "?")
        }
    }

    func releaseWriterOwnership(session: SessionID) {
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM writer WHERE slot = 1 AND owner = ?",
                           arguments: [session.raw])
        }
    }
}

/// STORE-06/07/09 over a real SQLite file (variant `sqlite`): the same
/// shared assertions as the in-memory backend, so semantics cannot drift
/// between mock and native tiers.
struct SQLiteStoreContractTests {

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("STORE-07 sqlite transcript resume and list preserves order across pages")
    func STORE_07_sqliteResumeListsInOrder() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteProbeStore(
            path: directory.appendingPathComponent("store.sqlite").path,
            limit: InMemorySessionStore.recordCap)
        try StoreContractAssertions.assertAppendOrderAndPagination(store, variant: "sqlite")
    }

    @Test("STORE-06 sqlite second writer on one session learns the exact owner")
    func STORE_06_sqliteWriterOwnershipExclusive() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let first = try SQLiteProbeStore(path: path, limit: InMemorySessionStore.recordCap)
        let second = try SQLiteProbeStore(path: path, limit: InMemorySessionStore.recordCap)
        try StoreContractAssertions.assertWriterOwnershipExclusive(
            first: first, second: second, variant: "sqlite")
    }

    @Test("STORE-09 sqlite store fills to quota then fails honestly")
    func STORE_09_sqliteQuotaBoundary() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteProbeStore(
            path: directory.appendingPathComponent("store.sqlite").path,
            limit: InMemorySessionStore.recordCap)
        try StoreContractAssertions.assertQuotaBoundary(
            store, limit: InMemorySessionStore.recordCap, variant: "sqlite")
    }
}
