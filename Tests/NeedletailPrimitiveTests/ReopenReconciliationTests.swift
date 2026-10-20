import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime

/// A3-2 reopen reconciliation over the production GRDB store. Every test
/// writes a ledger through one handle, CLOSES it, and reconciles through
/// a FRESH handle on the same file — genuine reopen, never two live
/// writers on one session. Malformed ledgers are hand-seeded (the actor
/// can never produce them); well-formed ledgers use the exact shapes the
/// reducer emits (derived `effectID/callID` IDs, callID-less admission
/// markers, callID-less denial receipts).
struct ReopenReconciliationTests {

    private static func freshPath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("store.sqlite").path)
    }

    private static func seed(
        _ path: String, session: SessionID, _ records: [DurableRecord], writer: String = "w-1"
    ) throws {
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: writer)
        try store.appendBatch(records, as: WriterIdentity(session: session, writer: writer))
        try store.close()
    }

    private static func reopenAndReconcile(_ path: String, session: SessionID) throws -> OperationReconciliation {
        let reopened = try GRDBSessionStore(path: path)
        let report = try reopened.reconcile(session: session)
        try reopened.close()
        return report
    }

    private static func toolIntent(_ id: String, call: String, mutating: Bool) -> DurableRecord {
        .operationIntent(OperationRef(
            operationID: OperationID(id), callID: call, state: .intent, mutating: mutating))
    }

    private static func toolResult(_ id: String, call: String, mutating: Bool, state: OperationState, outcome: String) -> DurableRecord {
        .operationResult(OperationRef(
            operationID: OperationID(id), callID: call, state: state, mutating: mutating), outcome: outcome)
    }

    @Test("A3-2 interleaved sessions reconcile strictly scoped")
    func interleavedSessionsStayScoped() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionA = SessionID("s-a")
        let sessionB = SessionID("s-b")
        // Session A: a completed tool operation. Session B: the SAME ID
        // strings, but an intent-only crash plus admission junk.
        try Self.seed(path, session: sessionA, [
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .done, outcome: "ok"),
        ])
        try Self.seed(path, session: sessionB, [
            .operationIntent(OperationRef(operationID: OperationID("a-op-1"), state: .intent, mutating: false)),
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
        ])
        let reportA = try Self.reopenAndReconcile(path, session: sessionA)
        #expect(reportA.completed == [OperationID("e1/c1")])
        #expect(reportA.heldOperations.isEmpty, "completed work holds nothing")
        let reportB = try Self.reopenAndReconcile(path, session: sessionB)
        #expect(reportB.completed.isEmpty)
        #expect(reportB.unmatchedMutating.map(\.operationID) == [OperationID("e1/c1")])
        #expect(reportB.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
        #expect(reportB.admissionIntents == 1, "admission marker counted, not orphaned")
    }

    @Test("A3-2 intent-only crash on mutating work holds as unknown")
    func intentOnlyCrashHoldsMutatingWork() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-crash")
        try Self.seed(path, session: session, [
            Self.toolIntent("e7/c1", call: "c1", mutating: true),
            Self.toolIntent("e7/c2", call: "c2", mutating: true),
            .transcriptAppended(.user("work submitted")),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed.isEmpty, "no result committed, nothing completed")
        #expect(report.unmatchedMutating.map(\.operationID) == [OperationID("e7/c1"), OperationID("e7/c2")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("e7/c1"), OperationID("e7/c2")])
        #expect(report.heldOperations.allSatisfy { $0.state == .unknown && $0.mutating })
    }

    @Test("A3-2 completed outcomes reconcile clean with no hold")
    func completedOutcomesReconcileClean() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-done")
        try Self.seed(path, session: session, [
            Self.toolIntent("e3/c1", call: "c1", mutating: true),
            Self.toolResult("e3/c1", call: "c1", mutating: true, state: .done, outcome: "edited"),
            Self.toolIntent("e3/c2", call: "c2", mutating: false),
            Self.toolResult("e3/c2", call: "c2", mutating: false, state: .done, outcome: "read it"),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed == [OperationID("e3/c1"), OperationID("e3/c2")])
        #expect(report.heldOperations.isEmpty && report.unmatchedMutating.isEmpty)
        #expect(report.explicitUnknown.isEmpty && report.orphanResults.isEmpty)
    }

    @Test("A3-2 explicit unknown outcomes survive as held evidence")
    func explicitUnknownsSurviveAsHeldEvidence() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-unknown")
        try Self.seed(path, session: session, [
            Self.toolIntent("e5/c1", call: "c1", mutating: true),
            Self.toolResult("e5/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown"),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed.isEmpty)
        #expect(report.explicitUnknown.map(\.operationID) == [OperationID("e5/c1")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("e5/c1")])
        #expect(report.heldOperations.first?.state == .unknown)
    }

    @Test("A3-2 admission markers and denial receipts never hold")
    func admissionShapesNeverHold() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-admit")
        // Exact reducer-emitted shapes: callID-less admission intent and
        // callID-less non-mutating "denied" result.
        try Self.seed(path, session: session, [
            .operationIntent(OperationRef(operationID: OperationID("a-op-9"), state: .intent, mutating: false)),
            .operationResult(OperationRef(operationID: OperationID("a-op-10"), state: .done, mutating: false), outcome: "denied"),
            .transcriptAppended(.user("hello")),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.admissionIntents == 1)
        #expect(report.nonToolResults == 1)
        #expect(report.completed.isEmpty && report.orphanResults.isEmpty)
        #expect(report.heldOperations.isEmpty, "non-tool shapes never hold mutating work")
    }

    @Test("A3-2 batch receipt completes only the calls it records")
    func batchReceiptNeverCompletesSiblingCalls() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-partial")
        // Two-call batch, one shared receipt text, but a result ONLY for
        // c1 — plus transcript responses for BOTH calls carrying the same
        // receipt. c2 must stay unmatched (held), never inferred complete.
        try Self.seed(path, session: session, [
            Self.toolIntent("e9/c1", call: "c1", mutating: true),
            Self.toolIntent("e9/c2", call: "c2", mutating: true),
            Self.toolResult("e9/c1", call: "c1", mutating: true, state: .done, outcome: "batch ok"),
            .transcriptAppended(.toolResponse(callID: "c1", text: "batch ok")),
            .transcriptAppended(.toolResponse(callID: "c2", text: "batch ok")),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed == [OperationID("e9/c1")], "only the recorded call completes")
        #expect(report.unmatchedMutating.map(\.operationID) == [OperationID("e9/c2")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("e9/c2")],
                "transcript receipt text is not a result record")
    }

    @Test("A3-2 non-mutating unmatched work is reported, never held")
    func nonMutatingUnmatchedNeverHolds() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-read")
        try Self.seed(path, session: session, [
            Self.toolIntent("e2/c1", call: "c1", mutating: false),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.unmatchedNonMutating == [OperationID("e2/c1")])
        #expect(report.heldOperations.isEmpty, "side-effect-free intent is re-runnable")
        #expect(report.unmatchedMutating.isEmpty)
    }

    @Test("A3-2 orphan results are reported; mutating orphans hold as unknown")
    func orphanResultsReportedWithConservativeHold() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-orphan")
        // Legacy shape: pre-A3-1 completions carry callIDs but no intent
        // was ever committed for them.
        try Self.seed(path, session: session, [
            Self.toolResult("ghost/write", call: "w", mutating: true, state: .done, outcome: "edited"),
            Self.toolResult("ghost/read", call: "r", mutating: false, state: .done, outcome: "read it"),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed.isEmpty, "no intent, no completion")
        #expect(report.orphanResults.map(\.operationID) == [OperationID("ghost/write"), OperationID("ghost/read")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("ghost/write")],
                "only the mutating orphan holds")
        #expect(report.heldOperations.first?.state == .unknown, "orphan hold is unknown, never asserted done")
    }

    @Test("A3-2 ambiguous delivery unknowns hold after reopen")
    func ambiguousDeliveryUnknownsHold() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-ambiguous")
        // Exact ambiguous-transport shape: callID-less, non-mutating,
        // unknown-state. It must surface (never swallowed into a count)
        // and hold — the live system blocks on every such marker.
        try Self.seed(path, session: session, [
            .operationResult(OperationRef(
                operationID: OperationID("a-op-77"), state: .unknown, mutating: false),
                outcome: "unknown"),
        ])
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed.isEmpty)
        #expect(report.nonToolResults == 0, "unknown-state is not a denial receipt")
        #expect(report.orphanResults.map(\.operationID) == [OperationID("a-op-77")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("a-op-77")],
                "explicit unknown-state always holds")
    }

    @Test("A3-2 unknown-state results hold however the flags disagree")
    func unknownStateAlwaysHolds() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Mutating intent, non-mutating unknown result.
        let sessionA = SessionID("s-union-a")
        try Self.seed(path, session: sessionA, [
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: false, state: .unknown, outcome: "unknown"),
        ], writer: "w-a")
        let reportA = try Self.reopenAndReconcile(path, session: sessionA)
        #expect(reportA.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
        // Non-mutating intent, mutating unknown result.
        let sessionB = SessionID("s-union-b")
        try Self.seed(path, session: sessionB, [
            Self.toolIntent("e1/c1", call: "c1", mutating: false),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown"),
        ], writer: "w-b")
        let reportB = try Self.reopenAndReconcile(path, session: sessionB)
        #expect(reportB.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
        // Neither side mutating — still held: unknown-state is the claim.
        let sessionC = SessionID("s-union-c")
        try Self.seed(path, session: sessionC, [
            Self.toolIntent("e1/c1", call: "c1", mutating: false),
            Self.toolResult("e1/c1", call: "c1", mutating: false, state: .unknown, outcome: "unknown"),
        ], writer: "w-c")
        let reportC = try Self.reopenAndReconcile(path, session: sessionC)
        #expect(reportC.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
    }

    @Test("A3-2 duplicate and contradictory ledgers fail closed")
    func malformedLedgersFailClosed() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-bad")
        // Duplicate intents.
        try Self.seed(path, session: session, [
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
        ], writer: "w-dup")
        let dupHandle = try GRDBSessionStore(path: path)
        #expect(throws: StoreError.self) { try dupHandle.reconcile(session: session) }
        try dupHandle.close()

        // Contradictory outcomes: done AND unknown for one ID.
        let session2 = SessionID("s-contra")
        try Self.seed(path, session: session2, [
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .done, outcome: "ok"),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown"),
        ], writer: "w-contra")
        let contraHandle = try GRDBSessionStore(path: path)
        #expect(throws: StoreError.self) { try contraHandle.reconcile(session: session2) }
        try contraHandle.close()

        // Namespace collision: callID-less intent sharing a tool ID.
        let session3 = SessionID("s-collide")
        try Self.seed(path, session: session3, [
            .operationIntent(OperationRef(operationID: OperationID("e1/c1"), state: .intent, mutating: false)),
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
        ], writer: "w-collide")
        let collideHandle = try GRDBSessionStore(path: path)
        #expect(throws: StoreError.self) { try collideHandle.reconcile(session: session3) }
        try collideHandle.close()
    }

    @Test("A3-2 callID-less malformed and duplicated shapes fail closed")
    func callIDLessMalformedShapesFailClosed() throws {
        // CallID-less intent carrying non-intent state.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                .operationIntent(OperationRef(
                    operationID: OperationID("a-op-1"), state: .done, mutating: false)),
            ])
        }
        // CallID-less result carrying intent state.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                .operationResult(OperationRef(
                    operationID: OperationID("a-op-2"), state: .intent, mutating: false),
                    outcome: "nope"),
            ])
        }
        // Duplicate admission intents with the same ID.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                .operationIntent(OperationRef(operationID: OperationID("a-op-3"), state: .intent, mutating: false)),
                .operationIntent(OperationRef(operationID: OperationID("a-op-3"), state: .intent, mutating: false)),
            ])
        }
        // Duplicate denial receipts with the same ID.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                .operationResult(OperationRef(operationID: OperationID("a-op-4"), state: .done, mutating: false), outcome: "denied"),
                .operationResult(OperationRef(operationID: OperationID("a-op-4"), state: .done, mutating: false), outcome: "denied"),
            ])
        }
        // Denial/tool namespace collision: callID-less result sharing a
        // tool operation ID.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.toolIntent("e1/c1", call: "c1", mutating: true),
                .operationResult(OperationRef(operationID: OperationID("e1/c1"), state: .done, mutating: false), outcome: "denied"),
            ])
        }
    }

    @Test("A3-2 malformed record states fail closed")
    func malformedStatesFailClosed() throws {
        // `.intent` state inside a RESULT record.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.toolIntent("e1/c1", call: "c1", mutating: true),
                .operationResult(OperationRef(
                    operationID: OperationID("e1/c1"), callID: "c1",
                    state: .intent, mutating: true), outcome: "nope"),
            ])
        }
        // Non-`.intent` state inside an INTENT record.
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                .operationIntent(OperationRef(
                    operationID: OperationID("e1/c1"), callID: "c1",
                    state: .done, mutating: true)),
            ])
        }
    }

    @Test("A3-2 reconciliation pages the whole session stream")
    func reconciliationPagesWholeStream() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-pages")
        // 505 filler rows force the 500-row pager onto a second page;
        // the operation records must still reconcile.
        var ledger: [DurableRecord] = (0..<505).map { .transcriptAppended(.user("fill-\($0)")) }
        ledger += [
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .done, outcome: "ok"),
        ]
        try Self.seed(path, session: session, ledger)
        let report = try Self.reopenAndReconcile(path, session: session)
        #expect(report.completed == [OperationID("e1/c1")])
        #expect(report.heldOperations.isEmpty)
    }
}
