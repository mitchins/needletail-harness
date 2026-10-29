import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport

/// M2-D D0 actor crash matrix: durable queue + dispatch linkage against
/// actual committed record groups and real provider dispatch. Crashes are
/// actor drops (in-memory state gone, store survives); rebuilds replay the
/// durable stream. No sleeps: gates, barriers and scripts only.
struct QueueCrashActorTests {

    /// Failing store: throws on any appendBatch containing a dispatch
    /// linkage record. Proves a pre-linkage commit failure prevents the
    /// provider effect (atomic group never partially commits).
    private final class LinkFailingStore: SessionStore, @unchecked Sendable {
        private let inner: InMemorySessionStore
        var failLinks = false
        init(inner: InMemorySessionStore) { self.inner = inner }
        private func failIfLink(_ records: [DurableRecord]) throws {
            if records.contains(where: { if case .queueDispatched = $0 { return true }; return false }) {
                throw StoreError.integrity("injected linkage-store failure")
            }
        }
        func claimWriterOwnership(session: SessionID, writer: String) throws { try inner.claimWriterOwnership(session: session, writer: writer) }
        func sessions() throws -> [SessionID] { try inner.sessions() }
        func releaseWriterOwnership(session: SessionID, writer: String) throws { try inner.releaseWriterOwnership(session: session, writer: writer) }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try failIfLink([record])
            try inner.append(record, as: identity)
        }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            try failIfLink(records)
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
        func artifactRecord(session: SessionID, digest: String) throws -> Data? { try inner.artifactRecord(session: session, digest: digest) }
        func publishArtifact(session: SessionID, as identity: WriterIdentity, kind: String, operationID: OperationID?, bytes: Data) throws -> ArtifactRef {
            try inner.publishArtifact(session: session, as: identity, kind: kind, operationID: operationID, bytes: bytes)
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

    /// Rebuild state after a crash: replay the durable stream, reconcile
    /// operations + queue, compose over a fresh idle state. Same-session
    /// resume path (cross-session new runs never see this state).
    private static func reopenedState(
        store: InMemorySessionStore, session: SessionID, epoch: EpochDescriptor
    ) throws -> SessionState {
        var stream: [DurableRecord] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            stream += page.map(\.record)
            guard let advanced = next else { break }
            cursor = advanced
        }
        let report = try reconcileOperations(stream)
        let recon = try reconcileQueue(stream)
        var state = SessionState.resumedAfterReopen(
            sessionID: session, epoch: epoch, trustMode: .workspace,
            heldOperations: report.heldOperations)
        var reason = state.heldReason
        if case .none = reason, recon.queueHeld {
            let held = recon.entries.filter { $0.state == .held }.count
            reason = .some(.error("reopen: \(recon.unknownLinks.count) uncompleted dispatch(es), \(held) held"))
        }
        return state.replacing(
            queue: recon.entries,
            queueHeld: state.queueHeld || recon.queueHeld, heldReason: reason,
            admittedCommands: recon.acks)
    }

