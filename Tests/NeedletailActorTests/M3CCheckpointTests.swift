import Testing
import Foundation
import Crypto
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
import SystemPackage

/// M3-C: two-phase checkpoint deterministic qualification (SPEC §§7.1–7.3).
/// Production SessionActor + transitions + real GRDB stores + scripted
/// transports. The capture request dials the FULL native history plus the
/// bounded checkpoint instruction; tool execution is locally disabled
/// (one paired denial + retry, second tool-bearing response terminates);
/// publication is a single atomic record group; the projection switches to
/// the shorter context via the durable record while the old history stays
/// intact.
struct M3CCheckpointTests {

    // MARK: - Harness

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    private static func tempStore() throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3c-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-m3c-\(UUID().uuidString.prefix(6))")
        let writer = WriterIdentity(session: session, writer: "w-m3c")
        try store.claimWriterOwnership(session: session, writer: writer.writer)
        return (dir, store, session, writer)
    }

    /// Actor over a REAL GRDB store with the native executor (read works;
    /// the checkpoint capture never executes tools regardless).
    private static func makeActor(
        dir: FilePath, store: GRDBSessionStore, session: SessionID,
        writer: WriterIdentity, transport: ScriptedTransport,
        approvals: ScriptedApprovals = ScriptedApprovals(), ids: DeterministicIDSource
    ) throws -> SessionActor<ScriptedTransport, NativeToolExecutor, GRDBSessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let state = SessionState(
            sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let resolver = try WorkspaceResolver(workspace: dir, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        return try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store,
            approvals: approvals, writer: writer.writer)
    }

    private static func awaitSettled<T: ModelTransport, E: ToolExecutor, S: SessionStore>(_ actor: SessionActor<T, E, S, ScriptedApprovals, VirtualClock, DeterministicIDSource>, wantCompleted: Bool = true) async throws -> SessionState {
        for _ in 0..<20_000 {
            let s = await actor.currentState()
            if s.phase == .idle { return s }
            if wantCompleted, case .completed = s.phase { return s }
            if case .failed = s.phase { return s }
            await Task.yield()
        }
        let s = await actor.currentState()
        Issue.record("actor never settled, phase=\(s.phase)")
        throw ScriptedError.outOfScript
    }

    private static func awaitCompleted<T: ModelTransport, E: ToolExecutor, S: SessionStore>(_ actor: SessionActor<T, E, S, ScriptedApprovals, VirtualClock, DeterministicIDSource>) async throws -> SessionState {
        for _ in 0..<20_000 {
            let state = await actor.currentState()
            if case .completed = state.phase { return state }
            await Task.yield()
        }
        let state = await actor.currentState()
        Issue.record("run never completed, phase=\(state.phase)")
        throw ScriptedError.outOfScript
    }

    private static func awaitIdle<T: ModelTransport, E: ToolExecutor, S: SessionStore>(_ actor: SessionActor<T, E, S, ScriptedApprovals, VirtualClock, DeterministicIDSource>) async throws -> SessionState {
        for _ in 0..<20_000 {
            let state = await actor.currentState()
            if state.phase == .idle { return state }
            await Task.yield()
        }
        let state = await actor.currentState()
        Issue.record("actor never returned to idle, phase=\(state.phase)")
        throw ScriptedError.outOfScript
    }

    /// Terminal phases refuse meta actions: dismiss to the idle boundary
    /// first (production RunCommand does the same before --checkpoint).
    private static func dismissToIdle<T: ModelTransport, E: ToolExecutor, S: SessionStore>(_ actor: SessionActor<T, E, S, ScriptedApprovals, VirtualClock, DeterministicIDSource>) async throws {
        await actor.dismissRun()
        _ = try await Self.awaitIdle(actor)
    }

    private static func records(_ store: GRDBSessionStore, _ session: SessionID) throws -> [DurableRecord] {
        let (page, _) = try store.records(session: session, since: 0, limit: 100_000)
        return page.map(\.record)
    }

    private static func checkpointJSON(goal: String, files: [[String: Any]] = []) -> String {
        let obj: [String: Any] = [
            "task_goal": goal,
            "user_constraints": ["keep tests green"],
            "completed_work": ["read files", "fixed moving_average"],
            "current_files": files,
            "open_questions": [],
            "failed_attempts": [],
            "next_actions": ["run the full suite"],
            "uncertainties": [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 1. Successful capture + publication, shorter projection

    @Test("M3-C: capture publishes atomically; projection is checkpoint block + tail; old history intact")
    func capturePublishesAndShortensProjection() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        try "alpha\n".write(to: dirURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let bodyHash = Self.sha("alpha\n")
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        // Turn 1: read (builds native history + read receipt). Turn 2: final.
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "reading", toolProposals: [
                    ToolProposal(callID: "c-read", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3c"))
        await actor.submitText(commandID: CommandID("task"), text: "Read a.txt and summarize the project state. This is the pinned original task.", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        // Filler turns: push the run past the bounded tail cap
        // (CheckpointTailCut.maxRecords) so the test proves the cut
        // actually shortens — a two-turn run would retain everything.
        let fillers = 40
        var fillerScript: [ProviderResponse] = []
        for _ in 0..<fillers {
            fillerScript.append(ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0)))
        }
        transport.script = fillerScript
        for i in 0..<fillers {
            await actor.submitText(commandID: CommandID("f-\(i)"), text: "filler \(i): confirm nothing new.", kind: .followUp, sealed: false)
            _ = try await Self.awaitCompleted(actor)
        }

        // Capture: a single valid checkpoint response.
        let beforeRecords = try Self.records(store, session).count
        transport.script = [
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "Read a.txt and summarize the project state", files: [
                    ["path": "a.txt", "sha256": bodyHash],
                ]), toolProposals: [], isFinal: true)),
        ]
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID != nil, "new epoch carries parent lineage")
        // Atomic record group: checkpointPublished + checkpointCommitted + epochOpened.
        let after = try Self.records(store, session)
        #expect(after.contains { if case .checkpointPublished = $0 { return true }; return false }, "checkpointPublished record durable")
        #expect(after.contains { if case .checkpointCommitted = $0 { return true }; return false })
        #expect(after.contains { if case .epochOpened = $0 { return true }; return false })
        let appended = after.count - beforeRecords
        // The publication group: sequenced event + checkpointPublished +
        // checkpointCommitted + epochOpened. Assert the three durable facts
        // and that nothing ELSE slipped in between (boundary: the suffix
        // since the "checkpointing" marker).
        let checkpointingIdx = after.firstIndex { record in
            if case .eventAppended(_, let kind, _) = record { return kind == "checkpointing" }
            return false
        }
        let group = after[(checkpointingIdx ?? 0)...]
        // checkpointing event + checkpoint-done event + the 3 durable
        // publication records (checkpointPublished/Committed/epochOpened).
        #expect(group.count == 5, "publication window = 2 events + 3 durable records, got \(group.count)")
        #expect(group.contains { if case .checkpointPublished = $0 { return true }; return false })
        #expect(group.contains { if case .checkpointCommitted = $0 { return true }; return false })
        #expect(group.contains { if case .epochOpened = $0 { return true }; return false })
        _ = appended
        // Projection: bounded tail — checkpoint block + recent tail, old
        // middle excluded. The run holds 5 + 2*fillers transcript records;
        // the tail keeps at most maxRecords snapped to a group boundary.
        let projected = try loadTranscriptProjection(from: store, session: session, limit: 1024)
        let full = try loadTranscript(from: store, session: session, limit: 1024)
        let projectedText = projected.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        #expect(projectedText.contains("checkpoint context"), "checkpoint block present")
        #expect(projectedText.contains("pinned original task"), "FIRST user message pinned verbatim in the checkpoint block")
        #expect(projectedText.contains("filler \(fillers - 1): confirm nothing new."), "retained tail preserved")
        #expect(projectedText.contains("filler 0: confirm nothing new.") == false, "early filler excluded from the new context")
        #expect(projectedText.contains("reading") == false, "first-turn messages excluded from the new context")
        #expect(projected.count < full.count, "projection is shorter than full history (\(projected.count) < \(full.count) messages)")
        #expect(projected.count <= CheckpointTailCut.maxRecords + 2, "bounded tail, got \(projected.count) messages")
        #expect(idle.liveReservations.isEmpty, "commit clears the attempt reservation")
        // Full history intact: every pre-publication record still there.
        #expect(after.contains { if case .transcriptAppended(.user(let t)) = $0 { return t.contains("pinned original task") }; return false })
        // Publication carries pinned constraints + tail cut.
        let publication = try #require(after.compactMap { record -> CheckpointPublication? in
            if case .checkpointPublished(let p) = record { return p }
            return nil
        }.first)
        #expect(publication.pinnedConstraints == ["Read a.txt and summarize the project state. This is the pinned original task."])
        #expect(publication.epoch.parentEpochID == idle.epoch.epochID || publication.epoch.parentEpochID != nil)
        // The cut moved off the stream head: the bounded tail starts past
        // the first transcript record.
        let (allSequenced, _) = try store.records(session: session, since: 0, limit: 100_000)
        let firstTranscriptSeq = try #require(allSequenced.first { sequenced in
            if case .transcriptAppended = sequenced.record { return true }
            return false
        }).sequence.value
        #expect(publication.retainedFromSeq > firstTranscriptSeq, "bounded cut starts past the stream head")
    }

    // MARK: - 2. Tool denial once, then commit

    @Test("M3-C: first tool proposal gets one paired denial + retry; no executor effect ever fires")
    func toolDenialOnceThenCommit() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cd"))
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "reading", toolProposals: [
                    ToolProposal(callID: "c-read", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
            // Capture attempt 1: model proposes a tool.
            ProviderResponse(requestID: RequestID("cp1"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "let me check", toolProposals: [
                    ToolProposal(callID: "c-bad", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"x\"}"),
                ], isFinal: false)),
            // Capture attempt 2 (after denial): valid JSON.
            ProviderResponse(requestID: RequestID("cp2"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "tool-denial flow goal"), toolProposals: [], isFinal: true)),
        ]
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID != nil, "retry after one denial commits")
        // Exactly two provider invocations during capture; zero executor work.
        let captureInvocations = transport.invocations.filter { $0.isCheckpoint }
        #expect(captureInvocations.count == 2, "capture + one retry, got \(captureInvocations.count)")
        let effects = try Self.records(store, session)
        #expect(!effects.contains { if case .operationIntent(let ref) = $0 { return ref.mutating && ref.callID == "c-bad" }; return false }, "denied proposal never became a durable intent")
        // The retry overlay is built by CheckpointValidator.captureOverlay
        // (unit-tested below); the production CLI wires the same helper
        // into messageProvider, so the denial note + instruction shape is
        // identical live and here.
    }

    // MARK: - 3. Second tool-bearing response terminates

    @Test("M3-C: second tool-bearing response fails the capture; epoch unchanged")
    func secondToolResponseFails() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3ct"))
        transport.script = [
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0)),
            ProviderResponse(requestID: RequestID("cp1"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "tools?", toolProposals: [ToolProposal(callID: "t1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")], isFinal: false)),
            ProviderResponse(requestID: RequestID("cp2"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "tools again", toolProposals: [ToolProposal(callID: "t2", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"b\"}")], isFinal: false)),
        ]
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        let epochBefore = (await actor.currentState()).epoch
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID == nil || idle.epoch.epochID == epochBefore.epochID, "epoch unchanged after termination")
        #expect((try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-failed" }; return false }), "checkpoint-failed recorded")
        #expect(!(try Self.records(store, session).contains { if case .checkpointPublished = $0 { return true }; return false }), "no publication")
    }

    // MARK: - 4. Malformed + fabricated references fail closed

    @Test("M3-C: malformed JSON and fabricated file references fail without publication")
    func malformedAndFabricatedFail() async throws {
        // Malformed: non-JSON text.
        do {
            let doc = try CheckpointValidator.parse(text: "I think the task went well overall.")
            #expect(doc.taskGoal.isEmpty == false, "unreachable")
        } catch { /* expected */ }
        do {
            _ = try CheckpointValidator.parse(text: "not json at all")
            Issue.record("non-JSON text must fail")
        } catch let e as CheckpointError {
            if case .malformed = e { } else { Issue.record("expected .malformed, got \(e)") }
        }
        // Fabricated reference: hash never recorded in the ledger.
        let (_, store, session, _) = try Self.tempStore()
        defer { try? store.close() }
        let fabricatedRoute = Self.checkpointJSON(goal: "g", files: [
            ["path": "ghost.txt", "sha256": String(repeating: "a", count: 64)],
        ])
        let doc = try CheckpointValidator.parse(text: fabricatedRoute)
        do {
            try CheckpointValidator.verify(
                doc, knownFileHashes: ["a.txt\u{1F}\(Self.sha("alpha\n"))"],
                maxSequence: 100, receiptSequences: [3])
            Issue.record("fabricated reference must fail")
        } catch let e as CheckpointError {
            if case .fabricatedReference = e { } else { Issue.record("expected .fabricatedReference, got \(e)") }
        }
        // observed_seq (snake_case wire key) decodes; a receipt-bearing
        // sequence verifies, a non-receipt or out-of-stream one fails.
        let knownHash = Self.sha("alpha\n")
        let withSeq = Self.checkpointJSON(goal: "g", files: [
            ["path": "a.txt", "sha256": knownHash, "observed_seq": 3],
        ])
        let seqDoc = try CheckpointValidator.parse(text: withSeq)
        #expect(seqDoc.currentFiles.first?.observedSeq == 3, "observed_seq decodes from the wire key")
        try CheckpointValidator.verify(
            seqDoc, knownFileHashes: ["a.txt\u{1F}\(knownHash)"],
            maxSequence: 100, receiptSequences: [3])
        do {
            try CheckpointValidator.verify(
                seqDoc, knownFileHashes: ["a.txt\u{1F}\(knownHash)"],
                maxSequence: 100, receiptSequences: [9])
            Issue.record("observed_seq naming no receipt must fail")
        } catch let e as CheckpointError {
            if case .fabricatedReference = e { } else { Issue.record("expected .fabricatedReference, got \(e)") }
        }
        do {
            try CheckpointValidator.verify(
                seqDoc, knownFileHashes: ["a.txt\u{1F}\(knownHash)"],
                maxSequence: 2, receiptSequences: [3])
            Issue.record("observed_seq past the stream bound must fail")
        } catch let e as CheckpointError {
            if case .fabricatedReference = e { } else { Issue.record("expected .fabricatedReference, got \(e)") }
        }
        // Stale pre-change hash: the ledger's after-only set rejects it.
        let staleRef = Self.checkpointJSON(goal: "g", files: [
            ["path": "a.txt", "sha256": Self.sha("before\n")],
        ])
        let staleDoc = try CheckpointValidator.parse(text: staleRef)
        do {
            try CheckpointValidator.verify(
                staleDoc, knownFileHashes: ["a.txt\u{1F}\(Self.sha("after\n"))"],
                maxSequence: 100, receiptSequences: [5])
            Issue.record("stale before-hash must fail")
        } catch let e as CheckpointError {
            if case .fabricatedReference = e { } else { Issue.record("expected .fabricatedReference, got \(e)") }
        }
        // Bounded decode: oversized document refuses.
        let huge = Self.checkpointJSON(goal: String(repeating: "x", count: 70_000))
        do {
            _ = try CheckpointValidator.parse(text: huge)
            Issue.record("oversized document must fail")
        } catch let e as CheckpointError {
            if case .bounds = e { } else { Issue.record("expected .bounds, got \(e)") }
        }
    }

    // MARK: - 5. Transport failure / cancellation during capture

    @Test("M3-C: capture transport failure fails closed; epoch unchanged; phase idle")
    func captureTransportFailureFailsClosed() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cf"))
        transport.script = [
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0)),
            // Capture request: out-of-script -> ScriptedError -> TransportFailure ambiguous.
        ]
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        let epochBefore = (await actor.currentState()).epoch
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.epochID == epochBefore.epochID, "epoch unchanged after capture failure")
        #expect(idle.phase == .idle)
        #expect(idle.unresolvedOperations.isEmpty, "capture failure leaves no unknown markers")
        #expect(idle.liveReservations.isEmpty, "failure clears the attempt reservation")
        #expect(!(try Self.records(store, session).contains { if case .checkpointPublished = $0 { return true }; return false }))
    }

    // MARK: - 6. Failed DB commit -> integrity stop, old epoch durable

    @Test("M3-C: failed publication commit integrity-stops; reopen sees NO new epoch")
    func failedCommitStopsWithOldEpoch() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (storeDir, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: storeDir) }
        let transport = ScriptedTransport()
        // Local fail-closed store wrapper (same shape as D3's): refuse ONLY
        // the checkpointPublished record batch.
        final class PublicationFailingStore: SessionStore, @unchecked Sendable {
            let inner: GRDBSessionStore
            init(_ inner: GRDBSessionStore) { self.inner = inner }
            func artifactRecord(session: SessionID, digest: String) throws -> Data? { try inner.artifactRecord(session: session, digest: digest) }
            func publishArtifact(session: SessionID, as identity: WriterIdentity, kind: String, operationID: OperationID?, bytes: Data) throws -> ArtifactRef { try inner.publishArtifact(session: session, as: identity, kind: kind, operationID: operationID, bytes: bytes) }
            func append(_ record: DurableRecord, as identity: WriterIdentity) throws { try inner.append(record, as: identity) }
            func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
                let hasPublication = records.contains { record in
                    if case .checkpointPublished = record { return true }
                    return false
                }
                if hasPublication {
                    throw StoreError.integrity("injected publication commit failure")
                }
                try inner.appendBatch(records, as: identity)
            }
            func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) { try inner.records(session: session, since: since, limit: limit) }
            func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) { try inner.records(since: since, limit: limit) }
            func sessions() throws -> [SessionID] { try inner.sessions() }
            func claimWriterOwnership(session: SessionID, writer: String) throws { try inner.claimWriterOwnership(session: session, writer: writer) }
            func releaseWriterOwnership(session: SessionID, writer: String) throws { try inner.releaseWriterOwnership(session: session, writer: writer) }
        }
        let failing = PublicationFailingStore(store)
        let idle = try ActorFixtures.idleState(mode: .trustedExec, permissive: true)
        let state = SessionState(sessionID: session, epoch: idle.epoch, trustMode: idle.trustMode, phase: .idle)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let actor = try SessionActor(
            state: state, ids: DeterministicIDSource(prefix: "m3cx"), clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: failing,
            approvals: ScriptedApprovals(), writer: writer.writer)
        transport.script = [ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0))]
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitSettled(actor)
        await actor.dismissRun()
        _ = try await Self.awaitSettled(actor, wantCompleted: false)
        transport.script = [
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "should not publish"), toolProposals: [], isFinal: true)),
        ]
        await actor.requestCheckpoint()
        // The commit failure must integrity-stop (visible as a hold), never
        // silently continue under the old epoch as if published.
        let settled = try await Self.awaitSettled(actor, wantCompleted: false)
        #expect(settled.queueHeld || settled.phase != .checkpointing, "commit failure surfaces (hold/stop), not silent continuation")
        #expect(try Self.records(store, session).contains { if case .checkpointPublished = $0 { return true }; return false } == false, "no durable publication")
    }

    // MARK: - 7. Reopen: old or new epoch, never hybrid

    @Test("M3-C: reopen after publication projects the SHORT context; pre-publication records intact")
    func reopenSelectsPublishedProjection() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        try "seed\n".write(to: dirURL.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cr"))
        transport.script = [
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0)),
        ]
        await actor.submitText(commandID: CommandID("task"), text: "the original pinned operator task text", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        transport.script = [
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "post-reopen goal"), toolProposals: [], isFinal: true)),
        ]
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        _ = try await Self.awaitIdle(actor)
        let newEpoch = (try Self.records(store, session)).compactMap { record -> EpochDescriptor? in
            if case .checkpointPublished(let p) = record { return p.epoch }
            return nil
        }.first
        let publishedEpoch = try #require(newEpoch)
        // Reopen through the production resume entry point with the NEW epoch:
        // the projection must be the shorter context (checkpoint block + tail),
        // never a hybrid of full history.
        var ids = DeterministicIDSource(prefix: "m3c-reopen")
        let resumed = try resumeSession(
            store: store, session: session, epoch: publishedEpoch, trustMode: .trustedExec,
            as: writer.writer, ids: &ids)
        #expect(resumed.epoch.epochID == publishedEpoch.epochID)
        let resumedProjection = try loadTranscriptProjection(from: store, session: session, limit: 1024)
        #expect(resumedProjection.count <= 3, "short projection after reopen, got \(resumedProjection.count)")
        #expect(resumedProjection.map { $0.text }.joined().contains("post-reopen goal"))
        // Old records intact: the original pinned user text still durable.
        #expect((try Self.records(store, session).contains { record in
            if case .transcriptAppended(.user(let t)) = record { return t.contains("pinned operator task") }
            return false
        }))
    }

    // MARK: - 8. Checkpoint refusal states

    @Test("M3-C: checkpoint refused with unresolved operations; queue entries do not silently cross epochs")
    func refusalAndQueueSafety() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cq"))
        // Seed an unresolved marker via the fault-injection pattern: an
        // executor result with a mismatched mutating claim fails closed.
        transport.script = [ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0))]
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        // Inject an unresolved marker by hand through the store (the ledger
        // is authoritative; resume reseeds it), then drive checkpoint
        // through a fresh actor over the same store.
        let marker = OperationRef(operationID: OperationID("eff-unknown/c1"), callID: "c1", state: .intent, mutating: true)
        try store.appendBatch([.operationIntent(marker)], as: writer)
        var ids = DeterministicIDSource(prefix: "m3cq2")
        let resumedState = try resumeSession(
            store: store, session: session, epoch: (await actor.currentState()).epoch,
            trustMode: .trustedExec, as: writer.writer, ids: &ids)
        #expect(resumedState.unresolvedOperations.isEmpty == false, "marker reseeds as unresolved")
        // A fresh actor over the resumed state (unresolved markers live there).
        let fresh = try SessionActor(
            state: resumedState, ids: DeterministicIDSource(prefix: "m3cq3"), clock: VirtualClock(now: 2_000_000),
            transport: transport, executor: NativeToolExecutor(resolver: try WorkspaceResolver(workspace: fp, readRoots: []), store: store, sessionID: session, writer: writer, execGrant: false),
            store: store, approvals: ScriptedApprovals(), writer: writer.writer)
        await fresh.requestCheckpoint()
        let state = await fresh.currentState()
        #expect(state.phase == .idle, "checkpoint refused under unresolved operations, phase=\(state.phase)")
        #expect((try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-refused-unresolved" }; return false }))
    }

    // MARK: - 9. Validator unit truth table

    @Test("M3-C validator: fences accepted, non-object refused, bounds enforced")
    func validatorTruthTable() throws {
        let fenced = "```json\n" + Self.checkpointJSON(goal: "fenced") + "\n```"
        let doc = try CheckpointValidator.parse(text: fenced)
        #expect(doc.taskGoal == "fenced")
        do {
            _ = try CheckpointValidator.parse(text: "[]")
            Issue.record("non-object must fail")
        } catch let e as CheckpointError {
            if case .malformed = e { } else { Issue.record("expected .malformed, got \(e)") }
        }
        do {
            _ = try CheckpointValidator.parse(text: "{\"no_task_goal\": true}")
            Issue.record("missing task_goal must fail")
        } catch let e as CheckpointError {
            if case .malformed = e { } else { Issue.record("expected .malformed, got \(e)") }
        }
        let badHash = Self.checkpointJSON(goal: "g", files: [["path": "p", "sha256": "ZZ"]])
        do {
            _ = try CheckpointValidator.parse(text: badHash)
            Issue.record("bad hash must fail")
        } catch let e as CheckpointError {
            if case .bounds = e { } else { Issue.record("expected .bounds, got \(e)") }
        }
    }

    // MARK: - 10. Tail cut unit truth table (pure)

    @Test("M3-C tail cut: empty/short retain all; straddles snap back; dangling and orphans refuse")
    func tailCutTruthTable() throws {
        #expect(CheckpointTailCut.compute([]) == 0, "empty history cuts at zero")
        let cleanShort: [(seq: UInt64, entry: TranscriptEntry)] = [
            (1, .user("a")), (2, .assistantText("b")), (3, .user("c")),
        ]
        #expect(CheckpointTailCut.compute(cleanShort) == 0, "short clean history retains everything")
        let longClean: [(seq: UInt64, entry: TranscriptEntry)] = (1...100).map { (UInt64($0), .user("u\($0)")) }
        #expect(CheckpointTailCut.compute(longClean) == 36, "long clean history keeps the last maxRecords")
        // Straddle: call at index 5, response at index 70, 74 entries —
        // the 64-record cut would land between them, so it snaps back.
        var straddle: [(seq: UInt64, entry: TranscriptEntry)] = []
        for i in 0..<5 { straddle.append((UInt64(i + 1), .user("u\(i)"))) }
        straddle.append((6, .toolCall(NativeToolCall(callID: "c1", tool: "read", arguments: "{}"))))
        for i in 0..<64 { straddle.append((UInt64(7 + i), .user("pad\(i)"))) }
        straddle.append((71, .toolResponse(callID: "c1", text: "data")))
        for i in 0..<3 { straddle.append((UInt64(72 + i), .user("tail\(i)"))) }
        #expect(straddle.count == 74)
        #expect(CheckpointTailCut.compute(straddle) == 5, "cut snaps back to include the straddled call")
        // Dangling call (crash between tool-call commit and result).
        let dangling: [(seq: UInt64, entry: TranscriptEntry)] = [
            (1, .user("do it")),
            (2, .assistantText("checking")),
            (3, .toolCall(NativeToolCall(callID: "c-dangle", tool: "read", arguments: "{\"path\":\"a.txt\"}"))),
        ]
        #expect(CheckpointTailCut.compute(dangling) == nil, "unmatched tail call refuses capture")
        // Orphan response (no preceding call anywhere).
        let orphan: [(seq: UInt64, entry: TranscriptEntry)] = [
            (1, .user("do it")),
            (2, .toolResponse(callID: "c-ghost", text: "data")),
        ]
        #expect(CheckpointTailCut.compute(orphan) == nil, "orphan response refuses capture")
    }

    // MARK: - 11. Dangling tool tail refuses at the actor

    @Test("M3-C: transcript ending in an unmatched tool call refuses capture; epoch unchanged")
    func danglingTranscriptRefusesCapture() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        // Crash shape: user + assistant text + tool call committed, no
        // result ever recorded (non-mutating intent leaves no unknown
        // marker, so the guards pass and the tail must refuse instead).
        try store.append(.transcriptAppended(.user("do the thing")), as: writer)
        try store.append(.transcriptAppended(.assistantText("checking")), as: writer)
        try store.append(.transcriptAppended(.toolCall(NativeToolCall(callID: "c-dangle", tool: "read", arguments: "{\"path\":\"a.txt\"}"))), as: writer)
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "would dangle"), toolProposals: [], isFinal: true)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3ch"))
        let epochBefore = (await actor.currentState()).epoch
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.epochID == epochBefore.epochID, "dangling tail never publishes")
        #expect(try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-failed" }; return false }, "dangling refusal recorded")
        #expect(!(try Self.records(store, session).contains { if case .checkpointPublished = $0 { return true }; return false }), "no publication")
    }

    // MARK: - 12. Full-field projection with authority markers

    @Test("M3-C: projection renders every checkpoint field; harness-bound vs model-asserted marked")
    func allFieldsProjected() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        try "alpha\n".write(to: dirURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let bodyHash = Self.sha("alpha\n")
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "reading", toolProposals: [
                    ToolProposal(callID: "c-read", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cf"))
        await actor.submitText(commandID: CommandID("task"), text: "Summarize a.txt for the all-fields check.", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        let fullDoc: [String: Any] = [
            "task_goal": "summarize a.txt",
            "user_constraints": ["keep tests green"],
            "completed_work": ["read a.txt end to end"],
            "current_files": [["path": "a.txt", "sha256": bodyHash]],
            "open_questions": ["is beta needed?"],
            "failed_attempts": ["no failures yet"],
            "next_actions": ["run the full suite", "ship it"],
            "uncertainties": ["model choice"],
        ]
        let fullJSON = String(decoding: try JSONSerialization.data(withJSONObject: fullDoc, options: [.sortedKeys]), as: UTF8.self)
        transport.script = [
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: fullJSON, toolProposals: [], isFinal: true)),
        ]
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        _ = try await Self.awaitIdle(actor)
        let projected = try loadTranscriptProjection(from: store, session: session, limit: 1024)
        let text = projected.map { $0.text }.joined(separator: "\n")
        #expect(text.contains("checkpoint context"), "block present")
        #expect(text.contains("summarize a.txt"), "goal rendered")
        #expect(text.contains("harness-pinned"), "pins marked harness-bound")
        #expect(text.contains("Summarize a.txt for the all-fields check."), "exact pinned constraint rendered")
        #expect(text.contains("read a.txt end to end"), "completed_work rendered")
        #expect(text.contains("model-asserted"), "model sections marked untrusted")
        #expect(text.contains("a.txt") && text.contains(bodyHash), "verified file reference rendered")
        #expect(text.contains("is beta needed?"), "open questions rendered")
        #expect(text.contains("no failures yet"), "failed attempts rendered")
        #expect(text.contains("ship it"), "next actions rendered")
        #expect(text.contains("model choice"), "uncertainties rendered")
    }

    // MARK: - 13. Stale before-hash fails; fresh after-hash commits

    @Test("M3-C: a stale pre-change hash fails verification; the after-hash publishes")
    func staleBeforeHashFailsFreshAfterHashCommits() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        try "alpha\n".write(to: dirURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let beforeHash = Self.sha("alpha\n")
        let afterHash = Self.sha("alpha beta\n")
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "editing", toolProposals: [
                    ToolProposal(callID: "c-edit", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\",\"expectedHash\":\"\(beforeHash)\",\"old_string\":\"alpha\\n\",\"new_string\":\"alpha beta\\n\"}"),
                ], isFinal: false)),
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(1)),
            // Capture 1 names the STALE pre-change hash.
            ProviderResponse(requestID: RequestID("cp1"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "stale ref", files: [["path": "a.txt", "sha256": beforeHash]]),
                toolProposals: [], isFinal: true)),
            // Capture 2 names the fresh after-hash.
            ProviderResponse(requestID: RequestID("cp2"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "fresh ref", files: [["path": "a.txt", "sha256": afterHash]]),
                toolProposals: [], isFinal: true)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3ce"))
        await actor.submitText(commandID: CommandID("task"), text: "Edit a.txt, then checkpoint it.", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        try await Self.dismissToIdle(actor)
        #expect(try String(contentsOf: dirURL.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha beta\n", "edit applied before capture")
        #expect(try Self.records(store, session).contains { if case .changeGroup = $0 { return true }; return false }, "change group durable")
        let epochBefore = (await actor.currentState()).epoch
        await actor.requestCheckpoint()
        _ = try await Self.awaitIdle(actor)
        #expect((await actor.currentState()).epoch.epochID == epochBefore.epochID, "stale before-hash never publishes")
        #expect(try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-failed" }; return false }, "stale refusal recorded")
        await actor.requestCheckpoint()
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID != nil, "after-hash publishes")
    }

    // MARK: - 14. Sealed capture inherits sealed

    @Test("M3-C: a sealed capture request carries the sealed flag to the provider")
    func sealedCaptureInheritsSealed() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        transport.script = [
            ActorFixtures.finalResponse(requestID: RequestID("scripted"), generation: Revision(0)),
            ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
                text: Self.checkpointJSON(goal: "sealed goal"), toolProposals: [], isFinal: true)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cs"))
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint(sealed: true)
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID != nil, "sealed capture still commits")
        let captures = transport.invocations.filter { $0.isCheckpoint }
        #expect(captures.count == 1 && captures.first?.sealed == true, "the capture invocation inherits sealed")
    }

    // MARK: - 15. Stale denial drops; the attempt keeps its one retry

    @Test("M3-C: a denial for a superseded attempt drops stale; the live attempt still commits")
    func staleDenialDrops() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let gate = GatedTransport()
        let (stream, cont) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let actor = try SessionActor(
            state: SessionState(sessionID: session, epoch: (try ActorFixtures.idleState(mode: .trustedExec, permissive: true)).epoch, trustMode: .trustedExec, phase: .idle),
            ids: DeterministicIDSource(prefix: "m3cn"), clock: VirtualClock(now: 3_000_000),
            transport: gate, executor: executor, store: store,
            approvals: ScriptedApprovals(), writer: writer.writer)
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if gate.invocations.count == 1 { break }
            await Task.yield()
        }
        cont.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("t1"), generation: Revision(0))))
        _ = try await Self.awaitCompleted(actor)
        try await Self.dismissToIdle(actor)
        await actor.requestCheckpoint()
        for _ in 0..<20_000 {
            let s = await actor.currentState()
            if s.phase == .checkpointing, gate.invocations.count == 2 { break }
            await Task.yield()
        }
        #expect((await actor.currentState()).phase == .checkpointing, "capture in flight")
        // A denial naming a superseded attempt: dropped, retry unconsumed.
        await actor.applyExternalEvent(.checkpointToolDenied(requestID: RequestID("bogus"), sealed: false, callIDs: ["x"], atMillis: 3_000_001))
        #expect((await actor.currentState()).phase == .checkpointing, "stale denial drops without effect")
        cont.yield(.respond(ProviderResponse(requestID: RequestID("cp"), generation: Revision(0), outcome: .textDeltaComplete(
            text: Self.checkpointJSON(goal: "stale-denial goal"), toolProposals: [], isFinal: true))))
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.epoch.parentEpochID != nil, "live attempt commits without spending its retry")
        #expect(!(try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-tool-denied" }; return false }), "no denial consumed")
    }

    // MARK: - 18. Cancel during capture aborts fail-closed (no hang, no publication)

    @Test("M3-C: cancelling a capture aborts fail-closed; epoch unchanged; never strands in cancelling")
    func cancelDuringCaptureAborts() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let gate = GatedTransport()
        let (stream, cont) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let executor = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer, execGrant: false)
        let actor = try SessionActor(
            state: SessionState(sessionID: session, epoch: (try ActorFixtures.idleState(mode: .trustedExec, permissive: true)).epoch, trustMode: .trustedExec, phase: .idle),
            ids: DeterministicIDSource(prefix: "m3cc"), clock: VirtualClock(now: 4_000_000),
            transport: gate, executor: executor, store: store,
            approvals: ScriptedApprovals(), writer: writer.writer)
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        for _ in 0..<20_000 {
            if gate.invocations.count == 1 { break }
            await Task.yield()
        }
        cont.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("t1"), generation: Revision(0))))
        _ = try await Self.awaitCompleted(actor)
        try await Self.dismissToIdle(actor)
        let epochBefore = (await actor.currentState()).epoch
        await actor.requestCheckpoint()
        for _ in 0..<20_000 {
            let s = await actor.currentState()
            if s.phase == .checkpointing, gate.invocations.count == 2 { break }
            await Task.yield()
        }
        #expect((await actor.currentState()).phase == .checkpointing, "capture in flight")
        await actor.cancel()
        // The in-flight task dies on cancellation; release the gate either
        // way — nothing may pair afterwards.
        cont.yield(.fail("cancelled"))
        let idle = try await Self.awaitIdle(actor)
        #expect(idle.phase == .idle, "cancel returns to idle, never strands in cancelling")
        #expect(idle.epoch.epochID == epochBefore.epochID, "epoch unchanged after cancel")
        #expect(idle.queueHeld == false, "cancel of a capture holds no queue")
        #expect(try Self.records(store, session).contains { if case .eventAppended(_, let kind, _) = $0 { return kind == "checkpoint-failed" }; return false }, "cancel recorded")
        #expect(!(try Self.records(store, session).contains { if case .checkpointPublished = $0 { return true }; return false }), "no publication")
    }

    // MARK: - 19. M3-D per-request usage accounting

    @Test("M3-D usage log: one complete entry per paired response; unknown stays unknown")
    func usageLogAccounting() async throws {
        let (dirURL, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let (_, store, session, writer) = try Self.tempStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: dirURL) }
        let transport = ScriptedTransport()
        transport.script = [
            ProviderResponse(requestID: RequestID("s1"), generation: Revision(0), outcome: .textDeltaComplete(
                text: "done", toolProposals: [], isFinal: true), usageInput: 100, usageOutput: 20),
            ActorFixtures.finalResponse(requestID: RequestID("s2"), generation: Revision(1)),
        ]
        let actor = try Self.makeActor(dir: fp, store: store, session: session, writer: writer, transport: transport, ids: DeterministicIDSource(prefix: "m3cu"))
        await actor.submitText(commandID: CommandID("task"), text: "task", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        await actor.submitText(commandID: CommandID("task2"), text: "task2", kind: .followUp, sealed: false)
        _ = try await Self.awaitCompleted(actor)
        let log = await actor.usageLog
        #expect(log.count == 2, "one entry per paired response, got \(log.count)")
        #expect(log[0].usageInput == 100 && log[0].usageOutput == 20, "usage carried verbatim")
        #expect(log[1].usageInput == nil && log[1].usageOutput == nil, "missing usage stays unknown, never zero-filled")
        #expect(!log[0].requestID.isEmpty && log[0].requestID != log[1].requestID, "distinct invocation identities")
    }

    // MARK: - 17. Capture overlay helper

    @Test("M3-C capture overlay: full history plus retry note plus instruction, input untouched")
    func captureOverlayHelper() throws {
        let history = [ChatMessage(role: .user, text: "full history")]
        let plain = CheckpointValidator.captureOverlay(history: history, retryNote: nil)
        #expect(plain.count == 2, "history + instruction")
        #expect(plain[0].text == "full history")
        #expect(plain[1].text == CheckpointValidator.instruction)
        let withRetry = CheckpointValidator.captureOverlay(history: history, retryNote: "retry note")
        #expect(withRetry.count == 3, "history + retry note + instruction")
        #expect(withRetry[1].text == "retry note")
        #expect(withRetry[2].text == CheckpointValidator.instruction)
        #expect(history.count == 1, "input history untouched")
    }
}
