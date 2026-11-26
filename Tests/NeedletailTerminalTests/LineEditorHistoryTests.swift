import Testing
import Foundation
@testable import NeedletailLineEditor

/// M4-D D2.7 history-hygiene seam tests (D7 review B2). The live proof
/// that a `y` decision line never persists is the D3 PTY oracle
/// `testConfirmHygieneNoDecisionInHistory` (Up-arrow recall after a
/// real approval through the release binary). These unit tests pin the
/// seam's contract with SEEDED history (only live replxx accepts
/// commit history in production): an exact tail match drops exactly
/// the decision line and preserves the prefix; a mismatched tail is
/// left untouched, never dropped.
struct LineEditorHistoryTests {

    @Test("seeded tail: exact match drops only the decision line")
    func exactTailDropPreservesPrefix() throws {
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        editor.addHistoryEntry("write the note")
        editor.addHistoryEntry("y")
        #expect(editor.historyEntries() == ["write the note", "y"], "seeded history must land verbatim")
        #expect(editor.dropLastHistoryEntry(matching: "y"), "exact-tail drop must succeed")
        #expect(editor.historyEntries() == ["write the note"], "only the decision line drops; the prefix survives byte-exact")
    }

    @Test("seeded multi-line prefix survives the drop")
    func multiLinePrefixSurvives() throws {
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        editor.addHistoryEntry("first")
        editor.addHistoryEntry("second")
        editor.addHistoryEntry("N")
        #expect(editor.dropLastHistoryEntry(matching: "N"), "exact-tail drop must succeed")
        #expect(editor.historyEntries() == ["first", "second"], "whole prefix preserved in order")
    }

    @Test("mismatched tail: drop refuses and preserves history")
    func mismatchedTailPreserved() throws {
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        editor.addHistoryEntry("write the note")
        editor.addHistoryEntry("something-else")
        #expect(!editor.dropLastHistoryEntry(matching: "y"), "non-tail drop must fail safe")
        #expect(editor.historyEntries() == ["write the note", "something-else"], "failed drop must not mutate history")
    }

    @Test("empty history: drop is a fail-safe no-op")
    func emptyHistoryDropIsNoop() throws {
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        #expect(editor.historyEntries().isEmpty, "fresh session must hold no history")
        #expect(!editor.dropLastHistoryEntry(matching: "y"), "drop on empty history must fail safe")
        #expect(editor.historyEntries().isEmpty, "failed drop must not mutate history")
    }
}
