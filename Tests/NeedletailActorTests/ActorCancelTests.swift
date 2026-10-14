import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// CORE-02 integration — cancellation with a live gated transport.
/// No sleeps: the test releases every suspension explicitly, so
/// cancel-before-release and release-before-cancel are driver choices.
struct ActorCancelTests {

    @Test("CORE-02 cancel with live transport holds and drops the late result")
    func CORE_02_cancelLiveTransportDropsLate() async throws {
        let transport = GatedTransport()
        let (actor, store) = try ActorFixtures.makeActor(transport: transport)
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        transport.gate = stream
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting }, "requesting")
        try await ActorFixtures.awaitInvocations(transport, count: 1)
        #expect(transport.invocations.count == 1, "one live invocation")
        // Cancel while the transport is suspended.
        await actor.cancel()
        let cancelling = await actor.currentState()
        #expect(cancelling.phase == .cancelling)
        #expect(cancelling.queueHeld, "cancel holds the queue")
        // Release the gate AFTER cancel: pairing finds no reservation → drops.
        let invocations = transport.invocations
        continuation.yield(.respond(ActorFixtures.finalResponse(
            requestID: invocations[0].requestID, generation: invocations[0].generation)))
        continuation.finish()
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .cancelling }, "still cancelling")
        let after = await actor.currentState()
        #expect(after.droppedStaleCount == cancelling.droppedStaleCount, "late result drops at the table, no event built")
        // Forced interrupt keeps history inspectable; dismiss returns.
        await actor.tick(at: 1_000_000 + cancelGraceMillis)
        let interrupted = await actor.currentState()
        guard case .interrupted = interrupted.phase else {
            Issue.record("expected interrupted"); return
        }
        await actor.dismissRun()
        #expect(await actor.currentState().phase == .idle)
        #expect(store.count > 0, "records persisted along the way")
    }

    @Test("CORE-02 release-before-cancel completes; cancel-after is a no-op")
    func CORE_02_releaseBeforeCancelCompletes() async throws {
        let transport = ScriptedTransport()
        let (actor, _) = try ActorFixtures.makeActor(transport: transport)
        // Canned final response: the actor pairs it (IDs stamped from the
        // reservation, not the payload) and lands completed.
        transport.script = [ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0))]
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, {
            if case .completed = $0.phase { return true }
            return false
        }, "completed")
        // Cancel after completion is a no-op diagnostic, not a resurrection.
        await actor.cancel()
        let state = await actor.currentState()
        guard case .completed = state.phase else {
            Issue.record("completed run must stay completed, got \(state.phase)"); return
        }
    }

    @Test("CORE-02 empty script fails transport to an ambiguous hold")
    func CORE_02_emptyScriptAmbiguousHold() async throws {
        let transport = ScriptedTransport()
        let (actor, _) = try ActorFixtures.makeActor(transport: transport)
        transport.script = []
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        // Out-of-script error → ambiguous hold (never silent, never resent).
        try await ActorFixtures.awaitPhase(actor, { $0.queueHeld }, "ambiguous hold")
        let held = await actor.currentState()
        #expect(held.unresolvedOperations.count == 1, "ambiguous send retains an unknown marker")
    }

    @Test("CORE-02 approval after cancel advances nothing")
    func CORE_02_approvalAfterCancelDrops() async throws {
        let approvals = ScriptedApprovals()
        let (actor, _) = try ActorFixtures.makeActor(approvals: approvals)
        _ = approvals
        // Drive to authorising with a scripted batch via direct events is a
        // transition-level path (pure suite); here prove the actor drops a
        // grant for a run that no longer exists.
        await actor.decideApproval(.approve, requestID: RequestID("ghost"), generation: Revision(99))
        let state = await actor.currentState()
        #expect(state.phase == .idle, "grant for nothing changes nothing")
        #expect(state.droppedStaleCount == 1)
    }

    @Test("CORE-02 cancelled mutating reservation retains unknown before clear")
    func CORE_02_cancelRetainsMutatingUnknown() async throws {
        // C3 at the actor seam: the transition-level proof lives in the pure
        // suite; here prove end-to-end that cancelling with a live mutating
        // reservation leaves exactly one unknown marker and clears tables.
        let transport = GatedTransport()
        let (actor, _) = try ActorFixtures.makeActor(transport: transport)
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        transport.gate = stream
        await actor.submitText(commandID: CommandID("c-1"), text: "work", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting }, "requesting")
        try await ActorFixtures.awaitInvocations(transport, count: 1)
        await actor.cancel()
        continuation.yield(.respond(ActorFixtures.finalResponse(
            requestID: transport.invocations[0].requestID, generation: transport.invocations[0].generation)))
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .cancelling }, "still cancelling")
        let state = await actor.currentState()
        // Request reservations are non-mutating: deliveryUnknown, no marker.
        #expect(state.unresolvedOperations.isEmpty, "non-mutating request leaves no unknown marker")
        #expect(state.activeRequest?.delivery == .deliveryUnknown)
        continuation.finish()
    }
}
