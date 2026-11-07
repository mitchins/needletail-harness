import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport
import NeedletailRuntime
import SystemPackage

/// M2-D D1 actor integration: production SessionActor + real committed
/// record groups + real temporary files, with a scripted validator seam
/// (the codebase's established ScriptedTransport pattern). The validator
/// reads the actual temp files on every call — mutations the test makes
/// between queueing and dispatch surface as stale evidence through the
/// real effect → validate → result → hold/dispatch loop. Real-filesystem
/// validator fidelity (containment, hashing, identity) is covered in
/// PrimitiveTests against the production FilesystemAttachmentValidator;
/// reopen replay goes through the production `resumeSession` entry point.
/// Darwin-debug: suite gated (B6 G14-class — the debug runner SIGBUSes
/// on these deep transition chains; Linux-debug + Darwin `-O` green).
#if canImport(Glibc)
struct QueueAttachmentActorTests {

    /// Scripted validator over real temp files: each snapshot's expected
    /// bytes are fixed at capture time; an observation is fresh iff the
    /// file's CURRENT bytes still equal them. No hashes are computed here
    /// (hash fidelity belongs to the Runtime validator tests) — the
    /// contentHash tokens are opaque, exactly as the transition treats them.
    final class FileWatchValidator: AttachmentValidator, @unchecked Sendable {
        private let lock = NSLock()
        private var expected: [String: Data] = [:]
        /// Workspace root for relative snapshot paths (real capture
        /// emits workspace-relative paths; resolution mirrors the
        /// resolver's root).
        var root: String = ""

        func expect(path: String, bytes: Data) {
            lock.withLock { expected[path] = bytes }
        }

