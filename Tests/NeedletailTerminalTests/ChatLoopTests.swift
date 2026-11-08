import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal
@testable import NeedletailLineEditor

/// C5.1/C5.8 loop legs (scripted input — no TTY, no input thread):
/// submit→effect translation, draft/cursor preservation across
/// streaming output, no duplicate operator submission, confirm flow.
struct ChatLoopTests {
    private func ownerCaps() -> TerminalCaps {
        TerminalCaps(color: false, cursorAddressing: false, width: 80)
    }

    @Test("scripted submit translates to exact-sync + submit effects (C5.8)")
    func scriptedSubmit() async {
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
        await loop.run(scriptedInput: ["hello", nil])
        let fx = await effects.all()
        #expect(fx.count == 1)
        #expect(fx[0] == [.submit(OperatorInput(text: "hello", commandID: CommandID("cmd-1")))])
        owner.close()
    }

    @Test("same text retried reuses the command ID (no duplicate submission)")
    func retryReusesID() async {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(
            caps: ownerCaps(), writer: { written.append($0) })
        let empty = QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                      heldReason: nil, pendingApproval: nil,
                                      admittedCommandIDs: [], liveEpoch: EpochID("e"))
        let n = LockedValue(0)
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { empty },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: { var id = 0; n.mutate { $0 += 1; id = $0 }; return CommandID("cmd-\(id)") })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        await loop.run(scriptedInput: ["same", "same", nil])
        let fx = await effects.all()
        #expect(fx.count == 2)
        // Both submissions carry the SAME command ID (Core admission
        // idempotency dedups; the adapter never mints a second ID for a
        // retry of the same text).
        #expect(fx[0] == fx[1])
        owner.close()
    }

    @Test("serveCompletion applies the display-safe rule on the live path")
    func serveCompletionFilters() async throws {
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
        // Seed a live suggestion via mirror, then deliver completions
        // including a hostile filename: the sync serve must drop it.
        loop.post(.mirror(text: "@e", cursor: 2))
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.completions(query: "e", revision: 1, candidates: [
            CandidateFile(path: "ok.swift"),
            CandidateFile(path: "ev\u{1B}.swift"),
        ]))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(loop.serveCompletion(input: "@e") == ["ok.swift"])
        loop.post(.inputLine(nil))
        await task.value
        owner.close()
    }

    @Test("confirm flow consumes the decision line; follow-up submits clean")
    func confirmFlow() async throws {
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
        // Drive the gateway path: presenter arms the loop with the
        // shared box. The run MUST be live before deciding (production
        // invariant: the loop starts before any actor work, so the
        // inbox exists when the presenter posts).
        let runTask = Task { await loop.run(scriptedInput: []) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let gateway = ReplxxApprovalGateway { req, box in
            loop.prepareConfirm(box: box)
            loop.post(.approvalArmed(req))
        }
        let req = ApprovalRequest(requestID: RequestID("r"), runID: RunID("r"), generation: Revision(1),
                                  operation: "op", requiredGrant: "read")
        async let decision = gateway.decide(req)
        // Inbox FIFO: approvalArmed is handled (prompt rendered, draft
        // snapshotted) before the answer below is processed.
        try await Task.sleep(nanoseconds: 200_000_000)
        // The actionable prompt rendered on the control lane.
        #expect(written.joined().contains("approval required:"))
        loop.post(.inputLine("y"))
        try await Task.sleep(nanoseconds: 200_000_000)
        // The follow-up line proves the mirror reset (not polluted by y).
        loop.post(.inputLine("second"))
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.inputLine(nil))
        await runTask.value
        let final = await decision
        #expect(final == .approve)
        // The decision line was consumed as a confirm, not a submit:
        // exactly one submit (for "second") was produced — never a
        // submit of "y", never a polluted draft.
        let fx = await effects.all()
        #expect(fx.count == 1)
        #expect(fx[0] == [.submit(OperatorInput(text: "second", commandID: CommandID("cmd-1")))])
        owner.close()
    }

    @Test("request-scoped finalize: unknown completions drop (C5.5)")
    func staleGate() async throws {
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
        // No nil terminator: the run stays alive for posted events.
        let task = Task { await loop.run(scriptedInput: ["hi"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Live request: progress registers, completion commits.
        loop.post(.tapProgress(RequestID("a"), 10))
        loop.post(.tapComplete(RequestID("a"), Revision(1), "# Done"))
        // Unknown request (never progressed, e.g. cancelled): drops.
        loop.post(.tapComplete(RequestID("zzz"), Revision(9), "# Ghost"))
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.inputLine(nil))
        await task.value
        let out = written.joined()
        #expect(out.contains("Done"))
        #expect(!out.contains("Ghost"))
        owner.close()
    }

    @Test("out-of-order completions drop below the committed revision")
    func revisionGate() async throws {
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
        let task = Task { await loop.run(scriptedInput: ["hi"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.tapProgress(RequestID("a"), 10))
        loop.post(.tapComplete(RequestID("a"), Revision(3), "# Third"))
        // Late straggler for an older revision of the same request.
        loop.post(.tapProgress(RequestID("a"), 11))
        loop.post(.tapComplete(RequestID("a"), Revision(1), "# First"))
        try await Task.sleep(nanoseconds: 200_000_000)
        loop.post(.inputLine(nil))
        await task.value
        let out = written.joined()
        #expect(out.contains("Third"))
        #expect(!out.contains("First"))
        owner.close()
    }
}

final class LockedEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UIEffect]] = []
    func append(_ fx: [UIEffect]) async { lock.withLock { items.append(fx) } }
    func all() -> [[UIEffect]] {
        // The loop already terminated (scripted EOF), so no race.
        lock.withLock { items }
    }
}
