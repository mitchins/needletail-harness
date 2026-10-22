import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// CORE-03/04 integration — invalid tracking and budgets through the real
/// actor. Short loops prove the wiring (turn counting across re-requests);
/// the 80-turn boundary itself is pinned in the pure suite.
struct ActorBudgetTests {

    @Test("CORE-03 three identical invalid notes stop the run")
    func CORE_03_invalidStops() async throws {
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.noteInvalidInput(fingerprint: "fp-x", cause: "bad slash")
        await actor.noteInvalidInput(fingerprint: "fp-x", cause: "bad slash")
        var state = await actor.currentState()
        #expect(!state.phase.isTerminal)
        await actor.noteInvalidInput(fingerprint: "fp-x", cause: "bad slash")
        state = await actor.currentState()
        guard case .failed(let failure) = state.phase else {
            Issue.record("third identical invalid must stop, got \(state.phase)"); return
        }
        guard case .invalidStopped = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(state.queueHeld, "invalid stop holds the queue")
    }

    @Test("CORE-04 turns count across post-tool re-requests")
    func CORE_04_turnsCountAcrossReRequests() async throws {
        let transport = ScriptedTransport()
        let executor = ScriptedExecutor()
        let (actor, store) = try ActorFixtures.makeActor(
            mode: .trustedExec, permissive: true, transport: transport, executor: executor)
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}"),
                ], isFinal: false)),
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: true)),
        ]
        await actor.submitText(commandID: CommandID("c-1"), text: "tools", kind: .followUp, sealed: false)

        for _ in 0..<100_000 where transport.invocations.count < 2 {
            await Task.yield()
        }
        #expect(transport.invocations.count == 2, "two provider dispatches total, got \(transport.invocations.count)")

        try await ActorFixtures.awaitPhase(actor, { state in
            if case .completed = state.phase { return true }
            return false
        }, "completed after tool round")
        let state = await actor.currentState()
        #expect(state.turnsUsed == 2, "tool round consumes one additional turn, got \(state.turnsUsed)")
        #expect(executor.calls.count == 1, "grant dispatches exactly one execution")
        #expect(state.pendingApproval == nil, "trusted execution asks no approval")

        let (entries, _) = try store.records(since: 0, limit: 100)
        let toolResponses = entries.compactMap { entry -> String? in
            guard case .transcriptAppended(.toolResponse(let callID, let text)) = entry.record else { return nil }
            return "\(callID):\(text)"
        }
        #expect(toolResponses.contains("c1:scripted"), "tool result is paired by call ID, got \(toolResponses)")
    }

    @Test("CORE-04 wall-clock deadline stops via explicit ticks")
    func CORE_04_deadlineStops() async throws {
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "live run")
        var state = await actor.currentState()
        let deadline = try #require(state.runDeadlineMillis)
        await actor.tick(at: deadline - 1)
        state = await actor.currentState()
        #expect(state.phase == .requesting || state.phase == .admitting, "pre-deadline continues")
        await actor.tick(at: deadline)
        state = await actor.currentState()
        guard case .failed(let failure) = state.phase else {
            Issue.record("deadline must stop, got \(state.phase)"); return
        }
        guard case .budgetExhausted = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
    }
}
