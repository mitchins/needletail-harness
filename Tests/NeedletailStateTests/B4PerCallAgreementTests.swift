import Testing
import NeedletailCore

/// B4 per-call agreement + omission legs (REV25 §4/B4): the executor's
/// per-call `mutating` attestation must agree with the dispatch-time
/// intent, omitted `started` on cancel/timeout is treated as started, and
/// provably-undispatched deterministic outcomes (nil `started`) are done.
/// Uses the real reducer only — no I/O.
struct B4PerCallAgreementTests {

    private static func executingState(batch: ToolBatch, ids: inout DeterministicIDSource) throws -> (SessionState, RunDescriptor) {
        var state = try StateFixtures.idle(permissive: true)
        let run = RunDescriptor(runID: RunID("run-1"), requestID: RequestID("req-1"), revision: Revision(1), startedAtMillis: 1000, sealed: false)
        state = state.replacing(phase: .executing, activeRun: run, liveReservations: [
            EffectReservation(effectID: EffectID("eff-1"), runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: batch.proposals.contains { $0.tool != "read" && $0.tool != "search" && $0.tool != "consult" }, batch: batch, kind: .executor)
        ], generation: 1)
        return (state, run)
    }

    private static func complete(_ state: SessionState, _ run: RunDescriptor, _ calls: [ToolCallOutcome], ids: inout DeterministicIDSource) -> Transition {
        let result = ExecutorResult(receipt: ExecutorReceipt(callID: "batch", status: "ok", summary: "batch"), calls: calls)
        return transition(state, .effectCompleted(effectID: EffectID("eff-1"), runID: run.runID, generation: run.revision, expectedRevision: run.revision, mutating: true, outcome: .perCall(result), atMillis: 1002), &ids)
    }

    // MARK: - Mutating agreement (RED/GREEN: before B4 the field did not exist, so both were done)

    @Test("B4: edit reporting success as non-mutating is failed closed (unknown+hold)")
    func editClaimsNonMutating() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a"}"#)])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let out = Self.complete(state, run, [ToolCallOutcome(callID: "c1", status: "success", summary: "ok", data: "ok", started: true, mutating: false)], ids: &ids)
        #expect(out.records.contains(where: { if case .operationResult(let r, let o) = $0 { return r.callID == "c1" && r.state == .unknown && o.contains("mutating mismatch") } else { return false } }), "mismatched attestation must be unknown+hold")
        #expect(out.state.queueHeld, "mismatch must hold the queue")
        #expect(out.state.unresolvedOperations.contains(where: { $0.callID == "c1" && $0.mutating }), "conservative mutating claim")
    }

    @Test("B4: read reporting success as mutating is failed closed (unknown+hold)")
    func readClaimsMutating() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: #"{"path":"a"}"#)])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let out = Self.complete(state, run, [ToolCallOutcome(callID: "c1", status: "success", summary: "ok", data: "ok", started: true, mutating: true)], ids: &ids)
        #expect(out.records.contains(where: { if case .operationResult(let r, let o) = $0 { return r.callID == "c1" && r.state == .unknown && o.contains("mutating mismatch") } else { return false } }), "invented mutation claim must be unknown+hold")
        #expect(out.state.queueHeld, "mismatch must hold the queue")
    }

    @Test("B4: matching attestations stand (edit mutating, read not)")
    func matchingAttestationsStand() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a"}"#),
            ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: #"{"path":"b"}"#),
        ])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let out = Self.complete(state, run, [
            ToolCallOutcome(callID: "c1", status: "success", summary: "ok", data: "ok", started: true, mutating: true),
            ToolCallOutcome(callID: "c2", status: "success", summary: "ok", data: "ok", started: true, mutating: false),
        ], ids: &ids)
        #expect(out.state.phase == .requesting, "agreement continues the run")
        #expect(out.state.unresolvedOperations.isEmpty, "no hold on agreement")
        let results = out.records.compactMap { if case .operationResult(let r, _) = $0 { return r } else { return nil } }
        #expect(results.first(where: { $0.callID == "c1" })?.mutating == true)
        #expect(results.first(where: { $0.callID == "c2" })?.mutating == false)
    }

    // MARK: - Omission + nil-started pins

    @Test("B4: cancelled with omitted started is treated as started (mutating unknown+hold)")
    func cancelledOmittedStartedHolds() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a"}"#)])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let out = Self.complete(state, run, [ToolCallOutcome(callID: "c1", status: "cancelled", summary: "late", data: "late", started: nil)], ids: &ids)
        #expect(out.records.contains(where: { if case .operationResult(let r, _) = $0 { return r.callID == "c1" && r.state == .unknown } else { return false } }), "omitted started on cancel must be unknown for mutating")
        #expect(out.state.queueHeld, "omission must hold")
    }

    @Test("B4: deterministic outcome with nil started is done (executor undispatched verdict)")
    func deterministicNilStartedIsDone() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: #"{"path":"a"}"#)])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        let out = Self.complete(state, run, [ToolCallOutcome(callID: "c1", status: "failed", summary: "lock contention", data: "", error: "lock", started: nil, mutating: true)], ids: &ids)
        #expect(out.state.phase == .requesting, "provably-undispatched deterministic failure continues")
        #expect(out.state.unresolvedOperations.isEmpty, "no hold for undispatched verdict")
        #expect(out.records.contains(where: { if case .operationResult(let r, let o) = $0 { return r.callID == "c1" && r.state == .done && o.contains("tool-failure") } else { return false } }))
    }

    // MARK: - No-entry (backend omits a dispatched call)

    @Test("B4: omitted call is unknown+hold for mutating, transcript-only for non-mutating")
    func omittedCallSplit() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a"}"#),
            ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: #"{"path":"b"}"#),
        ])
        let (state, run) = try Self.executingState(batch: batch, ids: &ids)
        // Backend reports only c1: c2 has no entry.
        let out = Self.complete(state, run, [ToolCallOutcome(callID: "c1", status: "success", summary: "ok", data: "ok", started: true)], ids: &ids)
        let results = out.records.compactMap { if case .operationResult(let r, let o) = $0 { return (r, o) } else { return nil } }
        #expect(results.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "reported call completes")
        #expect(!results.contains(where: { $0.0.callID == "c2" }), "omitted non-mutating call takes no durable result")
        #expect(out.records.contains(where: { if case .transcriptAppended(.toolResponse(let id, let t)) = $0 { return id == "c2" && t.contains("no-entry") } else { return false } }), "omitted call is transcript-visible")
        // And the mutating omission variant holds.
        var ids2 = StateFixtures.ids()
        let batch2 = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a"}"#)])
        let (state2, run2) = try Self.executingState(batch: batch2, ids: &ids2)
        let out2 = Self.complete(state2, run2, [], ids: &ids2)
        #expect(out2.records.contains(where: { if case .operationResult(let r, _) = $0 { return r.callID == "c1" && r.state == .unknown } else { return false } }), "omitted mutating call must be unknown+hold")
        #expect(out2.state.queueHeld, "omitted mutating call holds")
    }
}
