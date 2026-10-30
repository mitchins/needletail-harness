import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-D D2 real-tier proofs: the production executor captures
/// mutation-boundary identity, and the production validator + applier
/// compensate over real temporary filesystems with real GRDB preimages.
/// Pure preflight truth tables live in NeedletailStateTests/UndoTests; the
/// actor loop lives in NeedletailActorTests/UndoActorTests.
struct UndoFilesTests {
    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    private static func tempStore() throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-undo")
        let writer = WriterIdentity(session: session, writer: "w-undo")
        try store.claimWriterOwnership(session: session, writer: "w-undo")
        return (dir, store, session, writer)
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func shaData(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func reservation(_ batch: ToolBatch) -> EffectReservation {
        EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: true, batch: batch, kind: .executor, approvedPaths: ["/x"])
    }

    private static func editBatch(path: String, expectedHash: String, old: String, new: String, call: String = "c1") -> ToolBatch {
        ToolBatch([ToolProposal(callID: call, tool: "edit", argumentsDigest: "d",
                                arguments: "{\"path\":\"\(path)\",\"expectedHash\":\"\(expectedHash)\",\"old_string\":\"\(old)\",\"new_string\":\"\(new)\"}")])
    }

    // MARK: - UX-UNDO-01 real: boundary identity + preimage + restore

