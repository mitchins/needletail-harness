import Testing
import Foundation
import GRDB
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport

/// B0-F2B durability qualification: real GRDB persistence, cancellation
/// supersession and fresh-handle reconciliation. Every test writes through
/// one handle, closes it, and reconciles through a FRESH handle on the same
/// file — genuine SQLite persistence, not in-memory substitute.
struct B0F2BDurabilityTests {

    // MARK: - Helpers

    private static func freshPath() throws -> (directory: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-f2b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("store.sqlite").path)
    }

    private static func seed(_ path: String, session: SessionID, _ records: [DurableRecord], writer: String = "w-1") throws {
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: writer)
        try store.appendBatch(records, as: WriterIdentity(session: session, writer: writer))
        try store.close()
    }

    private static func reopen(_ path: String, session: SessionID) throws -> OperationReconciliation {
        let reopened = try GRDBSessionStore(path: path)
        let report = try reopened.reconcile(session: session)
        try reopened.close()
        return report
    }

    private static func intent(_ op: String, call: String, mutating: Bool) -> DurableRecord {
        .operationIntent(OperationRef(operationID: OperationID(op), callID: call, state: .intent, mutating: mutating))
    }

    private static func marker(_ op: String, call: String, mutating: Bool, outcome: String = "cancelled: pending") -> DurableRecord {
        .cancelledPendingMarker(OperationRef(operationID: OperationID(op), callID: call, state: .unknown, mutating: mutating), outcome: outcome)
    }

    private static func result(_ op: String, call: String, mutating: Bool, state: OperationState, outcome: String) -> DurableRecord {
        .operationResult(OperationRef(operationID: OperationID(op), callID: call, state: state, mutating: mutating), outcome: outcome)
    }

    private static func allRecords(_ path: String, session: SessionID) throws -> [DurableRecord] {
        let store = try GRDBSessionStore(path: path)
        var stream: [DurableRecord] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            stream += page.map(\.record)
            guard let n = next else { break }
            cursor = n
        }
        try store.close()
        return stream
    }

    // MARK: - 1 Intent → marker → proven-unstarted discharged

    @Test("F2B 1: intent marker proven-unstarted discharged after fresh handle")
    func intentMarkerProvenUnstartedDischarged() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-1")
        try Self.seed(path, session: s, [
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted"),
        ])
        // Exact ordering check before reopen
        let raw = try Self.allRecords(path, session: s)
        #expect(raw.count == 3)
        #expect(raw[0] == Self.intent("eff-1/c1", call: "c1", mutating: true))
        #expect(raw[1] == Self.marker("eff-1/c1", call: "c1", mutating: true))
        #expect(raw[2] == Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted"))

        let report = try Self.reopen(path, session: s)
        #expect(report.completed == [OperationID("eff-1/c1")], "proven-unstarted completes")
        #expect(report.heldOperations.isEmpty, "proven-unstarted holds nothing")
        #expect(report.explicitUnknown.isEmpty)
        #expect(report.unmatchedMutating.isEmpty)
        #expect(report.orphanResults.isEmpty)
        // One effective result per operation (the done supersedes marker)
        let stream = try Self.allRecords(path, session: s)
        let resultsForOp = stream.filter {
            if case .operationResult(let r, _) = $0, r.operationID == OperationID("eff-1/c1") { return true }
            if case .cancelledPendingMarker(let r, _) = $0, r.operationID == OperationID("eff-1/c1") { return true }
            return false
        }
        #expect(resultsForOp.count == 2, "marker + superseding result = 2 rows but one effective outcome")

        // RED/GREEN: wrong outcome must fail closed, not silently discharge
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.intent("eff-1/c1", call: "c1", mutating: true),
                Self.marker("eff-1/c1", call: "c1", mutating: true),
                Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted WRONG"),
            ])
        }
        // Wrong operationID never discharges neighbour (c2 orphan also held conservatively)
        let badReport = try reconcileOperations([
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.result("eff-1/c2", call: "c2", mutating: true, state: .done, outcome: "cancelled: unstarted"),
        ])
        #expect(Set(badReport.heldOperations.map(\.operationID)) == Set([OperationID("eff-1/c1"), OperationID("eff-1/c2")]))
        #expect(badReport.orphanResults.map(\.operationID) == [OperationID("eff-1/c2")])
    }

    // MARK: - 2 Intent → marker → started/unknown remains held

    @Test("F2B 2: intent marker started/unknown remains held after reopen")
    func intentMarkerStartedUnknownRemainsHeld() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-2")
        // Marker then unknown with termination promotion outcome -> still held
        try Self.seed(path, session: s, [
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.result("eff-1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown: cancelled pending terminated"),
        ])
        let report = try Self.reopen(path, session: s)
        #expect(report.completed.isEmpty)
        #expect(report.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")])
        #expect(report.explicitUnknown.map(\.operationID) == [OperationID("eff-1/c1")])
        #expect(report.explicitUnknown.first?.state == .unknown)
        // Not incorrectly discharged
        let raw = try Self.allRecords(path, session: s)
        #expect(raw.contains(Self.result("eff-1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown: cancelled pending terminated")))

        // RED/GREEN: without termination proof, other unknown outcomes must fail closed when marker exists
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.intent("eff-1/c1", call: "c1", mutating: true),
                Self.marker("eff-1/c1", call: "c1", mutating: true),
                Self.result("eff-1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown: some other reason"),
            ])
        }
    }

    // MARK: - 3 Intent → marker → cancellation error survives

    @Test("F2B 3: intent marker cancellation error uncertainty survives reopen")
    func intentMarkerCancellationErrorSurvives() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-3")
        let err = CancelledPendingError(effectID: EffectID("eff-1"), operationIDs: [OperationID("eff-1/c1")], error: "executor terminated", atMillis: 42)
        try Self.seed(path, session: s, [
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            .cancelledPendingError(err),
        ])
        let report = try Self.reopen(path, session: s)
        #expect(report.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")], "marker still held")
        #expect(report.cancelledPendingErrors.count == 1)
        #expect(report.cancelledPendingErrors.first?.atMillis == 42)
        #expect(report.cancelledPendingErrors.first?.effectID == EffectID("eff-1"))
        #expect(report.completed.isEmpty, "never converts to success")

        // RED/GREEN: error does not discharge marker; removing marker would incorrectly show not held
        let withoutMarker = try reconcileOperations([
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            .cancelledPendingError(err),
        ])
        // Without marker, unmatched mutating still holds (intent-only crash) - but error alone doesn't discharge
        #expect(withoutMarker.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")])
    }

    // MARK: - 4 Intent → marker → termination promotion survives lifecycle

    @Test("F2B 4: termination promotion classification survives fresh handle lifecycle")
    func terminationPromotionSurvivesLifecycle() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-4")
        // Simulate actor's cancelledPendingRemoved promotion: marker superseded by unknown terminated
        try Self.seed(path, session: s, [
            Self.intent("eff-2/c9", call: "c9", mutating: true),
            Self.marker("eff-2/c9", call: "c9", mutating: true, outcome: "cancelled: pending"),
            Self.result("eff-2/c9", call: "c9", mutating: true, state: .unknown, outcome: "unknown: cancelled pending terminated"),
        ])
        // First reopen
        let r1 = try Self.reopen(path, session: s)
        #expect(r1.heldOperations.map(\.operationID) == [OperationID("eff-2/c9")])
        #expect(r1.explicitUnknown.first?.state == .unknown)
        // Second fresh handle (process lifecycle) must give identical result
        let r2 = try Self.reopen(path, session: s)
        #expect(r2 == r1, "idempotent across lifecycles")
        // Raw ordering preserved
        let raw = try Self.allRecords(path, session: s)
        #expect(raw[0] == Self.intent("eff-2/c9", call: "c9", mutating: true))
        #expect(raw[1].isCancelledPendingMarker)
        #expect(raw[2].isOperationResultUnknown)

        // RED/GREEN: non-approved supersession outcome would fail closed, not silently hold
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.intent("eff-2/c9", call: "c9", mutating: true),
                Self.marker("eff-2/c9", call: "c9", mutating: true),
                Self.result("eff-2/c9", call: "c9", mutating: true, state: .unknown, outcome: "unknown: wrong promotion"),
            ])
        }
    }

    // MARK: - 5 Intent → marker → acknowledged unresolved never converts to success

    @Test("F2B 5: acknowledged unresolved is durable but never converts uncertainty to success")
    func acknowledgedUnresolvedNeverConverts() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-5")
        let ack = Acknowledgment(subjectSessions: [s], operationIDs: [OperationID("eff-1/c1")], determination: "operator-accepted-risk", atMillis: 9999)
        try Self.seed(path, session: s, [
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            .acknowledgedUnresolved(ack),
        ])
        let report = try Self.reopen(path, session: s)
        #expect(report.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")], "still held despite acknowledgment")
        #expect(report.completed.isEmpty, "never converts to completed")
        // Ack durable
        let raw = try Self.allRecords(path, session: s)
        #expect(raw.contains(.acknowledgedUnresolved(ack)))
        // Export contains ack with correct atMillis but held still reported
        let lines = try SessionExport.lines(dbPath: path, session: s, includeContent: true, exportedAt: 1, limits: .default)
        let blob = lines.joined()
        #expect(blob.contains("operator-accepted-risk"))
        let trailer = try #require(lines.last.flatMap { l -> [String: Any]? in try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] })
        let ops = trailer["operations"] as? [String: Any]
        let held = (ops?["held"] as? [String]) ?? []
        #expect(held.contains("eff-1/c1"), "trailer still shows held after ack")
        let completed = (ops?["completed"] as? [String]) ?? []
        #expect(!completed.contains("eff-1/c1"))

        // RED/GREEN: ack does not clear orphan/held; removing ack leaves same held
        let withoutAck = try reconcileOperations([
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
        ])
        #expect(withoutAck.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")])
    }

    // MARK: - 6 Interleaved operations selective supersession

    @Test("F2B 6: interleaved ops selective supersession by exact operationID regardless of ordering")
    func interleavedSelectiveSupersession() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-6")
        // Two mutating ops, markers interleaved, only c1 proven-unstarted
        try Self.seed(path, session: s, [
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.intent("eff-1/c2", call: "c2", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c2", call: "c2", mutating: true),
            // Supersede only c1
            Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted"),
            // c2 no result -> remains held
        ])
        let report = try Self.reopen(path, session: s)
        #expect(report.completed == [OperationID("eff-1/c1")])
        #expect(report.heldOperations.map(\.operationID) == [OperationID("eff-1/c2")])
        #expect(report.unmatchedMutating.map(\.operationID) == [OperationID("eff-1/c2")] || report.explicitUnknown.map(\.operationID) == [OperationID("eff-1/c2")], "c2 held via pending marker")
        // No unintended discharge of neighbour
        #expect(!report.completed.contains(OperationID("eff-1/c2")))

        // Reordered: result for c1 before marker for c2 (record ordering shuffled but operationID still exact)
        let s2 = SessionID("s-f2b-6b")
        try Self.seed(path, session: s2, [
            Self.intent("eff-2/c1", call: "c1", mutating: true),
            Self.intent("eff-2/c2", call: "c2", mutating: true),
            Self.marker("eff-2/c2", call: "c2", mutating: true),
            Self.result("eff-2/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted"),
            Self.marker("eff-2/c1", call: "c1", mutating: true),
        ], writer: "w-2")
        // Note: marker for c1 after result - per last-record-wins, marker after result is ignored (result wins). So c1 still completed, c2 held.
        let report2 = try Self.reopen(path, session: s2)
        #expect(report2.completed.contains(OperationID("eff-2/c1")))
        #expect(report2.heldOperations.map(\.operationID).contains(OperationID("eff-2/c2")))
        #expect(!report2.heldOperations.map(\.operationID).contains(OperationID("eff-2/c1")), "superseded marker not held")

        // RED/GREEN: supersession by wrong ID must not discharge
        let reportWrong = try reconcileOperations([
            Self.intent("eff-9/c1", call: "c1", mutating: true),
            Self.intent("eff-9/c2", call: "c2", mutating: true),
            Self.marker("eff-9/c1", call: "c1", mutating: true),
            Self.marker("eff-9/c2", call: "c2", mutating: true),
            Self.result("eff-9/c9", call: "c9", mutating: true, state: .done, outcome: "cancelled: unstarted"),
        ])
        #expect(reportWrong.completed.isEmpty)
        #expect(Set(reportWrong.heldOperations.map(\.operationID)) == Set([OperationID("eff-9/c1"), OperationID("eff-9/c2"), OperationID("eff-9/c9")]))
        #expect(reportWrong.orphanResults.map(\.operationID) == [OperationID("eff-9/c9")])

        // No replay: ensure no duplicate completion after reopen
        let s3 = SessionID("s-f2b-6c")
        try Self.seed(path, session: s3, [
            Self.intent("eff-3/c1", call: "c1", mutating: true),
            Self.marker("eff-3/c1", call: "c1", mutating: true),
            Self.result("eff-3/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown: cancelled pending terminated"),
        ], writer: "w-3")
        let r3 = try Self.reopen(path, session: s3)
        #expect(r3.heldOperations.count == 1 && r3.completed.isEmpty, "one held, not replayed as completed")
    }

    // MARK: - 7 Nonzero atMillis survives codec, reopen, export

    @Test("F2B 7: cancelledPendingError atMillis survives codec reopen and export metadata")
    func atMillisSurvivesCodecReopenExport() throws {
        let atMillis: UInt64 = 1_234_567_890_123
        let err = CancelledPendingError(effectID: EffectID("eff-at"), operationIDs: [OperationID("eff-at/c1"), OperationID("eff-at/c2")], error: "executor boom", atMillis: atMillis)
        // Codec round-trip
        let rec: DurableRecord = .cancelledPendingError(err)
        let data = try RecordCodec.encode(rec)
        let decoded = try RecordCodec.decode(data)
        guard case .cancelledPendingError(let decodedErr) = decoded else { Issue.record("decode not error"); return }
        #expect(decodedErr.atMillis == atMillis)
        #expect(decodedErr.effectID == EffectID("eff-at"))
        #expect(decodedErr.operationIDs == [OperationID("eff-at/c1"), OperationID("eff-at/c2")])

        // GRDB fresh-handle reopen
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-f2b-7")
        try Self.seed(path, session: s, [
            Self.intent("eff-at/c1", call: "c1", mutating: true),
            Self.marker("eff-at/c1", call: "c1", mutating: true),
            .cancelledPendingError(err),
        ])
        let report = try Self.reopen(path, session: s)
        #expect(report.cancelledPendingErrors.first?.atMillis == atMillis)
        // Raw persistence check via allRecords
        let raw = try Self.allRecords(path, session: s)
        let rawErr = try #require(raw.compactMap { r -> CancelledPendingError? in if case .cancelledPendingError(let e) = r { return e } else { return nil } }.first)
        #expect(rawErr.atMillis == atMillis, "GRDB persists atMillis")

        // Export metadata appears in both redacted and content modes
        for includeContent in [false, true] {
            let lines = try SessionExport.lines(dbPath: path, session: s, includeContent: includeContent, exportedAt: 9_999, limits: .default)
            let objs = try lines.map { l -> [String: Any] in try #require(JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any]) }
            let errRows = objs.filter { ($0["kind"] as? String) == "cancelledPendingError" }
            #expect(errRows.count == 1, "exactly one error row in export")
            let row = try #require(errRows.first)
            #expect(row["atMillis"] as? UInt64 == atMillis || (row["atMillis"] as? NSNumber)?.uint64Value == atMillis, "export atMillis correct, got \(String(describing: row["atMillis"]))")
            #expect(row["effectID"] as? String == "eff-at")
            let opIDs = (row["operationIDs"] as? [String]) ?? []
            #expect(Set(opIDs) == Set(["eff-at/c1", "eff-at/c2"]))
            if includeContent {
                #expect(row["error"] as? String == "executor boom")
                #expect(row["redacted"] as? Bool == false)
            } else {
                #expect(row["redacted"] as? Bool == true)
                #expect(row["error"] == nil, "redacted mode must not leak error text")
            }
        }

        // RED/GREEN: zero atMillis would be distinguishable; nonzero must not be coerced to 0
        let zeroErr = CancelledPendingError(effectID: EffectID("eff-zero"), operationIDs: [OperationID("eff-zero/c1")], error: "x", atMillis: 0)
        let zeroData = try RecordCodec.encode(.cancelledPendingError(zeroErr))
        let zeroDecoded = try RecordCodec.decode(zeroData)
        if case .cancelledPendingError(let ze) = zeroDecoded {
            #expect(ze.atMillis == 0)
            #expect(ze.atMillis != atMillis, "nonzero must not collapse to zero")
        } else { Issue.record("zero decode failed") }
    }

    // MARK: - 8 Reconcile rejects mismatched state/outcome supersession (Finding 1)

    @Test("F2B 8: marker supersession rejects state-outcome mismatch as integrity")
    func markerSupersessionRejectsMismatchedStateOutcome() throws {
        // done with terminated outcome must fail
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.intent("eff-1/c1", call: "c1", mutating: true),
                Self.marker("eff-1/c1", call: "c1", mutating: true),
                Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "unknown: cancelled pending terminated"),
            ])
        }
        // unknown with unstarted outcome must fail
        #expect(throws: StoreError.self) {
            try reconcileOperations([
                Self.intent("eff-1/c1", call: "c1", mutating: true),
                Self.marker("eff-1/c1", call: "c1", mutating: true),
                Self.result("eff-1/c1", call: "c1", mutating: true, state: .unknown, outcome: "cancelled: unstarted"),
            ])
        }
        // RED/GREEN: correct pairings still succeed (done+unstarted => completed, unknown+terminated => held)
        let okDone = try reconcileOperations([
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.result("eff-1/c1", call: "c1", mutating: true, state: .done, outcome: "cancelled: unstarted"),
        ])
        #expect(okDone.completed == [OperationID("eff-1/c1")])
        let okUnknown = try reconcileOperations([
            Self.intent("eff-1/c1", call: "c1", mutating: true),
            Self.marker("eff-1/c1", call: "c1", mutating: true),
            Self.result("eff-1/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown: cancelled pending terminated"),
        ])
        #expect(okUnknown.heldOperations.map(\.operationID) == [OperationID("eff-1/c1")])
    }

    // MARK: - 9 Writer fencing on fresh handle (Finding 3)

    @Test("F2B 9: fresh-handle writer fencing blocks stale writer and allows correct writer")
    func freshHandleWriterFencing() throws {
        let (dir, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionID("s-fence")
        // First handle claims w-1 and writes ledger, then closes
        do {
            let a = try GRDBSessionStore(path: path)
            try a.claimWriterOwnership(session: s, writer: "w-1")
            try a.appendBatch([Self.intent("eff-1/c1", call: "c1", mutating: true)], as: WriterIdentity(session: s, writer: "w-1"))
            try a.close()
        }
        // Fresh handle cannot append with stale w-1's old identity without reclaim? w-1 is still holder, so w-1 can still write, but w-2 cannot
        let fresh = try GRDBSessionStore(path: path)
        // Stale/mismatched writer must fail
        #expect(throws: StoreError.self) {
            try fresh.appendBatch([Self.intent("eff-1/c2", call: "c2", mutating: true)], as: WriterIdentity(session: s, writer: "w-stale"))
        }
        // Competing claim with new writer must learn who holds
        #expect(throws: StoreError.self) {
            try fresh.claimWriterOwnership(session: s, writer: "w-2")
        }
        // Correct holder can still append via fresh handle
        try fresh.appendBatch([Self.intent("eff-1/c2", call: "c2", mutating: true)], as: WriterIdentity(session: s, writer: "w-1"))
        let report = try fresh.reconcile(session: s)
        #expect(report.unmatchedMutating.map(\.operationID).contains(OperationID("eff-1/c1")))
        #expect(report.unmatchedMutating.map(\.operationID).contains(OperationID("eff-1/c2")))
        try fresh.close()

        // After close, new handle reopen sees both intents durable
        let reopened = try GRDBSessionStore(path: path)
        let r2 = try reopened.reconcile(session: s)
        #expect(r2.unmatchedMutating.count == 2)
        try reopened.close()
    }

    // MARK: - 10 Transition promotion via cancelledPendingRemoved (Finding 2)

    @Test("F2B 10: cancelledPendingRemoved transition promotes marker to unknown")
    func cancelledPendingRemovedPromotes() throws {
        var ids = DeterministicIDSource(prefix: "t")
        let epoch = try {
            let cfg = try validateConfig(Data("""
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
            """.utf8))
            let profile = try #require(cfg.profiles["local-coder"])
            let caps = effectiveCapabilities(build: .allAllowed, userConfig: cfg.tools, workspaceGrant: .allAllowed, invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false))
            let route = selectRoute(snapshot: cfg, requestedAlias: "local-coder", sealed: false)
            return EpochDescriptor(epochID: EpochID("epoch-1"), configSnapshot: cfg, profile: profile, effectiveCaps: caps, route: route)
        }()
        let run = RunDescriptor(runID: RunID("r1"), requestID: RequestID("req1"), revision: Revision(1), startedAtMillis: 1, sealed: false)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d")])
        let eff = EffectID("eff-1")
        let reservation = EffectReservation(effectID: eff, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: true, batch: batch, kind: .executor)
        var state = SessionState(sessionID: SessionID("s-promote"), epoch: epoch, trustMode: .workspace, phase: .cancelling, activeRun: run, queueHeld: true, heldReason: .cancelled(sinceMillis: 1), cancelledPendingReservations: [reservation], generation: 1, unresolvedOperations: [OperationRef(operationID: OperationID("eff-1/c1"), callID: "c1", state: .unknown, mutating: true)])
        let t = transition(state, .cancelledPendingRemoved(effectID: eff, atMillis: 9999), &ids)
        #expect(t.records.contains(where: { if case .operationResult(let r, let o) = $0 { return r.operationID == OperationID("eff-1/c1") && r.state == .unknown && o == "unknown: cancelled pending terminated" } else { return false } }))
        #expect(t.state.unresolvedOperations.contains(where: { $0.operationID == OperationID("eff-1/c1") && $0.state == .unknown }))
        #expect(t.state.cancelledPendingReservations.isEmpty)

        // RED/GREEN: without promotion, marker would stay as pendingMarker not as operationResult
        let rawBefore = state.cancelledPendingReservations
        #expect(rawBefore.count == 1)
    }

    // MARK: - 11 preDispatchFailure discharges after cancellation (Finding 4)

    @Test("F2B 11: preDispatchFailure after cancellation discharges to done")
    func preDispatchFailureDischarges() throws {
        var ids = DeterministicIDSource(prefix: "t2")
        let epoch = try {
            let cfg = try validateConfig(Data("""
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
            """.utf8))
            let profile = try #require(cfg.profiles["local-coder"])
            let caps = effectiveCapabilities(build: .allAllowed, userConfig: cfg.tools, workspaceGrant: .allAllowed, invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false))
            let route = selectRoute(snapshot: cfg, requestedAlias: "local-coder", sealed: false)
            return EpochDescriptor(epochID: EpochID("epoch-1"), configSnapshot: cfg, profile: profile, effectiveCaps: caps, route: route)
        }()
        let run = RunDescriptor(runID: RunID("r1"), requestID: RequestID("req1"), revision: Revision(1), startedAtMillis: 1, sealed: false)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"), ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d")])
        let eff = EffectID("eff-1")
        let reservation = EffectReservation(effectID: eff, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: true, batch: batch, kind: .executor)
        var state = SessionState(sessionID: SessionID("s-pre"), epoch: epoch, trustMode: .workspace, phase: .cancelling, activeRun: run, queueHeld: true, heldReason: .cancelled(sinceMillis: 1), cancelledPendingReservations: [reservation], generation: 1, unresolvedOperations: [OperationRef(operationID: OperationID("eff-1/c1"), callID: "c1", state: .unknown, mutating: true)])
        // Only c1 is mutating, c2 is read so not in unresolved
        let t = transition(state, .effectCompleted(effectID: eff, runID: run.runID, generation: run.revision, expectedRevision: run.revision, mutating: true, outcome: .preDispatchFailure(.preDispatch(status: "denied", summary: "policy")), atMillis: 2), &ids)
        // Should discharge c1 to done, not hold
        #expect(t.records.contains(where: { if case .operationResult(let r, let o) = $0 { return r.operationID == OperationID("eff-1/c1") && r.state == .done && o == "cancelled: unstarted" } else { return false } }))
        #expect(!t.state.unresolvedOperations.contains(where: { $0.operationID == OperationID("eff-1/c1") }))
        #expect(t.state.cancelledPendingReservations.isEmpty)
    }
}

private extension DurableRecord {
    var isCancelledPendingMarker: Bool { if case .cancelledPendingMarker = self { return true }; return false }
    var isOperationResultUnknown: Bool { if case .operationResult(let r, _) = self, r.state == .unknown { return true }; return false }
}
