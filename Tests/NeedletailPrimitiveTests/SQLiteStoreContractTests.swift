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
/// Test-local SQLite `SessionStore` (NOT product code, NOT M2-A).
///
/// Exists only to execute the shared `StoreContractAssertions` against a
/// real database file, giving STORE-06/07/09 assertions a second backend
/// (the production `GRDBSessionStore` certifies STORE-01/06/07/09).
/// Ownership fencing is shared-file SQL state; quota checks run inside the
/// same single transaction as the fence and the insert.
final class SQLiteProbeStore: SessionStore, @unchecked Sendable {
    private let queue: DatabaseQueue
    private let limit: Int

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
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    session TEXT NOT NULL,
                    payload TEXT NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS writer(
                    session TEXT PRIMARY KEY,
                    writer TEXT NOT NULL)
                """)
        }
    }

    func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
        // The payload codec throws .integrity for shapes the probe cannot
        // persist — before any SQL runs, so nothing half-written remains.
        let encoded = try ProbePayload.encode(record)
        // FENCE + QUOTA + INSERT in ONE write transaction (same as the
        // production store): the SQL ownership row is the only authority,
        // and no other handle can reassign between check and insert.
        try queue.write { db in
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [identity.session.raw])
            guard holder == identity.writer else {
                throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records") ?? 0
            guard count < limit else { throw StoreError.quotaExceeded(limit: limit) }
            try db.execute(sql: "INSERT INTO records (session, payload) VALUES (?, ?)",
                           arguments: [identity.session.raw, encoded])
        }
    }

    /// SESSION-SCOPED read (per-session log, per-session cursors).
    func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
        let texts = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, payload FROM records WHERE session = ? AND seq > ? ORDER BY seq LIMIT ?
                """, arguments: [session.raw, since, limit])
        }
        let batch = try texts.map { row -> SequencedRecord in
            let seq: Int64 = row["seq"]
            let payload: String = row["payload"]
            return try SequencedRecord(
                sequence: SequenceNumber(UInt64(seq)),
                record: ProbePayload.decode(payload))
        }
        let next: UInt64? = batch.count < limit ? nil : batch.last?.sequence.value
        return (batch, next)
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

    func claimWriterOwnership(session: SessionID, writer: String) throws {
        // A2 fencing persisted in the SHARED file: the atomic INSERT means
        // a competing handle either wins the row or reads exactly who does.
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO writer (session, writer) VALUES (?, ?) ON CONFLICT(session) DO NOTHING",
                arguments: [session.raw, writer])
            let holder = try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [session.raw])
            guard holder == writer else {
                throw StoreError.alreadyOwned(session: session.raw, writer: holder ?? "?")
            }
        }
    }

    func releaseWriterOwnership(session: SessionID, writer: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM writer WHERE session = ? AND writer = ?",
                arguments: [session.raw, writer])
            guard db.changesCount == 1 else {
                throw StoreError.notWriter(session: session.raw, writer: writer)
            }
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
        let identity = StoreContractAssertions.primaryIdentity
        try first.claimWriterOwnership(session: identity.session, writer: identity.writer)
        try StoreContractAssertions.assertAppendOrderAndPagination(first, variant: "sqlite", identity: identity)
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

    @Test("STORE-06 fencing contract holds on the sqlite probe backend")
    func STORE_06_sqliteProbeFencingContract() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let first = try SQLiteProbeStore(path: path, limit: InMemorySessionStore.recordCap)
        let second = try SQLiteProbeStore(path: path, limit: InMemorySessionStore.recordCap)
        try StoreContractAssertions.assertWriterFencing(
            first: first, second: second, variant: "sqlite-probe")
    }

    @Test("STORE-09 sqlite store fills to quota then fails honestly")
    func STORE_09_sqliteQuotaBoundary() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteProbeStore(
            path: directory.appendingPathComponent("store.sqlite").path,
            limit: InMemorySessionStore.recordCap)
        let identity = WriterIdentity(session: SessionID("s-q"), writer: "quota")
        try store.claimWriterOwnership(session: identity.session, writer: identity.writer)
        try StoreContractAssertions.assertQuotaBoundary(
            store, limit: InMemorySessionStore.recordCap, variant: "sqlite",
            identity: identity)
    }
}
