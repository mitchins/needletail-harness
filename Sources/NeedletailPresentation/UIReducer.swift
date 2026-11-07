import Foundation
import NeedletailCore

/// M1-B pure UI reducer (UX-DX §3.1). Deterministic: same state + same
/// action + same explicit IDs ⇒ same state + effects. The reducer NEVER
/// mutates `queue` (projection-only — edit/withdraw/resume become effects),
/// never mints queue identity, never touches grants/routes/history, and
/// never performs I/O. Late async results compare revisions and drop.

public func reduce(_ state: UIState, _ action: UIAction) -> (UIState, [UIEffect]) {
    switch action {
    case .input(let input):
        return reduceInput(state, input)
    case .session(let projection):
        return reduceSession(state, projection)
    case .completion(let result):
        return reduceCompletion(state, result)
    case .terminal:
        return (state, [])
    case .queueOp(let operation):
        return reduceQueueOp(state, operation)
    case .queueSync(let snapshot):
        return reduceQueueSync(state, snapshot)
    case .mention(let mention):
        return reduceMention(state, mention)
    }
}

private func reduceInput(_ state: UIState, _ input: InputAction) -> (UIState, [UIEffect]) {
    var composer = state.composer
    switch input {
    case .insertText(let text):
        guard (composer.text + text).utf8.count <= maxComposerBytes else {
            return (state, [])
        }
        let scalars = Array(text.unicodeScalars)
        let prefix = String(composer.text.unicodeScalars.prefix(composer.cursor))
        let suffix = String(composer.text.unicodeScalars.dropFirst(composer.cursor))
        composer.text = prefix + text + suffix
        composer.cursor += scalars.count
        composer.revision += 1
        composer.pasting = false
    case .deleteBackward(let count):
        guard count > 0 else { return (state, []) }
        let keep = max(0, composer.cursor - count)
        let prefix = String(composer.text.unicodeScalars.prefix(keep))
        let suffix = String(composer.text.unicodeScalars.dropFirst(composer.cursor))
        composer.text = prefix + suffix
        composer.cursor = keep
        composer.revision += 1
        composer.pasting = false
    case .moveCursor(let offset):
        let total = composer.text.unicodeScalars.count
        composer.cursor = min(max(0, composer.cursor + offset), total)
        composer.pasting = false
    case .submitDraft(let commandID):
        guard !composer.text.isEmpty else { return (state, []) }
        let effect = UIEffect.submit(OperatorInput(text: composer.text, commandID: commandID))
        var next = state
        next.composer = ComposerState()
        next.suggestion = nil
        // Tokens belong to the submitted draft: a fresh composer starts
        // with no accepted file identity. Mid-draft edits retain tokens
        // (attach re-validates path/identity in Core at submit).
        next.tokens = []
        return (next, [effect])
    case .newline:
        return reduceInput(state, .insertText("\n"))
    case .pasteLiteral(let text):
        // Pasted text is literal (UX-MENTION-02): it lands in the draft
        // but never opens a mention query; the popup (if any) dismisses.
        // The next real keystroke re-derives from the full text.
        guard (composer.text + text).utf8.count <= maxComposerBytes else {
            return (state, [])
        }
        let scalars = Array(text.unicodeScalars)
        let prefix = String(composer.text.unicodeScalars.prefix(composer.cursor))
        let suffix = String(composer.text.unicodeScalars.dropFirst(composer.cursor))
        composer.text = prefix + text + suffix
        composer.cursor += scalars.count
        composer.revision += 1
        composer.pasting = true
        var next = state
        next.composer = composer
        next.suggestion = nil
        return (next, [])
    }
    var next = state
    next.composer = composer
    return deriveMention(next)
}

/// Re-derives the mention popup from (composer.text, composer.cursor).
/// A changed query opens a fresh suggestion and requests completions;
/// an unchanged query keeps selection/candidates silently; no query
/// dismisses. Suppressed while `pasting` (paste is literal).
private func deriveMention(_ state: UIState) -> (UIState, [UIEffect]) {
    var next = state
    guard !next.composer.pasting else { return (next, []) }
    guard let found = mentionQuery(text: next.composer.text, cursor: next.composer.cursor) else {
        next.suggestion = nil
        return (next, [])
    }
    if next.suggestion?.query == found.query {
        return (next, [])
    }
    // A changed path restarts the query (fresh revision + fetch). A
    // range-suffix-only change keeps candidates/selection silently.
    if next.suggestion.map({ mentionPathQuery($0.query) }) != found.pathQuery {
        next.suggestion = MentionSuggestionState(
            query: found.query, revision: next.composer.revision,
            candidates: [], selectedIndex: 0)
        return (next, [.requestCompletions(query: found.pathQuery, revision: next.composer.revision)])
    }
    var current = next.suggestion!
    current.query = found.query
    next.suggestion = current
    return (next, [])
}

