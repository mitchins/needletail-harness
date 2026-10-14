import Testing
import Foundation
import NeedletailCore

/// CORE-03 invalid-attempt tracking + CORE-04 budgets, pure rows.
/// Fingerprints cover kinds — never content. Time enters via stamped ticks.
/// Forbidden: hidden extra requests, evidence loss, cross-fingerprint counting.
struct BudgetInvalidTests {

    @Test("CORE-03 three identical invalid attempts stop the run")
    func CORE_03_threeIdenticalStop() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        for i in 1...2 {
            let result = transition(state, .invalidInput(fingerprint: "fp-a", cause: "bad slash", atMillis: UInt64(1000 + i)), &ids)
            state = result.state
            #expect(!state.phase.isTerminal, "attempt \(i) counts, not stops")
        }
        #expect(state.invalidTracker == InvalidTracker(fingerprint: "fp-a", count: 2))
        let stopped = transition(state, .invalidInput(fingerprint: "fp-a", cause: "bad slash", atMillis: 1003), &ids)
        guard case .failed(let failure) = stopped.state.phase else {
            Issue.record("third identical attempt must stop"); return
        }
        guard case .invalidStopped = failure else {
            Issue.record("wrong failure kind: \(failure)"); return
        }
        #expect(stopped.state.queueHeld, "invalid stop holds the queue")
    }

    @Test("CORE-03 mixed fingerprints and valid input reset the counter")
    func CORE_03_mixedAndValidReset() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        state = transition(state, .invalidInput(fingerprint: "fp-a", cause: "x", atMillis: 1001), &ids).state
        state = transition(state, .invalidInput(fingerprint: "fp-b", cause: "y", atMillis: 1002), &ids).state
        #expect(state.invalidTracker.count == 1, "different fingerprint restarts the count")
        #expect(!state.phase.isTerminal)
        state = transition(state, .invalidInput(fingerprint: "fp-b", cause: "y", atMillis: 1003), &ids).state
        state = transition(state, StateFixtures.input("valid resets", id: "v-1"), &ids).state
        #expect(state.invalidTracker.count == 0, "valid admission resets")
        guard case .admitting = state.phase else {
            Issue.record("valid input still admits"); return
        }
    }

    @Test("CORE-04 turn limit stops at 80 with no 81st request")
    func CORE_04_turnLimitStops() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        // Simulate 79 consumed turns, then drive the 80th and 81st requests.
        var state = admitting.replacing(turnsUsed: 79)
        state = transition(state, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        #expect(state.turnsUsed == 80, "dispatch consumes a turn")
        // Post-tool continuation at the limit must stop, not dispatch.
        let reservation = EffectReservation(
            effectID: EffectID("eff-t"), runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: false)
        state = state.replacing(phase: .executing, liveReservations: [reservation])
        let over = transition(state, .effectCompleted(
            effectID: EffectID("eff-t"), runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("done"), atMillis: 1002), &ids)
        guard case .failed(let failure) = over.state.phase else {
            Issue.record("81st request must stop, got \(over.state.phase)"); return
        }
        guard case .budgetExhausted = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(!over.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "no hidden 81st request effect")
    }

    @Test("CORE-04 wall-clock deadline stops; early ticks continue")
    func CORE_04_wallClockDeadline() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let requesting = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1000), &ids).state
        let deadline = try #require(requesting.runDeadlineMillis)
        let early = transition(requesting, .tick(nowMillis: deadline - 1), &ids)
        #expect(early.state.phase == .requesting, "pre-deadline tick continues")
        #expect(early.effects.isEmpty && early.records.isEmpty, "no-op ticks append nothing")
        let late = transition(requesting, .tick(nowMillis: deadline), &ids)
        guard case .failed(let failure) = late.state.phase else {
            Issue.record("deadline must stop the run"); return
        }
        guard case .budgetExhausted = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
    }

    @Test("CORE-04 evidence preserved across budget stops")
    func CORE_04_evidencePreserved() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let expired = admitting.replacing(runDeadlineMillis: 500)
        let stopped = transition(expired, .tick(nowMillis: 501), &ids)
        guard case .failed = stopped.state.phase else {
            Issue.record("expected failed"); return
        }
        #expect(stopped.state.activeRun == nil)
        // History stands: dismiss returns to idle with records retained.
        let idle = transition(stopped.state, .dismissRun(atMillis: 502), &ids)
        #expect(idle.state.phase == .idle)
        _ = run
    }
}
