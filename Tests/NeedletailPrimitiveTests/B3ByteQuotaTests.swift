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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B3-B: artifact durability + byte quotas. Real GRDB stores, real files.
/// Quota math is byte-exact (UTF-8 bytes, never characters); every evidence
/// leg pins committed state via fresh handles or the read-only test
/// inspectors — never internal counters alone.
struct B3ByteQuotaTests {
    private static func tempDir(_ prefix: String = "b3q") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func freshStore(sessionByteLimit: Int64? = nil, globalByteLimit: Int64? = nil, freeSpaceReserve: Int64? = nil) throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = try Self.tempDir()
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path, sessionByteLimit: sessionByteLimit ?? GRDBSessionStore.defaultSessionByteLimit, globalByteLimit: globalByteLimit ?? GRDBSessionStore.defaultGlobalByteLimit, freeSpaceReserve: freeSpaceReserve ?? GRDBSessionStore.defaultFreeSpaceReserve)
        let session = SessionID("s-q")
        let writer = WriterIdentity(session: session, writer: "w")
        try store.claimWriterOwnership(session: session, writer: "w")
        return (dir, store, session, writer)
    }

    private static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func refPayloadBytes(digest: String, size: Int, kind: String = "t") throws -> Int {
        let ref = ArtifactRef(digest: digest, size: size, kind: kind, operationID: nil)
        return try RecordCodec.encode(DurableRecord.artifactPublished(ref)).count
    }

    private static func referencedDigests(store: GRDBSessionStore, session: SessionID) throws -> Set<String> {
        var out = Set<String>()
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                if case .artifactPublished(let ref) = row.record { out.insert(ref.digest) }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        return out
    }

    // MARK: - Quota accounting

    private static func makeReservation(batch: ToolBatch, approved: [String] = []) -> EffectReservation {
        EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: approved)
    }

    @Test("TOOL_approvalTwin")
    func approvalTwin() async throws {
        // NFC vs NFD twin: approving one must not authorize the other.
        #expect(ToolValidator.isApprovedPath(".env.\u{00E9}", approvedPaths: [".env.\u{00E9}"]) == true)
        #expect(ToolValidator.isApprovedPath(".env.e\u{0301}", approvedPaths: [".env.\u{00E9}"]) == false, "canonically equal but byte-distinct paths must not match")
        #expect(ToolValidator.isApprovedPrefix("sub/x", approvedPaths: ["sub"]) == true)
        #expect(ToolValidator.isApprovedPrefix(".env/x", approvedPaths: [".env.\u{00E9}"]) == false)
        #expect(ToolValidator.isApprovedPrefix("d\u{00E9}/f", approvedPaths: ["d\u{00E9}"]) == true)
        #expect(ToolValidator.isApprovedPrefix("de\u{0301}/f", approvedPaths: ["d\u{00E9}"]) == false, "NFD path must not match NFC grant")
        #expect(ToolValidator.dedupeByteDistinct(["a", ".env.\u{00E9}", ".env.e\u{0301}", "a"]).count == 3)
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let nfc = ".env.\u{00E9}"
        let nfd = ".env.e\u{0301}"
        let exec = NativeToolExecutor(resolver: try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: []), store: store, sessionID: session, writer: writer, rgPath: nil)
        let wb = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"" + nfc + "\",\"content\":\"x\\n\"}")])
        let resA = try await exec.execute(batch: wb, reservation: Self.makeReservation(batch: wb, approved: [nfc]))
        #expect(resA.calls[0].status == "success", "approved NFC form writes, got \(resA.calls[0])")
        let wb2 = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"" + nfd + "\",\"content\":\"x\\n\"}")])
        let resB = try await exec.execute(batch: wb2, reservation: Self.makeReservation(batch: wb2, approved: [nfc]))
        #expect(resB.calls[0].status == "denied", "unlisted NFD twin must stay denied, got \(resB.calls[0])")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(nfd).path), "twin file must not be created")
    }

    @Test("TOOL_quotaAppendCountsUtf8Bytes")
    func quotaAppendCountsUtf8Bytes() async throws {
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        // "😀" is 1 scalar but 4 UTF-8 bytes; quotas must count bytes.
        try store.append(.transcriptAppended(.user("hi")), as: writer)
        try store.append(.transcriptAppended(.user("😀")), as: writer)
        let usage = try store.byteUsageForTesting()
        var expected = 0
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                let bytes = try RecordCodec.encode(row.record)
                expected += bytes.count
                #expect(bytes.count >= String(decoding: bytes, as: UTF8.self).count, "byte count must exceed char count for non-ASCII")
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        #expect(usage[session.raw] == Int64(expected), "byte_usage must equal exact UTF-8 record bytes, got \(String(describing: usage[session.raw])) vs \(expected)")
        #expect(expected > "hi😀".count, "sanity: bytes exceed scalars here")
    }

    @Test("TOOL_quotaPreflightFailsFast")
    func quotaPreflightFailsFast() async throws {
        // Bytes over the session limit fail BEFORE any tmp file exists.
        let (dir, store, session, writer) = try Self.freshStore(sessionByteLimit: 100)
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let big = Data(repeating: 0x41, count: 200)
        do {
            _ = try store.publishArtifact(session: session, as: writer, kind: "t", operationID: nil, bytes: big)
            Issue.record("over-quota publish must fail")
        } catch let e as StoreError {
            guard case .quotaExceeded = e else { Issue.record("expected quotaExceeded, got \(e)"); return }
        }
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(leftovers.filter { $0.hasPrefix(".tmp-") }.isEmpty, "no tmp on preflight failure")
        #expect(try Self.referencedDigests(store: store, session: session).isEmpty, "no reference committed")
        #expect(try store.artifactPhysicalForTesting().isEmpty, "no physical row committed")
    }

    @Test("TOOL_quotaAuthoritativeAtCommit")
    func quotaAuthoritativeAtCommit() async throws {
        // Preflight under-counts the reference row on purpose; the in-txn
        // authoritative check fails deterministically and cleans up.
        let bytes = Data(repeating: 0x42, count: 60)
        let digest = Self.sha(bytes)
        let refLen = try Self.refPayloadBytes(digest: digest, size: bytes.count)
        let limit = Int64(bytes.count) + Int64(refLen) - 1
        let (dir, store, session, writer) = try Self.freshStore(sessionByteLimit: limit)
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        do {
            _ = try store.publishArtifact(session: session, as: writer, kind: "t", operationID: nil, bytes: bytes)
            Issue.record("authoritative over-quota publish must fail")
        } catch let e as StoreError {
            guard case .quotaExceeded = e else { Issue.record("expected quotaExceeded, got \(e)"); return }
        }
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(leftovers.isEmpty, "tmp cleaned and nothing renamed, found \(leftovers)")
        #expect(try Self.referencedDigests(store: store, session: session).isEmpty, "no reference committed")
        #expect(try store.artifactPhysicalForTesting().isEmpty, "no physical row committed")
        #expect(try store.byteUsageForTesting()[session.raw] == nil, "no usage bumped")
    }

    @Test("TOOL_quotaTwoSessionDedup")
    func quotaTwoSessionDedup() async throws {
        // Same bytes from two sessions: one file, one physical row, but each
        // session's logical usage counts its own reference.
        let (dir, store, _, _) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let bytes = Data("shared-bytes".utf8)
        let digest = Self.sha(bytes)
        let refLen = try Self.refPayloadBytes(digest: digest, size: bytes.count)
        for (i, w) in ["wa", "wb"].enumerated() {
            let s = SessionID("s-\(i)")
            try store.claimWriterOwnership(session: s, writer: w)
            let ref = try store.publishArtifact(session: s, as: WriterIdentity(session: s, writer: w), kind: "t", operationID: nil, bytes: bytes)
            #expect(ref.digest == digest)
        }
        let phys = try store.artifactPhysicalForTesting()
        #expect(phys == [digest: Int64(bytes.count)], "exactly one physical row, got \(phys)")
        let usage = try store.byteUsageForTesting()
        #expect(usage["s-0"] == Int64(refLen + bytes.count), "session logical counts own reference + distinct bytes, got \(String(describing: usage["s-0"]))")
        #expect(usage["s-1"] == Int64(refLen + bytes.count))
        for i in 0..<2 {
            let s = SessionID("s-\(i)")
            let back = try store.artifactRecord(session: s, digest: digest)
            #expect(back == bytes, "each session reads the shared bytes")
        }
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let finals = (try? FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".tmp-") }) ?? []
        #expect(finals == [digest], "exactly one stored file, got \(finals)")
    }

    // MARK: - Barrier legs (deterministic outcome sets)

    @Test("TOOL_barrierSerializedDedup")
    func barrierSerializedDedup() async throws {
        // Two concurrent publishers, same bytes: the artifact lock serializes;
        // the loser dedups (sees the winner's commit) and both succeed.
        let (dir, store, _, _) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let bytes = Data("barrier-bytes".utf8)
        let digest = Self.sha(bytes)
        let ia = WriterIdentity(session: SessionID("s-a"), writer: "wa")
        let ib = WriterIdentity(session: SessionID("s-b"), writer: "wb")
        try store.claimWriterOwnership(session: ia.session, writer: ia.writer)
        try store.claimWriterOwnership(session: ib.session, writer: ib.writer)
        async let ra = Result { try store.publishArtifact(session: ia.session, as: ia, kind: "t", operationID: nil, bytes: bytes) }
        async let rb = Result { try store.publishArtifact(session: ib.session, as: ib, kind: "t", operationID: nil, bytes: bytes) }
        let (a, b) = await (ra, rb)
        guard case .success(let refA) = a, case .success(let refB) = b else {
            Issue.record("both serialized publishers must succeed, got \(a) / \(b)"); return
        }
        #expect(refA.digest == digest && refB.digest == digest)
        #expect(try store.artifactPhysicalForTesting() == [digest: Int64(bytes.count)], "one physical row")
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(!entries.contains(where: { $0.hasPrefix(".tmp-") }), "no tmp leftovers: \(entries)")
        #expect(entries.filter({ !$0.hasPrefix(".tmp-") }) == [digest], "exactly one stored file")
    }

    @Test("TOOL_barrierLockBlocks", .timeLimit(.minutes(2)))
    func barrierLockBlocks() async throws {
        // A real cross-process-style lock holder (separate FD, LOCK_EX)
        // blocks a publisher; release lets it through. Deterministic with
        // wide margins (publish completes in ms once unblocked).
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let lockPath = dir.appendingPathComponent("store.sqlite-artifacts.lock").path
        // Touch the lock file path the store will use.
        _ = try store.publishArtifact(session: session, as: writer, kind: "seed", operationID: nil, bytes: Data("seed".utf8))
        let holder = lockPath.withCString { open($0, O_RDWR, mode_t(0o600)) }
        #expect(holder >= 0, "test setup: lock file must open")
        defer { if holder >= 0 { close(holder) } }
        #expect(flock(holder, LOCK_EX) == 0, "test setup: must acquire the artifact lock")
        final class FlagBox: @unchecked Sendable {
            var done = false
            var error: Error?
            let lock = NSLock()
            func setDone() { lock.withLock { done = true } }
            func isDone() -> Bool { lock.withLock { done } }
        }
        let box = FlagBox()
        let task = Task {
            do {
                _ = try store.publishArtifact(session: session, as: writer, kind: "t", operationID: nil, bytes: Data("blocked-bytes".utf8))
                box.setDone()
            } catch {
                box.lock.withLock { box.error = error }
                box.setDone()
            }
        }
        // The publisher must NOT complete while the lock is held elsewhere.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!box.isDone(), "publisher must block on the held artifact lock")
        #expect(flock(holder, LOCK_UN) == 0, "test teardown: must release the lock")
        await task.value
        #expect(box.isDone(), "publisher must complete after release")
        if let e = box.error { Issue.record("publisher failed after release: \(e)") }
        let back = try store.artifactRecord(session: session, digest: Self.sha(Data("blocked-bytes".utf8)))
        #expect(back == Data("blocked-bytes".utf8), "post-release publish committed")
    }

    @Test("TOOL_barrierConcurrentQuotaCleanup")
    func barrierConcurrentQuotaCleanup() async throws {
        // Global quota sized so exactly one of two concurrent same-byte
        // publishers commits; the loser fails quota (preflight or commit)
        // with no reference, no unreferenced file, and no tmp leftovers.
        // The winner's file and reference survive intact.
        let bytes = Data(repeating: 0x43, count: 60)
        let digest = Self.sha(bytes)
        let refLen = try Self.refPayloadBytes(digest: digest, size: bytes.count)
        // Winner commits phys(60)+rec(refLen); loser would need another
        // refLen on top. Window: [60+refLen, 60+2*refLen).
        let global = Int64(60 + refLen + refLen / 2)
        let (dir, store, _, _) = try Self.freshStore(globalByteLimit: global)
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let ia = WriterIdentity(session: SessionID("s-a"), writer: "wa")
        let ib = WriterIdentity(session: SessionID("s-b"), writer: "wb")
        try store.claimWriterOwnership(session: ia.session, writer: ia.writer)
        try store.claimWriterOwnership(session: ib.session, writer: ib.writer)
        async let ra = Result { try store.publishArtifact(session: ia.session, as: ia, kind: "t", operationID: nil, bytes: bytes) }
        async let rb = Result { try store.publishArtifact(session: ib.session, as: ib, kind: "t", operationID: nil, bytes: bytes) }
        let (a, b) = await (ra, rb)
        let successes = [a, b].filter { if case .success = $0 { return true }; return false }
        #expect(successes.count == 1, "exactly one publisher must commit, got \(a) / \(b)")
        let failures = [a, b].filter { if case .failure = $0 { return true }; return false }
        #expect(failures.count == 1)
        if case .failure(let err) = failures[0] {
            guard let se = err as? StoreError, case .quotaExceeded = se else {
                Issue.record("loser must fail quota, got \(err)"); return
            }
        }
        // Exactly one session references the digest (the winner).
        var refCount = 0
        for s in [ia.session, ib.session] {
            if try Self.referencedDigests(store: store, session: s).contains(digest) { refCount += 1 }
        }
        #expect(refCount == 1, "exactly one committed reference")
        #expect(try store.artifactPhysicalForTesting() == [digest: Int64(bytes.count)], "winner's physical row intact")
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(!entries.contains(where: { $0.hasPrefix(".tmp-") }), "loser's tmp cleaned, found \(entries)")
        #expect(entries.filter({ !$0.hasPrefix(".tmp-") }) == [digest], "only the winner's file remains")
    }
}