private func reduceSession(_ state: UIState, _ projection: SessionEventProjection) -> (UIState, [UIEffect]) {
    var next = state
    switch projection.kind {
    case "admitted":
        next.status = .busy(operation: "admitted \(projection.detail)")
    case "denied":
        next.status = .failed(cause: projection.detail)
        // Roll back unconfirmed optimistic rows: Core refused, so they
        // never became truth. Authoritative rows stay (sync owns them).
        next.queue.removeAll(where: { $0.isOptimistic })
    case "agent":
        let parts = projection.detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 {
            next.activeAgent = AgentSummary(
                modelAlias: parts[0], locality: parts[1], phase: parts[2],
                queueCount: next.queue.count)
        }
    default:
        if projection.kind.hasPrefix("run:") {
            let phase = String(projection.kind.dropFirst(4))
            if phase == "completed" || phase == "interrupted" {
                next.status = .idle
                next.activeAgent = nil
            } else if phase == "failed" {
                next.status = .failed(cause: projection.detail)
            } else {
                next.status = .busy(operation: projection.detail)
            }
        }
    }
    return (next, [])
}

private func reduceCompletion(_ state: UIState, _ result: CompletionResult) -> (UIState, [UIEffect]) {
    // Stale results (older than the live query, or no live query) drop
    // without touching the composer (DX-02).
    guard let current = state.suggestion, result.queryRevision == current.revision else {
        return (state, [])
    }
    var next = state
    let capped = Array(result.candidates.prefix(maxCandidates))
    let selected = min(current.selectedIndex ?? 0, max(0, capped.count - 1))
    next.suggestion = MentionSuggestionState(
        query: current.query, revision: current.revision,
        candidates: capped,
        selectedIndex: capped.isEmpty ? nil : selected,
        rangeError: nil)
    return (next, [])
}

private func reduceQueueOp(_ state: UIState, _ operation: QueueOperation) -> (UIState, [UIEffect]) {
    switch operation {
    case .submitFollowUp(let text, let commandID):
        guard !text.isEmpty, text.utf8.count <= maxComposerBytes else { return (state, []) }
        var next = state
        // Optimistic row: visibly pending until the actor confirms.
        // The entryID derives from the commandID so sync can match it;
        // resubmitting the same command replaces the row (STATE-02:
        // one command, one row, never duplicates).
        next.queue.removeAll(where: { $0.isOptimistic && $0.commandID == commandID })
        next.queue.append(.optimistic(text: text, kind: .followUp, commandID: commandID, revision: 0))
        return (next, [.queue(OperatorInput(text: text, commandID: commandID), .followUp)])
    case .submitSteer(let text, let commandID):
        guard !text.isEmpty, text.utf8.count <= maxComposerBytes else { return (state, []) }
        var next = state
        next.queue.removeAll(where: { $0.isOptimistic && $0.commandID == commandID })
        next.queue.append(.optimistic(text: text, kind: .steer, commandID: commandID, revision: 0))
        return (next, [.queue(OperatorInput(text: text, commandID: commandID), .steer)])
    case .editEntry(let entryID, let newText, let baseRevision):
        return (state, [.queueEdit(entryID: entryID, newText: newText, baseRevision: baseRevision)])
    case .withdrawEntry(let entryID):
        return (state, [.queueWithdraw(entryID: entryID)])
    case .resumeQueue:
        return (state, [.queueResume])
    case .attachFile(let path, let range):
        guard !path.isEmpty else { return (state, []) }
        return (state, [.attachFile(path: path, range: range)])
    case .reorderEntry(let entryID, let beforeID):
        return (state, [.queueReorder(entryID: entryID, beforeID: beforeID)])
    case .grantApproval:
        // IDs come from the Core-minted view; invent nothing. Sandbox
        // contexts preserve the sandbox decision kind (never recorded
        // as a human approval).
        guard let view = state.pendingApproval else { return (state, []) }
        let decision: ApprovalDecision = view.sandbox
            ? .sandboxGrant(note: "operator-confirmed") : .approve
        return (state, [.decideApproval(decision, requestID: view.requestID, generation: view.generation)])
    case .denyApproval(let reason):
        guard let view = state.pendingApproval else { return (state, []) }
        return (state, [.decideApproval(.deny(reason), requestID: view.requestID, generation: view.generation)])
    case .cancelRun:
        return (state, [.cancelCurrent])
    }
}

