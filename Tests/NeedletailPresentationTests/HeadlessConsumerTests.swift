import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B5 headless-consumer gate (§9 six capabilities). A non-terminal
/// frontend drives the full loop: projection → actions → recorded
/// (unexecuted) effects → authoritative responses → replay equality.
struct HeadlessConsumerTests {

    private func entry(_ id: String, command: String, order: UInt64) -> QueueEntry {
        QueueEntry(entryID: id, commandID: CommandID(command), kind: .followUp,
            state: .queued, revision: 1, text: "t", targetEpochID: EpochID("e-1"),
            orderKey: order, rank: Double(order))
    }

    private func script() -> [(UIAction, String, Bool)] {
        let approval = ApprovalRequestView(
            requestID: RequestID("r-1"), generation: Revision(3), operation: "exec",
            requiredGrant: "exec", protectedPaths: [], sandbox: false)
        return [
            // 1. Complete semantic projection arrives.
            (.queueSync(QueueSyncSnapshot(
                entries: [entry("q-1", command: "a", order: 1)], activeRequest: nil,
                queueHeld: true, heldReason: .cancelled(sinceMillis: 9),
                pendingApproval: approval, admittedCommandIDs: [CommandID("a")],
                liveEpoch: EpochID("e-1"))), "sync", false),
            // 2. Operator acts: mention, accept, queue, approve intent.
            (.input(.insertText("see @doc")), "type", true),
            (.mention(.acceptSelected), "accept-empty", true),
            (.queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))), "followup", true),
            (.queueOp(.grantApproval), "grant", true),
            // 4. Authoritative responses arrive.
            (.session(.denied(cause: "policy")), "denied", false),
            (.session(.runUpdate(phase: "completed", detail: "done")), "done", false),
        ]
    }

    @Test("B5 headless consumer drives the loop without executing effects")
    func B5_headlessLoop() throws {
        var consumer = HeadlessConsumer()
        for (action, label, isSend) in script() {
            if isSend { consumer.send(action, label: label) }
            else { consumer.receive(action, label: label) }
            if label == "denied" {
                guard case .failed = consumer.state.status else {
                    Issue.record("denial recorded, got \(consumer.state.status)"); return
                }
            }
        }
        // 1. Projection complete: queue + hold + approval present.
        #expect(consumer.state.queue.count == 1 && !consumer.state.queue[0].isOptimistic)
        // Completed supersedes the earlier denial (authoritative order).
        if case .idle = consumer.state.status { } else {
            Issue.record("completed run idles, got \(consumer.state.status)")
        }
        #expect(consumer.state.pendingApproval?.requestID == RequestID("r-1"))
        // 2+3. Effects recorded, never executed (no actor exists here).
        let kinds = consumer.requested.map { effectKind($0) }
        #expect(kinds.contains("queue") && kinds.contains("decideApproval"),
            "intents recorded, got \(kinds)")
        #expect(!consumer.requested.isEmpty)
        // 5. Replay from scratch reaches the identical state.
        #expect(consumer.replayed(with: script()) == consumer.state, "replay equality")
        // 6. Queue, permissions, undo and epoch state inspectable.
        #expect(consumer.state.queue.count == 1, "queue inspectable")
        #expect(consumer.state.pendingApproval != nil, "permissions inspectable")
        var probe = consumer
        probe.send(.inspect(.epochs), label: "epochs")
        #expect(probe.requested.last == .inspect(.epochs), "epoch view is a local inspect")
    }

    @Test("B5 headless consumer imports no terminal module")
    func B5_importGate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("HeadlessConsumer.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }
        #expect(imports.count == 3, "exactly three imports, got: \(imports)")
        for line in imports {
            #expect(line == "import Foundation" || line == "import NeedletailPresentation" || line == "import NeedletailCore",
                "no terminal/runtime/appkit import allowed, got: \(line)")
        }
    }

    private func effectKind(_ effect: UIEffect) -> String {
        switch effect {
        case .submit: return "submit"
        case .queue: return "queue"
        case .queueEdit: return "queueEdit"
        case .queueWithdraw: return "queueWithdraw"
        case .queueResume: return "queueResume"
        case .previewFile: return "previewFile"
        case .requestCompletions: return "requestCompletions"
        case .cancelCurrent: return "cancelCurrent"
        case .inspect: return "inspect"
        case .attachFile: return "attachFile"
        case .queueReorder: return "queueReorder"
        case .decideApproval: return "decideApproval"
        case .undoPreview: return "undoPreview"
        case .runUndo: return "runUndo"
        case .requestLineageFork: return "requestLineageFork"
        }
    }
}
