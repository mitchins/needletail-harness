import Testing
import Foundation
import NeedletailCore

/// B2 RED: Core reorder mechanics (R1). `rank` is display order;
/// `orderKey` stays the immutable admission/ack/watermark identity.
/// Fails until GREEN implements the reorder event + transition.
struct QueueReorderTests {

    private static func busyState(ids: inout DeterministicIDSource) throws -> SessionState {
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        let dispatched = transition(
            admitting,
            .requestDispatched(requestID: admitting.activeRun!.requestID, atMillis: 1001), &ids)
        return dispatched.state
    }

    @Test("B2 admission assigns rank equal to orderKey")
    func B2_admissionRankEqualsOrderKey() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        #expect(state.queue.count == 2)
        #expect(state.queue[0].rank == Double(state.queue[0].orderKey))
        #expect(state.queue[1].rank == Double(state.queue[1].orderKey))
        #expect(state.queue[0].rank < state.queue[1].rank, "admission order is rank order")
    }

    @Test("B2 reorder moves the entry and preserves ack identity")
    func B2_reorderPreservesAckIdentity() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        let ackBefore = try #require(state.admittedCommands[CommandID("a-1")])
        let orderBefore = state.queue[0].orderKey
        let moved = transition(state, .queueReorder(entryID: state.queue[1].entryID, beforeID: state.queue[0].entryID, atMillis: 1002), &ids)
        #expect(moved.state.queue[0].commandID == CommandID("b-1"), "b moved first")
        #expect(moved.state.queue[0].orderKey != moved.state.queue[1].orderKey, "orderKeys distinct")
        #expect(moved.state.queue.first(where: { $0.commandID == CommandID("a-1") })?.orderKey == orderBefore,
            "orderKey immutable across reorder")
        #expect(moved.state.admittedCommands[CommandID("a-1")] == ackBefore, "ack identity untouched")
    }

    @Test("B2 reorder of unknown or dispatched entries refuses loudly")
    func B2_reorderRefusals() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        let queueBefore = state.queue
        let unknown = transition(state, .queueReorder(entryID: "nope", beforeID: nil, atMillis: 1002), &ids)
        #expect(unknown.state.queue == queueBefore, "unknown entry: queue untouched")
        #expect(unknown.effects == [.emitUI(.denied(cause: "unknown queue entry"))],
            "unknown entry: loud refusal, got \(unknown.effects)")
    }

    @Test("B2 rank survives withdraw tombstone and replay")
    func B2_rankSurvivesTombstone() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        state = transition(state, .queueReorder(entryID: state.queue[1].entryID, beforeID: state.queue[0].entryID, atMillis: 1002), &ids).state
        let movedRank = state.queue[0].rank
        let withdrawn = transition(state, .queueWithdraw(entryID: state.queue[0].entryID, atMillis: 1003), &ids)
        #expect(withdrawn.state.queue[0].rank == movedRank, "tombstone keeps rank")
        #expect(withdrawn.state.queue[0].state == .withdrawn)
    }
}
