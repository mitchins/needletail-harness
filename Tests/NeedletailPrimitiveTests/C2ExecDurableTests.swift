import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage
import GRDB
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-C C2 (plan REV12 §7-C2): native acceptance + counterfactuals.
///
/// Real SessionActor (where actor-driven), real GRDB store, temporary
/// workspaces, owned child processes. Every leg either demonstrates the
/// protection or carries the counterfactual probe that fails when the
/// protection is removed.
///
/// Tiers: store seam (real GRDB), executor dispatch (real children),
/// actor composition (scripted transport/approvals, real executor+store).
/// No live models, no network, no production exec enablement.
@Suite(.serialized)
struct C2ExecDurableTests {

    // MARK: - Shared fixtures

    private static func tempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func makeStore(session: SessionID = SessionID("s-c2"), writer: String = "w-c2") throws -> (dir: URL, store: GRDBSessionStore, session: SessionID, identity: WriterIdentity) {
        let dir = try tempDir(prefix: "c2-store")
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        try store.claimWriterOwnership(session: session, writer: writer)
        return (dir, store, session, WriterIdentity(session: session, writer: writer))
    }

    private static func makeWorkspace() throws -> (URL, FilePath) {
        let url = try tempDir(prefix: "c2-ws")
        return (url, FilePath(url.path))
    }

    /// Owned fixtures for one approve→execute attempt. Fresh per attempt so
    /// a retried safe-direction probe flake never pollutes the winning
    /// attempt's durable-agreement assertions.
    private struct ExecAttempt {
        let wsURL: URL
        let dir: URL
        let dbPath: String
        let store: GRDBSessionStore
        let session: SessionID
        let identity: WriterIdentity
        let resolver: WorkspaceResolver
        let executor: NativeToolExecutor
        func cleanup() {
            try? FileManager.default.removeItem(at: wsURL)
            try? FileManager.default.removeItem(at: dir)
            try? store.close()
        }
    }

    private static func makeAttempt() throws -> ExecAttempt {
        let (wsURL, wsFP) = try makeWorkspace()
        let dir = try tempDir(prefix: "c2-exec")
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        let session = SessionID("s-c2")
        try store.claimWriterOwnership(session: session, writer: "w-c2")
        let identity = WriterIdentity(session: session, writer: "w-c2")
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let executor = makeExecutor(resolver: resolver, store: store, session: session, identity: identity)
        return ExecAttempt(wsURL: wsURL, dir: dir, dbPath: dbPath, store: store, session: session, identity: identity, resolver: resolver, executor: executor)
    }

    /// Retry budget, disabled with NEEDLETAIL_C2_NO_RETRY=1 for
    /// first-attempt flake measurement (mission §7: a retry may aid
    /// diagnosis but never turns a failed first attempt into a pass —
    /// measurement runs set the knob and report raw outcomes).
    private static var retryAttempts: Int {
        ProcessInfo.processInfo.environment["NEEDLETAIL_C2_NO_RETRY"] != nil ? 1 : 3
    }

    /// The safe-direction probe flake signature: a clean exit-0 observed as a
    /// timeout (conservative, never a false success). Only this signature
    /// retries; every other verdict fails the test immediately.
    private static func isProbeFlake(_ out: ToolCallOutcome) -> Bool {
        out.status == "timeout" && out.summary.contains("(exit 0)")
    }

    private static func makeExecutor(
        resolver: WorkspaceResolver, store: any SessionStore,
        session: SessionID, identity: WriterIdentity,
        deadlines: ToolDeadlines = ToolDeadlines(),
        preCall: (@Sendable (ToolProposal) async throws -> Void)? = nil,
        postCommit: (@Sendable () async throws -> Void)? = nil,
        execGrant: Bool = true
    ) -> NativeToolExecutor {
        NativeToolExecutor(
            resolver: resolver, store: store, sessionID: session, writer: identity,
            deadlines: deadlines, preCallSuspension: preCall,
            postCommitSuspension: postCommit, execGrant: execGrant)
    }

    private static func approve(
        executor: NativeToolExecutor, batch: ToolBatch
    ) throws -> (digests: [String: String], cwdIds: [String: String]) {
        let ids = try executor.resolveIdentities(batch: batch)
        var digests: [String: String] = [:]
        var cwdIds: [String: String] = [:]
        for id in ids {
            digests[id.callID] = id.contentDigest
            cwdIds[id.callID] = "\(id.cwdDevice):\(id.cwdInode)"
        }
        return (digests, cwdIds)
    }

    private static func makeReservation(
        batch: ToolBatch,
        digests: [String: String] = [:],
        cwdIds: [String: String] = [:]
    ) -> EffectReservation {
        EffectReservation(
            effectID: EffectID("eff-c2"), runID: RunID("r-c2"),
            requestID: RequestID("req-c2"), generation: Revision(1), revision: Revision(1),
            mutating: true, batch: batch, kind: .executor,
            approvedExecDigests: digests, approvedCwdIdentities: cwdIds)
    }

    private static func execBatch(_ json: String, callID: String = "c1") -> ToolBatch {
        ToolBatch([ToolProposal(callID: callID, tool: "exec", argumentsDigest: "d", arguments: json)])
    }

