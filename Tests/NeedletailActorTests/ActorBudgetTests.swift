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
        let (actor, _) = try ActorFixtures.makeActor(mode: .trustedExec, permissive: true, transport: transport)
        // Turn 1: interim response (no tools) → requesting, turnsUsed still 1.
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "part", toolProposals: [], isFinal: false))]
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting }, "requesting after interim")
        var state = await actor.currentState()
        #expect(state.turnsUsed == 1, "one dispatch consumed one turn")
        // Turn 2 via tool loop: proposals → trustedExec auto → executing.
        // A fresh run is needed (interim responses don't re-dispatch).
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.cancel()
        await actor.tick(at: 1_000_000 + cancelGraceMillis)
        await actor.dismissRun()
        await actor.submitText(commandID: CommandID("c-2"), text: "tools", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .executing }, "executing via trustedExec")
        state = await actor.currentState()
        #expect(state.liveReservations.count == 1, "tool batch reserved")
        // Scripted executor completion continues the loop with a re-request.
        let effectID = try #require(state.liveReservations.first?.effectID)
        await actor.completeEffect(effectID, outcome: .success("read ok"))
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting }, "requesting after tool round")
        state = await actor.currentState()
        // Initial dispatch consumed turn 1; the post-tool re-request
        // consumes turn 2 — every requestProvider dispatch counts.
        #expect(state.turnsUsed == 2, "turns count dispatches, got \(state.turnsUsed)")
        #expect(transport.invocations.count == 3, "three provider dispatches total, got \(transport.invocations.count)")
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
