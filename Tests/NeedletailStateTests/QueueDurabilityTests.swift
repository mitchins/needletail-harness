import Testing
import Foundation
@testable import NeedletailCore

/// M2-D D0: durable queue admission/hold/reconcile, dispatch linkage,
/// head barrier, retarget/reconcile — reducer level (fast, deterministic).
/// Actor + store fault-injection legs live in QueueCrashMatrixTests.
struct QueueDurabilityTests {

    private static func streamingWithQueue(
        ids: inout DeterministicIDSource, texts: [(String, String, QueueKind)] = [("one", "q-1", .followUp)]
    ) throws -> (SessionState, RunDescriptor) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        for (text, id, kind) in texts {
            state = transition(state, StateFixtures.input(text, id: id, kind: kind), &ids).state
        }
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        return (state, run)
    }

    private static func finalResponse(_ run: RunDescriptor, text: String = "done") -> SessionEvent {
        .providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(
                requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(text: text, toolProposals: [], isFinal: true)),
            atMillis: 1003)
    }

    private static func heldEntry(_ base: QueueEntry, state: QueueEntryState = .held) -> QueueEntry {
        QueueEntry(
            entryID: base.entryID, commandID: base.commandID, kind: base.kind,
            state: state, revision: base.revision, text: base.text,
            targetEpochID: base.targetEpochID, orderKey: base.orderKey, sealed: base.sealed)
    }

    @Test("D0 link commits atomically with history, intent and transcript")
    func linkAtomicWithDispatch() throws {
        var ids = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithQueue(ids: &ids)
        let completed = transition(streaming, Self.finalResponse(run), &ids)
        let records = completed.records
        // The dispatch group commits link + history + intent together.
        let linkIdx = records.firstIndex(where: {
            if case .queueDispatched = $0 { return true }; return false
        })
        let histIdx = records.firstIndex(where: {
            if case .queueUpdated(let e) = $0, e.state == .admittedToHistory { return true }; return false
        })
        let intentIdx = records.firstIndex(where: {
            if case .operationIntent = $0 { return true }; return false
        })
        let linkIdxU = try #require(linkIdx, "dispatch must commit a queue link")
        let histIdxU = try #require(histIdx, "dispatch must commit history admission")
        _ = try #require(intentIdx, "dispatch must commit the provider intent")
        _ = linkIdxU; _ = histIdxU
        guard case .queueDispatched(let link) = records[linkIdxU] else {
            Issue.record("not a link"); return
        }
        #expect(link.entryID == streaming.queue.first?.entryID, "link binds the dispatched entry")
        #expect(link.commandID == streaming.queue.first?.commandID)
        #expect(link.runID != run.runID, "link binds the NEW run, not the completed one")
        // The provider effect is requested in the same transition, bound
        // to the same effect/request/run as the link.
        let reserved = completed.effects.compactMap { e -> EffectID? in
            if case .reserveEffect(let r) = e { return r.effectID }; return nil
        }
        #expect(reserved == [link.effectID], "reservation and link agree on the effect")
        #expect(completed.effects.contains(where: {
            if case .requestProvider(let inv) = $0 {
                return inv.effectID == link.effectID && inv.requestID == link.requestID && inv.runID == link.runID
            }
            return false
        }), "invocation matches the link triple")
        #expect(completed.state.phase == .admitting, "auto-dispatch proceeds")
    }

    @Test("D0 head barrier: held head blocks a later dispatch and holds the queue")
    func barrierBlocksOvertake() throws {
        var ids = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithQueue(ids: &ids, texts: [("old", "q-old", .followUp), ("new", "q-new", .followUp)])
        // Hold the head manually (as cancel/switch would), queue stays unheld.
        var held = streaming.queue
        held[0] = Self.heldEntry(held[0])
        let state = streaming.replacing(queue: held)
        #expect(!state.queueHeld, "precondition: no global hold yet")
        let completed = transition(state, Self.finalResponse(run), &ids)
        // No auto-dispatch past the held head; the queue holds instead.
        #expect(completed.state.queueHeld, "barrier must hold the queue")
        let hasDispatch = completed.records.contains(where: {
            if case .queueDispatched = $0 { return true }; return false
        })
        #expect(!hasDispatch, "no dispatch past a held head")
        #expect(completed.effects.contains(where: {
            if case .requestProvider = $0 { return true }; return false
        }) == false, "no provider effect for a barred dispatch")
        #expect(completed.state.queue[1].state == .queued, "later entry waits, unmodified")
    }

    @Test("D0 steer priority still applies when nothing is held")
    func steerPriorityPreserved() throws {
        var ids = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithQueue(ids: &ids, texts: [("f", "q-f", .followUp), ("s", "q-s", .steer)])
        let completed = transition(streaming, Self.finalResponse(run), &ids)
        // Steer dispatches first even though it was queued later.
        let linkEntry = completed.records.compactMap { r -> String? in
            if case .queueDispatched(let l) = r { return l.entryID }; return nil
        }.first
        let steerID = streaming.queue.first(where: { $0.kind == .steer })?.entryID
        #expect(linkEntry == steerID, "steer dispatches before earlier follow-up")
    }

    @Test("D0 stale-epoch head trips the barrier instead of being skipped")
    func staleHeadTripsBarrier() throws {
        var ids = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithQueue(ids: &ids, texts: [("a", "q-a", .followUp), ("b", "q-b", .followUp)])
        // Epoch switch holds the head (stale target); a current entry sits behind it.
        let switched = transition(streaming, .switchModel(alias: streaming.epoch.profile.alias, atMillis: 1004), &ids)
        // Same-alias switch is a no-op epoch-wise; force staleness by hand to
        // isolate the barrier (switchModel coverage lives in EpochSwitchTests).
        _ = switched
        var queue = streaming.queue
        queue[0] = QueueEntry(
            entryID: queue[0].entryID, commandID: queue[0].commandID, kind: queue[0].kind,
            state: .held, revision: queue[0].revision, text: queue[0].text,
            targetEpochID: EpochID("epoch-stale"), orderKey: queue[0].orderKey, sealed: queue[0].sealed)
        let state = streaming.replacing(queue: queue)
        let completed = transition(state, Self.finalResponse(run), &ids)
        #expect(completed.state.queueHeld, "stale head must hold the queue")
        #expect(completed.state.queue[1].state == .queued, "later entry must not overtake")
        #expect(completed.effects.contains(where: {
            if case .requestProvider = $0 { return true }; return false
        }) == false, "no dispatch past a stale head")
    }

    @Test("D0 hold-for-approval holds the queue with a structured reason")
    func approvalHoldHoldsQueue() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let request = ApprovalRequest(
            requestID: run.requestID, runID: run.runID, generation: run.revision,
            operation: "op", requiredGrant: "explicit approval")
        let authorising = admitting.replacing(phase: .authorising, pendingApproval: .some(request))
        let held = transition(authorising, .approvalUnavailable(requestID: run.requestID, generation: run.revision, reason: "headless", atMillis: 1000), &ids)
        #expect(held.state.queueHeld, "unavailable approval must hold the queue")
        if case .approvalPending = held.state.heldReason {
        } else {
            Issue.record("reason must be approvalPending, got \(String(describing: held.state.heldReason))")
        }
    }

    @Test("D0 resume skips stale-target and held-unknown entries, records unholds")
    func resumeSkipsStaleAndUnknown() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        state = state.replacing(queueHeld: true, heldReason: .cancelled(sinceMillis: 1))
        let e1 = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .held, revision: 1, text: "a", targetEpochID: state.epoch.epochID, orderKey: 1, sealed: false)
        let e2 = QueueEntry(entryID: "q-2", commandID: CommandID("c-2"), kind: .followUp, state: .held, revision: 1, text: "b", targetEpochID: EpochID("epoch-old"), orderKey: 2, sealed: false)
        let e3 = QueueEntry(entryID: "q-3", commandID: CommandID("c-3"), kind: .followUp, state: .heldUnknown, revision: 1, text: "c", targetEpochID: state.epoch.epochID, orderKey: 3, sealed: false)
        state = state.replacing(queue: [e1, e2, e3])
        let resumed = transition(state, .queueResume(atMillis: 2000), &ids)
        #expect(resumed.state.queue[0].state == .queued, "current-epoch held entry released")
        #expect(resumed.state.queue[1].state == .held, "stale-target entry stays held")
        #expect(resumed.state.queue[2].state == .heldUnknown, "unknown-delivery entry stays held")
        #expect(resumed.state.queueHeld, "queue stays held while stale entries remain")
        let unholds = resumed.records.filter {
            if case .queueUpdated = $0 { return true }; return false
        }
        #expect(unholds.count == 1, "exactly one unhold recorded, got \(unholds.count)")
    }

    @Test("D0 retarget validates route and records the new target")
    func retargetValidatesAndRecords() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        let stale = QueueEntry(entryID: "q-9", commandID: CommandID("c-9"), kind: .followUp, state: .held, revision: 1, text: "x", targetEpochID: EpochID("epoch-old"), orderKey: 9, sealed: false)
        state = state.replacing(queue: [stale], queueHeld: true, heldReason: .staleAttachment)
        let retargeted = transition(state, .queueRetarget(entryID: "q-9", atMillis: 1001), &ids)
        #expect(retargeted.state.queue.first?.targetEpochID == state.epoch.epochID, "target moves to the current epoch")
        #expect(retargeted.state.queue.first?.state == .held, "retarget does not unhold by itself")
        #expect(retargeted.records.contains(where: {
            if case .queueUpdated(let e) = $0, e.entryID == "q-9" { return true }; return false
        }), "retarget decision recorded")
        // Unknown entry: denied, no records beyond the prefix.
        let unknown = transition(state, .queueRetarget(entryID: "q-nope", atMillis: 1002), &ids)
        #expect(unknown.records.allSatisfy {
            if case .queueUpdated = $0 { return false }; return true
        }, "no queue update for unknown entries")
        // Terminal entries are not retargetable.
        var done = state
        done = done.replacing(queue: [Self.heldEntry(stale, state: .withdrawn)])
        let refused = transition(done, .queueRetarget(entryID: "q-9", atMillis: 1003), &ids)
        #expect(refused.records.allSatisfy {
            if case .queueUpdated = $0 { return false }; return true
        }, "no queue update for terminal entries")
    }

    @Test("D0 reconcile requeues held-unknown entries and records the decision")
    func reconcileRequeuesHeldUnknown() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        let u = QueueEntry(entryID: "q-u", commandID: CommandID("c-u"), kind: .followUp, state: .heldUnknown, revision: 1, text: "u", targetEpochID: state.epoch.epochID, orderKey: 7, sealed: false)
        state = state.replacing(queue: [u], queueHeld: true, heldReason: .error("reopen: unknown"))
        let reconciled = transition(state, .queueReconcile(entryID: "q-u", atMillis: 1001), &ids)
        #expect(reconciled.state.queue.first?.state == .queued, "explicit reconcile releases to queued")
        #expect(reconciled.records.contains(where: {
            if case .queueUpdated(let e) = $0, e.entryID == "q-u" && e.state == .queued { return true }; return false
        }), "reconcile decision recorded for reopen survival")
        // Non-unknown entries refuse; nothing recorded.
        var plain = state
        plain = plain.replacing(queue: [Self.heldEntry(u, state: .queued)])
        let refused = transition(plain, .queueReconcile(entryID: "q-u", atMillis: 1002), &ids)
        #expect(refused.records.allSatisfy {
            if case .queueUpdated = $0 { return false }; return true
        }, "queued entries are not reconcileable")
    }

    @Test("D0 cancel marks queued entries held with durable records")
    func cancelMarksEntriesHeld() throws {
        var ids = StateFixtures.ids()
        let (streaming, _) = try Self.streamingWithQueue(ids: &ids, texts: [("a", "q-a", .followUp), ("b", "q-b", .steer)])
        let cancelled = transition(streaming, .cancelRequested(atMillis: 1005), &ids)
        #expect(cancelled.state.queue.allSatisfy { $0.state == .held }, "queued entries become held")
        #expect(cancelled.state.queueHeld, "queue held")
        let updates = cancelled.records.filter {
            if case .queueUpdated = $0 { return true }; return false
        }
        #expect(updates.count == 2, "one hold record per entry, got \(updates.count)")
    }

    @Test("D0 replay: never-sent entries reconstruct without holds")
    func replayNeverSent() throws {
        let e1 = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let e2 = QueueEntry(entryID: "q-2", commandID: CommandID("c-2"), kind: .steer, state: .queued, revision: 1, text: "b", targetEpochID: EpochID("e-1"), orderKey: 12, sealed: false)
        let recon = try reconcileQueue([.queueAdmitted(e1), .queueAdmitted(e2)])
        #expect(recon.entries.count == 2)
        #expect(recon.entries.allSatisfy { $0.state == .queued })
        #expect(!recon.queueHeld, "nothing sent, nothing held")
        #expect(recon.unknownLinks.isEmpty)
        #expect(recon.acks[CommandID("c-1")]?.entryID == "q-1")
        #expect(recon.acks[CommandID("c-1")]?.sequence == SequenceNumber(11))
        #expect(recon.acks[CommandID("c-2")]?.entryID == "q-2")
    }

    @Test("D0 replay: link without completion holds unknown and blocks dispatch")
    func replayLinkWithoutCompletionHolds() throws {
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        let updated = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .dispatched, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let recon = try reconcileQueue([
            .queueAdmitted(entry),
            .queueUpdated(updated),
            .queueDispatched(link),
            .queueUpdated(history),
        ])
        #expect(recon.entries.first?.state == .heldUnknown, "sent but uncompleted delivery holds")
        #expect(recon.queueHeld, "unknown delivery holds the queue")
        #expect(recon.unknownLinks.count == 1 && recon.unknownLinks.first?.entryID == "q-1")
    }

    @Test("D0 replay: link with run completion stands as history")
    func replayLinkWithCompletionStands() throws {
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let recon = try reconcileQueue([
            .queueAdmitted(entry),
            .queueDispatched(link),
            .queueUpdated(history),
            .eventAppended(seq: SequenceNumber(99), kind: "completed", digest: eventDigest("completed", "r-9")),
        ])
        #expect(recon.entries.first?.state == .admittedToHistory, "completed run stands as history")
        #expect(!recon.queueHeld, "no hold without unknowns")
        #expect(recon.unknownLinks.isEmpty)
    }

    @Test("D0 replay: explicit reconcile supersedes the unknown link")
    func replayReconcileSupersedesLink() throws {
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let dispatched = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .dispatched, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let requeued = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        // Dispatch, crash, reopen (unknown), reconcile to queued, crash:
        // the recorded reconcile decision stands — no re-held unknown.
        let recon = try reconcileQueue([
            .queueAdmitted(entry),
            .queueUpdated(dispatched),
            .queueDispatched(link),
            .queueUpdated(history),
            .queueUpdated(requeued),
        ])
        #expect(recon.entries.first?.state == .queued, "reconcile decision survives reopen")
        #expect(!recon.queueHeld, "reconciled requeue does not hold")
        #expect(recon.unknownLinks.isEmpty, "superseded link is not unknown")
        // A redispatch after reconcile starts a fresh unknown window.
        let link2 = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-10"), requestID: RequestID("req-10"), effectID: EffectID("eff-10"), epochID: EpochID("e-1"))
        let history2 = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let recon2 = try reconcileQueue([
            .queueAdmitted(entry),
            .queueUpdated(dispatched),
            .queueDispatched(link),
            .queueUpdated(history),
            .queueUpdated(requeued),
            .queueDispatched(link2),
            .queueUpdated(history2),
        ])
        #expect(recon2.entries.first?.state == .heldUnknown, "new link without completion holds again")
        #expect(recon2.queueHeld)
        #expect(recon2.unknownLinks.count == 1 && recon2.unknownLinks.first?.runID == RunID("r-10"), "only the latest link is unknown")
    }

    @Test("D0 replay: legacy history without link keeps recorded state")
    func replayLegacyHistoryStands() throws {
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let recon = try reconcileQueue([.queueAdmitted(entry), .queueUpdated(history)])
        #expect(recon.entries.first?.state == .admittedToHistory, "pre-linkage history is preserved, never auto-resent")
        #expect(!recon.queueHeld)
    }

    @Test("D0 replay: ack retention boundary survives reopen")
    func replayAckRetentionBoundary() throws {
        var records: [DurableRecord] = []
        for i in 1...Int(maxAdmittedCommands + 1) {
            let e = QueueEntry(entryID: "q-\(i)", commandID: CommandID("c-\(i)"), kind: .followUp, state: .queued, revision: 1, text: "t", targetEpochID: EpochID("e-1"), orderKey: UInt64(i), sealed: false)
            records.append(.queueAdmitted(e))
        }
        let recon = try reconcileQueue(records)
        #expect(recon.acks.count == Int(maxAdmittedCommands), "retention bound applies on replay")
        #expect(recon.acks[CommandID("c-1")] == nil, "oldest pruned")
        #expect(recon.acks[CommandID("c-\(maxAdmittedCommands + 1)")]?.entryID == "q-\(maxAdmittedCommands + 1)")
    }

    @Test("D0 replay: corrupt queue records fail closed")
    func replayCorruptRecordsThrow() throws {
        let e = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        #expect(throws: StoreError.self, "duplicate admission is corruption") {
            try reconcileQueue([.queueAdmitted(e), .queueAdmitted(e)])
        }
        let other = QueueEntry(entryID: "q-9", commandID: CommandID("c-9"), kind: .followUp, state: .queued, revision: 2, text: "b", targetEpochID: EpochID("e-1"), orderKey: 12, sealed: false)
        #expect(throws: StoreError.self, "update for unknown entry is corruption") {
            try reconcileQueue([.queueUpdated(other)])
        }
        let link = QueueDispatchLink(entryID: "q-9", commandID: CommandID("c-9"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        #expect(throws: StoreError.self, "linkage for unknown entry is corruption") {
            try reconcileQueue([.queueDispatched(link)])
        }
    }

    @Test("D0 resume composes replayed holds without bypassing unresolved ops")
    func resumeHonoursReplayedAndUnresolvedHolds() throws {
        var ids = StateFixtures.ids()
        let base = try StateFixtures.idle()
        // Reopened state: one unknown delivery + one unresolved operation.
        let recon = QueueReconstruction(
            entries: [QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .heldUnknown, revision: 1, text: "u", targetEpochID: base.epoch.epochID, orderKey: 5, sealed: false)],
            acks: [:], queueHeld: true, unknownLinks: [], failedLinks: [])
        let held = OperationRef(operationID: OperationID("eff-1/c1"), callID: "c1", state: .unknown, mutating: true)
        var state = SessionState.resumedAfterReopen(
            sessionID: base.sessionID, epoch: base.epoch, trustMode: base.trustMode,
            heldOperations: [held])
        state = state.replacing(
            queue: recon.entries,
            queueHeld: state.queueHeld || recon.queueHeld,
            heldReason: state.heldReason ?? .error("reopen: held queue entries"),
            admittedCommands: recon.acks)
        #expect(state.queueHeld, "reopen holds")
        #expect(state.unresolvedOperations.count == 1)
        // Resume refuses while unresolved markers stand (existing gate).
        let resume = transition(state, .queueResume(atMillis: 2000), &ids)
        #expect(resume.state.queueHeld, "no resume past unresolved ops")
        #expect(resume.state.queue.first?.state == .heldUnknown, "unknown entry untouched by refused resume")
    }

    @Test("D0 epoch switch holds stale entries and the queue with durable records")
    func switchModelHoldsQueue() throws {
        let twoModel = """
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434","http://127.0.0.1:11435"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1},{"alias":"second","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11435","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true}}
            """
        let snapshot = try validateConfig(Data(twoModel.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-1"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"))
        var ids = StateFixtures.ids()
        var state = SessionState(sessionID: SessionID("s-9"), epoch: epoch, trustMode: .workspace, phase: .idle)
        state = state.replacing(queue: [QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "old", targetEpochID: EpochID("epoch-1"), orderKey: 1, sealed: false)])
        let switched = transition(state, .switchModel(alias: "second", atMillis: 1001), &ids)
        #expect(switched.state.queue.first?.state == .held, "stale entries hold on switch")
        #expect(switched.state.queueHeld, "switch with stale entries holds the queue")
        if case .staleAttachment = switched.state.heldReason {
        } else {
            Issue.record("hold reason must be staleAttachment, got \(String(describing: switched.state.heldReason))")
        }
        let holds = switched.records.filter {
            if case .queueUpdated(let e) = $0, e.state == .held { return true }; return false
        }
        #expect(holds.count == 1, "one durable hold record, got \(holds.count)")
    }

    @Test("D0 failed dispatch holds the queue; resume after failure releases")
    func failedLinkHoldsQueue() throws {
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 11, sealed: false)
        // Link + failed run (no completion): determinate failure, not unknown.
        let recon = try reconcileQueue([
            .queueAdmitted(entry),
            .queueUpdated(history),
            .queueDispatched(link),
            .eventAppended(seq: SequenceNumber(4), kind: "failed", digest: eventDigest("failed", "r-9")),
        ])
        #expect(recon.entries.first?.state == .admittedToHistory, "failed dispatch keeps history")
        #expect(recon.queueHeld, "failed dispatch holds the queue like a live failed run")
        #expect(recon.unknownLinks.isEmpty, "determinate failure is not an unknown delivery")
        #expect(recon.failedLinks.count == 1)
        // A resume recorded after the failure releases the failed hold.
        let recon2 = try reconcileQueue([
            .queueAdmitted(entry),
            .queueUpdated(history),
            .queueDispatched(link),
            .eventAppended(seq: SequenceNumber(4), kind: "failed", digest: eventDigest("failed", "r-9")),
            .eventAppended(seq: SequenceNumber(5), kind: "queue-resumed", digest: "resumed"),
        ])
        #expect(!recon2.queueHeld, "resume after failure releases the failed hold")
        #expect(recon2.failedLinks.count == 1, "the failure itself is still recorded")
    }

    @Test("D0 grant clears only the approval hold, never other holds")
    func grantClearsOnlyApprovalHold() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: #"{"path":"f"}"#)])
        let request = ApprovalRequest(
            requestID: run.requestID, runID: run.runID, generation: run.revision,
            operation: "op", requiredGrant: "explicit approval", protectedPaths: [])
        let authorising = admitting.replacing(phase: .authorising, pendingApproval: .some(request), pendingBatch: .some(batch))
        // Approval hold from a prior unavailable decision: grant clears it.
        let held = authorising.replacing(queueHeld: true, heldReason: .some(.approvalPending))
        let granted = transition(held, .approvalGrant(requestID: run.requestID, generation: run.revision, atMillis: 1001), &ids)
        #expect(!granted.state.queueHeld, "grant releases its own approval hold")
        // An unrelated hold survives a grant.
        let otherHeld = authorising.replacing(queueHeld: true, heldReason: .error("unresolved markers"))
        let stillHeld = transition(otherHeld, .approvalGrant(requestID: run.requestID, generation: run.revision, atMillis: 1001), &ids)
        #expect(stillHeld.state.queueHeld, "non-approval holds survive a grant")
    }

    @Test("D0 64 KiB queue text budget refuses without dropping older entries")
    func queueTextBudgetRefuses() throws {
        var ids = StateFixtures.ids()
        let (streaming, _) = try Self.streamingWithQueue(ids: &ids, texts: [])
        var state = streaming
        // Two 30 KiB entries fit (60 KiB ≤ 64 KiB); a 10 KiB third does not.
        let big = String(repeating: "x", count: 30 * 1024)
        state = transition(state, StateFixtures.input(big, id: "b-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input(big, id: "b-2", kind: .followUp), &ids).state
        #expect(state.queue.count == 2)
        let refused = transition(state, StateFixtures.input(String(repeating: "y", count: 10 * 1024), id: "b-3", kind: .followUp), &ids)
        #expect(refused.state.queue.count == 2, "refusal must not insert or drop")
        let projections = refused.effects.compactMap { effect -> SessionEventProjection? in
            if case .emitUI(let projection) = effect { return projection }
            return nil
        }
        #expect(projections.contains(where: { $0.kind == "denied" && $0.detail.contains("queue text budget") }),
            "typed refusal with budget cause, got \(refused.effects)")
        #expect(refused.state.admittedCommands[CommandID("b-3")] == nil, "refused input leaves no ack")
    }

    @Test("D0 resume stays blocked while unresolved M2-C operations stand")
    func resumeBlockedByUnresolved() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        state = state.replacing(
            queue: [QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "x", targetEpochID: state.epoch.epochID, orderKey: 1, sealed: false)],
            queueHeld: true,
            heldReason: .error("cancelled"),
            unresolvedOperations: [OperationRef(operationID: OperationID("eff-1/c1"), callID: "c1", state: .unknown, mutating: true)])
        let resumed = transition(state, .queueResume(atMillis: 2000), &ids)
        #expect(resumed.state.queueHeld, "unresolved ops keep the queue held")
        #expect(resumed.state.queue.first?.state == .queued, "no state touched on refused resume")
    }

    @Test("D0 withdrawn entries never reach provider history")
    func withdrawnNeverDispatched() throws {
        var ids = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithQueue(ids: &ids, texts: [("drop", "q-drop", .followUp), ("keep", "q-keep", .followUp)])
        let dropID = try #require(streaming.queue.first?.entryID)
        var state = transition(streaming, .queueWithdraw(entryID: dropID, atMillis: 1003), &ids).state
        #expect(state.queue.first?.state == .withdrawn)
        let completed = transition(state, Self.finalResponse(run), &ids)
        // The surviving entry dispatches; the withdrawn text never does.
        let texts = completed.records.compactMap { r -> String? in
            if case .transcriptAppended(.user(let t)) = r { return t }; return nil
        }
        #expect(!texts.contains("drop"), "withdrawn text must never reach provider history")
        #expect(texts.contains("keep"), "surviving entry proceeds")
    }
}
