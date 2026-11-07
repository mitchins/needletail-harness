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

    @Test("UX-RENDER-01 semantic spans stable across widths and plain mode")
    func UX_RENDER_01_widthPlainStability() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("# Title\n- a\n- b")))
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: "f.md", provenance: .agent, hunks: ["+new", "-old", "@@ 1,2 @@"])])))
        let narrow = render(state, width: 40, capabilities: TerminalCapabilities())
        let wide = render(state, width: 120, capabilities: TerminalCapabilities())
        let dumb = render(state, width: 80, capabilities: TerminalCapabilities.dumb)
        // Lines plus the composer surface (overlay in capable mode,
        // inline line in dumb mode): same content everywhere.
        func full(_ f: RenderFrame) -> String {
            // Non-composer lines must be identical; the composer surface
            // (overlay vs "> "-prefixed inline line) is compared separately.
            f.lines.filter({ $0.id != "composer-inline" }).flatMap(\.runs).map(\.text).joined()
        }
        func composerText(_ f: RenderFrame) -> String {
            if let overlay = f.composerOverlay { return overlay.text }
            return f.lines.first(where: { $0.id == "composer-inline" })
                .map { $0.runs.map(\.text).joined() } ?? ""
        }
        #expect(full(narrow) == full(wide), "width changes layout, not content")
        #expect(full(dumb) == full(wide), "plain mode identical content")
        #expect(composerText(dumb) == "> " + composerText(wide), "inline mirrors overlay")
        for line in narrow.lines.flatMap(\.runs) + wide.lines.flatMap(\.runs) + dumb.lines.flatMap(\.runs) {
            #expect(!line.text.contains("\u{1b}"), "never emits ANSI bytes")
        }
    }

    @Test("UX-RENDER-02 markup renders literally without interpretation")
    func UX_RENDER_02_literalMarkup() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("**bold** `code` ```fence")))
        let frame = render(state, width: 40, capabilities: TerminalCapabilities())
        let text = frame.lines.flatMap(\.runs).map(\.text).joined()
            + (frame.composerOverlay.map(\.text) ?? "")
        #expect(text.contains("**bold**") && text.contains("`code`"), "no markdown interpretation, got: \(text)")
    }

    @Test("UX-RENDER-03 diff hunks preserve exact source bytes and roles")
    func UX_RENDER_03_diffExactness() throws {
        var state = UIState()
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: "f", provenance: .mixed, hunks: ["+a", "-b", "@@ 1 @@", "\\ No newline"])])))
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let texts = frame.lines.flatMap(\.runs).map(\.text)
        #expect(texts.contains("+a") && texts.contains("-b") && texts.contains("@@ 1 @@"),
            "source-change bytes exact, got: \(texts)")
    }

    @Test("UX-RENDER-04 controls neutralized before output")
    func UX_RENDER_04_controlBattery() throws {
        let hostile = ["\u{00}\u{07}\u{1b}[0m\u{9b}0m\u{90}x\u{9c}", "\u{202A}\u{2066}\u{200E}"]
        var state = UIState()
        _ = apply(&state, .input(.insertText(hostile.joined(separator: "|"))))
        _ = apply(&state, .inspectResult(.diff(files: [
            UIDiffFile(path: hostile[0], provenance: .user, hunks: hostile)])))
        let frame = render(state, width: 200, capabilities: TerminalCapabilities())
        for run in frame.lines.flatMap(\.runs) {
            for s in run.text.unicodeScalars {
                #expect(s.properties.generalCategory != .control, "no Cc survives")
                #expect(s.properties.generalCategory != .format, "no Cf survives")
            }
        }
        for id in frame.lines.map(\.id) {
            for s in id.unicodeScalars {
                #expect(s.properties.generalCategory != .control && s.properties.generalCategory != .format,
                    "ids sanitized too, got: \(id.debugDescription)")
            }
        }
    }

    @Test("UX-RENDER-05 wrapping never splits grapheme clusters")
    func UX_RENDER_05_clusterSafeWrap() throws {
        // Flags ride in a candidate path so they flow through wrapped
        // LINES (the composer overlay is never wrapped).
        let flags = String(repeating: "🇺🇸", count: 60)
        var state = UIState()
        _ = apply(&state, .input(.insertText("@f")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: flags)])))
        for width in [40, 80, 120] {
            let frame = render(state, width: width, capabilities: TerminalCapabilities())
            let text = frame.lines.flatMap(\.runs).map(\.text).joined()
            #expect(text.unicodeScalars.count >= flags.unicodeScalars.count,
                "no scalar lost at width \(width)")
            #expect(!text.contains("\u{FFFD}"), "no replacement from splitting")
            #expect(text.contains(flags), "cluster sequence intact at width \(width)")
        }
    }

    @Test("UX-RENDER-06 narrow and dumb terminals keep identical content")
    func UX_RENDER_06_plainFallback() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("hello @doc")))
        _ = apply(&state, .completion(CompletionResult(queryRevision: state.suggestion!.revision,
            candidates: [CandidateFile(path: "doc.md")])))
        let capable = render(state, width: 20, capabilities: TerminalCapabilities())
        let dumb = render(state, width: 20, capabilities: TerminalCapabilities.dumb)
        let capableText = capable.lines.flatMap(\.runs).map(\.text).joined()
            + (capable.composerOverlay.map(\.text) ?? "")
        let dumbText = dumb.lines.flatMap(\.runs).map(\.text).joined()
        #expect(capableText.contains("hello @doc") && dumbText.contains("hello @doc"))
        #expect(capable.composerOverlay != nil && dumb.composerOverlay == nil,
            "overlay vs inline is the only difference")
    }

    @Test("UX-RENDER-07 bounded chunks never drop core evidence")
    func UX_RENDER_07_boundedNoLoss() throws {
        var state = UIState()
        let rows = (0..<1000).map { i in
            QueueSummary(entryID: "q-\(i)", commandID: CommandID("c-\(i)"),
                kind: "followUp", state: "queued", revision: 1,
                delivery: .queued, pending: false,
                isOptimistic: false, staleTarget: false, hasAttachments: false)
        }
        state.queue = rows
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        #expect(frame.lines.count <= maxFrameLines)
        #expect(frame.lines.contains(where: { $0.id == "queue-truncated" }), "marked")
        #expect(frame.lines.contains(where: { $0.id == "queue-q-0" }), "oldest evidence kept")
    }

    @Test("UX-RENDER-08 rendering never mutates canonical bytes")
    func UX_RENDER_08_noMutation() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("exact *bytes* here")))
        let before = state
        for width in [20, 80, 200] {
            for caps in [TerminalCapabilities(), TerminalCapabilities.dumb] {
                _ = render(state, width: width, capabilities: caps)
            }
        }
        #expect(state == before, "reparse/reflow for display changes nothing")
        #expect(state.composer.text == "exact *bytes* here", "canonical bytes intact")
    }

    @Test("DX-09 frame output is PTY-safe by construction")
    func DX_09_framePTYSafe() throws {
        var state = UIState()
        _ = apply(&state, .input(.insertText("status @x")))
        _ = apply(&state, .session(.runUpdate(phase: "streaming", detail: "tokens")))
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        for run in frame.lines.flatMap(\.runs) {
            #expect(!run.text.contains("\u{1b}") && !run.text.contains("\u{9b}") && !run.text.contains("\u{90}"),
                "no screen-control sequence can reach a terminal, got: \(run.text.debugDescription)")
        }
    }

    @Test("DX-10 hostile interleavings replay deterministically without sleeps")
    func DX_10_replayDeterministic() throws {
        // No sleeps anywhere in this target's replay path by construction
        // (VirtualClock + scripted seams); this pins repeatability.
        for seed in [1, 7, 40] as [UInt64] {
            let trace = PermutationTests.script(seed: seed, length: 12)
            let first = PermutationTests.replay(trace)
            #expect(first.violations.isEmpty, "seed \(seed) holds")
            #expect(PermutationTests.replay(trace).draft == first.draft
                && PermutationTests.replay(trace).effects == first.effects,
                "repeatable without timing, seed \(seed)")
        }
    }
}
