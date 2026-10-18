import Testing
import GRDB
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Lossless codec for the transcript shapes the shared contract appends.
/// Shapes outside the codec fail reads with `.integrity` — the probe never
/// invents payload bytes.
private struct TranscriptPayload: Codable {
    var kind: String // "user" | "assistantText" | "toolCall" | "toolResponse"
    var text: String?
    var callID: String?
    var tool: String?
    var arguments: String?

    init(_ entry: TranscriptEntry) throws {
        switch entry {
        case .user(let text):
            self.init(kind: "user", text: text)
        case .assistantText(let text):
            self.init(kind: "assistantText", text: text)
        case .toolCall(let call):
            self.init(kind: "toolCall", callID: call.callID, tool: call.tool, arguments: call.arguments)
        case .toolResponse(let callID, let text):
            self.init(kind: "toolResponse", text: text, callID: callID)
        }
    }

    init(kind: String, text: String? = nil, callID: String? = nil, tool: String? = nil, arguments: String? = nil) {
        self.kind = kind
        self.text = text
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
    }

    var entry: TranscriptEntry? {
        switch kind {
        case "user":
            text.map(TranscriptEntry.user)
        case "assistantText":
            text.map(TranscriptEntry.assistantText)
        case "toolCall":
            if let callID, let tool, let arguments {
                TranscriptEntry.toolCall(NativeToolCall(callID: callID, tool: tool, arguments: arguments))
            } else { nil }
        case "toolResponse":
            if let callID, let text {
                TranscriptEntry.toolResponse(callID: callID, text: text)
            } else { nil }
        default:
            nil
        }
    }
}

private enum ProbePayload {
    static func encode(_ record: DurableRecord) throws -> String {
        guard case .transcriptAppended(let entry) = record else {
            throw StoreError.integrity("probe store persists transcript records only, got other shape")
        }
        let data = try JSONEncoder().encode(TranscriptPayload(entry))
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.integrity("payload is not UTF-8")
        }
        return text
    }

    static func decode(_ text: String) throws -> DurableRecord {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TranscriptPayload.self, from: data),
              let entry = payload.entry else {
            throw StoreError.integrity("undecodable payload: \(text.prefix(64))")
        }
        return .transcriptAppended(entry)
    }
}
final class SQLiteProbeStore: SessionStore, @unchecked Sendable {
    /// Test-local SQLite `SessionStore` (NOT product code, NOT M2-A).
    ///
/// Exists only to execute the shared `StoreContractAssertions` against a
/// real database file, giving STORE-07/09 native-storage evidence plus
/// global-writer-slot evidence (STORE-06 certification is deferred to M2-A;
/// see `XUnitIngestionTests.deferredToM2A`).
    /// Ordering, pagination, ownership and quota are enforced in SQL; record
    /// payloads persist in a `payload` column via the test-local lossless
    /// codec above, so a FRESH handle on the same file resumes the full
    /// history (STORE-07 reopen leg). The quota count cache is exact under
    /// the single-writer contract runs (this handle is the sole appender);
    /// the shared assertion's final SQL tally cross-checks it.
    private let queue: DatabaseQueue
    private let limit: Int
    private let lock = NSLock()
    private var recordCount: Int

    init(path: String, limit: Int) throws {
        // WAL is set via Configuration so the mode change happens at
        // connection setup, outside any transaction (a second handle on a
        // shared file cannot PRAGMA journal_mode from inside one).
        var configuration = Configuration()
        configuration.journalMode = .wal
        // NORMAL sync keeps the 10k-row quota fill fast; crash durability
        // is proven separately by the STORE-02 kill primitive, not here.
        // prepareDatabase runs outside any transaction, which this pragma
        // requires (journalMode above is applied by GRDB at connect time).
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
                    payload TEXT NOT NULL)
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
        // The payload codec throws .integrity for shapes the probe cannot
        // persist — before any SQL runs, so nothing half-written remains.
        let encoded = try ProbePayload.encode(record)
        let rowID = try queue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO records (payload) VALUES (?)",
                           arguments: [encoded])
            return db.lastInsertedRowID
        }
        lock.withLock { recordCount += 1 }
        _ = rowID
    }

    func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        let texts = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records WHERE seq > ? ORDER BY seq LIMIT ?
                """, arguments: [since, limit])
        }
        // Every row decodes through the lossless codec: a fresh handle on a
        // reopened file resumes identical records, not fingerprints.
        let batch = try texts.map { row -> SequencedRecord in
            let seq: Int64 = row["seq"]
            let payload: String = row["payload"]
            return try SequencedRecord(sequence: SequenceNumber(UInt64(seq)),
                                       record: ProbePayload.decode(payload))
        }
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
    }

    /// GRDB reaps the connection; the file stays for the next handle.
    func close() throws {
        try queue.close()
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

/// Global writer slot + STORE-07/09 over a real SQLite file (variant
/// `sqlite`): the same
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
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let first = try SQLiteProbeStore(path: dbPath, limit: InMemorySessionStore.recordCap)
        try StoreContractAssertions.assertAppendOrderAndPagination(first, variant: "sqlite")
        // Reopen leg: a FRESH handle on the same file resumes the identical
        // history — payloads persist in SQL, not in handle memory.
        try first.close()
        let reopened = try SQLiteProbeStore(path: dbPath, limit: InMemorySessionStore.recordCap)
        let (all, tailNext) = try reopened.records(since: 0, limit: Int.max)
        let expected = (0..<7).map { DurableRecord.transcriptAppended(.user("msg-\($0)")) }
        #expect(all.map(\.record) == expected, "reopened store resumes identical records")
        #expect(all.map(\.sequence.value) == [1, 2, 3, 4, 5, 6, 7], "reopened sequences stay dense")
        #expect(tailNext == nil, "full read ends with a nil cursor")
        let (tail, _) = try reopened.records(since: 4, limit: 10)
        #expect(tail.map(\.record) == Array(expected[4...]), "reopened since-cursor replays the tail")
    }

    @Test("global writer slot: a competing session's claim fails with the exact owner (sqlite)")
    func SingleWriterSlot_sqliteCompetingSessionLearnsOwner() throws {
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
