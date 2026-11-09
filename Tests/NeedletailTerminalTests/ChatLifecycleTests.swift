import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal
@testable import NeedletailLineEditor

/// M4-D D4.4 draft/cursor preservation + stale callback handling
/// (loop tier; the reducer rule is DX-02). A superseded completion
/// revision must drop without touching the draft or opening the
/// accept gate; the live revision then populates against the
/// byte-exact draft. Deterministic: scripted inbox, sleeps only for
/// cross-task settling (no timing assertions — state oracles only).
@Suite(.serialized)
struct ChatLifecycleTests {
    private func ownerCaps() -> TerminalCaps {
        TerminalCaps(color: false, cursorAddressing: false, width: 80)
    }

    @Test("D4.4 stale completions for a superseded query drop; draft byte-exact, live revision populates")
    func staleCompletionsDropDraftIntact() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                       heldReason: nil, pendingApproval: nil,
                                       admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { CommandID("cmd-1") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let task = Task { await loop.run(scriptedInput: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Two query generations: "@ab" (rev 1) superseded by "@abc".
        loop.post(.mirror(text: "@ab", cursor: 3))
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.mirror(text: "@abc", cursor: 4))
        try await Task.sleep(nanoseconds: 200_000_000)
        let revs = await effects.all().flatMap { $0 }.compactMap { fx -> UInt64? in
            if case .requestCompletions(_, let r) = fx { return r }
            return nil
        }
        #expect(revs.count == 2, "two query revisions expected, got \(revs)")
        // Late straggler for the SUPERSEDED revision: drops — no popup,
        // draft untouched, pending query undisturbed.
        loop.post(.completions(query: "ab", revision: revs[0], candidates: [CandidateFile(path: "stale.swift")]))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(loop.acceptSnapshot() == nil, "stale completions must not open the accept gate")
        #expect(loop.isSuggestionLive(), "superseded query still pending — stale drop must not clear it")
        // Live revision populates against the byte-exact draft.
        loop.post(.completions(query: "abc", revision: revs[1], candidates: [CandidateFile(path: "live.swift")]))
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let snap = loop.acceptSnapshot() else {
            Issue.record("live completions must open the accept gate")
            loop.post(.inputLine(nil))
            await task.value
            owner.close()
            return
        }
        #expect(snap.base == "@abc", "draft must be byte-exact after the stale drop, got \(snap.base)")
        #expect(snap.display.contains("live.swift"), "live candidates populate the gate, got \(snap.display)")
        loop.post(.inputLine(nil))
        await task.value
        owner.close()
    }
}
