import Testing
import Foundation
import GRDB
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport

/// M2-D D2 durable-tier proofs over real GRDB: journal crash-boundary
/// recovery through the production `resumeSession` entry point, and export
/// projection of every D2 record shape (redaction-gated like all receipts).
/// Pure journal truth tables live in NeedletailStateTests/UndoTests.
struct UndoJournalTests {
    private static func tempStore() throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-j-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-undo-j")
        let writer = WriterIdentity(session: session, writer: "w-undo-j")
        try store.claimWriterOwnership(session: session, writer: "w-undo-j")
        return (dir, store, session, writer)
    }

    private static func epoch() throws -> EpochDescriptor {
        let configJSON = """
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M2_J_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
            """
        let snapshot = try validateConfig(Data(configJSON.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        return EpochDescriptor(
            epochID: EpochID("epoch-1"), parentEpochID: nil,
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
    }

    private static func member(_ path: String, seed: UInt64) -> ChangeGroupMember {
        ChangeGroupMember(
            operationID: OperationID("eff-1/c\(seed)"), callID: "c\(seed)",
            path: path, grantedRoot: "/tmp/ws",
            created: false, beforeHash: "before-\(seed)", afterHash: "after-\(seed)",
            deviceBefore: 100 + seed, inodeBefore: 200 + seed, modeBefore: "644",
            preimageDigest: "before-\(seed)", emptyOriginal: false,
            deviceAfter: 100 + seed, inodeAfter: 300 + seed, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "edited \(path)")
    }

    private static func records(_ store: GRDBSessionStore, _ session: SessionID) throws -> [DurableRecord] {
        let (page, _) = try store.records(session: session, since: 0, limit: 100_000)
        return page.map(\.record)
    }

    // MARK: - Crash boundaries through production resume

    @Test("UX-UNDO-05 crash boundary 2: intent without result reopens unknown and held, never replayed")
    func UX_UNDO_05_intentWithoutResultReopensUnknown() throws {
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let inverseID = "undo/undo-7/chg-3/eff-1/c1"
        try store.appendBatch([
            .operationIntent(OperationRef(
                operationID: OperationID(inverseID), callID: inverseID,
                state: .intent, mutating: true)),
        ], as: writer)
        var ids = DeterministicIDSource(prefix: "rj")
        let rebuilt = try resumeSession(
            store: store, session: session, epoch: try Self.epoch(),
            trustMode: .workspace, as: "w-undo-j", ids: &ids)
        #expect(rebuilt.queueHeld, "unsettled inverse holds the queue")
        #expect(rebuilt.unresolvedOperations.contains(where: {
            $0.operationID.raw == inverseID && $0.state == .unknown
        }), "intent-only inverse reseeds as unknown")
        #expect(rebuilt.undoDispositions.isEmpty, "no disposition without one recorded")
    }

    @Test("UX-UNDO-09 crash boundary 5/6: settled journal + disposition reseed; reopen replays nothing")
    func UX_UNDO_09_settledJournalReseeds() throws {
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let member = Self.member("a.txt", seed: 1)
        let group = ChangeGroup(
            groupID: "chg-1", runID: RunID("run-1"), effectID: EffectID("eff-1"),
            members: [member], hadExecProposals: false, hadReadProposals: false)
        let inverseID = undoInverseID(undoCommandID: "undo-1", groupID: group.groupID, operationID: member.operationID)
        let disposition = UndoDispositionRecord(
            undoCommandID: "undo-1", groupID: group.groupID, outcome: .completed,
            fileOutcomes: [UndoFileOutcome(
                inverseID: inverseID, path: "a.txt",
                result: "applied", detail: "restored a.txt",
                beforeHash: "before-1", afterHash: "after-1")],
            reason: "all 1 inverse(s) applied", atMillis: 9000)
        try store.appendBatch([
            .changeGroup(group),
            .operationIntent(OperationRef(
                operationID: OperationID(inverseID), callID: inverseID,
                state: .intent, mutating: true)),
            .operationResult(
                OperationRef(
                    operationID: OperationID(inverseID), callID: inverseID,
                    state: .done, mutating: true),
                outcome: "applied: restored a.txt"),
            .undoDisposition(disposition),
            .transcriptAppended(.workspaceChangeNotice(WorkspaceChangeNotice(
                undoCommandID: "undo-1", groupID: group.groupID,
                outcome: .completed,
                files: disposition.fileOutcomes,
                hadExecProposals: false, reason: "all 1 inverse(s) applied"))),
        ], as: writer)
        var ids = DeterministicIDSource(prefix: "rj")
        let rebuilt = try resumeSession(
            store: store, session: session, epoch: try Self.epoch(),
            trustMode: .workspace, as: "w-undo-j", ids: &ids)
        #expect(rebuilt.undoDispositions == [disposition], "durable disposition reseeds the live mirror")
        #expect(!rebuilt.queueHeld, "settled journal holds nothing")
        #expect(rebuilt.unresolvedOperations.isEmpty)
        #expect(reconcileChangeGroups(try Self.records(store, session)).map(\.groupID) == ["chg-1"], "group survives reopen (UX-UNDO-07 ledger leg)")
    }

    // MARK: - Export projection of every D2 shape

    @Test("export projects change groups, dispositions, forks and notices with redaction")
    func exportProjectsD2Shapes() throws {
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let member = Self.member("notes/plan.txt", seed: 1)
        let group = ChangeGroup(
            groupID: "chg-1", runID: RunID("run-1"), effectID: EffectID("eff-1"),
            members: [member], hadExecProposals: true, hadReadProposals: false)
        let notice = WorkspaceChangeNotice(
            undoCommandID: "undo-1", groupID: group.groupID,
            outcome: .completed, files: [UndoFileOutcome(
                inverseID: "i", path: "notes/plan.txt",
                result: "applied", detail: "restored SECRET-BYTES",
                beforeHash: String(repeating: "b", count: 64),
                afterHash: String(repeating: "a", count: 64))],
            hadExecProposals: true, reason: "all applied SECRET-REASON")
        try store.appendBatch([
            .sessionOpened(session: session, atMillis: 1000),
            .changeGroup(group),
            .undoDisposition(UndoDispositionRecord(
                undoCommandID: "undo-1", groupID: group.groupID,
                outcome: .completed, fileOutcomes: notice.files,
                reason: "all applied SECRET-REASON", atMillis: 2000)),
            .lineageFork(LineageFork(
                forkID: "fork-1", sessionID: session,
                parentEpochID: EpochID("epoch-1"),
                boundary: LineageBoundary(epochID: EpochID("epoch-1"), throughSequence: 4),
                divergenceNote: "history preserved; workspace NOT restored",
                atMillis: 3000)),
            .transcriptAppended(.workspaceChangeNotice(notice)),
        ], as: writer)
        for includeContent in [false, true] {
            let lines = try SessionExport.lines(
                dbPath: store.path, session: session,
                includeContent: includeContent, exportedAt: 9_999_999)
            let objects = try lines.compactMap { line -> [String: Any]? in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
            let kinds = Set(objects.compactMap { $0["kind"] as? String })
            #expect(kinds.contains("change-group"), "group projects (content=\(includeContent))")
            #expect(kinds.contains("undo-disposition"), "disposition projects (content=\(includeContent))")
            #expect(kinds.contains("lineage-fork"), "fork projects (content=\(includeContent))")
            let noticeRows = objects.filter { ($0["role"] as? String) == "notice" }
            #expect(noticeRows.count == 1, "notice projects as transcript (content=\(includeContent))")
            // Major 4: hashes are structural — present with AND without
            // content (only free-text reason/detail gate on content).
            let flat = lines.joined()
            #expect(flat.contains("\"afterHash\""), "after hashes project structurally")
            #expect(flat.contains("\"beforeHash\""), "before hashes project structurally")
            // Notice file rows carry the inverse journal key in both
            // modes; the per-file detail travels only with content.
            let noticeFiles = noticeRows.compactMap { $0["files"] as? [[String: Any]] }.flatMap { $0 }
            #expect(noticeFiles.count == 1, "notice projects exactly one file row (content=\(includeContent))")
            #expect(noticeFiles.allSatisfy({ ($0["operationID"] as? String) == "i" }), "inverse identity travels structurally")
            if includeContent {
                #expect(noticeFiles.contains(where: { ($0["detail"] as? String) == "restored SECRET-BYTES" }), "file detail travels with content")
            } else {
                #expect(!noticeFiles.contains(where: { $0["detail"] != nil }), "redacted exports carry no per-file detail")
            }
            let blob = lines.joined()
            if includeContent {
                #expect(blob.contains("SECRET-REASON"), "content mode carries the reason")
                #expect(blob.contains("SECRET-BYTES"), "content mode carries file details")
            } else {
                #expect(!blob.contains("SECRET-REASON") && !blob.contains("SECRET-BYTES"), "redacted mode drops free text")
                #expect(blob.contains("notes/plan.txt"), "paths stay structural without content")
            }
        }
    }

    // MARK: - Blocker 1: ambiguous inverse holds durably across reopen

    @Test("UX-UNDO-05 ambiguous inverse (unknown result) reopens held with a recovery marker and no disposition")
    func UX_UNDO_05_ambiguousResultReopensHeld() throws {
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let inverseID = "undo/undo-3/chg-1/eff-1/c1"
        try store.appendBatch([
            .operationIntent(OperationRef(
                operationID: OperationID(inverseID), callID: inverseID,
                state: .intent, mutating: true)),
            // Ambiguous outcome commits state .unknown (Blocker 1): a .done
            // result would pair complete and drop the hold on reopen.
            .operationResult(
                OperationRef(
                    operationID: OperationID(inverseID), callID: inverseID,
                    state: .unknown, mutating: true),
                outcome: "unknown: post-commit read failed"),
        ], as: writer)
        var ids = DeterministicIDSource(prefix: "rj")
        let rebuilt = try resumeSession(
            store: store, session: session, epoch: try Self.epoch(),
            trustMode: .workspace, as: "w-undo-j", ids: &ids)
        #expect(rebuilt.queueHeld, "ambiguous inverse holds the queue across reopen")
        #expect(rebuilt.unresolvedOperations.count == 1, "exactly one recovery marker (deduplicated), got \(rebuilt.unresolvedOperations)")
        #expect(rebuilt.unresolvedOperations.first?.operationID.raw == inverseID)
        #expect(rebuilt.undoDispositions.isEmpty, "no disposition invented by recovery")
        // And the journal still classifies it unknown (no silent settle).
        let (entries, unknowns) = reconcileUndoJournal(try Self.records(store, session))
        #expect(entries["undo-3"]?.disposition == nil)
        #expect(unknowns.count == 1 && unknowns[0].operationID.raw == inverseID)
    }

    @Test("UX-UNDO-05 pre-fix ambiguous rows (done + unknown: outcome) still reopen held")
    func UX_UNDO_05_preFixAmbiguousRowsReopenHeld() throws {
        // Compatibility (review delta): the parent commit recorded
        // ambiguous inverses as state .done with an "unknown:" outcome
        // string. The outcome string is durable unknowability evidence —
        // reopen must hold even though the state enum says done.
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let inverseID = "undo/undo-4/chg-1/eff-1/c1"
        let disposition = UndoDispositionRecord(
            undoCommandID: "undo-4", groupID: "chg-1",
            outcome: .needsReconciliation,
            fileOutcomes: [UndoFileOutcome(
                inverseID: inverseID, path: "a.txt",
                result: "unknown", detail: "failed (may have mutated)",
                beforeHash: "b0", afterHash: "a0")],
            reason: "inverse a.txt failed ambiguously", atMillis: 9000)
        try store.appendBatch([
            .operationIntent(OperationRef(
                operationID: OperationID(inverseID), callID: inverseID,
                state: .intent, mutating: true)),
            .operationResult(
                OperationRef(
                    operationID: OperationID(inverseID), callID: inverseID,
                    state: .done, mutating: true),
                outcome: "unknown: post-commit read failed"),
            .undoDisposition(disposition),
        ], as: writer)
        var ids = DeterministicIDSource(prefix: "rj")
        let rebuilt = try resumeSession(
            store: store, session: session, epoch: try Self.epoch(),
            trustMode: .workspace, as: "w-undo-j", ids: &ids)
        #expect(rebuilt.queueHeld, "pre-fix ambiguous journal holds the queue")
        #expect(rebuilt.unresolvedOperations.count == 1, "exactly one marker, got \(rebuilt.unresolvedOperations)")
        #expect(rebuilt.unresolvedOperations.first?.operationID.raw == inverseID)
        #expect(rebuilt.unresolvedOperations.first?.state == .unknown)
        #expect(rebuilt.undoDispositions == [disposition], "recorded disposition still reseeds")
        let (_, unknowns) = reconcileUndoJournal(try Self.records(store, session))
        #expect(unknowns.count == 1 && unknowns[0].operationID.raw == inverseID, "journal classifies done+unknown: as unknown")
    }
}