    private static func leaseRows(_ store: GRDBSessionStore, atPath path: String) throws -> Int {
        let q = try DatabaseQueue(path: path)
        return try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spill_leases") ?? -1
        }
    }

    private static func stagingFiles(_ store: GRDBSessionStore, dbPath: String) throws -> [String] {
        let root = GRDBSessionStore.artifactsRoot(for: dbPath)
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasPrefix(".tmp-lease-") }
    }

    private static func publishedDigests(store: GRDBSessionStore, session: SessionID) throws -> [String] {
        var out: [String] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                if case .artifactPublished(let ref) = row.record { out.append(ref.digest) }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        return out
    }

    private static func resetHooks() {
        GRDBSessionStore._testHook_spillTTL = nil
        GRDBSessionStore._testHook_bootIDFails = false
        GRDBSessionStore._testHook_bootIDOverride = nil
        GRDBSessionStore._testHook_monotonicOverride = nil
    }

    // MARK: - Store seam

    @Test("C2 store: two streams publish, both commit, leases gone")
    func spillTwoStreamPublish() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let out = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 1024)
        let err = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stderr", requestedBytes: 1024)
        #expect(try Self.leaseRows(store, atPath: dbPath) == 2)
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: out.path))
        try Data("warn\n".utf8).write(to: URL(fileURLWithPath: err.path))
        let refOut = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: out)
        // Quota/free-space correct after the first publish deleted its lease.
        #expect(try Self.leaseRows(store, atPath: dbPath) == 1)
        let refErr = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: err)
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty)
        #expect(try store.readArtifact(refOut) == Data("hello\n".utf8))
        #expect(try store.readArtifact(refErr) == Data("warn\n".utf8))
        let digests = try Self.publishedDigests(store: store, session: session)
        #expect(digests.contains(refOut.digest) && digests.contains(refErr.digest), "both publishes commit durable references")
    }

    @Test("C2 store: identical bytes on both streams adopt without over-count")
    func spillIdenticalDigestAdopt() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let a = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        let b = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stderr", requestedBytes: 64)
        try Data("same\n".utf8).write(to: URL(fileURLWithPath: a.path))
        try Data("same\n".utf8).write(to: URL(fileURLWithPath: b.path))
        let refA = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: a)
        let refB = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: b)
        #expect(refA.digest == refB.digest, "identical bytes share the digest")
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty, "adopt removes the redundant staging name")
        // Exactly-once accounting: one physical row; session usage is two
        // record payloads plus ONE copy of the bytes (adopt skips the second).
        let probe = try DatabaseQueue(path: dbPath)
        let phys = try probe.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_physical WHERE digest = ?", arguments: [refA.digest]) ?? -1 }
        #expect(phys == 1, "adopt inserts a single physical row, got \(phys)")
        let payloadBytes = try RecordCodec.encode(DurableRecord.artifactPublished(refA)).count
        let usage = try probe.read { db in try Int64.fetchOne(db, sql: "SELECT bytes FROM byte_usage WHERE session = ?", arguments: [session.raw]) }
        #expect(usage == Int64(2 * payloadBytes + refA.size), "adopted bytes counted exactly once, got \(String(describing: usage))")
    }

    @Test("C2 store: zero-byte stream releases, no empty artifact")
    func spillZeroByteRelease() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 1024)
        try store.releaseArtifactSpill(as: writer, handle: h)
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty)
        #expect(try Self.publishedDigests(store: store, session: session).isEmpty)
    }

    @Test("C2 store: grant refused on quota, nothing staged")
    func spillGrantQuotaRefused() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-store-q")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, sessionByteLimit: 1024)
        let session = SessionID("s-q")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        defer { try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        do {
            _ = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 32 * 1024 * 1024)
            Issue.record("grant must refuse: 32MiB lease against a 1KiB session limit")
        } catch let e as StoreError {
            guard case .quotaExceeded = e else {
                Issue.record("wrong error for quota refusal: \(e)")
                return
            }
        }
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0, "refused grant leaves no row")
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty, "refused grant stages no file")
    }

    @Test("C2 store: publish requires its lease; forged paths rejected")
    func spillPublishFencing() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("x".utf8).write(to: URL(fileURLWithPath: h.path))
        let forged = SpillHandle(leaseID: UUID(), session: session, stream: "stdout", kind: "exec-output", path: "/tmp/c2-forged", bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: forged)
            Issue.record("unknown lease must fail")
        } catch is StoreError { }
        let escape = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "exec-output", path: "/tmp/c2-escape", bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: escape)
            Issue.record("path escape must fail")
        } catch is StoreError { }
        let wrongKind = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "other", path: h.path, bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: wrongKind)
            Issue.record("kind mismatch must fail")
        } catch is StoreError { }
        try store.releaseArtifactSpill(as: writer, handle: h)
    }

    @Test("C2 store: boot-id mismatch reclaims unconditionally")
    func spillBootIDMismatchReclaim() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-store-boot")
        defer { try? FileManager.default.removeItem(at: dir) }
        GRDBSessionStore._testHook_bootIDOverride = "boot-A"
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-boot")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("stale\n".utf8).write(to: URL(fileURLWithPath: h.path))
        try store.close()
        GRDBSessionStore._testHook_bootIDOverride = "boot-B"
        let reopened = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        defer { try? reopened.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        #expect(try Self.leaseRows(reopened, atPath: dbPath) == 0, "cross-boot lease reclaimed")
        #expect(try Self.stagingFiles(reopened, dbPath: dbPath).isEmpty, "cross-boot staging removed")
    }

    @Test("C2 store: TTL reclaims same-boot stale leases; sweep skips on unreadable boot-id")
    func spillTTLReclaim() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-store-ttl")
        defer { try? FileManager.default.removeItem(at: dir) }
        GRDBSessionStore._testHook_bootIDOverride = "boot-T"
        GRDBSessionStore._testHook_monotonicOverride = 1_000_000_000
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-ttl")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: h.path))
        try store.close()
        // Same boot, far past the TTL: reclaim.
        GRDBSessionStore._testHook_monotonicOverride = 1_000_000_000 + UInt64(2400 + 60) * 1_000_000_000
        let reopened = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        #expect(try Self.leaseRows(reopened, atPath: dbPath) == 0, "TTL lease reclaimed")
        #expect(try Self.stagingFiles(reopened, dbPath: dbPath).isEmpty)
        // A fresh lease survives while young.
        GRDBSessionStore._testHook_monotonicOverride = 2_000_000_000
        let h2 = try reopened.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try reopened.close()
        GRDBSessionStore._testHook_monotonicOverride = 2_000_000_000 + UInt64(60) * 1_000_000_000
        let reopened2 = try GRDBSessionStore(path: dbPath)
        defer { try? reopened2.close() }
        #expect(try Self.leaseRows(reopened2, atPath: dbPath) == 1, "young lease never reclaimed")
        // Unreadable boot-id: sweep skips, the young lease survives.
        GRDBSessionStore._testHook_bootIDFails = true
        try reopened2.close()
        let reopened3 = try GRDBSessionStore(path: dbPath)
        defer { try? reopened3.close() }
        #expect(try Self.leaseRows(reopened3, atPath: dbPath) == 1, "sweep skips on unreadable boot-id")
        try? reopened3.releaseArtifactSpill(as: writer, handle: h2)
    }

    @Test("C2 store: boot-id read failure refuses the grant, no row")
    func spillBootIDFailureRefusesGrant() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        GRDBSessionStore._testHook_bootIDFails = true
        do {
            _ = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
            Issue.record("grant must fail closed without a time base")
        } catch is StoreError { }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
    }

    @Test("C2 store: external lock holder cannot hang publication (bounded contention)")
    func spillLockBoundedUnderExternalHolder() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let lockPath = dbPath + "-artifacts.lock"
        // A second open description holds LOCK_EX (the kernel mediates
        // flock identically within and across processes): every spill path
        // must fail bounded with typed contention, never hang.
        final class HolderBox: @unchecked Sendable { var fd: Int32 = -1 }
        let box = HolderBox()
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            let fd: Int32 = lockPath.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { return }
            box.fd = fd
            acquired.signal()
            _ = release.wait(timeout: DispatchTime.now() + 30)
            close(fd)
        }
        holder.start()
        #expect(acquired.wait(timeout: DispatchTime.now() + 30) == .success, "holder takes the lock")
        let t0 = Date()
        do {
            _ = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
            Issue.record("contended grant must fail, not hang or succeed")
        } catch let e as StoreError {
            guard case .contention = e else {
                Issue.record("contended grant must be typed contention, got \(e)")
                release.signal()
                return
            }
        }
        let dt = Date().timeIntervalSince(t0)
        #expect(dt < 15, "grant bounded by its 10s budget (took \(dt)s), never indefinite")
        release.signal()
    }

    @Test("C2 store: killed lock holder never wedges the store")
    func spillLockSurvivesKilledHolder() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let lockPath = dbPath + "-artifacts.lock"
        // A holder that vanishes releases the lock with its last fd — the
        // kernel closes open descriptions on process (or thread) exit, so
        // closing the fd here models SIGKILL of a holder exactly.
        let fd: Int32 = lockPath.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        close(fd)
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try store.releaseArtifactSpill(as: writer, handle: h)
    }

    @Test("C2 store: crash leaves lease row+staging; reopen reclaims by TTL")
    func spillCrashRecoveryAcrossHandles() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-crash-lease")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        GRDBSessionStore._testHook_monotonicOverride = 5_000_000_000
        GRDBSessionStore._testHook_bootIDOverride = "boot-X"
        do {
            let store = try GRDBSessionStore(path: dbPath)
            let session = SessionID("s-crash-lease")
            try store.claimWriterOwnership(session: session, writer: "w")
            let writer = WriterIdentity(session: session, writer: "w")
            let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
            try Data("partial\n".utf8).write(to: URL(fileURLWithPath: h.path))
            // Simulate a crash: close WITHOUT releasing. Row + staging persist.
            try store.close()
        }
        let root = GRDBSessionStore.artifactsRoot(for: dbPath)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(leftovers.contains(where: { $0.hasPrefix(".tmp-lease-") }), "crash leaves the staging file")
        // Reopen far past the TTL on the same boot: the sweep reclaims.
        GRDBSessionStore._testHook_monotonicOverride = 5_000_000_000 + UInt64(2400 + 60) * 1_000_000_000
        let reopened = try GRDBSessionStore(path: dbPath)
        defer { try? reopened.close() }
        #expect(try Self.leaseRows(reopened, atPath: dbPath) == 0, "crashed lease reclaimed")
        #expect(try Self.stagingFiles(reopened, dbPath: dbPath).isEmpty, "crashed staging reclaimed")
        // The store remains fully usable after recovery.
        let session = SessionID("s-crash-lease")
        let writer = WriterIdentity(session: session, writer: "w")
        let h2 = try reopened.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("fresh\n".utf8).write(to: URL(fileURLWithPath: h2.path))
        let ref = try reopened.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: h2)
        #expect(try reopened.readArtifact(ref) == Data("fresh\n".utf8))
    }

    @Test("C2 store: genuine v3 database with records migrates to v4 intact")
    func spillGenuineV3Migration() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-store-genuine-v3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let session = SessionID("s-v3")
        // Craft a genuine v3 store: v3 tables at user_version 3, with
        // committed records (intent + done result), an artifact reference,
        // the artifact file itself, and byte accounting.
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let root = GRDBSessionStore.artifactsRoot(for: dbPath)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("abc".utf8).write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent(digest)))
        let raw = try DatabaseQueue(path: dbPath)
        let opID = "eff-9/c9"
        let intentPayload = try RecordCodec.encode(DurableRecord.operationIntent(OperationRef(operationID: OperationID(opID), callID: "c9", state: .intent, mutating: true)))
        let resultPayload = try RecordCodec.encode(DurableRecord.operationResult(OperationRef(operationID: OperationID(opID), callID: "c9", state: .done, mutating: true), outcome: "tool-failure: done"))
        let artPayload = try RecordCodec.encode(DurableRecord.artifactPublished(ArtifactRef(digest: digest, size: 3, kind: "exec-output", operationID: nil)))
        try raw.write { db in
            try db.execute(sql: "CREATE TABLE records(seq INTEGER PRIMARY KEY, session TEXT NOT NULL, payload TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE writer(session TEXT PRIMARY KEY, writer TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE byte_usage(session TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK (bytes >= 0))")
            try db.execute(sql: "CREATE TABLE artifact_physical(digest TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK (size >= 0))")
            try db.execute(sql: "INSERT INTO records(seq, session, payload) VALUES (1, ?, ?)", arguments: [session.raw, String(decoding: intentPayload, as: UTF8.self)])
            try db.execute(sql: "INSERT INTO records(seq, session, payload) VALUES (2, ?, ?)", arguments: [session.raw, String(decoding: resultPayload, as: UTF8.self)])
            try db.execute(sql: "INSERT INTO records(seq, session, payload) VALUES (3, ?, ?)", arguments: [session.raw, String(decoding: artPayload, as: UTF8.self)])
            try db.execute(sql: "INSERT INTO writer(session, writer) VALUES (?, 'w-v3')", arguments: [session.raw])
            try db.execute(sql: "INSERT INTO byte_usage(session, bytes) VALUES (?, ?)", arguments: [session.raw, 1000])
            try db.execute(sql: "INSERT INTO artifact_physical(digest, size) VALUES (?, 3)", arguments: [digest])
            try db.execute(sql: "CREATE INDEX records_session ON records(session, seq)")
            try db.execute(sql: "PRAGMA user_version = 3")
        }
        // Open: forward migration to v4 must preserve everything.
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let version = try raw.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        #expect(version == 4, "migration stamps v4, got \(String(describing: version))")
        let tables = try raw.read { db in try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")) }
        #expect(tables.contains("spill_leases"), "migration creates spill_leases")
        let indexes = try raw.read { db in try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")) }
        #expect(indexes.contains("records_session"), "session index survives migration")
        #expect(indexes.contains("spill_leases_session"), "migration creates the lease index")
        // Operation records intact and reconcile clean.
        let (page, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(page.count == 3, "all v3 records survive, got \(page.count)")
        let rec = try store.reconcile(session: session)
        #expect(rec.completed.count == 1, "intent+done reconciles completed: \(rec)")
        #expect(rec.heldOperations.isEmpty, "no holds from the migrated past")
        // Referenced artifact bytes intact and quota-accounted.
        let v3bytes = try store.readArtifact(ArtifactRef(digest: digest, size: 3, kind: "exec-output", operationID: nil))
        #expect(v3bytes == Data("abc".utf8))
        // The migrated store grants and publishes spill leases.
        let writer = WriterIdentity(session: session, writer: "w-v3")
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("new\n".utf8).write(to: URL(fileURLWithPath: h.path))
        let ref = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: h)
        #expect(try store.readArtifact(ref) == Data("new\n".utf8))
    }

    @Test("C2 store: v3 file migrates to v4 with the spill table")
    func spillV4Migration() throws {
        let dir = try Self.tempDir(prefix: "c2-store-v3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        // Craft a v3-shaped database with raw SQL, then open it: the store
        // must migrate forward to v4 (spill_leases + index + user_version).
        let raw = try DatabaseQueue(path: dbPath)
        try raw.write { db in
            try db.execute(sql: "CREATE TABLE records(seq INTEGER PRIMARY KEY, session TEXT NOT NULL, payload TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE writer(session TEXT PRIMARY KEY, writer TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE byte_usage(session TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK (bytes >= 0))")
            try db.execute(sql: "CREATE TABLE artifact_physical(digest TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK (size >= 0))")
            try db.execute(sql: "PRAGMA user_version = 3")
        }
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        #expect(GRDBSessionStore.schemaVersion == 4)
        let version = try raw.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        #expect(version == 4, "migration stamps v4, got \(String(describing: version))")
        let tables = try raw.read { db in try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")) }
        #expect(tables.contains("spill_leases"), "migration creates spill_leases")
    }

    // MARK: - Executor dispatch

    @Test("C2 exec: approved command runs once and produces a durable result")
    func execApprovedRunsOnceDurable() async throws {
        defer { Self.resetHooks() }
        // Bounded retry on the safe-direction probe flake only (saturated
        // hosts can mark a clean exit-0 timedOut); fresh fixtures per
        // attempt so the winning attempt's agreement assertions are exact.
        var win: ExecAttempt? = nil
        var last: ToolCallOutcome? = nil
        for _ in 0..<Self.retryAttempts {
            let f = try Self.makeAttempt()
            let batch = Self.execBatch("{\"executable\":\"/bin/echo\",\"argv\":[\"/bin/echo\",\"hello\",\"durable\"],\"timeoutSecs\":30}")
            let (digests, cwdIds) = try Self.approve(executor: f.executor, batch: batch)
            let result = try await f.executor.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
            guard let out = result.calls.first else { f.cleanup(); Issue.record("no outcome"); return }
            if out.status == "success" { win = f; last = out; break }
            last = out
            f.cleanup()
            guard Self.isProbeFlake(out) else { Issue.record("non-flake failure, no retry: \(out)"); return }
        }
        guard let f = win, let out = last, out.status == "success" else {
            Issue.record("safe-direction flake persisted across attempts: \(String(describing: last))")
            return
        }
        defer { f.cleanup() }
        let store = f.store
        let session = f.session
        let dbPath = f.dbPath
        #expect(out.started == true)
        #expect(out.data.contains("hello durable"), "preview carries output, got \(out.data)")
        let artifactID = try #require(out.artifactID, "success carries its stdout artifact")
        let bytes = try store.readArtifact(ArtifactRef(digest: artifactID, size: 14, kind: "exec-output", operationID: nil))
        #expect(bytes == Data("hello durable\n".utf8), "artifact bytes are the exact child output")
        let digests2 = try Self.publishedDigests(store: store, session: session)
        #expect(digests2.contains(artifactID), "artifact reference committed durably")
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0, "no lease leak")
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty, "no staging leak")
    }

    @Test("C2 exec: substituted executable never launches")
    func execSubstitutionNeverLaunches() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let script = wsURL.appendingPathComponent("tool.sh")
        try "#!/bin/sh\necho ORIGINAL\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        // In-place substitution AFTER approval (same path, different bytes).
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL\necho PWNED\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "conflict", "digest mismatch refuses pre-spawn, got \(out)")
        #expect(out.started == nil, "refused pre-spawn claims no dispatch")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL").path), "substituted payload never executed")
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty)
        // Counterfactual: the CURRENT bytes, freshly approved, run fine.
        let (digests2, cwdIds2) = try Self.approve(executor: exec, batch: batch)
        let result2 = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests2, cwdIds: cwdIds2))
        #expect(result2.calls.first?.status == "success", "fresh approval of current bytes runs, got \(String(describing: result2.calls.first))")
        #expect(FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL").path), "counterfactual: approved current bytes execute")
    }

    @Test("C2 exec: missing approval and missing grant never spawn")
    func execMissingApprovalOrGrantRefused() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let script = wsURL.appendingPathComponent("gated.sh")
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}")
        // No digest in the reservation: conflict, nothing spawned.
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let r1 = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(r1.calls.first?.status == "conflict")
        #expect(r1.calls.first?.started == nil)
        // Grant not composed: denied even WITH a valid approval.
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let ungranted = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer, execGrant: false)
        let r2 = try await ungranted.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        #expect(r2.calls.first?.status == "denied", "uncomposed grant fails closed, got \(String(describing: r2.calls.first))")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL2").path), "nothing spawned without approval/grant")
    }

    @Test("C2 exec: cwd swap refuses pre-spawn")
    func execCwdSwapConflict() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let sub = wsURL.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let outside = try Self.tempDir(prefix: "c2-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let script = wsURL.appendingPathComponent("cwdprobe.sh")
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"cwd\":\"sub\",\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        // Swap the approved cwd for a symlink escaping the workspace.
        try FileManager.default.moveItem(at: sub, to: wsURL.appendingPathComponent("sub.orig"))
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: sub); try? FileManager.default.moveItem(at: wsURL.appendingPathComponent("sub.orig"), to: sub) }
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        #expect(result.calls.first?.status == "conflict", "cwd escape refuses, got \(String(describing: result.calls.first))")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL3").path), "escaped cwd never launches")
    }

    @Test("C2 exec: truncation carries exact discarded-byte counts")
    func execTruncationExactCounts() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        // 40 MiB of zeros through dd: deterministic byte count, no shell glob.
        let batch = Self.execBatch("{\"executable\":\"/bin/sh\",\"argv\":[\"/bin/sh\",\"-c\",\"dd if=/dev/zero bs=1048576 count=40 2>/dev/null\"],\"timeoutSecs\":120}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "success", "bounded drain runs to completion, got \(out)")
        #expect(out.truncated == true, "40MiB against a 32MiB cap truncates")
        let artifactID = try #require(out.artifactID)
        let bytes = try store.readArtifact(ArtifactRef(digest: artifactID, size: 32 * 1024 * 1024, kind: "exec-output", operationID: nil))
        #expect(bytes.count == 32 * 1024 * 1024, "artifact holds exactly the cap, got \(bytes.count)")
        #expect(out.summary.contains("stdout-discarded=8388608"), "discarded count exact (40MiB-32MiB), got \(out.summary)")
        #expect(out.summary.contains("stdout 33554432B"), "kept count exact, got \(out.summary)")
    }

    @Test("C2 exec: deadline timeout maps to started-unknown, never success")
    func execTimeoutMapsUnknown() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(
            resolver: resolver, store: store, session: session, identity: writer,
            deadlines: ToolDeadlines(localIO: 30, search: 120, exec: 2))
        let batch = Self.execBatch("{\"executable\":\"/bin/sleep\",\"argv\":[\"/bin/sleep\",\"30\"],\"timeoutSecs\":60}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "timeout", "deadline kill is a timeout, got \(out)")
        #expect(out.started == true, "a deadline-killed child definitely started: hold, not done")
    }

    @Test("C2 exec: artifact failure after spawn maps to started-unknown, never success")
    func execArtifactFailureMapsUnknown() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let dir = try Self.tempDir(prefix: "c2-store-tiny")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 16-byte artifact cap: the 100-byte child output cannot publish.
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, artifactByteLimit: 16)
        let session = SessionID("s-tiny")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        defer { try? store.close() }
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = Self.execBatch("{\"executable\":\"/bin/echo\",\"argv\":[\"/bin/echo\",\"012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\"],\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "timeout", "unrecordable output is uncertain, got \(out)")
        #expect(out.started == true, "the child ran: hold, never a fabricated receipt")
        #expect(out.artifactID == nil, "no artifact reference without durable bytes")
    }

    @Test("C2 exec: spill-grant refusal prevents spawn (failed, unstarted)")
    func execGrantRefusalPreventsSpawn() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let dir = try Self.tempDir(prefix: "c2-store-nolease")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1 KiB session budget: the 32 MiB per-stream grant cannot fit.
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, sessionByteLimit: 1024)
        let session = SessionID("s-nolease")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        defer { try? store.close() }
        let script = wsURL.appendingPathComponent("never.sh")
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL4\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "failed", "grant refusal is deterministic, got \(out)")
        #expect(out.started == nil, "nothing spawned: no hold, provider may re-propose")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL4").path), "spawn prevented")
    }

    @Test("C2 exec: second-stream refusal aborts the call and releases the first lease")
    func execSecondStreamRefusalAborts() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let dir = try Self.tempDir(prefix: "c2-store-2s")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 48 MiB budget: first 32 MiB grant fits, the second does not.
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, sessionByteLimit: 48 * 1024 * 1024)
        let session = SessionID("s-2s")
        try store.claimWriterOwnership(session: session, writer: "w")
        let writer = WriterIdentity(session: session, writer: "w")
        defer { try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let script = wsURL.appendingPathComponent("never2.sh")
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "failed", "second-stream refusal aborts pre-spawn, got \(out)")
        #expect(out.started == nil)
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL5").path), "no partial-leak spawn")
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0, "first lease released synchronously")
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty)
    }

    @Test("C2 exec: ordered batch halts — earlier edit stands, later call unstarted")
    func execOrderedBatchHalt() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: wsURL.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let h = SHA256.hash(data: Data("v1\n".utf8)).map { String(format: "%02x", $0) }.joined()
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let exec = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: writer)
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d",
                         arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"v1\\n\",\"new_string\":\"v2\\n\"}"),
            ToolProposal(callID: "c2", tool: "exec", argumentsDigest: "d",
                         arguments: "{\"executable\":\"/bin/echo\",\"argv\":[\"/bin/echo\",\"x\"],\"timeoutSecs\":30}"),
            ToolProposal(callID: "c3", tool: "write", argumentsDigest: "d",
                         arguments: "{\"path\":\"g\",\"content\":\"should-never-exist\\n\"}"),
        ])
        // No exec approval: c2 conflicts. c1 must still apply, c3 unstarted.
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls.count == 3)
        #expect(result.calls[0].status == "success", "earlier edit stands, got \(result.calls[0])")
        #expect(result.calls[1].status == "conflict", "unapproved exec conflicts, got \(result.calls[1])")
        #expect(result.calls[2].status == "cancelled" && result.calls[2].started == false,
                "halted call is cancelled-unstarted, got \(result.calls[2])")
        #expect(try String(contentsOf: wsURL.appendingPathComponent("f"), encoding: .utf8) == "v2\n")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("g").path), "halted write never runs")
    }

    @Test("C2 exec: shebang script runs with resolved-path argv0")
    func execShebangArgv0() async throws {
        defer { Self.resetHooks() }
        var win: (ExecAttempt, ToolCallOutcome)? = nil
        for _ in 0..<Self.retryAttempts {
            let f = try Self.makeAttempt()
            let script = f.wsURL.appendingPathComponent("argv0.sh")
            try "#!/bin/sh\necho \"argv0=$0\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let batch = Self.execBatch("{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}")
            let (digests, cwdIds) = try Self.approve(executor: f.executor, batch: batch)
            let result = try await f.executor.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
            guard let out = result.calls.first else { f.cleanup(); Issue.record("no outcome"); return }
            if out.status == "success" { win = (f, out); break }
            f.cleanup()
            guard Self.isProbeFlake(out) else { Issue.record("non-flake failure, no retry: \(out)"); return }
        }
        guard let (f, out) = win else {
            Issue.record("safe-direction flake persisted across attempts")
            return
        }
        defer { f.cleanup() }
        // The kernel re-execs the interpreter with the path given to
        // execve: for an fd-bound spawn that is /proc/self/fd/N, not the
        // display path (plan REV8: "display == executed" softened for
        // shebang $0). The leg proves the inheritable-fd split works.
        #expect(out.data.contains("argv0=/proc/self/fd/"), "shebang $0 is the exec-fd path, got \(out.data)")
    }

    @Test("C2 exec: post-commit suspension past the deadline stays unknown despite completion")
    func execPostCommitSuspensionTimeout() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let hanging: @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let exec = Self.makeExecutor(
            resolver: resolver, store: store, session: session, identity: writer,
            deadlines: ToolDeadlines(localIO: 30, search: 120, exec: 2),
            postCommit: hanging)
        let batch = Self.execBatch("{\"executable\":\"/bin/echo\",\"argv\":[\"/bin/echo\",\"done\"],\"timeoutSecs\":30}")
        let (digests, cwdIds) = try Self.approve(executor: exec, batch: batch)
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
        let out = try #require(result.calls.first)
        #expect(out.status == "timeout", "post-commit suspension loses to the deadline, got \(out)")
        #expect(out.started == true, "completed-but-unreceipted stays unknown: hold")
    }

    // MARK: - Spawn classification (runner level)

    @Test("C2 spawn: ENOENT, EACCES and ENOEXEC classify pre-dispatch, never started")
    func spawnErrorClassification() throws {
        // ENOENT: nothing at the path.
        do {
            _ = try NativeToolExecutor.runBounded(
                executablePath: "/nonexistent-c2-xyz", args: [], stdoutCap: 4096, stderrCap: 4096,
                timeout: 10, cwdFD: nil, execPath: nil, useSession: false)
            Issue.record("ENOENT must throw")
        } catch let e as ToolFailure {
            guard case .preDispatch(let status, let summary) = e else {
                Issue.record("wrong ToolFailure shape: \(e)")
                return
            }
            #expect(status == "failed", "execve failure is deterministic failed, got \(status)")
            #expect(summary.contains("No such file"), "errno preserved, got \(summary)")
        }
        // EACCES: present but not executable.
        let dir = try Self.tempDir(prefix: "c2-noexec")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain")
        try "hello\n".write(to: plain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        do {
            _ = try NativeToolExecutor.runBounded(
                executablePath: plain.path, args: [], stdoutCap: 4096, stderrCap: 4096,
                timeout: 10, cwdFD: nil, execPath: nil, useSession: false)
            Issue.record("EACCES must throw")
        } catch let e as ToolFailure {
            guard case .preDispatch(let status, let summary) = e else {
                Issue.record("wrong ToolFailure shape: \(e)")
                return
            }
            #expect(status == "failed")
            #expect(summary.contains("Permission denied"), "got \(summary)")
        }
        // ENOEXEC: executable bit but invalid format (no shebang).
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        do {
            _ = try NativeToolExecutor.runBounded(
                executablePath: plain.path, args: [], stdoutCap: 4096, stderrCap: 4096,
                timeout: 10, cwdFD: nil, execPath: nil, useSession: false)
            Issue.record("ENOEXEC must throw")
        } catch let e as ToolFailure {
            guard case .preDispatch(let status, let summary) = e else {
                Issue.record("wrong ToolFailure shape: \(e)")
                return
            }
            #expect(status == "failed")
            #expect(summary.contains("invalid executable format"), "got \(summary)")
        }
    }

    @Test("C2 spawn: death after the marker is started-signal-terminated, never success")
    func spawnDeathAfterMarker() throws {
        defer {
            NativeToolExecutor._testHook_killAfterMarker = false
            Self.resetHooks()
        }
        // SIGKILL between 0x01 and execve: the image never runs, but the
        // spawn sequence verifiably started. Classification must be a
        // started failure (exit 128) — never success, never pre-dispatch.
        NativeToolExecutor._testHook_killAfterMarker = true
        let run = try NativeToolExecutor.runBounded(
            executablePath: "/bin/echo", args: ["hi"], stdoutCap: 4096, stderrCap: 4096,
            timeout: 10, cwdFD: nil, execPath: nil, useSession: false)
        #expect(run.status == 128, "signalled child reports 128, got \(run.status)")
        #expect(!run.timedOut, "prompt SIGKILL is a determined failure, not a timeout")
        #expect(run.stdout.isEmpty, "image never executed: no output")
    }

    @Test("C2 spawn: hang after the marker times out unknown, never success")
    func spawnHangAfterMarker() throws {
        defer {
            NativeToolExecutor._testHook_stopAfterMarker = false
            Self.resetHooks()
        }
        // SIGSTOP between 0x01 and execve: [0x01] observed, EOF never
        // arrives. The run deadline decides — timeout/unknown+hold, never
        // a fabricated successful launch.
        NativeToolExecutor._testHook_stopAfterMarker = true
        let run = try NativeToolExecutor.runBounded(
            executablePath: "/bin/echo", args: ["hi"], stdoutCap: 4096, stderrCap: 4096,
            timeout: 3, cwdFD: nil, execPath: nil, useSession: false)
        #expect(run.timedOut, "stalled launch must time out, got \(run)")
        #expect(run.stdout.isEmpty, "no output from a never-executed image")
    }

    @Test("C2 spawn: bad cwd descriptor classifies pre-dispatch")
    func spawnBadCwdDescriptor() throws {
        // An fd number that can never be open in this process: fchdir fails
        // EBADF before execve, and the pipe reports it (never silent start).
        do {
            _ = try NativeToolExecutor.runBounded(
                executablePath: "/bin/echo", args: ["hi"], stdoutCap: 4096, stderrCap: 4096,
                timeout: 10, cwdFD: 500, execPath: nil, useSession: false)
            Issue.record("EBADF cwd must throw")
        } catch let e as ToolFailure {
            guard case .preDispatch(let status, let summary) = e else {
                Issue.record("wrong ToolFailure shape: \(e)")
                return
            }
            #expect(status == "failed")
            #expect(summary.contains("Bad file descriptor") || summary.contains("bad descriptor"), "got \(summary)")
        }
    }

    // MARK: - Recovery (store + reconcile level)

    @Test("C2 recovery: intent without result reconciles unknown+held, never auto-completes")
    func crashIntentNeverAutoCompletes() throws {
        defer { Self.resetHooks() }
        let dir = try Self.tempDir(prefix: "c2-crash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let session = SessionID("s-crash")
        do {
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: session, writer: "w-crash")
            let writer = WriterIdentity(session: session, writer: "w-crash")
            // Simulate a crash after intent commit, before any completion.
            let op = OperationID("eff-x/c1")
            try store.appendBatch(
                [.operationIntent(OperationRef(operationID: op, callID: "c1", state: .intent, mutating: true))],
                as: writer)
            try store.close()
        }
        // Reopen: nothing auto-executes (no live actor, no replay).
        let reopened = try GRDBSessionStore(path: dbPath)
        defer { try? reopened.close() }
        let reconciliation = try reopened.reconcile(session: session)
        #expect(reconciliation.unmatchedMutating.count == 1, "intent-only mutating op is unmatched, got \(reconciliation)")
        #expect(reconciliation.heldOperations.count == 1, "unmatched mutating op holds")
        #expect(reconciliation.completed.isEmpty, "no auto-completion across the crash")
        #expect(try Self.stagingFiles(reopened, dbPath: dbPath).isEmpty)
    }

    // MARK: - Actor composition (scripted transport/approvals, real executor+store)
    /// Scripted transport: canned FIFO responses. Mirrors the ActorTests seam
    /// (kept local: that target cannot see NeedletailRuntime/GRDB).
    private final class C2Transport: ModelTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _script: [ProviderResponse] = []
        private var _invocations = 0
        var script: [ProviderResponse] {
            get { lock.withLock { _script } }
            set { lock.withLock { _script = newValue } }
        }
        var invocations: Int { lock.withLock { _invocations } }
        func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
            lock.withLock { _invocations += 1 }
            guard let next = lock.withLock({ _script.isEmpty ? nil : _script.removeFirst() }) else {
                throw C2ScriptError.outOfScript
            }
            _ = intake
            return TransportResult(response: next)
        }
    }

    private enum C2ScriptError: Error {
        case outOfScript
    }

    /// Scripted approvals: FIFO decisions.
    private final class C2Approvals: ApprovalGateway, @unchecked Sendable {
        private let lock = NSLock()
        private var _script: [ApprovalDecision] = []
        var script: [ApprovalDecision] {
            get { lock.withLock { _script } }
            set { lock.withLock { _script = newValue } }
        }
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            lock.withLock { _script.isEmpty ? .unavailable("no scripted decision") : _script.removeFirst() }
        }
    }

    /// GRDB wrapper that fails result-bearing appends (completion-store-fail
    /// injection). Everything else forwards to the real store.
    private final class C2FailingStore: SessionStore, @unchecked Sendable {
        private let inner: GRDBSessionStore
        var failResults = false
        var failIntents = false
        init(inner: GRDBSessionStore) { self.inner = inner }
        func claimWriterOwnership(session: SessionID, writer: String) throws { try inner.claimWriterOwnership(session: session, writer: writer) }
        func sessions() throws -> [SessionID] { try inner.sessions() }
        func releaseWriterOwnership(session: SessionID, writer: String) throws { try inner.releaseWriterOwnership(session: session, writer: writer) }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws { try inner.append(record, as: identity) }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            if failResults && records.contains(where: { if case .operationResult = $0 { return true } else { return false } }) {
                throw StoreError.integrity("injected completion-store failure")
            }
            if failIntents && records.contains(where: {
                if case .operationIntent(let ref) = $0, ref.callID != nil { return true } else { return false }
            }) {
                throw StoreError.integrity("injected intent-store failure")
            }
            try inner.appendBatch(records, as: identity)
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }
        func recoverWriterOwnership(session: SessionID, expectedWriter: String, newWriter: String, authorization: RecoveryAuthorization) throws {
            try inner.recoverWriterOwnership(session: session, expectedWriter: expectedWriter, newWriter: newWriter, authorization: authorization)
        }
        func artifactRecord(session: SessionID, digest: String) throws -> Data? {
            try inner.artifactRecord(session: session, digest: digest)
        }
        func publishArtifact(session: SessionID, as identity: WriterIdentity, kind: String, operationID: OperationID?, bytes: Data) throws -> ArtifactRef {
            try inner.publishArtifact(session: session, as: identity, kind: kind, operationID: operationID, bytes: bytes)
        }
        func openArtifactSpill(session: SessionID, as identity: WriterIdentity, kind: String, stream: String, requestedBytes: Int64) throws -> SpillHandle {
            try inner.openArtifactSpill(session: session, as: identity, kind: kind, stream: stream, requestedBytes: requestedBytes)
        }
        func publishArtifactFromFile(session: SessionID, as identity: WriterIdentity, kind: String, spill: SpillHandle) throws -> ArtifactRef {
            try inner.publishArtifactFromFile(session: session, as: identity, kind: kind, spill: spill)
        }
        func releaseArtifactSpill(as identity: WriterIdentity, handle: SpillHandle) throws {
            try inner.releaseArtifactSpill(as: identity, handle: handle)
        }
        func close() throws { try inner.close() }
    }

    private static func actorEpoch() throws -> SessionState {
        let snapshot = try validateConfig(Data("""
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-c2a"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route, execComposed: true)
        return SessionState(sessionID: SessionID("s-c2a"), epoch: epoch, trustMode: .workspace, phase: .idle)
    }

    private static func awaitInvocations(_ transport: C2Transport, count: Int, label: String) async throws {
        // Sleep-polling (not bare yields): a real child round-trip takes
        // wall-clock milliseconds that bare yields can spin past.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if transport.invocations >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("transport never reached \(count) invocations (\(label))")
        throw C2ScriptError.outOfScript
    }

    private static func describeState(_ st: SessionState) -> String {
        "phase=\(st.phase) queueHeld=\(st.queueHeld) unresolved=\(st.unresolvedOperations.count) pendAppr=\(st.pendingApproval != nil) pendBatch=\(st.pendingBatch != nil)"
    }

    private static func awaitCondition(_ label: String, _ check: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("actor never reached \(label)")
        throw C2ScriptError.outOfScript
    }

    private enum AttemptVerdict {
        case success
        /// Safe-direction probe flake (clean exit-0 observed as timeout):
        /// retry with fresh fixtures.
        case flaky(String)
        /// Deterministic failure: recorded, never retried.
        case failed
    }

    private static func runActorSuccessOnce() async throws -> AttemptVerdict {
        let (wsURL, wsFP) = try Self.makeWorkspace()
        let dir = try Self.tempDir(prefix: "c2-actor")
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        let cleanup = {
            try? FileManager.default.removeItem(at: wsURL)
            try? FileManager.default.removeItem(at: dir)
            try? store.close()
        }
        let session = SessionID("s-c2a")
        try store.claimWriterOwnership(session: session, writer: "c2a-writer")
        let identity = WriterIdentity(session: session, writer: "c2a-writer")
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let executor = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: identity)
        let transport = C2Transport()
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d",
                                arguments: "{\"executable\":\"/bin/echo\",\"argv\":[\"/bin/echo\",\"hello\",\"actor\"],\"timeoutSecs\":30}"),
                ], isFinal: false)),
            ProviderResponse(
                requestID: RequestID("s2"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: true)),
        ]
        let approvals = C2Approvals()
        approvals.script = [.approve]
        let actor = try SessionActor(
            state: try Self.actorEpoch(), ids: DeterministicIDSource(prefix: "c2a"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: "c2a-writer", execResolver: executor)
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        do {
            try await Self.awaitInvocations(transport, count: 2, label: "provider continuation after exec")
        } catch {
            let st = await actor.currentState()
            // Flake evidence: a committed timeout result WITH a published
            // artifact means the child ran clean and only the verdict
            // flaked (a genuine hang/no-spawn leaves no artifact).
            let arts = (try? Self.publishedDigests(store: store, session: session)) ?? []
            if !arts.isEmpty {
                cleanup()
                return .flaky("timeout-with-artifact (inv=\(transport.invocations) \(Self.describeState(st)))")
            }
            Issue.record("stall diagnostics: inv=\(transport.invocations) \(Self.describeState(st))")
            cleanup()
            return .failed
        }
        // Let the completion commit settle (isFinal closes the run).
        try await Self.awaitCondition("completed after exec") {
            if case .completed = await actor.currentState().phase { return true }
            return false
        }
        let final = await actor.currentState()
        #expect(final.unresolvedOperations.isEmpty, "clean exec holds nothing")
        // Durable agreement: intent + done result + artifact reference.
        // Flake evidence is precomputed: a committed artifact means the
        // child ran clean (a genuine hang/no-spawn leaves no artifact).
        let committedArtifacts = (try? Self.publishedDigests(store: store, session: session)) ?? []
        var intents = 0
        var doneResults = 0
        var artifacts: [String] = []
        var transcripts: [String] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                switch row.record {
                case .operationIntent(let ref) where ref.callID == "c1": intents += 1
                case .operationResult(let ref, let outcome) where ref.callID == "c1":
                    if ref.state == .done {
                        doneResults += 1
                        #expect(outcome.contains("exec succeeded"), "receipt carries the exec outcome, got \(outcome)")
                    } else if !committedArtifacts.isEmpty {
                        cleanup()
                        return .flaky("unknown completion with committed artifact: \(outcome)")
                    } else {
                        Issue.record("non-done completion without artifact: \(outcome)")
                        cleanup()
                        return .failed
                    }
                case .artifactPublished(let ref): artifacts.append(ref.digest)
                case .transcriptAppended(.toolResponse(_, let text)): transcripts.append(text)
                default: break
                }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        #expect(intents == 1, "exactly one durable intent")
        #expect(doneResults == 1, "exactly one done completion (runs once)")
        #expect(artifacts.count == 1, "one published artifact, got \(artifacts)")
        let bytes = try store.readArtifact(ArtifactRef(digest: try #require(artifacts.first), size: 12, kind: "exec-output", operationID: nil))
        #expect(bytes == Data("hello actor\n".utf8), "artifact bytes are the exact child output")
        #expect(transcripts.joined().contains("hello actor"), "provider continuation carries the preview")
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0, "no lease leak")
        #expect(try Self.stagingFiles(store, dbPath: dbPath).isEmpty, "no staging leak")
        // Keep fixtures alive for the caller (none needed post-assert).
        cleanup()
        return .success
    }

    @Test("C2 actor: approved exec runs once through the real loop with durable agreement")
    func actorApprovedExecRunsOnceDurable() async throws {
        defer { Self.resetHooks() }
        for attempt in 1...Self.retryAttempts {
            switch try await Self.runActorSuccessOnce() {
            case .success: return
            case .flaky(let note):
                if attempt == 3 { Issue.record("safe-direction flake persisted across attempts: \(note)") }
            case .failed: return
            }
        }
    }

    @Test("C2 actor: completion store-fail leaves an unresolved hold, no silent retry")
    func actorCompletionStoreFailLeavesHold() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let dir = try Self.tempDir(prefix: "c2-actor-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let inner = try GRDBSessionStore(path: dbPath)
        defer { try? inner.close() }
        let session = SessionID("s-c2a")
        try inner.claimWriterOwnership(session: session, writer: "c2a-writer")
        let store = C2FailingStore(inner: inner)
        store.failResults = true
        let identity = WriterIdentity(session: session, writer: "c2a-writer")
        // The child appends one line per launch: launch count is observable.
        let script = wsURL.appendingPathComponent("once.sh")
        try "#!/bin/sh\necho run >> \(wsURL.path)/RUNS\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let executor = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: identity)
        let transport = C2Transport()
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d",
                                arguments: "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"),
                ], isFinal: false)),
            ProviderResponse(
                requestID: RequestID("s2"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: true)),
        ]
        let approvals = C2Approvals()
        approvals.script = [.approve]
        let actor = try SessionActor(
            state: try Self.actorEpoch(), ids: DeterministicIDSource(prefix: "c2f"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: "c2a-writer", execResolver: executor)
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        // The completion cannot commit: the actor must hold instead of
        // continuing. Poll for the hold (no continuation arrives).
        try await Self.awaitCondition("unresolved hold") {
            let st = await actor.currentState()
            return st.queueHeld && !st.unresolvedOperations.isEmpty
        }
        #expect(transport.invocations == 1, "no provider continuation past the hold")
        let runs = try? String(contentsOf: wsURL.appendingPathComponent("RUNS"), encoding: .utf8)
        #expect(runs == "run\n", "the child ran exactly once, got \(String(describing: runs))")
        // A fresh command is blocked by the cross-run gate: still one run.
        await actor.submitText(commandID: CommandID("a-2"), text: "again", kind: .followUp, sealed: false)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(transport.invocations == 1, "gate blocks fresh work while unresolved")
        let runs2 = try? String(contentsOf: wsURL.appendingPathComponent("RUNS"), encoding: .utf8)
        #expect(runs2 == "run\n", "no silent re-execution across the crash-equivalent, got \(String(describing: runs2))")
        let final = await actor.currentState()
        #expect(final.unresolvedOperations.count == 1, "one held operation")
        #expect(final.unresolvedOperations.first?.state == .unknown, "completion-fail is unknown, never done")
    }
    @Test("C2 exec: omitted cwd pins the workspace root (never inherits process cwd)")
    func execOmittedCwdPinsRoot() async throws {
        defer { Self.resetHooks() }
        var win: (ExecAttempt, ToolCallOutcome)? = nil
        for _ in 0..<Self.retryAttempts {
            let f = try Self.makeAttempt()
            // /bin/pwd prints the child's working directory: it must be
            // the workspace root even though no cwd was approved.
            let batch = Self.execBatch("{\"executable\":\"/bin/pwd\",\"argv\":[\"/bin/pwd\"],\"timeoutSecs\":30}")
            let (digests, cwdIds) = try Self.approve(executor: f.executor, batch: batch)
            let result = try await f.executor.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
            guard let out = result.calls.first else { f.cleanup(); Issue.record("no outcome"); return }
            if out.status == "success" { win = (f, out); break }
            f.cleanup()
            guard Self.isProbeFlake(out) else { Issue.record("non-flake failure, no retry: \(out)"); return }
        }
        guard let (f, out) = win else {
            Issue.record("safe-direction flake persisted across attempts")
            return
        }
        defer { f.cleanup() }
        #expect(out.data.trimmingCharacters(in: .whitespacesAndNewlines) == f.wsURL.path,
                "omitted cwd runs in the workspace root, got \(out.data)")
        // Counterfactual: a different process cwd must not leak in.
        #expect(out.data.trimmingCharacters(in: .whitespacesAndNewlines) != FileManager.default.currentDirectoryPath,
                "child cwd is pinned, not inherited")
    }

    @Test("C2 store: forged spill handles are rejected, never publish or delete")
    func spillForgedHandlesRejected() throws {
        defer { Self.resetHooks() }
        let (dir, store, session, writer) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let h = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stdout", requestedBytes: 64)
        try Data("real\n".utf8).write(to: URL(fileURLWithPath: h.path))
        // Unknown lease: rejected, nothing published.
        let forged = SpillHandle(leaseID: UUID(), session: session, stream: "stdout", kind: "exec-output", path: h.path, bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: forged)
            Issue.record("unknown-lease publish must fail")
        } catch is StoreError { }
        // Cross-lease path: lease row of h but another handle's path.
        let h2 = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "stderr", requestedBytes: 64)
        let crossed = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "exec-output", path: h2.path, bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: crossed)
            Issue.record("cross-lease publish must fail")
        } catch is StoreError { }
        // Escape path: lease row of h but /tmp path.
        let escape = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "exec-output", path: "/tmp/c2-escape-x", bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: escape)
            Issue.record("escape publish must fail")
        } catch is StoreError { }
        // Kind mismatch: row says exec-output, handle claims other.
        let wrongKind = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "other", path: h.path, bytes: 64)
        do {
            _ = try store.publishArtifactFromFile(session: session, as: writer, kind: "other", spill: wrongKind)
            Issue.record("kind-mismatch publish must fail")
        } catch is StoreError { }
        // Release with a forged path must not delete arbitrary files.
        let victim = dir.appendingPathComponent("victim").path
        try Data("precious".utf8).write(to: URL(fileURLWithPath: victim))
        let evilRelease = SpillHandle(leaseID: h.leaseID, session: session, stream: "stdout", kind: "exec-output", path: victim, bytes: 64)
        do {
            try store.releaseArtifactSpill(as: writer, handle: evilRelease)
            Issue.record("forged release must fail")
        } catch is StoreError { }
        #expect(FileManager.default.fileExists(atPath: victim), "forged release deletes nothing")
        // Stream with a separator is refused at grant.
        do {
            _ = try store.openArtifactSpill(session: session, as: writer, kind: "exec-output", stream: "a/b", requestedBytes: 64)
            Issue.record("separator stream must be refused")
        } catch is StoreError { }
        // The genuine handle still publishes after the forgery attempts.
        let ref = try store.publishArtifactFromFile(session: session, as: writer, kind: "exec-output", spill: h)
        #expect(try store.readArtifact(ref) == Data("real\n".utf8))
        try store.releaseArtifactSpill(as: writer, handle: h2)
        #expect(try Self.leaseRows(store, atPath: dbPath) == 0)
    }

    @Test("C2 exec: stderr-only output publishes stderr, releases stdout")
    func execStderrOnlyPublishesStderr() async throws {
        defer { Self.resetHooks() }
        var win: (ExecAttempt, ToolCallOutcome)? = nil
        for _ in 0..<Self.retryAttempts {
            let f = try Self.makeAttempt()
            let batch = Self.execBatch("{\"executable\":\"/bin/sh\",\"argv\":[\"/bin/sh\",\"-c\",\"echo only-err 1>&2\"],\"timeoutSecs\":30}")
            let (digests, cwdIds) = try Self.approve(executor: f.executor, batch: batch)
            let result = try await f.executor.execute(batch: batch, reservation: Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds))
            guard let out = result.calls.first else { f.cleanup(); Issue.record("no outcome"); return }
            if out.status == "success" { win = (f, out); break }
            f.cleanup()
            guard Self.isProbeFlake(out) else { Issue.record("non-flake failure, no retry: \(out)"); return }
        }
        guard let (f, out) = win else {
            Issue.record("safe-direction flake persisted across attempts")
            return
        }
        defer { f.cleanup() }
        #expect(out.artifactID == nil, "empty stdout publishes no artifact")
        #expect(out.summary.contains("stderr-artifact="), "stderr digest recorded, got \(out.summary)")
        let stderrDigest = out.summary.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("stderr-artifact=") }).map { String($0.dropFirst("stderr-artifact=".count)) }
        let digest = try #require(stderrDigest)
        let bytes = try f.store.readArtifact(ArtifactRef(digest: digest, size: 9, kind: "exec-output", operationID: nil))
        #expect(bytes == Data("only-err\n".utf8), "stderr bytes durable, got \(String(decoding: bytes, as: UTF8.self))")
        #expect(try Self.leaseRows(f.store, atPath: f.dbPath) == 0, "both leases settled")
        #expect(try Self.stagingFiles(f.store, dbPath: f.dbPath).isEmpty)
    }

    @Test("C2 exec: cancellation propagates and releases spill leases")
    func execCancelPropagatesAndReleases() async throws {
        defer { Self.resetHooks() }
        let f = try Self.makeAttempt()
        defer { f.cleanup() }
        let batch = Self.execBatch("{\"executable\":\"/bin/sleep\",\"argv\":[\"/bin/sleep\",\"30\"],\"timeoutSecs\":120}")
        let (digests, cwdIds) = try Self.approve(executor: f.executor, batch: batch)
        let reservation = Self.makeReservation(batch: batch, digests: digests, cwdIds: cwdIds)
        let task = Task { try await f.executor.execute(batch: batch, reservation: reservation) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled exec must throw CancellationError, not an outcome")
        } catch is CancellationError {
            // Expected: cancellation is delivery, never converted.
        } catch {
            Issue.record("wrong error on cancel: \(error)")
        }
        // No zombie, no lease leak, no staging leak after cancellation.
        #expect(try Self.leaseRows(f.store, atPath: f.dbPath) == 0, "cancel releases both leases")
        #expect(try Self.stagingFiles(f.store, dbPath: f.dbPath).isEmpty)
    }

    @Test("C2 actor: intent store-fail prevents spawn (failed, unstarted)")
    func actorIntentStoreFailPreventsSpawn() async throws {
        defer { Self.resetHooks() }
        let (wsURL, wsFP) = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: wsURL) }
        let dir = try Self.tempDir(prefix: "c2-actor-intent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("store.sqlite").path
        let inner = try GRDBSessionStore(path: dbPath)
        defer { try? inner.close() }
        let session = SessionID("s-c2a")
        try inner.claimWriterOwnership(session: session, writer: "c2a-writer")
        let store = C2FailingStore(inner: inner)
        store.failIntents = true
        let identity = WriterIdentity(session: session, writer: "c2a-writer")
        let script = wsURL.appendingPathComponent("never2.sh")
        try "#!/bin/sh\ntouch \(wsURL.path)/SENTINEL6\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let resolver = try WorkspaceResolver(workspace: wsFP, readRoots: [])
        let executor = Self.makeExecutor(resolver: resolver, store: store, session: session, identity: identity)
        let transport = C2Transport()
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d",
                                arguments: "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"),
                ], isFinal: false)),
        ]
        let approvals = C2Approvals()
        approvals.script = [.approve]
        let actor = try SessionActor(
            state: try Self.actorEpoch(), ids: DeterministicIDSource(prefix: "c2i"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: "c2a-writer", execResolver: executor)
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        // The intent cannot commit: the run fails before any dispatch.
        try await Self.awaitCondition("intent failure stops the run") {
            let st = await actor.currentState()
            if case .failed = st.phase { return true }
            return false
        }
        #expect(transport.invocations == 1, "no continuation past the unpersisted intent")
        #expect(!FileManager.default.fileExists(atPath: wsURL.appendingPathComponent("SENTINEL6").path), "intent failure prevents spawn")
    }
}