    private static func makeGatedActor(
        store: InMemorySessionStore, state: SessionState,
        transport: GatedTransport, ids: DeterministicIDSource, writer: String = "q-writer"
    ) throws -> SessionActor<GatedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer)
    }

    private static func makeScriptedActor(
        store: InMemorySessionStore, state: SessionState,
        transport: ScriptedTransport, ids: DeterministicIDSource, writer: String = "q-writer"
    ) throws -> SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer)
    }

    /// M2-D D0: the ID allocator must continue past the reopened log, or
    /// new admissions reuse sequence numbers and the next reconcile fails
    /// closed on its own log ("duplicate queue admission"). Seed from the
    /// durable high-water mark (event sequences + entry orderKeys).
    private static func replayWatermark(store: InMemorySessionStore, session: SessionID) throws -> UInt64 {
        var maxSeq: UInt64 = 0
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for rec in page {
                maxSeq = max(maxSeq, rec.sequence.value)
                switch rec.record {
                case .queueAdmitted(let e), .queueUpdated(let e):
                    maxSeq = max(maxSeq, e.orderKey)
                default:
                    break
                }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        return maxSeq
    }

    @Test("D0 boundary 1: crash before linkage resumes dispatchable with no duplicate")
    func crashBeforeLinkageResumes() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(store: store, state: idle, transport: gate, ids: DeterministicIDSource(prefix: "qa"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        // Crash before the follow-up ever dispatches (no linkage possible).
        // (Actor dropped; the store survives with the committed records.)
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(rebuilt.queue.count == 1 && rebuilt.queue.first?.state == .queued, "never-sent entry stays queued")
        #expect(!rebuilt.queueHeld, "no hold without linkage or unknowns")
        #expect(rebuilt.admittedCommands[CommandID("f-1")] != nil, "ack survives reopen")
        // A fresh run completes; the queued entry auto-dispatches exactly once.
        let t2 = ScriptedTransport()
        t2.script = [
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
        ]
        let actor2 = try Self.makeScriptedActor(store: store, state: rebuilt, transport: t2, ids: DeterministicIDSource(prefix: "qb"))
        await actor2.submitText(commandID: CommandID("run-2"), text: "run2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "follow-up dispatched and done")
        let links = try store.records(session: idle.sessionID, since: 0, limit: 500).0.compactMap { r -> QueueDispatchLink? in
            if case .queueDispatched(let l) = r.record { return l }; return nil
        }
        #expect(links.count == 1, "exactly one dispatch linkage, no duplicate: \(links.count)")
        continuation.finish()
    }

    @Test("D0 boundary 2: crash after linkage holds unknown; reconcile releases once")
    func crashAfterLinkageHoldsUnknown() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(store: store, state: idle, transport: gate, ids: DeterministicIDSource(prefix: "qc"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        // Complete the run: dispatches the follow-up (link commits), whose
        // provider response never arrives.
        let inv1 = gate.invocations
        continuation.yield(.respond(ActorFixtures.finalResponse(requestID: inv1[0].requestID, generation: inv1[0].generation)))
        try await ActorFixtures.awaitInvocations(gate, count: 2)
        // Crash with the dispatched provider effect in flight.
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(rebuilt.queue.first?.state == .heldUnknown, "sent but uncompleted holds unknown")
        #expect(rebuilt.queueHeld, "unknown delivery holds the queue")
        // Resume does not release or dispatch it; no provider effect runs.
        let g2 = GatedTransport()
        let actor2 = try Self.makeGatedActor(store: store, state: rebuilt, transport: g2, ids: DeterministicIDSource(prefix: "qd"))
        await actor2.resumeQueue()
        let held = await actor2.currentState()
        #expect(held.queue.first?.state == .heldUnknown, "resume never releases unknowns")
        #expect(held.queueHeld, "queue stays held")
        #expect(g2.invocations.isEmpty, "no automatic provider effect after reopen+resume")
        // Explicit reconcile releases exactly once.
        let entryID = try #require(held.queue.first?.entryID)
        await actor2.reconcileQueue(entryID: entryID)
        let released = await actor2.currentState()
        #expect(released.queue.first?.state == .queued, "reconcile requeues")
        continuation.finish()
    }

    @Test("D0 reconcile then redispatch delivers exactly once, survives reopen")
    func reconcileRedispatchDeliversOnce() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        // Seed: queued entry, dispatched with linkage, no completion.
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: idle.epoch.epochID)
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "follow", targetEpochID: idle.epoch.epochID, orderKey: 5, sealed: false)
        let dispatched = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .dispatched, revision: 1, text: "follow", targetEpochID: idle.epoch.epochID, orderKey: 5, sealed: false)
        let identity = WriterIdentity(session: idle.sessionID, writer: "q-writer")
        try store.claimWriterOwnership(session: idle.sessionID, writer: "q-writer")
        try store.appendBatch([.queueAdmitted(entry), .queueUpdated(dispatched), .queueDispatched(link)], as: identity)
        // Rebuild, reconcile, crash, rebuild: the decision persists.
        var state = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(state.queue.first?.state == .heldUnknown)
        let t = ScriptedTransport()
        let actor = try Self.makeScriptedActor(store: store, state: state, transport: t, ids: DeterministicIDSource(prefix: "qe"))
        await actor.reconcileQueue(entryID: "q-1")
        state = await actor.currentState()
        #expect(state.queue.first?.state == .queued)
        // Crash; reopen must show the queued (reconciled) entry, not unknown.
        let state2 = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(state2.queue.first?.state == .queued, "reconcile decision survives reopen")
        #expect(!state2.queueHeld, "no hold after reconciled requeue")
        // Redispatch delivers exactly once: a fresh run completes, the
        // follow-up dispatches (link #2), and exactly one provider
        // invocation carries the new linked request.
        let t2 = ScriptedTransport()
        t2.script = [
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
        ]
        let actor2 = try Self.makeScriptedActor(store: store, state: state2, transport: t2, ids: DeterministicIDSource(prefix: "qe2"))
        await actor2.submitText(commandID: CommandID("run-9"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "reconciled entry dispatched and done")
        let links = try store.records(session: idle.sessionID, since: 0, limit: 500).0.compactMap { rec -> QueueDispatchLink? in
            if case .queueDispatched(let l) = rec.record { return l }
            return nil
        }
        #expect(links.count == 2, "exactly two dispatches total, got \(links.count)")
        let link2 = try #require(links.last)
        #expect(link2.effectID != link.effectID, "redispatch mints a fresh effect identity")
        let followInvocations = t2.invocations.filter { $0.requestID == link2.requestID }
        #expect(followInvocations.count == 1, "exactly one provider invocation for the redispatch, got \(followInvocations.count)")
    }

    @Test("D0 boundary 3: crash after completion stands as history")
    func crashAfterCompletionStands() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let t = ScriptedTransport()
        t.script = [
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
            ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
        ]
        let actor = try Self.makeScriptedActor(store: store, state: idle, transport: t, ids: DeterministicIDSource(prefix: "qf"))
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, {
            if case .completed = $0.phase { return true }; return false
        }, "first run completed")
        await actor.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "follow-up dispatched")
        await actor.dismissRun()
        // Crash; reopen sees settled history, no hold, no unknowns.
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(rebuilt.queue.allSatisfy { $0.state == .admittedToHistory })
        #expect(!rebuilt.queueHeld, "completed work leaves no hold")
        #expect(rebuilt.unresolvedOperations.isEmpty)
        // New work proceeds without acknowledgment.
        let t2 = ScriptedTransport()
        t2.script = [ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))]
        let actor2 = try Self.makeScriptedActor(store: store, state: rebuilt, transport: t2, ids: DeterministicIDSource(prefix: "qg"))
        await actor2.submitText(commandID: CommandID("run-2"), text: "run2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            if case .completed = $0.phase { return true }; return false
        }, "new work proceeds")
    }

    private static func awaitPhaseLink(
        _ actor: SessionActor<GatedTransport, ScriptedExecutor, LinkFailingStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        _ check: (SessionState) -> Bool, _ label: String
    ) async throws {
        for _ in 0..<20_000 {
            if check(await actor.currentState()) { return }
            await Task.yield()
        }
        Issue.record("actor never reached \(label)")
        throw ScriptedError.outOfScript
    }

    @Test("D0 store failure before linkage prevents dispatch")
    func storeFailureBeforeLinkPreventsDispatch() async throws {
        let inner = InMemorySessionStore()
        let store = LinkFailingStore(inner: inner)
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try SessionActor(
            state: idle, ids: DeterministicIDSource(prefix: "qh"), clock: VirtualClock(now: 1_000_000),
            transport: gate, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q-writer")
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await Self.awaitPhaseLink(actor, { $0.queue.count == 1 }, "queued")
        store.failLinks = true
        let inv1 = gate.invocations
        continuation.yield(.respond(ActorFixtures.finalResponse(requestID: inv1[0].requestID, generation: inv1[0].generation)))
        try await Self.awaitPhaseLink(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "dispatch commit failure stops the run")
        #expect(gate.invocations.count == 1, "no provider effect for the undispatched entry, got \(gate.invocations.count)")
        let hasLink = try inner.records(session: idle.sessionID, since: 0, limit: 500).0.contains(where: {
            if case .queueDispatched = $0.record { return true }; return false
        })
        #expect(!hasLink, "no linkage committed on store failure")
        continuation.finish()
    }

    @Test("D0 duplicate ack returns the original across reopen; withdrawn never replays")
    func duplicateAckAndWithdrawSurviveReopen() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(store: store, state: idle, transport: gate, ids: DeterministicIDSource(prefix: "qi"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("dup"), text: "v1", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        let ack1 = try #require((await actor1.currentState()).admittedCommands[CommandID("dup")])
        // Crash; reopen; retry the same command ID: identical ack, no duplicate.
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        let ackR = try #require(rebuilt.admittedCommands[CommandID("dup")])
        #expect(ackR == ack1, "replayed ack matches the original")
        #expect(rebuilt.queue.count == 1, "no duplicate entry on reopen")
        let t2 = ScriptedTransport()
        t2.script = [ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))]
        let actor2 = try Self.makeScriptedActor(store: store, state: rebuilt, transport: t2, ids: DeterministicIDSource(prefix: "qj"))
        await actor2.submitText(commandID: CommandID("dup"), text: "totally different", kind: .followUp, sealed: false)
        let after = await actor2.currentState()
        #expect(after.queue.count == 1, "retry must not insert")
        #expect(after.admittedCommands[CommandID("dup")] == ack1, "retry returns the original ack")
        continuation.finish()
    }

    @Test("D0 post-reopen admissions continue the ID sequence without collisions")
    func postReopenAdmissionsUseFreshIDs() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(store: store, state: idle, transport: gate, ids: DeterministicIDSource(prefix: "qv"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        // Crash; rebuild with a seeded allocator past the durable high-water mark.
        let watermark = try Self.replayWatermark(store: store, session: idle.sessionID)
        #expect(watermark > 0, "log has sequences to continue past")
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        let gate2 = GatedTransport()
        let (stream2, continuation2) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate2.gate = stream2
        let actor2 = try Self.makeGatedActor(store: store, state: rebuilt, transport: gate2, ids: DeterministicIDSource(prefix: "qw", counter: watermark))
        await actor2.submitText(commandID: CommandID("run-2"), text: "run2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate2, count: 1)
        await actor2.submitText(commandID: CommandID("f-2"), text: "follow2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, { $0.queue.count == 2 }, "second entry queued")
        let after = await actor2.currentState()
        let ids = after.queue.map(\.entryID)
        #expect(Set(ids).count == 2, "no entry ID reuse after reopen, got \(ids)")
        #expect(after.queue[1].orderKey > watermark, "new admission continues past the watermark")
        // Crash again: reopen must reconcile cleanly (no duplicate-admission integrity fault).
        let rebuilt2 = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(rebuilt2.queue.count == 2, "both entries survive the second reopen")
        #expect(rebuilt2.admittedCommands[CommandID("f-2")]?.entryID == after.queue[1].entryID, "new ack replays")
        continuation.finish()
        continuation2.finish()
    }

    @Test("D0 held queue remains held across reopen; cancel marks entries durable")
    func heldQueueSurvivesReopen() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(store: store, state: idle, transport: gate, ids: DeterministicIDSource(prefix: "qk"))
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("f-1"), text: "follow", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        await actor1.cancel()
        try await ActorFixtures.awaitPhase(actor1, { $0.queueHeld }, "cancel holds the queue")
        // Crash; reopen must preserve the held queue (entries + hold).
        let rebuilt = try Self.reopenedState(store: store, session: idle.sessionID, epoch: idle.epoch)
        #expect(rebuilt.queue.first?.state == .held, "cancel-held entries stay held")
        #expect(rebuilt.queueHeld, "held queue remains held after reopen")
        continuation.finish()
    }
}
