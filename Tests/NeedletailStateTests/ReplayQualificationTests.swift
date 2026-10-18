import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// STATE-01 replay with a REAL reserved effect (no fabricated IDs).
///
/// The trace drives the reducer through the production reservation path
/// (provider response carrying a reads batch → validation → trusted
/// dispatch reserves one effect via `DeterministicIDSource`), then cancels
/// and delivers the late completion for THAT reserved effect ID.
/// Oracles are independent: state (phase, counters, reservations cleared),
/// effects (cancel shape present, re-request/reservation forbidden after
/// cancel, bare drop on the late completion) and receipts (cancel record
/// present, late completion appends nothing).
struct ReplayQualificationTests {

    private struct Trace {
        let final: SessionState
        let reservedID: EffectID
        let preCancelDropped: Int
        let cancelled: SessionState
        let late: Transition
    }

    private static func run() throws -> Trace {
        var ids = StateFixtures.ids()
        // Permissive grant + workspace reads: trusted dispatch, no approval.
        let epoch = try StateFixtures.epoch(permissive: true)
        _ = try validateTrustConsistency(mode: .workspace, caps: epoch.effectiveCaps.tools)
        var state = SessionState(sessionID: SessionID("s-1"), epoch: epoch, trustMode: .workspace, phase: .idle)
        state = transition(state, StateFixtures.input("run", id: "cmd-1"), &ids).state
        let run = try #require(state.activeRun, "admission must reserve a run")
        state = transition(state, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(
            requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d")])
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(text: "calls", toolProposals: batch.proposals, isFinal: false)),
            atMillis: 1003), &ids).state
        let dispatch = transition(state, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids)
        // STATE ORACLE (pre-cancel): exactly one live reservation.
        #expect(dispatch.state.phase == .executing, "reads dispatch executes, got \(dispatch.state.phase)")
        #expect(dispatch.state.liveReservations.count == 1, "one intent reserved before dispatch")
        // EFFECT ORACLE (pre-cancel): the reservation is the REAL one the
        // reducer minted — extract it from the transition output, never
        // invent an ID.
        guard case .reserveEffect(let reservation) = dispatch.effects.first,
              dispatch.effects.count == 1 else {
            Issue.record("dispatch must emit exactly one reserveEffect, got \(dispatch.effects)")
            throw FixtureFailure.admission
        }
        #expect(dispatch.state.liveReservations.first == reservation, "live table matches minted reservation")
        state = dispatch.state

        let cancelled = transition(state, .cancelRequested(atMillis: 1005), &ids)
        // STATE ORACLE (cancelled): reservations cleared, queue held.
        #expect(cancelled.state.phase == .cancelling, "cancel lands in cancelling")
        #expect(cancelled.state.liveReservations.isEmpty, "cancel clears live reservations")
        // EFFECT ORACLE (cancelled): in-flight cancel signalled, and the
        // forbidden shapes are absent — no re-request, no new reservation.
        #expect(cancelled.effects.contains(.cancelInFlight(runID: run.runID, reason: "operator cancel")),
                "cancel must signal in-flight work")
        #expect(!cancelled.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            if case .reserveEffect = $0 { return true }
            return false
        }), "cancel must not re-request or reserve")
        // RECEIPT ORACLE (cancelled): a `cancelling` receipt exists —
        // presence alone would pass without proving the cancel was recorded.
        #expect(cancelled.records.contains(where: {
            if case .eventAppended(_, "cancelling", _) = $0 { return true }
            return false
        }), "cancel must leave a cancelling receipt, got \(cancelled.records)")
        let preCancelDropped = cancelled.state.droppedStaleCount

        // Late completion for the CANCELLED reservation (real ID).
        let late = transition(cancelled.state, .effectCompleted(
            effectID: reservation.effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("late"), atMillis: 1006), &ids)
        return Trace(final: late.state, reservedID: reservation.effectID,
                     preCancelDropped: preCancelDropped, cancelled: cancelled.state, late: late)
    }

    @Test("STATE-01 replay: identical cancellation trace yields identical state and no late resurrection")
    func STATE_01_cancelledLateCompletionReplays() throws {
        let a = try Self.run()
        let b = try Self.run()
        // Determinism: the same trace from the same seed is bit-identical.
        #expect(a.final == b.final, "replay must be deterministic")
        #expect(a.reservedID == b.reservedID, "deterministic IDs mint the same reservation")
        // STATE ORACLE (late): no resurrection, exactly one stale drop, and
        // the drop changes NOTHING else — whole-state preservation.
        #expect(a.final.phase == .cancelling, "cancelled run does not become completed")
        #expect(a.final.droppedStaleCount == a.preCancelDropped + 1, "late completion drops exactly once")
        #expect(a.final == a.cancelled.replacing(droppedStaleCount: a.preCancelDropped + 1),
                "stale drop must preserve the whole cancelled state")
        #expect(a.final.liveReservations.isEmpty, "late completion reserves nothing")
        // EFFECT + RECEIPT ORACLES (late): bare drop — nothing out, nothing appended.
        #expect(a.late.effects.isEmpty, "late completion emits no effects, got \(a.late.effects)")
        #expect(a.late.records.isEmpty, "late completion appends no receipts, got \(a.late.records)")
    }
}
