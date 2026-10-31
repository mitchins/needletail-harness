import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport

/// M2-D D1 actor integration: production SessionActor + real committed
/// record groups + real temporary files, with a scripted validator seam
/// (the codebase's established ScriptedTransport pattern). The validator
/// reads the actual temp files on every call — mutations the test makes
/// between queueing and dispatch surface as stale evidence through the
/// real effect → validate → result → hold/dispatch loop. Real-filesystem
/// validator fidelity (containment, hashing, identity) is covered in
/// PrimitiveTests against the production FilesystemAttachmentValidator;
/// reopen replay goes through the production `resumeSession` entry point.
struct QueueAttachmentActorTests {

    /// Scripted validator over real temp files: each snapshot's expected
    /// bytes are fixed at capture time; an observation is fresh iff the
    /// file's CURRENT bytes still equal them. No hashes are computed here
    /// (hash fidelity belongs to the Runtime validator tests) — the
    /// contentHash tokens are opaque, exactly as the transition treats them.
    final class FileWatchValidator: AttachmentValidator, @unchecked Sendable {
        private let lock = NSLock()
        private var expected: [String: Data] = [:]

        func expect(path: String, bytes: Data) {
            lock.withLock { expected[path] = bytes }
        }

        func validate(entryID: String, snapshots: [AttachmentSnapshot]) async -> [AttachmentObservation] {
            snapshots.map { snapshot in
                let current = try? Data(contentsOf: URL(fileURLWithPath: snapshot.path))
                let wanted = lock.withLock { expected[snapshot.path] }
                let fresh = current == wanted && wanted != nil
                return AttachmentObservation(
                    snapshotHash: snapshot.contentHash, device: snapshot.device,
                    inode: snapshot.inode, size: snapshot.size,
                    contentHash: fresh ? snapshot.contentHash : "STALE",
                    totalLines: snapshot.totalLines, readable: current != nil,
                    denyReason: current == nil ? "removed" : nil)
            }
        }
    }

    struct TempFiles {
        let dir: URL
        let validator = FileWatchValidator()

        func write(_ name: String, text: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }

        func path(_ name: String) -> String {
            dir.appendingPathComponent(name).path
        }

