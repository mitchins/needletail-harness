import Testing
import Foundation
import NeedletailCore

/// Focused oracles for the completed-slice residuals S1/S5/S6/S7/S9.
/// Each pins the exact fixed behavior; forbids regressions to the hole.
struct ResidualFixTests {

    private static func streamingWithMutating(ids: inout DeterministicIDSource) throws -> SessionState {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        var live = state.liveReservations
        live.append(EffectReservation(
            effectID: EffectID("eff-mut"), runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: true, kind: .executor))
        return state.replacing(liveReservations: live)
    }

    @Test("S1 marker bound overflows to a visible integrity stop")
    func markerBoundIntegrityStop() throws {
        var ids = StateFixtures.ids()
        let base = try Self.streamingWithMutating(ids: &ids)
        // 63 markers + cancel retention of 1 = 64: still legal.
        let padded = base.replacing(unresolvedOperations: (0..<63).map {
            OperationRef(operationID: OperationID("op-\($0)"), state: .unknown, mutating: false)
        })
        let full = transition(padded, .cancelRequested(atMillis: 2000), &ids)
        #expect(full.state.unresolvedOperations.count == 64, "64th marker retained")
        guard case .cancelling = full.state.phase else {
            Issue.record("64 markers must still cancel, got \(full.state.phase)"); return
        }
        // One more retention overflows visibly — never silently.
        var ids2 = StateFixtures.ids(prefix: "u")
        let armed = try Self.streamingWithMutating(ids: &ids2).replacing(unresolvedOperations: (0..<64).map {
            OperationRef(operationID: OperationID("op-\($0)"), state: .unknown, mutating: false)
        })
        let stopped = transition(armed, .cancelRequested(atMillis: 2000), &ids2)
        guard case .failed(let failure) = stopped.state.phase else {
            Issue.record("65th marker must integrity-stop, got \(stopped.state.phase)"); return
        }
        guard case .integrityStopped = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(stopped.state.unresolvedOperations.count == 64, "no silent growth past the bound")
    }

    @Test("S5 withdrawn retry replays the withdrawn ack")
    func withdrawnAckTracksTombstone() throws {
        var ids = StateFixtures.ids()
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(
            requestID: admitting.activeRun!.requestID, atMillis: 1001), &ids).state
        state = transition(state, StateFixtures.input("bye", id: "w-9"), &ids).state
        let entryID = try #require(state.queue.first?.entryID)
        state = transition(state, .queueWithdraw(entryID: entryID, atMillis: 1002), &ids).state
        #expect(state.admittedCommands[CommandID("w-9")]?.state == .withdrawn, "index tracks the tombstone")
        let retry = transition(state, StateFixtures.input("again", id: "w-9"), &ids)
        #expect(retry.state.admittedCommands[CommandID("w-9")]?.state == .withdrawn, "retry replays withdrawn, not queued")
    }

    @Test("S6 sealed entries keep sealing into auto-dispatched runs")
    func sealedEntryKeepsSealing() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        // Sealed follow-up queued behind the non-sealed run.
        state = transition(state, StateFixtures.input("sealed next", id: "s-9", kind: .followUp, sealed: true), &ids).state
        #expect(state.queue.first?.sealed == true, "entry carries its own sealed flag")
        // Final response auto-dispatches the entry into a sealed run.
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: true))
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids).state
        guard case .admitting = state.phase, let next = state.activeRun else {
            Issue.record("expected auto-dispatched admitting, got \(state.phase)"); return
        }
        #expect(next.sealed, "dispatched run inherits the entry's sealing")
    }

    @Test("S7 matching transport confirmation short-circuits cancel grace")
    func transportConfirmationShortCircuits() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .cancelRequested(atMillis: 2000), &ids).state
        guard case .cancelling = state.phase else {
            Issue.record("expected cancelling"); return
        }
        // Confirmation for the cancelled run (old generation): interrupted now.
        let confirmed = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .ambiguous, error: "server confirmed stop", atMillis: 2001), &ids)
        guard case .interrupted = confirmed.state.phase else {
            Issue.record("confirmation must short-circuit, got \(confirmed.state.phase)"); return
        }
        // Foreign confirmation still drops.
        let foreign = transition(state, .transportFailed(
            requestID: RequestID("other"), generation: run.revision,
            phase: .ambiguous, error: "x", atMillis: 2001), &ids)
        #expect(foreign.state.phase == .cancelling, "foreign confirmation drops")
        #expect(foreign.state.droppedStaleCount == state.droppedStaleCount + 1)
    }

    @Test("S9 continuation with markers holds instead of dispatching")
    func continuationBlockedByMarkers() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        // Live non-mutating reservation + an unrelated marker standing.
        let effectID = EffectID("eff-live")
        var live = state.liveReservations
        live.append(EffectReservation(
            effectID: effectID, runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: false, kind: .provider))
        let marker = OperationRef(operationID: OperationID("op-u"), state: .unknown, mutating: true)
        state = state.replacing(phase: .executing, liveReservations: live, unresolvedOperations: [marker])
        let held = transition(state, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("ok"), atMillis: 1002), &ids)
        #expect(held.state.queueHeld, "markers block continuation")
        #expect(!held.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "no re-request while markers stand")
    }
}