extension B3ByteQuotaTests {
    @Test("TOOL_negativeSizeRejected")
    func negativeSizeRejected() throws {
        // Negative sizes must fail closed as integrity errors, never
        // subtract from quotas. (publishArtifact derives size from bytes,
        // so this exercises the guard directly.)
        let (dir, store, session, _) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let view = GRDBSessionStore.ByteQuotaView(logicalCurrent: 0, physicalSum: 0, globalRecordBytes: 0, orphanBytes: 0, physicalRows: [:], sessionHasDigest: false)
        do {
            try store.checkByteQuotas(view, session: session.raw, payloadBytes: 10, digest: String(repeating: "a", count: 64), size: -5)
            Issue.record("negative size must fail closed")
        } catch let error as StoreError {
            guard case .integrity = error else { Issue.record("expected integrity, got \(error)"); return }
        }
    }

    @Test("TOOL_intMaxSizeQuotaExceeded")
    func intMaxSizeQuotaExceeded() throws {
        // Int.max size must fail closed as quota (never trap on overflow).
        let (dir, store, session, _) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let view = GRDBSessionStore.ByteQuotaView(logicalCurrent: 0, physicalSum: 0, globalRecordBytes: 0, orphanBytes: 0, physicalRows: [:], sessionHasDigest: false)
        do {
            try store.checkByteQuotas(view, session: session.raw, payloadBytes: 10, digest: String(repeating: "b", count: 64), size: Int64.max)
            Issue.record("Int.max size must fail closed")
        } catch let error as StoreError {
            guard case .quotaExceeded = error else { Issue.record("expected quotaExceeded, got \(error)"); return }
        }
    }

