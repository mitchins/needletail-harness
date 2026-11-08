import Foundation
import NeedletailCore
import NeedletailPresentation

/// M4-C composer bridge (pure submit/key/slash mapping, adapter tier).
///
/// The bridge proposes `UIAction`s from committed replxx lines and key
/// events. It never touches `SessionActor`, never mints queue identity
/// (commandIDs arrive edge-minted; retries reuse the same ID — dedup is
/// Core admission idempotency), never approves natively. Approval rows
/// are non-actionable here: the bridge produces NO `.decideApproval`
/// path (C5 asserts this); the interactive approval decision flows
/// solely through `ReplxxApprovalGateway`.
///
/// Draft rule: the replxx buffer is authoritative live; the bridge
/// emits `replaceDraft` ONLY at submit/clear boundaries (with the exact
/// line), after the 64 KiB cap pre-check on BOTH branches. Slash
/// commands consume the line and clear the mirror.
public enum ComposerBridge {
    public enum KeyPress: Sendable, Equatable {
        case ctrlC
        case ctrlJ
        case esc
    }

    public enum SubmitOutcome: Sendable, Equatable {
        case actions([UIAction])
        /// Over-cap or otherwise rejected: buffer preserved, operator
        /// shown `reason`. Never submits, never clears.
        case rejected(reason: String)
        /// Adapter-local notices (help, deferred, usage): caller renders
        /// `notice` through the output owner, dispatches `actions`.
        case notice(String, actions: [UIAction])
    }

    /// Maps one committed line. Slash lines dispatch commands; plain
    /// lines submit (idle) or queue a follow-up (busy, SPEC ¶744).
    public static func actionsForSubmitLine(
        _ line: String,
        state: UIState,
        commandID: CommandID
    ) -> SubmitOutcome {
        if line.utf8.count > maxComposerBytes {
            return .rejected(reason: "draft exceeds 64 KiB; edit or clear before submitting")
        }
        if line.hasPrefix("/") {
            return actionsForSlash(line, commandID: commandID)
        }
        if case .busy = state.status {
            // Busy: queue a follow-up, never submit (SPEC ¶744); clear
            // the mirror so the queued text cannot be re-submitted.
            return .actions([
                .queueOp(.submitFollowUp(text: line, commandID: commandID)),
                .input(.replaceDraft("")),
            ])
        }
        return .actions([
            .input(.replaceDraft(line)),
            .input(.submitDraft(commandID: commandID)),
        ])
    }

    /// Ctrl+C decision (pure, tested): armed confirm ALWAYS clears the
    /// live buffer (even mid-run — approvals arrive while busy; cancel
    /// would deny the pending request the prompt asks about); busy
    /// cancels; idle-nonempty clears; idle-empty hints. The handler
    /// executes the buffer edit via `set_state` (mirror syncs); only
    /// `.cancel` posts a key event (actor effect).
    public enum CtrlCAction: Sendable, Equatable {
        case cancelRun
        case clearBuffer
        case hint
    }

    public static func ctrlCAction(busy: Bool, armed: Bool, draftNonEmpty: Bool) -> CtrlCAction {
        if armed { return .clearBuffer }
        if busy { return .cancelRun }
        return draftNonEmpty ? .clearBuffer : .hint
    }

    /// Key map: Ctrl+C → see `ctrlCAction`; Ctrl+J → newline into the
    /// live buffer (via `set_state`, never a commit); Esc → dismiss
    /// (reducer noops when no popup is live — same observable as
    /// suppressing, so always dispatch).
    public static func actionsForKey(_ key: KeyPress, state: UIState) -> [UIAction] {
        switch key {
        case .ctrlC:
            if case .busy = state.status {
                return [.queueOp(.cancelRun)]
            }
            if !state.composer.text.isEmpty {
                return [.input(.replaceDraft(""))]
            }
            return []
        case .ctrlJ:
            return [.input(.newline)]
        case .esc:
            return [.mention(.dismissSuggestion)]
        }
    }

    /// Operator hint for a no-op key (idle-empty Ctrl+C). Adapter-local.
    public static let idleEmptyHint = "composer empty — type text, /keys for commands"

