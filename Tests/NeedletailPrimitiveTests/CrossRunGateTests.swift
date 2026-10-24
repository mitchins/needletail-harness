import Testing
import Foundation
import GRDB
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport

/// B5-B cross-run unresolved-outcome gate: native legs against real
/// stores (GRDB file store incl. fresh-handle reopen, InMemory,
/// SQLite probe, forwarding wrapper). Every scenario the contract
/// mandates: empty bootstrap, clean sessions, non-mutating-only
/// intents, mutating intent/result holds, explicit unknown + cancelled
/// markers, corrupt fail-closed, cross-workspace detection, the exact
/// three-run no-consumption sequence, acknowledgment commit + verify,
/// export redaction + exact identity, and counterfactual hazard pins.
struct CrossRunGateTests {

    // MARK: - Fixtures

    private static func tempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func freshGRDB(in directory: URL, name: String = "store.sqlite") throws -> GRDBSessionStore {
        try GRDBSessionStore(path: directory.appendingPathComponent(name).path)
    }

    private static func intent(
        _ op: String, call: String?, mutating: Bool
    ) -> DurableRecord {
        .operationIntent(OperationRef(
            operationID: OperationID(op), callID: call, state: .intent, mutating: mutating))
    }

    private static func result(
        _ op: String, call: String?, mutating: Bool, state: OperationState, outcome: String
    ) -> DurableRecord {
        .operationResult(OperationRef(
            operationID: OperationID(op), callID: call, state: state, mutating: mutating),
            outcome: outcome)
    }

    private static func seed(
        _ store: GRDBSessionStore, session: String, writer: String,
        records: [DurableRecord]
    ) throws {
        let id = SessionID(session)
        try store.claimWriterOwnership(session: id, writer: writer)
        try store.appendBatch(records, as: WriterIdentity(session: id, writer: writer))
    }

    private static func seed(
        _ store: InMemorySessionStore, session: String, writer: String,
        records: [DurableRecord]
    ) throws {
        let id = SessionID(session)
        try store.claimWriterOwnership(session: id, writer: writer)
        try store.appendBatch(records, as: WriterIdentity(session: id, writer: writer))
    }

