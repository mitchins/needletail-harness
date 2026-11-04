import Testing
import Foundation
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime

/// M3 review closeout (out-of-diff Major on `Transcript.swift`): the
/// 1,024-record page limit must guard the SELECTED active tail after a
/// checkpoint publication — not the preserved full history. The ledger
/// keeps every pre-checkpoint record; only the model context is bounded.
///
/// RED pre-fix: `longHistoryWithCheckpointProjectsTail` throws
/// `pageOverflow` because the limit is enforced before the tail is
/// selected. GREEN post-fix: the full-history check runs only when no
/// checkpoint exists, and the tail check runs on the selected tail.
struct M3CProjectionLimitTests {

    private static func tempStore() throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3c-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-m3c-limit-\(UUID().uuidString.prefix(6))")
        let writer = WriterIdentity(session: session, writer: "w-m3c-limit")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        return (dir, store, session, writer)
    }

    private static func epoch() throws -> EpochDescriptor {
        let rawOptions = Data(#"{"temperature":0.2}"#.utf8)
        let profile = try ModelProfile(
            alias: "local-coder", wireProtocol: .openAIChatCompletions,
            baseURL: "http://127.0.0.1:11434", modelID: "qwen2.5-coder-32b",
            contextWindow: 262144, maxOutput: 4096, locality: .local,
            credential: nil, connectTimeout: 10, readIdleTimeout: 300,
            requestTimeout: 1800, maxInFlight: 1,
            requestOptions: ["temperature": .number(0.2)],
            requestOptionsRaw: rawOptions)
        let snapshot = ConfigSnapshot(
            version: 1, profiles: [profile.alias: profile],
            defaultAlias: profile.alias,
            allowHTTPOrigins: ["http://127.0.0.1:11434"],
            tools: .allDenied)
        let caps = EffectiveCapabilities(
            tools: .allDenied, route: .localOnly, deniedBy: ["build", "userConfig"])
        return EpochDescriptor(
            epochID: EpochID("epoch-new"), parentEpochID: EpochID("epoch-old"),
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: "local-coder"))
    }

    private static func transcriptSeqs(_ store: GRDBSessionStore, _ session: SessionID) throws -> [UInt64] {
        let (page, _) = try store.records(session: session, since: 0, limit: 100_000)
        return page.compactMap { sequenced in
            if case .transcriptAppended = sequenced.record { return sequenced.sequence.value }
            return nil
        }
    }

    @Test("M3-C: projection over >1,024 records with a checkpoint returns block + bounded tail")
    func longHistoryWithCheckpointProjectsTail() async throws {
        let (dirURL, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let total = 1100
        var batch: [DurableRecord] = []
        for i in 0..<total {
            batch.append(.transcriptAppended(.user("filler \(i): confirm nothing new.")))
            if batch.count == 275 {
                try store.appendBatch(batch, as: writer)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try store.appendBatch(batch, as: writer) }
        let seqs = try Self.transcriptSeqs(store, session)
        #expect(seqs.count == total, "all \(total) history records durable, got \(seqs.count)")
        // Bounded tail: last 40 transcript records (a completed group
        // boundary by construction of the fixture — user-only turns).
        let retainedFrom = seqs[total - 40]
        try store.appendBatch([.checkpointPublished(CheckpointPublication(
            epoch: try Self.epoch(),
            checkpointJSON: #"{"task_goal":"summarize the project state"}"#,
            pinnedConstraints: ["keep tests green"],
            retainedFromSeq: retainedFrom,
            boundarySequence: retainedFrom > 0 ? retainedFrom - 1 : 0))], as: writer)
        // RED pre-fix: this throws pageOverflow (limit enforced before the
        // tail is selected) even though the retained tail is bounded.
        let projected = try loadTranscriptProjection(from: store, session: session, limit: 1024)
        #expect(projected.count == 41, "checkpoint block + 40 tail messages, got \(projected.count)")
        let text = projected.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        #expect(text.contains("checkpoint context"), "checkpoint block present")
        #expect(text.contains("filler \(total - 1): confirm nothing new."), "retained tail preserved")
        #expect(!text.contains("filler 0: confirm nothing new."), "early history excluded from the new context")
        // Complete historical evidence preserved: the ledger still holds
        // every pre-checkpoint record plus the publication.
        let (all, _) = try store.records(session: session, since: 0, limit: 100_000)
        #expect(all.count == total + 1, "ledger intact (\(total) history + publication), got \(all.count)")
        // Continuation through the production request builder: the
        // projection feeds the exact body assembler the transport invokes.
        let body = try chatRequestBody(modelID: "probe", messages: projected, maxTokens: 16, options: [:])
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wireMessages = try #require(decoded["messages"] as? [[String: Any]])
        #expect(wireMessages.count == projected.count, "every projected message reaches the wire body")
        let firstText = (wireMessages.first?["content"] as? String) ?? ""
        #expect(firstText.contains("checkpoint context"), "checkpoint block is the first wire message")
    }

    @Test("M3-C: projection over >1,024 records WITHOUT a checkpoint still fails honest")
    func longHistoryWithoutCheckpointStillOverflows() async throws {
        let (dirURL, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        var batch: [DurableRecord] = []
        for i in 0..<1100 {
            batch.append(.transcriptAppended(.user("filler \(i)")))
            if batch.count == 275 {
                try store.appendBatch(batch, as: writer)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try store.appendBatch(batch, as: writer) }
        // No publication: the pre-checkpoint full-history limit stands.
        #expect(throws: TranscriptError.pageOverflow(limit: 1024)) {
            try loadTranscriptProjection(from: store, session: session, limit: 1024)
        }
    }

    @Test("M3-C: an oversized retained tail still fails honest after publication")
    func oversizedTailStillOverflows() async throws {
        let (dirURL, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        var batch: [DurableRecord] = []
        for i in 0..<1100 {
            batch.append(.transcriptAppended(.user("filler \(i)")))
            if batch.count == 275 {
                try store.appendBatch(batch, as: writer)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try store.appendBatch(batch, as: writer) }
        let seqs = try Self.transcriptSeqs(store, session)
        // Cut at the stream head: the selected tail (1,100) exceeds the page.
        try store.appendBatch([.checkpointPublished(CheckpointPublication(
            epoch: try Self.epoch(),
            checkpointJSON: #"{"task_goal":"summarize the project state"}"#,
            pinnedConstraints: ["keep tests green"],
            retainedFromSeq: seqs.first ?? 1,
            boundarySequence: 0))], as: writer)
        #expect(throws: TranscriptError.pageOverflow(limit: 1024)) {
            try loadTranscriptProjection(from: store, session: session, limit: 1024)
        }
    }
}
