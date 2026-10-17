import Foundation
import NeedletailCore

/// M1-B minimal pure UI state (UX-DX §3.1). The composer/draft and display
/// selection live here; the authoritative queue, permissions, model route
/// and session history DO NOT (read-only projections only). Value types;
/// no I/O, no clock, no randomness.

public let maxComposerBytes = 64 * 1_024
public let maxCandidates = 10

public struct ComposerState: Sendable, Equatable {
    /// Draft text (UTF-8, bounded — over-cap input is rejected with reason,
    /// never truncated silently, so bytes are never lost by the reducer).
    public var text: String
    /// Cursor as a Unicode-scalar offset into `text`.
    public var cursor: Int
    /// Monotonic revision: every keystroke/paste/selection change bumps it;
    /// late async results compare against it (DX-02).
    public var revision: UInt64
    /// True while a bracketed paste is being composed (never submits).
    public var pasting: Bool

    public init(text: String = "", cursor: Int = 0, revision: UInt64 = 0, pasting: Bool = false) {
        self.text = text
        self.cursor = cursor
        self.revision = revision
        self.pasting = pasting
    }
}

public struct CandidateFile: Sendable, Equatable {
    /// Opaque display path (String — no SystemPackage in Presentation).
    /// The UI never opens it; confinement happens in Runtime at submit.
    public var path: String
    public var kind: String
    public var previewLines: [String]
    public var previewTruncated: Bool

    public init(path: String, kind: String = "file", previewLines: [String] = [], previewTruncated: Bool = false) {
        self.path = path
        self.kind = kind
        self.previewLines = previewLines
        self.previewTruncated = previewTruncated
    }
}

public struct MentionSuggestionState: Sendable, Equatable {
    public var query: String
    public var revision: UInt64
    public var candidates: [CandidateFile]

    public init(query: String, revision: UInt64, candidates: [CandidateFile] = []) {
        self.query = query
        self.revision = revision
        self.candidates = candidates
    }
}

/// Read-only projection of one queue entry (QueueSummary(entry:) is the
/// ONLY constructor — Presentation mints no queue identity).
public struct QueueSummary: Sendable, Equatable {
    public var entryID: String
    public var kind: String
    public var state: String
    public var revision: UInt64
    public var delivery: DeliveryStatus
    public var pending: Bool

    public init(entry: QueueEntry, delivery: DeliveryStatus, pending: Bool) {
        self.entryID = entry.entryID
        self.kind = entry.kind.rawValue
        self.state = entry.state.rawValue
        self.revision = entry.revision
        self.delivery = delivery
        self.pending = pending
    }
}

public struct AgentSummary: Sendable, Equatable {
    public var modelAlias: String
    public var locality: String
    public var phase: String
    public var queueCount: Int

    public init(modelAlias: String, locality: String, phase: String, queueCount: Int) {
        self.modelAlias = modelAlias
        self.locality = locality
        self.phase = phase
        self.queueCount = queueCount
    }
}

public enum InspectionView: Sendable, Equatable {
    case context(lines: [String])
    case queue(ids: [String])
    case epochs(ids: [String])
}

public enum UIStatus: Sendable, Equatable {
    case idle
    case busy(operation: String)
    case held(reason: String)
    case failed(cause: String)
}

public struct UIState: Sendable, Equatable {
    public var composer: ComposerState
    public var suggestion: MentionSuggestionState?
    public var queue: [QueueSummary]
    public var activeAgent: AgentSummary?
    public var inspection: InspectionView?
    public var status: UIStatus

    public init(
        composer: ComposerState = ComposerState(),
        suggestion: MentionSuggestionState? = nil,
        queue: [QueueSummary] = [], activeAgent: AgentSummary? = nil,
        inspection: InspectionView? = nil, status: UIStatus = .idle
    ) {
        self.composer = composer
        self.suggestion = suggestion
        self.queue = queue
        self.activeAgent = activeAgent
        self.inspection = inspection
        self.status = status
    }
}
