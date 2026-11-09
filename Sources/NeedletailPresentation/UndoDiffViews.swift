import Foundation
import NeedletailCore

/// B4 pure diff/undo/rewind views (UX-NAV-07, UX-UNDO-06/08/09 pure
/// legs). Read-only projections of existing Core/Runtime mechanisms;
/// Presentation performs no filesystem undo and never claims an action
/// succeeded — views request authoritative actions via intents.

public struct UIUndoFile: Sendable, Equatable {
    public var path: String
    public var beforeHash: String?
    public var afterHash: String?
    public var eligible: Bool
    /// Present blocks the run: user edit, exec side-effect, missing
    /// preimage, special file. Never silently overwritten.
    public var conflict: String?

    public init(path: String, beforeHash: String? = nil, afterHash: String? = nil,
                eligible: Bool, conflict: String? = nil) {
        self.path = path
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.eligible = eligible
        self.conflict = conflict
    }
}

public struct UIUndoPreview: Sendable, Equatable {
    public var groupID: String
    public var files: [UIUndoFile]
    public var canRun: Bool
    public var notice: String

    public init(groupID: String, files: [UIUndoFile], canRun: Bool, notice: String) {
        self.groupID = groupID
        self.files = files
        self.canRun = canRun
        self.notice = notice
    }
}

public struct UIUndoOutcome: Sendable, Equatable {
    public var groupID: String
    public var applied: [String]
    public var refused: [(path: String, reason: String)]
    public var failed: [(path: String, error: String)]
    public var notice: String

    public init(groupID: String, applied: [String],
                refused: [(path: String, reason: String)],
                failed: [(path: String, error: String)], notice: String) {
        self.groupID = groupID
        self.applied = applied
        self.refused = refused
        self.failed = failed
        self.notice = notice
    }

    public static func == (lhs: UIUndoOutcome, rhs: UIUndoOutcome) -> Bool {
        lhs.groupID == rhs.groupID && lhs.applied == rhs.applied
            && lhs.refused.map(\.path) == rhs.refused.map(\.path)
            && lhs.refused.map(\.reason) == rhs.refused.map(\.reason)
            && lhs.failed.map(\.path) == rhs.failed.map(\.path)
            && lhs.failed.map(\.error) == rhs.failed.map(\.error)
            && lhs.notice == rhs.notice
    }
}

public enum UIDiffProvenance: String, Sendable, Equatable {
    /// Change-group native edit.
    case agent
    /// Pre-existing or user change (never attributed to the agent).
    case user
    case mixed
}

public struct UIDiffFile: Sendable, Equatable {
    public var path: String
    public var provenance: UIDiffProvenance
    /// Hunks are terminal-sanitized at render; count/byte caps are
    /// enforced by the edge (B5 bounds the frame queues).
    public var hunks: [String]

    public init(path: String, provenance: UIDiffProvenance, hunks: [String]) {
        self.path = path
        self.provenance = provenance
        self.hunks = hunks
    }
}

public struct UIRewindView: Sendable, Equatable {
    public var boundaryEpoch: String
    public var throughSequence: UInt64
    /// Dirty worktree: fork lineage only, warn loudly, never mutate.
    public var divergent: Bool
    public var warning: String

    public init(boundaryEpoch: String, throughSequence: UInt64, divergent: Bool, warning: String) {
        self.boundaryEpoch = boundaryEpoch
        self.throughSequence = throughSequence
        self.divergent = divergent
        self.warning = warning
    }
}

public enum UndoIntent: Sendable, Equatable {
    /// Dry-run preview (no mutation); the actor reconciles the group.
    case preview(groupID: String)
    /// Latest-eligible-group preview (bare `/undo`; read-only).
    /// Runs still require an explicit group ID — never guessed.
    case previewLatest
    /// Explicit run (idempotent by undo command ID in Core).
    case run(groupID: String)
}
