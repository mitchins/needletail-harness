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
        case tab
        case up
        case down
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
            return actionsForSlash(line, state: state, commandID: commandID)
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
        case warnPending
        case exit
    }

    /// M4-D D2.5 (spec §2.1 ¶746): idle-empty Ctrl+C EXITS when there is
    /// no queued/unsent work, and warns (asks) when there is — a second
    /// consecutive idle-empty Ctrl+C exits. The M4-C idle-empty hint is
    /// replaced by this authorized behavior change (receipt as-built
    /// delta). `exitArmed` is the loop-owned two-press latch.
    public static func ctrlCAction(busy: Bool, armed: Bool, draftNonEmpty: Bool, queuePending: Bool, exitArmed: Bool) -> CtrlCAction {
        if armed { return .clearBuffer }
        if busy { return .cancelRun }
        if draftNonEmpty { return .clearBuffer }
        if queuePending, !exitArmed { return .warnPending }
        return .exit
    }

    /// Key map: Ctrl+J → newline into the live buffer (via `set_state`,
    /// never a commit); Esc → dismiss (reducer noops when no popup is
    /// live — same observable as suppressing, so always dispatch).
    /// Ctrl+C is NOT mapped here: the loop owns the latch-aware
    /// decision (`ctrlCAction` + two-press exit latch, M4-D D2.5) on
    /// both the live bindKey path and the scripted `.key` path.
    public static func actionsForKey(_ key: KeyPress, state: UIState) -> [UIAction] {
        switch key {
        case .ctrlC:
            return []
        case .tab, .up, .down:
            // Loop-driven (Tab-accept, arrow selection): the loop owns
            // these via the latch-aware paths, not the pure key map.
            return []
        case .ctrlJ:
            return [.input(.newline)]
        case .esc:
            return [.mention(.dismissSuggestion)]
        }
    }

    /// Pending-work warning for the two-press exit latch (idle-empty
    /// Ctrl+C with queued entries). Adapter-local.
    public static let pendingExitWarning = "queued work pending — submit, withdraw, or Ctrl+C again to exit"

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
        // Full clear is a boundary (M4-D D2 review): route through
        // replaceDraft so tokens/suggestion clear with the draft — a
        // per-key delete sequence would leave accepted file tokens
        // attached to an empty composer (stale file on next submit).
        if text.isEmpty {
            return [.input(.replaceDraft(""))]
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

    /// M4-D D3 review: pending-queue predicate for the exit latch.
    /// Dispatched/history/withdrawn rows are DONE — only queued, held,
    /// heldUnknown, pending, or optimistic (unconfirmed) rows block
    /// exit. (state.queue retains history rows, so a bare non-empty
    /// check would warn forever after the first queued turn.)
    public static func hasPendingQueueEntries(state: UIState) -> Bool {
        state.queue.contains { entry in
            entry.isOptimistic || entry.pending
                || entry.state == "queued" || entry.state == "held"
                || entry.state == "heldUnknown"
        }
    }

    /// M4-D D2 Tab-accept gate (pure, shared by the input-thread
    /// buffer sync and the main-task dispatch): what `acceptSelected`
    /// WOULD produce, or nil when there is nothing safe to accept.
    /// Computed THROUGH the pure reducer (no duplicated span logic).
    /// The inserted candidate segment must be display-safe (M4-C
    /// injection rule: hostile paths never reach the live line; the
    /// semantic popup still lists everything through `terminalSafe`).
    /// A nil gate means "leave text and state untouched".
    public static func acceptPreview(state: UIState) -> (text: String, cursor: Int)? {
        guard state.suggestion != nil else { return nil }
        let before = state.tokens.count
        let (next, _) = reduce(state, .mention(.acceptSelected))
        guard next.tokens.count == before + 1, let token = next.tokens.last else { return nil }
        var inserted = token.path
        if let range = token.lineRange {
            inserted += range.lowerBound == range.upperBound
                ? "#L\(range.lowerBound)" : "#L\(range.lowerBound)-L\(range.upperBound)"
        }
        guard isDisplaySafePath(inserted) else { return nil }
        return (next.composer.text, next.composer.cursor)
    }

    /// Injection rule (M4-C, retained and enforced by `acceptPreview`
    /// in M4-D D2): candidates render DIRECTLY in replxx (no sanitizer
    /// on that path), so only display-safe paths are accepted: any
    /// path the sanitizer would rewrite (control/Cf bytes, e.g. a
    /// model-written hostile filename) — or containing LF, which
    /// `displaySafe` preserves but which would split the live line —
    /// is refused, never inserted. The semantic popup (rendered
    /// frames) still lists everything through `terminalSafe`.
    /// (The M4-C revision-keyed sync-serve cache is retired: Tab is
    /// loop-driven now. This comment anchors the removal for review.)
    public static func isDisplaySafePath(_ path: String) -> Bool {
        path == displaySafe(path) && !path.contains("\n")
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

    private static func actionsForSlash(_ line: String, state: UIState, commandID: CommandID) -> SubmitOutcome {
        let body = String(line.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first?.lowercased() else {
            return .notice("usage: /steer /queue /undo /preview /models /sessions /agents /context /epochs /compact /diff /rewind /cancel /keys", actions: [clearMirror()])
        }
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "steer":
            guard !rest.isEmpty, rest.utf8.count <= maxComposerBytes else {
                return .notice("usage: /steer <text> (≤ 64 KiB)", actions: [clearMirror()])
            }
            return .actions([.queueOp(.submitSteer(text: rest, commandID: commandID)), clearMirror()])
        case "queue":
            guard !rest.isEmpty else {
                return .actions([.inspect(.queue), clearMirror()])
            }
            return queueSubcommand(rest, state: state)
        case "undo":
            if rest.isEmpty {
                // Bare `/undo`: latest-eligible-group preview (read-only;
                // runs always need an explicit group — never guessed).
                return .actions([.undoIntent(.previewLatest), clearMirror()])
            }
            if rest == "run" {
                return .notice("usage: /undo run <group> (runs need an explicit group)", actions: [clearMirror()])
            }
            if rest.hasPrefix("run ") {
                return .actions([.undoIntent(.run(groupID: String(rest.dropFirst(4)))), clearMirror()])
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
        case "preview":
            // Spec §2.2 keyboard/dumb-terminal fallback: `/preview @path`
            // or `/preview path`. Ranges belong to attach, not preview.
            var target = rest
            if target.hasPrefix("@") { target = String(target.dropFirst()) }
            guard !target.isEmpty, !target.contains("#") else {
                return .notice("usage: /preview @path", actions: [clearMirror()])
            }
            return .actions([.inspect(.filePreview(path: target)), clearMirror()])
        case "models":
            guard rest.isEmpty else {
                return .notice("usage: /models", actions: [clearMirror()])
            }
            return .actions([.inspect(.models), clearMirror()])
        case "sessions":
            guard rest.isEmpty else {
                return .notice("usage: /sessions", actions: [clearMirror()])
            }
            return .actions([.inspect(.sessions), clearMirror()])
        case "agents":
            guard rest.isEmpty else {
                return .notice("usage: /agents", actions: [clearMirror()])
            }
            return .actions([.inspect(.agents), clearMirror()])
        case "context":
            guard rest.isEmpty else {
                return .notice("usage: /context", actions: [clearMirror()])
            }
            return .actions([.inspect(.context), clearMirror()])
        case "epochs":
            guard rest.isEmpty else {
                return .notice("usage: /epochs", actions: [clearMirror()])
            }
            return .actions([.inspect(.epochs), clearMirror()])
        case "compact":
            guard rest.isEmpty else {
                return .notice("usage: /compact", actions: [clearMirror()])
            }
            return .actions([.inspect(.compactDryRun), clearMirror()])
        case "diff":
            guard rest.isEmpty else {
                return .notice("usage: /diff", actions: [clearMirror()])
            }
            return .actions([.inspect(.diff), clearMirror()])
        case "help":
            return .notice("not yet in interactive mode: /help — see /keys", actions: [clearMirror()])
        default:
            return .notice("unknown command /\(verb) — " + slashHelp, actions: [clearMirror()])
        }
    }

    private static func parseRewind(_ text: String) -> LineageBoundary? {
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, let seq = UInt64(parts[1]) else { return nil }
        return LineageBoundary(epochID: EpochID(parts[0]), throughSequence: seq)
    }

    /// M4-D D2: `/queue` subcommands. Indexing is 1-based over the
    /// displayed queue order (`state.queue`, the same rows Render
    /// shows). Unknown indices and malformed shapes are usage notices;
    /// entry existence/revision conflicts are Core's to judge (the
    /// edge passes IDs through, never invents them).
    private static func queueSubcommand(_ rest: String, state: UIState) -> SubmitOutcome {
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first?.lowercased() else {
            return .notice("usage: /queue [resume|edit <n> <text>|withdraw <n>|reorder <n> [before <m>]]", actions: [clearMirror()])
        }
        switch verb {
        case "resume":
            guard parts.count == 1 else {
                return .notice("usage: /queue resume", actions: [clearMirror()])
            }
            return .actions([.queueOp(.resumeQueue), clearMirror()])
        case "withdraw", "edit", "reorder":
            guard parts.count >= 2, let index = Int(parts[1]), index >= 1, index <= state.queue.count else {
                let count = state.queue.count
                let shape = verb == "edit" ? " <text>" : verb == "reorder" ? " [before <m>]" : ""
                return .notice("usage: /queue \(verb) <n>\(shape) (1…\(count) queued)", actions: [clearMirror()])
            }
            let entry = state.queue[index - 1]
            if verb == "withdraw" {
                guard parts.count == 2 else {
                    return .notice("usage: /queue withdraw <n>", actions: [clearMirror()])
                }
                return .actions([.queueOp(.withdrawEntry(entryID: entry.entryID)), clearMirror()])
            }
            if verb == "edit" {
                guard parts.count == 3, !parts[2].isEmpty, parts[2].utf8.count <= maxComposerBytes else {
                    return .notice("usage: /queue edit <n> <text> (≤ 64 KiB)", actions: [clearMirror()])
                }
                return .actions([.queueOp(.editEntry(entryID: entry.entryID, newText: parts[2], baseRevision: entry.revision)), clearMirror()])
            }
            // reorder <n> [before <m>]: m omitted moves to the head.
            var beforeID: String? = nil
            if parts.count == 3 {
                let tail = parts[2].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard tail.count == 2, tail[0].lowercased() == "before", let m = Int(tail[1]), m >= 1, m <= state.queue.count, m != index else {
                    return .notice("usage: /queue reorder <n> [before <m>]", actions: [clearMirror()])
                }
                beforeID = state.queue[m - 1].entryID
            } else if parts.count > 3 {
                return .notice("usage: /queue reorder <n> [before <m>]", actions: [clearMirror()])
            }
            return .actions([.queueOp(.reorderEntry(entryID: entry.entryID, beforeID: beforeID)), clearMirror()])
        default:
            return .notice("usage: /queue [resume|edit <n> <text>|withdraw <n>|reorder <n> [before <m>]]", actions: [clearMirror()])
        }
    }

    private static let slashHelp =
        "commands: /steer <text> /queue [resume|edit|withdraw|reorder] /undo [run <group>] /preview @path /models /sessions /agents /context /epochs /compact /diff /rewind <epoch>#<seq> /cancel /keys"
}
