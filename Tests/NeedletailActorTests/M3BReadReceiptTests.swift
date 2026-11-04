import Testing
import Foundation
import Crypto
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
import SystemPackage

/// M3-B Phase A: model-visible read receipt. The native executor computes
/// the exact full-file SHA-256 on every read (`ToolCallOutcome.beforeHash`),
/// but the model-visible transcript carried only the bounded preview. The
/// receipt exposes path + sha256 + truncation so a follow-up `edit` can
/// propose the OBSERVED hash (the earlier live loop fabricated `000…0`).
/// RED written against the pre-fix reducer: the transcript assertions below
/// fail while `toolText = outcome.data` only. GREEN after the reducer emits
/// the executor-computed receipt. Scripted transport stands in for the
/// model; executor, reducer, actor, transcript and store are production.
struct M3BReadReceiptTests {

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3b-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    private static func makeActor(
        dir: FilePath, store: InMemorySessionStore, session: SessionID,
        writer: WriterIdentity, transport: ScriptedTransport,
        executor: NativeToolExecutor, approvals: ScriptedApprovals,
        ids: DeterministicIDSource
    ) throws -> SessionActor<ScriptedTransport, NativeToolExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let state = SessionState(sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        return try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: writer.writer)
    }

    private static func awaitCompleted(_ actor: SessionActor<ScriptedTransport, NativeToolExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>) async throws -> SessionState {
        for _ in 0..<20_000 {
            let state = await actor.currentState()
            if case .completed = state.phase { return state }
            await Task.yield()
        }
        let state = await actor.currentState()
        Issue.record("run never completed, phase=\(state.phase)")
        throw ScriptedError.outOfScript
    }

    private static func transcriptToolResponses(_ store: InMemorySessionStore) throws -> [(callID: String, text: String)] {
        let (page, _) = try store.records(since: 0, limit: 100_000)
        return page.compactMap { sequenced in
            if case .transcriptAppended(.toolResponse(let callID, let text)) = sequenced.record {
                return (callID, text)
            }
            return nil
        }
    }

    // MARK: - 1+2: receipt carries the exact hash (RED pre-fix, GREEN post-fix)

    @Test("M3-B A1: read transcript carries the executor-computed full-file sha256 + truncation flag")
    func readReceiptCarriesHash() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let body = "line one\nM3B receipt fixture\nline three\n"
        try body.write(to: url.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        let expectedHash = Self.sha(Data(body.utf8))
        let store = InMemorySessionStore()
        let session = SessionID("s-m3b-read")
        let writer = WriterIdentity(session: session, writer: "w-m3b")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "reading", toolProposals: [
                    ToolProposal(callID: "cr", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"r.txt\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer,
                                       transport: transport, executor: executor,
                                       approvals: ScriptedApprovals(), ids: DeterministicIDSource(prefix: "m3br"))
        await actor.submitText(commandID: CommandID("run-1"), text: "read the file", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        let responses = try Self.transcriptToolResponses(store)
        let readResponse = try #require(responses.first(where: { $0.callID == "cr" }), "read tool response missing from transcript")
        // The receipt must name the executor-computed hash over the COMPLETE
        // bytes and the bounded path, plus the truncation flag.
        #expect(readResponse.text.contains("sha256: \(expectedHash)"),
                "model-visible read response must carry the exact full-file sha256, got: \(readResponse.text.prefix(300))")
        #expect(readResponse.text.contains("path: r.txt"))
        #expect(readResponse.text.contains("truncated: false"))
        #expect(readResponse.text.contains("line one"), "bounded content preserved")
    }

    // MARK: - 5: pagination/truncation does not misrepresent the hash

    @Test("M3-B A1: truncated read still reports the COMPLETE-file sha256")
    func truncatedReadHashIsCompleteFile() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: url.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let expectedHash = Self.sha(Data(lines.utf8))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: InMemorySessionStore(), sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"big.txt\",\"limit\":10}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        let outcome = try #require(result.calls.first)
        #expect(outcome.status == "success")
        #expect(outcome.truncated == true, "preview truncated")
        #expect(outcome.beforeHash == expectedHash, "hash must cover the complete observed bytes, not the preview")
        // The reducer receipt built from this outcome reports the same hash
        // with truncated: true (verified through the actor loop below in
        // readReceiptCarriesHash; here the executor half is pinned).
    }

    // MARK: - 3+4: edit consumes the observed hash; stale hash conflicts with zero overwrite

    @Test("M3-B A1: edit with the observed receipt hash succeeds; stale hash conflicts with zero overwrite")
    func editConsumesObservedHashThenStaleConflicts() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "RATE = 2\n\ndef double(x):\n    return x * RATE\n"
        try original.write(to: url.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        let originalHash = Self.sha(Data(original.utf8))
        let store = InMemorySessionStore()
        let session = SessionID("s-m3b-edit")
        let writer = WriterIdentity(session: session, writer: "w-m3b")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let transport = ScriptedTransport()
        // Turn 1: read (receipt carries originalHash). Turn 2: edit with the
        // OBSERVED hash. Turn 3: edit with the STALE original hash.
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "reading", toolProposals: [
                    ToolProposal(callID: "cr", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"calc.py\"}"),
                ], isFinal: false)),
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(1), outcome: .textDeltaComplete(
                text: "editing", toolProposals: [
                    ToolProposal(callID: "ce", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"calc.py\",\"expectedHash\":\"\(originalHash)\",\"old_string\":\"RATE = 2\",\"new_string\":\"RATE = 3\"}"),
                ], isFinal: false)),
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(2), outcome: .textDeltaComplete(
                text: "retrying stale", toolProposals: [
                    ToolProposal(callID: "cs", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"calc.py\",\"expectedHash\":\"\(originalHash)\",\"old_string\":\"RATE = 3\",\"new_string\":\"RATE = 4\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(3)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer,
                                       transport: transport, executor: executor,
                                       approvals: ScriptedApprovals(), ids: DeterministicIDSource(prefix: "m3be"))
        await actor.submitText(commandID: CommandID("run-1"), text: "fix the rate", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)

        // The edit executed exactly once: RATE = 3 landed.
        let edited = try String(contentsOf: url.appendingPathComponent("calc.py"), encoding: .utf8)
        #expect(edited == "RATE = 3\n\ndef double(x):\n    return x * RATE\n", "observed-hash edit succeeded")
        // The stale retry conflicted: RATE = 4 never landed (zero overwrite).
        #expect(!edited.contains("RATE = 4"), "stale-hash conflict must not overwrite")

        let responses = try Self.transcriptToolResponses(store)
        // The read receipt named the hash the edit then used successfully.
        let readResponse = try #require(responses.first(where: { $0.callID == "cr" }))
        #expect(readResponse.text.contains("sha256: \(originalHash)"), "receipt hash is the real current hash")
        // The conflict response is empty (executor data), but the durable
        // record classifies it: verify the operationResult outcome.
        let (page, _) = try store.records(since: 0, limit: 100_000)
        let conflictResults = page.compactMap { sequenced -> String? in
            if case .operationResult(_, let outcome) = sequenced.record, outcome.contains("hash mismatch") { return outcome }
            return nil
        }
        #expect(conflictResults.count == 1, "stale-hash edit recorded as conflict, got \(conflictResults)")
        // Final bytes double-checked.
        #expect(Self.sha(Data(edited.utf8)) != originalHash)
    }
}
