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

    @Test("UX-MENTION-01 @ after comma, quote, and CR opens a query")
    func UX_MENTION_01_punctuationBoundaries() throws {
        for prefix in ["a,@", "\"@", "line1\r\n@", "(@"] {
            var state = UIState()
            _ = apply(&state, .input(.insertText(prefix + "sr")))
            #expect(state.suggestion?.query == "sr", "\(prefix.debugDescription) is a boundary")
        }
    }

    @Test("UX-MENTION-01 fetch key strips the range suffix")
    func UX_MENTION_01_fetchStripsRange() throws {
        var state = UIState()
        let fx = apply(&state, .input(.insertText("see @doc#L1")))
        #expect(state.suggestion?.query == "doc#L1", "full query kept for accept")
        #expect(fx.contains(where: {
            if case .requestCompletions(let q, _) = $0 { return q == "doc" }
            return false
        }), "fetch carries the path key only, got \(fx)")
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
        #expect(state.suggestion?.query == "secretx", "typed text re-derives; paste stays literal")
    }

    @Test("UX-MENTION-03 accept inserts unicode path token and moves cursor")
    func UX_MENTION_03_acceptInsertsToken() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "docs/ünïcode notes.md")])))
        let fx = apply(&state, .mention(.acceptSelected))
        #expect(state.composer.text.contains("docs/ünïcode notes.md"), "token text landed, got \(state.composer.text)")
        let expectedCursor = "see ".unicodeScalars.count + "docs/ünïcode notes.md".unicodeScalars.count
        #expect(state.composer.cursor == expectedCursor, "cursor after token, got \(state.composer.cursor)")
        #expect(state.suggestion == nil, "popup dismissed after accept")
        #expect(state.tokens.count == 1 && state.tokens[0].path == "docs/ünïcode notes.md", "structured token recorded")
        #expect(!fx.contains(where: { if case .submit = $0 { return true }; return false }), "accept never submits")
    }

    @Test("UX-MENTION-03 mid-token accept replaces the whole span")
    func UX_MENTION_03_midTokenAccept() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @longquery tail")))
        _ = apply(&state, .input(.moveCursor(-9)))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "f.md")])))
        _ = apply(&state, .mention(.acceptSelected))
        #expect(state.composer.text == "see f.md tail", "no query tail left, got \(state.composer.text)")
    }

    @Test("UX-MENTION-08 valid range accept records token and cursor")
    func UX_MENTION_08_validRangeAccept() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc#L10-L30")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "doc.md")])))
        let fx = apply(&state, .mention(.acceptSelected))
        #expect(state.tokens.count == 1 && state.tokens[0].lineRange == 10...30, "range recorded")
        #expect(state.composer.text == "see doc.md#L10-L30", "display carries range, got \(state.composer.text)")
        #expect(fx.isEmpty, "accept emits no effects")
    }

    @Test("UX-MENTION-11 submit clears accepted tokens with the draft")
    func UX_MENTION_11_submitClearsTokens() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("@a ")))
        state.tokens = [MentionToken(path: "a", revision: 1)]
        let fx = apply(&state, .input(.submitDraft(commandID: CommandID("s-1"))))
        #expect(fx.count == 1, "submit still emits")
        #expect(state.tokens.isEmpty, "tokens belong to the submitted draft")
        #expect(state.composer.text.isEmpty && state.suggestion == nil)
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

    @Test("UX-MENTION-05 catalogue caps and exclusions are caller-enforced")
    func UX_MENTION_05_capsAndExclusions() throws {
        let big = (0..<100_000).map { "src/f\($0).swift" }
        // The seam contract: callers filter secrets/out-of-root BEFORE the
        // source (product confinement is Runtime's job, proven in B6).
        // Discriminating check: the unfiltered source SEES the secret, the
        // filtered one does not — dropping `excluded` fails this test.
        let raw = ScriptedCandidates(catalog: big + [".secrets/key"])
        #expect(raw.candidates(query: "key", revision: 1).contains(where: { $0.path == ".secrets/key" }),
            "unfiltered source sees the secret")
        let source = ScriptedCandidates(catalog: big + [".secrets/key"], excluded: [".secrets/key"])
        let found = source.candidates(query: "f", revision: 1)
        #expect(found.count == maxCandidates, "hard cap holds")
        #expect(source.candidates(query: "key", revision: 1).isEmpty,
            "excluded entries never surface even on exact match")
    }

    @Test("UX-MENTION-06 preview sanitized, truncated, no provider request")
    func UX_MENTION_06_previewSanitized() throws {
        let hostile = ["\u{1b}]0;pwned\u{07}line1", "\u{202E}rtl", "ok"]
        let (lines, truncated) = sanitizePreview(hostile + (0..<20).map { "pad\($0)" })
        #expect(lines.count <= 8, "8-line cap")
        #expect(lines.joined().utf8.count <= 4 * 1_024, "4-KiB cap")
        #expect(!lines.joined().unicodeScalars.contains("\u{1b}"), "escape neutralized")
        #expect(!lines.joined().unicodeScalars.contains("\u{202E}"), "bidi neutralized")
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

    @Test("UX-MENTION-10 invalid attach refused purely; sealed is actor-side")
    func UX_MENTION_10_emptyAttachRefusedPurely() throws {
        // Pure leg: an empty path is refused with no effect. Sealed-mode
        // refusal is an actor decision (Core re-validates route/consent);
        // the intent must therefore carry no grant — only path+range.
        var state = UIState()
        let fx = apply(&state, .queueOp(.attachFile(path: "", range: nil)))
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

    @Test("UX-MENTION-08 range-only edit keeps candidates without refetch")
    func UX_MENTION_08_rangeEditRetains() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("see @doc")))
        let rev = state.suggestion!.revision
        _ = apply(&state, .completion(CompletionResult(queryRevision: rev,
            candidates: [CandidateFile(path: "doc.md"), CandidateFile(path: "doc2.md")])))
        _ = apply(&state, .mention(.selectNext))
        let fx = apply(&state, .input(.insertText("#L10")))
        #expect(state.suggestion?.candidates.count == 2, "candidates survive range suffix")
        #expect(state.suggestion?.selectedIndex == 1, "selection survives range suffix")
        #expect(!fx.contains(where: {
            if case .requestCompletions = $0 { return true }
            return false
        }), "range-only edit emits no refetch")
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
