import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B4 RED: UX-UNDO-06/08/09 pure legs, UX-NAV-07 diff views, approval
/// identity display. Fails until GREEN implements the views.
struct UndoDiffViewsTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    private func undoFile(_ path: String, eligible: Bool, conflict: String? = nil) -> UIUndoFile {
        UIUndoFile(path: path, beforeHash: "b1", afterHash: "a1", eligible: eligible, conflict: conflict)
    }

    @Test("UX-UNDO-06 exec-side-effect file is not natively undoable")
    func UX_UNDO_06_execEffectNotUndoable() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.undoPreview(preview: UIUndoPreview(
            groupID: "g-1",
            files: [undoFile("fmt.out", eligible: false, conflict: "shell-produced change: not in native ledger")],
            canRun: false,
            notice: "nothing reversible"))))
        guard case .undoPreview(let preview) = state.inspection else {
            Issue.record("undo preview must project"); return
        }
        #expect(!preview.canRun, "no silent undo of exec effects")
        #expect(preview.files.first?.conflict != nil, "conflict visible")
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let text = frame.lines.flatMap(\.runs).map(\.text).joined()
        #expect(text.contains("not in native ledger"), "refusal rendered, got: \(text)")
    }

    @Test("UX-UNDO-08 rewind shows lineage fork and divergence, mutates nothing")
    func UX_UNDO_08_rewindForkView() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.rewind(view: UIRewindView(
            boundaryEpoch: "e-5", throughSequence: 42,
            divergent: true,
            warning: "dirty worktree: fork only, no file mutation"))))
        guard case .rewind(let view) = state.inspection else {
            Issue.record("rewind view must project"); return
        }
        #expect(view.divergent && view.warning.contains("no file mutation"))
        let fx = apply(&state, .undoIntent(.run(groupID: "g-9")))
        #expect(fx == [.runUndo(groupID: "g-9")], "run is an explicit intent, never implicit")
    }

    @Test("UX-UNDO-09 duplicate undo after success is idempotent notice")
    func UX_UNDO_09_duplicateIsNotice() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.undoOutcome(outcome: UIUndoOutcome(
            groupID: "g-1", applied: ["a"], refused: [], failed: [],
            notice: "already applied: duplicate request returned the recorded disposition"))))
        guard case .undoOutcome(let outcome) = state.inspection else {
            Issue.record("outcome view must project"); return
        }
        #expect(outcome.notice.contains("already applied"))
    }

    @Test("UX-UNDO preview shows eligible set, conflicts and limits")
    func UX_UNDO_previewEligibility() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.undoPreview(preview: UIUndoPreview(
            groupID: "g-2",
            files: [undoFile("a", eligible: true), undoFile("b", eligible: false, conflict: "changed by user")],
            canRun: false,
            notice: "1 conflict blocks the run"))))
        guard case .undoPreview(let preview) = state.inspection else {
            Issue.record("undo preview must project"); return
        }
        #expect(!preview.canRun && preview.files.count == 2)
        #expect(preview.files[1].conflict == "changed by user", "user edit conflict visible, never overwritten")
    }

    @Test("UX-NAV-07 diff shows agent, user and mixed provenance bounded")
    func UX_NAV_07_diffProvenance() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: "agent.swift", provenance: .agent, hunks: ["+new line"]),
            UIDiffFile(path: "notes.md", provenance: .user, hunks: ["-old"]),
            UIDiffFile(path: "mix.swift", provenance: .mixed, hunks: ["+a", "-b"]),
        ])))
        guard case .diff(let files) = state.inspection else {
            Issue.record("diff view must project"); return
        }
        #expect(files.count == 3)
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let ids = Set(frame.lines.map(\.id))
        #expect(ids.contains("diff-agent.swift") && ids.contains("diff-notes.md") && ids.contains("diff-mix.swift"))
        let text = frame.lines.flatMap(\.runs).map(\.text).joined()
        #expect(text.contains("agent") && text.contains("user") && text.contains("mixed"),
            "provenance labeled, authorship never implied, got: \(text)")
    }

    @Test("UX approval shows exact executable identity and scope")
    func UX_APPROVAL_execIdentity() throws {
        var state = UIState()
        _ = apply(&state, .queueSync(QueueSyncSnapshot(
            entries: [], activeRequest: nil, queueHeld: false, heldReason: nil,
            pendingApproval: ApprovalRequestView(
                requestID: RequestID("r-1"), generation: Revision(3), operation: "exec make",
                requiredGrant: "exec", protectedPaths: ["/work"],
                execIdentities: [ExecIdentitySummary(resolvedPath: "/bin/sh", contentDigest: "aaaaaaaa")],
                sandbox: false),
            admittedCommandIDs: [], liveEpoch: EpochID("e-1"))))
        #expect(state.pendingApproval?.execIdentities.first?.resolvedPath == "/bin/sh")
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let text = frame.lines.flatMap(\.runs).map(\.text).joined()
        #expect(text.contains("/bin/sh") && text.contains("/work"),
            "identity and scope rendered, got: \(text)")
    }

    @Test("UX-UNDO-08 rewind fork is an explicit record-only request")
    func UX_UNDO_08_rewindRequest() throws {
        let (_, fx) = reduce(UIState(), .rewindRequest(boundary: LineageBoundary(epochID: EpochID("e-5"), throughSequence: 42)))
        #expect(fx == [.requestLineageFork(boundary: LineageBoundary(epochID: EpochID("e-5"), throughSequence: 42))],
            "fork request is explicit and record-only")
    }
}
