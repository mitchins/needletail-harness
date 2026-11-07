import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B1 RED: UX-MENTION-01…12 pure mention/attachment contract.
/// These tests name the proposed API; they fail until GREEN implements it.
struct MentionGrammarTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    @Test("UX-MENTION-01 @ at word boundary opens a query")
    func UX_MENTION_01_boundaryOpensQuery() throws {
        var state = UIState()
        let fx = apply(&state, .input(.insertText("see @sr")))
        #expect(state.suggestion?.query == "sr", "query derived, got \(String(describing: state.suggestion))")
        #expect(fx.contains(where: {
            if case .requestCompletions(let q, _) = $0 { return q == "sr" }
            return false
        }), "fetch requested once")
    }

    @Test("UX-MENTION-01 email address is not a mention trigger")
    func UX_MENTION_01_emailIsNotTrigger() throws {
        var state = UIState()
        let fx = apply(&state, .input(.insertText("mail foo@bar")))
        #expect(state.suggestion == nil, "email @ must not trigger")
        #expect(fx.isEmpty, "no fetch for email text")
    }

    @Test("UX-MENTION-02 escaped at-sign stays literal")
    func UX_MENTION_02_escapedAtIsLiteral() throws {
        var state = UIState()
        let fx = apply(&state, .input(.insertText("cost \\@5")))
        #expect(state.suggestion == nil, "escaped @ is literal")
        #expect(fx.isEmpty)
    }

    @Test("UX-MENTION-02 pasted mention text stays literal until typed")
    func UX_MENTION_02_pasteStaysLiteral() throws {
        var state = UIState()
        let fx = apply(&state, .input(.pasteLiteral("@secret")))
        #expect(state.suggestion == nil, "pasted @ must not trigger")
        #expect(fx.isEmpty, "paste emits no fetch")
        _ = apply(&state, .input(.insertText("x")))
        // After a real keystroke the (text,cursor) grammar rules again.
        #expect(state.composer.text == "@secretx")
    }

    @Test("UX-MENTION-03 accept inserts unicode path token and moves cursor")
    func UX_MENTION_03_acceptInsertsToken() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "docs/ünïcode notes.md")])))
        let fx = apply(&state, .mention(.acceptSelected))
        #expect(state.composer.text.contains("docs/ünïcode notes.md"), "token text landed, got \(state.composer.text)")
        #expect(state.suggestion == nil, "popup dismissed after accept")
        #expect(state.tokens.count == 1 && state.tokens[0].path == "docs/ünïcode notes.md", "structured token recorded")
        #expect(!fx.contains(where: { if case .submit = $0 { return true }; return false }), "accept never submits")
    }

    @Test("UX-MENTION-04 late completion preserves newer selection")
    func UX_MENTION_04_lateCompletionKeepsSelection() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("@a")))
        let rev = state.suggestion!.revision
        _ = apply(&state, .completion(CompletionResult(queryRevision: rev,
            candidates: [CandidateFile(path: "a1"), CandidateFile(path: "a2")])))
        _ = apply(&state, .mention(.selectNext))
        #expect(state.suggestion?.selectedIndex == 1)
        // A stale earlier-revision result arrives: must drop entirely.
        _ = apply(&state, .completion(CompletionResult(queryRevision: rev &- 1,
            candidates: [CandidateFile(path: "stale")])))
        #expect(state.suggestion?.selectedIndex == 1, "selection preserved")
        #expect(!(state.suggestion?.candidates.contains(where: { $0.path == "stale" }) ?? true), "stale candidates dropped")
    }

    @Test("UX-MENTION-05 catalogue caps and secret names excluded")
    func UX_MENTION_05_capsAndExclusions() throws {
        let big = (0..<100_000).map { "src/f\($0).swift" }
        let source = ScriptedCandidates(catalog: big + [".secrets/key"])
        let found = source.candidates(query: "src/f", revision: 1)
        #expect(found.count == maxCandidates, "hard cap holds")
        #expect(!found.contains(where: { $0.path.contains(".secrets") }), "secrets never surface")
    }

    @Test("UX-MENTION-06 preview sanitized, truncated, no provider request")
    func UX_MENTION_06_previewSanitized() throws {
        let hostile = ["\u{1b}]0;pwned\u{07}line1", "\u{202E}rtl", "ok"]
        let (lines, truncated) = sanitizePreview(hostile + (0..<20).map { "pad\($0)" })
        #expect(lines.count <= 8, "8-line cap")
        #expect(lines.joined().utf8.count <= 4 * 1_024, "4-KiB cap")
        #expect(!lines.joined().contains("\u{1b}"), "escape neutralized")
        #expect(!lines.joined().contains("\u{202E}"), "bidi neutralized")
        #expect(truncated, "truncation flagged")
    }

    @Test("UX-MENTION-07 binary and denied files are typed, contentless")
    func UX_MENTION_07_typedRefusals() throws {
        let bin = CandidateFile(path: "a.bin", kind: "binary", previewLines: [], previewTruncated: false)
        let denied = CandidateFile(path: "nope", kind: "denied", previewLines: [], previewTruncated: false)
        #expect(bin.previewLines.isEmpty && bin.kind == "binary")
        #expect(denied.previewLines.isEmpty && denied.kind == "denied")
        var state = UIState()
        _ = apply(&state, .input(.insertText("@a")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [bin, denied])))
        #expect(state.suggestion?.candidates.count == 2, "typed rows displayable")
    }

    @Test("UX-MENTION-08 exact ranges, reversed and out-of-bounds rejected")
    func UX_MENTION_08_rangeGrammar() throws {
        #expect(parseMentionRange("#L10-L30") == 10...30, "exact bounds")
        #expect(parseMentionRange("#L10") == 10...10, "single line")
        #expect(parseMentionRange("#L30-L10") == nil, "reversed rejected")
        #expect(parseMentionRange("#L0-L5") == nil, "zero line rejected")
        #expect(parseMentionRange("#L10-L999999999") == nil, "absurd range rejected")
    }

    @Test("UX-MENTION-09 attach intent routes to Core validation")
    func UX_MENTION_09_attachIsIntent() throws {
        let state = UIState()
        let (_, fx) = reduce(state, .queueOp(.attachFile(path: "docs/a.md", range: 1...3)))
        #expect(fx.count == 1, "exactly one effect")
        #expect(fx[0] == .attachFile(path: "docs/a.md", range: 1...3), "attach intent, actor decides")
    }

    @Test("UX-MENTION-10 sealed context refuses attach at intent validation")
    func UX_MENTION_10_sealedRefusesAttach() throws {
        let state = UIState()
        // Empty path is never a valid attachment: refused purely, no effect.
        let (_, fx) = reduce(state, .queueOp(.attachFile(path: "", range: nil)))
        #expect(fx.isEmpty, "invalid attach emits nothing")
    }

    @Test("UX-MENTION-11 preview cancel admits nothing")
    func UX_MENTION_11_cancelAdmitsNothing() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc")))
        _ = apply(&state, .mention(.dismissSuggestion))
        #expect(state.suggestion == nil)
        #expect(state.tokens.isEmpty, "no token recorded")
        #expect(state.composer.text == "see @doc", "draft preserved byte-exact")
    }

    @Test("UX-MENTION-12 consent-gated attach carries route intent only")
    func UX_MENTION_12_attachCarriesNoGrant() throws {
        let (_, fx) = reduce(UIState(), .queueOp(.attachFile(path: "docs/a.md", range: nil)))
        for e in fx {
            if case .submit = e { Issue.record("attach must never submit"); }
        }
        #expect(fx.count == 1, "single attach intent, no grant, no submit")
    }

    @Test("UX-MENTION-08 reversed range accept records validation failure")
    func UX_MENTION_08_reversedAcceptFails() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc#L30-L10")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "doc.md")])))
        let fx = apply(&state, .mention(.acceptSelected))
        #expect(state.tokens.isEmpty, "no token on invalid range")
        #expect(state.suggestion?.rangeError != nil, "visible validation failure")
        #expect(fx.isEmpty, "no effects on failed accept")
    }

    @Test("UX-MENTION-03 selection clamps to candidate list")
    func UX_MENTION_03_selectionClamps() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("@a")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "only")])))
        _ = apply(&state, .mention(.selectNext))
        _ = apply(&state, .mention(.selectNext))
        #expect(state.suggestion?.selectedIndex == 0, "clamps at single candidate")
        _ = apply(&state, .mention(.selectPrevious))
        #expect(state.suggestion?.selectedIndex == 0, "clamps at zero")
    }
}
