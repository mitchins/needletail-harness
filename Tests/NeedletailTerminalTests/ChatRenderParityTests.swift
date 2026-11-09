import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal

/// M4-D D4.3 release-binary vs semantic-frame parity (deterministic
/// side). The SAME hand-written strings are asserted against the
/// semantic renderers here and against the release-binary PTY
/// transcript in `ChatPTYTests.parityFixedScenario` — the two tiers
/// agree by construction, never by generation. The PTY leg proves the
/// binary emits exactly what the frames say; this file pins what the
/// frames say.
struct ChatRenderParityTests {
    /// The fixed parity scenario, in words: the operator submits
    /// "parity probe"; the provider answers two paragraphs,
    /// "parity line one" and "parity line two" (a bare newline is a
    /// markdown soft break and joins — as-built contract, pinned in
    /// `MarkdownRendererTests`). Every string below is hand-written.
    static let probe = "parity probe"
    static let answerText = "parity line one\n\nparity line two"
    static let answer = ["parity line one", "parity line two"]

    @Test("D4.3 semantic side: submitted state renders the probe in status and composer")
    func semanticSubmittedState() {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText(Self.probe)))
        (state, _) = reduce(state, .input(.submitDraft(commandID: CommandID("p-1"))))
        let frame = render(state, width: 80, capabilities: .dumb)
        let status = frame.lines.filter { $0.id.hasPrefix("status-busy") }
            .map { $0.runs.map(\.text).joined() }
        #expect(status == [Self.probe], "submitted probe must sit in status-busy, got \(status)")
        let inline = frame.lines.filter { $0.id == "composer-inline" }
            .map { $0.runs.map(\.text).joined() }
        #expect(inline == ["> "], "submit clears the mirror, got \(inline)")
    }

    @Test("D4.3 semantic side: tap block renders the answer lines verbatim")
    func semanticTapBlock() {
        let context = RenderContext(sessionID: "parity", requestID: "parity-r")
        let blocks = renderMarkdownBlock(Self.answerText, context: context)
        #expect(blocks.map(\.plainText) == Self.answer,
            "tap render must preserve answer lines verbatim, got \(blocks.map(\.plainText))")
    }

    @Test("D4.3 semantic side: suggestion candidates render as exact rows")
    func semanticCandidates() {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText("@e")))
        (state, _) = reduce(state, .completion(CompletionResult(
            queryRevision: 1,
            candidates: [CandidateFile(path: "ok.swift"), CandidateFile(path: "dir/nope.swift")])))
        let frame = render(state, width: 80, capabilities: .dumb)
        let rows = frame.lines.filter { $0.id.hasPrefix("candidate-") }
            .map { $0.runs.map(\.text).joined() }
        #expect(rows == ["ok.swift", "dir/nope.swift"], "candidate rows must be exact, got \(rows)")
    }
}
