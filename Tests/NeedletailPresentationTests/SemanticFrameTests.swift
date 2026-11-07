import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// B5 RED: deterministic semantic frames, bounded output, and the
/// headless-consumer architectural gate (six capabilities).
/// Fails until GREEN implements the frame cap + consumer proof.
struct SemanticFrameTests {

    private func apply(_ state: inout UIState, _ action: UIAction) -> [UIEffect] {
        let r = reduce(state, action)
        state = r.0
        return r.1
    }

    @Test("B5 frame output is bounded with a visible marker")
    func B5_frameBounded() throws {
        var state = UIState()
        let rows = (0..<300).map { i in
            QueueSummary(entryID: "q-\(i)", commandID: CommandID("c-\(i)"),
                kind: "followUp", state: "queued", revision: 1,
                delivery: .queued, pending: false,
                isOptimistic: false, staleTarget: false, hasAttachments: false)
        }
        state.queue = rows
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(frame.lines.count <= maxFrameLines, "absolute bound holds")
        // Directional and discriminating: the OLDEST maxQueueRows survive.
        let queueLines = frame.lines.filter { $0.id.hasPrefix("queue-q-") }
        #expect(queueLines.count == maxQueueRows, "exactly the cap renders, got \(queueLines.count)")
        #expect(frame.lines.contains(where: { $0.id == "queue-q-0" }), "oldest row kept")
        #expect(frame.lines.contains(where: { $0.id == "queue-q-63" }), "cap edge kept")
        #expect(!frame.lines.contains(where: { $0.id == "queue-q-64" }), "newest rows drop")
        #expect(frame.lines.contains(where: { $0.id == "queue-truncated" }),
            "truncation is visible, never silent")
        let marker = frame.lines.first(where: { $0.id == "queue-truncated" })!
        #expect(marker.runs.map(\.text).joined().contains("236 more"),
            "hidden count reported, got: \(marker.runs.map(\.text).joined())")
    }

    @Test("B5 absolute frame bound holds with a marker under wrap overflow")
    func B5_frameAbsoluteBound() throws {
        var state = UIState()
        // 200 epoch rows with long prefill: each wraps to ~3 lines at
        // width 80, forcing well past the 512-line bound.
        _ = apply(&state, .inspectResult(.epochs(rows: (0..<200).map { i in
            UIEpochRow(epochID: "e-\(i)", parentID: "e-0",
                checkpoint: .success(costMillis: 1),
                prefill: String(repeating: "p", count: 180))
        })))
        for caps in [TerminalCapabilities(), TerminalCapabilities.dumb] {
            let frame = render(state, width: 80, capabilities: caps)
            #expect(frame.lines.count <= maxFrameLines,
                "absolute bound holds, got \(frame.lines.count)")
            #expect(frame.lines.contains(where: { $0.id == "frame-truncated" }),
                "overflow is marked")
        }
        let dumb = render(state, width: 80, capabilities: TerminalCapabilities.dumb)
        #expect(dumb.lines.contains(where: { $0.id == "composer-inline" }),
            "inline composer survives the cap in dumb mode")
    }

    @Test("B5 hostile bytes stay inert in text, ids and overlay")
    func B5_hostileBytesInert() throws {
        let evil = "x\u{1b}]0;pwned\u{07}y\u{202E}z"
        var state = UIState()
        func checkClean(_ state: UIState, _ where_: String = #function) {
            for caps in [TerminalCapabilities(), TerminalCapabilities.dumb] {
                let frame = render(state, width: 200, capabilities: caps)
                var blobs = frame.lines.flatMap(\.runs).map(\.text)
                blobs.append(contentsOf: frame.lines.map(\.id))
                if let overlay = frame.composerOverlay {
                    blobs.append(overlay.text)
                }
                for blob in blobs {
                    #expect(!blob.contains("\u{1b}"), "no escape survives (\(where_)): \(blob.debugDescription)")
                    #expect(!blob.contains("\u{202E}"), "no bidi survives (\(where_))")
                    #expect(!blob.contains("\u{07}"), "no BEL survives (\(where_))")
                }
            }
        }
        _ = apply(&state, .input(.insertText(evil)))
        checkClean(state, "composer")
        _ = apply(&state, .queueSync(QueueSyncSnapshot(
            entries: [QueueEntry(entryID: evil, commandID: CommandID(evil), kind: .followUp,
                state: .queued, revision: 1, text: evil, targetEpochID: EpochID(evil),
                orderKey: 1, rank: 1.0)],
            activeRequest: nil, queueHeld: true, heldReason: .error(evil),
            pendingApproval: ApprovalRequestView(
                requestID: RequestID("r-1"), generation: Revision(1), operation: evil,
                requiredGrant: evil, protectedPaths: [evil],
                execIdentities: [ExecIdentitySummary(resolvedPath: evil, contentDigest: evil)],
                sandbox: false),
            admittedCommandIDs: [], liveEpoch: EpochID("e-1"))))
        checkClean(state, "queue+approval")
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: evil + ".md", provenance: .user, hunks: ["\u{1b}[3J" + evil]),
        ])))
        checkClean(state, "diff")
        _ = apply(&state, .inspectResult(.undoPreview(preview: UIUndoPreview(
            groupID: evil, files: [UIUndoFile(path: evil, eligible: false, conflict: evil)],
            canRun: false, notice: evil))))
        checkClean(state, "undo")
        _ = apply(&state, .inspectResult(.sessions(rows: [
            UISessionRow(sessionID: SessionID(evil), phase: evil, lastActivityMillis: nil,
                routeAlias: evil, locality: evil, modelAlias: evil, isLive: false),
        ], asOfMillis: 1)))
        checkClean(state, "sessions")
        _ = apply(&state, .inspectResult(.models(routes: [
            UIModelRoute(alias: evil, locality: evil, kind: .local, models: [evil])])))
        checkClean(state, "models")
        _ = apply(&state, .inspectResult(.agents(rows: [
            UIAgentRow(alias: evil, phase: evil, childActivity: evil)])))
        checkClean(state, "agents")
        _ = apply(&state, .inspectResult(.compact(preview: UICompactPreview(
            estimatedTokens: 1, wouldReplaceEpoch: true, note: evil))))
        checkClean(state, "compact")
        _ = apply(&state, .inspectResult(.epochs(rows: [
            UIEpochRow(epochID: evil, parentID: evil, checkpoint: .failed(reason: evil), prefill: evil)])))
        checkClean(state, "epochs")
        // Mention popup with hostile path + hostile range error.
        state.suggestion = MentionSuggestionState(query: evil, revision: 1,
            candidates: [CandidateFile(path: evil)],
            selectedIndex: 0, rangeError: evil)
        checkClean(state, "suggestion")
    }

    @Test("B5 same query twice requests completions once")
    func B5_noDuplicateFetch() throws {
        var state = UIState()
        let first = apply(&state, .input(.insertText("@doc")))
        #expect(first.count == 1, "first query fetches")
        _ = apply(&state, .input(.moveCursor(-1)))
        _ = apply(&state, .input(.moveCursor(1)))
        let third = apply(&state, .input(.insertText("")))
        #expect(!third.contains(where: {
            if case .requestCompletions = $0 { return true }; return false
        }), "identical query never refetches, got \(third)")
    }

    @Test("B5 render is pure: no state change, identical full frames")
    func B5_renderPure() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("@doc")))
        let before = state
        let f1 = render(state, width: 80, capabilities: TerminalCapabilities())
        let f2 = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(state == before, "rendering mutates nothing")
        #expect(f1.lines.map(\.id) == f2.lines.map(\.id)
            && f1.lines.flatMap(\.runs).map(\.text) == f2.lines.flatMap(\.runs).map(\.text)
            && f1.lines.flatMap(\.runs).map(\.role) == f2.lines.flatMap(\.runs).map(\.role),
            "same state renders the same full frame")
}
}
