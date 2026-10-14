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
    case .deleteBackward(let count):
        let keep = max(0, composer.cursor - count)
        let prefix = String(composer.text.unicodeScalars.prefix(keep))
        let suffix = String(composer.text.unicodeScalars.dropFirst(composer.cursor))
        composer.text = prefix + suffix
        composer.cursor = keep
        composer.revision += 1
    case .moveCursor(let offset):
        let total = composer.text.unicodeScalars.count
        composer.cursor = min(max(0, composer.cursor + offset), total)
    case .submitDraft(let commandID):
        guard !composer.text.isEmpty else { return (state, []) }
        let effect = UIEffect.submit(OperatorInput(text: composer.text, commandID: commandID))
        composer = ComposerState()
        var next = state
        next.composer = composer
        return (next, [effect])
    case .newline:
        return reduceInput(state, .insertText("\n"))
    case .pasteLiteral(let text):
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
    }
    var next = state
    next.composer = composer
    return (next, [])
}

private func reduceSession(_ state: UIState, _ projection: SessionEventProjection) -> (UIState, [UIEffect]) {
    var next = state
    switch projection.kind {
    case "admitted":
        next.status = .busy(operation: "admitted \(projection.detail)")
    case "denied":
        next.status = .failed(cause: projection.detail)
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
    next.suggestion = MentionSuggestionState(
        query: current.query, revision: current.revision,
        candidates: Array(result.candidates.prefix(maxCandidates)))
    return (next, [])
}

private func reduceQueueOp(_ state: UIState, _ operation: QueueOperation) -> (UIState, [UIEffect]) {
    switch operation {
    case .submitFollowUp(let text, let commandID):
        guard !text.isEmpty, text.utf8.count <= maxComposerBytes else { return (state, []) }
        return (state, [.queue(OperatorInput(text: text, commandID: commandID), .followUp)])
    case .submitSteer(let text, let commandID):
        guard !text.isEmpty, text.utf8.count <= maxComposerBytes else { return (state, []) }
        return (state, [.queue(OperatorInput(text: text, commandID: commandID), .steer)])
    case .editEntry(let entryID, let newText, let baseRevision):
        return (state, [.queueEdit(entryID: entryID, newText: newText, baseRevision: baseRevision)])
    case .withdrawEntry(let entryID):
        return (state, [.queueWithdraw(entryID: entryID)])
    case .resumeQueue:
        return (state, [.queueResume])
    }
}

/// File-candidate seam (Presentation-owned, String paths). M1-B ships no
/// product implementation — tests use a tiny scripted fake. Confinement
/// stays in Runtime at submit time; the UI never opens these paths.
public protocol FileCandidateSource: Sendable {
    func candidates(query: String, revision: UInt64) -> [CandidateFile]
}
