import Testing
import Foundation
import NeedletailCore

/// Remediation R3 — oversized batches (M3-D T08: a turn proposing more
/// than 8 tool calls died terminally although nothing had executed).
/// Policy: the first two oversized postContent failures per run answer
/// with a bounded model-visible rejection + provider continuation; the
/// third, or any oversized failure past the turn budget, fails exactly
/// as before. Non-marker postContent errors are untouched (terminal).
struct OversizedBatchTests {

    private static func streaming(ids: inout DeterministicIDSource) throws -> (SessionState, RunDescriptor) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let requesting = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1000), &ids).state
        guard case .requesting = requesting.phase else {
            Issue.record("expected requesting"); throw FixtureFailure.admission
        }
        let started = transition(requesting, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1100), &ids).state
        guard case .streaming = started.phase else {
            Issue.record("expected streaming"); throw FixtureFailure.admission
        }
        return (started, run)
    }

    private static func oversizedError() -> String {
        "\(oversizedBatchMarker): more than 8 tool calls (limit 8 per turn; no tools ran; resubmit the work as 8 or fewer calls per turn)"
    }

    private static func failedPhase(_ t: Transition) -> SessionPhase {
        t.state.phase
    }

    @Test("R3 oversized batch continues with a model-visible notice")
    func oversizedContinues() throws {
        var ids = StateFixtures.ids()
        let (state, run) = try Self.streaming(ids: &ids)
        let turnsBefore = state.turnsUsed
        let out = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .postContent, error: Self.oversizedError(), atMillis: 2000), &ids)
        guard case .requesting = out.state.phase else {
            Issue.record("oversized batch must continue requesting, got \(out.state.phase)"); return
        }
        #expect(out.state.oversizedBatchContinuations == 1, "continuation counter increments")
        #expect(out.state.turnsUsed == turnsBefore + 1, "the spent turn is consumed")
        #expect(out.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "exactly one fresh provider request")
        // Model-visible: a .user harness notice carrying the bound.
        let users = out.records.compactMap { r -> String? in
            if case .transcriptAppended(.user(let text)) = r { return text }
            return nil
        }
        #expect(users.count == 1, "exactly one model-visible notice, got \(users.count)")
        #expect(users[0].contains("8"), "notice carries the exact bound")
        #expect(users[0].contains("no tools ran"), "notice states nothing executed")
        // No intents/results: nothing ran, nothing to reconcile.
        #expect(!out.records.contains(where: {
            if case .operationIntent = $0 { return true }
            return false
        }), "no intents for a batch that never existed")
        #expect(!out.records.contains(where: {
            if case .operationResult = $0 { return true }
            return false
        }), "no results for a batch that never existed")
    }

    @Test("R3 third oversized batch fails terminally")
    func oversizedBounded() throws {
        var ids = StateFixtures.ids()
        var (state, run) = try Self.streaming(ids: &ids)
        state = state.replacing(oversizedBatchContinuations: 2)
        let out = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .postContent, error: Self.oversizedError(), atMillis: 2000), &ids)
        guard case .failed(let failure) = Self.failedPhase(out) else {
            Issue.record("third oversized batch must fail, got \(out.state.phase)"); return
        }
        guard case .providerError(let msg) = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(msg.contains("oversized tool batch repeated"), "terminal message names the repetition, got \(msg)")
    }

    @Test("R3 non-marker postContent still fails terminally")
    func nonMarkerUntouched() throws {
        var ids = StateFixtures.ids()
        let (state, run) = try Self.streaming(ids: &ids)
        let out = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .postContent, error: "malformedEvent: delta.content is not a string", atMillis: 2000), &ids)
        guard case .failed(let failure) = Self.failedPhase(out) else {
            Issue.record("ordinary postContent failure must stay terminal, got \(out.state.phase)"); return
        }
        guard case .providerError(let msg) = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(msg.contains("provider stream failed"), "unchanged terminal mapping, got \(msg)")
        #expect(out.state.oversizedBatchContinuations == 0, "counter untouched by ordinary failures")
    }

    @Test("R3 oversized batch past the turn budget still exhausts")
    func oversizedPastBudget() throws {
        var ids = StateFixtures.ids()
        var (state, run) = try Self.streaming(ids: &ids)
        state = state.replacing(turnsUsed: state.turnLimit)
        let out = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .postContent, error: Self.oversizedError(), atMillis: 2000), &ids)
        guard case .failed(let failure) = Self.failedPhase(out) else {
            Issue.record("oversized past budget must fail, got \(out.state.phase)"); return
        }
        guard case .budgetExhausted = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
    }

    @Test("R3 counter resets on fresh admission")
    func counterResetsOnAdmission() throws {
        var ids = StateFixtures.ids()
        // Admission path resets run counters (turnsUsed, preSendRetries).
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        #expect(admitting.oversizedBatchContinuations == 0, "fresh admission starts at zero continuations")
        #expect(admitting.turnsUsed == 0 && admitting.preSendRetries == 0, "run counters reset")
    }
}
