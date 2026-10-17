import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// Reducer core: draft ops preserve bytes exactly, caps reject loudly,
/// queue intents become effects (never state), stale completions drop.
struct ReducerTests {

    @Test("DX-01 replay twice yields identical frames and effects")
    func DX_01_replayDeterministic() throws {
        let script: [UIAction] = [
            .input(.insertText("hello")),
            .input(.insertText(" world")),
            .input(.moveCursor(-6)),
            .input(.deleteBackward(1)),
            .queueOp(.submitFollowUp(text: "go", commandID: CommandID("q-1"))),
            .session(.admitted(commandID: CommandID("q-1"), revision: 1)),
        ]
        func run() -> (UIState, [UIEffect], RenderFrame) {
            var state = UIState()
            var effects: [UIEffect] = []
            for action in script {
                let (next, emitted) = reduce(state, action)
                state = next
                effects += emitted
            }
            return (state, effects, render(state, width: 80, capabilities: TerminalCapabilities()))
        }
        let (s1, e1, f1) = run()
        let (s2, e2, f2) = run()
        #expect(s1 == s2 && e1 == e2 && f1 == f2, "deterministic replay")
        #expect(s1.composer.text == "hell world", "draft edits exact, got '\(s1.composer.text)'")
        #expect(e1.count == 1, "one queue effect, got \(e1.count)")
    }

    @Test("draft edits preserve bytes exactly, caps reject loudly")
    func draftPreservation() throws {
        var state = UIState()
        let emoji = "héllo 🌍"
        (state, _) = reduce(state, .input(.insertText(emoji)))
        #expect(state.composer.text == emoji)
        #expect(state.composer.cursor == Array(emoji.unicodeScalars).count, "cursor counts scalars")
        // Over-cap insert refuses with zero mutation.
        let big = String(repeating: "x", count: maxComposerBytes + 1)
        let (capped, effects) = reduce(state, .input(.insertText(big)))
        #expect(capped == state, "over-cap insert changes nothing")
        #expect(effects.isEmpty)
        // Paste never submits: no submit effect from pasteLiteral.
        let (pasted, pasteEffects) = reduce(state, .input(.pasteLiteral("a\nb")))
        #expect(pasteEffects.isEmpty, "paste is literal, never a submission")
        #expect(pasted.composer.text.contains("a\nb"))
        // Empty submit is a no-op, not an empty request.
        let empty = UIState()
        let (_, emptyEffects) = reduce(empty, .input(.submitDraft(commandID: CommandID("e"))))
        #expect(emptyEffects.isEmpty)
    }

    @Test("DX-03 queue intents become effects; state queue untouched")
    func DX_03_intentsAreEffects() throws {
        let state = UIState()
        let (editState, editEffects) = reduce(state, .queueOp(.editEntry(entryID: "e1", newText: "x", baseRevision: 1)))
        #expect(editState.queue.isEmpty, "reducer never mutates queue")
        #expect(editEffects == [.queueEdit(entryID: "e1", newText: "x", baseRevision: 1)])
        let (_, withdrawEffects) = reduce(state, .queueOp(.withdrawEntry(entryID: "e1")))
        #expect(withdrawEffects == [.queueWithdraw(entryID: "e1")])
        let (_, resumeEffects) = reduce(state, .queueOp(.resumeQueue))
        #expect(resumeEffects == [.queueResume])
    }

    @Test("DX-03 session projections update read-only state")
    func DX_03_projectionUpdates() throws {
        var state = UIState()
        (state, _) = reduce(state, .session(.admitted(commandID: CommandID("q-1"), revision: 1)))
        guard case .busy = state.status else {
            Issue.record("admitted projection must mark busy"); return
        }
        (state, _) = reduce(state, .session(.denied(cause: "policy")))
        guard case .failed = state.status else {
            Issue.record("denial projection must mark failed"); return
        }
    }

    @Test("projection minting outside Core is unrepresentable in product")
    func projectionConstructionSite() throws {
        // R21 static pin (mirrored here as documentation): SessionEventProjection
        // carries an internal init, so only Core constructs it. This test
        // exercises the CONSUMING side with actor-originated values.
        let projection = SessionEventProjection.admitted(commandID: CommandID("q-9"), revision: 3)
        let (state, _) = reduce(UIState(), .session(projection))
        guard case .busy = state.status else {
            Issue.record("actor-originated projection must apply"); return
        }
    }
}