    /// Interactive overlay suppression: replxx owns the live line, so
    /// the semantic `composerOverlay` must not double-draw it (and must
    /// not route ZWJ drafts through `terminalSafe`). Adapter-local.
    public static func frameForInteractive(_ frame: RenderFrame) -> RenderFrame {
        // Dumb/non-addressable frames ALSO carry an inline composer line
        // (`composer-inline` + wrapped continuations) — dropped here for
        // the same reason (replxx renders the prompt itself on every
        // path; double-draw would also route ZWJ drafts through
        // `terminalSafe`). Adapter-local.
        RenderFrame(
            lines: frame.lines.filter { $0.id != "composer-inline" && !$0.id.hasPrefix("composer-inline#") },
            statusLine: frame.statusLine, composerOverlay: nil, width: frame.width)
    }

    // MARK: - Live mirror (modify-callback → fine-grained proposals)

    /// Maps a replxx modify event to reducer actions. replxx positions
    /// are UTF-32 code points = Swift scalar offsets (exact). Emits the
    /// minimal edit script (move/delete/insert — never `replaceDraft`,
    /// so the mention popup survives typing); convergent (equal states
    /// ⇒ no actions). Multi-line or large single-event insertions are
    /// mirrored as `pasteLiteral` (bracketed-paste heuristic, SPEC
    /// ¶751: pasted `@` stays literal) — replxx consumes the bracket
    /// markers, so insertion shape is the only signal; per-keystroke
    /// typing never trips it (one scalar per event).
    public static func actionsForMirror(text: String, cursor: Int, state: UIState) -> [UIAction] {
        let oldText = state.composer.text
        let oldCursor = state.composer.cursor
        if text == oldText {
            return cursor == oldCursor ? [] : [.input(.moveCursor(cursor - oldCursor))]
        }
        let oldScalars = Array(oldText.unicodeScalars)
        let newScalars = Array(text.unicodeScalars)
        var prefix = 0
        while prefix < oldScalars.count, prefix < newScalars.count, oldScalars[prefix] == newScalars[prefix] {
            prefix += 1
        }
        // Common suffix of the differing tails: only [prefix, oldCount -
        // suffix) is replaced, so mid-text edits converge exactly.
        var suffix = 0
        while suffix < (oldScalars.count - prefix), suffix < (newScalars.count - prefix),
              oldScalars[oldScalars.count - 1 - suffix] == newScalars[newScalars.count - 1 - suffix] {
            suffix += 1
        }
        let deleteEnd = oldScalars.count - suffix
        let deleteCount = max(0, deleteEnd - prefix)
        let middle = String(String.UnicodeScalarView(newScalars.dropFirst(prefix).dropLast(suffix)))
        var actions: [UIAction] = []
        let toDeleteEnd = deleteEnd - oldCursor
        if toDeleteEnd != 0 { actions.append(.input(.moveCursor(toDeleteEnd))) }
        if deleteCount > 0 { actions.append(.input(.deleteBackward(deleteCount))) }
        if !middle.isEmpty {
            let pasted = middle.contains("\n") || middle.unicodeScalars.count > 32
            actions.append(.input(pasted ? .pasteLiteral(middle) : .insertText(middle)))
        }
        let landed = prefix + middle.unicodeScalars.count
        let adjust = cursor - landed
        if adjust != 0 { actions.append(.input(.moveCursor(adjust))) }
        return actions
    }

    // MARK: - Completion cache (revision-keyed, sync serve)

    /// Revision-keyed candidate cache (C3): replxx demands candidates
    /// synchronously, so the async edge fetch stores here and the sync
    /// callback serves only the live revision. Bounded (latest two
    /// revisions); pruned on submit/clear.
    public struct CompletionCache: Sendable {
        private var entries: [UInt64: [CandidateFile]] = [:]

        public init() {}

        public mutating func store(_ candidates: [CandidateFile], revision: UInt64) {
            entries[revision] = candidates
            while entries.count > 2 {
                entries.removeValue(forKey: entries.keys.min()!)
            }
        }

        public mutating func dropAll() { entries.removeAll() }

        public func candidates(forRevision revision: UInt64) -> [CandidateFile]? {
            entries[revision]
        }
    }

