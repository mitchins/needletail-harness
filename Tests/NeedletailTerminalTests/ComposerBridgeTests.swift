import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal

/// C5.8/C5.5/C3: submit/key/slash mapping. Includes the negative
/// assertion that the interactive action map NEVER produces
/// `.decideApproval` (single-owner approval: gateway path only).
struct ComposerBridgeTests {
    private func idleState() -> UIState { UIState() }
    private func busyState() -> UIState { UIState(status: .busy(operation: "streaming")) }
    private var commandID: CommandID { CommandID("cmd-1") }

    @Test("idle submit exact-syncs then submits")
    func idleSubmit() {
        let outcome = ComposerBridge.actionsForSubmitLine("hello", state: idleState(), commandID: commandID)
        guard case .actions(let actions) = outcome else { Issue.record("expected actions"); return }
        #expect(actions == [
            .input(.replaceDraft("hello")),
            .input(.submitDraft(commandID: commandID)),
        ])
    }

    @Test("busy submit queues follow-up and clears mirror (SPEC 744)")
    func busyFollowUp() {
        let outcome = ComposerBridge.actionsForSubmitLine("later", state: busyState(), commandID: commandID)
        guard case .actions(let actions) = outcome else { Issue.record("expected actions"); return }
        #expect(actions == [
            .queueOp(.submitFollowUp(text: "later", commandID: commandID)),
            .input(.replaceDraft("")),
        ])
    }

    @Test("over-cap line rejected on both branches, buffer preserved")
    func overCapRejected() {
        let big = String(repeating: "x", count: maxComposerBytes + 1)
        for state in [idleState(), busyState()] {
            let outcome = ComposerBridge.actionsForSubmitLine(big, state: state, commandID: commandID)
            guard case .rejected(let reason) = outcome else { Issue.record("expected reject"); return }
            #expect(reason.contains("64 KiB"))
        }
    }

    @Test("ctrlC decision matrix: armed clears, busy cancels, idle-empty exits or warns (M4-D D2.5)")
    func ctrlCMatrix() {
        // Armed confirm: clear even mid-run (cancelling would deny the
        // pending request the prompt asks about).
        #expect(ComposerBridge.ctrlCAction(busy: true, armed: true, draftNonEmpty: true, queuePending: true, exitArmed: false) == .clearBuffer)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: true, draftNonEmpty: false, queuePending: false, exitArmed: false) == .clearBuffer)
        #expect(ComposerBridge.ctrlCAction(busy: true, armed: false, draftNonEmpty: true, queuePending: false, exitArmed: false) == .cancelRun)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: true, queuePending: false, exitArmed: false) == .clearBuffer)
        // Idle-empty: exit when nothing pending; warn once then exit
        // when queued work exists (two-press latch).
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: false, queuePending: false, exitArmed: false) == .exit)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: false, queuePending: false, exitArmed: true) == .exit)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: false, queuePending: true, exitArmed: false) == .warnPending)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: false, queuePending: true, exitArmed: true) == .exit)
    }

    @Test("key map: ctrlC is loop-owned; ctrlJ/esc dispatch")
    func keyMap() {
        // Ctrl+C is decided by the loop (latch-aware ctrlCAction), not
        // the pure key map — the map returns nothing for it.
        #expect(ComposerBridge.actionsForKey(.ctrlC, state: busyState()) == [])
        #expect(ComposerBridge.actionsForKey(.ctrlC, state: idleState()) == [])
        #expect(ComposerBridge.pendingExitWarning.contains("Ctrl+C"))
        #expect(ComposerBridge.actionsForKey(.ctrlJ, state: idleState()) == [.input(.newline)])
        // Esc always dispatches dismiss (reducer noops with no popup).
        #expect(ComposerBridge.actionsForKey(.esc, state: idleState()) == [.mention(.dismissSuggestion)])
        let suggesting = UIState(suggestion: MentionSuggestionState(query: "@a", revision: 1))
        #expect(ComposerBridge.actionsForKey(.esc, state: suggesting) == [.mention(.dismissSuggestion)])
    }

    @Test("queue subcommands map indices to entry IDs (M4-D D2)")
    func queueSubcommands() {
        let cid = CommandID("q-sub")
        func queuedState() -> UIState {
            var s = UIState()
            s.queue = [
                QueueSummary(entryID: "e1", commandID: cid, kind: "followUp", state: "held", revision: 3, delivery: .queued, pending: false, isOptimistic: false, staleTarget: false, hasAttachments: false),
                QueueSummary(entryID: "e2", commandID: cid, kind: "steer", state: "held", revision: 5, delivery: .queued, pending: false, isOptimistic: false, staleTarget: false, hasAttachments: false),
            ]
            return s
        }
        let qs = queuedState()
        // resume
        guard case .actions(let resume) = ComposerBridge.actionsForSubmitLine("/queue resume", state: qs, commandID: cid) else {
            Issue.record("resume must produce actions"); return
        }
        #expect(resume.contains(.queueOp(.resumeQueue)))
        // withdraw maps 1-based index → entry ID
        guard case .actions(let wd) = ComposerBridge.actionsForSubmitLine("/queue withdraw 2", state: qs, commandID: cid) else {
            Issue.record("withdraw must produce actions"); return
        }
        #expect(wd.contains(.queueOp(.withdrawEntry(entryID: "e2"))))
        // edit carries text + base revision
        guard case .actions(let ed) = ComposerBridge.actionsForSubmitLine("/queue edit 1 new text here", state: qs, commandID: cid) else {
            Issue.record("edit must produce actions"); return
        }
        #expect(ed.contains(.queueOp(.editEntry(entryID: "e1", newText: "new text here", baseRevision: 3))))
        // reorder before m
        guard case .actions(let ro) = ComposerBridge.actionsForSubmitLine("/queue reorder 2 before 1", state: qs, commandID: cid) else {
            Issue.record("reorder must produce actions"); return
        }
        #expect(ro.contains(.queueOp(.reorderEntry(entryID: "e2", beforeID: "e1"))))
        // reorder bare moves to head (anchors before the first live entry)
        guard case .actions(let roTop) = ComposerBridge.actionsForSubmitLine("/queue reorder 2", state: qs, commandID: cid) else {
            Issue.record("bare reorder must produce actions"); return
        }
        #expect(roTop.contains(.queueOp(.reorderEntry(entryID: "e2", beforeID: "e1"))))
        // unknown indices are usage notices, never actions
        guard case .notice = ComposerBridge.actionsForSubmitLine("/queue withdraw 9", state: qs, commandID: cid) else {
            Issue.record("out-of-range index must be a usage notice"); return
        }
        guard case .notice = ComposerBridge.actionsForSubmitLine("/queue edit 0 x", state: qs, commandID: cid) else {
            Issue.record("zero index must be a usage notice"); return
        }
        guard case .notice = ComposerBridge.actionsForSubmitLine("/queue frobnicate", state: qs, commandID: cid) else {
            Issue.record("unknown subcommand must be a usage notice"); return
        }
        // empty queue: indices unusable
        guard case .notice = ComposerBridge.actionsForSubmitLine("/queue withdraw 1", state: idleState(), commandID: cid) else {
            Issue.record("empty-queue withdraw must be a usage notice"); return
        }
    }

    @Test("slash commands map to existing vocabulary")
    func slashMap() {
        let cid = commandID
        let steer = ComposerBridge.actionsForSubmitLine("/steer fix it", state: idleState(), commandID: cid)
        guard case .actions(let a1) = steer else { Issue.record("steer"); return }
        #expect(a1 == [.queueOp(.submitSteer(text: "fix it", commandID: cid)), .input(.replaceDraft(""))])

        let queue = ComposerBridge.actionsForSubmitLine("/queue", state: idleState(), commandID: cid)
        guard case .actions(let a2) = queue else { Issue.record("queue"); return }
        #expect(a2 == [.inspect(.queue), .input(.replaceDraft(""))])

        let undo = ComposerBridge.actionsForSubmitLine("/undo g-1", state: idleState(), commandID: cid)
        guard case .actions(let a3) = undo else { Issue.record("undo"); return }
        #expect(a3 == [.undoIntent(.preview(groupID: "g-1")), .input(.replaceDraft(""))])

        let rewind = ComposerBridge.actionsForSubmitLine("/rewind epoch-9#42", state: idleState(), commandID: cid)
        guard case .actions(let a4) = rewind else { Issue.record("rewind"); return }
        #expect(a4 == [.rewindRequest(boundary: LineageBoundary(epochID: EpochID("epoch-9"), throughSequence: 42)), .input(.replaceDraft(""))])

        let cancel = ComposerBridge.actionsForSubmitLine("/cancel", state: idleState(), commandID: cid)
        guard case .actions(let a5) = cancel else { Issue.record("cancel"); return }
        #expect(a5 == [.queueOp(.cancelRun), .input(.replaceDraft(""))])
    }

    @Test("slash errors and deferrals are explicit notices")
    func slashEdge() {
        let cid = commandID
        for cmd in ["/", "/steer", "/rewind nope", "/bogus q"] {
            let outcome = ComposerBridge.actionsForSubmitLine(cmd, state: idleState(), commandID: cid)
            switch outcome {
            case .notice(let text, let actions):
                #expect(!text.isEmpty)
                #expect(actions == [.input(.replaceDraft(""))])
            case .actions:
                Issue.record("unexpected actions for \(cmd)")
            case .rejected:
                Issue.record("unexpected reject for \(cmd)")
            }
        }
        // /queue with an unknown subcommand is a usage notice, never silent.
        guard case .notice = ComposerBridge.actionsForSubmitLine("/queue frobnicate", state: idleState(), commandID: cid) else {
            Issue.record("/queue frobnicate must be a usage notice"); return
        }
    }

    @Test("mirror diff converges exactly (typing, mid-edit, backspace, paste)")
    func mirrorDiff() {
        let base = UIState(composer: ComposerState(text: "axc", cursor: 2, revision: 5))
        // Convergent: equal states ⇒ no actions.
        #expect(ComposerBridge.actionsForMirror(text: "axc", cursor: 2, state: base) == [])
        // Mid-text replace x→b.
        #expect(ComposerBridge.actionsForMirror(text: "abc", cursor: 2, state: base)
            == [.input(.deleteBackward(1)), .input(.insertText("b"))])
        // Typing at end.
        let end = UIState(composer: ComposerState(text: "ab", cursor: 2, revision: 5))
        #expect(ComposerBridge.actionsForMirror(text: "abc", cursor: 3, state: end) == [.input(.insertText("c"))])
        // Backspace.
        let full = UIState(composer: ComposerState(text: "abc", cursor: 3, revision: 5))
        #expect(ComposerBridge.actionsForMirror(text: "ab", cursor: 2, state: full) == [.input(.deleteBackward(1))])
        // Multi-line single event ⇒ pasteLiteral (SPEC 751).
        let empty = UIState()
        let paste = ComposerBridge.actionsForMirror(text: "a\n@b", cursor: 4, state: empty)
        #expect(paste == [.input(.pasteLiteral("a\n@b"))])
        // Cursor-only move.
        #expect(ComposerBridge.actionsForMirror(text: "axc", cursor: 0, state: base) == [.input(.moveCursor(-2))])
    }

    @Test("accept gate opens on safe candidates, refuses hostile ones (M4-D D2)")
    func acceptPreviewGate() {
        func suggested(_ text: String, _ candidates: [CandidateFile], selected: Int? = nil) -> UIState {
            UIState(
                composer: ComposerState(text: text, cursor: text.unicodeScalars.count, revision: 9),
                suggestion: MentionSuggestionState(query: "e", revision: 9, candidates: candidates, selectedIndex: selected))
        }
        // Safe candidate: gate opens with the accepted display text.
        let open = suggested("@e", [CandidateFile(path: "ok.swift"), CandidateFile(path: "other.swift")])
        guard let accepted = ComposerBridge.acceptPreview(state: open) else {
            Issue.record("accept gate must open on a live safe suggestion"); return
        }
        #expect(accepted.text == "ok.swift", "display text replaces the query span, got \(accepted.text)")
        #expect(accepted.cursor == accepted.text.unicodeScalars.count)
        // No suggestion / empty candidates ⇒ closed.
        #expect(ComposerBridge.acceptPreview(state: idleState()) == nil)
        #expect(ComposerBridge.acceptPreview(state: suggested("@e", [])) == nil)
        // Hostile selected path ⇒ closed (never reaches the live line;
        // the popup still lists it — render path unaffected).
        let hostile = suggested("@e", [CandidateFile(path: "ev\u{1B}[31mil.swift")])
        #expect(ComposerBridge.acceptPreview(state: hostile) == nil, "hostile path must not gate accept")
        // Selected index honored.
        let second = suggested("@e", [CandidateFile(path: "a.swift"), CandidateFile(path: "b.swift")], selected: 1)
        #expect(ComposerBridge.acceptPreview(state: second)?.text == "b.swift")
        // Range suffix carried into the display text.
        var ranged = suggested("@e#L10-L20", [CandidateFile(path: "ok.swift")])
        ranged.suggestion = MentionSuggestionState(query: "e#L10-L20", revision: 9, candidates: [CandidateFile(path: "ok.swift")])
        #expect(ComposerBridge.acceptPreview(state: ranged)?.text == "ok.swift#L10-L20")
    }

    @Test("interactive frame drops dumb-inline composer too")
    func overlayAndInlineSuppressed() {
        let frame = RenderFrame(
            lines: [
                SemanticLine(id: "a", runs: [StyledRun(text: "hi", role: .normal)]),
                SemanticLine(id: "composer-inline", runs: [StyledRun(text: "> draft", role: .composerText)]),
                SemanticLine(id: "composer-inline#1", runs: [StyledRun(text: "cont", role: .composerText)]),
            ],
            composerOverlay: ComposerOverlay(text: "draft", cursor: 5),
            width: 80)
        let adapted = ComposerBridge.frameForInteractive(frame)
        #expect(adapted.composerOverlay == nil)
        #expect(adapted.lines.map(\.id) == ["a"])
    }

    @Test("accept follows the live reducer state (query drift keeps candidates)")
    func acceptFollowsLiveState() {
        // Same-path query drift ("@a" → "@ab") keeps the suggestion
        // (reducer: silent query update); the gate follows the reducer,
        // so accept stays open on the CURRENT span.
        let state = UIState(
            composer: ComposerState(text: "@ab", cursor: 3, revision: 10),
            suggestion: MentionSuggestionState(query: "ab", revision: 9, candidates: [CandidateFile(path: "abc.swift")]))
        #expect(ComposerBridge.acceptPreview(state: state)?.text == "abc.swift")
    }

    @Test("command IDs mint fresh per submission event, even for identical text")
    func commandIDs() {
        var store = ComposerBridge.CommandIDStore()
        let first = store.id(for: "hello") { CommandID("id-1") }
        #expect(first == CommandID("id-1"))
        // An identical-text resubmission is a NEW explicit event: it
        // must mint fresh (same-ID reuse made Core swallow the second
        // turn as a silent no-op — M4-D residual fix). Retries reuse the
        // already-minted ID below this layer, never through the store.
        #expect(store.id(for: "hello") { CommandID("id-2") } == CommandID("id-2"))
        #expect(store.id(for: "other") { CommandID("id-3") } == CommandID("id-3"))
        // Non-consecutive repeat mints fresh as well (no text-keyed
        // memory anywhere in the path).
        #expect(store.id(for: "hello") { CommandID("id-4") } == CommandID("id-4"))
        #expect(store.lastSubmission?.text == "hello")
        #expect(store.lastSubmission?.id == CommandID("id-4"))
    }

    @Test("interactive map never produces decideApproval")
    func noDecideApproval() {
        let cid = commandID
        let lines = ["hi", "busy text", "/steer x", "/queue", "/undo g", "/rewind e#1",
                     "/compact", "/cancel", "/keys", "/diff", "/nope", "/undo", "/"]
        let states = [idleState(), busyState()]
        for line in lines {
            for state in states {
                let outcome = ComposerBridge.actionsForSubmitLine(line, state: state, commandID: cid)
                let actions: [UIAction]
                switch outcome {
                case .actions(let a): actions = a
                case .notice(_, let a): actions = a
                case .rejected: continue
                }
                for action in actions {
                    if case .queueOp(.grantApproval) = action { Issue.record("grantApproval from \(line)") }
                    if case .queueOp(.denyApproval) = action { Issue.record("denyApproval from \(line)") }
                }
            }
        }
        for key in [ComposerBridge.KeyPress.ctrlC, .ctrlJ, .esc, .tab, .up, .down] {
            for state in states {
                for action in ComposerBridge.actionsForKey(key, state: state) {
                    if case .queueOp(.grantApproval) = action { Issue.record("grantApproval from key") }
                    if case .queueOp(.denyApproval) = action { Issue.record("denyApproval from key") }
                }
            }
        }
    }

    @Test("interactive frame suppresses composer overlay")
    func overlaySuppressed() {
        let frame = RenderFrame(
            lines: [SemanticLine(id: "a", runs: [StyledRun(text: "hi", role: .normal)])],
            composerOverlay: ComposerOverlay(text: "dr👨‍👩‍👧aft", cursor: 3),
            width: 80)
        let adapted = ComposerBridge.frameForInteractive(frame)
        #expect(adapted.composerOverlay == nil)
        #expect(adapted.lines == frame.lines)
    }

    @Test("undo slash: bare previews latest, run needs explicit group")
    func undoSlash() {
        let cid = commandID
        guard case .actions(let latest) = ComposerBridge.actionsForSubmitLine("/undo", state: idleState(), commandID: cid) else {
            Issue.record("bare /undo must produce actions"); return
        }
        #expect(latest.contains(.undoIntent(.previewLatest)))
        guard case .actions(let pv) = ComposerBridge.actionsForSubmitLine("/undo g-7", state: idleState(), commandID: cid) else {
            Issue.record("/undo g must produce actions"); return
        }
        #expect(pv.contains(.undoIntent(.preview(groupID: "g-7"))))
        guard case .actions(let rn) = ComposerBridge.actionsForSubmitLine("/undo run g-7", state: idleState(), commandID: cid) else {
            Issue.record("/undo run g must produce actions"); return
        }
        #expect(rn.contains(.undoIntent(.run(groupID: "g-7"))))
        guard case .notice = ComposerBridge.actionsForSubmitLine("/undo run", state: idleState(), commandID: cid) else {
            Issue.record("bare /undo run must be a usage notice"); return
        }
    }

    @Test("inspect verbs map to inspect commands (M4-D D2)")
    func inspectVerbs() {
        let cid = commandID
        let pairs: [(String, InspectionCommand)] = [
            ("/models", .models), ("/sessions", .sessions), ("/agents", .agents),
            ("/context", .context), ("/epochs", .epochs),
            ("/compact", .compactDryRun), ("/diff", .diff),
        ]
        for (cmd, expected) in pairs {
            guard case .actions(let actions) = ComposerBridge.actionsForSubmitLine(cmd, state: idleState(), commandID: cid) else {
                Issue.record("\(cmd) must produce actions"); continue
            }
            #expect(actions.contains(.inspect(expected)), "\(cmd) must inspect \(expected)")
        }
        // Trailing text is a usage notice, never a silent inspect.
        guard case .notice = ComposerBridge.actionsForSubmitLine("/models extra", state: idleState(), commandID: cid) else {
            Issue.record("/models extra must be a usage notice"); return
        }
        guard case .notice(let compactUsage, _) = ComposerBridge.actionsForSubmitLine("/compact extra-ok", state: idleState(), commandID: cid) else {
            Issue.record("/compact extra-ok must be a usage notice"); return
        }
        #expect(compactUsage.contains("usage: /compact"))
    }

    @Test("preview slash resolves @path, rejects ranges and empties")
    func previewSlash() {
        let cid = commandID
        guard case .actions(let a1) = ComposerBridge.actionsForSubmitLine("/preview @docs/a.md", state: idleState(), commandID: cid) else {
            Issue.record("/preview @path must produce actions"); return
        }
        #expect(a1.contains(.inspect(.filePreview(path: "docs/a.md"))))
        guard case .actions(let a2) = ComposerBridge.actionsForSubmitLine("/preview docs/a.md", state: idleState(), commandID: cid) else {
            Issue.record("/preview path must produce actions"); return
        }
        #expect(a2.contains(.inspect(.filePreview(path: "docs/a.md"))))
        guard case .notice = ComposerBridge.actionsForSubmitLine("/preview", state: idleState(), commandID: cid) else {
            Issue.record("bare /preview must be a usage notice"); return
        }
        guard case .notice = ComposerBridge.actionsForSubmitLine("/preview @a.md#L10", state: idleState(), commandID: cid) else {
            Issue.record("ranged /preview must be a usage notice"); return
        }
    }
}
