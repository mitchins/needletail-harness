import Foundation

/// M4-B B2: Core-minted read-only approval view. Carries the exact IDs
/// the actor's `decideApproval` requires, so Presentation can display
/// and route decisions without inventing identity or reading actor
/// state. `sandbox` marks gateway-originated policy decisions (display
/// and grant-kind only — the UI never evaluates policy).
public struct ApprovalRequestView: Sendable, Equatable {
    public var requestID: RequestID
    public var generation: Revision
    public var operation: String
    public var requiredGrant: String
    public var protectedPaths: [String]
    public var sandbox: Bool

    public init(requestID: RequestID, generation: Revision, operation: String,
                requiredGrant: String, protectedPaths: [String], sandbox: Bool) {
        self.requestID = requestID
        self.generation = generation
        self.operation = operation
        self.requiredGrant = requiredGrant
        self.protectedPaths = protectedPaths
        self.sandbox = sandbox
    }

    public init(request: ApprovalRequest, sandbox: Bool) {
        self.init(requestID: request.requestID, generation: request.generation,
                  operation: request.operation, requiredGrant: request.requiredGrant,
                  protectedPaths: request.protectedPaths, sandbox: sandbox)
    }
}

/// M4-B B2: authoritative queue snapshot for Presentation. Built by the
/// impure edge from `SessionActor.currentState()` (Presentation never
/// reads the actor itself) and fed to the pure reducer as a single
/// `UIAction.queueSync`. Everything in here is a value snapshot;
/// the reducer projects but never mutates Core truth.
public struct QueueSyncSnapshot: Sendable, Equatable {
    public var entries: [QueueEntry]
    public var activeRequest: ActiveRequest?
    public var queueHeld: Bool
    public var heldReason: HoldReason?
    public var pendingApproval: ApprovalRequestView?
    /// Authoritatively admitted commands (ack index keys). Optimistic
    /// rows whose command is absent here stay pending; rows whose
    /// command is present are replaced by the authoritative entry.
    public var admittedCommandIDs: Set<CommandID>
    public var liveEpoch: EpochID

    public init(entries: [QueueEntry], activeRequest: ActiveRequest?,
                queueHeld: Bool, heldReason: HoldReason?,
                pendingApproval: ApprovalRequestView?,
                admittedCommandIDs: Set<CommandID>, liveEpoch: EpochID) {
        self.entries = entries
        self.activeRequest = activeRequest
        self.queueHeld = queueHeld
        self.heldReason = heldReason
        self.pendingApproval = pendingApproval
        self.admittedCommandIDs = admittedCommandIDs
        self.liveEpoch = liveEpoch
    }

    /// Convenience: snapshot straight from live state. `sandbox` comes
    /// from the edge's approval-gateway wiring (sandbox gateways mark
    /// their decisions); it has no default — defaulting false would
    /// fail open by miswiring a sandbox request as human-grantable.
    public static func from(_ state: SessionState, sandbox: Bool) -> QueueSyncSnapshot {
        QueueSyncSnapshot(
            entries: state.queue,
            activeRequest: state.activeRequest,
            queueHeld: state.queueHeld,
            heldReason: state.heldReason,
            pendingApproval: state.pendingApproval.map { ApprovalRequestView(request: $0, sandbox: sandbox) },
            admittedCommandIDs: Set(state.admittedCommands.keys),
            liveEpoch: state.epoch.epochID)
    }
}
