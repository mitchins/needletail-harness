import Testing
import Foundation
import NeedletailCore

/// STATE-01 pure rows — every ID-carrying event that mismatches the live
/// run (or replays a consumed effect) drops with a counter bump and zero
/// side effects. Forbidden: state advance, dispatch, history append, draft
/// effects, forgotten mutating outcomes.
struct StaleCompletionTests {

    private static func liveTriple(ids: inout DeterministicIDSource) throws -> (SessionState, RunDescriptor, EffectID) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let requesting = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        let streaming = transition(
            requesting, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        // Simulate one live non-mutating reservation (provider request shape).
        let effectID = EffectID("eff-live")
        let reservation = EffectReservation(
            effectID: effectID, runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
        return (streaming.replacing(liveReservations: [reservation]), run, effectID)
    }

    private static func staleResponse(run: RunDescriptor, generation: Revision) -> SessionEvent {
        .providerResponse(
            requestID: run.requestID, generation: generation,
            response: ProviderResponse(requestID: run.requestID, generation: generation,
                outcome: .textDeltaComplete(text: "stale", toolProposals: [], isFinal: true)),
            atMillis: 5000)
    }

    @Test("STATE-01 old-generation and post-cancel completions drop")
    func STATE_01_staleGenerationsDrop() throws {
        var ids = StateFixtures.ids()
        let (streaming, run, _) = try Self.liveTriple(ids: &ids)
        let before = streaming.droppedStaleCount
        // Old generation.
        let old = transition(streaming, Self.staleResponse(run: run, generation: Revision(0)), &ids)
        #expect(old.state.droppedStaleCount == before + 1)
        #expect(old.state.phase == .streaming, "no advance on stale")
        #expect(old.effects.isEmpty && old.records.isEmpty, "no effects, no history")
        // Post-cancel generation (cancel bumps to 2; run was 1).
        let cancelled = transition(streaming, .cancelRequested(atMillis: 6000), &ids)
        let late = transition(cancelled.state, Self.staleResponse(run: run, generation: run.revision), &ids)
        #expect(late.state.droppedStaleCount == cancelled.state.droppedStaleCount + 1)
    }

    @Test("STATE-01 duplicate effect redelivery drops as consumed")
    func STATE_01_duplicateRedeliveryDrops() throws {
        var ids = StateFixtures.ids()
        let (streaming, run, effectID) = try Self.liveTriple(ids: &ids)
        // First acceptance consumes (simulate: mark consumed + advance).
        var consumed = streaming.consumedEffects
        consumed.insert(effectID)
        let advanced = streaming.replacing(phase: .requesting, consumedEffects: consumed)
        let dup = transition(advanced, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("again"), atMillis: 7000), &ids)
        #expect(dup.state.droppedStaleCount == advanced.droppedStaleCount + 1)
        #expect(dup.state.unresolvedOperations.isEmpty, "consumed duplicate adds no unknown marker — outcome stands")
    }

    @Test("STATE-01 unconsumed mutating mismatch retains unknown")
    func STATE_01_mutatingMismatchRetainsUnknown() throws {
        var ids = StateFixtures.ids()
        let (streaming, run, effectID) = try Self.liveTriple(ids: &ids)
        var reservations = streaming.liveReservations
        reservations.append(EffectReservation(
            effectID: EffectID("eff-mut"), runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: true, kind: .executor))
        let armed = streaming.replacing(liveReservations: reservations)
        // Wrong revision for a live mutating effect: outcome unknowable.
        let dropped = transition(armed, .effectCompleted(
            effectID: EffectID("eff-mut"), runID: run.runID, generation: run.revision,
            expectedRevision: Revision(999), mutating: true,
            outcome: .success("maybe"), atMillis: 7000), &ids)
        #expect(dropped.state.droppedStaleCount == armed.droppedStaleCount + 1)
        #expect(dropped.state.unresolvedOperations.count == 1)
        #expect(dropped.state.unresolvedOperations.first?.state == .unknown)
        #expect(dropped.records.contains(where: {
            if case .operationResult(_, let outcome) = $0 { return outcome == "unknown" }
            return false
        }))
        #expect(!dropped.state.liveReservations.contains(where: { $0.effectID == EffectID("eff-mut") }))
        _ = effectID
    }

    @Test("STATE-01 stale approvals and transport failures drop")
    func STATE_01_staleApprovalsAndTransportDrop() throws {
        var ids = StateFixtures.ids()
        let (streaming, run, _) = try Self.liveTriple(ids: &ids)
        let before = streaming.droppedStaleCount
        // Approval with no pending approval and wrong generation.
        var state = streaming
        state = transition(state, .approvalGrant(requestID: run.requestID, generation: Revision(0), atMillis: 8000), &ids).state
        #expect(state.droppedStaleCount == before + 1)
        // Transport failure for an unknown request.
        state = transition(state, .transportFailed(
            requestID: RequestID("ghost"), generation: run.revision,
            phase: .ambiguous, error: "x", atMillis: 8001), &ids).state
        #expect(state.droppedStaleCount == before + 2)
        // RequestStarted for a finished generation.
        state = transition(state, .requestStarted(requestID: run.requestID, generation: Revision(0), atMillis: 8002), &ids).state
        #expect(state.droppedStaleCount == before + 3)
        #expect(state.phase == .streaming, "drops never advance the phase")
    }
}
