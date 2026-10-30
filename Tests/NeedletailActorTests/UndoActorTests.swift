import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage

/// M2-D D2 actor integration: production SessionActor + production
/// NativeToolExecutor + production validator/applier over real temporary
/// filesystems, real InMemory store, scripted transport/approvals. The
/// executor genuinely mutates the temp workspace, so every identity, hash
/// and preimage the loop judges is real — only the provider is scripted.
/// Fault injection uses scripted seams at the applier boundary; reopen goes
/// through the production `resumeSession` entry point.
struct UndoActorTests {
    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-actor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeActor(
        dir: FilePath, store: InMemorySessionStore, state: SessionState,
        transport: ScriptedTransport, executor: NativeToolExecutor,
        approvals: ScriptedApprovals, session: SessionID, writer: WriterIdentity,
        inverseApplier: (any UndoInverseApplier)? = nil,
        ids: DeterministicIDSource
    ) throws -> SessionActor<ScriptedTransport, NativeToolExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        let resolver = try WorkspaceResolver(workspace: dir, readRoots: [])
        let validator = FilesystemUndoValidator(resolver: resolver)
        let applier: any UndoInverseApplier
        if let faulting = inverseApplier {
            applier = faulting
        } else {
            applier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        }
        return try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: writer.writer,
            undoValidator: validator, inverseApplier: applier)
    }

    private static func records(_ store: InMemorySessionStore) throws -> [DurableRecord] {
        let (page, _) = try store.records(since: 0, limit: 100_000)
        return page.map(\.record)
    }

    private static func groups(_ store: InMemorySessionStore) throws -> [ChangeGroup] {
        reconcileChangeGroups(try Self.records(store))
    }

    private static func preimages(_ store: InMemorySessionStore, session: SessionID, group: ChangeGroup) throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        for member in group.members {
            if let digest = member.preimageDigest {
                out[digest] = (try store.artifactRecord(session: session, digest: digest)) != nil
            }
        }
        return out
    }

    private static func awaitDisposition(
        _ actor: SessionActor<ScriptedTransport, NativeToolExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        command: String
    ) async throws -> UndoDispositionRecord {
        for _ in 0..<20_000 {
            let state = await actor.currentState()
            if let recorded = state.undoDispositions.first(where: { $0.undoCommandID == command }) {
                return recorded
            }
            await Task.yield()
        }
        Issue.record("actor never recorded disposition for \(command)")
        throw ScriptedError.outOfScript
    }

    /// Scripted applier for fault injection: fails the FIRST inverse it
    /// sees (cleanly or ambiguously) while leaving the real filesystem
    /// untouched; every later inverse refuses. Single-shot by construction.
    final class FaultApplier: UndoInverseApplier, @unchecked Sendable {
        enum Fault: Sendable { case clean, ambiguous }
        let fault: Fault
        private let lock = NSLock()
        private var used = false
        init(fault: Fault) { self.fault = fault }
        func apply(_ inverse: UndoInverse) async -> UndoInverseOutcome {
            let first = lock.withLock { () -> Bool in
                defer { used = true }
                return !used
            }
            guard first else { return .refused(reason: "fault applier single-shot") }
            switch fault {
            case .clean:
                return .failed(error: "injected clean failure", possiblyMutated: false)
            case .ambiguous:
                return .failed(error: "injected ambiguous failure", possiblyMutated: true)
            }
        }
    }

    // MARK: - Full loop: batch → group → undo → notice → next request

    @Test("UNDO end-to-end: real batch records a group; undo restores, deletes, notices, continues")
    func fullUndoLoop() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InMemorySessionStore()
        let session = SessionID("s-undo-actor")
        let writer = WriterIdentity(session: session, writer: "w-undo")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let idleSession = SessionState(
            sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let approvals = ScriptedApprovals()
        let transport = ScriptedTransport()
        // b.txt pre-exists; the batch creates a.txt and edits b.txt
        // (separate paths — same-path multi-touch refuses by identity rule).
        try "b1\n".write(to: url.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let hB1 = Self.sha("b1\n")
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "batch", toolProposals: [
                    ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\",\"content\":\"a1\\n\"}"),
                    ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"b.txt\",\"expectedHash\":\"\(hB1)\",\"old_string\":\"b1\",\"new_string\":\"b2\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
            // Post-undo continuation (STATE-05 leg): one more request.
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(2)),
        ]
        let actor = try Self.makeActor(
            dir: fp, store: store, state: idleSession, transport: transport,
            executor: executor, approvals: approvals, session: session,
            writer: writer, ids: DeterministicIDSource(prefix: "ua"))
        await actor.submitText(commandID: CommandID("run-1"), text: "do the edits", kind: .followUp, sealed: false)
        // The batch completes and the run settles.
        for _ in 0..<20_000 {
            let state = await actor.currentState()
            if case .completed = state.phase { break }
            await Task.yield()
        }
        let settled = await actor.currentState()
        guard case .completed = settled.phase else {
            Issue.record("run never completed, phase=\(settled.phase)")
            return
        }
        #expect(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8) == "a1\n")
        #expect(try String(contentsOf: url.appendingPathComponent("b.txt"), encoding: .utf8) == "b2\n")
        let recorded = try Self.groups(store)
        #expect(recorded.count == 1, "exactly one change group recorded, got \(recorded.count)")
        let group = try #require(recorded.first)
        #expect(group.members.count == 2, "create + replace both proven")
        let paths = Set(group.members.map(\.path))
        #expect(paths == ["a.txt", "b.txt"])
        #expect(group.members.allSatisfy { $0.deviceAfter != 0 && $0.inodeAfter != 0 }, "boundary identity on every member")
        let createMember = try #require(group.members.first(where: { $0.created }))
        #expect(createMember.preimageDigest == nil, "creates carry no preimage by construction")
        let editMember = try #require(group.members.first(where: { !$0.created }))
        #expect(editMember.preimageDigest != nil, "replace carries its verified preimage")

        // Run the undo: reverse order — b.txt restores, a.txt deletes.
        let command = await actor.runUndo(
            group: group,
            preimagesAvailable: try Self.preimages(store, session: session, group: group))
        let disposition = try await Self.awaitDisposition(actor, command: command)
        #expect(disposition.outcome == .completed, "real undo completes, got \(disposition)")
        #expect(disposition.fileOutcomes.count == 2)
        #expect(try String(contentsOf: url.appendingPathComponent("b.txt"), encoding: .utf8) == "b1\n", "edit restored to the proven original")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("a.txt").path), "created file deleted")
        // The notice committed atomically with the disposition (STATE-05).
        let log = try Self.records(store)
        let noticeIdx = log.firstIndex(where: {
            if case .transcriptAppended(.workspaceChangeNotice(let n)) = $0 { return n.undoCommandID == command }
            return false
        })
        let dispIdx = log.firstIndex(where: {
            if case .undoDisposition(let d) = $0 { return d.undoCommandID == command }
            return false
        })
        #expect(noticeIdx != nil && dispIdx != nil && noticeIdx! == dispIdx! + 1, "notice commits immediately with its disposition")

        // UNDO-09 at the actor seam: the same command resubmitted answers
        // from the journal with no second mutation.
        try "b-user\n".write(to: url.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        await actor.applyExternalEvent(.undoRun(
            undoCommandID: command, group: group,
            preimagesAvailable: try Self.preimages(store, session: session, group: group),
            atMillis: 9_000_000))
        for _ in 0..<5_000 { await Task.yield() }
        let after = await actor.currentState()
        #expect(after.undoDispositions.filter({ $0.undoCommandID == command }).count == 1, "no second disposition recorded")
        #expect(try String(contentsOf: url.appendingPathComponent("b.txt"), encoding: .utf8) == "b-user\n", "duplicate performs no second inverse")
        let intents = try Self.records(store).filter {
            if case .operationIntent(let ref) = $0 { return ref.operationID.raw.hasPrefix("undo/") }
            return false
        }
        #expect(intents.count == 2, "no new inverse intents on duplicate, got \(intents.count)")

        // STATE-05 end-to-end: the next provider request carries the notice.
        await actor.submitText(commandID: CommandID("run-2"), text: "continue", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if transport.invocations.count >= 2 { break }
            await Task.yield()
        }
        #expect(transport.invocations.count >= 2, "loop continues after undo")
    }

    // MARK: - Preview conflict + fault injection at the actor seam

    @Test("preview reports user drift; run then refuses with zero inverses")
    func previewConflictThenRefusedRun() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InMemorySessionStore()
        let session = SessionID("s-undo-preview")
        let writer = WriterIdentity(session: session, writer: "w-undo")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let state = SessionState(sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        try "p1\n".write(to: url.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
        let hP1 = Self.sha("p1\n")
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "batch", toolProposals: [
                    ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"p.txt\",\"expectedHash\":\"\(hP1)\",\"old_string\":\"p1\",\"new_string\":\"p2\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
        ]
        let actor = try Self.makeActor(
            dir: fp, store: store, state: state, transport: transport,
            executor: executor, approvals: ScriptedApprovals(), session: session,
            writer: writer, ids: DeterministicIDSource(prefix: "up"))
        await actor.submitText(commandID: CommandID("run-1"), text: "edit p", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if case .completed = await actor.currentState().phase { break }
            await Task.yield()
        }
        let group = try #require(try Self.groups(store).first)
        // Drift the file, then preview: dry run stages nothing permanent.
        try "p-user\n".write(to: url.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
        await actor.previewUndo(group: group, preimagesAvailable: try Self.preimages(store, session: session, group: group))
        for _ in 0..<5_000 { await Task.yield() }
        let previewed = await actor.currentState()
        #expect(previewed.pendingUndo == nil, "conflicted preview clears pending")
        #expect(previewed.undoDispositions.isEmpty, "preview records no disposition")
        // And the run refuses with zero new inverse intents.
        let intentsBefore = try Self.records(store).filter {
            if case .operationIntent(let ref) = $0 { return ref.operationID.raw.hasPrefix("undo/") }
            return false
        }.count
        let command = await actor.runUndo(group: group, preimagesAvailable: try Self.preimages(store, session: session, group: group))
        let disposition = try await Self.awaitDisposition(actor, command: command)
        #expect(disposition.outcome == .refused)
        let intentsAfter = try Self.records(store).filter {
            if case .operationIntent(let ref) = $0 { return ref.operationID.raw.hasPrefix("undo/") }
            return false
        }.count
        #expect(intentsAfter == intentsBefore, "refused group commits zero inverse intents")
        #expect(try String(contentsOf: url.appendingPathComponent("p.txt"), encoding: .utf8) == "p-user\n", "refused run mutates nothing")
    }

    @Test("fault injection: ambiguous first inverse holds unknown with queue barrier")
    func ambiguousFailureHolds() async throws {        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InMemorySessionStore()
        let session = SessionID("s-undo-fault")
        let writer = WriterIdentity(session: session, writer: "w-undo")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let state = SessionState(sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        try "m1\n".write(to: url.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try "n1\n".write(to: url.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "batch", toolProposals: [
                    ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"m.txt\",\"expectedHash\":\"\(Self.sha("m1\n"))\",\"old_string\":\"m1\",\"new_string\":\"m2\"}"),
                    ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"n.txt\",\"expectedHash\":\"\(Self.sha("n1\n"))\",\"old_string\":\"n1\",\"new_string\":\"n2\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
        ]
        let probeActor = try Self.makeActor(
            dir: fp, store: store, state: state, transport: transport,
            executor: executor, approvals: ScriptedApprovals(), session: session,
            writer: writer, ids: DeterministicIDSource(prefix: "uf0"))
        await probeActor.submitText(commandID: CommandID("run-1"), text: "edit both", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if case .completed = await probeActor.currentState().phase { break }
            await Task.yield()
        }
        let group = try #require(try Self.groups(store).first)
        #expect(group.members.count == 2)
        // Re-enter with a faulting applier: the FIRST inverse (n.txt, the
        // reverse-batch head) fails ambiguously without touching the FS.
        let idle2 = SessionState(sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let actor2 = try Self.makeActor(
            dir: fp, store: store, state: idle2, transport: ScriptedTransport(),
            executor: executor, approvals: ScriptedApprovals(), session: session,
            writer: writer, inverseApplier: FaultApplier(fault: .ambiguous),
            ids: DeterministicIDSource(prefix: "uf"))
        let command = await actor2.runUndo(group: group, preimagesAvailable: try Self.preimages(store, session: session, group: group))
        let disposition = try await Self.awaitDisposition(actor2, command: command)
        #expect(disposition.outcome == .needsReconciliation, "ambiguous first inverse holds, got \(disposition)")
        let st = await actor2.currentState()
        #expect(st.queueHeld, "unknown inverse holds the queue")
        #expect(st.unresolvedOperations.contains(where: { $0.state == .unknown && $0.operationID.raw.hasPrefix("undo/") }), "unknown inverse seeds a recovery marker")
        #expect(try String(contentsOf: url.appendingPathComponent("n.txt"), encoding: .utf8) == "n2\n", "fault applier mutates nothing")
        #expect(try String(contentsOf: url.appendingPathComponent("m.txt"), encoding: .utf8) == "m2\n", "chain halts: second inverse never runs")
    }

    // MARK: - Boundary 5: settled journal without disposition recovers on reopen

    @Test("boundary 5: settled journal without disposition recovers via recoverUndoJournal before next request")
    func boundary5RecoverySweep() async throws {
        let store = InMemorySessionStore()
        let session = SessionID("s-undo-r5")
        let writer = WriterIdentity(session: session, writer: "w-undo")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let idle = try ActorFixtures.idleState(mode: .workspace, permissive: true)
        // Seed the crash shape directly: group + intent + done result, but
        // NO disposition (process died after the last result commit).
        let member = ChangeGroupMember(
            operationID: OperationID("eff-9/c1"), callID: "c1",
            path: "r5.txt", grantedRoot: "/tmp/ws",
            created: false, beforeHash: "b0", afterHash: "a0",
            deviceBefore: 1, inodeBefore: 2, modeBefore: "644",
            preimageDigest: "b0", emptyOriginal: false,
            deviceAfter: 1, inodeAfter: 3, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "edited r5.txt")
        let group = ChangeGroup(
            groupID: "chg-9", runID: RunID("run-9"), effectID: EffectID("eff-9"),
            members: [member], hadExecProposals: false, hadReadProposals: false)
        let inverseID = undoInverseID(undoCommandID: "undo-9", groupID: group.groupID, operationID: member.operationID)
        try store.appendBatch([
            .changeGroup(group),
            .operationIntent(OperationRef(
                operationID: OperationID(inverseID), callID: inverseID,
                state: .intent, mutating: true)),
            .operationResult(
                OperationRef(
                    operationID: OperationID(inverseID), callID: inverseID,
                    state: .done, mutating: true),
                outcome: "applied: restored r5.txt"),
        ], as: writer)
        // Production reopen: nothing held (everything settled), no
        // disposition, no notice — the exact gap Major 2 names.
        var rids = DeterministicIDSource(prefix: "r5")
        let rebuilt = try resumeSession(
            store: store, session: session, epoch: idle.epoch,
            trustMode: .workspace, as: writer.writer, ids: &rids)
        #expect(!rebuilt.queueHeld, "settled journal holds nothing")
        #expect(rebuilt.undoDispositions.isEmpty, "no disposition without one recorded")
        #expect(pendingUndoFinalizations(try Self.records(store)).count == 1, "pure detector finds the boundary-5 journal")
        // Recovery sweep through the production actor: disposition + notice
        // commit atomically; a second sweep is a pure no-op.
        let transport = ScriptedTransport()
        transport.script = [ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0))]
        let actor = try Self.makeActor(
            dir: FilePath("/tmp"), store: store, state: rebuilt,
            transport: transport,
            executor: NativeToolExecutor(
                resolver: try WorkspaceResolver(workspace: nil, readRoots: []),
                store: store, sessionID: session, writer: writer),
            approvals: ScriptedApprovals(), session: session,
            writer: writer, ids: rids)
        let recovered = await actor.recoverUndoJournal()
        #expect(recovered.count == 1 && recovered[0].outcome == .completed, "sweep recovers the completed journal, got \(recovered)")
        #expect(recovered[0].fileOutcomes.first?.afterHash == "a0", "recovered outcomes carry the exact hashes")
        let again = await actor.recoverUndoJournal()
        #expect(again.isEmpty, "second sweep finds nothing pending (idempotent)")
        // STATE-05: the recovered notice precedes the next provider request.
        await actor.submitText(commandID: CommandID("run-2"), text: "continue", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if transport.invocations.count >= 1 { break }
            await Task.yield()
        }
        #expect(transport.invocations.count >= 1, "loop continues after recovery")
        let log = try Self.records(store)
        let transcript = log.compactMap { record -> TranscriptEntry? in
            if case .transcriptAppended(let entry) = record { return entry }
            return nil
        }
        let noticeIdx = transcript.firstIndex(where: {
            if case .workspaceChangeNotice(let n) = $0 { return n.undoCommandID == "undo-9" }
            return false
        })
        let run2Idx = transcript.firstIndex(where: {
            if case .user(let text) = $0 { return text == "continue" }
            return false
        })
        #expect(noticeIdx != nil && run2Idx != nil && noticeIdx! < run2Idx!, "recovered notice precedes the next request")
    }
}
