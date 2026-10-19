import Testing
import GRDB
import Foundation
import NeedletailCore
import NeedletailRuntime
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
        var cursor: UInt64? = 0
        var lastSeq: UInt64 = 0
        while let since = cursor {
            let (page, next) = try reopened.records(since: since, limit: 512)
            for record in page {
                #expect(record.sequence.value == lastSeq + 1, "sequences stay dense at scale")
                lastSeq = record.sequence.value
            }
            resumed += page.count
            cursor = next
        }
        #expect(resumed == 10_007, "7 shared-contract rows + 10k bulk rows resume in full, got \(resumed)")
    }
}