/// Applies an authoritative Core snapshot (B2). Authoritative rows
/// replace the queue wholesale; optimistic rows survive only while
/// their command is unknown to Core (unconfirmed), and vanish once
/// admitted. Hold and approval views project directly; nothing here
/// mutates Core truth or auto-releases anything.
private func reduceQueueSync(_ state: UIState, _ snapshot: QueueSyncSnapshot) -> (UIState, [UIEffect]) {
    var next = state
    var rows: [QueueSummary] = snapshot.entries.map { entry in
        QueueSummary(
            entryID: entry.entryID, commandID: entry.commandID,
            kind: entry.kind.rawValue, state: entry.state.rawValue,
            revision: entry.revision,
            delivery: deliveryStatus(entry: entry, activeRequest: snapshot.activeRequest),
            pending: false,
            isOptimistic: false,
            staleTarget: entry.targetEpochID != snapshot.liveEpoch,
            hasAttachments: !entry.attachments.isEmpty)
    }
    for optimistic in state.queue where optimistic.isOptimistic {
        // Confirmed (Core knows the command AND lists an entry for it)
        // or resolved (Core knows the command, entry gone: dispatched,
        // withdrawn, pruned) → drop. Unknown → still pending.
        guard let commandID = optimistic.commandID else { continue }
        if snapshot.admittedCommandIDs.contains(commandID) { continue }
        rows.append(optimistic)
    }
    // Display order follows Core array order... except optimistic rows
    // appended at the end (they have no rank yet — Core assigns order
    // at admission).
    next.queue = rows
    next.pendingApproval = snapshot.pendingApproval
    if snapshot.queueHeld {
        let reason: String
        switch snapshot.heldReason {
        case .none: reason = "queue held"
        case .cancelled: reason = "queue held: cancelled"
        case .error(let message): reason = "queue held: \(message)"
        case .staleAttachment: reason = "queue held: stale attachment"
        case .policyChanged: reason = "queue held: policy changed"
        case .checkpointBusy: reason = "queue held: checkpoint busy"
        case .budgetStopped: reason = "queue held: budget stopped"
        case .approvalPending: reason = "queue held: approval pending"
        }
        next.status = .held(reason: reason)
    }
    return (next, [])
}

private func reduceMention(_ state: UIState, _ mention: MentionAction) -> (UIState, [UIEffect]) {
    switch mention {
    case .selectNext, .selectPrevious:
        guard var current = state.suggestion, !current.candidates.isEmpty else {
            return (state, [])
        }
        let base = current.selectedIndex ?? 0
        let next: Int
        if case .selectNext = mention {
            next = min(base + 1, current.candidates.count - 1)
        } else {
            next = max(base - 1, 0)
        }
        var out = state
        current.selectedIndex = next
        out.suggestion = current
        return (out, [])
    case .dismissSuggestion:
        // Cancel: popup goes, draft and tokens stay byte-exact, no effects.
        guard state.suggestion != nil else { return (state, []) }
        var out = state
        out.suggestion = nil
        return (out, [])
    case .acceptSelected:
        guard let current = state.suggestion,
              !current.candidates.isEmpty else {
            return (state, [])
        }
        let index = min(current.selectedIndex ?? 0, current.candidates.count - 1)
        let candidate = current.candidates[index]
        // A `#L` suffix on the query selects a line range; an invalid
        // range fails visibly without inserting anything (UX-MENTION-08).
        var lineRange: ClosedRange<Int>? = nil
        if let hashIndex = current.query.firstIndex(of: "#") {
            let suffix = String(current.query[hashIndex...])
            guard suffix.hasPrefix("#L"), let parsed = parseMentionRange(suffix) else {
                var out = state
                var failed = current
                failed.rangeError = "invalid range \(suffix.debugDescription); use #L10 or #L10-L30"
                out.suggestion = failed
                return (out, [])
            }
            lineRange = parsed
        }
        guard let found = mentionQuery(text: state.composer.text, cursor: state.composer.cursor) else {
            return (state, [])
        }
        // Replace the whole token span, not just the typed prefix: scan
        // forward from the cursor to whitespace/end so a mid-token accept
        // cannot leave a query tail behind.
        let scalars = Array(state.composer.text.unicodeScalars)
        var tokenEnd = state.composer.cursor
        while tokenEnd < scalars.count && !scalars[tokenEnd].properties.isWhitespace {
            tokenEnd += 1
        }
        var display = candidate.path
        if let range = lineRange {
            display += range.lowerBound == range.upperBound
                ? "#L\(range.lowerBound)" : "#L\(range.lowerBound)-L\(range.upperBound)"
        }
        let prefix = String(String.UnicodeScalarView(scalars[..<found.at]))
        let suffix = String(String.UnicodeScalarView(scalars[tokenEnd...]))
        var composer = state.composer
        composer.text = prefix + display + suffix
        composer.cursor = found.at + display.unicodeScalars.count
        composer.revision += 1
        var out = state
        out.composer = composer
        out.suggestion = nil
        out.tokens.append(MentionToken(path: candidate.path, lineRange: lineRange, revision: composer.revision))
        return (out, [])
    }
}

/// File-candidate seam (Presentation-owned, String paths). M1-B ships no
/// product implementation — tests use a tiny scripted fake. Confinement
/// stays in Runtime at submit time; the UI never opens these paths.
public protocol FileCandidateSource: Sendable {
    func candidates(query: String, revision: UInt64) -> [CandidateFile]
}
