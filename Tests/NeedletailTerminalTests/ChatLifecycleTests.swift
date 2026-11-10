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
/// byte-exact draft. Deterministic: scripted inbox, bounded readiness
/// waits (effect batches, gate snapshots, joins) — no blind sleeps,
/// no timing assertions, state oracles only.
@Suite(.serialized)
struct ChatLifecycleTests {
    private func ownerCaps() -> TerminalCaps {
        TerminalCaps(color: false, cursorAddressing: false, width: 80)
    }

    private func waitFor(marker: String, in box: LockedBox, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.joined().contains(marker) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// Effect-batch readiness: `.mirror` dispatches on a changed query
    /// and `.completions` always appends (even a dropped stale revision
    /// lands an empty batch), so reaching `count` batches proves every
    /// posted event was handled — a blind sleep proves nothing.
    private func waitForEffects(_ count: Int, in effects: LockedEffects, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if effects.all().count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return effects.all().count >= count
    }

    private func waitForSnapshot(_ loop: ChatLoop, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loop.acceptSnapshot() != nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return loop.acceptSnapshot() != nil
    }

    private func join(task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var done = false
        }
        let flag = Flag()
        Task {
            await task.value
            flag.lock.withLock { flag.done = true }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if flag.lock.withLock({ flag.done }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
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
        #expect(await waitFor(marker: "idle", in: written, timeout: 5), "loop never rendered")
        // Two query generations: "@ab" (rev 1) superseded by "@abc".
        loop.post(.mirror(text: "@ab", cursor: 3))
        #expect(await waitForEffects(1, in: effects, timeout: 5), "first mirror never dispatched")
        loop.post(.mirror(text: "@abc", cursor: 4))
        #expect(await waitForEffects(2, in: effects, timeout: 5), "second mirror never dispatched")
        let revs = await effects.all().flatMap { $0 }.compactMap { fx -> UInt64? in
            if case .requestCompletions(_, let r) = fx { return r }
            return nil
        }
        #expect(revs.count == 2, "two query revisions expected, got \(revs)")
        // Late straggler for the SUPERSEDED revision: drops — no popup,
        // draft untouched, pending query undisturbed. The stale post
        // always appends a batch (even empty), so the count bump proves
        // it was handled before the negative assertions below.
        loop.post(.completions(query: "ab", revision: revs[0], candidates: [CandidateFile(path: "stale.swift")]))
        #expect(await waitForEffects(3, in: effects, timeout: 5), "stale completion never handled")
        #expect(loop.acceptSnapshot() == nil, "stale completions must not open the accept gate")
        #expect(loop.isSuggestionLive(), "superseded query still pending — stale drop must not clear it")
        // Live revision populates against the byte-exact draft; the gate
        // opening proves the live completion was handled.
        loop.post(.completions(query: "abc", revision: revs[1], candidates: [CandidateFile(path: "live.swift")]))
        #expect(await waitForSnapshot(loop, timeout: 5), "live completions never handled")
        guard let snap = loop.acceptSnapshot() else {
            Issue.record("live completions must open the accept gate")
            loop.post(.inputLine(nil))
            _ = await join(task: task, timeout: 5)
            owner.close()
            return
        }
        #expect(snap.base == "@abc", "draft must be byte-exact after the stale drop, got \(snap.base)")
        #expect(snap.display.contains("live.swift"), "live candidates populate the gate, got \(snap.display)")
        loop.post(.inputLine(nil))
        #expect(await join(task: task, timeout: 5), "loop did not exit")
        owner.close()
    }
}
