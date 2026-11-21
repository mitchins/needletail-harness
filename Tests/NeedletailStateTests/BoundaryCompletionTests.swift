import Testing
import Foundation
import NeedletailCore

/// Remediation R4 — quiescent-at-boundary completion. A fully resolved
/// tool batch at the turn budget lands completed (telemetry kind
/// "completed-budget-boundary") instead of failed: the verdict still
/// comes from the oracle. Unknown outcomes still hold the queue, and
/// mid-pipeline budget guards (validation and friends, where the model
/// never saw results) still fail terminally.
struct BoundaryCompletionTests {

    private static func executingState(
        batch: ToolBatch, ids: inout DeterministicIDSource
    ) throws -> (SessionState, RunDescriptor) {
        var state = try StateFixtures.idle(permissive: true)
        let run = RunDescriptor(runID: RunID("run-1"), requestID: RequestID("req-1"), revision: Revision(1), startedAtMillis: 1000, sealed: false)
        state = state.replacing(phase: .executing, activeRun: run, liveReservations: [
            EffectReservation(effectID: EffectID("eff-1"), runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, batch: batch, kind: .executor)
        ], generation: 1)
        return (state, run)
    }

    private static func validatingState(ids: inout DeterministicIDSource) throws -> SessionState {
        var state = try StateFixtures.idle(trustMode: .workspace, permissive: true)
        state = transition(state, StateFixtures.input("run", id: "a-1"), &ids).state
        state = transition(state, .requestDispatched(requestID: state.activeRun!.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: state.activeRun!.requestID, generation: state.activeRun!.revision, atMillis: 1002), &ids).state
        return state
    }

    @Test("R4 resolved batch at the budget lands completed-boundary")
    func boundaryLandsCompleted() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        var (state, run) = try Self.executingState(batch: batch, ids: &ids)
        state = state.replacing(turnsUsed: 80, turnLimit: 80)
        let out = transition(state, .effectCompleted(
            effectID: EffectID("eff-1"), runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("file"), atMillis: 1010), &ids)
        guard case .completed = out.state.phase else {
            Issue.record("boundary landing must complete, got \(out.state.phase)"); return
        }
        #expect(out.state.activeRun == nil, "completed run releases the run")
        #expect(out.records.contains(where: {
            if case .eventAppended(_, let kind, _) = $0 { return kind == "completed-budget-boundary" }
            return false
        }), "boundary landing is marked, not plain completed")
        #expect(!out.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "no further provider request")
        #expect(!out.state.queueHeld, "clean boundary does not hold the queue")
        #expect(out.effects.contains(where: {
            if case .emitUI(let p) = $0 {
                return p.kind == "run:budget-boundary"
                    && p.detail == "run finished at turn-budget boundary; verdict by oracle"
            }
            return false
        }), "boundary landing projects the distinct UI kind, not plain run:completed")
    }

    @Test("R4 unknown outcomes at the budget still hold, never complete")
    func unknownStillHoldsAtBoundary() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        var (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let marker = OperationRef(operationID: OperationID("op-1"), callID: "c0", state: .unknown, mutating: false)
        state = state.replacing(turnsUsed: 80, turnLimit: 80, unresolvedOperations: [marker])
        let out = transition(state, .effectCompleted(
            effectID: EffectID("eff-1"), runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("file"), atMillis: 1010), &ids)
        #expect(out.state.queueHeld, "unknown outcomes hold the queue even at the budget")
        guard case .executing = out.state.phase else {
            Issue.record("held continuation stays live, got \(out.state.phase)"); return
        }
    }

    @Test("R4 mid-pipeline validation budget guard still fails")
    func validationBudgetStillFails() throws {
        var ids = StateFixtures.ids()
        var state = try Self.validatingState(ids: &ids)
        let run = try #require(state.activeRun)
        // Drive a response carrying an invalid batch (absolute path), then
        // validation at the turn limit: the model never saw results, so
        // the run must fail, not complete.
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"/etc/passwd\"}")
            ], isFinal: false))
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids).state
        state = state.replacing(turnsUsed: 80, turnLimit: 80)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"/etc/passwd\"}")])
        let out = transition(state, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids)
        guard case .failed(let failure) = out.state.phase else {
            Issue.record("mid-pipeline budget exhaustion must fail, got \(out.state.phase)"); return
        }
        guard case .budgetExhausted(let msg) = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(msg.contains("after validation"), "validation guard unchanged, got \(msg)")
    }
}
