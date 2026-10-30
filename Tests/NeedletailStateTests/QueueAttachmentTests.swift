import Testing
import Foundation
@testable import NeedletailCore
import NeedletailTestSupport

/// M2-D D1: attachment snapshots, stale dispatch refusal, budget/sealed/
/// consent gates — reducer level (fast, deterministic). Filesystem capture
/// and actor integration legs live in AttachmentCaptureTests (temp fs) and
/// QueueAttachmentActorTests (production actor + temp-fs validator).
struct QueueAttachmentTests {

    // MARK: - Fixtures

    static func snap(
        path: String = "notes/a.txt", device: UInt64 = 7, inode: UInt64 = 9,
        size: Int = 12, hash: String = "ha", lines: Int = 3,
        excerpt: String = "hello\nworld\n", truncated: Bool = false,
        range: AttachmentLineRange? = nil, epoch: String = "epoch-1",
        alias: String = "local-coder", locality: Locality = .local,
        sealed: Bool = false, intent: String = "mention"
    ) -> AttachmentSnapshot {
        AttachmentSnapshot(
            path: path, grantedRoot: "workspace",
            device: device, inode: inode, size: size,
            contentHash: hash, lineRange: range, totalLines: lines,
            content: .included(excerpt: excerpt, truncated: truncated),
            captureEpochID: EpochID(epoch),
            routeGrant: AttachmentRouteGrant(alias: alias, locality: locality, sealed: sealed),
            intent: intent)
    }

    static func obs(
        of snapshot: AttachmentSnapshot,
        device: UInt64? = nil, inode: UInt64? = nil, size: Int? = nil,
        hash: String? = nil, lines: Int? = nil, readable: Bool = true,
        denyReason: String? = nil
    ) -> AttachmentObservation {
        AttachmentObservation(
            snapshotHash: snapshot.contentHash,
            device: device ?? snapshot.device, inode: inode ?? snapshot.inode,
            size: size ?? snapshot.size, contentHash: hash ?? snapshot.contentHash,
            totalLines: lines ?? snapshot.totalLines,
            readable: readable, denyReason: denyReason)
    }

    static func inputWithAttachments(
        _ text: String, id: String = "cmd-1", kind: QueueKind = .followUp,
        sealed: Bool = false, attachments: [AttachmentSnapshot], at: UInt64 = 1000
    ) -> SessionEvent {
        .operatorInputAttachments(
            commandID: CommandID(id), text: text, kind: kind,
            sealed: sealed, attachments: attachments, atMillis: at)
    }

