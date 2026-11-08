import Testing
import Foundation
import NeedletailCore
@testable import NeedletailPresentation

/// M4-C additive `InputAction.replaceDraft`: exact-sync boundary spec.
/// Rejects over-cap, sets cursor/end, bumps revision, clears pasting +
/// suggestion + tokens. Live mirroring must NOT use it (mention flows
/// restart after a boundary by design).
struct ReplaceDraftTests {
    @Test("replaceDraft exact-syncs the draft")
    func exactSync() {
        let state = UIState(composer: ComposerState(text: "old", cursor: 1, revision: 7))
        let (next, effects) = reduce(state, .input(.replaceDraft("new text")))
        #expect(effects.isEmpty)
        #expect(next.composer.text == "new text")
        #expect(next.composer.cursor == "new text".unicodeScalars.count)
        #expect(next.composer.revision == 8)
        #expect(next.composer.pasting == false)
    }

    @Test("replaceDraft clears suggestion and tokens like a submit boundary")
    func clearsBoundary() {
        let state = UIState(
            composer: ComposerState(text: "a @b", cursor: 4, revision: 2, pasting: true),
            suggestion: MentionSuggestionState(query: "@b", revision: 2),
            tokens: [MentionToken(path: "f", revision: 1)])
        let (next, _) = reduce(state, .input(.replaceDraft("fresh")))
        #expect(next.suggestion == nil)
        #expect(next.tokens.isEmpty)
        #expect(next.composer.pasting == false)
    }

    @Test("replaceDraft rejects over-cap whole")
    func overCapRejected() {
        let state = UIState(composer: ComposerState(text: "keep", cursor: 4, revision: 1))
        let big = String(repeating: "x", count: maxComposerBytes + 1)
        let (next, effects) = reduce(state, .input(.replaceDraft(big)))
        #expect(effects.isEmpty)
        #expect(next == state)
    }

    @Test("replaceDraft to empty is the clear boundary")
    func clearBoundary() {
        let state = UIState(composer: ComposerState(text: "draft", cursor: 5, revision: 3))
        let (next, _) = reduce(state, .input(.replaceDraft("")))
        #expect(next.composer.text == "")
        #expect(next.composer.cursor == 0)
        #expect(next.composer.revision == 4)
    }
}
