import Testing
import GRDB
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
@testable import NeedletailRuntime

/// M2-A production-store native-storage evidence (`GRDBSessionStore`):
/// reopen persistence (STORE-01), durability pragmas (STORE-01),
/// fail-closed schema faults (STORE-05), resume/list at scale (STORE-07),
/// per-session fenced writer ownership (STORE-06) and quotas (STORE-09).
/// These are the CERTIFYING variants (tier map: NeedletailPrimitiveTests
/// + `sqlite` token → `.nativeStorage`).
struct ProductionStoreTests {

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let identity = WriterIdentity(
        session: SessionID("s-prod"), writer: "prod-1")

    // MARK: - STORE-01

    @Test("STORE-01 sqlite production store persists records across close and reopen")
    func STORE_01_sqliteProductionStorePersistsAcrossReopen() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let first = try GRDBSessionStore(path: path)
        try first.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        let written: [DurableRecord] = (0..<5).map { .transcriptAppended(.user("msg-\($0)")) }
        for record in written { try first.append(record, as: Self.identity) }
        try first.close()

        // FRESH handle on the same file: identical records, dense sequences.
        let reopened = try GRDBSessionStore(path: path)
        let (all, next) = try reopened.records(since: 0, limit: 100)
        #expect(all.map(\.record) == written, "reopened store resumes identical records")
        #expect(all.map(\.sequence.value) == [1, 2, 3, 4, 5], "sequences stay dense across reopen")
        #expect(next == nil, "full read ends with a nil cursor")
        // New appends continue the dense sequence after reopen — the
        // writer claim SURVIVED the close (durable ownership), so the same
        // identity appends without re-claiming.
        try reopened.append(.transcriptAppended(.user("post-reopen")), as: Self.identity)
        let (tail, _) = try reopened.records(since: 5, limit: 10)
        #expect(tail.map(\.record) == [.transcriptAppended(.user("post-reopen"))])
        #expect(tail.first?.sequence.value == 6)
    }

    @Test("STORE-01 sqlite durability pragmas hold on the store's own connection")
    func STORE_01_sqliteDurabilityPragmasHoldOnOwnConnection() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path)
        // GRDB's WAL setup forces synchronous=NORMAL after prepareDatabase;
        // the store re-asserts FULL post-init. Verify on the store's OWN
        // connection (these pragmas are per-connection).
        let synchronous = try store.pragmaValue("synchronous")
        let journalMode = try store.pragmaValue("journal_mode")
        #expect(synchronous == "2", "synchronous must be FULL (2), got \(synchronous ?? "?")")
        #expect(journalMode == "wal", "journal_mode must be wal, got \(journalMode ?? "?")")
        // Post-close operations are typed .integrity, never GRDB misuse.
        try store.close()
        do {
            try store.append(.transcriptAppended(.user("after-close")), as: Self.identity)
            Issue.record("append after close must fail")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        }
    }

    // MARK: - STORE-05

    @Test("STORE-05 sqlite future schema version and corrupt store fail closed")
    func STORE_05_sqliteFutureOrCorruptStoreFailsClosed() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        // Future schema version: a store written by a NEWER binary must
        // refuse to open — never migrate backwards, never guess.
        let future = try GRDBSessionStore(path: path)
        try future.close()
        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: "PRAGMA user_version = \(GRDBSessionStore.schemaVersion + 1)")
        }
        do {
            _ = try GRDBSessionStore(path: path)
            Issue.record("a future-schema store must refuse to open")
        } catch let error as StoreError {
            guard case .integrity(let message) = error, message.contains("future schema version") else {
                Issue.record("expected future-schema .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }

        // Corrupt file: valid SQLite header garbage is unreadable as our
        // schema — open must fail closed, never construct a half store.
        let corruptPath = directory.appendingPathComponent("corrupt.sqlite").path
        try Data("this is not a database, but it starts like one".utf8).write(to: URL(fileURLWithPath: corruptPath))
        do {
            _ = try GRDBSessionStore(path: corruptPath)
            Issue.record("a corrupt store must refuse to open")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }

        // Foreign schema stamped with OUR version: opens must fail on the
        // shape check, never silently adopt incompatible tables.
        let foreignPath = directory.appendingPathComponent("foreign.sqlite").path
        let foreign = try GRDBSessionStore(path: foreignPath)
        try foreign.close()
        let rawForeign = try DatabaseQueue(path: foreignPath)
        try rawForeign.write { db in
            try db.execute(sql: "DROP TABLE records")
            try db.execute(sql: "CREATE TABLE records (different INTEGER)")
        }
        do {
            _ = try GRDBSessionStore(path: foreignPath)
            Issue.record("a foreign-schema store must refuse to open")
        } catch let error as StoreError {
            guard case .integrity(let message) = error, message.contains("foreign or incompatible") else {
                Issue.record("expected foreign-schema .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }

        // Corrupt PAYLOAD row: a valid store file with one undecodable row
        // fails reads with .integrity — never skipped, never substituted.
        let rowPath = directory.appendingPathComponent("rowfault.sqlite").path
        let rowStore = try GRDBSessionStore(path: rowPath)
        try rowStore.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        try rowStore.append(.transcriptAppended(.user("keep")), as: Self.identity)
        try rowStore.append(.transcriptAppended(.user("doomed")), as: Self.identity)
        let rawRow = try DatabaseQueue(path: rowPath)
        try rawRow.write { db in
            try db.execute(sql: "UPDATE records SET payload = 'garbage' WHERE seq = 2")
        }
        do {
            _ = try rowStore.records(since: 0, limit: 100)
            Issue.record("a corrupt payload row must fail reads")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }
    }

    @Test("STORE-05 sqlite foreign unversioned store is rejected before adoption")
    func STORE_05_sqliteForeignVersionZeroRejected() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Foreign v0: a valid SQLite file with user tables that are not a
        // needletail schema must be rejected BEFORE we create or stamp
        // anything.
        let foreignPath = directory.appendingPathComponent("foreign-v0.sqlite").path
        let foreignDB = try DatabaseQueue(path: foreignPath)
        try foreignDB.write { db in
            try db.execute(sql: "CREATE TABLE payments (id INTEGER PRIMARY KEY, cents INTEGER)")
            try db.execute(sql: "INSERT INTO payments (cents) VALUES (42)")
        }
        do {
            _ = try GRDBSessionStore(path: foreignPath)
            Issue.record("a foreign v0 store must be rejected, not adopted")
        } catch let error as StoreError {
            guard case .integrity(let message) = error, message.contains("foreign unversioned") else {
                Issue.record("expected foreign-v0 .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }
        // Nothing was written into the foreign file.
        let recheck = try DatabaseQueue(path: foreignPath)
        let tables = try recheck.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
        }
        #expect(tables == ["payments"], "foreign store must be untouched, got \(tables.sorted())")

        // Crashed-migration v0 (OUR tables present, stamped v0): opening
        // RESUMES the migration rather than rejecting.
        let crashedPath = directory.appendingPathComponent("crashed-v0.sqlite").path
        let crashed = try GRDBSessionStore(path: crashedPath)
        try crashed.close()
        let rawCrashed = try DatabaseQueue(path: crashedPath)
        try rawCrashed.write { db in
            try db.execute(sql: "PRAGMA user_version = 0")
        }
        let resumed = try GRDBSessionStore(path: crashedPath)
        let (all, _) = try resumed.records(since: 0, limit: 10)
        #expect(all.isEmpty, "resumed store opens clean")
    }

    @Test("STORE-05 sqlite impostor column types and primary keys are rejected")
    func STORE_05_sqliteImpostorColumnTypesRejected() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // records.seq TEXT PRIMARY KEY: same column NAMES, incompatible
        // declared type and key metadata — ordering would corrupt silently
        // (10 sorts after 9) if only names were checked.
        func impostor(path: String, seqDecl: String) throws {
            let db = try DatabaseQueue(path: path)
            try db.write { outer in
                try outer.execute(sql: "CREATE TABLE records (seq \(seqDecl), payload TEXT NOT NULL)")
                try outer.execute(sql: "CREATE TABLE writer (slot INTEGER PRIMARY KEY, owner TEXT NOT NULL)")
            }
            do {
                _ = try GRDBSessionStore(path: path)
                Issue.record("impostor schema \(seqDecl) must be rejected")
            } catch let error as StoreError {
                guard case .integrity(let message) = error, message.contains("foreign or incompatible") else {
                    Issue.record("expected impostor-schema .integrity, got \(error)"); return
                }
            } catch {
                Issue.record("expected StoreError.integrity, got \(error)"); return
            }
        }
        try impostor(path: directory.appendingPathComponent("text-seq.sqlite").path,
                     seqDecl: "TEXT PRIMARY KEY")
        try impostor(path: directory.appendingPathComponent("no-pk-seq.sqlite").path,
                     seqDecl: "INTEGER")
    }

    @Test("STORE-05 store refuses non-positive page limits")
    func STORE_05_sqliteRejectsNonPositiveLimit() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path)
        try store.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        try store.append(.transcriptAppended(.user("only")), as: Self.identity)
        for badLimit in [0, -1] {
            do {
                _ = try store.records(since: 0, limit: badLimit)
                Issue.record("limit \(badLimit) must be an integrity fault")
            } catch let error as StoreError {
                guard case .integrity = error else {
                    Issue.record("expected .integrity, got \(error)"); return
                }
            }
        }
    }

    // MARK: - STORE-06 (the M2-0 deferral lands here)

    @Test("STORE-06 sqlite two writers compete for one session (fenced)")
    func STORE_06_sqliteTwoWritersCompeteForOneSession() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        // GENUINELY independent handles on one file.
        let first = try GRDBSessionStore(path: path)
        let second = try GRDBSessionStore(path: path)
        try StoreContractAssertions.assertWriterFencing(
            first: first, second: second, variant: "production-sqlite")
    }

    // MARK: - STORE-07

    @Test("STORE-07 sqlite production store resumes the shared contract across pages")
    func STORE_07_sqliteProductionResumeAtScale() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The scale leg seeds 10k rows into one session: raise that
        // session's quota for THIS store (quotas themselves are STORE-09).
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path,
            sessionRecordLimit: 20_000)
        try store.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        // The SAME shared assertions the in-memory and probe backends run:
        // semantics cannot drift between backends.
        try StoreContractAssertions.assertAppendOrderAndPagination(
            store, variant: "production-sqlite", identity: Self.identity)
        // Scale: a 10k-row history seeded via the single-transaction bulk
        // path (protocol `append` stays one-commit-per-record), then paged
        // back through a FRESH handle in bounded batches — never loaded
        // wholesale.
        try store.appendBatch((0..<10_000).map { .transcriptAppended(.user("bulk-\($0 % 97)")) }, as: Self.identity)
        try store.close()
        let reopened = try GRDBSessionStore(path: store.path)
        var resumed = 0
        var pages = 0
        var cursor: UInt64? = 0
        var lastSeq: UInt64 = 0
        while let since = cursor {
            let (page, next) = try reopened.records(since: since, limit: 512)
            // Bounded paging is the contract: a page never exceeds the
            // limit, and the resume provably takes MANY pages (10007 rows
            // / 512) — never loaded wholesale.
            #expect(page.count <= 512, "page must respect the limit, got \(page.count)")
            for record in page {
                #expect(record.sequence.value == lastSeq + 1, "sequences stay dense at scale")
                lastSeq = record.sequence.value
            }
            resumed += page.count
            pages += 1
            cursor = next
        }
        #expect(resumed == 10_007, "7 shared-contract rows + 10k bulk rows resume in full, got \(resumed)")
        #expect(pages >= 20, "10_007 rows at limit 512 must take ~20 pages, got \(pages)")
    }

    // MARK: - STORE-09

    @Test("STORE-09 sqlite production quotas enforce inside the transaction")
    func STORE_09_sqliteProductionQuotasEnforceInTransaction() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Small configured limits: no 10k fill needed to prove the rule.
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path,
            sessionRecordLimit: 3, globalRecordLimit: 5)
        let s1 = WriterIdentity(session: SessionID("s-one"), writer: "w-one")
        let s2 = WriterIdentity(session: SessionID("s-two"), writer: "w-two")
        let s3 = WriterIdentity(session: SessionID("s-three"), writer: "w-three")
        for identity in [s1, s2, s3] {
            try store.claimWriterOwnership(session: identity.session, writer: identity.writer)
        }
        // Session quota: s-one fills its 3 rows; the 4th fails honestly.
        for i in 0..<3 { try store.append(.transcriptAppended(.user("one-\(i)")), as: s1) }
        #expect(throws: StoreError.quotaExceeded(limit: 3)) {
            try store.append(.transcriptAppended(.user("one-overflow")), as: s1)
        }
        // Another session is unaffected by s-one's session quota.
        try store.append(.transcriptAppended(.user("two-0")), as: s2)
        // Global quota: 3 (s-one) + 1 (s-two) + 1 (s-two) = 5 → s-three's
        // first append breaches the global cap.
        try store.append(.transcriptAppended(.user("two-1")), as: s2)
        #expect(throws: StoreError.quotaExceeded(limit: 5)) {
            try store.append(.transcriptAppended(.user("three-0")), as: s3)
        }
        // In-transaction proof: a batch that would breach rolls back WHOLE
        // — no partial rows slip past the quota check.
        #expect(throws: StoreError.quotaExceeded(limit: 5)) {
            try store.appendBatch((0..<4).map { .transcriptAppended(.user("batch-\($0)")) }, as: s3)
        }
        let (all, _) = try store.records(since: 0, limit: 100)
        #expect(all.count == 5, "failed batch must leave zero partial rows, got \(all.count)")
        // Released capacity still appends: a released session's rows stay
        // (history is never rewritten), but the freed WRITER can retry on
        // another session within the global cap... global is full, so the
        // honest end state: every further append still fails.
        #expect(throws: StoreError.quotaExceeded(limit: 5)) {
            try store.append(.transcriptAppended(.user("two-2")), as: s2)
        }
    }
}
