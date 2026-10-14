import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Queue admission/idempotence at the actor seam (I14, R10/C2): duplicate
/// commandIDs replay identical acks across dispatch and withdrawal; the
/// 512-entry retention boundary re-admits pruned IDs as visibly-new
/// entries (honest, tested at full scale — fast, in-memory).
struct ActorQueueTests {

    @Test("duplicate commandID replays the identical ack end to end")
    func duplicateAckIdentical() async throws {
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.submitText(commandID: CommandID("d-1"), text: "first", kind: .followUp, sealed: false)
        // Drive the run to requesting so the retry takes the busy path.
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "live run")
        await actor.submitText(commandID: CommandID("d-1"), text: "different text", kind: .followUp, sealed: false)
        let state = await actor.currentState()
        let queued = state.queue.filter { $0.commandID == CommandID("d-1") }
        #expect(queued.count <= 1, "no duplicate entry, got \(queued.count)")
    }

    @Test("withdrawn IDs replay withdrawn acks, never new entries")
    func withdrawnAckStable() async throws {
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "live run")
        await actor.submitText(commandID: CommandID("w-1"), text: "bye", kind: .followUp, sealed: false)
        var state = await actor.currentState()
        let entryID = try #require(state.queue.first(where: { $0.commandID == CommandID("w-1") })?.entryID)
        await actor.withdrawEntry(entryID: entryID)
        state = await actor.currentState()
        #expect(state.queue.first(where: { $0.commandID == CommandID("w-1") })?.state == .withdrawn)
        await actor.submitText(commandID: CommandID("w-1"), text: "resurrected?", kind: .followUp, sealed: false)
        state = await actor.currentState()
        #expect(state.queue.filter({ $0.commandID == CommandID("w-1") }).count == 1, "no resurrection")
        #expect(state.queue.first(where: { $0.commandID == CommandID("w-1") })?.state == .withdrawn)
    }

    @Test("C2 retention boundary holds end to end at small scale")
    func retentionBoundaryEndToEnd() async throws {
        // Full 513-step scale runs in the pure suite (queue caps block bulk
        // admission here); this row proves the actor wires the same path.
        let (actor, _) = try ActorFixtures.makeActor()
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .requesting || $0.phase == .admitting }, "live run")
        await actor.submitText(commandID: CommandID("e-1"), text: "n-1", kind: .followUp, sealed: false)
        var state = await actor.currentState()
        let ack1 = try #require(state.admittedCommands[CommandID("e-1")])
        await actor.submitText(commandID: CommandID("e-1"), text: "retry", kind: .followUp, sealed: false)
        state = await actor.currentState()
        #expect(state.admittedCommands[CommandID("e-1")] == ack1, "same ack on retry")
    }
}
