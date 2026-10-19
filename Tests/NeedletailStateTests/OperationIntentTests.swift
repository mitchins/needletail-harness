import Testing
import Foundation
import NeedletailCore

/// A3-1 stable operation identities + intent/result ordering (pure rows).
/// Every externally dispatchable tool operation gets a derived operation
/// ID (`effectID/callID`); dispatch commits one intent per operation and
/// completion records results under the SAME IDs. Forbidden: minted IDs
/// that break intent/result correlation, `mutating: false` on mutating
/// completions, silent multi-call collapse.
struct OperationIntentTests {

    private static func executingState(
        batch: ToolBatch, ids: inout DeterministicIDSource
    ) throws -> (SessionState, RunDescriptor, [DurableRecord]) {
        var state = try StateFixtures.idle(trustMode: .trustedExec, permissive: true)
        state = transition(state, StateFixtures.input("run", id: "a-1"), &ids).state
        state = transition(state, .requestDispatched(requestID: state.activeRun!.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: state.activeRun!.requestID, generation: state.activeRun!.revision, atMillis: 1002), &ids).state
        let run = try #require(state.activeRun)
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(text: "calls", toolProposals: batch.proposals.map {
                ToolProposal(callID: $0.callID, tool: $0.tool, argumentsDigest: "d")
            }, isFinal: false))
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids).state
        let completed = transition(state, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids)
        return (completed.state, run, completed.records)
    }

    private static func intents(in records: [DurableRecord]) -> [OperationRef] {
        records.compactMap {
            if case .operationIntent(let ref) = $0 { return ref }
            return nil
        }
    }

    private static func results(in records: [DurableRecord]) -> [(OperationRef, String)] {
        records.compactMap {
            if case .operationResult(let ref, let outcome) = $0 { return (ref, outcome) }
            return nil
        }
    }

    @Test("A3-1 dispatch commits one intent per operation with derived stable IDs")
    func dispatchCommitsPerOperationIntents() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d"),
        ])
        let (executing, _, records) = try Self.executingState(batch: batch, ids: &ids)
        #expect(executing.phase == .executing, "trustedExec batch dispatches, got \(executing.phase)")
        let reservation = try #require(executing.liveReservations.first)
        #expect(reservation.mutating, "edit/exec batch is mutating")
        let found = Self.intents(in: records)
        #expect(found.count == 2, "one intent per operation, got \(found.count)")
        let expected = [
            OperationID("\(reservation.effectID.raw)/c1"),
            OperationID("\(reservation.effectID.raw)/c2"),
        ]
        #expect(found.map(\.operationID) == expected, "derived IDs, stable across replay")
        #expect(found.allSatisfy { $0.state == .intent && $0.mutating }, "intent state + mutating flag travel")
        #expect(Set(found.map(\.operationID)).count == 2, "multi-call identities stay distinct")
    }

    @Test("A3-1 completion records results under the same IDs with the true mutating flag")
    func completionCorrelatesWithIntents() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d"),
        ])
        let (executing, run, dispatchRecords) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        let done = transition(executing, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: true,
            outcome: .success("ok"), atMillis: 1005), &ids)
        #expect(done.state.phase == .requesting, "completion continues the run")
        let intentIDs = Set(Self.intents(in: dispatchRecords).map(\.operationID))
        let completed = Self.results(in: done.records)
        #expect(Set(completed.map { $0.0.operationID }) == intentIDs, "results reuse the intent IDs")
        #expect(completed.allSatisfy { $0.0.state == .done }, "completion state travels")
        #expect(completed.allSatisfy { $0.0.mutating }, "mutating batch completion is mutating, not false")
        #expect(completed.allSatisfy { $0.1 == "ok" }, "receipt text carried")
    }

    @Test("A3-1 read-only batch intents and results stay non-mutating")
    func readOnlyBatchStaysNonMutating() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d")])
        let (executing, run, dispatchRecords) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        #expect(Self.intents(in: dispatchRecords).allSatisfy { !$0.mutating })
        let done = transition(executing, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("read it"), atMillis: 1005), &ids)
        let completed = Self.results(in: done.records)
        #expect(completed.count == 1)
        #expect(completed[0].0.mutating == false, "read completion is not mutating")
        #expect(completed[0].0.operationID == OperationID("\(effectID.raw)/c1"))
    }

    @Test("A3-1 failure receipt correlates with the intent ID")
    func failureReceiptCorrelates() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d")])
        let (executing, run, dispatchRecords) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        let intentID = try #require(Self.intents(in: dispatchRecords).first).operationID
        let failed = transition(executing, .effectFailed(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: true,
            error: "disk gone", atMillis: 1005), &ids)
        let completed = Self.results(in: failed.records)
        #expect(completed.count == 1)
        #expect(completed[0].0.operationID == intentID, "failure result reuses the intent ID")
        #expect(completed[0].0.mutating, "mutating batch failure stays mutating")
        #expect(completed[0].1 == "tool-failure: disk gone", "failure receipt text carried, got \(completed[0].1)")
    }

    @Test("A3-1 revision-mismatched completion retains derived unknown markers")
    func mismatchedCompletionRetainsDerivedUnknowns() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d"),
        ])
        let (executing, run, dispatchRecords) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        let intentIDs = Set(Self.intents(in: dispatchRecords).map(\.operationID))
        // Wrong revision: the reservation is live and mutating, so the
        // completion is unknowable — retained, never continued.
        let stale = transition(executing, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: Revision(run.revision.value + 1), mutating: true,
            outcome: .success("late"), atMillis: 1005), &ids)
        #expect(stale.state.liveReservations.isEmpty, "stale reservation dropped")
        let markerIDs = Set(stale.state.unresolvedOperations.map(\.operationID))
        #expect(markerIDs == intentIDs, "unknown markers reuse the intent IDs, got \(markerIDs)")
        #expect(stale.state.unresolvedOperations.allSatisfy { $0.state == .unknown && $0.mutating })
        let recorded = Self.results(in: stale.records).filter { $0.1 == "unknown" }
        #expect(Set(recorded.map { $0.0.operationID }) == intentIDs, "unknown outcomes pair with the intents")
        #expect(stale.state.phase != .requesting, "no continuation on mismatched completion")
    }

    @Test("A3-1 double completion drops bare with no new result")
    func doubleCompletionDropsBare() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d")])
        let (executing, run, _) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        let event = SessionEvent.effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: true,
            outcome: .success("ok"), atMillis: 1005)
        let first = transition(executing, event, &ids)
        #expect(first.state.consumedEffects.contains(effectID))
        let second = transition(first.state, event, &ids)
        #expect(second.records.isEmpty, "consumed completion records nothing")
        #expect(Self.results(in: second.records).isEmpty, "no second success result")
        #expect(second.state.droppedStaleCount == first.state.droppedStaleCount + 1)
    }

    @Test("A3-1 consumed check drops even when the reservation is still live")
    func consumedCheckWinsOverLiveReservation() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d")])
        let (executing, run, _) = try Self.executingState(batch: batch, ids: &ids)
        let effectID = try #require(executing.liveReservations.first).effectID
        // Hypothetical torn state: consumed recorded but the reservation
        // never removed. The consumed check must still win — a second
        // success result must never exist.
        let torn = executing.replacing(consumedEffects: [effectID])
        let again = transition(torn, .effectCompleted(
            effectID: effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: true,
            outcome: .success("ok"), atMillis: 1005), &ids)
        #expect(again.records.isEmpty, "consumed completion records nothing even with a live reservation")
        #expect(Self.results(in: again.records).isEmpty, "no second success result")
    }
}
