import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B5 RED: deterministic semantic frames, bounded output, and the
/// headless-consumer architectural gate (six capabilities).
/// Fails until GREEN implements the frame cap + consumer proof.
struct SemanticFrameTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    @Test("B5 frame output is bounded with a visible marker")
    func B5_frameBounded() throws {
        var state = UIState()
        let rows = (0..<300).map {
            QueueSummary(entryID: "q-\($0)", commandID: CommandID("c-\($0)"),
                kind: "followUp", state: "queued", revision: 1,
                delivery: .queued, pending: false,
                isOptimistic: false, staleTarget: false, hasAttachments: false)
        }
        state.queue = rows
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(frame.lines.count <= 512, "bounded frame, got \(frame.lines.count)")
        #expect(frame.lines.contains(where: { $0.id == "queue-truncated" }),
            "truncation is visible, never silent")
    }

    @Test("B5 hostile bytes stay inert data in every frame role")
    func B5_hostileBytesInert() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("hi\u{1b}]0;pwned\u{07}@x\u{202E}y")))
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: "evil\u{1b}[2J.md", provenance: .user, hunks: ["\u{1b}[3J"]),
        ])))
        let frame = render(state, width: 200, capabilities: TerminalCapabilities())
        let text = frame.lines.flatMap(\.runs).map(\.text).joined()
        let ids = frame.lines.map(\.id).joined()
        for blob in [text, ids] {
            #expect(!blob.contains("\u{1b}"), "no escape survives, got: \(blob)")
            #expect(!blob.contains("\u{202E}"), "no bidi survives")
            #expect(!blob.contains("\u{07}"), "no BEL survives")
        }
    }

    @Test("B5 same query twice requests completions once")
    func B5_noDuplicateFetch() throws {
        var state = UIState()
        let first = apply(&state, .input(.insertText("@doc")))
        #expect(first.count == 1, "first query fetches")
        _ = apply(&state, .input(.moveCursor(-1)))
        _ = apply(&state, .input(.moveCursor(1)))
        let third = apply(&state, .input(.insertText("")))
        #expect(!third.contains(where: {
            if case .requestCompletions = $0 { return true }; return false
        }), "identical query never refetches, got \(third)")
    }

    @Test("B5 render is pure: no state change, no effects possible")
    func B5_renderPure() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("@a")))
        let before = state
        let f1 = render(state, width: 80, capabilities: TerminalCapabilities())
        let f2 = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(state == before, "rendering mutates nothing")
        #expect(f1.lines.map(\.id) == f2.lines.map(\.id), "same state renders same frame")
    }
}