    @Test("TOOL_appendBatchMismatch")
    func appendBatchMismatch() throws {
        // Same digest with different sizes in one batch fails closed.
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try store.claimWriterOwnership(session: session, writer: "w")
        let digest = String(repeating: "c", count: 64)
        let ref1 = ArtifactRef(digest: digest, size: 10, kind: "t", operationID: nil)
        let ref2 = ArtifactRef(digest: digest, size: 20, kind: "t", operationID: nil)
        do {
            try store.appendBatch([
                .artifactPublished(ref1),
                .artifactPublished(ref2),
            ], as: WriterIdentity(session: session, writer: "w"))
            Issue.record("mismatched batch must fail")
        } catch let error as StoreError {
            guard case .integrity = error else { Issue.record("expected integrity, got \(error)"); return }
        }
    }

    @Test("TOOL_appendBatchCommittedSizeMismatch")
    func appendBatchCommittedSizeMismatch() throws {
        // Batch referencing a committed digest with a different size fails
        // closed (exercises the moved committed-row check, not just the
        // intra-batch check).
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try store.claimWriterOwnership(session: session, writer: "w")
        let digest = String(repeating: "d", count: 64)
        let committed = ArtifactRef(digest: digest, size: 100, kind: "t", operationID: nil)
        try store.append(.artifactPublished(committed), as: WriterIdentity(session: session, writer: "w"))
        #expect(try store.artifactPhysicalForTesting()[digest] == 100)
        let mismatched = ArtifactRef(digest: digest, size: 200, kind: "t", operationID: nil)
        do {
            try store.appendBatch([.artifactPublished(mismatched)], as: WriterIdentity(session: session, writer: "w"))
            Issue.record("batch against mismatched committed row must fail")
        } catch let error as StoreError {
            guard case .integrity = error else { Issue.record("expected integrity, got \(error)"); return }
        }
        #expect(try store.artifactPhysicalForTesting()[digest] == 100, "committed row untouched")
    }