    /// Serves the sync completion callback: candidates ONLY when the
    /// cached revision equals the live composer revision AND the input
    /// still matches the live suggestion query (otherwise stale —
    /// DX-02: serve nothing). Tab before the async fetch returns serves
    /// nothing. Returns display paths.
    ///
    /// Injection rule: candidates render DIRECTLY in replxx (no
    /// sanitizer on that path), so only display-safe paths are served:
    /// any path the sanitizer would rewrite (control/Cf bytes, e.g. a
    /// model-written hostile filename) — or containing LF, which
    /// `displaySafe` preserves but which would split the live line —
    /// is dropped, never inserted. The semantic popup (rendered
    /// frames) still lists everything through `terminalSafe`.
    public static func isDisplaySafePath(_ path: String) -> Bool {
        path == displaySafe(path) && !path.contains("\n")
    }
    public static func completionCandidates(
        input: String,
        cursor: Int,
        cache: CompletionCache,
        state: UIState
    ) -> [String] {
        guard let suggestion = state.suggestion,
              suggestion.revision == state.composer.revision,
              let live = mentionQuery(text: state.composer.text, cursor: state.composer.cursor),
              live.query == suggestion.query,
              live.query == mentionQuery(text: input, cursor: cursor)?.query,
              let cached = cache.candidates(forRevision: suggestion.revision)
        else { return [] }
        return cached.map(\.path).filter(isDisplaySafePath)
    }

    // MARK: - Command IDs (retry reuses the same ID)

    /// Deduplication aid: the edge mints one UUID per submission; a
    /// retry of the SAME text reuses its ID (dedup is Core admission
    /// idempotency — the adapter just keeps the mapping). New text
    /// mints and remembers.
    public struct CommandIDStore: Sendable {
        private var lastText: String?
        private var lastID: CommandID?

        public init() {}

        public mutating func id(for text: String, mint: () -> CommandID) -> CommandID {
            if text == lastText, let lastID { return lastID }
            let fresh = mint()
            lastText = text
            lastID = fresh
            return fresh
        }
    }

    // MARK: - Confirm mode (approval y/N serialized through replxx)

    /// Interprets a confirm-armed `readLine` result: explicit `y`/`yes`
    /// approves; EOF/cancel/empty/anything else denies (fail-closed,
    /// matching `TerminalApprovalGateway` semantics).
    public static func interpretConfirmLine(_ line: String?) -> Bool {
        guard let line else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "y" || trimmed == "yes"
    }

    // MARK: - Slash

    private static func clearMirror() -> UIAction { .input(.replaceDraft("")) }

    private static func actionsForSlash(_ line: String, commandID: CommandID) -> SubmitOutcome {
        let body = String(line.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first?.lowercased() else {
            return .notice("usage: /steer /queue /undo /rewind /compact /cancel /keys", actions: [clearMirror()])
        }
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "steer":
            guard !rest.isEmpty, rest.utf8.count <= maxComposerBytes else {
                return .notice("usage: /steer <text> (≤ 64 KiB)", actions: [clearMirror()])
            }
            return .actions([.queueOp(.submitSteer(text: rest, commandID: commandID)), clearMirror()])
        case "queue":
            guard rest.isEmpty else {
                // /queue resume|edit|withdraw are deferred (explicit
                // message, never silent inspect).
                return .notice("/queue resume|edit|withdraw are not yet in interactive mode", actions: [clearMirror()])
            }
            return .actions([.inspect(.queue), clearMirror()])
        case "undo":
            guard !rest.isEmpty else {
                // PARTIAL: latest-eligible-group resolution edge-side via
                // UndoLedger reconcile is deferred, not in M4-C.
                return .notice("usage: /undo <group>", actions: [clearMirror()])
            }
            return .actions([.undoIntent(.preview(groupID: rest)), clearMirror()])
        case "rewind":
            guard let boundary = parseRewind(rest) else {
                return .notice("usage: /rewind <epochID>#<throughSequence>", actions: [clearMirror()])
            }
            return .actions([.rewindRequest(boundary: boundary), clearMirror()])
        case "compact":
            return .actions([.inspect(.compactDryRun), clearMirror()])
        case "cancel":
            return .actions([.queueOp(.cancelRun), clearMirror()])
        case "keys":
            return .notice(slashHelp, actions: [clearMirror()])
        case "preview", "diff", "agents", "context", "epochs", "sessions", "models", "help":
            return .notice("/\(verb) is not yet in interactive mode", actions: [clearMirror()])
        default:
            return .notice("unknown command /\(verb) — " + slashHelp, actions: [clearMirror()])
        }
    }

    private static func parseRewind(_ text: String) -> LineageBoundary? {
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, let seq = UInt64(parts[1]) else { return nil }
        return LineageBoundary(epochID: EpochID(parts[0]), throughSequence: seq)
    }

    private static let slashHelp =
        "commands: /steer <text> /queue /undo <group> /rewind <epoch>#<seq> /compact /cancel /keys"
}
