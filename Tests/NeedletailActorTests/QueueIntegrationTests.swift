import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport

/// M4-B B6: deferred integration coverage (M4-due QUEUE rows + M2-due
/// crash/stale/epoch rows with no prior case-named tests). Actor +
/// InMemory store + scripted/gated transports. Every interleaving is
/// barrier-synchronized (no auto-dispatch assumptions beyond what the
/// test itself observes); sleeps never appear.
/// Darwin-debug: suite gated (B2/B6 G14-class — the debug runner SIGBUSes
/// on these deep transition chains; Linux-debug + Darwin `-O` green).
#if canImport(Glibc)
struct QueueIntegrationTests {

    private static func gatedPair() throws -> (
        SessionActor<GatedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        InMemorySessionStore, GatedTransport,
        AsyncStream<GatedTransport.TransportGateCommand>.Continuation
    ) {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try SessionActor(
            state: idle, ids: DeterministicIDSource(prefix: "b6"),
            clock: VirtualClock(now: 1_000_000),
            transport: gate, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "b6-writer")
        return (actor, store, gate, continuation)
    }

    private static func done() -> ProviderResponse {
        ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))
    }

    private static func failedRun() -> ProviderResponse {
        ProviderResponse(requestID: RequestID("x"), generation: Revision(0),
            outcome: .failed("boom"))
    }

    private static func linkCommandIDs(store: InMemorySessionStore, session: SessionID, ids: [String: String]) throws -> [String] {
        let (records, _) = try store.records(session: session, since: 0, limit: 500)
        return records.compactMap { rec in
            if case .queueDispatched(let l) = rec.record { return ids[l.entryID] }
            return nil
        }
    }

    private static func entryIDsByCommand(_ state: SessionState) -> [String: String] {
        Dictionary(uniqueKeysWithValues: state.queue.map { ($0.entryID, $0.commandID.raw) })
    }

    // NOTE (B6 review): the GatedTransport suspends before
    // requestStarted, so the run sits in requesting, not streaming.
    // Both phases route operatorInput to the identical admitToQueueState
    // path (SessionTransition: requesting + streaming arms), so queueing
    // behavior is phase-independent; the streaming-specific interleave
    // (tool JSON never split) is covered by D0 boundary tests + DX-04.
    @Test("UX-QUEUE-01 follow-up queues during a busy run, drains after")
    func UX_QUEUE_01_busyFollowupQueued() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        let session = try await actor.currentState().sessionID
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("f-1"), text: "later", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "follow-up queued")
        #expect(gate.invocations.count == 1, "nothing sent during the current turn")
        cont.yield(.respond(Self.done()))
        cont.yield(.respond(Self.done()))
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "streaming test drain")
        // Dispatch commits link + history-admission atomically, so the
        // linkage count per entry IS the exactly-once counter.
        let (records, _) = try store.records(session: session, since: 0, limit: 500)
        let links = records.compactMap { rec -> String? in
            if case .queueDispatched(let l) = rec.record, l.commandID == CommandID("f-1") { return l.entryID }
            return nil
        }
        #expect(links.count == 1, "follow-up dispatched exactly once: \(links)")
        cont.finish()
    }

    @Test("UX-QUEUE-02 busy submit is durable exactly once")
    func UX_QUEUE_02_busySubmitDurableOnce() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        let session = try await actor.currentState().sessionID
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("f-1"), text: "one", kind: .followUp, sealed: false)
        await actor.submitText(commandID: CommandID("f-1"), text: "two", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "single durable entry")
        #expect((await actor.currentState()).admittedCommands[CommandID("f-1")] != nil, "ack indexed")
        cont.yield(.respond(Self.done()))
        cont.yield(.respond(Self.done()))
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "drain")
        let (allRecords, _) = try store.records(session: (try await actor.currentState()).sessionID, since: 0, limit: 500)
        let links = allRecords.compactMap { rec -> String? in
            if case .queueDispatched(let l) = rec.record, l.commandID == CommandID("f-1") { return l.entryID }
            return nil
        }
        #expect(links.count == 1, "duplicate submit dispatches exactly once")
        cont.finish()
    }

    // NOTE (B6 review): same busy-run admission path as above; no
    // tool call is in flight in this harness (see D0 boundary tests
    // for tool-JSON atomicity under steer).
    @Test("UX-QUEUE-03 steer queues during a busy run, never interleaves")
    func UX_QUEUE_03_steerQueuesDuringBusyRun() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("s-1"), text: "steer", kind: .steer, sealed: false)
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.first(where: { $0.commandID == CommandID("s-1") })?.kind == .steer
        }, "steer queued by kind")
        #expect(gate.invocations.count == 1, "no interleaved dispatch mid-turn")
        cont.yield(.respond(Self.done()))
        cont.yield(.respond(Self.done()))
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "steer dispatched after the boundary")
        let doneRecords = try store.records(session: (try await actor.currentState()).sessionID, since: 0, limit: 500).0.filter { rec in
            if case .queueUpdated(let e) = rec.record {
                return e.commandID == CommandID("s-1") && e.state == .admittedToHistory
            }
            return false
        }
        #expect(doneRecords.count == 1, "steer completes exactly once after the boundary")
        cont.finish()
    }

    @Test("UX-QUEUE-04 two steers and three follow-ups drain FIFO")
    func UX_QUEUE_04_fifoAcrossTurns() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        let session = try await actor.currentState().sessionID
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("s-1"), text: "s-1", kind: .steer, sealed: false)
        await actor.submitText(commandID: CommandID("s-2"), text: "s-2", kind: .steer, sealed: false)
        await actor.submitText(commandID: CommandID("f-1"), text: "f-1", kind: .followUp, sealed: false)
        await actor.submitText(commandID: CommandID("f-2"), text: "f-2", kind: .followUp, sealed: false)
        await actor.submitText(commandID: CommandID("f-3"), text: "f-3", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 5 }, "five queued")
        let queuedOrder = await actor.currentState().queue.map { $0.commandID.raw }
        #expect(queuedOrder == ["s-1", "s-2", "f-1", "f-2", "f-3"], "FIFO admission")
        let idOf = Self.entryIDsByCommand(await actor.currentState())
        for _ in 0..<6 { cont.yield(.respond(Self.done())) }
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "full drain")
        let dispatched = try Self.linkCommandIDs(store: store, session: session, ids: idOf)
        #expect(dispatched == ["s-1", "s-2", "f-1", "f-2", "f-3"],
            "queued entries dispatch FIFO: \(dispatched)")
        cont.finish()
    }

    @Test("UX-QUEUE-05 edit, reorder and withdraw apply before dispatch")
    func UX_QUEUE_05_mutationsBeforeDispatch() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        let session = try await actor.currentState().sessionID
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("a"), text: "a", kind: .followUp, sealed: false)
        await actor.submitText(commandID: CommandID("b"), text: "b", kind: .followUp, sealed: false)
        await actor.submitText(commandID: CommandID("c"), text: "c", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 3 }, "three queued")
        var state = await actor.currentState()
        let b = try #require(state.queue.first(where: { $0.commandID == CommandID("b") }))
        await actor.editEntry(entryID: b.entryID, newText: "B!", baseRevision: b.revision)
        state = await actor.currentState()
        let c = try #require(state.queue.first(where: { $0.commandID == CommandID("c") }))
        let a = try #require(state.queue.first(where: { $0.commandID == CommandID("a") }))
        await actor.reorderQueueEntry(entryID: c.entryID, beforeID: a.entryID)
        await actor.withdrawEntry(entryID: a.entryID)
        state = await actor.currentState()
        #expect(state.queue.map(\.commandID).map(\.raw) == ["c", "a", "b"],
            "reorder moves c first; withdraw tombstones a in place")
        #expect(state.queue.first(where: { $0.commandID == CommandID("b") })?.text == "B!")
        let idOf = Self.entryIDsByCommand(state)
        for _ in 0..<4 { cont.yield(.respond(Self.done())) }
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.filter({ $0.state != .withdrawn }).allSatisfy({ $0.state == .admittedToHistory })
        }, "drain survivors")
        let dispatched = try Self.linkCommandIDs(store: store, session: session, ids: idOf)
        #expect(!dispatched.contains("a"), "withdrawn never dispatches: \(dispatched)")
        #expect(dispatched.first == "c", "reordered entry dispatches first: \(dispatched)")
        let bEntry = await actor.currentState().queue.first(where: { $0.commandID == CommandID("b") })
        #expect(bEntry?.text == "B!", "edited text is what dispatched: \(String(describing: bEntry?.text))")
        let (records, _) = try store.records(session: session, since: 0, limit: 500)
        let composed = records.compactMap { rec -> String? in
            if case .transcriptAppended(let t) = rec.record {
                if case .user(let text) = t { return text }
                return nil
            }
            return nil
        }.joined(separator: "\n")
        #expect(composed.contains("B!"), "edited bytes enter model context, not the stale text")
        cont.finish()
    }

    @Test("UX-QUEUE-07 cancel holds the queue; nothing auto-sends")
    func UX_QUEUE_07_cancelHoldsNoAutoSend() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("f-1"), text: "later", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        await actor.cancel()
        try await ActorFixtures.awaitPhase(actor, { $0.queueHeld }, "held on cancel")
        // Cancel grace is timer-driven: advance past it so the run
        // reaches its terminal interrupted phase before resuming.
        await actor.tick(at: 9_999_999)
        try await ActorFixtures.awaitPhase(actor, {
            if case .interrupted = $0.phase { return true }; return false
        }, "cancel grace terminal")
        let held = gate.invocations.count
        for _ in 0..<2000 { await Task.yield() }
        #expect(gate.invocations.count == held, "no automatic send while held")
        await actor.resumeQueue()
        let resumed = try await actor.currentState()
        #expect(!resumed.queueHeld, "explicit resume releases the hold")
        cont.finish()
        try store.releaseWriterOwnership(session: resumed.sessionID, writer: "b6-writer")
        // Drain phase on a fresh scripted transport (deterministic
        // completions; the cancelled run's orphaned gate waiter cannot
        // steal scripted responses).
        let t2 = ScriptedTransport()
        t2.script = [Self.done(), Self.done()]
        let actor2 = try SessionActor(
            state: resumed, ids: DeterministicIDSource(prefix: "qb"),
            clock: VirtualClock(now: 2_000_000),
            transport: t2, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q-writer")
        await actor2.submitText(commandID: CommandID("run-2"), text: "drain", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "explicit resume dispatches")
    }

    @Test("UX-QUEUE-11 headless approval holds without implicit consent")
    func UX_QUEUE_11_headlessApprovalHeld() async throws {
        let transport = ScriptedTransport()
        let executor = ScriptedExecutor()
        let approvals = ScriptedApprovals()
        approvals.script = [.unavailable("headless: no TTY")]
        let (actor, _) = try ActorFixtures.makeActor(
            mode: .workspace, permissive: true, transport: transport, executor: executor, approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [ToolProposal(
                callID: "c1", tool: "edit", argumentsDigest: "d",
                arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"hello\",\"new_string\":\"world\"}")], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queueHeld }, "headless approval holds the queue")
        let held = await actor.currentState()
        #expect(held.queueHeld, "unavailable gateway holds rather than auto-consents")
        #expect(held.heldReason == .approvalPending, "hold cites the pending approval, got: \(String(describing: held.heldReason))")
        #expect(held.pendingApproval != nil, "approval request is recorded for the operator")
        #expect(executor.calls.isEmpty, "no tool executed without a grant decision")
    }

    @Test("UX-QUEUE-12 failed run keeps the queue; resume is explicit")
    func UX_QUEUE_12_failedKeepsQueue() async throws {
        let (actor, store, gate, cont) = try Self.gatedPair()
        _ = store
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("f-1"), text: "later", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        cont.yield(.respond(Self.failedRun()))
        try await ActorFixtures.awaitPhase(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "run failed")
        #expect(await actor.currentState().queue.count == 1, "queue stays visible")
        let held = gate.invocations.count
        for _ in 0..<2000 { await Task.yield() }
        #expect(gate.invocations.count == held, "no surprise continuation")
        await actor.resumeQueue()
        let resumed = try await actor.currentState()
        cont.finish()
        try store.releaseWriterOwnership(session: resumed.sessionID, writer: "b6-writer")
        // Drain phase on a fresh scripted transport (deterministic
        // completions; the failed run's orphaned gate waiter cannot
        // steal scripted responses).
        let t2 = ScriptedTransport()
        t2.script = [Self.done(), Self.done()]
        let actor2 = try SessionActor(
            state: resumed, ids: DeterministicIDSource(prefix: "qb"),
            clock: VirtualClock(now: 2_000_000),
            transport: t2, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q-writer")
        await actor2.submitText(commandID: CommandID("run-2"), text: "drain", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "explicit resume dispatches")
    }

    // The uncertain pre-crash dispatch is not re-sent automatically;
    // exactly one explicit redispatch completes the work.
    @Test("UX-QUEUE-06 crash at the dispatch boundary: no auto-resend, one explicit redispatch")
    func UX_QUEUE_06_crashBoundaryNoAutoResend() async throws {
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try SessionActor(
            state: idle, ids: DeterministicIDSource(prefix: "qa"),
            clock: VirtualClock(now: 1_000_000),
            transport: gate, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q-writer")
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitText(commandID: CommandID("f-1"), text: "later", kind: .followUp, sealed: false)
        // Complete run-1, then let f-1 DISPATCH (linkage committed)...
        continuation.yield(.respond(Self.done()))
        try await ActorFixtures.awaitInvocations(gate, count: 2)
        // ...then crash before the follow-up's run completes. (Actor
        // dropped; the store survives with the committed records.)
        var rids = DeterministicIDSource(prefix: "qb")
        let rebuilt = try resumeSession(store: store, session: idle.sessionID, epoch: idle.epoch, trustMode: .workspace, as: "q-writer", ids: &rids)
        let unknown = rebuilt.queue.filter { $0.state == .heldUnknown }
        #expect(unknown.count == 1 && unknown.first?.commandID == CommandID("f-1"),
            "dispatched-but-uncompleted delivery holds as unknown, got \(rebuilt.queue.map { "\($0.commandID.raw):\($0.state)" })")
        #expect(rebuilt.queueHeld, "queue holds until explicit reconciliation")
        // Explicit reconcile requeues; redispatch completes exactly once.
        let t2 = ScriptedTransport()
        t2.script = [ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)),
                     ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))]
        let actor2 = try SessionActor(
            state: rebuilt, ids: rids, clock: VirtualClock(now: 1_000_000),
            transport: t2, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q-writer")
        let target = try #require(unknown.first)
        await actor2.reconcileQueue(entryID: target.entryID)
        // Reconcile requeues but the hold stands until explicit resume.
        await actor2.resumeQueue()
        await actor2.submitText(commandID: CommandID("run-3"), text: "drain", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.filter({ $0.commandID == CommandID("f-1") }).allSatisfy({ $0.state == .admittedToHistory })
        }, "reconciled entry drains exactly once")
        let (records, _) = try store.records(session: idle.sessionID, since: 0, limit: 500)
        // Linkages are the dispatch counter (dispatch commits link +
        // history atomically): exactly the uncertain pre-crash dispatch
        // plus the single explicit redispatch — never an auto-resend.
        let links = records.compactMap { rec -> String? in
            if case .queueDispatched(let l) = rec.record, l.commandID == CommandID("f-1") { return l.entryID }
            return nil
        }
        #expect(links.count == 2, "one uncertain dispatch + one explicit redispatch: \(links)")
        #expect(Set(links).count == 1, "both linkages bind the same entry (no duplicate)")
        continuation.finish()
    }

    @Test("UX-QUEUE-10 epoch switch holds queued entries; re-consent releases")
    func UX_QUEUE_10_epochSwitchHoldsForReconsent() async throws {
        // Two-alias snapshot so a live model switch is possible.
        let configJSON = "{\"version\":1,\"default_model\":\"local-coder\",\"allow_http_origins\":[\"http://127.0.0.1:11434\",\"http://127.0.0.1:11435\"],\"models\":[{\"alias\":\"local-coder\",\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://127.0.0.1:11434\",\"model\":\"qwen\",\"context_window\":262144,\"max_output\":4096,\"locality\":\"local\",\"credential\":{\"env\":\"NT_M2_X_KEY\"},\"connect_timeout_s\":10,\"read_idle_timeout_s\":300,\"request_timeout_s\":1800,\"max_in_flight\":1},{\"alias\":\"local-reviewer\",\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://127.0.0.1:11435\",\"model\":\"qwen\",\"context_window\":262144,\"max_output\":4096,\"locality\":\"local\",\"credential\":{\"env\":\"NT_M2_X_KEY\"},\"connect_timeout_s\":10,\"read_idle_timeout_s\":300,\"request_timeout_s\":1800,\"max_in_flight\":1}],\"tools\":{\"read\":true,\"search\":true,\"edit\":true,\"write\":true,\"exec\":\"ask\",\"consult\":false}}"
        let snapshot = try validateConfig(Data(configJSON.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        let epochA = EpochDescriptor(epochID: EpochID("epoch-a"), parentEpochID: nil,
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
        let idle = SessionState(sessionID: SessionID("s-q10"), epoch: epochA, trustMode: .workspace, phase: .idle)
        let store = InMemorySessionStore()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        var rids = DeterministicIDSource(prefix: "q10")
        let actor = try SessionActor(
            state: idle, ids: rids, clock: VirtualClock(now: 1_000_000),
            transport: gate, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "q10-writer")
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitText(commandID: CommandID("q-1"), text: "queued", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued under epoch A")
        // Live epoch switch: the queued entry's target goes stale and the
        // whole queue holds. Nothing dispatches on the stale epoch.
        await actor.switchModel(alias: "local-reviewer")
        try await ActorFixtures.awaitPhase(actor, { $0.queueHeld }, "epoch switch holds the queue")
        let held = await actor.currentState()
        #expect(held.queue.first?.targetEpochID != held.epoch.epochID, "target predates the live epoch")
        #expect(gate.invocations.count == 1, "no dispatch on the stale epoch")
        // Explicit re-consent (retarget) + resume releases exactly once.
        let entryID = try #require(held.queue.first?.entryID)
        await actor.retargetQueueEntry(entryID: entryID)
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.first?.attachmentConsentEpoch == nil || $0.queue.first?.targetEpochID == $0.epoch.epochID
        }, "entry re-targeted to the live epoch")
        await actor.resumeQueue()
        continuation.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        continuation.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "re-consented queue drains")
        #expect(gate.invocations.count == 2, "exactly one post-switch dispatch")
        continuation.finish()
    }
}
#endif