    @Test("TOOL_crashOrphanRetrySucceeds")
    func crashOrphanRetrySucceeds() throws {
        // A crash between rename and reference commit leaves the final file.
        // Re-publishing adopts it instead of failing or duplicating.
        let (dir, store, session, writer) = try Self.freshStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try store.claimWriterOwnership(session: session, writer: "w")
        let bytes = Data("crash-orphan-payload".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: root + "/" + digest))
        let ref = try store.publishArtifact(session: session, as: writer, kind: "t", operationID: nil, bytes: bytes)
        #expect(ref.digest == digest, "crash-orphan retry must succeed by adopting the verified file")
        #expect(try store.artifactRecord(session: session, digest: digest) == bytes)
        #expect(try store.artifactPhysicalForTesting()[digest] == Int64(bytes.count))
    }

    @Test("TOOL_preflightQuotaBeforeFs")
    func preflightQuotaBeforeFs() throws {
        // Quota failure must precede any filesystem mutation (no tmp file).
        let (dir, store, session, writer) = try Self.freshStore(sessionByteLimit: 100)
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try store.claimWriterOwnership(session: session, writer: "w")
        // 60 bytes passes preflight (usage 0 + 60 <= 100), but the
        // authoritative check adds the reference row and must fail.
        // Use small enough bytes that preflight passes on bytes alone.
        do {
            _ = try store.publishArtifact(session: session, as: writer, kind: "t", operationID: nil, bytes: Data(repeating: 0x41, count: 60))
            Issue.record("expected authoritative quota failure")
        } catch let error as StoreError {
            guard case .quotaExceeded = error else { Issue.record("expected quotaExceeded, got \(error)"); return }
        }
        let root = GRDBSessionStore.artifactsRoot(for: dir.appendingPathComponent("store.sqlite").path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(!entries.contains(where: { $0.hasPrefix(".tmp-") }), "no tmp leftovers, found \(entries)")
        #expect(!entries.contains(where: { $0.count == 64 }), "no final file from failed publish")
    }
}
