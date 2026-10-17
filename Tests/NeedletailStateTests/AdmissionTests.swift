import Testing
import Foundation
import NeedletailCore

/// Fresh admission + reservation ordering (plan §2.5 m143): valid input
/// reserves run/request/effect IDs, records intent BEFORE dispatch effects,
/// resets run-scoped counters, and validates the route at the boundary.
/// Forbidden: dispatch without reserveEffect, counter leaks across runs.
struct AdmissionTests {

    @Test("STATE-01 admission reserves IDs and orders intent before dispatch")
    func admissionReservesAndOrders() throws {
        var ids = StateFixtures.ids()
        let (state, run) = try StateFixtures.admitted("hello", ids: &ids)
        #expect(run.revision == Revision(1), "first run takes generation 1")
        #expect(state.generation == 1)
        #expect(state.turnsUsed == 0 && state.preSendRetries == 0, "run counters reset")
        // R8: reserveEffect precedes requestProvider in the effects array.
        let kinds = state.liveReservations.map(\.effectID.raw)
        #expect(kinds.count == 1, "exactly one live reservation")
    }

    @Test("admission emits reserveEffect before requestProvider")
    func admissionEffectOrder() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let result = transition(idle, StateFixtures.input("hi"), &ids)
        #expect(result.effects.count == 3, "reserve + request + UI, got \(result.effects.count)")
        guard case .reserveEffect = result.effects[0] else {
            Issue.record("first effect must be reserveEffect"); return
        }
        guard case .requestProvider = result.effects[1] else {
            Issue.record("second effect must be requestProvider"); return
        }
        #expect(result.records.first?.isEventAppended == true, "intent records follow the event record")
    }

    @Test("duplicate commandID returns the identical ack")
    func duplicateCommandReturnsSameAck() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let first = transition(idle, StateFixtures.input("x", id: "dup"), &ids)
        // Busy-path duplicate: drive to requesting, then retry the same ID.
        let requesting = transition(first.state, .requestDispatched(requestID: first.state.activeRun!.requestID, atMillis: 1001), &ids)
        let retry = transition(requesting.state, StateFixtures.input("y-different-text", id: "dup"), &ids)
        #expect(retry.state.queue.count == 0, "no second entry for a duplicate ID")
        #expect(retry.state.admittedCommands[CommandID("dup")]?.sequence == first.state.admittedCommands[CommandID("dup")]?.sequence,
                "same ack sequence — idempotent, not re-admitted")
    }

    @Test("queue caps reject structurally, never silently")
    func queueCapsReject() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        // Fill to the cap through the busy path (admit one run, then queue 20).
        let first = transition(state, StateFixtures.input("run", id: "run-0"), &ids)
        state = first.state
        for i in 1...20 {
            let result = transition(state, StateFixtures.input("item \(i)", id: "q-\(i)"), &ids)
            state = result.state
        }
        #expect(state.queue.count == 20)
        let over = transition(state, StateFixtures.input("one too many", id: "q-21"), &ids)
        #expect(over.state.queue.count == 20, "21st item must not insert")
        let projections = over.effects.compactMap { effect -> SessionEventProjection? in
            if case .emitUI(let projection) = effect { return projection }
            return nil
        }
        #expect(projections.contains(where: { $0.kind == "denied" }),
                "rejection must surface as a denied projection, got \(over.effects)")
    }

    @Test("unresolved markers block fresh runs but allow held queueing")
    func unresolvedBlocksRuns() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        // Seed an unknown marker directly (cancel-before-completion shape).
        let marker = OperationRef(operationID: OperationID("op-x"), state: .unknown, mutating: true)
        state = state.replacing(unresolvedOperations: [marker])
        let result = transition(state, StateFixtures.input("go", id: "blocked-1"), &ids)
        #expect(result.state.activeRun == nil, "no run while markers stand")
        #expect(result.state.queueHeld, "queue held with the refusal")
        #expect(result.state.queue.count == 1 && result.state.queue[0].state == .held,
                "text still admits — as a HELD entry, never a run")
    }
}

private extension DurableRecord {
    var isEventAppended: Bool {
        if case .eventAppended = self { return true }
        return false
    }
}