    /// Idle state with an in-flight run and one queued attachment entry.
    static func streamingWithAttachment(
        ids: inout DeterministicIDSource, snapshot: AttachmentSnapshot,
        text: String = "look at this", id: String = "cmd-q"
    ) throws -> (SessionState, RunDescriptor) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        state = transition(
            state,
            Self.inputWithAttachments(text, id: id, attachments: [snapshot], at: 1003),
            &ids).state
        return (state, run)
    }

    static func finalResponse(_ run: RunDescriptor, text: String = "done") -> SessionEvent {
        .providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(
                requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(text: text, toolProposals: [], isFinal: true)),
            atMillis: 1004)
    }

    static func hasEffect(_ effects: [Effect], where predicate: (Effect) -> Bool) -> Bool {
        effects.contains(where: predicate)
    }

    static func isValidationRequest(_ e: Effect, entryID: String) -> Bool {
        if case .validateAttachments(let id, _) = e { return id == entryID }
        return false
    }

    static func isProviderRequest(_ e: Effect) -> Bool {
        if case .requestProvider = e { return true }
        return false
    }

    // MARK: - Admission

    @Test("idle attachment input dispatches immediately with composed transcript")
    func freshAdmissionComposesExcerpts() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let snapshot = Self.snap()
        let result = transition(
            idle, Self.inputWithAttachments("review this", attachments: [snapshot]), &ids)
        guard case .admitting = result.state.phase else {
            Issue.record("attachment input must admit a fresh run when idle"); return
        }
        #expect(!Self.hasEffect(result.effects) { if case .validateAttachments = $0 { return true }; return false },
                "capture-fresh dispatch needs no revalidation round trip")
        let users = result.records.compactMap { record -> String? in
            if case .transcriptAppended(.user(let text)) = record { return text }
            return nil
        }
        #expect(users.count == 1, "one user transcript row")
        #expect(users[0].contains("review this"), "operator text preserved")
        #expect(users[0].contains("notes/a.txt"), "manifest names the file")
        #expect(users[0].contains("hello"), "excerpt enters model context")
        #expect(users[0].contains("sha256:ha"), "manifest binds the hash")
    }

    @Test("sealed attachment admission is refused fresh and queued")
    func sealedAdmissionRefusesAttachments() throws {
        var ids = StateFixtures.ids()
        // Fresh (idle) sealed submission.
        let idle = try StateFixtures.idle()
        let fresh = transition(
            idle, Self.inputWithAttachments("x", sealed: true, attachments: [Self.snap()]), &ids)
        #expect(fresh.state.phase == .idle, "no run admitted")
        #expect(!Self.hasEffect(fresh.effects, where: Self.isProviderRequest), "zero provider requests")
        #expect(Self.hasEffect(fresh.effects) {
            if case .emitUI(let p) = $0 { return p.kind == "denied" && p.detail.contains("sealed") }
            return false
        }, "explicit sealed-admission denial")
        // Queued (busy) sealed submission.
        let (streaming, _) = try Self.streamingWithAttachment(ids: &ids, snapshot: Self.snap())
        let queued = transition(
            streaming, Self.inputWithAttachments("y", id: "cmd-y", sealed: true, attachments: [Self.snap(path: "notes/b.txt")], at: 1005), &ids)
        #expect(queued.state.queue.count == 1, "refused admission leaves the queue untouched")
        #expect(!Self.hasEffect(queued.effects, where: Self.isProviderRequest), "zero provider requests")
    }

    @Test("admitted excerpts count toward the 64 KiB queue text budget")
    func budgetCountsExcerpts() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let busy = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        // One entry whose text + 4 KiB excerpt lands exactly on budget.
        let big = String(repeating: "a", count: maxQueueTextBytes - maxAttachmentExcerptBytes)
        let snapshot = Self.snap(excerpt: String(repeating: "e", count: maxAttachmentExcerptBytes))
        let first = transition(
            busy, Self.inputWithAttachments(big, id: "cmd-big", attachments: [snapshot], at: 1002), &ids)
        #expect(first.state.queue.count == 1, "exactly-at-budget admission fits")
        // One more byte overflows.
        let over = transition(
            first.state, Self.inputWithAttachments("b", id: "cmd-over", attachments: [], at: 1003), &ids)
        #expect(over.state.queue.count == 1, "overflow refuses without dropping the admitted entry")
        #expect(Self.hasEffect(over.effects) {
            if case .emitUI(let p) = $0 { return p.kind == "denied" && p.detail.contains("budget") }
            return false
        }, "typed budget refusal")
        #expect(!Self.hasEffect(over.effects, where: Self.isProviderRequest), "zero provider requests")
    }

    // MARK: - Dispatch validation

    @Test("queued attachment entry requests validation instead of dispatching")
    func queuedEntryRequestsValidation() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let completed = transition(streaming, Self.finalResponse(run), &ids)
        #expect(Self.hasEffect(completed.effects) { Self.isValidationRequest($0, entryID: entryID) },
                "completion emits a validation request for the dwelled entry")
        #expect(!Self.hasEffect(completed.effects, where: Self.isProviderRequest),
                "no dispatch before evidence")
        #expect(completed.state.queue.first?.state == .queued, "entry untouched (not marked, not held)")
        #expect(!completed.state.queueHeld, "queue not held while validation is in flight")
    }

    @Test("fresh validation evidence dispatches with excerpts in the transcript")
    func validationFreshDispatches() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids)
        let validated = transition(
            requested.state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [Self.obs(of: snapshot)], atMillis: 1005),
            &ids)
        #expect(Self.hasEffect(validated.effects, where: Self.isProviderRequest), "fresh evidence dispatches")
        let links = validated.records.compactMap { record -> QueueDispatchLink? in
            if case .queueDispatched(let link) = record { return link }
            return nil
        }
        #expect(links.count == 1 && links[0].entryID == entryID, "dispatch commits the linkage")
        let users = validated.records.compactMap { record -> String? in
            if case .transcriptAppended(.user(let text)) = record { return text }
            return nil
        }
        #expect(users.contains(where: { $0.contains("hello") && $0.contains("notes/a.txt") }),
                "validated excerpts enter model context on dispatch")
    }

    @Test("byte change with unchanged size holds the head as stale")
    func byteChangeSameSizeStale() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        // A second plain entry queues behind the attachment entry.
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        state = transition(state, Self.inputWithAttachments("first", id: "cmd-first", attachments: [snapshot], at: 1003), &ids).state
        state = transition(state, StateFixtures.input("second", id: "cmd-2", at: 1004), &ids).state
        let headID = try #require(state.queue.first?.entryID)
        let requested = transition(state, Self.finalResponse(run), &ids)
        // Same size, different bytes: only the hash changes.
        var staleObs = Self.obs(of: snapshot)
        staleObs = AttachmentObservation(
            snapshotHash: staleObs.snapshotHash, device: staleObs.device,
            inode: staleObs.inode, size: staleObs.size, contentHash: "DIFFERENT",
            totalLines: staleObs.totalLines, readable: true)
        let held = transition(
            requested.state,
            .attachmentValidationResult(entryID: headID, requested: [snapshot],
                                        observations: [staleObs], atMillis: 1005),
            &ids)
        #expect(!Self.hasEffect(held.effects, where: Self.isProviderRequest), "stale head never dispatches")
        let head = try #require(held.state.queue.first(where: { $0.entryID == headID }))
        #expect(head.state == .held, "refused entry is marked held (external fixes must not auto-dispatch)")
        #expect(held.state.queueHeld, "queue holds")
        #expect(held.state.heldReason == HoldReason.staleAttachment, "first-assignment of the stale-attachment reason")
        let tail = try #require(held.state.queue.first(where: { $0.commandID == CommandID("cmd-2") }))
        #expect(tail.state == .queued, "the entry behind is preserved, not skipped")
        // The barrier re-trips: a later completion dispatches nothing.
        #expect(!held.state.queue.contains(where: { $0.state == .dispatched }),
                "no dispatch marking on the stale path")
    }

    @Test("replaced file, removed file, bad range and missing evidence all hold")
    func staleVariantsHold() throws {
        // Replaced (identity change).
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids)
        let replaced = transition(
            requested.state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [Self.obs(of: snapshot, inode: 999)], atMillis: 1005),
            &ids)
        #expect(replaced.state.heldReason == HoldReason.staleAttachment, "replacement holds as stale")
        #expect(!Self.hasEffect(replaced.effects, where: Self.isProviderRequest))

        // Removed (unreadable).
        var ids2 = StateFixtures.ids()
        let (streaming2, run2) = try Self.streamingWithAttachment(ids: &ids2, snapshot: Self.snap())
        let entryID2 = try #require(streaming2.queue.first?.entryID)
        let requested2 = transition(streaming2, Self.finalResponse(run2), &ids2)
        let removed = transition(
            requested2.state,
            .attachmentValidationResult(entryID: entryID2, requested: [Self.snap()],
                                        observations: [Self.obs(of: Self.snap(), readable: false, denyReason: "removed")], atMillis: 1005),
            &ids2)
        #expect(removed.state.heldReason == HoldReason.staleAttachment, "removal holds as stale")

        // Invalid range (file shrank below the selected range).
        var ids3 = StateFixtures.ids()
        let ranged = Self.snap(lines: 10, range: AttachmentLineRange(start: 1, end: 10))
        let (streaming3, run3) = try Self.streamingWithAttachment(ids: &ids3, snapshot: ranged)
        let entryID3 = try #require(streaming3.queue.first?.entryID)
        let requested3 = transition(streaming3, Self.finalResponse(run3), &ids3)
        let badRange = transition(
            requested3.state,
            .attachmentValidationResult(entryID: entryID3, requested: [ranged],
                                        observations: [Self.obs(of: ranged, lines: 4)], atMillis: 1005),
            &ids3)
        #expect(badRange.state.heldReason == HoldReason.staleAttachment, "invalid range holds as stale")

        // Missing evidence (uncomposed validator shape): fail-closed hold.
        var ids4 = StateFixtures.ids()
        let (streaming4, run4) = try Self.streamingWithAttachment(ids: &ids4, snapshot: Self.snap())
        let entryID4 = try #require(streaming4.queue.first?.entryID)
        let requested4 = transition(streaming4, Self.finalResponse(run4), &ids4)
        let missing = transition(
            requested4.state,
            .attachmentValidationResult(entryID: entryID4, requested: [Self.snap()],
                                        observations: [], atMillis: 1005),
            &ids4)
        #expect(missing.state.queueHeld, "missing evidence holds")
        #expect(missing.state.heldReason != .staleAttachment, "missing evidence is an error hold, not a file-stale hold")
        #expect(!Self.hasEffect(missing.effects, where: Self.isProviderRequest))
    }

    @Test("sealed entry carrying snapshots is held at dispatch (defense in depth)")
    func sealedEntryHeldAtDispatch() throws {
        // Admission refuses sealed attachments, so this state is only
        // reachable by hand — the dispatch gate must still hold it.
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        let snapshot = Self.snap()
        var queue = state.queue
        _ = queue
        let rogue = QueueEntry(
            entryID: "q-rogue", commandID: CommandID("cmd-rogue"), kind: .followUp,
            state: .queued, revision: 1, text: "rogue", targetEpochID: state.epoch.epochID,
            orderKey: 99, sealed: true,
            attachments: [snapshot], attachmentConsentEpoch: state.epoch.epochID)
        state = state.replacing(queue: [rogue])
        let requested = transition(state, Self.finalResponse(run), &ids)
        let held = transition(
            requested.state,
            .attachmentValidationResult(entryID: "q-rogue", requested: [snapshot],
                                        observations: [Self.obs(of: snapshot)], atMillis: 1005),
            &ids)
        #expect(held.state.queueHeld, "sealed entry with snapshots holds")
        #expect(!Self.hasEffect(held.effects, where: Self.isProviderRequest))
    }

    // MARK: - Replace / withdraw / supersede

    @Test("stale hold needs explicit replace plus resume before redispatch")
    func staleReplaceResumeRedispatch() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids)
        var staleObs = Self.obs(of: snapshot)
        staleObs = AttachmentObservation(
            snapshotHash: staleObs.snapshotHash, device: staleObs.device,
            inode: staleObs.inode, size: staleObs.size, contentHash: "CHANGED",
            totalLines: staleObs.totalLines, readable: true)
        var state = transition(
            requested.state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [staleObs], atMillis: 1005),
            &ids).state
        #expect(state.heldReason == HoldReason.staleAttachment)
        // Resume alone cannot clear a file-stale hold: the entry unholds,
        // but the next completion revalidates and re-holds (never silently
        // dispatches the changed file).
        state = transition(state, .queueResume(atMillis: 1006), &ids).state
        #expect(state.queue.first?.state == .queued, "resume unholds the entry")
        #expect(!state.queueHeld, "resume clears the hold")
        // A fresh run completes; the pop re-requests validation...
        state = transition(state, StateFixtures.input("run2", id: "cmd-2"), &ids).state
        let run2 = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run2.requestID, atMillis: 1007), &ids).state
        state = transition(state, .requestStarted(requestID: run2.requestID, generation: run2.revision, atMillis: 1008), &ids).state
        let rerequested = transition(state, Self.finalResponse(run2), &ids)
        #expect(Self.hasEffect(rerequested.effects) { Self.isValidationRequest($0, entryID: entryID) },
                "unfixed file revalidates instead of dispatching")
        // ...and stale evidence re-holds.
        state = transition(
            rerequested.state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [staleObs], atMillis: 1009),
            &ids).state
        #expect(state.heldReason == HoldReason.staleAttachment, "still stale, still held")
        // Explicit replace (fresh capture) preserves the held state...
        let fixed = Self.snap(hash: "CHANGED")
        state = transition(
            state, .queueAttachmentReplace(entryID: entryID, snapshots: [fixed], atMillis: 1010), &ids).state
        let replaced = try #require(state.queue.first(where: { $0.entryID == entryID }))
        #expect(replaced.state == .held, "replace alone never dispatches")
        #expect(replaced.attachments == [fixed], "snapshots replaced")
        // ...resume releases, and fresh validation of the new snapshot dispatches.
        state = transition(state, .queueResume(atMillis: 1011), &ids).state
        #expect(state.queue.first?.state == .queued)
        state = transition(state, StateFixtures.input("run3", id: "cmd-3"), &ids).state
        let run3 = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run3.requestID, atMillis: 1012), &ids).state
        state = transition(state, .requestStarted(requestID: run3.requestID, generation: run3.revision, atMillis: 1013), &ids).state
        let final = transition(state, Self.finalResponse(run3), &ids)
        let dispatched = transition(
            final.state,
            .attachmentValidationResult(entryID: entryID, requested: [fixed],
                                        observations: [Self.obs(of: fixed)], atMillis: 1014),
            &ids)
        #expect(Self.hasEffect(dispatched.effects, where: Self.isProviderRequest),
                "replaced + resumed + freshly validated dispatches")
    }

    @Test("withdraw before dispatch produces zero provider requests")
    func withdrawBeforeDispatchZeroProvider() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        var state = transition(streaming, .queueWithdraw(entryID: entryID, atMillis: 1004), &ids).state
        let tombstone = try #require(state.queue.first(where: { $0.entryID == entryID }))
        #expect(tombstone.state == .withdrawn, "withdrawn")
        #expect(tombstone.attachments == [snapshot], "provenance survives withdrawal")
        state = transition(state, Self.finalResponse(run), &ids).state
        #expect(!state.queue.contains(where: { $0.state == .dispatched }),
                "withdrawn entry never dispatches")
        #expect({ if case .completed = state.phase { return true }; return false }(),
                "run lands completed with an empty pop")
    }

    @Test("plain @path text without snapshots dispatches with no validation")
    func atMentionTextWithoutSnapshots() throws {
        var ids = StateFixtures.ids()
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        // Model/tool output shaped like a mention is just text: no
        // snapshot is minted from the string, so no validation gates it.
        state = transition(state, StateFixtures.input("see @notes/a.txt for details", id: "cmd-m"), &ids).state
        let entry = try #require(state.queue.first)
        #expect(entry.attachments.isEmpty, "text never becomes a snapshot")
        let completed = transition(state, Self.finalResponse(run), &ids)
        #expect(!Self.hasEffect(completed.effects) { if case .validateAttachments = $0 { return true }; return false },
                "snapshot-free entries never request validation")
        #expect(Self.hasEffect(completed.effects, where: Self.isProviderRequest), "normal dispatch")
    }

    @Test("metadata-only snapshot dispatches a manifest without bytes")
    func metadataOnlyDispatchesManifest() throws {
        var ids = StateFixtures.ids()
        let meta = AttachmentSnapshot(
            path: "bin/blob", grantedRoot: "workspace", device: 1, inode: 2,
            size: 1024, contentHash: "hb", lineRange: nil, totalLines: 0,
            content: .metadataOnly(reason: "non-UTF8 content: identity only"),
            captureEpochID: EpochID("epoch-1"),
            routeGrant: AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false),
            intent: "mention")
        // Fresh path: manifest composes, no excerpt travels.
        let idle = try StateFixtures.idle()
        let fresh = transition(idle, Self.inputWithAttachments("check this", attachments: [meta]), &ids)
        let users = fresh.records.compactMap { record -> String? in
            if case .transcriptAppended(.user(let text)) = record { return text }
            return nil
        }
        #expect(users[0].contains("bin/blob"), "manifest names the file")
        #expect(users[0].contains("non-UTF8 content"), "manifest carries the reason")
        #expect(!users[0].contains("excerpt"), "no excerpt bytes travel")
        // Queued path: identity/hash agreement dispatches.
        var ids2 = StateFixtures.ids()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids2, snapshot: meta)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids2)
        let dispatched = transition(
            requested.state,
            .attachmentValidationResult(entryID: entryID, requested: [meta],
                                        observations: [Self.obs(of: meta)], atMillis: 1005),
            &ids2)
        #expect(Self.hasEffect(dispatched.effects, where: Self.isProviderRequest),
                "metadata-only dispatches on fresh identity")
    }

    @Test("validation result after replace re-requests for current snapshots")
    func validationSupersededByReplace() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids)
        // Operator replaces while validation is in flight.
        var state = transition(
            requested.state,
            .queueAttachmentReplace(entryID: entryID, snapshots: [Self.snap(hash: "h2")], atMillis: 1005),
            &ids).state
        #expect(state.queue.first?.state == .queued, "replace preserves queued state")
        // Stale result (bound to the old snapshots) re-requests, never judges.
        state = transition(
            state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [Self.obs(of: snapshot)], atMillis: 1006),
            &ids).state
        #expect(!state.queueHeld, "superseded evidence holds nothing")
        #expect(state.queue.first?.state == .queued, "entry untouched")
    }

    @Test("validation result landing during a live run is dropped")
    func resultDuringActiveRunDrops() throws {
        var ids = StateFixtures.ids()
        let snapshot = Self.snap()
        let (streaming, run) = try Self.streamingWithAttachment(ids: &ids, snapshot: snapshot)
        let entryID = try #require(streaming.queue.first?.entryID)
        let requested = transition(streaming, Self.finalResponse(run), &ids)
        // A fresh submission starts a new run before the verdict lands.
        var state = transition(requested.state, StateFixtures.input("meanwhile", id: "cmd-x", at: 1005), &ids).state
        #expect(state.activeRun != nil, "new run admitted")
        let run2 = try #require(state.activeRun)
        state = transition(
            state,
            .attachmentValidationResult(entryID: entryID, requested: [snapshot],
                                        observations: [Self.obs(of: snapshot)], atMillis: 1006),
            &ids).state
        #expect(state.activeRun?.runID == run2.runID, "live run untouched by stale evidence")
        #expect(state.queue.first?.state == .queued, "entry still queued; next completion revalidates")
    }

    // MARK: - Prompt composition units

    @Test("composeDispatchText covers manifest, truncation and metadata")
    func composeDispatchTextUnits() {
        #expect(composeDispatchText(text: "hi", attachments: []) == "hi", "no attachments: byte-identical")
        let full = composeDispatchText(text: "t", attachments: [Self.snap()])
        #expect(full.contains("[attached file: notes/a.txt (12 bytes, sha256:ha, 3 lines, captured mention]"))
        #expect(full.contains("(excerpt: complete file content shown)"))
        let trunc = composeDispatchText(
            text: "t", attachments: [Self.snap(size: 9000, excerpt: String(repeating: "x", count: 4096), truncated: true)])
        #expect(trunc.contains("first 4096 of 9000 bytes shown; full content NOT included — use the read tool for more"))
        let ranged = composeDispatchText(
            text: "t", attachments: [Self.snap(lines: 9, range: AttachmentLineRange(start: 2, end: 3))])
        #expect(ranged.contains("lines 2-3 of 9"))
        let meta = composeDispatchText(text: "t", attachments: [
            AttachmentSnapshot(
                path: "b", grantedRoot: "workspace", device: 1, inode: 2, size: 8,
                contentHash: "h", lineRange: nil, totalLines: 0,
                content: .metadataOnly(reason: "non-UTF8 content: identity only"),
                captureEpochID: EpochID("e"), routeGrant: AttachmentRouteGrant(alias: "a", locality: .local, sealed: false),
                intent: "mention")])
        #expect(meta.contains("no bytes included: non-UTF8 content: identity only — use the read tool for content"))
    }

    @Test("validation result for a non-head entry validates the head instead")
    func validationResultForNonHeadValidatesHead() throws {
        // Defensive branch: queue order cannot change while validation is
        // in flight (no dispatch without a run), so the head at result
        // time is normally the requested entry. Hand-build the skewed
        // state to pin the fail-safe direction: evidence for a trailing
        // entry must validate the head, never judge by it.
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let followSnap = Self.snap(path: "notes/f.txt", hash: "hf")
        let steerSnap = Self.snap(path: "notes/s.txt", hash: "hs")
        func entry(_ id: String, kind: QueueKind, snap: AttachmentSnapshot) -> QueueEntry {
            QueueEntry(
                entryID: id, commandID: CommandID("cmd-\(id)"), kind: kind,
                state: .queued, revision: 1, text: id, targetEpochID: idle.epoch.epochID,
                orderKey: 1, sealed: false,
                attachments: [snap], attachmentConsentEpoch: idle.epoch.epochID)
        }
        let state = idle.replacing(
            phase: .completed(RunReceipt(
                runID: RunID("r-0"), completedAtMillis: 999,
                turnsUsed: 0, toolCallCount: 0)),
            queue: [entry("q-steer", kind: .steer, snap: steerSnap),
                    entry("q-follow", kind: .followUp, snap: followSnap)])
        // The follow-up's verdict arrives: the pop selects the steer head,
        // so the transition re-requests validation for the steer.
        let result = transition(
            state,
            .attachmentValidationResult(entryID: "q-follow", requested: [followSnap],
                                        observations: [Self.obs(of: followSnap)], atMillis: 1005),
            &ids)
        #expect(Self.hasEffect(result.effects) { Self.isValidationRequest($0, entryID: "q-steer") },
                "head steer revalidated, follow-up evidence not misapplied")
        #expect(!Self.hasEffect(result.effects, where: Self.isProviderRequest), "no dispatch on a superseded verdict")
        #expect(!result.state.queueHeld, "re-request holds nothing")
        // The steer's fresh verdict dispatches the steer first (kind order).
        let dispatched = transition(
            result.state,
            .attachmentValidationResult(entryID: "q-steer", requested: [steerSnap],
                                        observations: [Self.obs(of: steerSnap)], atMillis: 1006),
            &ids)
        #expect(Self.hasEffect(dispatched.effects, where: Self.isProviderRequest), "steer dispatches first")
        let dispatchedID = dispatched.state.queue.first(where: { $0.state == .admittedToHistory })?.entryID
        #expect(dispatchedID == "q-steer", "strict kind order preserved under validation")
    }

    // MARK: - Epoch / consent

    static let twoProfileJSON = """
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434","http://127.0.0.1:11435"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1},{"alias":"second","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11435","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true}}
        """

    @Test("epoch switch holds attachments until explicit retarget re-consents")
    func epochSwitchRequiresRetarget() throws {
        var ids = StateFixtures.ids()
        let snapshot = try Self.twoProfileSnapshot()
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-1"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"))
        var state = SessionState(sessionID: SessionID("s-1"), epoch: epoch, trustMode: .workspace, phase: .idle)
        // Busy the session and queue an attachment entry (capture epoch-1).
        state = transition(state, StateFixtures.input("run"), &ids).state
        let run1 = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run1.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run1.requestID, generation: run1.revision, atMillis: 1002), &ids).state
        let snap = Self.snap(epoch: "epoch-1")
        state = transition(state, Self.inputWithAttachments("q", id: "cmd-q", attachments: [snap], at: 1003), &ids).state
        let entryID = try #require(state.queue.first?.entryID)
        // Complete run 1 (validation requested, left unanswered), dismiss,
        // then switch epochs: the entry holds as a stale target.
        state = transition(state, Self.finalResponse(run1), &ids).state
        state = transition(state, .dismissRun(atMillis: 1005), &ids).state
        state = transition(state, .switchModel(alias: "second", atMillis: 1006), &ids).state
        #expect(state.epoch.profile.alias == "second", "epoch switched")
        #expect(state.queue.first?.state == .held, "stale-target entry held")
        #expect(state.queueHeld, "queue holds after epoch switch")
        // Retarget alone re-consents but releases nothing.
        state = transition(state, .queueRetarget(entryID: entryID, atMillis: 1007), &ids).state
        let retargeted = try #require(state.queue.first(where: { $0.entryID == entryID }))
        #expect(retargeted.targetEpochID == state.epoch.epochID, "retarget binds the new epoch")
        #expect(retargeted.attachmentConsentEpoch == state.epoch.epochID, "retarget refreshes attachment consent")
        #expect(retargeted.state == .held, "retarget does not release the hold")
        #expect(retargeted.attachments == [snap], "retarget never touches snapshots")
        // Resume releases; the next completion revalidates under epoch-2.
        state = transition(state, .queueResume(atMillis: 1008), &ids).state
        #expect(state.queue.first?.state == .queued, "resume unholds the re-consented entry")
        state = transition(state, StateFixtures.input("run2", id: "cmd-2"), &ids).state
        let run2 = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run2.requestID, atMillis: 1009), &ids).state
        state = transition(state, .requestStarted(requestID: run2.requestID, generation: run2.revision, atMillis: 1010), &ids).state
        let requested = transition(state, Self.finalResponse(run2), &ids)
        #expect(Self.hasEffect(requested.effects) { Self.isValidationRequest($0, entryID: entryID) },
                "re-consented entry revalidates instead of dispatching blind")
        let dispatched = transition(
            requested.state,
            .attachmentValidationResult(entryID: entryID, requested: [snap],
                                        observations: [Self.obs(of: snap)], atMillis: 1011),
            &ids)
        #expect(Self.hasEffect(dispatched.effects, where: Self.isProviderRequest),
                "consent epoch == live epoch dispatches after fresh validation")
    }

    @Test("resume without retarget keeps epoch-stale entries held")
    func resumeWithoutRetargetStaysHeld() throws {
        var ids = StateFixtures.ids()
        let snapshot = try Self.twoProfileSnapshot()
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-1"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"))
        var state = SessionState(sessionID: SessionID("s-1"), epoch: epoch, trustMode: .workspace, phase: .idle)
        state = transition(state, StateFixtures.input("run"), &ids).state
        let run1 = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run1.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run1.requestID, generation: run1.revision, atMillis: 1002), &ids).state
        state = transition(state, Self.inputWithAttachments("q", id: "cmd-q", attachments: [Self.snap(epoch: "epoch-1")], at: 1003), &ids).state
        state = transition(state, Self.finalResponse(run1), &ids).state
        state = transition(state, .dismissRun(atMillis: 1005), &ids).state
        state = transition(state, .switchModel(alias: "second", atMillis: 1006), &ids).state
        // Resume WITHOUT retarget: the stale-target entry stays held and
        // the queue stays held — no silent carryover.
        state = transition(state, .queueResume(atMillis: 1007), &ids).state
        #expect(state.queue.first?.state == .held, "no retarget, no release")
        #expect(state.queueHeld, "queue stays held")
    }

    static func twoProfileSnapshot() throws -> ConfigSnapshot {
        try validateConfig(Data(twoProfileJSON.utf8))
    }
}
