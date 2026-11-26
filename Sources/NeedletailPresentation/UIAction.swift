import Foundation
import NeedletailCore

/// M1-B UI actions (UX-DX §3.1). Operator intents, session projections from
/// the actor, completion results, terminal capability changes, and queue
/// operations. `queueOp` cases are INTENTS the reducer turns into
/// `UIEffect.queue*` requests — the actor decides (DX-03).
public enum UIAction: Sendable, Equatable {
    case input(InputAction)
    case session(SessionEventProjection)
    case completion(CompletionResult)
    case terminal(TerminalCapabilityChange)
    case queueOp(QueueOperation)
    case mention(MentionAction)
    /// Authoritative queue snapshot from Core (built by the impure edge
    /// via `QueueSyncSnapshot.from`). The ONLY writer of `UIState.queue`.
    case queueSync(QueueSyncSnapshot)
    /// Typed inspection payload from the edge (local store/actor reads
    /// only — never a provider call). Maps to `InspectionView`.
    case inspectResult(InspectionResult)
    /// Inspection intent: the edge performs a LOCAL store/actor read
    /// and feeds back an `inspectResult`. Never a provider request.
    case inspect(InspectionCommand)
    /// Undo intent: the actor reconciles the group and validates;
    /// never a direct mutation by the UI.
    case undoIntent(UndoIntent)
    /// Rewind fork request: record-only lineage fork (Core validates
    /// the boundary; no file mutation, no branch switch).
    case rewindRequest(boundary: LineageBoundary)
}

public enum MentionAction: Sendable, Equatable {
    case selectNext
    case selectPrevious
    case acceptSelected
    case dismissSuggestion
}

public enum InputAction: Sendable, Equatable {
    case insertText(String)
    case deleteBackward(Int)
    case moveCursor(Int)
    /// Exact-sync boundary (M4-C submit/clear only — never the live
    /// keystroke mirror, which uses fine-grained actions so the mention
    /// popup survives typing). Rejects over-`maxComposerBytes` text
    /// (same 64 KiB rule as `insertText`, never silent truncation);
    /// clears suggestion AND tokens (submit-boundary semantics, like
    /// `submitDraft`'s reset — the mention flow restarts after a
    /// boundary).
    case replaceDraft(String)
    /// The commandID is minted by the impure edge (one UUID per submission;
    /// retries reuse it) so the pure reducer can dedup without randomness.
    case submitDraft(commandID: CommandID)
    case newline
    case pasteLiteral(String)
}

public struct CompletionResult: Sendable, Equatable {
    public var queryRevision: UInt64
    public var candidates: [CandidateFile]

    public init(queryRevision: UInt64, candidates: [CandidateFile]) {
        self.queryRevision = queryRevision
        self.candidates = candidates
    }
}

public struct TerminalCapabilityChange: Sendable, Equatable {
    public var width: Int?
    public var capabilities: TerminalCapabilities?

    public init(width: Int? = nil, capabilities: TerminalCapabilities? = nil) {
        self.width = width
        self.capabilities = capabilities
    }
}

public enum QueueOperation: Sendable, Equatable {
    case submitFollowUp(text: String, commandID: CommandID)
    case submitSteer(text: String, commandID: CommandID)
    case editEntry(entryID: String, newText: String, baseRevision: UInt64)
    case withdrawEntry(entryID: String)
    case resumeQueue
    /// M2-D connection intent: the actor validates (snapshot/consent/
    /// sealed/route) and refuses loudly; Presentation never grants.
    /// `range` is 1-based closed, nil for the whole file.
    case attachFile(path: String, range: ClosedRange<Int>?)
    /// B2 reorder intent (display rank only; Core owns order).
    case reorderEntry(entryID: String, beforeID: String?)
    /// B2 approval intents: IDs come from the projected
    /// `ApprovalRequestView`; without a live view these emit nothing.
    case grantApproval
    case denyApproval(reason: String)
    /// B2 cancel intent: the actor cancels and holds; no auto-resume.
    case cancelRun
}

public enum UIEffect: Sendable, Equatable {
    case submit(OperatorInput)
    case queue(OperatorInput, QueueKind)
    case queueEdit(entryID: String, newText: String, baseRevision: UInt64)
    case queueWithdraw(entryID: String)
    case queueResume
    case previewFile(path: String)
    case requestCompletions(query: String, revision: UInt64)
    case cancelCurrent
    case inspect(InspectionCommand)
    case attachFile(path: String, range: ClosedRange<Int>?)
    case queueReorder(entryID: String, beforeID: String?)
    case decideApproval(ApprovalDecision, requestID: RequestID, generation: Revision)
    case undoPreview(groupID: String)
    /// Latest-eligible-group preview (M4-D D2: bare `/undo`). The edge
    /// resolves the group; never a sentinel string.
    case undoPreviewLatest
    case runUndo(groupID: String)
    case requestLineageFork(boundary: LineageBoundary)
}

public struct OperatorInput: Sendable, Equatable {
    public var text: String
    public var commandID: CommandID

    public init(text: String, commandID: CommandID) {
        self.text = text
        self.commandID = commandID
    }
}

public enum InspectionCommand: Sendable, Equatable {
    case context
    case queue
    case epochs
    case sessions
    case agents
    case models
    case compactDryRun
    case diff
    case undoPreview(groupID: String)
    /// Dumb-terminal/keyboard fallback preview (spec §2.2 `/preview @path`):
    /// bounded local file text, never provider-bound.
    case filePreview(path: String)
    case rewind(epochID: EpochID, throughSequence: UInt64)
    case dismiss
}
