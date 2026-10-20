import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime

/// A3-3 authorized ownership recovery over two independent GRDB handles.
/// The old writer's handle stays OPEN across the takeover (unexpected
/// resume); the recovery handle performs the guarded atomic swap; fresh
/// handles verify durability. Fencing, audit evidence, hold preservation
/// and rollback are asserted through the production store — never a
/// generic lock service.
struct WriterRecoveryTests {

    private static func freshPath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("store.sqlite").path)
    }

    private static func auth(
        session: SessionID, expected: String = "w-old", new: String = "w-new",
        operatorID: String = "op-1", reference: String = "ticket-7",
        reason: String = "shift handover", atMillis: UInt64 = 9_000
    ) -> RecoveryAuthorization {
        RecoveryAuthorization(
            session: session, expectedWriter: expected, newWriter: new,
            operatorID: operatorID, reference: reference, reason: reason, atMillis: atMillis)
    }

    private static func toolIntent(_ id: String, call: String, mutating: Bool) -> DurableRecord {
        .operationIntent(OperationRef(
            operationID: OperationID(id), callID: call, state: .intent, mutating: mutating))
    }

    private static func toolResult(_ id: String, call: String, mutating: Bool, outcome: String) -> DurableRecord {
        .operationResult(OperationRef(
            operationID: OperationID(id), callID: call, state: .done, mutating: mutating), outcome: outcome)
    }

    @Test("A3-3 authorized takeover swaps ownership with a durable audit")
    func authorizedTakeoverSwapsOwnershipWithAudit() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-takeover")
        // Old writer live, handle stays OPEN (unexpected resume later).
        let oldHandle = try GRDBSessionStore(path: path)
        try oldHandle.claimWriterOwnership(session: session, writer: "w-old")
        try oldHandle.append(Self.toolIntent("e1/c1", call: "c1", mutating: true),
                             as: WriterIdentity(session: session, writer: "w-old"))
        // New writer cannot append before the takeover commits.
        let newHandle = try GRDBSessionStore(path: path)
        #expect(throws: StoreError.notWriter(session: "s-takeover", writer: "w-new")) {
            try newHandle.append(.transcriptAppended(.user("early")),
                                 as: WriterIdentity(session: session, writer: "w-new"))
        }
        // Authorized takeover on the second handle.
        try newHandle.recoverWriterOwnership(
            session: session, expectedWriter: "w-old", newWriter: "w-new",
            authorization: Self.auth(session: session))
        // New writer appends (no re-claim needed — the row says w-new)…
        try newHandle.append(.transcriptAppended(.user("post-takeover")),
                             as: WriterIdentity(session: session, writer: "w-new"))
        // …and a third handle re-claims idempotently, proving durability.
        let thirdHandle = try GRDBSessionStore(path: path)
        try thirdHandle.claimWriterOwnership(session: session, writer: "w-new")
        try thirdHandle.append(.transcriptAppended(.user("third")),
                               as: WriterIdentity(session: session, writer: "w-new"))
        // The audit row was committed AT the takeover; later appends follow
        // it. Exactly one audit row exists, fully reconstructible.
        let (page, _) = try thirdHandle.records(session: session, since: 0, limit: 100)
        let audits = page.compactMap { sequenced -> WriterRecovery? in
            if case .writerRecovered(let audit) = sequenced.record { return audit }
            return nil
        }
        guard audits.count == 1, let audit = audits.first else {
            Issue.record("takeover must commit exactly one writerRecovered audit row")
            return
        }
        #expect(audit.previousWriter == "w-old")
        #expect(audit.newWriter == "w-new")
        #expect(audit.operatorID == "op-1" && audit.reference == "ticket-7")
        #expect(audit.reason == "shift handover" && audit.atMillis == 9_000)
        #expect(audit.unresolvedOperations.map(\.operationID) == [OperationID("e1/c1")],
                "intent-only crash preserved as held evidence")
        try oldHandle.close()
        try newHandle.close()
        try thirdHandle.close()
    }

    @Test("A3-3 old writer fails closed on every mutation after takeover")
    func oldWriterFailsClosedAfterTakeover() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-stale")
        let oldHandle = try GRDBSessionStore(path: path)
        try oldHandle.claimWriterOwnership(session: session, writer: "w-old")
        let recoveryHandle = try GRDBSessionStore(path: path)
        try recoveryHandle.recoverWriterOwnership(
            session: session, expectedWriter: "w-old", newWriter: "w-new",
            authorization: Self.auth(session: session))
        // The old handle never closed — its unexpected resume fails on
        // single append, batch append AND release.
        #expect(throws: StoreError.notWriter(session: "s-stale", writer: "w-old")) {
            try oldHandle.append(.transcriptAppended(.user("stale")),
                                 as: WriterIdentity(session: session, writer: "w-old"))
        }
        #expect(throws: StoreError.notWriter(session: "s-stale", writer: "w-old")) {
            try oldHandle.appendBatch([.transcriptAppended(.user("stale-batch"))],
                                      as: WriterIdentity(session: session, writer: "w-old"))
        }
        #expect(throws: StoreError.notWriter(session: "s-stale", writer: "w-old")) {
            try oldHandle.releaseWriterOwnership(session: session, writer: "w-old")
        }
        // And the old identity can never re-claim over the new owner.
        #expect(throws: StoreError.alreadyOwned(session: "s-stale", writer: "w-new")) {
            try oldHandle.claimWriterOwnership(session: session, writer: "w-old")
        }
        try oldHandle.close()
        try recoveryHandle.close()
    }

    @Test("A3-3 stale expected owners and duplicate replays fail closed")
    func staleExpectedAndDuplicateReplayFailClosed() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-stale-exp")
        let first = try GRDBSessionStore(path: path)
        try first.claimWriterOwnership(session: session, writer: "w-old")
        let second = try GRDBSessionStore(path: path)
        // Competing recovery with a stale expected owner loses, learning
        // the actual holder.
        #expect(throws: StoreError.alreadyOwned(session: "s-stale-exp", writer: "w-old")) {
            try second.recoverWriterOwnership(
                session: session, expectedWriter: "w-ghost", newWriter: "w-sneak",
                authorization: Self.auth(session: session, expected: "w-ghost", new: "w-sneak"))
        }
        // The legitimate takeover commits…
        try first.recoverWriterOwnership(
            session: session, expectedWriter: "w-old", newWriter: "w-new",
            authorization: Self.auth(session: session))
        // …and replaying the same (now stale) authorization fails closed —
        // recovery is not idempotent, and names the current holder.
        #expect(throws: StoreError.alreadyOwned(session: "s-stale-exp", writer: "w-new")) {
            try second.recoverWriterOwnership(
                session: session, expectedWriter: "w-old", newWriter: "w-new",
                authorization: Self.auth(session: session))
        }
        // A competing second takeover with a FRESH expected owner is a new
        // authorized transition, not a replay — it commits.
        try second.recoverWriterOwnership(
            session: session, expectedWriter: "w-new", newWriter: "w-next",
            authorization: Self.auth(session: session, expected: "w-new", new: "w-next",
                                     reference: "ticket-8"))
        let (page, _) = try second.records(session: session, since: 0, limit: 100)
        let audits = page.compactMap { sequenced -> WriterRecovery? in
            if case .writerRecovered(let audit) = sequenced.record { return audit }
            return nil
        }
        #expect(audits.map(\.newWriter) == ["w-new", "w-next"], "both takeovers audited in order")
        try first.close()
        try second.close()
    }

    @Test("A3-3 unauthorized and malformed authorizations fail closed")
    func unauthorizedAuthorizationsFailClosed() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-auth")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-old")
        // An arbitrary boolean cannot exist here by construction — the API
        // takes no Bool. Every unverified/malformed proof fails closed:
        let badProofs: [RecoveryAuthorization] = [
            // No operator identity.
            Self.auth(session: session, operatorID: ""),
            // No authorization reference.
            Self.auth(session: session, reference: ""),
            // No human reason.
            Self.auth(session: session, reason: ""),
            // Scope mismatch: proof authorizes another session.
            Self.auth(session: SessionID("s-other")),
            // Scope mismatch: proof names another expected writer.
            Self.auth(session: session, expected: "w-ghost"),
            // Scope mismatch: proof names another new writer.
            Self.auth(session: session, new: "w-sneak"),
        ]
        for proof in badProofs {
            #expect(throws: StoreError.self) {
                try store.recoverWriterOwnership(
                    session: session, expectedWriter: "w-old", newWriter: "w-new",
                    authorization: proof)
            }
        }
        // Same-identity "takeover" is meaningless — fail closed.
        #expect(throws: StoreError.self) {
            try store.recoverWriterOwnership(
                session: session, expectedWriter: "w-old", newWriter: "w-old",
                authorization: Self.auth(session: session, new: "w-old"))
        }
        // Empty writer identities fail closed.
        #expect(throws: StoreError.self) {
            try store.recoverWriterOwnership(
                session: session, expectedWriter: "", newWriter: "w-new",
                authorization: Self.auth(session: session, expected: ""))
        }
        // Nothing moved: the holder is still w-old, no audit row exists.
        #expect(throws: StoreError.notWriter(session: "s-auth", writer: "w-new")) {
            try store.append(.transcriptAppended(.user("nope")),
                             as: WriterIdentity(session: session, writer: "w-new"))
        }
        let (page, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(!page.contains { if case .writerRecovered = $0.record { return true }; return false },
                "no audit row without an authorized takeover")
        try store.close()
    }

    @Test("A3-3 invalid ledger prevents recovery with full rollback")
    func invalidLedgerPreventsRecovery() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-corrupt")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-old")
        // Corrupt ledger: duplicate intents for one operation.
        try store.appendBatch([
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
        ], as: WriterIdentity(session: session, writer: "w-old"))
        let (beforeRows, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(throws: StoreError.self) {
            try store.recoverWriterOwnership(
                session: session, expectedWriter: "w-old", newWriter: "w-new",
                authorization: Self.auth(session: session))
        }
        // Full rollback: holder unchanged, no audit row, no extra rows.
        #expect(throws: StoreError.notWriter(session: "s-corrupt", writer: "w-new")) {
            try store.append(.transcriptAppended(.user("nope")),
                             as: WriterIdentity(session: session, writer: "w-new"))
        }
        let (afterRows, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(afterRows.map(\.record) == beforeRows.map(\.record), "failed takeover leaves the ledger byte-identical")
        #expect(!afterRows.contains { if case .writerRecovered = $0.record { return true }; return false })
        try store.close()
    }

    @Test("A3-3 exhausted quotas roll back the complete takeover")
    func exhaustedQuotasRollBackTakeover() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Session quota: the audit row would breach it.
        let session = SessionID("s-quota")
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("quota.sqlite").path,
            sessionRecordLimit: 2, globalRecordLimit: 100_000)
        try store.claimWriterOwnership(session: session, writer: "w-old")
        try store.appendBatch([
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            .transcriptAppended(.user("fill")),
        ], as: WriterIdentity(session: session, writer: "w-old"))
        #expect(throws: StoreError.quotaExceeded(limit: 2)) {
            try store.recoverWriterOwnership(
                session: session, expectedWriter: "w-old", newWriter: "w-new",
                authorization: Self.auth(session: session))
        }
        #expect(throws: StoreError.notWriter(session: "s-quota", writer: "w-new")) {
            try store.append(.transcriptAppended(.user("nope")),
                             as: WriterIdentity(session: session, writer: "w-new"))
        }
        let (page, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(page.count == 2, "failed takeover adds no rows")
        try store.close()
        // Global quota: rows across sessions already saturate it.
        let gstore = try GRDBSessionStore(
            path: directory.appendingPathComponent("gquota.sqlite").path,
            sessionRecordLimit: 100_000, globalRecordLimit: 2)
        let ga = SessionID("s-g-a"), gb = SessionID("s-g-b")
        try gstore.claimWriterOwnership(session: ga, writer: "w-old")
        try gstore.claimWriterOwnership(session: gb, writer: "w-other")
        try gstore.append(.transcriptAppended(.user("a")),
                          as: WriterIdentity(session: ga, writer: "w-old"))
        try gstore.append(.transcriptAppended(.user("b")),
                          as: WriterIdentity(session: gb, writer: "w-other"))
        #expect(throws: StoreError.quotaExceeded(limit: 2)) {
            try gstore.recoverWriterOwnership(
                session: ga, expectedWriter: "w-old", newWriter: "w-new",
                authorization: Self.auth(session: ga))
        }
        let (gpage, _) = try gstore.records(session: ga, since: 0, limit: 100)
        #expect(!gpage.contains { if case .writerRecovered = $0.record { return true }; return false })
        try gstore.close()
    }

    @Test("A3-3 recovery preserves every unresolved hold and resumes blocked")
    func recoveryPreservesHolds() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-holds")
        let oldHandle = try GRDBSessionStore(path: path)
        try oldHandle.claimWriterOwnership(session: session, writer: "w-old")
        try oldHandle.appendBatch([
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: true, outcome: "ok"),
            Self.toolIntent("e1/c2", call: "c2", mutating: true),
            Self.toolIntent("e1/c3", call: "c3", mutating: false),
        ], as: WriterIdentity(session: session, writer: "w-old"))
        let before = try oldHandle.reconcile(session: session)
        #expect(before.completed == [OperationID("e1/c1")])
        #expect(before.heldOperations.map(\.operationID) == [OperationID("e1/c2")])
        let recoveryHandle = try GRDBSessionStore(path: path)
        try recoveryHandle.recoverWriterOwnership(
            session: session, expectedWriter: "w-old", newWriter: "w-new",
            authorization: Self.auth(session: session))
        // Reconcile after takeover on a fresh handle: identical holds —
        // recovery establishes NOTHING about external operations.
        let freshHandle = try GRDBSessionStore(path: path)
        let after = try freshHandle.reconcile(session: session)
        #expect(after.completed == before.completed)
        #expect(after.heldOperations == before.heldOperations, "holds survive the takeover byte-identical")
        #expect(after.unmatchedNonMutating == [OperationID("e1/c3")])
        try oldHandle.close()
        try recoveryHandle.close()
        try freshHandle.close()
    }
}
