import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// STATE-01 actor parity — the reservation table drops foreign completions
/// BEFORE any event is built (R9); cancel-then-new-run is immune to late
/// old results; unknown effectIDs never construct events.
struct ActorStaleTests {

    @Test("STATE-01 cancel-then-new-run is immune to late old results")
    func STATE_01_cancelThenNewRunImmune() async throws {
        let transport = GatedTransport()
        let (actor, _) = try ActorFixtures.makeActor(transport: transport)
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        transport.gate = stream
        await actor.submitText(commandID: CommandID("old"), text: "old work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting }, "old run live")
        let oldRun = try #require((await actor.currentState()).activeRun)
        try await ActorFixtures.awaitInvocations(transport, count: 1)
        await actor.cancel()
        let atCancel = await actor.currentState()
        // Release the OLD transport result after cancel: the cleared table
        // drops it BEFORE any event exists — not even the stale counter
        // moves (table-drop precedes transition-drop).
        continuation.yield(.respond(ActorFixtures.finalResponse(
            requestID: transport.invocations[0].requestID, generation: transport.invocations[0].generation)))
        continuation.finish()
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .cancelling }, "still cancelling")
        let afterLate = await actor.currentState()
        #expect(afterLate.droppedStaleCount == atCancel.droppedStaleCount, "pre-event table drop")
        await actor.tick(at: 1_000_000 + cancelGraceMillis)
        await actor.dismissRun()
        // New run on a fresh generation (gate exhausted → ambiguous hold,
        // which still proves the new run is distinct and live).
        transport.gate = nil
        await actor.submitText(commandID: CommandID("new"), text: "new work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "new run live")
        let state = await actor.currentState()
        let newRun = try #require(state.activeRun)
        #expect(newRun.runID != oldRun.runID, "distinct runs")
        #expect(newRun.revision.value > oldRun.revision.value, "generation advanced past the cancelled run")
    }

    @Test("STATE-01 unknown effectIDs never construct events")
    func STATE_01_unknownEffectIDsDrop() async throws {
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "live run")
        let before = await actor.currentState()
        await actor.completeEffect(EffectID("ghost"), outcome: .success("spoofed"))
        await actor.failEffect(EffectID("ghost"), error: "spoofed")
        let after = await actor.currentState()
        #expect(after.droppedStaleCount == before.droppedStaleCount, "ghost completions drop before events, not even counted")
        #expect(after.phase == before.phase && after.turnsUsed == before.turnsUsed)
    }
}
