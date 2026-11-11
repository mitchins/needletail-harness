import Testing
import Foundation
import NeedletailCore

/// B2 RED: Core reorder mechanics (R1). `rank` is display order;
/// `orderKey` stays the immutable admission/ack/watermark identity.
/// Fails until GREEN implements the reorder event + transition.
/// Darwin-debug: suite gated (B2 G14-class — the debug runner SIGBUSes
/// on these deep transition chains; Linux-debug + Darwin `-O` green).
#if canImport(Glibc)
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
        // Dispatched/withdrawn entry: withdraw a-1, then reorder it.
        let withdrawn = transition(state, .queueWithdraw(entryID: state.queue[0].entryID, atMillis: 1003), &ids)
        let dead = transition(withdrawn.state, .queueReorder(entryID: withdrawn.state.queue[0].entryID, beforeID: nil, atMillis: 1004), &ids)
        #expect(dead.state.queue == withdrawn.state.queue, "withdrawn entry: queue untouched")
        #expect(dead.effects == [.emitUI(.denied(cause: "only undispatched entries can be reordered"))],
            "withdrawn entry: loud refusal, got \(dead.effects)")
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

    @Test("B2 reorder midpoint exhaustion refuses loudly and never reverts replay")
    func B2_reorderRankExhaustionRefuses() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("a", id: "a-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("b", id: "b-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("c", id: "c-1", kind: .followUp), &ids).state
        // The durable stream the journal holds: admissions at
        // ADMISSION-TIME rank, then one queueUpdated per accepted move.
        let admitted = state.queue
        var records: [DurableRecord] = []
        var refused = false
        var moves = 0
        for _ in 0..<500 {
            let target = transition(state, .queueReorder(entryID: state.queue[2].entryID, beforeID: state.queue[1].entryID, atMillis: 2000), &ids)
            // .denied is a static FACTORY on SessionEventProjection (not
            // an enum case): equality/predicate matching only.
            if target.effects.contains(where: {
                if case .emitUI(let proj) = $0 {
                    return proj.kind == "denied" && proj.detail.contains("rank precision exhausted")
                }
                return false
            }) {
                refused = true
                break
            }
            #expect(target.effects.count == 1, "each accepted move emits exactly the reorder status")
            if let last = target.records.last, case .queueUpdated(let moved) = last {
                records.append(.queueUpdated(moved))
            }
            state = target.state
            moves += 1
        }
        #expect(refused, "midpoint must eventually collapse and refuse loudly (moves: \(moves))")
        #expect(moves > 10, "exhaustion must require real halving, not an immediate refusal")
        // The refusal left the queue untouched and recorded no update:
        // replay from admission-time ranks + the recorded updates must
        // reproduce the live order exactly (a reorder never silently
        // reverts — the contract this guard protects).
        let recon = try reconcileQueue([
            .queueAdmitted(admitted[0]),
            .queueAdmitted(admitted[1]),
            .queueAdmitted(admitted[2]),
        ] + records)
        #expect(recon.entries.map(\.commandID) == state.queue.map(\.commandID),
            "replay must match the live order at exhaustion, got \(recon.entries.map(\.commandID)) vs \(state.queue.map(\.commandID))")
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
        // Admissions carry admission-time rank (pre-move `state`), so
        // replay without the update record yields a,b,c — the test
        // fails unless the update record is honored.
        let admitted = Dictionary(uniqueKeysWithValues: state.queue.map { ($0.commandID, $0) })
        let byID = Dictionary(uniqueKeysWithValues: moved.state.queue.map { ($0.commandID, $0) })
        let records: [DurableRecord] = [
            .queueAdmitted(admitted[CommandID("a-1")]!),
            .queueAdmitted(admitted[CommandID("b-1")]!),
            .queueAdmitted(admitted[CommandID("c-1")]!),
            .queueUpdated(byID[CommandID("c-1")]!),
        ]
        let recon = try reconcileQueue(records)
        #expect(recon.entries.map(\.commandID) == [CommandID("c-1"), CommandID("a-1"), CommandID("b-1")],
            "reopen preserves the operator reorder, got \(recon.entries.map(\.commandID))")
    }
}
#endif