        /// Hand-built snapshot (opaque identity/hash tokens) with expected
        /// bytes registered in the validator — the actor loop under test,
        /// not capture (capture is covered in PrimitiveTests).
        func snapshot(_ name: String, text: String, epoch: EpochID) throws -> AttachmentSnapshot {
            let bytes = Data(text.utf8)
            try bytes.write(to: dir.appendingPathComponent(name))
            validator.expect(path: path(name), bytes: bytes)
            return AttachmentSnapshot(
                path: path(name), grantedRoot: "workspace",
                device: 7, inode: 9, size: bytes.count,
                contentHash: "hash:\(text)", lineRange: nil,
                totalLines: text.components(separatedBy: "\n").count - 1,
                content: .included(excerpt: text, truncated: false),
                captureEpochID: epoch,
                routeGrant: AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false),
                intent: "mention")
        }
    }

    static func makeFiles() throws -> TempFiles {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qattach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TempFiles(dir: dir)
    }

    static func makeGatedActor(
        store: InMemorySessionStore, state: SessionState,
        transport: GatedTransport, ids: DeterministicIDSource,
        validator: (any AttachmentValidator)?,
        writer: String = "qa-writer"
    ) throws -> SessionActor<GatedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource> {
        try SessionActor(
            state: state, ids: ids, clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: writer,
            attachmentValidator: validator)
    }

    static func final() -> GatedTransport.TransportGateCommand {
        .respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0)))
    }

    static func transcriptUsers(store: InMemorySessionStore, session: SessionID) throws -> [String] {
        let (page, _) = try store.records(session: session, since: 0, limit: 10_000)
        return page.compactMap { sequenced in
            if case .transcriptAppended(.user(let text)) = sequenced.record { return text }
            return nil
        }
    }

    @Test("QUEUE-08: stale head holds via production actor, fix redispatches with new bytes")
    func staleHeadHoldsAndFixRedispatches() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let snap = try files.snapshot("a.txt", text: "version one\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: files.validator)

        // Run 1 in flight; queue the attachment entry behind it.
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "review this", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        // Mutate (same size — only the content token can catch it), then finish run 1.
        try files.write("a.txt", text: "version two\n")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(
            actor, { $0.queueHeld && $0.queue.first?.state == .held }, "stale hold")
        let held = await actor.currentState()
        #expect(held.heldReason == HoldReason.staleAttachment, "production hold carries the stale reason")
        #expect(gate.invocations.count == 1, "stale head never dispatches")

        // Resume WITHOUT fixing cannot be exploited: the head unholds,
        // but the next pop revalidates it before anything behind can move.
        await actor.resumeQueue()
        try await ActorFixtures.awaitPhase(actor, { !$0.queueHeld }, "resumed-unfixed")
        await actor.submitText(commandID: CommandID("tail-1"), text: "tail", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 2)
        await actor.submitText(commandID: CommandID("tail-2"), text: "tail queued", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 2 }, "tail queued")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, {
            $0.queueHeld && $0.queue.first?.state == .held
        }, "revalidation re-trips the stale hold")
        let barred = await actor.currentState()
        #expect(gate.invocations.count == 2, "nothing overtakes the stale head")
        #expect(barred.heldReason == HoldReason.staleAttachment, "re-hold carries the stale reason")
        let tail = try #require(barred.queue.first(where: { $0.commandID == CommandID("tail-2") }))
        #expect(tail.state == .queued, "the entry behind is preserved, not skipped")

        // Explicit fix: fresh capture of the changed file, replace, resume.
        let fixed = try files.snapshot("a.txt", text: "version two\n", epoch: idle.epoch.epochID)
        #expect(fixed.contentHash != snap.contentHash, "the file really changed")
        let entryID = try #require(barred.queue.first?.entryID)
        await actor.replaceEntryAttachments(entryID: entryID, snapshots: [fixed])
        try await ActorFixtures.awaitPhase(
            actor, { $0.queue.first?.attachments.first?.contentHash == fixed.contentHash }, "replaced")
        await actor.resumeQueue()
        try await ActorFixtures.awaitPhase(actor, { !$0.queueHeld }, "resumed")
        await actor.submitText(commandID: CommandID("run-2"), text: "run2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 3)
        continuation.yield(Self.final())
        // The fixed head validates fresh and dispatches; the preserved
        // tail follows on the next pop with no validation gate.
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.first?.state == .admittedToHistory
        }, "fixed head dispatched")
        try await ActorFixtures.awaitInvocations(gate, count: 4)
        #expect(gate.invocations.count == 4, "replaced + resumed + freshly validated dispatches exactly once")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "tail follows")
        try await ActorFixtures.awaitInvocations(gate, count: 5)
        #expect(gate.invocations.count == 5, "queue flows after the fix")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, {
            if case .completed = $0.phase { return true }; return false
        }, "drained")
        continuation.finish()
        // The dispatched run carries the NEW bytes, never the stale ones.
        let users = try Self.transcriptUsers(store: store, session: idle.sessionID)
        #expect(users.contains(where: { $0.contains("version two") }), "new excerpt enters model context")
        #expect(!users.contains(where: { $0.contains("version one") }), "stale bytes never entered context")
    }

    @Test("MENTION-11: withdraw before dispatch produces zero provider requests")
    func withdrawBeforeDispatchZeroProvider() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let snap = try files.snapshot("w.txt", text: "withdraw me\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: files.validator)
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "queued", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        let entryID = try #require((await actor.currentState()).queue.first?.entryID)
        await actor.withdrawEntry(entryID: entryID)
        try await ActorFixtures.awaitPhase(
            actor, { $0.queue.first?.state == .withdrawn }, "withdrawn")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, {
            if case .completed = $0.phase { return true }; return false
        }, "completed")
        #expect(gate.invocations.count == 1, "withdrawn entry never dispatches: zero further provider requests")
        continuation.finish()
        let users = try Self.transcriptUsers(store: store, session: idle.sessionID)
        #expect(!users.contains(where: { $0.contains("withdraw me") }), "withdrawn excerpt never enters context")
    }

    @Test("stale snapshot after crash/reopen holds until replace + resume + revalidate")
    func staleAfterReopenHoldsUntilFix() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let snap = try files.snapshot("c.txt", text: "before crash\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor1 = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: files.validator)
        await actor1.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor1.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "queued", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor1, { $0.queue.count == 1 }, "queued")
        // Mutate, finish, hold — the hold commits — then crash (drop actor1).
        try files.write("c.txt", text: "after crash!\n")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor1, { $0.queueHeld }, "stale hold committed")
        continuation.finish()

        // Reopen through the production entry point: snapshots survive,
        // evidence does not (the next dispatch revalidates).
        var rids = DeterministicIDSource(prefix: "qb")
        let rebuilt = try resumeSession(
            store: store, session: idle.sessionID, epoch: idle.epoch,
            trustMode: .workspace, as: "qa-writer", ids: &rids)
        let reopened = try #require(rebuilt.queue.first)
        #expect(reopened.state == .held, "stale hold survives reopen")
        #expect(reopened.attachments == [snap], "snapshot provenance survives reopen")
        let gate2 = GatedTransport()
        let (stream2, continuation2) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate2.gate = stream2
        let actor2 = try Self.makeGatedActor(
            store: store, state: rebuilt, transport: gate2, ids: rids,
            validator: files.validator, writer: "qa-writer")
        // Replace (recapture post-crash bytes) + resume + fresh run.
        let fixed = try files.snapshot("c.txt", text: "after crash!\n", epoch: idle.epoch.epochID)
        await actor2.replaceEntryAttachments(entryID: reopened.entryID, snapshots: [fixed])
        await actor2.resumeQueue()
        await actor2.submitText(commandID: CommandID("run-2"), text: "run2", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate2, count: 1)
        continuation2.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.allSatisfy { $0.state != .queued && $0.state != .held }
        }, "dispatched after fix")
        try await ActorFixtures.awaitInvocations(gate2, count: 2)
        #expect(gate2.invocations.count == 2, "exactly one redispatch after reopen + fix")
        continuation2.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor2, {
            if case .completed = $0.phase { return true }; return false
        }, "drained")
        continuation2.finish()
        let users = try Self.transcriptUsers(store: store, session: idle.sessionID)
        #expect(users.contains(where: { $0.contains("after crash!") }), "post-crash bytes enter context only after fix")
    }

    @Test("uncomposed validator holds fail-closed with no dispatch")
    func nilValidatorHoldsFailClosed() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let snap = try files.snapshot("x.txt", text: "x\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        // No validator composed.
        let actor = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: nil)
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "queued", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, { $0.queueHeld }, "held without validator")
        #expect(gate.invocations.count == 1, "missing evidence never dispatches")
        continuation.finish()
    }
}
