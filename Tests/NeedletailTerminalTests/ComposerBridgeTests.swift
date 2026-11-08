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

    @Test("ctrlC decision matrix: armed always clears (even busy)")
    func ctrlCMatrix() {
        // Armed confirm: clear even mid-run (cancelling would deny the
        // pending request the prompt asks about).
        #expect(ComposerBridge.ctrlCAction(busy: true, armed: true, draftNonEmpty: true) == .clearBuffer)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: true, draftNonEmpty: false) == .clearBuffer)
        #expect(ComposerBridge.ctrlCAction(busy: true, armed: false, draftNonEmpty: true) == .cancelRun)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: true) == .clearBuffer)
        #expect(ComposerBridge.ctrlCAction(busy: false, armed: false, draftNonEmpty: false) == .hint)
    }

    @Test("key map: ctrlC/ctrlJ/esc")
    func keyMap() {
        #expect(ComposerBridge.actionsForKey(.ctrlC, state: busyState()) == [.queueOp(.cancelRun)])
        #expect(ComposerBridge.actionsForKey(.ctrlC, state: UIState(composer: ComposerState(text: "draft", cursor: 5)))
            == [.input(.replaceDraft(""))])
        #expect(ComposerBridge.actionsForKey(.ctrlC, state: idleState()) == [])
        #expect(ComposerBridge.idleEmptyHint.contains("/keys"))
        #expect(ComposerBridge.actionsForKey(.ctrlJ, state: idleState()) == [.input(.newline)])
        // Esc always dispatches dismiss (reducer noops with no popup).
        #expect(ComposerBridge.actionsForKey(.esc, state: idleState()) == [.mention(.dismissSuggestion)])
        let suggesting = UIState(suggestion: MentionSuggestionState(query: "@a", revision: 1))
        #expect(ComposerBridge.actionsForKey(.esc, state: suggesting) == [.mention(.dismissSuggestion)])
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
        for cmd in ["/", "/steer", "/rewind nope", "/preview x", "/diff", "/bogus q",
                    "/queue resume", "/undo", "/compact extra-ok"] {
            let outcome = ComposerBridge.actionsForSubmitLine(cmd, state: idleState(), commandID: cid)
            switch outcome {
            case .notice(let text, let actions):
                #expect(!text.isEmpty)
                #expect(actions == [.input(.replaceDraft(""))])
            case .actions:
                // /compact with trailing text still maps (dry-run only).
                #expect(cmd.hasPrefix("/compact"))
            case .rejected:
                Issue.record("unexpected reject for \(cmd)")
            }
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

    @Test("hostile candidates never reach the live line (injection rule)")
    func hostileCandidatesDropped() {
        var cache = ComposerBridge.CompletionCache()
        cache.store([CandidateFile(path: "ok.swift"), CandidateFile(path: "ev\u{1B}[31mil.swift")], revision: 9)
        let state = UIState(
            composer: ComposerState(text: "@e", cursor: 2, revision: 9),
            suggestion: MentionSuggestionState(query: "e", revision: 9))
        #expect(ComposerBridge.completionCandidates(input: "@e", cursor: 2, cache: cache, state: state) == ["ok.swift"])
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

    @Test("completion cache serves only the live revision+query")
    func completionCache() {
        var cache = ComposerBridge.CompletionCache()
        cache.store([CandidateFile(path: "a.swift"), CandidateFile(path: "b.swift")], revision: 9)
        var state = UIState(
            composer: ComposerState(text: "@a", cursor: 2, revision: 9),
            suggestion: MentionSuggestionState(query: "a", revision: 9))
        #expect(ComposerBridge.completionCandidates(input: "@a", cursor: 2, cache: cache, state: state)
            == ["a.swift", "b.swift"])
        // Stale revision ⇒ nothing.
        state.composer.revision = 10
        #expect(ComposerBridge.completionCandidates(input: "@a", cursor: 2, cache: cache, state: state) == [])
        // Evicted revision ⇒ nothing.
        cache.store([CandidateFile(path: "c")], revision: 10)
        cache.store([CandidateFile(path: "d")], revision: 11)
        state.composer.revision = 9
        #expect(ComposerBridge.completionCandidates(input: "@a", cursor: 2, cache: cache, state: state) == [])
    }

    @Test("command IDs reuse on retry, mint on new text")
    func commandIDs() {
        var store = ComposerBridge.CommandIDStore()
        let first = store.id(for: "hello") { CommandID("id-1") }
        #expect(first == CommandID("id-1"))
        #expect(store.id(for: "hello") { CommandID("id-2") } == CommandID("id-1"))
        #expect(store.id(for: "other") { CommandID("id-3") } == CommandID("id-3"))
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
        for key in [ComposerBridge.KeyPress.ctrlC, .ctrlJ, .esc] {
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
}
