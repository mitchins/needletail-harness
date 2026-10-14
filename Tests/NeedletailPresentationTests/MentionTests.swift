import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// Tiny scripted candidate source (tests only): deterministic, bounded,
/// no filesystem. Product wiring is M2-D/M4.
struct ScriptedCandidates: FileCandidateSource, Sendable {
    var catalog: [String]
    func candidates(query: String, revision: UInt64) -> [CandidateFile] {
        _ = revision
        return catalog.filter { $0.contains(query) }.prefix(maxCandidates).map {
            CandidateFile(path: $0, previewLines: ["-- preview --"])
        }
    }
}

/// DX-02 — late async results carry revisions; stale ones drop without
/// touching the composer. Secret/ignored entries never surface (the fake
/// catalogue simply omits them — product confinement is Runtime's job).
struct MentionTests {

    @Test("DX-02 stale candidate results drop, composer untouched")
    func DX_02_staleCandidatesDrop() throws {
        let source = ScriptedCandidates(catalog: ["src/a.swift", "src/ab.swift", "src/b.swift"])
        var state = UIState()
        state.suggestion = MentionSuggestionState(query: "a", revision: 2, candidates: [])
        (state, _) = reduce(state, .input(.insertText("keep me")))
        // Revision N+1 arrives first and applies ...
        let fresh = source.candidates(query: "ab", revision: 3)
        state.suggestion = MentionSuggestionState(query: "ab", revision: 3, candidates: [])
        (state, _) = reduce(state, .completion(CompletionResult(queryRevision: 3, candidates: fresh)))
        #expect(state.suggestion?.candidates.count == 1, "fresh revision applies")
        // ... then the late revision-2 result arrives and must drop.
        let stale = source.candidates(query: "a", revision: 2)
        (state, _) = reduce(state, .completion(CompletionResult(queryRevision: 2, candidates: stale)))
        #expect(state.suggestion?.revision == 3, "stale result ignored")
        #expect(state.suggestion?.candidates.count == 1, "stale candidates never overwrite")
        #expect(state.composer.text == "keep me", "composer untouched throughout")
    }

    @Test("DX-02 completion for no live query drops")
    func DX_02_noLiveQueryDrops() throws {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText("typing")))
        let before = state
        (state, _) = reduce(state, .completion(CompletionResult(
            queryRevision: 9, candidates: [CandidateFile(path: "x")])))
        #expect(state == before, "no live query: zero mutation")
    }

    @Test("DX-02 candidate lists cap at the design bound")
    func DX_02_catalogueCaps() throws {
        let big = (0..<10_000).map { "src/file-\($0).swift" }
        let source = ScriptedCandidates(catalog: big)
        let found = source.candidates(query: "file-", revision: 1)
        #expect(found.count == maxCandidates, "bounded enumeration, got \(found.count)")
    }
}
