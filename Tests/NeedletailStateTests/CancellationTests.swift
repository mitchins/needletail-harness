import Testing
import Foundation
import NeedletailCore

/// CORE-02 pure rows — cancellation at every active state via direct
/// transition calls (actor interleavings live in NeedletailActorTests).
/// Given an active phase, When cancel arrives, Then generation bumps, the
/// queue holds, live mutating reservations retain unknown markers BEFORE
/// tables clear, and late completions drop. Forbidden: resurrection,
/// auto-dispatch, forgotten side effects, second owner.
struct CancellationTests {

    /// Drives idle → admitting → requesting → streaming, returning each prefix.
    static func streamingState(ids: inout DeterministicIDSource) throws -> (admitting: SessionState, requesting: SessionState, streaming: SessionState, run: RunDescriptor) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let requesting = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        guard case .requesting = requesting.phase else {
            Issue.record("expected requesting"); throw FixtureFailure.admission
        }
        let streaming = transition(
            requesting,
            .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        guard case .streaming = streaming.phase else {
            Issue.record("expected streaming"); throw FixtureFailure.admission
        }
        return (admitting, requesting, streaming, run)
    }

    @Test("CORE-02 cancel in requesting, streaming, admitting holds and bumps")
    func CORE_02_cancelActivePhases() throws {
        var ids = StateFixtures.ids()
        let (admitting, requesting, streaming, _) = try Self.streamingState(ids: &ids)
        for (name, state) in [("admitting", admitting), ("requesting", requesting), ("streaming", streaming)] {
            let gen = state.generation
            let cancelled = transition(state, .cancelRequested(atMillis: 2000), &ids)
            #expect(cancelled.state.phase == .cancelling, "\(name): must enter cancelling")
            #expect(cancelled.state.generation == gen + 1, "\(name): generation must bump")
            #expect(cancelled.state.queueHeld, "\(name): queue must hold")
            #expect(cancelled.state.liveReservations.isEmpty, "\(name): tables clear after retention")
            let kinds = cancelled.effects.compactMap { effect -> String? in
                switch effect {
                case .cancelInFlight: return "cancelInFlight"
                case .cancelTimer: return "cancelTimer"
                default: return nil
                }
            }
            #expect(kinds.contains("cancelInFlight"), "\(name): must emit cancelInFlight")
        }
    }

    @Test("CORE-02 cancel preserves mutating provenance before clearing")
    func CORE_02_cancelRetainsMutatingUnknown() throws {
        // Simulate a live mutating reservation (scripted-executor shape):
        // cancel must append its unknown marker BEFORE the tables clear.
        var ids = StateFixtures.ids()
        let prefixes = try Self.streamingState(ids: &ids)
        var streaming = prefixes.2
        var reservations = streaming.liveReservations
        reservations.append(EffectReservation(
            effectID: EffectID("eff-live"), runID: streaming.activeRun!.runID,
            requestID: streaming.activeRun!.requestID, generation: streaming.activeRun!.revision,
            revision: streaming.activeRun!.revision, mutating: true))
        streaming = streaming.replacing(liveReservations: reservations)
        let cancelled = transition(streaming, .cancelRequested(atMillis: 2000), &ids)
        #expect(cancelled.state.unresolvedOperations.count == 1, "one unknown marker retained")
        #expect(cancelled.state.unresolvedOperations.first?.state == .unknown)
        #expect(cancelled.state.unresolvedOperations.first?.mutating == true)
        #expect(cancelled.records.contains(where: {
            if case .operationResult(_, let outcome) = $0 { return outcome == "unknown" }
            return false
        }), "unknown record precedes invalidation")
        #expect(cancelled.state.liveReservations.isEmpty, "tables clear after retention")
    }

    @Test("CORE-02 cancel grace forces interrupted without confirmation")
    func CORE_02_cancelDeadlineForcesInterrupted() throws {
        var ids = StateFixtures.ids()
        let (_, _, streaming, _) = try Self.streamingState(ids: &ids)
        let cancelled = transition(streaming, .cancelRequested(atMillis: 2000), &ids)
        let early = transition(cancelled.state, .tick(nowMillis: 2000 + cancelGraceMillis - 1), &ids)
        #expect(early.state.phase == .cancelling, "pre-deadline tick is a no-op")
        #expect(early.effects.isEmpty && early.records.isEmpty, "no-op ticks append nothing")
        let forced = transition(cancelled.state, .tick(nowMillis: 2000 + cancelGraceMillis), &ids)
        guard case .interrupted = forced.state.phase else {
            Issue.record("deadline must force interrupted"); return
        }
    }

    @Test("CORE-02 idle cancel is a no-op; double cancel is idempotent")
    func CORE_02_idleAndDoubleCancel() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let noop = transition(idle, .cancelRequested(atMillis: 1000), &ids)
        #expect(noop.state == idle, "idle cancel changes nothing")
        #expect(noop.effects.isEmpty && noop.records.isEmpty)
        let (_, _, streaming, _) = try Self.streamingState(ids: &ids)
        let once = transition(streaming, .cancelRequested(atMillis: 2000), &ids)
        let twice = transition(once.state, .cancelRequested(atMillis: 2001), &ids)
        #expect(twice.state.generation == once.state.generation, "second cancel bumps nothing")
        #expect(twice.effects.isEmpty, "idempotent cancel emits nothing new")
    }

    @Test("CORE-02 interrupted session stays inspectable, then dismisses")
    func CORE_02_interruptedInspectable() throws {
        var ids = StateFixtures.ids()
        let (_, _, streaming, run) = try Self.streamingState(ids: &ids)
        let cancelled = transition(streaming, .cancelRequested(atMillis: 2000), &ids)
        let forced = transition(cancelled.state, .tick(nowMillis: 9000), &ids)
        guard case .interrupted = forced.state.phase else {
            Issue.record("expected interrupted"); return
        }
        #expect(forced.state.activeRun == nil, "no live run, but history stands")
        // Late completion for the dead run drops (generation mismatch).
        let late = transition(forced.state, .providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(text: "late", toolProposals: [], isFinal: true)),
            atMillis: 9001), &ids)
        #expect(late.state.droppedStaleCount == forced.state.droppedStaleCount + 1)
        let idle = transition(forced.state, .dismissRun(atMillis: 9002), &ids)
        #expect(idle.state.phase == .idle, "explicit ack returns to idle")
    }
}