        func validate(entryID: String, snapshots: [AttachmentSnapshot]) async -> [AttachmentObservation] {
            snapshots.map { snapshot in
                let resolved: String
                if snapshot.path.hasPrefix("/") {
                    resolved = snapshot.path
                } else if root.isEmpty {
                    resolved = snapshot.path
                } else {
                    resolved = (root as NSString).appendingPathComponent(snapshot.path)
                }
                let current = try? Data(contentsOf: URL(fileURLWithPath: resolved))
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
        var files = TempFiles(dir: dir)
        files.validator.root = dir.path
        return files
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

    @Test("UX-MENTION-09 mutation before dispatch holds; nothing half-composed enters context")
    func UX_MENTION_09_mutationHoldsBeforeDispatch() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let snap = try files.snapshot("m9.txt", text: "version one\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: files.validator)
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "review this", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued")
        // Mutate between queueing and dispatch: the file changed under
        // the snapshot, so dispatch must hold rather than compose either
        // version half-heartedly.
        try files.write("m9.txt", text: "version two, sneaked in\n")
        continuation.yield(Self.final())
        try await ActorFixtures.awaitPhase(actor, {
            $0.queueHeld && $0.queue.first?.state == .held
        }, "mutated entry held stale")
        #expect(gate.invocations.count == 1, "stale entry never dispatches")
        let held = await actor.currentState()
        #expect(held.heldReason == HoldReason.staleAttachment, "hold carries the stale reason")
        let users = try Self.transcriptUsers(store: store, session: idle.sessionID)
        #expect(!users.contains(where: { $0.contains("version one") || $0.contains("version two") }),
            "no half-composed excerpt enters context: \(users)")
        continuation.finish()
    }

    @Test("UX-MENTION-10 large references compose bounded excerpts; sealed refuses")
    func UX_MENTION_10_boundedOrSealed() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        // 2 MiB of repetitive content with unique head/tail markers.
        let big = "HEAD-MARKER\n" + String(repeating: "x", count: 2 * 1024 * 1024) + "\nTAIL-MARKER-never-included\n"
        try big.write(to: files.dir.appendingPathComponent("big.bin"), atomically: true, encoding: .utf8)
        let idle0 = try ActorFixtures.idleState()
        let resolver = try WorkspaceResolver(workspace: FilePath(files.dir.path), readRoots: [])
        let capture = AttachmentCaptureService(resolver: resolver)
        let snap = try capture.capture(relativePath: "big.bin", lineRange: nil,
            intent: "mention", epochID: idle0.epoch.epochID,
            routeGrant: AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false))
        files.validator.expect(path: snap.path, bytes: Data(big.utf8))
        #expect(snap.content.excerptBytes <= 4 * 1024, "capture bounds the excerpt, got \(snap.content.excerptBytes)")
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        let actor = try Self.makeGatedActor(
            store: store, state: idle, transport: gate,
            ids: DeterministicIDSource(prefix: "qa"), validator: files.validator)
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-big"), text: "summarize", kind: .followUp,
            sealed: false, attachments: [snap])
        continuation.yield(Self.final())
        continuation.yield(Self.final())
        continuation.yield(Self.final())
        for _ in 0..<2000 { await Task.yield() }
        do { let st = await actor.currentState(); print("M10-STATE", st.phase, st.queue.map { "\($0.commandID.raw):\($0.state)" }, st.heldReason as Any, "inv=", gate.invocations.count) }
        try await ActorFixtures.awaitPhase(actor, {
            $0.queue.allSatisfy { $0.state == .admittedToHistory }
        }, "bounded dispatch completes")
        let users = try Self.transcriptUsers(store: store, session: idle.sessionID)
        let composed = users.joined(separator: "\n")
        #expect(composed.utf8.count < 64 * 1024, "2 MiB reference composes bounded, got \(composed.utf8.count) bytes")
        #expect(composed.contains("HEAD-MARKER"), "excerpt head present")
        #expect(composed.contains("first ") && composed.contains("shown"), "truncation manifest present")
        #expect(!composed.contains("TAIL-MARKER"), "tail beyond the bound never enters context")
        // Sealed mode refuses attachments instead of downgrading silently.
        // A following normal submit proves the actor processed past the
        // refusal (deterministic barrier, not a timing assumption).
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-sealed"), text: "sealed", kind: .followUp,
            sealed: true, attachments: [snap])
        await actor.submitText(commandID: CommandID("probe-1"), text: "probe", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, {
            $0.admittedCommands[CommandID("probe-1")] != nil
        }, "probe admitted past the refusal")
        let after = await actor.currentState()
        #expect(after.admittedCommands[CommandID("q-sealed")] == nil, "sealed attach never admitted")
        #expect(after.queue.allSatisfy { $0.commandID != CommandID("q-sealed") }, "no queue row for sealed attach")
        continuation.finish()
    }

    @Test("UX-MENTION-12 epoch switch holds for re-consent; retarget releases")
    func UX_MENTION_12_epochSwitchHoldsForReconsent() async throws {
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let store = InMemorySessionStore()
        let idle = try ActorFixtures.idleState()
        let session = idle.sessionID
        let snap = try files.snapshot("c.txt", text: "consented\n", epoch: idle.epoch.epochID)
        let gate = GatedTransport()
        let (stream, continuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate.gate = stream
        var rids = DeterministicIDSource(prefix: "m12")
        let actor = try SessionActor(
            state: idle, ids: rids, clock: VirtualClock(now: 1_000_000),
            transport: gate, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "m12-writer",
            attachmentValidator: files.validator)
        await actor.submitText(commandID: CommandID("run-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate, count: 1)
        await actor.submitTextWithAttachments(
            commandID: CommandID("q-1"), text: "with file", kind: .followUp,
            sealed: false, attachments: [snap])
        try await ActorFixtures.awaitPhase(actor, { $0.queue.count == 1 }, "queued under epoch A")
        // Crash, then reopen under a NEW epoch (models a route/epoch
        // switch, e.g. to cloud): the queued entry's target predates the
        // live epoch, so it must hold for explicit re-consent.
        let epochB = EpochDescriptor(
            epochID: EpochID("epoch-b"), parentEpochID: idle.epoch.epochID,
            configSnapshot: idle.epoch.configSnapshot, profile: idle.epoch.profile,
            effectiveCaps: idle.epoch.effectiveCaps, route: idle.epoch.route)
        var rids2 = DeterministicIDSource(prefix: "m12b")
        try store.releaseWriterOwnership(session: session, writer: "m12-writer")
        let rebuilt = try resumeSession(store: store, session: session, epoch: epochB,
            trustMode: .workspace, as: "m12-writer", ids: &rids2)
        #expect(rebuilt.queue.first?.targetEpochID != rebuilt.epoch.epochID, "target predates the live epoch")
        // A fresh actor on the rebuilt state. Submitting while the
        // stale head sits queued does NOT dispatch it (no silent
        // re-consent, no skip): the barrier trips on the first
        // completion attempt instead.
        let gate2 = GatedTransport()
        let (stream2, continuation2) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        gate2.gate = stream2
        var rids3 = DeterministicIDSource(prefix: "m12c")
        let actor2 = try SessionActor(
            state: rebuilt, ids: rids2, clock: VirtualClock(now: 2_000_000),
            transport: gate2, executor: ScriptedExecutor(), store: store,
            approvals: ScriptedApprovals(), writer: "m12-writer",
            attachmentValidator: files.validator)
        // A fresh run jumps ahead while the stale head waits; queue a
        // current entry behind the stale head WHILE that run is in
        // flight (busy admits queue behind). Its completion pops the
        // queue, and the pop trips the head barrier instead of
        // dispatching (or skipping) the stale entry.
        await actor2.submitText(commandID: CommandID("run-2"), text: "drain", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(gate2, count: 1)
        await actor2.submitText(commandID: CommandID("q-2"), text: "behind", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor2, { $0.queue.count == 2 }, "current entry queued behind stale head")
        continuation2.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        for _ in 0..<2000 { await Task.yield() }
        do {
            let st = await actor2.currentState()
            print("M12-POST-R1 held=\(st.queueHeld) q=\(st.queue.map { "\($0.commandID.raw):\($0.state)" }) inv=\(gate2.invocations.count) phase=\(st.phase) active=\(String(describing: st.activeRun?.runID))")
        }
        try await ActorFixtures.awaitPhase(actor2, { $0.queueHeld }, "stale head blocks the queue")
        let held = await actor2.currentState()
        // The barrier holds the QUEUE (entries stay queued, nothing
        // dispatched past the stale head).
        #expect(held.queue.first(where: { $0.commandID == CommandID("q-1") })?.state == .queued,
            "stale head itself stays queued: \(held.queue.map { "\($0.commandID.raw):\($0.state)" })")
        #expect(held.heldReason == .error("queue head targets a stale epoch; retarget or withdraw \(held.queue.first!.entryID)"),
            "hold names the stale-epoch cause, got: \(String(describing: held.heldReason))")
        #expect(gate2.invocations.count == 1, "nothing dispatched past the stale head")
        // Explicit re-consent (retarget) + resume releases the head.
        let entryID = try #require(held.queue.first(where: { $0.commandID == CommandID("q-1") })?.entryID)
        await actor2.retargetQueueEntry(entryID: entryID)
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.first(where: { $0.commandID == CommandID("q-1") })?.attachmentConsentEpoch == EpochID("epoch-b")
        }, "consent refreshed to the live epoch")
        await actor2.resumeQueue()
        await actor2.submitText(commandID: CommandID("run-3"), text: "drain", kind: .followUp, sealed: false)
        continuation2.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        continuation2.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        continuation2.yield(.respond(ActorFixtures.finalResponse(requestID: RequestID("x"), generation: Revision(0))))
        try await ActorFixtures.awaitPhase(actor2, {
            $0.queue.filter({ $0.commandID == CommandID("q-1") || $0.commandID == CommandID("q-2") }).allSatisfy({ $0.state == .admittedToHistory })
        }, "re-consented head drains in order")
        let users = try Self.transcriptUsers(store: store, session: session)
        #expect(users.contains(where: { $0.contains("consented") }), "re-consented excerpt enters context")
        continuation2.finish()
        continuation.finish()
    }
}
#endif
