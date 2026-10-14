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
}

public enum InputAction: Sendable, Equatable {
    case insertText(String)
    case deleteBackward(Int)
    case moveCursor(Int)
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
    case dismiss
}
