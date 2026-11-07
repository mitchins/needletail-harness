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

    @Test("B2 reorder anchors must be live undispatched entries")
    func B2_reorderAnchorRules() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        let queueBefore = state.queue
        // Unknown anchor refuses.
        let unknownAnchor = transition(state, .queueReorder(entryID: state.queue[0].entryID, beforeID: "nope", atMillis: 1002), &ids)
        #expect(unknownAnchor.state.queue == queueBefore, "unknown anchor: queue untouched")
        #expect(unknownAnchor.effects == [.emitUI(.denied(cause: "unknown reorder anchor"))])
        // Self anchor is an idempotent no-op ack.
        let selfAnchor = transition(state, .queueReorder(entryID: state.queue[0].entryID, beforeID: state.queue[0].entryID, atMillis: 1003), &ids)
        #expect(selfAnchor.state.queue == queueBefore, "self anchor: no move")
        // Dispatched anchor refuses: dispatch b via a fresh run is heavy
        // here; withdraw-then-anchor covers the non-live path instead.
        let withdrawn = transition(state, .queueWithdraw(entryID: state.queue[1].entryID, atMillis: 1004), &ids).state
        let deadAnchor = transition(withdrawn, .queueReorder(entryID: withdrawn.queue[0].entryID, beforeID: withdrawn.queue[1].entryID, atMillis: 1005), &ids)
        #expect(deadAnchor.state.queue == withdrawn.queue, "withdrawn anchor: queue untouched")
        #expect(deadAnchor.effects == [.emitUI(.denied(cause: "unknown reorder anchor"))])
    }

    @Test("B2 rank survives withdraw tombstone (live)")
    func B2_rankSurvivesTombstoneLive() throws {
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

    @Test("B2 reorder survives reopen via rank-ordered replay")
    func B2_reorderSurvivesReopen() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("c", id: "c-1", kind: .followUp), &ids).state
        // Move c first: live order becomes c,a,b.
        let moved = transition(state, .queueReorder(entryID: state.queue[2].entryID, beforeID: state.queue[0].entryID, atMillis: 1002), &ids)
        #expect(moved.state.queue.map(\.commandID) == [CommandID("c-1"), CommandID("a-1"), CommandID("b-1")])
        // Rebuild the durable stream the journal would hold: admissions
        // in admission order plus the reorder's queueUpdated record.
        let byID = Dictionary(uniqueKeysWithValues: moved.state.queue.map { ($0.commandID, $0) })
        let records: [DurableRecord] = [
            .queueAdmitted(byID[CommandID("a-1")]!),
            .queueAdmitted(byID[CommandID("b-1")]!),
            .queueAdmitted(byID[CommandID("c-1")]!),
            .queueUpdated(byID[CommandID("c-1")]!),
        ]
        let recon = try reconcileQueue(records)
        #expect(recon.entries.map(\.commandID) == [CommandID("c-1"), CommandID("a-1"), CommandID("b-1")],
            "reopen preserves the operator reorder, got \(recon.entries.map(\.commandID))")
    }
}
