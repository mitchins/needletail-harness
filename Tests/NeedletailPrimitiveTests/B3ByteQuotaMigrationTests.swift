import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import GRDB
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B3-B part 2: migration, reconciliation, old-binary behavior,
/// free-space reserve, no-replay, and recovery byte accounting.
struct B3ByteQuotaMigrationTests {
    private static func tempDir(_ prefix: String = "b3m") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func usage(of store: GRDBSessionStore, session: String) throws -> Int64? {
        try store.byteUsageForTesting()[session]
    }

    @Test("TOOL_migrateV2ToV3Backfills")
    func migrateV2ToV3Backfills() async throws {
        // Hand-build a genuine v2 store: transcript + artifactPublished rows
        // across two sessions sharing one digest, plus the artifact file.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let digest = Self.sha(Data("shared-13byt".utf8))
        #expect(digest.count == 64)
        let refPayloadA: String = {
            let ref = ArtifactRef(digest: digest, size: 13, kind: "exec-output", operationID: nil)
            return String(decoding: try! RecordCodec.encode(DurableRecord.artifactPublished(ref)), as: UTF8.self)
        }()
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE records(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL, session TEXT NOT NULL DEFAULT '')")
            try db.execute(sql: "CREATE TABLE writer(session TEXT PRIMARY KEY, writer TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO records (payload, session) VALUES (?, ?)", arguments: [String(decoding: try RecordCodec.encode(DurableRecord.transcriptAppended(.user("hello"))), as: UTF8.self), "s-1"])
            try db.execute(sql: "INSERT INTO records (payload, session) VALUES (?, ?)", arguments: [refPayloadA, "s-1"])
            try db.execute(sql: "INSERT INTO records (payload, session) VALUES (?, ?)", arguments: [refPayloadA, "s-2"])
            try db.execute(sql: "INSERT INTO writer (session, writer) VALUES (?, ?)", arguments: ["s-1", "w"])
            try db.execute(sql: "INSERT INTO writer (session, writer) VALUES (?, ?)", arguments: ["s-2", "w"])
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        let root = GRDBSessionStore.artifactsRoot(for: path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("shared-13byt".utf8).write(to: URL(fileURLWithPath: root + "/" + digest))
        // Open migrates v2 -> v3 with recompute-to-expected backfill.
        let store = try GRDBSessionStore(path: path)
        defer { try? store.close() }
        let phys = try store.artifactPhysicalForTesting()
        #expect(phys == [digest: 13], "physical backfilled from committed refs, got \(phys)")
        let s1rec = try RecordCodec.encode(DurableRecord.transcriptAppended(.user("hello"))).count + refPayloadA.utf8.count
        let usage = try store.byteUsageForTesting()
        #expect(usage["s-1"] == Int64(s1rec + 13), "s-1 gets record bytes + its distinct artifact, got \(String(describing: usage["s-1"])) vs \(s1rec + 13)")
        let s2rec = refPayloadA.utf8.count
        #expect(usage["s-2"] == Int64(s2rec + 13), "s-2 gets its own logical share of the shared digest")
        // Reopen is stable (idempotent migration).
        try store.close()
        let reopened = try GRDBSessionStore(path: path)
        defer { try? reopened.close() }
        #expect(try reopened.artifactPhysicalForTesting() == phys)
        #expect(try reopened.byteUsageForTesting() == usage)
    }

    @Test("TOOL_migrateEmptyV2Store")
    func migrateEmptyV2Store() async throws {
        // A v2 store with tables but no rows migrates to empty v3 tables.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE records(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL, session TEXT NOT NULL DEFAULT '')")
            try db.execute(sql: "CREATE TABLE writer(session TEXT PRIMARY KEY, writer TEXT NOT NULL)")
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        let store = try GRDBSessionStore(path: path)
        defer { try? store.close() }
        #expect(try store.byteUsageForTesting().isEmpty)
        #expect(try store.artifactPhysicalForTesting().isEmpty)
    }

    @Test("TOOL_reconcileOrphan")
    func reconcileOrphan() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        let session = SessionID("s-r")
        try store.claimWriterOwnership(session: session, writer: "w")
        let identity = WriterIdentity(session: session, writer: "w")
        // Committed artifact + an unreferenced orphan file + a tmp leftover.
        _ = try store.publishArtifact(session: session, as: identity, kind: "t", operationID: nil, bytes: Data("committed".utf8))
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let orphanBytes = Data("orphan-data!!".utf8)
        let orphanDigest = Self.sha(orphanBytes)
        try orphanBytes.write(to: URL(fileURLWithPath: root + "/" + orphanDigest))
        try Data("partial".utf8).write(to: URL(fileURLWithPath: root + "/.tmp-leftover"))
        let before = try store.byteUsageForTesting()
        let report = try store.reconcileByteUsage()
        #expect(report.orphanFilesAttributed == 1, "one orphan attributed, got \(report)")
        let phys = try store.artifactPhysicalForTesting()
        #expect(phys[orphanDigest] == Int64(orphanBytes.count), "orphan gains a physical row")
        #expect(phys.count == 2, "committed + orphan physical rows, got \(phys)")
        #expect(try store.byteUsageForTesting() == before, "no session is ever charged for orphans")
        // Idempotent: second run changes nothing.
        let snap1 = (try store.byteUsageForTesting(), try store.artifactPhysicalForTesting())
        let report2 = try store.reconcileByteUsage()
        #expect(report2.physicalRowsAdded == 0 && report2.physicalRowsRemoved == 0 && report2.sessionsSet == snap1.0.count, "second run is a no-op on tables")
        #expect((try store.byteUsageForTesting(), try store.artifactPhysicalForTesting()) == snap1, "tables byte-identical after second run")
    }

