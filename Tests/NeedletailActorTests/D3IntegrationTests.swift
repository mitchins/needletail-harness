import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage

/// M2-D D3 integration: the assembled D0+D1+D2 system through the single
/// authoritative reopening sequence (`reopenHeadlessSession`), real GRDB
/// stores, the production SessionActor, real temporary workspaces and
/// synthetic provider responses. No live models, no terminal UI.
///
/// Every scenario terminates the actor (drops it and closes the store
/// handle — process death, never a graceful shutdown) and reopens through
/// the production path. Counterfactual legs prove each recovery step is
/// load-bearing by bypassing it.
struct D3IntegrationTests {

    // MARK: - Harness

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("d3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func tempStore(at dir: URL) throws -> GRDBSessionStore {
        try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
    }

    private static func idleState(session: SessionID, mode: TrustMode, permissive: Bool) throws -> SessionState {
        let idle = try ActorFixtures.idleState(mode: mode, permissive: permissive)
        return SessionState(
            sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func awaitState<T, E, S, A>(
        _ actor: SessionActor<T, E, S, A, SystemClock, DeterministicIDSource>,
        _ check: (SessionState) -> Bool, _ label: String
    ) async throws where T: ModelTransport, E: ToolExecutor, S: SessionStore, A: ApprovalGateway {
        for _ in 0..<20_000 {
            if check(await actor.currentState()) { return }
            await Task.yield()
        }
        Issue.record("actor never reached \(label)")
        throw ScriptedError.outOfScript
    }

    private static func storeRecords(_ store: GRDBSessionStore, _ session: SessionID) throws -> [DurableRecord] {
        let (page, _) = try store.records(session: session, since: 0, limit: 100_000)
        return page.map(\.record)
    }

    private static func undoIntents(_ store: GRDBSessionStore, _ session: SessionID) throws -> [String] {
        try Self.storeRecords(store, session).compactMap { record in
            if case .operationIntent(let ref) = record, ref.operationID.raw.hasPrefix("undo/") {
                return ref.operationID.raw
            }
            return nil
        }
    }

    /// Fail-closed store wrapper: throws `.integrity` on batches matching
    /// the predicate (commit-failure injection), forwarding everything else.
    final class FailingStore<Base: SessionStore>: SessionStore, @unchecked Sendable {
        let inner: Base
        var failWhen: (@Sendable ([DurableRecord]) -> Bool)?
        init(_ inner: Base, failWhen: (@Sendable ([DurableRecord]) -> Bool)? = nil) {
            self.inner = inner
            self.failWhen = failWhen
        }
        func artifactRecord(session: SessionID, digest: String) throws -> Data? {
            try inner.artifactRecord(session: session, digest: digest)
        }
        func publishArtifact(session: SessionID, as identity: WriterIdentity, kind: String, operationID: OperationID?, bytes: Data) throws -> ArtifactRef {
            try inner.publishArtifact(session: session, as: identity, kind: kind, operationID: operationID, bytes: bytes)
        }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try inner.append(record, as: identity)
        }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            if let failWhen, failWhen(records) { throw StoreError.integrity("injected commit failure") }
            try inner.appendBatch(records, as: identity)
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }
        func sessions() throws -> [SessionID] { try inner.sessions() }
        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try inner.claimWriterOwnership(session: session, writer: writer)
        }
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try inner.releaseWriterOwnership(session: session, writer: writer)
        }
        func recoverWriterOwnership(session: SessionID, expectedWriter: String, newWriter: String, authorization: RecoveryAuthorization) throws {
            try inner.recoverWriterOwnership(session: session, expectedWriter: expectedWriter, newWriter: newWriter, authorization: authorization)
        }
        func openArtifactSpill(session: SessionID, as identity: WriterIdentity, kind: String, stream: String, requestedBytes: Int64) throws -> SpillHandle {
            try inner.openArtifactSpill(session: session, as: identity, kind: kind, stream: stream, requestedBytes: requestedBytes)
        }
        func publishArtifactFromFile(session: SessionID, as identity: WriterIdentity, kind: String, spill: SpillHandle, operationID: OperationID? = nil) throws -> ArtifactRef {
            try inner.publishArtifactFromFile(session: session, as: identity, kind: kind, spill: spill, operationID: operationID)
        }
        func releaseArtifactSpill(as identity: WriterIdentity, handle: SpillHandle) throws {
            try inner.releaseArtifactSpill(as: identity, handle: handle)
        }
    }

    // MARK: - Scenario A: queue crash/reopen (order, IDs, acks, no duplicates)

    @Test("A: queue crash/reopen restores order, IDs and acks; redispatch happens exactly once per entry")
    func queueCrashReopen() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-a")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        // Generation 1: run-1 in flight (gated forever), q2 + q3 queued.
        var store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let gate1 = GatedTransport()
        let (stream1, _) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate1.gate = stream1
        var ids1 = DeterministicIDSource(prefix: "a1")
        let actor1 = try SessionActor(
            state: try Self.idleState(session: session, mode: .workspace, permissive: true),
            ids: ids1, clock: SystemClock(), transport: gate1,
            executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer.writer)
        await actor1.submitText(commandID: CommandID("run-1"), text: "first", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.activeRequest != nil }, "run-1 requesting")
        await actor1.submitText(commandID: CommandID("q-2"), text: "second", kind: .steer, sealed: false)
        await actor1.submitText(commandID: CommandID("q-3"), text: "third", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.queue.count == 2 }, "q2+q3 queued")
        let before = await actor1.currentState()
        let idsBefore = before.queue.map(\.entryID)
        #expect(before.queue.map(\.commandID) == [CommandID("q-2"), CommandID("q-3")], "positional order preserved")
        #expect(before.admittedCommands[CommandID("q-2")] != nil && before.admittedCommands[CommandID("q-3")] != nil, "queued entries acked")
        #expect(gate1.invocations.count == 1, "only run-1 sent before the crash")
        // Terminate mid-flight (process death: drop the actor, close the handle).
        try store.close()
        // Generation 2: reopen through the single authoritative sequence,
        // then drain exactly once per entry.
        store = try Self.tempStore(at: dir)
        let transport2 = ScriptedTransport()
        transport2.script = [
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        var ids2 = DeterministicIDSource(prefix: "a2")
        let (actor2, report2) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids2, clock: SystemClock(),
            transport: transport2, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect(report2.queueEntries == 2, "both queued entries restored, got \(report2.queueEntries)")
        #expect(!report2.blocked, "clean queue crash is not blocking")
        let after = await actor2.currentState()
        #expect(after.queue.map(\.entryID) == idsBefore, "entry IDs stable across reopen")
        #expect(after.admittedCommands[CommandID("q-2")] != nil && after.admittedCommands[CommandID("q-3")] != nil, "acks survive reopen")
        #expect(transport2.invocations.isEmpty, "reopen dispatches nothing by itself")
        await actor2.submitText(commandID: CommandID("run-4"), text: "drain", kind: .followUp, sealed: false)
        try await Self.awaitState(actor2, {
            if case .completed = $0.phase, transport2.invocations.count == 3,
               $0.queue.allSatisfy({ $0.state == .admittedToHistory }) { return true }
            return false
        }, "drained exactly once per entry")
        let drained = await actor2.currentState()
        #expect(drained.queue.allSatisfy({ $0.state == .admittedToHistory }), "every entry completed exactly once; run-1 never resent or recompleted")
        try store.close()
        _ = ids1
    }

    // MARK: - Scenario B: unknown delivery (held head, no resend, reconcile durability)

    @Test("B: unknown delivery holds the head; resume never resends; reconcile survives reopen and releases only the intended entry")
    func unknownDeliveryNoResend() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-b")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        // Generation 1: run-0 in flight (gated); q1 + q2 queued behind it.
        // Releasing run-0 pops q1, whose dispatch stays gated (link commits,
        // delivery never confirmed); q3 queues behind q1's run. Terminate.
        var store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let gate1 = GatedTransport()
        let (stream1, cont1) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate1.gate = stream1
        var ids1 = DeterministicIDSource(prefix: "b1")
        let actor1 = try SessionActor(
            state: try Self.idleState(session: session, mode: .workspace, permissive: true),
            ids: ids1, clock: SystemClock(), transport: gate1,
            executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer.writer)
        await actor1.submitText(commandID: CommandID("run-0"), text: "bootstrap", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.activeRequest != nil }, "run-0 requesting")
        await actor1.submitText(commandID: CommandID("q-1"), text: "first queued", kind: .followUp, sealed: false)
        await actor1.submitText(commandID: CommandID("q-2"), text: "second queued", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.queue.count == 2 }, "q1+q2 queued")
        cont1.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0))))
        // Await the invocation itself (the entry state commits before the
        // transport call records — awaiting state alone would race it).
        for _ in 0..<20_000 {
            if gate1.invocations.count == 2 { break }
            await Task.yield()
        }
        #expect(gate1.invocations.count == 2, "run-0 sent, then q1 sent (link commits, delivery never confirmed)")
        #expect((await actor1.currentState()).queue.first?.state == .admittedToHistory, "q1 dispatched into the gate")
        await actor1.submitText(commandID: CommandID("q-3"), text: "third queued", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.queue.count == 3 }, "q3 queued behind q1's run")
        try store.close()
        // Generation 2: q1 held-unknown head; resume resends nothing and
        // nothing overtakes; reconcile releases only q1; terminate.
        store = try Self.tempStore(at: dir)
        let gate2 = GatedTransport()
        let (stream2, _) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate2.gate = stream2
        var ids2 = DeterministicIDSource(prefix: "b2")
        let (actor2, report2) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids2, clock: SystemClock(),
            transport: gate2, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect(report2.blocked && report2.queueHeld, "unknown delivery blocks")
        let held = await actor2.currentState()
        #expect(held.queue.first?.state == .heldUnknown, "q1 held-unknown head")
        #expect(held.queue.dropFirst().allSatisfy({ $0.state == .queued }), "q2+q3 still queued behind")
        await actor2.resumeQueue()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(gate2.invocations.isEmpty, "resume never resends an unknown delivery")
        #expect((await actor2.currentState()).queue.dropFirst().allSatisfy({ $0.state == .queued }), "no overtake while the head is held")
        await actor2.reconcileQueue(entryID: held.queue.first!.entryID)
        try await Self.awaitState(actor2, { $0.queue.first?.state == .queued }, "q1 requeued (intended entry only)")
        #expect((await actor2.currentState()).queue.dropFirst().allSatisfy({ $0.state == .queued }), "q2+q3 untouched by q1's reconciliation")
        try store.close()
        // Generation 3: the reconcile decision survived the second reopen —
        // q1 is queued (not unknown). A fresh run drains the queue in order,
        // each entry dispatched and completed exactly once.
        store = try Self.tempStore(at: dir)
        let transport3 = ScriptedTransport()
        transport3.script = [
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        var ids3 = DeterministicIDSource(prefix: "b3")
        let (actor3, _) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids3, clock: SystemClock(),
            transport: transport3, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect((await actor3.currentState()).queue.first?.state == .queued, "reconcile decision survived the second reopen")
        await actor3.submitText(commandID: CommandID("run-4"), text: "drain", kind: .followUp, sealed: false)
        try await Self.awaitState(actor3, {
            if case .completed = $0.phase, transport3.invocations.count == 4,
               $0.queue.allSatisfy({ $0.state == .admittedToHistory }) { return true }
            return false
        }, "drained exactly once per entry")
        #expect(transport3.invocations.count == 4, "run-4, q1, q2, q3 dispatched exactly once each, got \(transport3.invocations.count)")
        let drained = await actor3.currentState()
        #expect(drained.queue.allSatisfy({ $0.state == .admittedToHistory }), "each entry completed exactly once")
        try store.close()
        _ = ids1
    }

    // MARK: - Scenario E: notice recovery before the next provider request

    @Test("E: crash after durable inverse result but before notice recovers exactly once; next request carries it")
    func noticeRecoveryBeforeNextRequest() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-e")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .trustedExec, permissive: true).epoch
        // Seed the crash shape through real records: group + intent + done
        // result, but no disposition (died after the result commit).
        // Terminating here is the crash; recovery happens on reopen.
        do {
            let store = try Self.tempStore(at: dir)
            try store.claimWriterOwnership(session: session, writer: writer.writer)
            let member = ChangeGroupMember(
                operationID: OperationID("eff-9/c1"), callID: "c1",
                path: "e.txt", grantedRoot: "/tmp/ws",
                created: false, beforeHash: "b0", afterHash: "a0",
                deviceBefore: 1, inodeBefore: 2, modeBefore: "644",
                preimageDigest: "b0", emptyOriginal: false,
                deviceAfter: 1, inodeAfter: 3, modeAfter: "644",
                receiptStatus: "success", receiptSummary: "edited e.txt")
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
                    outcome: "applied: restored e.txt"),
            ], as: writer)
            try store.close()
        }
        // Reopen through the single authoritative sequence: the sweep
        // recovers disposition + notice before the actor is returned, so no
        // provider request can precede the notice.
        let store = try Self.tempStore(at: dir)
        let transport = ScriptedTransport()
        transport.script = [ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0))]
        var ids = DeterministicIDSource(prefix: "e1")
        let (actor, report) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .trustedExec,
            as: writer.writer, ids: &ids, clock: SystemClock(),
            transport: transport, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect(report.journalsRecovered == 1 && report.journalsUnrecovered == 0, "boundary-5 journal recovered, got \(report)")
        #expect(!report.blocked)
        let recovered = await actor.currentState()
        #expect(recovered.undoDispositions.count == 1 && recovered.undoDispositions[0].outcome == .completed)
        await actor.submitText(commandID: CommandID("run-2"), text: "continue", kind: .followUp, sealed: false)
        try await Self.awaitState(actor, {
            if case .completed = $0.phase { return true }
            return false
        }, "run-2 completed")
        #expect(transport.invocations.count == 1, "exactly one provider request after recovery")
        let log = try Self.storeRecords(store, session)
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
        // Exactly-once: a second sweep finds nothing pending.
        let journaled = try Self.storeRecords(store, session).filter {
            if case .undoDisposition(let d) = $0 { return d.undoCommandID == "undo-9" }
            return false
        }
        #expect(journaled.count == 1, "exactly one disposition committed")
        try store.close()
    }

    @Test("E2: live disposition-batch commit failure integrity-stops; reopen holds the unsettled inverse with no replay")
    func dispositionCommitFailureRecovers() async throws {
        // The disposition always commits atomically with its final inverse
        // result, so a commit failure can never strand a result without its
        // notice (boundary 5 is unreachable by crash timing). What it CAN
        // strand is the LAST intent without its result — and the system
        // must hold that honestly instead of replaying or dropping it.
        for failNotice in [false, true] {
            let dir = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let session = SessionID(failNotice ? "s-d3-e2n" : "s-d3-e2d")
            let writer = WriterIdentity(session: session, writer: "w-d3")
            let epoch = try Self.idleState(session: session, mode: .trustedExec, permissive: true).epoch
            let raw = try Self.tempStore(at: dir)
            try raw.claimWriterOwnership(session: session, writer: writer.writer)
            let resolver = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
            let executor = NativeToolExecutor(resolver: resolver, store: raw, sessionID: session, writer: writer, execGrant: false)
            try "live1\n".write(to: dir.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
            try "live1\n".write(to: dir.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
            let hM = Self.sha("live1\n")
            let transport = ScriptedTransport()
            transport.script = [
                ProviderResponse(requestID: RequestID("s"), generation: Revision(0), outcome: .textDeltaComplete(
                    text: "batch", toolProposals: [
                        ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"m.txt\",\"expectedHash\":\"\(hM)\",\"old_string\":\"live1\",\"new_string\":\"live2\"}"),
                        ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"n.txt\",\"expectedHash\":\"\(hM)\",\"old_string\":\"live1\",\"new_string\":\"live2\"}"),
                    ], isFinal: false)),
                ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ]
            // Fail the atomic disposition+notice batch (both predicates hit
            // the same batch: disposition and notice commit together).
            let failing = FailingStore(raw) { records in
                records.contains {
                    if failNotice {
                        if case .transcriptAppended(.workspaceChangeNotice) = $0 { return true }
                    } else if case .undoDisposition = $0 { return true }
                    return false
                }
            }
            var ids = DeterministicIDSource(prefix: "e2")
            let failingActor = try SessionActor(
                state: try Self.idleState(session: session, mode: .trustedExec, permissive: true),
                ids: DeterministicIDSource(prefix: "e2"), clock: SystemClock(), transport: transport,
                executor: executor, store: failing,
                approvals: ScriptedApprovals(), writer: writer.writer,
                undoValidator: FilesystemUndoValidator(resolver: resolver),
                inverseApplier: FilesystemUndoApplier(resolver: resolver, store: raw, session: session, writer: writer))
            await failingActor.submitText(commandID: CommandID("run-1"), text: "edit", kind: .followUp, sealed: false)
            try await Self.awaitState(failingActor, {
                if case .completed = $0.phase { return true }
                return false
            }, "batch completed")
            let (batchPage, _) = try raw.records(session: session, since: 0, limit: 100_000)
            let groups = reconcileChangeGroups(batchPage.map(\.record))
            let group = try #require(groups.first)
            var preimages: [String: Bool] = [:]
            for member in group.members {
                if let digest = member.preimageDigest {
                    preimages[digest] = (try raw.artifactRecord(session: session, digest: digest)) != nil
                }
            }
            _ = await failingActor.runUndo(group: group, preimagesAvailable: preimages)
            try await Self.awaitState(failingActor, {
                if case .failed = $0.phase { return true }
                return false
            }, "integrity stop on commit failure")
            let (failPage, _) = try raw.records(session: session, since: 0, limit: 100_000)
            let failLog = failPage.map(\.record)
            #expect(!failLog.contains(where: {
                if case .undoDisposition = $0 { return true }
                return false
            }), "failed batch commits no disposition")
            #expect(!failLog.contains(where: {
                if case .transcriptAppended(.workspaceChangeNotice) = $0 { return true }
                return false
            }), "failed batch publishes no notice")
            // Both inverses ran (real files restored); only the FIRST has a
            // durable result — the last intent stands unknown and held.
            #expect(try String(contentsOf: dir.appendingPathComponent("m.txt"), encoding: .utf8) == "live1\n")
            #expect(try String(contentsOf: dir.appendingPathComponent("n.txt"), encoding: .utf8) == "live1\n")
            #expect(failLog.contains(where: {
                if case .operationResult(let ref, _) = $0 { return ref.operationID.raw.hasPrefix("undo/") && ref.state == .done }
                return false
            }), "first inverse result durable")
            try raw.close()
            // Clean reopen through the authoritative sequence: the unsettled
            // inverse holds (no auto-replay, no silent settle), the sweep
            // correctly finds nothing finalizable, and the files are
            // untouched by recovery.
            let clean = try Self.tempStore(at: dir)
            let intentsBefore = try Self.undoIntents(clean, session).count
            var ids2 = DeterministicIDSource(prefix: "e2r")
            let (actor2, report) = try await reopenHeadlessSession(
                store: clean, session: session, epoch: epoch, trustMode: .trustedExec,
                as: writer.writer, ids: &ids2, clock: SystemClock(),
                transport: ScriptedTransport(), executor: executor,
                approvals: ScriptedApprovals(),
                undoValidator: FilesystemUndoValidator(resolver: resolver),
                inverseApplier: FilesystemUndoApplier(resolver: resolver, store: clean, session: session, writer: writer))
            #expect(report.unknownOperations == 1, "unsettled inverse reseeded (failNotice=\(failNotice))")
            #expect(report.journalsRecovered == 0 && report.journalsUnrecovered == 0, "nothing finalizable: no false recovery")
            #expect(report.blocked, "unknown inverse blocks")
            #expect(try Self.undoIntents(clean, session).count == intentsBefore, "recovery replays no inverse")
            #expect(try String(contentsOf: dir.appendingPathComponent("m.txt"), encoding: .utf8) == "live1\n", "no wrong-file overwrite on reopen")
            // Explicit reconciliation of the ambiguous inverse releases the
            // hold without a second mutation.
            let unknownOp = try #require((await actor2.currentState()).unresolvedOperations.first?.operationID)
            await actor2.acknowledgeUnknown(operationID: unknownOp, determination: "operator-accepted-risk: inspected, restored bytes verified")
            try await Self.awaitState(actor2, { $0.unresolvedOperations.isEmpty }, "unknown acknowledged")
            try clean.close()
        }
    }

    // MARK: - Scenario C: stale attachment (snapshot survives, head holds, fix redispatches)

    @Test("C: stale attachment snapshot survives reopen; dispatch blocked with no overtake; fix redispatches with reconsent")
    func staleAttachmentReopenBlocksHead() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-c")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let idle = try Self.idleState(session: session, mode: .workspace, permissive: true)
        let epoch = idle.epoch
        var store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let resolver = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
        let capture = AttachmentCaptureService(resolver: resolver)
        let grant = AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false)
        try "v1\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let snap = try capture.capture(
            relativePath: "f.txt", lineRange: nil, intent: "mention",
            epochID: epoch.epochID, routeGrant: grant)
        // Generation 1: run-0 gated in flight; qa (snapshotted) + qb queued.
        let gate1 = GatedTransport()
        let (stream1, _) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate1.gate = stream1
        let validator = FilesystemAttachmentValidator(resolver: resolver)
        var ids1 = DeterministicIDSource(prefix: "c1")
        let actor1 = try SessionActor(
            state: try Self.idleState(session: session, mode: .workspace, permissive: true),
            ids: ids1, clock: SystemClock(), transport: gate1,
            executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer.writer,
            attachmentValidator: validator)
        await actor1.submitText(commandID: CommandID("run-0"), text: "bootstrap", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.activeRequest != nil }, "run-0 requesting")
        await actor1.submitTextWithAttachments(commandID: CommandID("q-a"), text: "review f", kind: .followUp, sealed: false, attachments: [snap])
        await actor1.submitText(commandID: CommandID("q-b"), text: "behind", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.queue.count == 2 }, "qa+qb queued")
        // Mutate the file, then crash before run-0 completes.
        try "v2\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try store.close()
        // Generation 2: reopen with the real validator. A fresh run
        // completes; the pop validates qa against the mutated file and
        // holds the head stale — qb never overtakes.
        store = try Self.tempStore(at: dir)
        let transport2 = ScriptedTransport()
        transport2.script = [
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        var ids2 = DeterministicIDSource(prefix: "c2")
        let (actor2, _) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids2, clock: SystemClock(),
            transport: transport2, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals(),
            attachmentValidator: FilesystemAttachmentValidator(resolver: resolver))
        let reopened = await actor2.currentState()
        let qaBefore = try #require(reopened.queue.first(where: { $0.commandID == CommandID("q-a") }))
        #expect(qaBefore.attachments.first?.contentHash == snap.contentHash, "original snapshot survives reopen byte-identically")
        await actor2.submitText(commandID: CommandID("run-1"), text: "pop", kind: .followUp, sealed: false)
        try await Self.awaitState(actor2, { $0.queueHeld }, "stale head holds")
        for _ in 0..<2_000 { await Task.yield() }
        let held = await actor2.currentState()
        #expect(held.queue.first(where: { $0.commandID == CommandID("q-a") })?.state == .held, "stale head held")
        #expect(held.queue.first(where: { $0.commandID == CommandID("q-b") })?.state == .queued, "qb queued behind, never overtaking")
        #expect(transport2.invocations.count == 1, "only run-1 sent; the stale head dispatched nothing")
        // Fix path: replacement preserves the hold (never auto-dispatches)
        // and refreshes consent to the live epoch; resume unholds; the next
        // completion validates fresh and dispatches.
        let fresh = try capture.capture(
            relativePath: "f.txt", lineRange: nil, intent: "mention",
            epochID: epoch.epochID, routeGrant: grant)
        #expect(fresh.contentHash != snap.contentHash, "fresh capture sees the mutation")
        await actor2.replaceEntryAttachments(entryID: qaBefore.entryID, snapshots: [fresh])
        let replaced = await actor2.currentState()
        #expect(replaced.queueHeld, "replacement never auto-dispatches")
        #expect(replaced.queue.first(where: { $0.commandID == CommandID("q-a") })?.state == .held, "still held after replace")
        await actor2.resumeQueue()
        try await Self.awaitState(actor2, { !$0.queueHeld }, "resumed-unfixed")
        await actor2.submitText(commandID: CommandID("run-2"), text: "redrive", kind: .followUp, sealed: false)
        try await Self.awaitState(actor2, {
            if case .completed = $0.phase, transport2.invocations.count == 4,
               $0.queue.allSatisfy({ $0.state == .admittedToHistory }) { return true }
            return false
        }, "drained after fix")
        #expect(transport2.invocations.count == 4, "run-1, run-2, qa, qb each sent exactly once, got \(transport2.invocations.count)")
        let drained = await actor2.currentState()
        #expect(drained.queue.allSatisfy({ $0.state == .admittedToHistory }), "fixed head and follower both complete")
        try store.close()
        _ = ids1
    }

    // MARK: - Scenario D: partial native undo across reopen

    @Test("D: partial native undo reopens with exact partial disposition, no repeated inverses, user edits retained")
    func partialUndoReopenKeepsPartial() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-d")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let idle = try Self.idleState(session: session, mode: .trustedExec, permissive: true)
        let epoch = idle.epoch
        var store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let resolver = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        try "m1\n".write(to: dir.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try "n1\n".write(to: dir.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let hM1 = Self.sha("m1\n")
        let hN1 = Self.sha("n1\n")
        let transport1 = ScriptedTransport()
        transport1.script = [
            ProviderResponse(requestID: RequestID("s"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "batch", toolProposals: [
                    ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"m.txt\",\"expectedHash\":\"\(hM1)\",\"old_string\":\"m1\",\"new_string\":\"m2\"}"),
                    ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"n.txt\",\"expectedHash\":\"\(hN1)\",\"old_string\":\"n1\",\"new_string\":\"n2\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        var ids1 = DeterministicIDSource(prefix: "d1")
        // Faulting applier: the FIRST inverse (n.txt, reverse-batch head)
        // applies for real; the SECOND (m.txt) fails cleanly.
        let realApplier = FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer)
        final class FailPathApplier: UndoInverseApplier, @unchecked Sendable {
            let real: FilesystemUndoApplier
            let failSuffix: String
            init(real: FilesystemUndoApplier, failSuffix: String) {
                self.real = real
                self.failSuffix = failSuffix
            }
            func apply(_ inverse: UndoInverse) async -> UndoInverseOutcome {
                if inverse.path.hasSuffix(failSuffix) {
                    return .failed(error: "injected clean failure", possiblyMutated: false)
                }
                return await real.apply(inverse)
            }
        }
        let actor1 = try SessionActor(
            state: try Self.idleState(session: session, mode: .trustedExec, permissive: true),
            ids: ids1, clock: SystemClock(), transport: transport1,
            executor: executor, store: store,
            approvals: ScriptedApprovals(), writer: writer.writer,
            undoValidator: FilesystemUndoValidator(resolver: resolver),
            inverseApplier: FailPathApplier(real: realApplier, failSuffix: "m.txt"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "edit both", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, {
            if case .completed = $0.phase { return true }
            return false
        }, "batch completed")
        let groups = reconcileChangeGroups(try Self.storeRecords(store, session))
        #expect(groups.count == 1 && groups[0].members.count == 2, "eligible native group recorded")
        let group = groups[0]
        var preimages: [String: Bool] = [:]
        for member in group.members {
            if let digest = member.preimageDigest {
                preimages[digest] = (try store.artifactRecord(session: session, digest: digest)) != nil
            }
        }
        let command = await actor1.runUndo(group: group, preimagesAvailable: preimages)
        for _ in 0..<20_000 {
            if (await actor1.currentState()).undoDispositions.contains(where: { $0.undoCommandID == command }) { break }
            await Task.yield()
        }
        let disposition = try #require((await actor1.currentState()).undoDispositions.first(where: { $0.undoCommandID == command }))
        #expect(disposition.outcome == .partial, "applied + clean failure is partial, got \(disposition)")
        #expect(try String(contentsOf: dir.appendingPathComponent("n.txt"), encoding: .utf8) == "n1\n", "n restored")
        #expect(try String(contentsOf: dir.appendingPathComponent("m.txt"), encoding: .utf8) == "m2\n", "m untouched by the failed leg")
        let intentsBefore = try Self.undoIntents(store, session).count
        // User edit after the partial undo, then crash (drop + close).
        try "m-user\n".write(to: dir.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try store.close()
        // Reopen through the single authoritative sequence with the REAL
        // applier: the partial journal replays nothing automatically.
        store = try Self.tempStore(at: dir)
        var ids2 = DeterministicIDSource(prefix: "d2")
        let (actor2, report2) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .trustedExec,
            as: writer.writer, ids: &ids2, clock: SystemClock(),
            transport: ScriptedTransport(), executor: executor,
            approvals: ScriptedApprovals(),
            undoValidator: FilesystemUndoValidator(resolver: resolver),
            inverseApplier: FilesystemUndoApplier(resolver: resolver, store: store, session: session, writer: writer))
        #expect(report2.dispositionsReseeded == 1, "partial disposition reseeded")
        #expect(report2.journalsRecovered == 0 && report2.journalsUnrecovered == 0, "dispositioned journal needs no sweep")
        #expect(!report2.blocked, "clean partial failure holds nothing")
        #expect(try Self.undoIntents(store, session).count == intentsBefore, "zero automatic repeated inverses across reopen")
        #expect(try String(contentsOf: dir.appendingPathComponent("m.txt"), encoding: .utf8) == "m-user\n", "user edit retained")
        #expect(try String(contentsOf: dir.appendingPathComponent("n.txt"), encoding: .utf8) == "n1\n", "restored file intact")
        let log = try Self.storeRecords(store, session)
        #expect(log.contains(where: {
            if case .transcriptAppended(.workspaceChangeNotice(let n)) = $0 { return n.undoCommandID == command && n.outcome == .partial }
            return false
        }), "honest partial notice durable")
        // Duplicate command answers from the reseeded journal, no mutation.
        await actor2.applyExternalEvent(.undoRun(
            undoCommandID: command, group: group,
            preimagesAvailable: preimages, atMillis: 9_000_000))
        for _ in 0..<2_000 { await Task.yield() }
        #expect(try Self.undoIntents(store, session).count == intentsBefore, "duplicate performs no second inverse")
        try store.close()
        _ = ids1
    }

    // MARK: - Scenario F: combined holds, explicit reconciliation, ordered recovery

    @Test("F: combined holds block every bypass; explicit reconciliation releases exactly one next action")
    func combinedHoldsReconcileInOrder() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-f")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let idle = try Self.idleState(session: session, mode: .workspace, permissive: true)
        let epoch = idle.epoch
        var store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let resolver = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
        try "A1\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let hA1 = Self.sha("A1\n")
        let capture = AttachmentCaptureService(resolver: resolver)
        let grant = AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false)
        let snap = try capture.capture(
            relativePath: "a.txt", lineRange: nil, intent: "mention",
            epochID: epoch.epochID, routeGrant: grant)
        let gate = GatedTransport()
        let (stream, _) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let gated = B0ActorIntegrationTests.GatedExecutor()
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        // Provider answers (scripted); the TOOL batch gates inside the
        // native-shaped executor so cancel can strand it mid-flight.
        // run-1 carries the edit proposal; the final ends the turn.
        let provider = ScriptedTransport()
        provider.script = [
            ProviderResponse(requestID: RequestID("s"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "batch", toolProposals: [
                    ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\",\"expectedHash\":\"\(hA1)\",\"old_string\":\"A1\",\"new_string\":\"A2\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        let ids1 = DeterministicIDSource(prefix: "f1")
        let actor1 = try SessionActor(
            state: try Self.idleState(session: session, mode: .workspace, permissive: true),
            ids: ids1, clock: SystemClock(), transport: provider,
            executor: gated, store: store, approvals: approvals,
            writer: writer.writer)
        // Batch 1 dispatched, then cancelled while gated: the cancel
        // retains an unknown marker (resolvable via the explicit
        // acknowledgment path, including across reopen).
        await actor1.submitText(commandID: CommandID("run-1"), text: "edit a", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, {
            if case .executing = $0.phase { return true }
            return false
        }, "batch-1 executing")
        await actor1.cancel()
        let wall = UInt64(Date().timeIntervalSince1970 * 1000)
        await actor1.tick(at: wall + cancelGraceMillis + 1_000)
        try await Self.awaitState(actor1, {
            if case .interrupted = $0.phase { return true }
            return false
        }, "cancel settled interrupted")
        let effID = try #require(gated.calls.first?.reservation.effectID)
        await actor1.completeEffect(effID, outcome: .perCall(ExecutorResult(
            receipt: ExecutorReceipt(callID: "mix", status: "cancelled", summary: "late"),
            calls: [ToolCallOutcome(callID: "c1", status: "cancelled", summary: "late", data: "x", started: true)])))
        try await Self.awaitState(actor1, { !$0.unresolvedOperations.isEmpty }, "unknown marker retained")
        // Queued follow-up with a snapshot + a tail behind it; then the
        // attachment file changes and a settled undo journal is seeded.
        await actor1.submitTextWithAttachments(commandID: CommandID("q-f"), text: "fix f", kind: .followUp, sealed: false, attachments: [snap])
        await actor1.submitText(commandID: CommandID("q-t"), text: "tail", kind: .followUp, sealed: false)
        try await Self.awaitState(actor1, { $0.queue.count == 2 }, "follow-up + tail queued")
        try "A2\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let member = ChangeGroupMember(
            operationID: OperationID("eff-9/c1"), callID: "c1",
            path: "uf.txt", grantedRoot: dir.path,
            created: false, beforeHash: "b0", afterHash: "a0",
            deviceBefore: 1, inodeBefore: 2, modeBefore: "644",
            preimageDigest: "b0", emptyOriginal: false,
            deviceAfter: 1, inodeAfter: 3, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "edited uf.txt")
        let groupF = ChangeGroup(
            groupID: "chg-f", runID: RunID("run-9"), effectID: EffectID("eff-9"),
            members: [member], hadExecProposals: false, hadReadProposals: false)
        let inverseF = undoInverseID(undoCommandID: "undo-f", groupID: groupF.groupID, operationID: member.operationID)
        try store.appendBatch([
            .changeGroup(groupF),
            .operationIntent(OperationRef(
                operationID: OperationID(inverseF), callID: inverseF,
                state: .intent, mutating: true)),
            .operationResult(
                OperationRef(
                    operationID: OperationID(inverseF), callID: inverseF,
                    state: .done, mutating: true),
                outcome: "applied: restored uf.txt"),
        ], as: writer)
        try store.close()
        // Reopen: unknown marker + unrecovered settled journal block.
        store = try Self.tempStore(at: dir)
        let gate2 = GatedTransport()
        let (stream2, _) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate2.gate = stream2
        var ids2 = DeterministicIDSource(prefix: "f2")
        let (actor2, report) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids2, clock: SystemClock(),
            transport: gate2, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals(),
            attachmentValidator: FilesystemAttachmentValidator(resolver: resolver))
        #expect(report.blocked, "combined holds block")
        #expect(report.unknownOperations == 1, "cancel-ambiguous marker reseeded")
        #expect(report.journalsUnrecovered == 1, "settled journal cannot finalize while held")
        #expect(report.queueHeld)
        // Every bypass attempt fails without external effects.
        await actor2.resumeQueue()
        for _ in 0..<1_000 { await Task.yield() }
        #expect(gate2.invocations.isEmpty, "resume dispatches nothing while blocked")
        let qfID = try #require((await actor2.currentState()).queue.first(where: { $0.commandID == CommandID("q-f") })?.entryID)
        await actor2.retargetQueueEntry(entryID: qfID)
        for _ in 0..<1_000 { await Task.yield() }
        #expect((await actor2.currentState()).queueHeld, "retarget never releases a hold")
        #expect(gate2.invocations.isEmpty, "retarget dispatches nothing")
        await actor2.requestCheckpoint()
        for _ in 0..<1_000 { await Task.yield() }
        let afterCheckpoint = await actor2.currentState()
        #expect(afterCheckpoint.unresolvedOperations.count == 1, "checkpoint refused while unknown (markers intact)")
        #expect(gate2.invocations.isEmpty, "checkpoint dispatches nothing")
        await actor2.submitText(commandID: CommandID("q-new"), text: "new", kind: .followUp, sealed: false)
        for _ in 0..<1_000 { await Task.yield() }
        let afterSubmit = await actor2.currentState()
        #expect(afterSubmit.queue.contains(where: { $0.commandID == CommandID("q-new") && $0.state == .held }), "new admission queues held, never dispatched")
        #expect(gate2.invocations.isEmpty, "new admission dispatches nothing while markers stand")
        let zMember = ChangeGroupMember(
            operationID: OperationID("eff-z/c1"), callID: "c1", path: "z.txt",
            grantedRoot: dir.path, created: true, beforeHash: nil, afterHash: "z",
            deviceBefore: nil, inodeBefore: nil, modeBefore: nil,
            preimageDigest: nil, emptyOriginal: false,
            deviceAfter: 9, inodeAfter: 9, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "write z.txt")
        let zGroup = ChangeGroup(
            groupID: "chg-z", runID: RunID("r"), effectID: EffectID("e"),
            members: [zMember], hadExecProposals: false, hadReadProposals: false)
        let intentsBefore = try Self.undoIntents(store, session).count
        await actor2.runUndo(group: zGroup, preimagesAvailable: [:])
        for _ in 0..<1_000 { await Task.yield() }
        #expect((await actor2.currentState()).pendingUndo == nil, "undo refused while markers stand")
        #expect(try Self.undoIntents(store, session).count == intentsBefore, "refused undo stages no inverses")
        // Explicit reconciliation, in order: acknowledge the unknown,
        // finalize the settled journal, fix the stale snapshot, resume.
        let unknownOp = try #require((await actor2.currentState()).unresolvedOperations.first?.operationID)
        await actor2.acknowledgeUnknown(operationID: unknownOp, determination: "operator-accepted-risk: inspected, undispatched")
        try await Self.awaitState(actor2, { $0.unresolvedOperations.isEmpty }, "markers discharged by recorded decision")
        let acked = try Self.storeRecords(store, session).contains(where: {
            if case .acknowledgedUnresolved(let ack) = $0 { return ack.operationIDs == [unknownOp] }
            return false
        })
        #expect(acked, "acknowledgment is durable")
        let recovery = try await actor2.recoverUndoJournal()
        #expect(recovery.recovered.count == 1 && recovery.unrecovered.isEmpty, "settled journal finalizes once quiescent")
        let fresh = try capture.capture(
            relativePath: "a.txt", lineRange: nil, intent: "mention",
            epochID: epoch.epochID, routeGrant: grant)
        await actor2.replaceEntryAttachments(entryID: qfID, snapshots: [fresh])
        await actor2.resumeQueue()
        try await Self.awaitState(actor2, { !$0.queueHeld }, "holds released in order")
        try store.close()
        // Final generation: exactly one next action proceeds, no duplicates.
        store = try Self.tempStore(at: dir)
        let transport3 = ScriptedTransport()
        transport3.script = [
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("s"), generation: Revision(0)),
        ]
        var ids3 = DeterministicIDSource(prefix: "f3")
        let (actor3, report3) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids3, clock: SystemClock(),
            transport: transport3, executor: ScriptedExecutor(),
            approvals: ScriptedApprovals(),
            attachmentValidator: FilesystemAttachmentValidator(resolver: resolver))
        #expect(!report3.blocked, "reconciled session is dispatchable")
        await actor3.submitText(commandID: CommandID("run-n"), text: "next", kind: .followUp, sealed: false)
        try await Self.awaitState(actor3, {
            if case .completed = $0.phase, transport3.invocations.count == 4,
               $0.queue.filter({ $0.state == .admittedToHistory }).count >= 3 { return true }
            return false
        }, "drained")
        let drained = await actor3.currentState()
        #expect(drained.queue.filter({ $0.state == .admittedToHistory }).count >= 3, "follow-up, tail and new entry all complete in order, got \(drained.queue.map(\.state))")
        #expect(transport3.invocations.count == 4, "run-n, q-f, q-t, q-new dispatched exactly once each, got \(transport3.invocations.count)")
        try store.close()
    }

    // MARK: - Counterfactuals: each recovery step is load-bearing

    @Test("acknowledgeUnknown discharges the marker, records the decision, and reopen reseeds no hold")
    func acknowledgeUnknownPure() throws {
        var ids = DeterministicIDSource(prefix: "ak")
        let op = OperationID("eff-9/c9")
        let base = try ActorFixtures.idleState(mode: .workspace, permissive: true)
        let marked = base.replacing(unresolvedOperations: [
            OperationRef(operationID: op, callID: "c9", state: .unknown, mutating: true),
        ])
        // Refused while a run is in flight.
        let run = RunDescriptor(runID: RunID("run-1"), requestID: RequestID("req-1"), revision: Revision(1), startedAtMillis: 1, sealed: false)
        let executing = marked.replacing(phase: .executing, activeRun: run)
        let busy = transition(executing, .acknowledgeUnknown(operationID: op, determination: "x", atMillis: 1), &ids)
        #expect(busy.state.unresolvedOperations.count == 1, "in-flight runs cannot reconcile unknowns")
        // Unknown operation ID: denied, nothing recorded.
        let ghost = transition(marked, .acknowledgeUnknown(operationID: OperationID("ghost"), determination: "x", atMillis: 1), &ids)
        #expect(ghost.state.unresolvedOperations.count == 1)
        #expect(!ghost.records.contains(where: { if case .acknowledgedUnresolved = $0 { return true } else { return false } }))
        // Recorded decision discharges the marker.
        let t = transition(marked, .acknowledgeUnknown(operationID: op, determination: "operator-accepted-risk", atMillis: 2), &ids)
        #expect(t.state.unresolvedOperations.isEmpty, "marker discharged")
        let acks = t.records.compactMap { if case .acknowledgedUnresolved(let a) = $0 { return a } else { return nil } }
        #expect(acks.count == 1 && acks[0].operationIDs == [op], "exactly one durable decision")
        // Reopen with intent + cancelled-pending marker + ack: the marker
        // is classified as explicit-unknown but reseeds NO hold.
        let report = try reconcileOperations([
            .operationIntent(OperationRef(operationID: op, callID: "c9", state: .intent, mutating: true)),
            .cancelledPendingMarker(
                OperationRef(operationID: op, callID: "c9", state: .unknown, mutating: true),
                outcome: "cancelled: pending"),
            .acknowledgedUnresolved(acks[0]),
        ])
        #expect(report.heldOperations.isEmpty, "acknowledged markers never reseed holds, got \(report.heldOperations)")
        #expect(report.explicitUnknown.count == 1, "evidence preserved without the hold")
        // Without the acknowledgment the same journal holds.
        let unacked = try reconcileOperations([
            .operationIntent(OperationRef(operationID: op, callID: "c9", state: .intent, mutating: true)),
            .cancelledPendingMarker(
                OperationRef(operationID: op, callID: "c9", state: .unknown, mutating: true),
                outcome: "cancelled: pending"),
        ])
        #expect(unacked.heldOperations.count == 1, "unacknowledged markers still hold")
    }

    @Test("CF-resume: bypassing resumeSession loses the queue; the helper restores it")
    func bypassResumeLosesQueue() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-cf1")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        let store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let entry = QueueEntry(
            entryID: "q-cf", commandID: CommandID("cmd-cf"), kind: .followUp,
            state: .queued, revision: 1, text: "queued work",
            targetEpochID: epoch.epochID, orderKey: 7, sealed: false)
        try store.appendBatch([.queueAdmitted(entry)], as: writer)
        // Bypass: a fresh actor on the used store sees no queue.
        let bypass = try SessionActor(
            state: try Self.idleState(session: session, mode: .workspace, permissive: true),
            ids: DeterministicIDSource(prefix: "cf"), clock: SystemClock(),
            transport: ScriptedTransport(), executor: ScriptedExecutor(),
            store: store, approvals: ScriptedApprovals(), writer: writer.writer)
        #expect((await bypass.currentState()).queue.isEmpty, "without resume the durable queue is invisible")
        // Authoritative path: the same store reopens with the entry.
        var ids = DeterministicIDSource(prefix: "cf2")
        let (_, report) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: writer.writer, ids: &ids, clock: SystemClock(),
            transport: ScriptedTransport(), executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect(report.queueEntries == 1, "resume restores the queued entry")
        #expect(!report.blocked)
    }

    @Test("CF-sweep: bypassing recoverUndoJournal leaves no disposition or notice")
    func bypassSweepLeavesNoNotice() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-cf2")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        let store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let member = ChangeGroupMember(
            operationID: OperationID("eff-9/c1"), callID: "c1",
            path: "cf.txt", grantedRoot: "/tmp/ws",
            created: false, beforeHash: "b0", afterHash: "a0",
            deviceBefore: 1, inodeBefore: 2, modeBefore: "644",
            preimageDigest: "b0", emptyOriginal: false,
            deviceAfter: 1, inodeAfter: 3, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "edited cf.txt")
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
                outcome: "applied: restored cf.txt"),
        ], as: writer)
        // Bypass: resume without the sweep recovers no disposition/notice.
        var ids = DeterministicIDSource(prefix: "cf")
        let resumed = try resumeSession(
            store: store, session: session, epoch: epoch,
            trustMode: .workspace, as: writer.writer, ids: &ids)
        let manual = try SessionActor(
            state: resumed, ids: ids, clock: SystemClock(),
            transport: ScriptedTransport(), executor: ScriptedExecutor(),
            store: store, approvals: ScriptedApprovals(), writer: writer.writer)
        let idle = await manual.currentState()
        #expect(idle.undoDispositions.isEmpty, "resume alone materializes no disposition")
        #expect(!(try Self.storeRecords(store, session).contains(where: {
            if case .transcriptAppended(.workspaceChangeNotice) = $0 { return true }
            return false
        })), "resume alone publishes no notice")
        // Authoritative path: the sweep materializes both.
        let recovery = try await manual.recoverUndoJournal()
        #expect(recovery.recovered.count == 1, "sweep recovers the settled journal")
    }

    @Test("CF-fencing: a competing writer is refused loudly; the store is untouched")
    func competingWriterRefused() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-cf3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        let store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: "w-first")
        var ids = DeterministicIDSource(prefix: "cf")
        let (actor, _) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: "w-first", ids: &ids, clock: SystemClock(),
            transport: ScriptedTransport(), executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        _ = actor
        let before = try Self.storeRecords(store, session).count
        do {
            var ids2 = DeterministicIDSource(prefix: "cfx")
            _ = try await reopenHeadlessSession(
                store: store, session: session, epoch: epoch, trustMode: .workspace,
                as: "w-second", ids: &ids2, clock: SystemClock(),
                transport: ScriptedTransport(), executor: ScriptedExecutor(),
                approvals: ScriptedApprovals())
            Issue.record("competing writer must throw")
        } catch let error as StoreError {
            guard case .alreadyOwned = error else {
                Issue.record("expected alreadyOwned, got \(error)")
                throw ScriptedError.outOfScript
            }
        }
        #expect(try Self.storeRecords(store, session).count == before, "refused reopen mutates nothing")
        // The legitimate writer still reopens.
        var ids3 = DeterministicIDSource(prefix: "cf3")
        let (_, report3) = try await reopenHeadlessSession(
            store: store, session: session, epoch: epoch, trustMode: .workspace,
            as: "w-first", ids: &ids3, clock: SystemClock(),
            transport: ScriptedTransport(), executor: ScriptedExecutor(),
            approvals: ScriptedApprovals())
        #expect(!report3.blocked)
    }

    @Test("CF-corrupt: a contradictory journal fails reopen loudly with no actor")
    func corruptJournalFailsReopen() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-d3-cf4")
        let writer = WriterIdentity(session: session, writer: "w-d3")
        let epoch = try Self.idleState(session: session, mode: .workspace, permissive: true).epoch
        let store = try Self.tempStore(at: dir)
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let dup = OperationRef(operationID: OperationID("eff-1/c1"), callID: "c1", state: .intent, mutating: true)
        try store.appendBatch([.operationIntent(dup), .operationIntent(dup)], as: writer)
        var ids = DeterministicIDSource(prefix: "cf")
        do {
            _ = try await reopenHeadlessSession(
                store: store, session: session, epoch: epoch, trustMode: .workspace,
                as: writer.writer, ids: &ids, clock: SystemClock(),
                transport: ScriptedTransport(), executor: ScriptedExecutor(),
                approvals: ScriptedApprovals())
            Issue.record("contradictory journal must fail reopen")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected integrity, got \(error)")
                throw ScriptedError.outOfScript
            }
        }
    }
}
