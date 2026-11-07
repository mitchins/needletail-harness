import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B2 RED: UX-QUEUE-01…05/07/11/12 pure queue/interruption/recovery
/// contract. Names the proposed API; fails until GREEN implements it.
struct QueueProjectionTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    private func sync(entries: [QueueEntry] = [],
                      held: Bool = false,
                      reason: HoldReason? = nil,
                      approval: ApprovalRequestView? = nil,
                      acked: Set<CommandID> = [],
                      epoch: EpochID = EpochID("e-1")) -> UIAction {
        UIAction.queueSync(QueueSyncSnapshot(
            entries: entries, activeRequest: nil,
            queueHeld: held, heldReason: reason,
            pendingApproval: approval, admittedCommandIDs: acked,
            liveEpoch: epoch))
    }

    private func entry(_ id: String, command: String, kind: QueueKind = .followUp,
                       state: QueueEntryState = .queued, order: UInt64 = 1) -> QueueEntry {
        QueueEntry(entryID: id, commandID: CommandID(command), kind: kind,
            state: state, revision: 1, text: "t", targetEpochID: EpochID("e-1"),
            orderKey: order, rank: Double(order))
    }

    @Test("UX-QUEUE-02 follow-up while busy renders optimistic pending")
    func UX_QUEUE_02_optimisticPending() throws {
        var state = UIState()
        let fx = apply(&state, .queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))))
        #expect(fx.count == 1, "exactly one effect")
        #expect(state.queue.count == 1 && state.queue[0].isOptimistic, "optimistic row visible")
        #expect(state.queue[0].pending, "marked pending until Core confirms")
        #expect(state.queue[0].commandID == CommandID("f-1"), "ack correlation key present")
    }

    @Test("UX-QUEUE-02 sync confirms the optimistic row authoritatively")
    func UX_QUEUE_02_syncConfirms() throws {
        var state = UIState()
        _ = apply(&state, .queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))))
        _ = apply(&state, sync(entries: [entry("q-1", command: "f-1")], acked: [CommandID("f-1")]))
        #expect(state.queue.count == 1, "single authoritative row")
        #expect(!state.queue[0].isOptimistic && !state.queue[0].pending, "confirmed, not pending")
        #expect(state.queue[0].entryID == "q-1", "Core identity wins")
    }

    @Test("UX-QUEUE-02 resubmitting a command replaces the optimistic row")
    func UX_QUEUE_02_resubmitDedupes() throws {
        var state = UIState()
        _ = apply(&state, .queueOp(.submitFollowUp(text: "one", commandID: CommandID("f-1"))))
        _ = apply(&state, .queueOp(.submitFollowUp(text: "two", commandID: CommandID("f-1"))))
        #expect(state.queue.count == 1, "one command, one row — never duplicates")
    }

    @Test("UX-QUEUE-02 denial rolls back the optimistic row")
    func UX_QUEUE_02_denialRollsBack() throws {
        var state = UIState()
        _ = apply(&state, .queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))))
        #expect(state.queue.count == 1)
        let fx = apply(&state, .session(.denied(cause: "policy")))
        #expect(state.queue.isEmpty, "optimistic row rolled back")
        #expect(fx.isEmpty, "denial produces no new effects")
        if case .failed = state.status { } else { Issue.record("status must be failed") }
    }

    @Test("UX-QUEUE-04 queue order survives sync FIFO")
    func UX_QUEUE_04_orderPreserved() throws {
        var state = UIState()
        _ = apply(&state, sync(entries: [
            entry("q-1", command: "a", order: 1),
            entry("q-2", command: "b", kind: .steer, order: 2),
            entry("q-3", command: "c", order: 3)], acked: [CommandID("a"), CommandID("b"), CommandID("c")]))
        #expect(state.queue.map(\.entryID) == ["q-1", "q-2", "q-3"], "FIFO order kept")
    }

    @Test("UX-QUEUE-05 reorder intent carries entry and anchor")
    func UX_QUEUE_05_reorderIntent() throws {
        let (_, fx) = reduce(UIState(), .queueOp(.reorderEntry(entryID: "q-2", beforeID: "q-1")))
        #expect(fx == [.queueReorder(entryID: "q-2", beforeID: "q-1")], "single reorder intent")
    }

    @Test("UX-QUEUE-03 steer intent never interleaves the draft")
    func UX_QUEUE_03_steerIsIntent() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("draft")))
        let fx = apply(&state, .queueOp(.submitSteer(text: "turn", commandID: CommandID("s-1"))))
        #expect(fx.count == 1, "exactly one effect")
        #expect(state.composer.text == "draft", "draft untouched")
        #expect(state.queue.count == 1 && state.queue[0].isOptimistic,
            "only a visibly-pending optimistic row until Core confirms")
    }

    @Test("UX-QUEUE-07 cancel intent and held projection")
    func UX_QUEUE_07_cancelHolds() throws {
        var state = UIState()
        let fx = apply(&state, .queueOp(.cancelRun))
        #expect(fx == [.cancelCurrent], "cancel intent routes to the actor")
        _ = apply(&state, sync(entries: [entry("q-1", command: "a", state: .held)], held: true, reason: .cancelled(sinceMillis: 9)))
        if case .held(let reason) = state.status { #expect(reason.contains("cancel")) }
        else { Issue.record("status must be held, got \(state.status)") }
        #expect(state.queue.count == 1, "held queue stays visible")
        let fx2 = apply(&state, .queueOp(.resumeQueue))
        #expect(fx2.count == 1, "resume is explicit, never automatic")
    }

    @Test("UX-QUEUE-11 approval intents carry minted IDs; absent approval emits nothing")
    func UX_QUEUE_11_approvalIntents() throws {
        var state = UIState()
        #expect(apply(&state, .queueOp(.grantApproval)).isEmpty, "no approval: no effect")
        #expect(apply(&state, .queueOp(.denyApproval(reason: "no"))).isEmpty, "no approval: no effect")
        _ = apply(&state, sync(approval: ApprovalRequestView(
            requestID: RequestID("r-1"), generation: Revision(3), operation: "rm -rf /",
            requiredGrant: "exec", protectedPaths: ["/"], sandbox: false)))
        #expect(state.pendingApproval?.requestID == RequestID("r-1"), "view projected")
        let fx = apply(&state, .queueOp(.grantApproval))
        #expect(fx == [.decideApproval(.approve, requestID: RequestID("r-1"), generation: Revision(3))])
        let fx2 = apply(&state, .queueOp(.denyApproval(reason: "no")))
        #expect(fx2 == [.decideApproval(.deny("no"), requestID: RequestID("r-1"), generation: Revision(3))])
    }

    @Test("UX-QUEUE-11 sandbox approval routes sandboxGrant, never human approve")
    func UX_QUEUE_11_sandboxGrantKind() throws {
        var state = UIState()
        _ = apply(&state, sync(approval: ApprovalRequestView(
            requestID: RequestID("r-2"), generation: Revision(4), operation: "exec",
            requiredGrant: "exec", protectedPaths: [], sandbox: true)))
        let fx = apply(&state, .queueOp(.grantApproval))
        #expect(fx == [.decideApproval(.sandboxGrant(note: "operator-confirmed"), requestID: RequestID("r-2"), generation: Revision(4))],
            "sandbox context preserves decision kind, got \(fx)")
    }

    @Test("UX-QUEUE-12 failed run keeps queue visible with no auto-resume")
    func UX_QUEUE_12_failedKeepsQueue() throws {
        var state = UIState()
        _ = apply(&state, sync(entries: [entry("q-1", command: "a")], acked: [CommandID("a")]))
        let fx = apply(&state, .session(.runUpdate(phase: "failed", detail: "boom")))
        #expect(state.queue.count == 1, "queue stays visible")
        #expect(!fx.contains(where: { if case .queueResume = $0 { return true }; return false }),
            "no surprise continuation")
        if case .failed = state.status { } else { Issue.record("status must be failed") }
    }

    @Test("UX-QUEUE-01 stream delta touches neither draft nor queue")
    func UX_QUEUE_01_deltaIgnores() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("typing")))
        _ = apply(&state, sync(entries: [entry("q-1", command: "a")], acked: [CommandID("a")]))
        let before = state
        let fx = apply(&state, .session(.delta(requestID: RequestID("r-9"), text: "chunk")))
        #expect(state == before, "delta is display-hint only")
        #expect(fx.isEmpty)
    }

    @Test("UX-QUEUE-08 stale target entry is marked and rendered")
    func UX_QUEUE_08_staleTargetMarked() throws {
        var state = UIState()
        var old = entry("q-1", command: "a", order: 1)
        old = QueueEntry(entryID: old.entryID, commandID: old.commandID, kind: old.kind,
            state: old.state, revision: old.revision, text: old.text,
            targetEpochID: EpochID("e-0"), orderKey: old.orderKey, rank: old.rank)
        _ = apply(&state, sync(entries: [old], acked: [CommandID("a")], epoch: EpochID("e-1")))
        #expect(state.queue.first?.staleTarget == true, "epoch drift flagged")
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(frame.lines.contains(where: { $0.id == "queue-q-1" && $0.runs.map(\.text).joined().contains("stale") }),
            "stale marker rendered")
    }
}