    @Test("UX-UNDO-01 real: executor captures boundary identity; validator eligible; applier restores")
    func UX_UNDO_01_realEditRestoreRoundTrip() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "original\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h0 = Self.sha("original\n")
        let batch = Self.editBatch(path: "f.txt", expectedHash: h0, old: "original", new: "edited")
        let result = try await exec.execute(batch: batch, reservation: Self.reservation(batch))
        let outcome = try #require(result.calls.first)
        #expect(outcome.status == "success", "edit must succeed, got \(outcome)")
        #expect(outcome.deviceBefore != nil && outcome.inodeBefore != nil, "before identity captured at the boundary")
        #expect(outcome.deviceAfter != nil && outcome.inodeAfter != nil, "post-commit identity captured at the boundary")
        #expect(outcome.grantedRoot == fp.string, "granting root bound at the boundary")
        #expect(outcome.created != true, "replace is not a create")
        let digest = try #require(outcome.artifactID, "replace publishes a preimage artifact")
        #expect(try store.artifactRecord(session: session, digest: digest) == Data("original\n".utf8), "preimage bytes are the proven original")
        // The group builder accepts the proven member.
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        #expect(group.members.count == 1)
        let member = group.members[0]
        #expect(member.preimageDigest == digest && !member.emptyOriginal)
        // Real validator: eligible.
        let validator = FilesystemUndoValidator(resolver: resolver)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        let needs = inverses.map { UndoValidationNeed(inverseID: $0.inverseID, path: $0.path) }
        let observations = await validator.validate(members: needs)
        #expect(observations.count == 1 && observations[0].readable)
        #expect(undoPreflight(member: member, observation: observations[0], preimageAvailable: true) == .eligible)
        // Real applier: restores the proven original.
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let applied = await applier.apply(inverses[0])
        guard case .applied = applied else {
            Issue.record("restore must apply, got \(applied)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "original\n", "bytes restored")
    }

    // MARK: - UX-UNDO-02 real (RED): user edit refuses without overwrite

    @Test("UX-UNDO-02 real: user edit after the batch refuses; attacker bytes never overwritten")
    func UX_UNDO_02_realUserEditRefuses() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = Self.editBatch(path: "f.txt", expectedHash: Self.sha("v1\n"), old: "v1", new: "v2")
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        // The user edits after the batch (same size — only content proves it).
        try "vX\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let validator = FilesystemUndoValidator(resolver: resolver)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        let observations = await validator.validate(members: inverses.map {
            UndoValidationNeed(inverseID: $0.inverseID, path: $0.path)
        })
        #expect(undoPreflight(member: group.members[0], observation: observations[0], preimageAvailable: true) != .eligible, "drifted content fails preflight")
        // Counterfactual: even a direct apply refuses without touching bytes.
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let refused = await applier.apply(inverses[0])
        guard case .refused = refused else {
            Issue.record("drifted file must refuse, got \(refused)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "vX\n", "user bytes untouched")
    }

    // MARK: - UX-UNDO-03 real: created file deletes; repurposed file refuses

    @Test("UX-UNDO-03 real: exact created file deletes; replaced file refuses")
    func UX_UNDO_03_realCreatedFileRules() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d",
                                            arguments: "{\"path\":\"n.txt\",\"content\":\"fresh\\n\"}")])
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        #expect(outcome.status == "success" && outcome.created == true, "create succeeds, got \(outcome)")
        #expect(outcome.beforeHash == nil && outcome.artifactID == nil, "creates publish no preimage by construction")
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        #expect(group.members[0].created)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        guard case .removeCreated = inverses[0].kind else {
            Issue.record("create inverse must be removeCreated")
            return
        }
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let applied = await applier.apply(inverses[0])
        guard case .applied = applied else {
            Issue.record("exact created file must delete, got \(applied)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("n.txt").path), "created file removed")
        // Repurposed: recreate with different bytes but SAME name — the
        // recorded identity no longer matches, so the inverse refuses.
        try "attacker\n".write(to: url.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let repurposed = await applier.apply(inverses[0])
        guard case .refused = repurposed else {
            Issue.record("repurposed file must refuse, got \(repurposed)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("n.txt"), encoding: .utf8) == "attacker\n", "unrelated bytes never deleted")
    }

    // MARK: - UX-UNDO-11 real: symlink swap, mode change, root mismatch

    @Test("UX-UNDO-11 real: symlink swap refuses without following")
    func UX_UNDO_11_realSymlinkSwapRefuses() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: url.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = Self.editBatch(path: "f.txt", expectedHash: Self.sha("v1\n"), old: "v1", new: "v2")
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        // Swap the path for a symlink to the outside file.
        try FileManager.default.removeItem(at: url.appendingPathComponent("f.txt"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("f.txt"), withDestinationURL: url.appendingPathComponent("outside.txt"))
        let validator = FilesystemUndoValidator(resolver: resolver)
        let observations = await validator.validate(members: [UndoValidationNeed(inverseID: inverses[0].inverseID, path: "f.txt")])
        #expect(observations[0].readable == false, "symlink is unreadable evidence")
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let refused = await applier.apply(inverses[0])
        guard case .refused = refused else {
            Issue.record("symlink swap must refuse, got \(refused)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("outside.txt"), encoding: .utf8) == "outside\n", "symlink target never followed or written")
    }

    @Test("UX-UNDO-11 real: mode change refuses; granting-root mismatch refuses")
    func UX_UNDO_11_realModeAndRootRefuse() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let file = url.appendingPathComponent("f.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = Self.editBatch(path: "f.txt", expectedHash: Self.sha("v1\n"), old: "v1", new: "v2")
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        #expect(outcome.mode == "640", "mode preserved on the receipt")
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        // chmod after the batch: identity holds, mode drifts.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let refused = await applier.apply(inverses[0])
        guard case .refused = refused else {
            Issue.record("mode drift must refuse, got \(refused)")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "v2\n", "drifted bytes untouched")
        // Cross-workspace applier: same bytes, different root — refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let (url2, fp2) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url2) }
        let resolver2 = try WorkspaceResolver(workspace: fp2, readRoots: [])
        let foreign = FilesystemUndoApplier(resolver: resolver2, store: store, session: session, writer: writer)
        let crossRefused = await foreign.apply(inverses[0])
        guard case .refused = crossRefused else {
            Issue.record("cross-workspace inverse must refuse, got \(crossRefused)")
            return
        }
    }

    // MARK: - UX-UNDO-10 real: unavailable preimage fails clean, mutates nothing

    @Test("UX-UNDO-10 real: corrupt preimage digest fails clean without mutation")
    func UX_UNDO_10_realMissingPreimageFailsClean() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = Self.editBatch(path: "f.txt", expectedHash: Self.sha("v1\n"), old: "v1", new: "v2")
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        var inverses = undoInverses(undoCommandID: "undo-1", group: group)
        // Lose the preimage reference (quota-loss shape: digest unknown).
        guard case .restore(_, let expect) = inverses[0].kind else {
            Issue.record("expected a restore inverse")
            return
        }
        inverses[0] = UndoInverse(
            inverseID: inverses[0].inverseID, undoCommandID: "undo-1",
            groupID: "chg-1", path: "f.txt", grantedRoot: inverses[0].grantedRoot,
            kind: .restore(preimageDigest: String(repeating: "0", count: 64), expect: expect),
            restoreMode: inverses[0].restoreMode)
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let failed = await applier.apply(inverses[0])
        guard case .failed(let error, let possiblyMutated) = failed, !possiblyMutated else {
            Issue.record("missing preimage must fail clean, got \(failed)")
            return
        }
        #expect(error.contains("unavailable"), "cause names the missing preimage")
        #expect(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "v2\n", "postimage untouched")
    }

    @Test("restoreMissing refuses without touching the file")
    func restoreMissingRefuses() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "post\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let inverse = UndoInverse(
            inverseID: "undo/undo-1/chg-1/eff-1/c1", undoCommandID: "undo-1",
            groupID: "chg-1", path: "f.txt", grantedRoot: fp.string,
            kind: .restoreMissing(expect: UndoFileState(
                device: 1, inode: 2, hash: Self.sha("post\n"), mode: "644")),
            restoreMode: "644")
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let outcome = await applier.apply(inverse)
        guard case .refused = outcome else {
            Issue.record("missing-preimage inverse must refuse, got \(outcome)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "post\n", "refused inverse mutates nothing")
    }

    // MARK: - Counterfactual: a repeated inverse never applies twice
    @Test("UX-UNDO-09 counterfactual: applying the same inverse twice refuses the second")
    func UX_UNDO_09_doubleApplyRefuses() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = Self.editBatch(path: "f.txt", expectedHash: Self.sha("v1\n"), old: "v1", new: "v2")
        let outcome = try #require(try await exec.execute(batch: batch, reservation: Self.reservation(batch)).calls.first)
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let first = await applier.apply(inverses[0])
        guard case .applied = first else {
            Issue.record("first apply must succeed, got \(first)")
            return
        }
        // Naive replay of the same inverse: the file now equals the
        // PREIMAGE, not the recorded postimage — revalidation refuses
        // instead of restoring again (or worse, erroring destructively).
        let second = await applier.apply(inverses[0])
        guard case .refused = second else {
            Issue.record("second apply must refuse, got \(second)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "v1\n", "exactly-once effect, still the original bytes")
    }

    // MARK: - Empty original + zero-byte restore

    @Test("empty original real: zero-byte file restores to zero bytes")
    func realEmptyOriginalRestores() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try Data().write(to: url.appendingPathComponent("e.txt"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        // Empty file contains no oldBytes: use a write-replacement instead.
        let repBatch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d",
                                                arguments: "{\"path\":\"e.txt\",\"expectedHash\":\"\(emptySHA256Hex)\",\"content\":\"v2\\n\"}")])
        let outcome = try #require(try await exec.execute(batch: repBatch, reservation: Self.reservation(repBatch)).calls.first)
        #expect(outcome.status == "success", "empty replacement must succeed, got \(outcome)")
        let group = try #require(buildChangeGroup(
            groupID: "chg-1", runID: RunID("r1"), effectID: EffectID("eff-1"),
            proposals: repBatch.proposals, outcomes: ["c1": outcome], doneCallIDs: ["c1"]))
        let member = group.members[0]
        #expect(member.emptyOriginal && member.preimageDigest == nil, "zero-byte original is proven-empty, not missing")
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        let applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        let applied = await applier.apply(inverses[0])
        guard case .applied = applied else {
            Issue.record("empty restore must apply, got \(applied)")
            return
        }
        #expect((try Data(contentsOf: url.appendingPathComponent("e.txt"))).isEmpty, "restored to zero bytes")
    }
}