    @Test("TOOL_reconcileMissingLogical")
    func reconcileMissingLogical() async throws {
        // Simulate a historical miss: committed reference whose session
        // lost its byte_usage row AND whose physical row is gone.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        let session = SessionID("s-m")
        try store.claimWriterOwnership(session: session, writer: "w")
        let identity = WriterIdentity(session: session, writer: "w")
        let bytes = Data("ref-bytes-here!".utf8)
        let ref = try store.publishArtifact(session: session, as: identity, kind: "t", operationID: nil, bytes: bytes)
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("store.sqlite").path)
        try await raw.write { db in
            try db.execute(sql: "DELETE FROM byte_usage WHERE session = ?", arguments: [session.raw])
            try db.execute(sql: "DELETE FROM artifact_physical WHERE digest = ?", arguments: [ref.digest])
        }
        #expect(try store.byteUsageForTesting()[session.raw] == nil)
        #expect(try store.artifactPhysicalForTesting()[ref.digest] == nil)
        let report = try store.reconcileByteUsage()
        #expect(report.sessionsSet >= 1 && report.physicalRowsAdded >= 1, "missing rows restored, got \(report)")
        let usage = try store.byteUsageForTesting()
        let expectedRef = try RecordCodec.encode(DurableRecord.artifactPublished(ref)).count
        #expect(usage[session.raw] == Int64(expectedRef + bytes.count), "usage restored exactly, got \(String(describing: usage[session.raw])) vs \(expectedRef + bytes.count)")
        #expect(try store.artifactPhysicalForTesting()[ref.digest] == Int64(bytes.count))
    }

    @Test("TOOL_reconcileStaleRemovalAndOvercount")
    func reconcileStaleRemovalAndOvercount() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        let session = SessionID("s-s")
        try store.claimWriterOwnership(session: session, writer: "w")
        let identity = WriterIdentity(session: session, writer: "w")
        // (a) Orphan file gains a row, then the file is deleted -> row removed.
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let orphan = Data("stale-orphan!".utf8)
        let orphanDigest = Self.sha(orphan)
        try orphan.write(to: URL(fileURLWithPath: root + "/" + orphanDigest))
        _ = try store.reconcileByteUsage()
        #expect(try store.artifactPhysicalForTesting()[orphanDigest] == Int64(orphan.count))
        try FileManager.default.removeItem(atPath: root + "/" + orphanDigest)
        let r1 = try store.reconcileByteUsage()
        #expect(r1.physicalRowsRemoved >= 1, "deleted orphan row removed, got \(r1)")
        #expect(try store.artifactPhysicalForTesting()[orphanDigest] == nil)
        // (b) Committed digest whose last reference is deleted and whose file
        // is gone -> row removed; overcounted usage lowered.
        let bytes = Data("gone-soon-data!".utf8)
        let ref = try store.publishArtifact(session: session, as: identity, kind: "t", operationID: nil, bytes: bytes)
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("store.sqlite").path)
        try await raw.write { db in
            try db.execute(sql: "DELETE FROM records WHERE payload LIKE ?", arguments: ["%\(ref.digest)%"])
        }
        try? FileManager.default.removeItem(atPath: root + "/" + ref.digest)
        try await raw.write { db in
            try db.execute(sql: "UPDATE byte_usage SET bytes = 999999999 WHERE session = ?", arguments: [session.raw])
        }
        let r2 = try store.reconcileByteUsage()
        #expect(r2.physicalRowsRemoved >= 1, "unreferenced+missing row removed, got \(r2)")
        #expect(try store.artifactPhysicalForTesting()[ref.digest] == nil)
        let usage = try store.byteUsageForTesting()
        #expect((usage[session.raw] ?? 0) < 999999999, "overcount lowered, got \(String(describing: usage[session.raw]))")
    }

    @Test("TOOL_oldBinaryNewStore")
    func oldBinaryNewStore() async throws {
        // A newer user_version refuses to open (fail closed, no guessing).
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let seed = try GRDBSessionStore(path: path)
        try seed.close()
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "PRAGMA user_version = \(GRDBSessionStore.schemaVersion + 1)")
        }
        do {
            _ = try GRDBSessionStore(path: path)
            Issue.record("newer-schema store must refuse to open")
        } catch let error as StoreError {
            guard case .integrity(let message) = error, message.contains("future schema version") else {
                Issue.record("expected future-schema .integrity, got \(error)"); return
            }
        }
        // A v3-stamped file missing the new tables is foreign, not adopted.
        let badPath = dir.appendingPathComponent("bad.sqlite").path
        let badRaw = try DatabaseQueue(path: badPath)
        try await badRaw.write { db in
            try db.execute(sql: "CREATE TABLE records(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL, session TEXT NOT NULL DEFAULT '')")
            try db.execute(sql: "CREATE TABLE writer(session TEXT PRIMARY KEY, writer TEXT NOT NULL)")
            try db.execute(sql: "PRAGMA user_version = \(GRDBSessionStore.schemaVersion)")
        }
        do {
            _ = try GRDBSessionStore(path: badPath)
            Issue.record("v3-stamped store missing new tables must refuse to open")
        } catch let error as StoreError {
            guard case .integrity(let message) = error, message.contains("foreign or incompatible") else {
                Issue.record("expected shape .integrity, got \(error)"); return
            }
        }
    }

    @Test("TOOL_freeSpaceReserve")
    func freeSpaceReserve() async throws {
        // An unsatisfiable reserve denies publication without touching disk.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, freeSpaceReserve: Int64.max)
        defer { try? store.close() }
        let session = SessionID("s-f")
        try store.claimWriterOwnership(session: session, writer: "w")
        do {
            _ = try store.publishArtifact(session: session, as: WriterIdentity(session: session, writer: "w"), kind: "t", operationID: nil, bytes: Data("x".utf8))
            Issue.record("sub-reserve publish must be denied")
        } catch let error as StoreError {
            guard case .quotaExceeded = error else { Issue.record("expected quotaExceeded, got \(error)"); return }
        }
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        #expect(!(FileManager.default.fileExists(atPath: root)), "nothing written on reserve denial")
    }

    @Test("TOOL_noReplayAfterUncertainty")
    func noReplayAfterUncertainty() async throws {
        // A crash between rename and commit leaves bytes with no reference.
        // Reconciliation attributes the physical row but never invents a
        // reference: no session claims the bytes, no silent replay.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        let session = SessionID("s-n")
        try store.claimWriterOwnership(session: session, writer: "w")
        let ghost = Data("crash-orphan-bytes".utf8)
        let ghostDigest = Self.sha(ghost)
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try ghost.write(to: URL(fileURLWithPath: root + "/" + ghostDigest))
        _ = try store.reconcileByteUsage()
        #expect(try store.artifactPhysicalForTesting()[ghostDigest] == Int64(ghost.count))
        var cursor: UInt64 = 0
        var refs = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                if case .artifactPublished(let ref) = row.record, ref.digest == ghostDigest { refs += 1 }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        #expect(refs == 0, "reconcile must never invent a reference")
        #expect(try store.artifactRecord(session: session, digest: ghostDigest) == nil, "no session claims the orphan")
        // The store stays healthy: a normal publish still works.
        let ref = try store.publishArtifact(session: session, as: WriterIdentity(session: session, writer: "w"), kind: "t", operationID: nil, bytes: Data("live".utf8))
        #expect(try store.artifactRecord(session: session, digest: ref.digest) == Data("live".utf8))
    }

    @Test("TOOL_recoverCountsBytes")
    func recoverCountsBytes() async throws {
        // The recovery audit row counts toward byte quotas like any insert.
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let session = SessionID("s-r")
        let store = try GRDBSessionStore(path: path)
        defer { try? store.close() }
        try store.claimWriterOwnership(session: session, writer: "w-old")
        try store.append(.transcriptAppended(.user("before")), as: WriterIdentity(session: session, writer: "w-old"))
        let before = try store.byteUsageForTesting()[session.raw] ?? -1
        let auth = RecoveryAuthorization(session: session, expectedWriter: "w-old", newWriter: "w-new", operatorID: "op", reference: "t-1", reason: "test", atMillis: 1)
        try store.recoverWriterOwnership(session: session, expectedWriter: "w-old", newWriter: "w-new", authorization: auth)
        // The audit row's exact bytes must be added (recomputed independently).
        var expected = before
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                if case .writerRecovered = row.record {
                    expected += Int64(try RecordCodec.encode(row.record).count)
                }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        #expect(try store.byteUsageForTesting()[session.raw] == expected, "recovery audit bytes counted")
    }
}
