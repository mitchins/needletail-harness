import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal
@testable import NeedletailLineEditor

/// C5.1/C5.8 loop legs (scripted input — no TTY, no input thread):
/// submit→effect translation, draft/cursor preservation across
/// streaming output, no duplicate operator submission, confirm flow.
struct ChatLoopTests {
    private func ownerCaps() -> TerminalCaps {
        TerminalCaps(color: false, cursorAddressing: false, width: 80)
    }

    @Test("scripted submit translates to exact-sync + submit effects (C5.8)")
    func scriptedSubmit() async {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        await loop.run(scriptedInput: ["hello", nil])
        let fx = await effects.all()
        guard fx.count == 1 else {
            Issue.record("expected 1 effect batch, got \(fx.count)")
            owner.close()
            return
        }
        #expect(fx[0] == [.submit(OperatorInput(text: "hello", commandID: CommandID("cmd-1")))])
        owner.close()
    }

    @Test("same text resubmitted mints a distinct command ID per Enter (no silent no-op)")
    func retryReusesID() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let n = LockedValue(0)
        let turnDone = LockedValue(false)
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { var id = 0; n.mutate { $0 += 1; id = $0 }; return CommandID("cmd-\(id)") },
            onTurnFinished: { turnDone.set(true) })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        // First submit marks busy optimistically (M4-D D2: closes the
        // submit-to-first-projection Ctrl+C window); a terminal
        // projection returns to idle; the resubmit then dispatches a
        // SECOND genuine turn with a FRESH command ID (M4-D residual
        // fix — same-ID reuse made Core replay the prior admission
        // without dispatching).
        let task = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        loop.post(.inputLine("same"))
        #expect(await waitFor(marker: "same", in: written, timeout: 5), "submit never dispatched")
        // Drive the terminal transition directly: admitted then completed.
        loop.post(.projection(.admitted(commandID: CommandID("cmd-1"), revision: 1)))
        loop.post(.projection(.runUpdate(phase: "completed", detail: "done")))
        // Readiness, not sleep: the terminal projection retires the
        // turn (fires onTurnFinished) before the resubmit may proceed —
        // posts are FIFO, but the resubmit's effect shape depends on
        // the loop having retired to idle first.
        #expect(await waitForFlag(turnDone, timeout: 5), "terminal projection never retired the turn")
        loop.post(.inputLine("same"))
        #expect(await waitForEffects(2, in: effects, timeout: 5), "resubmit never dispatched")
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        let fx = await effects.all()
        // Guard BEFORE indexing: #expect records but does not return,
        // and indexing a short array traps (ud2/SIGILL), killing the
        // whole runner binary. A short batch list is a clean failure,
        // never a crash.
        guard fx.count == 2 else {
            Issue.record("expected 2 effect batches, got \(fx.count)")
            owner.close()
            return
        }
        // Two explicit submissions carry DISTINCT command IDs: each
        // Enter is a genuine admission (Core same-ID idempotency only
        // replays true retries, which reuse the minted ID below this
        // layer — never through the store).
        #expect(fx[0] != fx[1])
        #expect(fx[0] == [.submit(OperatorInput(text: "same", commandID: CommandID("cmd-1")))])
        #expect(fx[1] == [.submit(OperatorInput(text: "same", commandID: CommandID("cmd-2")))])
        owner.close()
    }

    @Test("Tab accepts the live suggestion into a token; second Tab is a no-op (M4-D D2)")
    func tabAcceptsSuggestion() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                       heldReason: nil, pendingApproval: nil,
                                       admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let task = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        // Type a mention query; the edge fetch is simulated by posting
        // completions (the reducer fills the suggestion popup).
        loop.post(.mirror(text: "@e", cursor: 2))
        #expect(await waitForEffects(1, in: effects, timeout: 5), "mirror never dispatched")
        loop.post(.completions(query: "e", revision: 1, candidates: [
            CandidateFile(path: "ok.swift"),
            CandidateFile(path: "ev\u{1B}.swift"),
        ]))
        // Gate open on the safe selected candidate (hostile entries never
        // gate acceptance of the selected one) — the gate opening proves
        // the completions were handled.
        guard await waitForSnapshot(loop, timeout: 5),
              let snap = loop.acceptSnapshot() else {
            Issue.record("accept gate must open on a live safe suggestion")
            loop.post(.inputLine(nil))
            _ = await join(task: task, timeout: 5)
            owner.close()
            return
        }
        loop.post(.tabAccept(base: snap.base, display: snap.display, cursor: snap.cursor))
        // tabAccept handled ⟺ gate closed (it was open above).
        let closeDeadline = Date().addingTimeInterval(5)
        while loop.acceptSnapshot() != nil, Date() < closeDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Consumed: suggestion cleared, gate closed, token minted (the
        // attach composition test proves the token captures).
        #expect(loop.acceptSnapshot() == nil, "second Tab must be a no-op after accept")
        // Selection keys with no suggestion are safe no-ops.
        loop.post(.key(.up))
        loop.post(.key(.down))
        // Barrier: nil shuts the loop (FIFO — keys handled first); the
        // join proves processing, then the run ends cleanly.
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        owner.close()
    }

    @Test("Tab with no suggestion and arrows without popup are no-ops (M4-D D2)")
    func tabArrowsNoopWithoutSuggestion() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                       heldReason: nil, pendingApproval: nil,
                                       admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        #expect(loop.acceptSnapshot() == nil, "no suggestion ⇒ closed gate")
        let task = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        loop.post(.key(.tab))
        loop.post(.key(.up))
        loop.post(.key(.down))
        // Barrier: nil shuts the loop (FIFO — keys handled first); the
        // join proves processing, then the negative assertion is sound.
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        #expect(await effects.all().isEmpty, "no-op keys must emit no effects")
        owner.close()
    }

    @Test("confirm flow consumes the decision line; follow-up submits clean")
    func confirmFlow() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        // Drive the gateway path: presenter arms the loop with the
        // shared box. The run MUST be live before deciding (production
        // invariant: the loop starts before any actor work, so the
        // inbox exists when the presenter posts).
        let runTask = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        let gateway = ReplxxApprovalGateway { req, box in
            loop.prepareConfirm(box: box)
            loop.post(.approvalArmed(req))
        }
        let req = ApprovalRequest(requestID: RequestID("r"), runID: RunID("r"), generation: Revision(1),
                                  operation: "op", requiredGrant: "read")
        async let decision = gateway.decide(req)
        // Inbox FIFO: approvalArmed is handled (prompt rendered, draft
        // snapshotted) before the answer below is processed. The prompt
        // rendering proves the arm was handled — readiness, not sleep.
        #expect(await waitFor(marker: "approval required:", in: written, timeout: 5),
            "actionable prompt never rendered")
        loop.post(.inputLine("y"))
        // FIFO: the decision line is consumed before the follow-up below;
        // no sleep needed between ordered posts.
        // The follow-up line proves the mirror reset (not polluted by y).
        loop.post(.inputLine("second"))
        #expect(await waitForEffects(1, in: effects, timeout: 5), "follow-up never dispatched")
        loop.post(.inputLine(nil))
        #expect(await join(task: runTask, timeout: 5), "loop did not exit")
        let final = await decision
        #expect(final == .approve)
        // The decision line was consumed as a confirm, not a submit:
        // exactly one submit (for "second") was produced — never a
        // submit of "y", never a polluted draft.
        let fx = await effects.all()
        guard fx.count == 1 else {
            Issue.record("expected 1 effect batch, got \(fx.count)")
            owner.close()
            return
        }
        #expect(fx[0] == [.submit(OperatorInput(text: "second", commandID: CommandID("cmd-1")))])
        owner.close()
    }

    @Test("stale confirm arm submits the line normally, no hygiene warning")
    func staleArmSubmitsNormally() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let runTask = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        // Arm, then settle the box actor-side: cancellation wins the race
        // against the operator's answer (the production stale-arm shape).
        let box = ContinuationBox()
        loop.prepareConfirm(box: box)
        box.resumeDeny()
        // The late decision line takes the stale path: a normal submit,
        // never a confirm consumption, never a hygiene warning (the
        // scripted path owns no live history to drop).
        loop.post(.inputLine("y"))
        #expect(await waitForEffects(1, in: effects, timeout: 5), "stale line never dispatched")
        let fx = effects.all()
        loop.post(.inputLine(nil))
        #expect(await join(task: runTask, timeout: 5), "loop did not exit")
        #expect(!written.joined().contains("confirm hygiene"), "no spurious hygiene warning on the scripted path")
        #expect(fx == [[.submit(OperatorInput(text: "y", commandID: CommandID("cmd-1")))]], "stale line submits normally")
        owner.close()
    }

    @Test("idle-empty Ctrl+C exits the run (M4-D D2.5)")
    func idleEmptyCtrlCExits() async throws {
        let written = LockedBox()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false, heldReason: nil, pendingApproval: nil, admittedCommandIDs: [], liveEpoch: EpochID("e")) },
            onEffects: { _ in },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let runTask = Task { await loop.run(scriptedInput: []) }
        // Readiness: the initial frame must exist before the key post
        // (posts before the inbox exists drop).
        let ready = await waitFor(marker: "idle", in: written, timeout: 5)
        #expect(ready, "loop never rendered initial frame")
        loop.post(.key(.ctrlC))
        // Bounded join: a failed exit must fail the test, never hang it.
        let exited = await join(task: runTask, timeout: 5)
        #expect(exited, "idle-empty Ctrl+C did not shut the run down")
        owner.close()
    }

    @Test("idle-empty Ctrl+C with queued work warns once, exits twice (M4-D D2.5)")
    func queuedCtrlCWarnsThenExits() async throws {
        let written = LockedBox()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let entry = QueueEntry(
            entryID: "e1", commandID: CommandID("c1"), kind: .followUp,
            state: .queued, revision: 1, text: "pending", targetEpochID: EpochID("e"),
            orderKey: 1, rank: 1.0)
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { QueueSyncSnapshot(entries: [entry], activeRequest: nil, queueHeld: true, heldReason: nil, pendingApproval: nil, admittedCommandIDs: [], liveEpoch: EpochID("e")) },
            onEffects: { _ in },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let runTask = Task { await loop.run(scriptedInput: []) }
        // Readiness: the queue row (kind + state) renders in the
        // initial frame (status is not idle with a held queue).
        #expect(await waitFor(marker: "followUp queued", in: written, timeout: 5), "loop never rendered initial frame")
        loop.post(.key(.ctrlC))
        #expect(await waitFor(marker: "queued work pending", in: written, timeout: 5), "first Ctrl+C must warn, not exit")
        // Any other input disarms the latch: typing clears it.
        loop.post(.inputLine("hello"))
        _ = await waitFor(marker: "hello", in: written, timeout: 5)
        loop.post(.key(.ctrlC))
        #expect(await waitFor(marker: "queued work pending", in: written, timeout: 5), "latch must disarm on other input")
        // Second consecutive press exits.
        loop.post(.key(.ctrlC))
        let exited = await join(task: runTask, timeout: 5)
        #expect(exited, "second Ctrl+C did not shut the run down")
        owner.close()
    }

    private func waitFor(marker: String, in box: LockedBox, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.joined().contains(marker) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Effect-batch readiness: posts are FIFO, so reaching `count`
    /// batches proves every event posted before the last dispatch was
    /// handled (a blind sleep proves nothing on a slow runner).
    private func waitForEffects(_ count: Int, in effects: LockedEffects, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if effects.all().count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return effects.all().count >= count
    }

    /// Accept-gate readiness: polls the lock-published snapshot (the
    /// input thread's own cross-thread read — safe to poll here).
    private func waitForSnapshot(_ loop: ChatLoop, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loop.acceptSnapshot() != nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return loop.acceptSnapshot() != nil
    }

    private func waitForFlag(_ flag: LockedValue<Bool>, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if flag.get() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return flag.get()
    }

    private func join(task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var done = false
        }
        let flag = Flag()
        Task {
            await task.value
            flag.lock.withLock { flag.done = true }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if flag.lock.withLock({ flag.done }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test("turn-terminal projection set: terminal phases retire, hints and denials do not (M4-D D1 + D7 review B4)")
    func turnTerminalSet() {
        #expect(ChatLoop.isTurnTerminal(.runFinished(outcome: "completed", detail: "d")), "run_finished must retire")
        // `denied` is NOT terminal (D7 review B4): Core emits denials
        // for non-terminal mid-run refusals (queue ops while busy,
        // stale revisions, unquiescent undo, reconcile blocks —
        // SessionTransition emits `.emitUI(.denied)` from ~20 such
        // sites). Retiring on them would drop in-flight commits, hide
        // progress, and fire the turn hook for a turn that never
        // ended.
        #expect(!ChatLoop.isTurnTerminal(.denied(cause: "c")), "denied must not retire (mid-run refusals are not outcomes)")
        for phase in ["completed", "failed", "interrupted", "budget-boundary"] {
            #expect(ChatLoop.isTurnTerminal(.runUpdate(phase: phase, detail: "d")), "run:\(phase) must retire")
        }
        for phase in ["queue", "model", "epoch", "tool-exec", "undo", "authorising", "cancelling"] {
            #expect(!ChatLoop.isTurnTerminal(.runUpdate(phase: phase, detail: "d")), "run:\(phase) must not retire")
        }
        #expect(!ChatLoop.isTurnTerminal(.delta(requestID: RequestID("r"), text: "t")), "delta must not retire")
        #expect(!ChatLoop.isTurnTerminal(.admitted(commandID: CommandID("c"), revision: 1)), "admitted must not retire")
        #expect(!ChatLoop.isTurnTerminal(.agent(alias: "a", locality: "l", phase: "p")), "agent must not retire")
    }

    @Test("confirm-armed paste denies fail-closed; draft preserved; no auto-confirm (M4-D D2)")
    func confirmArmedPasteDenies() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                       heldReason: nil, pendingApproval: nil,
                                       admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let runTask = Task { await loop.run(scriptedInput: []) }
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        let gateway = ReplxxApprovalGateway { req, box in
            loop.prepareConfirm(box: box)
            loop.post(.approvalArmed(req))
        }
        let req = ApprovalRequest(requestID: RequestID("r"), runID: RunID("r"), generation: Revision(1),
                                  operation: "op", requiredGrant: "read")
        async let decision = gateway.decide(req)
        #expect(await waitFor(marker: "approval required:", in: written, timeout: 5),
            "actionable prompt never rendered")
        // A pasted multi-line block arrives as one line (bracketed paste
        // collapses to the readLine result): not y/yes ⇒ deny, never
        // auto-confirm, never submit. `await decision` below suspends
        // until the paste line is consumed — it IS the readiness wait.
        loop.post(.inputLine("pasted line one\nrm -rf /\nline three"))
        let final = await decision
        #expect(final == .deny("operator did not explicitly approve"), "armed paste must deny fail-closed, got \(final)")
        // Draft mirror restored; follow-up submits cleanly.
        loop.post(.inputLine("second"))
        #expect(await waitForEffects(1, in: effects, timeout: 5), "follow-up never dispatched")
        loop.post(.inputLine(nil))
        #expect(await join(task: runTask, timeout: 5), "loop did not exit")
        let fx = await effects.all()
        guard fx.count == 1 else {
            Issue.record("only the follow-up submits, got \(fx.count) effect batches")
            owner.close()
            return
        }
        #expect(fx[0] == [.submit(OperatorInput(text: "second", commandID: CommandID("cmd-1")))])
        owner.close()
    }

    @Test("request-scoped finalize: unknown completions drop (C5.5)")
    func staleGate() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        // No nil terminator: the run stays alive for posted events.
        let task = Task { await loop.run(scriptedInput: ["hi"]) }
        #expect(await waitFor(marker: "hi", in: written, timeout: 5), "scripted submit never rendered")
        // Live request: progress registers, completion commits.
        loop.post(.tapProgress(RequestID("a"), 10))
        loop.post(.tapComplete(RequestID("a"), Revision(1), "# Done"))
        // Unknown request (never progressed, e.g. cancelled): drops.
        loop.post(.tapComplete(RequestID("zzz"), Revision(9), "# Ghost"))
        // Barrier: nil shuts the loop (FIFO — taps handled first); the
        // join proves processing, then the negative assertion is sound.
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        let out = written.joined()
        #expect(out.contains("Done"))
        #expect(!out.contains("Ghost"))
        owner.close()
    }

    @Test("out-of-order completions drop below the committed revision")
    func revisionGate() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let task = Task { await loop.run(scriptedInput: ["hi"]) }
        #expect(await waitFor(marker: "hi", in: written, timeout: 5), "scripted submit never rendered")
        loop.post(.tapProgress(RequestID("a"), 10))
        loop.post(.tapComplete(RequestID("a"), Revision(3), "# Third"))
        // Late straggler for an older revision of the same request.
        loop.post(.tapProgress(RequestID("a"), 11))
        loop.post(.tapComplete(RequestID("a"), Revision(1), "# First"))
        // Barrier: nil shuts the loop (FIFO — taps handled first); the
        // join proves processing, then the negative assertion is sound.
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        let out = written.joined()
        #expect(out.contains("Third"))
        #expect(!out.contains("First"))
        owner.close()
    }
}

final class LockedEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UIEffect]] = []
    func append(_ fx: [UIEffect]) async { lock.withLock { items.append(fx) } }
    func all() -> [[UIEffect]] {
        // The loop already terminated (scripted EOF), so no race.
        lock.withLock { items }
    }
}