    /// Forwarding wrapper (same shape as the actor-test doubles): proves
    /// `sessions()` delegation carries the real set through.
    private final class ForwardingStore: SessionStore, @unchecked Sendable {
        private let inner: InMemorySessionStore
        init(inner: InMemorySessionStore) { self.inner = inner }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try inner.append(record, as: identity)
        }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            try inner.appendBatch(records, as: identity)
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }
        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try inner.claimWriterOwnership(session: session, writer: writer)
        }
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try inner.releaseWriterOwnership(session: session, writer: writer)
        }
        func sessions() throws -> [SessionID] { try inner.sessions() }
    }

    ///-Blind wrapper: simulates the FORBIDDEN permissive default
    /// (`sessions()` silently returning []) over a dirty inner store.
    /// Used ONLY by the silent-exemption counterfactual.
    private final class BlindStore: SessionStore, @unchecked Sendable {
        private let inner: InMemorySessionStore
        init(inner: InMemorySessionStore) { self.inner = inner }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try inner.append(record, as: identity)
        }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            try inner.appendBatch(records, as: identity)
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }
        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try inner.claimWriterOwnership(session: session, writer: writer)
        }
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try inner.releaseWriterOwnership(session: session, writer: writer)
        }
        func sessions() throws -> [SessionID] { [] }
    }

    /// Silent-drop wrapper: `append` of the acknowledgment SUCCEEDS but
    /// the record never lands. Simulates a persistence failure the caller
    /// cannot see without the read-back verification.
    private final class SilentDropStore: SessionStore, @unchecked Sendable {
        private let inner: InMemorySessionStore
        init(inner: InMemorySessionStore) { self.inner = inner }
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            if case .acknowledgedUnresolved = record { return }
            try inner.append(record, as: identity)
        }
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            for record in records { try append(record, as: identity) }
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }
        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try inner.claimWriterOwnership(session: session, writer: writer)
        }
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try inner.releaseWriterOwnership(session: session, writer: writer)
        }
        func sessions() throws -> [SessionID] { try inner.sessions() }
    }

    // MARK: - sessions() enumeration

    @Test("B5-B empty store enumerates empty (GRDB, InMemory, probe)")
    func emptyStoreEnumeratesEmpty() throws {
        let directory = try Self.tempDir(prefix: "gate-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grdb = try Self.freshGRDB(in: directory)
        defer { try? grdb.close() }
        #expect(try grdb.sessions().isEmpty)
        #expect(try InMemorySessionStore().sessions().isEmpty)
        let probe = try SQLiteProbeStore(
            path: directory.appendingPathComponent("probe.sqlite").path, limit: 100)
        #expect(try probe.sessions().isEmpty)
    }

    @Test("B5-B sessions enumerates every session once, sorted")
    func sessionsEnumeratesOnceSorted() throws {
        let directory = try Self.tempDir(prefix: "gate-sessions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grdb = try Self.freshGRDB(in: directory)
        defer { try? grdb.close() }
        // Insert out of order with duplicates-heavy streams.
        try Self.seed(grdb, session: "s-zulu", writer: "w", records: [
            .sessionOpened(session: SessionID("s-zulu"), atMillis: 1),
            .transcriptAppended(.user("z")),
        ])
        try Self.seed(grdb, session: "s-alpha", writer: "w", records: [
            .sessionOpened(session: SessionID("s-alpha"), atMillis: 2),
        ])
        try Self.seed(grdb, session: "s-mike", writer: "w", records: [
            .sessionOpened(session: SessionID("s-mike"), atMillis: 3),
            .transcriptAppended(.user("m1")),
            .transcriptAppended(.user("m2")),
        ])
        let ids = try grdb.sessions().map(\.raw)
        #expect(ids == ["s-alpha", "s-mike", "s-zulu"])
    }

    @Test("B5-B sessions visible on fresh-handle reopen (GRDB durability)")
    func sessionsSurviveReopen() throws {
        let directory = try Self.tempDir(prefix: "gate-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try Self.freshGRDB(in: directory)
        try Self.seed(first, session: "s-dirty", writer: "w", records: [
            Self.intent("e1/c1", call: "c1", mutating: true),
        ])
        try first.close()
        let second = try Self.freshGRDB(in: directory)
        defer { try? second.close() }
        #expect(try second.sessions().map(\.raw) == ["s-dirty"])
        // And the hold is visible through the fresh handle too.
        let holds = try CrossRunGate.unresolvedHolds(store: second)
        #expect(holds.count == 1)
        #expect(holds[0].session.raw == "s-dirty")
    }

    @Test("B5-B InMemory sessions + forwarding wrapper enumerate")
    func inMemoryAndWrapperEnumerate() throws {
        let inner = InMemorySessionStore()
        #expect(try inner.sessions().isEmpty)
        try Self.seed(inner, session: "s-b", writer: "w", records: [
            .transcriptAppended(.user("b")),
        ])
        try Self.seed(inner, session: "s-a", writer: "w", records: [
            .transcriptAppended(.user("a")),
        ])
        #expect(try inner.sessions().map(\.raw) == ["s-a", "s-b"])
        let forwarded = ForwardingStore(inner: inner)
        #expect(try forwarded.sessions().map(\.raw) == ["s-a", "s-b"])
    }

    @Test("B5-B probe store enumerates transcript sessions")
    func probeStoreEnumerates() throws {
        let directory = try Self.tempDir(prefix: "gate-probe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try SQLiteProbeStore(
            path: directory.appendingPathComponent("probe.sqlite").path, limit: 100)
        let id = SessionID("s-p")
        try probe.claimWriterOwnership(session: id, writer: "w")
        try probe.append(.transcriptAppended(.user("hi")), as: WriterIdentity(session: id, writer: "w"))
        #expect(try probe.sessions().map(\.raw) == ["s-p"])
    }

    // MARK: - Gate classification

    @Test("B5-B empty store is clean")
    func emptyStoreIsClean() throws {
        #expect(try CrossRunGate.unresolvedHolds(store: InMemorySessionStore()).isEmpty)
        let directory = try Self.tempDir(prefix: "gate-clean0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grdb = try Self.freshGRDB(in: directory)
        defer { try? grdb.close() }
        #expect(try CrossRunGate.unresolvedHolds(store: grdb).isEmpty)
    }

    @Test("B5-B clean sessions do not trip (completed mutating, identities only)")
    func cleanSessionsDoNotTrip() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-clean", writer: "w", records: [
            .sessionOpened(session: SessionID("s-clean"), atMillis: 1),
            Self.intent("e1/c1", call: "c1", mutating: true),
            Self.result("e1/c1", call: "c1", mutating: true, state: .done, outcome: "ok"),
        ])
        try Self.seed(store, session: "s-ident", writer: "w2", records: [
            .sessionOpened(session: SessionID("s-ident"), atMillis: 2),
        ])
        #expect(try CrossRunGate.unresolvedHolds(store: store).isEmpty)
    }

    @Test("B5-B unmatched non-mutating intents do not block")
    func nonMutatingIntentsDoNotBlock() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-ro", writer: "w", records: [
            Self.intent("read-1", call: "c1", mutating: false),
            // CallID-less noise: admission marker + denial receipt.
            .operationIntent(OperationRef(
                operationID: OperationID("admit-1"), callID: nil, state: .intent, mutating: false)),
            .operationResult(OperationRef(
                operationID: OperationID("deny-1"), callID: nil, state: .done, mutating: false),
                outcome: "denied"),
        ])
        #expect(try CrossRunGate.unresolvedHolds(store: store).isEmpty)
    }

    @Test("B5-B unmatched mutating intent trips with exact session + op IDs")
    func unmatchedMutatingTrips() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-dirty", writer: "w", records: [
            Self.intent("e1/c9", call: "c9", mutating: true),
        ])
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 1)
        #expect(holds[0].session.raw == "s-dirty")
        #expect(holds[0].unmatchedMutating.map(\.operationID.raw) == ["e1/c9"])
        #expect(holds[0].operationIDs.map(\.raw) == ["e1/c9"])
    }

    @Test("B5-B explicit unknown results trip")
    func explicitUnknownTrips() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-unk", writer: "w", records: [
            Self.intent("e2/c1", call: "c1", mutating: true),
            Self.result("e2/c1", call: "c1", mutating: true, state: .unknown, outcome: "unknown"),
        ])
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 1)
        #expect(holds[0].heldOperations.count == 1)
        #expect(holds[0].operationIDs.map(\.raw) == ["e2/c1"])
    }

    @Test("B5-B unsuperseded cancelled-pending marker trips; superseded does not")
    func cancelledPendingMarkerSemantics() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-held", writer: "w", records: [
            Self.intent("e3/c1", call: "c1", mutating: true),
            .cancelledPendingMarker(OperationRef(
                operationID: OperationID("e3/c1"), callID: "c1", state: .unknown, mutating: true),
                outcome: "unknown: cancelled pending"),
        ])
        try Self.seed(store, session: "s-cleared", writer: "w2", records: [
            Self.intent("e4/c1", call: "c1", mutating: true),
            .cancelledPendingMarker(OperationRef(
                operationID: OperationID("e4/c1"), callID: "c1", state: .unknown, mutating: true),
                outcome: "unknown: cancelled pending"),
            Self.result("e4/c1", call: "c1", mutating: true, state: .done,
                        outcome: "cancelled: unstarted"),
        ])
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 1)
        #expect(holds[0].session.raw == "s-held")
    }

    @Test("B5-B corrupt ledger fails closed (duplicate intents)")
    func corruptLedgerFailsClosed() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-bad", writer: "w", records: [
            Self.intent("e5/c1", call: "c1", mutating: true),
            Self.intent("e5/c1", call: "c1", mutating: true),
        ])
        #expect(throws: StoreError.integrity("duplicate intent for operation e5/c1")) {
            try CrossRunGate.unresolvedHolds(store: store)
        }
    }

    @Test("B5-B undecodable row fails closed through a real GRDB file")
    func undecodableRowFailsClosedNative() throws {
        let directory = try Self.tempDir(prefix: "gate-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        try Self.seed(store, session: "s-ok", writer: "w", records: [
            .transcriptAppended(.user("fine")),
        ])
        try store.close()
        // Corrupt one row with raw SQL on a fresh handle (simulates disk
        // corruption / foreign writer — never decodable, never skipped).
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO records (session, payload) VALUES (?, ?)",
                arguments: ["s-corrupt", "not-json{{{"])
        }
        try queue.close()
        let reopened = try GRDBSessionStore(path: dbPath)
        defer { try? reopened.close() }
        #expect(throws: StoreError.self) {
            try CrossRunGate.unresolvedHolds(store: reopened)
        }
    }

    @Test("B5-B unknown record case fails closed (M2-A foreign-row contract)")
    func unknownCaseFailsClosed() throws {
        let directory = try Self.tempDir(prefix: "gate-future")
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        try store.close()
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO records (session, payload) VALUES (?, ?)",
                arguments: ["s-future", "{\"futureCase\":{}}"])
        }
        try queue.close()
        let reopened = try GRDBSessionStore(path: dbPath)
        defer { try? reopened.close() }
        #expect(throws: StoreError.self) {
            try CrossRunGate.unresolvedHolds(store: reopened)
        }
    }

    // MARK: - Cross-workspace + three-run no-consumption

    @Test("B5-B hold in one workspace blocks a gate check for another (store-wide)")
    func crossWorkspaceHoldDetected() throws {
        // Workspace identity never enters the ledger: the gate takes no
        // workspace input by construction, so dirt from ANY origin blocks.
        let directory = try Self.tempDir(prefix: "gate-xws")
        defer { try? FileManager.default.removeItem(at: directory) }
        let seeder = try Self.freshGRDB(in: directory)
        try Self.seed(seeder, session: "s-workspace-one", writer: "w", records: [
            Self.intent("e6/c1", call: "c1", mutating: true),
        ])
        try seeder.close()
        // "Another workspace" = a fresh handle with no shared state except
        // the same store file.
        let other = try Self.freshGRDB(in: directory)
        defer { try? other.close() }
        let holds = try CrossRunGate.unresolvedHolds(store: other)
        #expect(holds.count == 1)
        #expect(holds[0].session.raw == "s-workspace-one")
    }

    @Test("B5-B exact three-run sequence: ack never consumes historical holds")
    func threeRunSequenceNoConsumption() throws {
        let directory = try Self.tempDir(prefix: "gate-3run")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Run A leaves an unresolved mutating operation.
        let runA = try Self.freshGRDB(in: directory)
        try Self.seed(runA, session: "s-run-a", writer: "w-a", records: [
            Self.intent("ea/c1", call: "c1", mutating: true),
        ])
        try runA.close()
        // Run B's gate trips (blocked without authorization).
        let runB = try Self.freshGRDB(in: directory)
        var holdsB = try CrossRunGate.unresolvedHolds(store: runB)
        #expect(holdsB.count == 1)
        #expect(holdsB[0].session.raw == "s-run-a")
        // Run B records its explicit decision in its OWN session.
        let idB = SessionID("s-run-b")
        try runB.claimWriterOwnership(session: idB, writer: "w-b")
        try runB.append(
            .sessionOpened(session: idB, atMillis: 100), as: WriterIdentity(session: idB, writer: "w-b"))
        let ackB = Acknowledgment(
            subjectSessions: holdsB.map(\.session),
            operationIDs: holdsB.flatMap(\.operationIDs),
            determination: "operator-accepted-risk", atMillis: 200)
        try CrossRunGate.appendAcknowledgment(
            store: runB, as: WriterIdentity(session: idB, writer: "w-b"), acknowledgment: ackB)
        try runB.close()
        // Run C is blocked AGAIN: B's acknowledgment consumed nothing.
        let runC = try Self.freshGRDB(in: directory)
        defer { try? runC.close() }
        holdsB = try CrossRunGate.unresolvedHolds(store: runC)
        #expect(holdsB.count == 1)
        #expect(holdsB[0].session.raw == "s-run-a")
        #expect(holdsB[0].operationIDs.map(\.raw) == ["ea/c1"])
        // B's session carries the decision; A's holds are preserved.
        let (pageB, _) = try runC.records(session: idB, since: 0, limit: 100)
        #expect(pageB.map(\.record).contains(.acknowledgedUnresolved(ackB)))
        let reportA = try runC.reconcile(session: SessionID("s-run-a"))
        #expect(reportA.heldOperations.map(\.operationID.raw) == ["ea/c1"])
    }

    @Test("B5-B acknowledgment records exact subjects, ops, determination, time")
    func acknowledgmentRecordsExactIdentity() throws {
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-d1", writer: "w", records: [
            Self.intent("e7/c1", call: "c1", mutating: true),
        ])
        try Self.seed(store, session: "s-d2", writer: "w2", records: [
            Self.intent("e8/c1", call: "c1", mutating: false),
            Self.intent("e8/c2", call: "c2", mutating: true),
        ])
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 2)
        let idN = SessionID("s-new")
        try store.claimWriterOwnership(session: idN, writer: "w-n")
        let identity = WriterIdentity(session: idN, writer: "w-n")
        try store.append(.sessionOpened(session: idN, atMillis: 1), as: identity)
        let ack = Acknowledgment(
            subjectSessions: holds.map(\.session),
            operationIDs: holds.flatMap(\.operationIDs),
            determination: "manually-reconciled:ops-verified-by-hand", atMillis: 4242)
        try CrossRunGate.appendAcknowledgment(store: store, as: identity, acknowledgment: ack)
        let (page, _) = try store.records(session: idN, since: 0, limit: 100)
        let acks = page.compactMap { record -> Acknowledgment? in
            if case .acknowledgedUnresolved(let a) = record.record { return a }
            return nil
        }
        #expect(acks == [ack])
        #expect(acks[0].subjectSessions.map(\.raw) == ["s-d1", "s-d2"])
        #expect(acks[0].operationIDs.map(\.raw) == ["e7/c1", "e8/c2"])
        #expect(acks[0].determination == "manually-reconciled:ops-verified-by-hand")
        #expect(acks[0].atMillis == 4242)
    }

    @Test("B5-B flag without a committed acknowledgment is not authorization")
    func missingPersistenceBlocks() throws {
        // (a) Loud append failure throws.
        let inner = InMemorySessionStore()
        try Self.seed(inner, session: "s-d", writer: "w", records: [
            Self.intent("e9/c1", call: "c1", mutating: true),
        ])
        let idN = SessionID("s-n")
        try inner.claimWriterOwnership(session: idN, writer: "w-n")
        let identity = WriterIdentity(session: idN, writer: "w-n")
        let ack = Acknowledgment(
            subjectSessions: [SessionID("s-d")], operationIDs: [OperationID("e9/c1")],
            determination: "operator-accepted-risk", atMillis: 1)
        // (b) Silent drop: append "succeeds" but nothing lands — the
        // read-back verification still refuses to proceed.
        let silent = SilentDropStore(inner: InMemorySessionStore())
        try silent.claimWriterOwnership(session: idN, writer: "w-n")
        #expect(throws: StoreError.self) {
            try CrossRunGate.appendAcknowledgment(store: silent, as: identity, acknowledgment: ack)
        }
    }

    // MARK: - Counterfactuals (hazard pins: these PASS by showing the hazard)

    @Test("B5-B COUNTERFACTUAL: a permissive empty sessions() blinds the gate")
    func counterfactualSilentExemption() throws {
        // If `sessions()` silently returned [] on a dirty store (the
        // forbidden permissive default), the gate would report clean. This
        // passing test pins that blindness: enumeration is load-bearing,
        // which is why the protocol has NO default.
        let inner = InMemorySessionStore()
        try Self.seed(inner, session: "s-hidden", writer: "w", records: [
            Self.intent("eX/c1", call: "c1", mutating: true),
        ])
        #expect(try CrossRunGate.unresolvedHolds(store: inner).count == 1)
        let blind = BlindStore(inner: inner)
        #expect(try CrossRunGate.unresolvedHolds(store: blind).isEmpty,
                "empty enumeration hides real holds — the forbidden default would fail open")
    }

    @Test("B5-B COUNTERFACTUAL: naive clean check diverges from the gate")
    func counterfactualFalseClean() throws {
        // A naive "completed-only" check certifies a ledger the gate
        // holds: gate sensitivity to unmatched-mutating/unknown is the
        // difference under test.
        let store = InMemorySessionStore()
        try Self.seed(store, session: "s-naive", writer: "w", records: [
            Self.intent("eN/c1", call: "c1", mutating: true),
            Self.result("eN/c1", call: "c1", mutating: true, state: .done, outcome: "ok"),
            Self.intent("eN/c2", call: "c2", mutating: true),
        ])
        let (page, _) = try store.records(session: SessionID("s-naive"), since: 0, limit: 1000)
        let report = try reconcileOperations(page.map(\.record))
        #expect(!report.completed.isEmpty, "naive check sees completion")
        let holds = try CrossRunGate.unresolvedHolds(store: store)
        #expect(holds.count == 1, "gate still holds the unmatched mutating intent")
        #expect(holds[0].operationIDs.map(\.raw) == ["eN/c2"])
    }
}
