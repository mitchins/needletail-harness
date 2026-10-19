import Testing
import GRDB
import Foundation
import NeedletailCore
import NeedletailRuntime
@testable import NeedletailRuntime
import NeedletailTestSupport

/// M2-A A1 native-storage evidence over the PRODUCTION store
/// (`GRDBSessionStore`): reopen persistence (STORE-01), fail-closed
/// schema faults (STORE-05), and resume/list at scale (STORE-07).
/// These are the CERTIFYING variants (tier map: NeedletailPrimitiveTests
/// + `sqlite` token → `.nativeStorage`); the M2-0 probe-store tests
/// remain as supporting evidence but no longer certify STORE-01/07.
struct ProductionStoreTests {

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - STORE-01

    @Test("STORE-01 sqlite production store persists records across close and reopen")
    func STORE_01_sqliteProductionStorePersistsAcrossReopen() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let first = try GRDBSessionStore(path: path)
        let written: [DurableRecord] = (0..<5).map { .transcriptAppended(.user("msg-\($0)")) }
        for record in written { try first.append(record) }
        try first.close()

        // FRESH handle on the same file: identical records, dense sequences.
        let reopened = try GRDBSessionStore(path: path)
        let (all, next) = try reopened.records(since: 0, limit: 100)
        #expect(all.map(\.record) == written, "reopened store resumes identical records")
        #expect(all.map(\.sequence.value) == [1, 2, 3, 4, 5], "sequences stay dense across reopen")
        #expect(next == nil, "full read ends with a nil cursor")
        // New appends continue the dense sequence after reopen.
        try reopened.append(.transcriptAppended(.user("post-reopen")))
        let (tail, _) = try reopened.records(since: 5, limit: 10)
        #expect(tail.map(\.record) == [.transcriptAppended(.user("post-reopen"))])
        #expect(tail.first?.sequence.value == 6)
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
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }

        // Future-version refusal must name the reason.
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
        try rowStore.append(.transcriptAppended(.user("keep")))
        try rowStore.append(.transcriptAppended(.user("doomed")))
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
                try outer.execute(sql: """
                    CREATE TABLE records (seq \(seqDecl), payload TEXT NOT NULL)
                    """)
                try outer.execute(sql: """
                    CREATE TABLE writer (slot INTEGER PRIMARY KEY, owner TEXT NOT NULL)
                    """)
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
        try store.append(.transcriptAppended(.user("only")))
        do {
            _ = try store.records(since: 0, limit: 0)
            Issue.record("limit 0 must be an integrity fault")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        }
        do {
            _ = try store.records(since: 0, limit: -1)
            Issue.record("negative limit (SQLite no-limit) must be an integrity fault")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        }
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
            try store.append(.transcriptAppended(.user("after-close")))
            Issue.record("append after close must fail")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        }
    }

    // MARK: - STORE-07

    @Test("STORE-07 sqlite production store resumes the shared contract across pages")
    func STORE_07_sqliteProductionResumeAtScale() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path)
        // The SAME shared assertions the in-memory and probe backends run:
        // semantics cannot drift between backends.
        try StoreContractAssertions.assertAppendOrderAndPagination(store, variant: "production-sqlite")
        // Scale: a 10k-row history seeded via the single-transaction bulk
        // path (protocol `append` stays one-commit-per-record), then paged
        // back through a FRESH handle in bounded batches — never loaded
        // wholesale.
        try store.appendBatch((0..<10_000).map { .transcriptAppended(.user("bulk-\($0 % 97)")) })
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
}
