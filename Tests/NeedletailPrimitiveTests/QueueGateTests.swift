import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport
import NeedletailRuntime

/// M2-D D0 cross-session gate: unknown queue deliveries hold new mutating
/// runs; never-sent queued entries do not.
struct QueueGateTests {

    @Test("D0 cross-session gate holds unknown deliveries, ignores never-sent queues")
    func crossSessionGateHoldsUnknownDeliveries() throws {
        let store = InMemorySessionStore()
        let idA = SessionID("s-A")
        let idB = SessionID("s-B")
        try store.claimWriterOwnership(session: idA, writer: "w")
        try store.claimWriterOwnership(session: idB, writer: "w")
        let idAIdent = WriterIdentity(session: idA, writer: "w")
        let idBIdent = WriterIdentity(session: idB, writer: "w")
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 1, sealed: false)
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 1, sealed: false)
        try store.appendBatch([.queueAdmitted(entry), .queueUpdated(history), .queueDispatched(link)], as: idAIdent)
        let other = QueueEntry(entryID: "q-9", commandID: CommandID("c-9"), kind: .followUp, state: .queued, revision: 1, text: "b", targetEpochID: EpochID("e-1"), orderKey: 2, sealed: false)
        try store.appendBatch([.queueAdmitted(other)], as: idBIdent)
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 1, "only the unknown-delivery session holds, got \(holds.count)")
        #expect(holds.first?.session == idA)
        #expect(holds.first?.unknownQueueDeliveries.count == 1)
        #expect(holds.first?.unknownQueueDeliveries.first?.entryID == "q-1")
    }

    @Test("D0 cross-session gate stays clean when every link completed")
    func crossSessionGateCleanOnCompletion() throws {
        let store = InMemorySessionStore()
        let idA = SessionID("s-A")
        try store.claimWriterOwnership(session: idA, writer: "w")
        let ident = WriterIdentity(session: idA, writer: "w")
        let entry = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .queued, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 1, sealed: false)
        let link = QueueDispatchLink(entryID: "q-1", commandID: CommandID("c-1"), runID: RunID("r-9"), requestID: RequestID("req-9"), effectID: EffectID("eff-9"), epochID: EpochID("e-1"))
        let history = QueueEntry(entryID: "q-1", commandID: CommandID("c-1"), kind: .followUp, state: .admittedToHistory, revision: 1, text: "a", targetEpochID: EpochID("e-1"), orderKey: 1, sealed: false)
        var records: [DurableRecord] = [
            .queueAdmitted(entry), .queueUpdated(history), .queueDispatched(link),
            .eventAppended(seq: SequenceNumber(4), kind: "completed", digest: eventDigest("completed", "r-9")),
        ]
        records.append(.operationResult(
            OperationRef(operationID: OperationID("eff-9/c-9"), callID: "c-9", state: .done, mutating: false),
            outcome: "done"))
        try store.appendBatch(records, as: ident)
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.isEmpty, "completed dispatch leaves no hold, got \(holds.count)")
    }
}
