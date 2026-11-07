import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B5 headless-consumer gate (§9 six capabilities, fail-closed).
/// A non-terminal frontend drives the full loop: projection → actions
/// → recorded (unexecuted) effects → authoritative responses → replay
/// equality. Every capability below fails closed.
struct HeadlessConsumerTests {

    private func entry(_ id: String, command: String, order: UInt64) -> QueueEntry {
        QueueEntry(entryID: id, commandID: CommandID(command), kind: .followUp,
            state: .queued, revision: 1, text: "t", targetEpochID: EpochID("e-1"),
            orderKey: order, rank: Double(order))
    }

    private func approval() -> ApprovalRequestView {
        ApprovalRequestView(
            requestID: RequestID("r-1"), generation: Revision(3), operation: "exec",
            requiredGrant: "exec", protectedPaths: [], sandbox: false)
    }

    /// Full loop script: projection, mention fetch/accept, queue,
    /// approve, admitted, agent, confirm-sync, completed.
    private func script() -> [(UIAction, String, Bool)] {
        let candidates = [CandidateFile(path: "doc.md"), CandidateFile(path: "doc2.md")]
        return [
            (.queueSync(QueueSyncSnapshot(
                entries: [entry("q-1", command: "a", order: 1)], activeRequest: nil,
                queueHeld: true, heldReason: .cancelled(sinceMillis: 9),
                pendingApproval: approval(), admittedCommandIDs: [CommandID("a")],
                liveEpoch: EpochID("e-1"))), "sync", false),
            (.input(.insertText("see @doc")), "type", true),
            (.completion(CompletionResult(queryRevision: 1, candidates: candidates)), "candidates", false),
            (.mention(.selectNext), "select", true),
            (.mention(.acceptSelected), "accept", true),
            (.queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))), "followup", true),
            (.queueOp(.grantApproval), "grant", true),
            (.session(.admitted(commandID: CommandID("f-1"), revision: 1)), "admitted", false),
            (.session(.agent(alias: "m", locality: "local", phase: "requesting")), "agent", false),
            (.queueSync(QueueSyncSnapshot(
                entries: [entry("q-1", command: "a", order: 1), entry("q-2", command: "f-1", order: 2)],
                activeRequest: nil, queueHeld: false, heldReason: nil,
                pendingApproval: approval(), admittedCommandIDs: [CommandID("a"), CommandID("f-1")],
                liveEpoch: EpochID("e-1"))), "confirm", false),
            (.session(.runUpdate(phase: "completed", detail: "done")), "done", false),
        ]
    }

    @Test("B5 headless consumer drives the loop without executing effects")
    func B5_headlessLoop() throws {
        var consumer = HeadlessConsumer()
        var receiveEffects: [[UIEffect]] = []
        for (action, label, isSend) in script() {
            if isSend { consumer.send(action, label: label) }
            else { receiveEffects.append(consumer.receive(action, label: label)) }
        }
        // Cap 1: complete projection — queue + hold + approval present.
        #expect(consumer.state.queue.count == 2 && consumer.state.queue.allSatisfy({ !$0.isOptimistic }))
        if case .held = consumer.state.status { Issue.record("hold released by confirm sync"); return }
        #expect(consumer.state.pendingApproval?.requestID == RequestID("r-1"))
        #expect(consumer.state.tokens.count == 1 && consumer.state.tokens[0].path == "doc2.md",
            "accept leg exercised with real candidates")
        // Cap 2: the EXACT recorded effect list, in order.
        let kinds = consumer.requested.map { effectKind($0) }
        #expect(kinds == ["requestCompletions", "queue", "decideApproval"],
            "exact effects in order, got \(kinds)")
        // Cap 3: recorded, never executed; authoritative inputs request nothing.
        #expect(receiveEffects.allSatisfy({ $0.isEmpty }), "receives request no work (fail-closed under -O too)")
        // Cap 4: admitted + agent applied (status moved admitted→idle via completed).
        if case .idle = consumer.state.status { } else {
            Issue.record("completed run idles, got \(consumer.state.status)")
        }
        #expect(consumer.state.activeAgent == nil, "completed clears the agent")
        // Cap 5: replay twice — identical states AND effect lists.
        let r1 = consumer.replayed(with: script())
        let r2 = consumer.replayed(with: script())
        #expect(r1.state == consumer.state && r2.state == consumer.state, "replay equality")
        #expect(r1.requested == consumer.requested && r2.requested == consumer.requested,
            "no duplicate requests on replay")
        // Cap 6: all four domains inspectable without a terminal import.
        #expect(consumer.state.queue.count == 2, "queue inspectable")
        #expect(consumer.state.pendingApproval != nil, "permissions inspectable")
        var probe = consumer
        probe.send(.inspectResult(.undoPreview(preview: UIUndoPreview(groupID: "g", files: [],
            canRun: false, notice: "n"))), label: "undo")
        guard case .undoPreview = probe.state.inspection else {
            Issue.record("undo state inspectable"); return
        }
        probe.send(.inspectResult(.epochs(rows: [
            UIEpochRow(epochID: "e-2", parentID: "e-1",
                checkpoint: .success(costMillis: 1), prefill: nil)])), label: "epochs")
        guard case .epochs(let rows) = probe.state.inspection, rows.count == 1,
              rows[0].parentID == "e-1" else {
            Issue.record("epoch lineage inspectable"); return
        }
    }

    @Test("B5 optimistic refusal rolls back byte-exactly")
    func B5_rollbackExact() throws {
        var consumer = HeadlessConsumer()
        consumer.send(.queueOp(.submitFollowUp(text: "later", commandID: CommandID("f-1"))), label: "f")
        let withOptimistic = consumer.state
        #expect(withOptimistic.queue.count == 1 && withOptimistic.queue[0].isOptimistic)
        let fx = consumer.receive(.session(.denied(cause: "policy")), label: "denied")
        #expect(fx.isEmpty, "denial requests nothing")
        #expect(consumer.state.queue.isEmpty, "optimistic row rolled back")
        if case .failed = consumer.state.status { } else {
            Issue.record("denial fails the status, got \(consumer.state.status)")
        }
        #expect(consumer.state.composer == withOptimistic.composer, "draft untouched by rollback")
        #expect(consumer.state.tokens == withOptimistic.tokens, "tokens untouched by rollback")
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
