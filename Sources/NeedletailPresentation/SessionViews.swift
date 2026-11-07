import Foundation
import NeedletailCore

/// B3 read-only session/model/context/epoch views (UX-NAV-01…06).
/// All types are value snapshots built by the impure edge from Core
/// stores; the reducer projects them, never fetches. No provider
/// request is required to inspect local state.

/// Raw session facts; liveness is DERIVED by the reducer from
/// `asOfMillis` (explicit clock — no wall time in the pure layer).
public struct UISessionRow: Sendable, Equatable {
    public var sessionID: SessionID
    public var phase: String
    public var lastActivityMillis: UInt64?
    public var routeAlias: String
    public var locality: String
    public var modelAlias: String
    public var isLive: Bool

    public init(sessionID: SessionID, phase: String, lastActivityMillis: UInt64?,
                routeAlias: String, locality: String, modelAlias: String, isLive: Bool) {
        self.sessionID = sessionID
        self.phase = phase
        self.lastActivityMillis = lastActivityMillis
        self.routeAlias = routeAlias
        self.locality = locality
        self.modelAlias = modelAlias
        self.isLive = isLive
    }
}

public enum SessionLiveness: String, Sendable, Equatable {
    case active
    case idle
    case stale
    case unknown
}

/// Liveness rule (UX-NAV-01): live streaming phases are active;
/// other live sessions idle; non-live sessions idle within the
/// 5-minute heartbeat window, stale past it; a missing heartbeat is
/// unknown — never rendered as live proof, never as zero-idle.
public func sessionLiveness(row: UISessionRow, asOfMillis: UInt64) -> SessionLiveness {
    if row.isLive {
        switch row.phase {
        case "requesting", "streaming", "authorising": return .active
        default: return .idle
        }
    }
    guard let last = row.lastActivityMillis else { return .unknown }
    let age = asOfMillis >= last ? asOfMillis - last : 0
    return age <= 300_000 ? .idle : .stale
}

public struct UIDisplaySession: Sendable, Equatable {
    public var row: UISessionRow
    public var liveness: SessionLiveness

    public init(row: UISessionRow, liveness: SessionLiveness) {
        self.row = row
        self.liveness = liveness
    }
}

public struct UIAgentRow: Sendable, Equatable {
    public var alias: String
    public var phase: String
    /// Bounded consult rendered as child activity (UX-NAV-02), never
    /// as a recursive team.
    public var childActivity: String?

    public init(alias: String, phase: String, childActivity: String? = nil) {
        self.alias = alias
        self.phase = phase
        self.childActivity = childActivity
    }
}

public enum UIModelRouteKind: String, Sendable, Equatable {
    case local
    case cloud
}

public struct UIModelRoute: Sendable, Equatable {
    public var alias: String
    public var locality: String
    public var kind: UIModelRouteKind
    public var models: [String]

    public init(alias: String, locality: String, kind: UIModelRouteKind, models: [String]) {
        self.alias = alias
        self.locality = locality
        self.kind = kind
        self.models = models
    }
}

public struct UIContextUsage: Sendable, Equatable {
    /// Nil with estimated=true means estimated, never zero-actual.
    public var inputTokens: UInt64?
    public var estimated: Bool
    public var cacheHits: UInt64?
    /// True renders "unknown", never "0 hits" (UX-NAV-04).
    public var cacheUnknown: Bool
    public var receipts: UInt64
    public var unverifiedClaims: UInt64

    public init(inputTokens: UInt64?, estimated: Bool, cacheHits: UInt64?,
                cacheUnknown: Bool, receipts: UInt64, unverifiedClaims: UInt64) {
        self.inputTokens = inputTokens
        self.estimated = estimated
        self.cacheHits = cacheHits
        self.cacheUnknown = cacheUnknown
        self.receipts = receipts
        self.unverifiedClaims = unverifiedClaims
    }
}

public enum UICheckpointState: Sendable, Equatable {
    case none
    case success(costMillis: UInt64)
    case failed(reason: String)
}

public struct UIEpochRow: Sendable, Equatable {
    public var epochID: String
    public var parentID: String?
    public var checkpoint: UICheckpointState
    public var prefill: String?

    public init(epochID: String, parentID: String? = nil,
                checkpoint: UICheckpointState = .none, prefill: String? = nil) {
        self.epochID = epochID
        self.parentID = parentID
        self.checkpoint = checkpoint
        self.prefill = prefill
    }
}

public struct UICompactPreview: Sendable, Equatable {
    public var estimatedTokens: UInt64
    public var wouldReplaceEpoch: Bool
    /// Always zero: a dry run performs no provider call (UX-NAV-05).
    public var providerCalls: UInt64
    public var note: String

    public init(estimatedTokens: UInt64, wouldReplaceEpoch: Bool, providerCalls: UInt64, note: String) {
        self.estimatedTokens = estimatedTokens
        self.wouldReplaceEpoch = wouldReplaceEpoch
        self.providerCalls = providerCalls
        self.note = note
    }
}

/// Typed inspection payloads from the edge (store/actor reads).
/// The reducer maps each to the matching `InspectionView`.
public enum InspectionResult: Sendable, Equatable {
    case sessions(rows: [UISessionRow], asOfMillis: UInt64)
    case agents(rows: [UIAgentRow])
    case models(routes: [UIModelRoute])
    case context(usage: UIContextUsage)
    case epochs(rows: [UIEpochRow])
    case compact(preview: UICompactPreview)
}
