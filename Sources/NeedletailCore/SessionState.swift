/// M1-B production session state (SPEC §4, ARCH §§1–4). Every field is
/// `let`: each transition builds ONE new value wholesale and the actor
/// reassigns it — nothing mutates in place. Epoch-frozen M1-A inputs
/// (`ConfigSnapshot`, `ModelProfile`, `EffectiveCapabilities`) are embedded
/// by value and never altered; a change means a new epoch object (I03).

public enum TrustMode: String, Sendable, Equatable, Codable {
    case observe
    case workspace
    case trustedExec
}

/// Fail-closed session-creation rule (M1B2-5): the mode must agree with the
/// granted capabilities. `observe` allows read/search only; `trustedExec`
/// requires exec to be granted (a trusted session that cannot execute is a
/// contradiction, not a quieter workspace).
public func validateTrustConsistency(mode: TrustMode, caps: ToolCapabilities) throws -> TrustMode {
    switch mode {
    case .observe:
        guard caps.exec == .denied, !caps.edit, !caps.write else {
            throw ConfigError(
                path: "$.trust", kind: .contradictoryFlags,
                message: "observe mode with mutating grants.",
                hint: "observe allows read/search only; use workspace or trustedExec for mutations.")
        }
    case .trustedExec:
        guard caps.exec != .denied else {
            throw ConfigError(
                path: "$.trust", kind: .contradictoryFlags,
                message: "trustedExec mode with exec denied.",
                hint: "trusted execution requires an exec grant; use workspace for ask-gated execution.")
        }
    case .workspace:
        break
    }
    return mode
}

public enum SessionPhase: Sendable, Equatable {
    case idle
    case admitting
    case requesting
    case streaming
    case validatingTools
    case authorising
    case executing
    case cancelling
    case interrupted
    case failed(RunFailure)
    case completed(RunReceipt)
    case checkpointing
}

extension SessionPhase {
    /// Phases with a live run that cancellation, holds and stale rules apply to.
    public var hasActiveRun: Bool {
        switch self {
        case .requesting, .streaming, .validatingTools, .authorising, .executing, .cancelling:
            return true
        case .idle, .admitting, .checkpointing, .interrupted, .failed, .completed:
            return false
        }
    }

    /// Phases during which new operator input queues rather than admits directly.
    /// `admitting` and `checkpointing` are busy (an operation is in flight) but carry no run.
    public var isBusy: Bool { hasActiveRun || self == .admitting || self == .checkpointing }

    public var isTerminal: Bool {
        switch self {
        case .failed, .completed, .interrupted: return true
        default: return false
        }
    }
}

public struct RunDescriptor: Sendable, Equatable {
    public let runID: RunID
    public let requestID: RequestID
    public let revision: Revision
    public let startedAtMillis: UInt64
    public let sealed: Bool

    public init(runID: RunID, requestID: RequestID, revision: Revision, startedAtMillis: UInt64, sealed: Bool) {
        self.runID = runID
        self.requestID = requestID
        self.revision = revision
        self.startedAtMillis = startedAtMillis
        self.sealed = sealed
    }
}

public enum DeliveryState: Sendable, Equatable {
    case sending
    case responseComplete
    case deliveryUnknown
}

/// Delivery states live on the ACTIVE REQUEST (R14), never on queue
/// entries. History admission stays transactional/idempotent; remote
/// delivery is never promised exactly once (ARCH §3, I14).
public struct ActiveRequest: Sendable, Equatable {
    public let requestID: RequestID
    public let runID: RunID
    public let generation: Revision
    public let delivery: DeliveryState
    public let bytesOut: Int

    public init(requestID: RequestID, runID: RunID, generation: Revision, delivery: DeliveryState, bytesOut: Int) {
        self.requestID = requestID
        self.runID = runID
        self.generation = generation
        self.delivery = delivery
        self.bytesOut = bytesOut
    }
}

public enum QueueKind: String, Sendable, Equatable, Codable {
    case followUp
    case steer
}

public enum QueueEntryState: String, Sendable, Equatable, Codable {
    case queued
    case held
    case dispatched
    case admittedToHistory
    case withdrawn
}

public struct QueueEntry: Sendable, Equatable, Codable {
    public let entryID: String
    public let commandID: CommandID
    public let kind: QueueKind
    public let state: QueueEntryState
    public let revision: UInt64
    public let text: String
    public let targetEpochID: EpochID
    /// Reserved for M2-D reorder flows; M1-B never reorders (no code path assigns order).
    public let orderKey: UInt64
    /// Sealing travels WITH the entry (S6): a sealed submission queued
    /// behind a non-sealed run keeps its own flag into its own run.
    public let sealed: Bool

    public init(entryID: String, commandID: CommandID, kind: QueueKind, state: QueueEntryState, revision: UInt64, text: String, targetEpochID: EpochID, orderKey: UInt64, sealed: Bool = false) {
        self.entryID = entryID
        self.commandID = commandID
        self.kind = kind
        self.state = state
        self.revision = revision
        self.text = text
        self.targetEpochID = targetEpochID
        self.orderKey = orderKey
        self.sealed = sealed
    }

    public func withState(_ state: QueueEntryState) -> QueueEntry {
        QueueEntry(
            entryID: entryID, commandID: commandID, kind: kind,
            state: state, revision: revision, text: text,
            targetEpochID: targetEpochID, orderKey: orderKey, sealed: sealed)
    }

    public func withRevision(_ revision: UInt64, text: String) -> QueueEntry {
        QueueEntry(
            entryID: entryID, commandID: commandID, kind: kind,
            state: state, revision: revision, text: text,
            targetEpochID: targetEpochID, orderKey: orderKey, sealed: sealed)
    }
}

public enum HoldReason: Sendable, Equatable {
    case cancelled(sinceMillis: UInt64)
    case error(String)
    case staleAttachment
    case policyChanged
    case checkpointBusy
    case budgetStopped
    case approvalPending
}

public enum RunFailure: Sendable, Equatable {
    case providerError(String)
    case budgetExhausted(String)
    case invalidStopped(String)
    case approvalDenied(String)
    case integrityStopped(String)
}

public struct RunReceipt: Sendable, Equatable {
    public let runID: RunID
    public let completedAtMillis: UInt64
    public let turnsUsed: Int
    public let toolCallCount: Int

    public init(runID: RunID, completedAtMillis: UInt64, turnsUsed: Int, toolCallCount: Int) {
        self.runID = runID
        self.completedAtMillis = completedAtMillis
        self.turnsUsed = turnsUsed
        self.toolCallCount = toolCallCount
    }
}

public struct ApprovalRequest: Sendable, Equatable {
    public let requestID: RequestID
    public let runID: RunID
    public let generation: Revision
    /// Rendered, redacted operation description (terminalSafe at construction).
    public let operation: String
    public let requiredGrant: String

    public init(requestID: RequestID, runID: RunID, generation: Revision, operation: String, requiredGrant: String) {
        self.requestID = requestID
        self.runID = runID
        self.generation = generation
        self.operation = terminalSafe(operation)
        self.requiredGrant = requiredGrant
    }
}

/// Consecutive identical invalid/denied attempts. The fingerprint covers
/// the input KIND + normalized target (FNV-1a, deterministic) — raw
/// secrets are never fingerprinted or logged. Session-scoped; only valid
/// input resets it.
public struct InvalidTracker: Sendable, Equatable {
    public let fingerprint: String
    public let count: Int
    public static let limit = 3

    public init(fingerprint: String = "", count: Int = 0) {
        self.fingerprint = fingerprint
        self.count = count
    }
}

public enum OperationState: Sendable, Equatable, Codable {
    case intent
    case unknown
    case done
}

public struct OperationRef: Sendable, Equatable, Codable {
    public let operationID: OperationID
    public let callID: String?
    public let state: OperationState
    public let mutating: Bool

    public init(operationID: OperationID, callID: String? = nil, state: OperationState, mutating: Bool) {
        self.operationID = operationID
        self.callID = callID
        self.state = state
        self.mutating = mutating
    }
}

public struct EpochDescriptor: Sendable, Equatable, Codable {
    public let epochID: EpochID
    public let parentEpochID: EpochID?
    public let configSnapshot: ConfigSnapshot
    public let profile: ModelProfile
    public let effectiveCaps: EffectiveCapabilities
    public let route: Route

    public init(epochID: EpochID, parentEpochID: EpochID? = nil, configSnapshot: ConfigSnapshot, profile: ModelProfile, effectiveCaps: EffectiveCapabilities, route: Route) {
        self.epochID = epochID
        self.parentEpochID = parentEpochID
        self.configSnapshot = configSnapshot
        self.profile = profile
        self.effectiveCaps = effectiveCaps
        self.route = route
    }
}

extension SessionState {
    /// Single reconstruction point: every field defaults to the current
    /// value, so new fields cannot be silently dropped by row builders.
    public func replacing(
        epoch: EpochDescriptor? = nil, trustMode: TrustMode? = nil,
        phase: SessionPhase? = nil, activeRun: RunDescriptor?? = nil,
        activeRequest: ActiveRequest?? = nil, queue: [QueueEntry]? = nil,
        queueHeld: Bool? = nil, heldReason: HoldReason?? = nil,
        admittedCommands: [CommandID: QueueAck]? = nil,
        consumedEffects: Set<EffectID>? = nil, turnsUsed: Int? = nil,
        turnLimit: Int? = nil, runDeadlineMillis: UInt64?? = nil,
        preSendRetries: Int? = nil, invalidTracker: InvalidTracker? = nil,
        pendingApproval: ApprovalRequest?? = nil, pendingBatch: ToolBatch?? = nil,
        retryDeadlineMillis: UInt64?? = nil,
        liveReservations: [EffectReservation]? = nil,
        cancelledPendingReservations: [EffectReservation]? = nil, generation: UInt64? = nil,
        unresolvedOperations: [OperationRef]? = nil,
        droppedStaleCount: Int? = nil, lastSequence: UInt64? = nil
    ) -> SessionState {
        SessionState(
            sessionID: sessionID, epoch: epoch ?? self.epoch,
            trustMode: trustMode ?? self.trustMode, phase: phase ?? self.phase,
            activeRun: activeRun ?? self.activeRun,
            activeRequest: activeRequest ?? self.activeRequest,
            queue: queue ?? self.queue, queueHeld: queueHeld ?? self.queueHeld,
            heldReason: heldReason ?? self.heldReason,
            admittedCommands: admittedCommands ?? self.admittedCommands,
            consumedEffects: consumedEffects ?? self.consumedEffects,
            turnsUsed: turnsUsed ?? self.turnsUsed, turnLimit: turnLimit ?? self.turnLimit,
            runDeadlineMillis: runDeadlineMillis ?? self.runDeadlineMillis,
            preSendRetries: preSendRetries ?? self.preSendRetries,
            invalidTracker: invalidTracker ?? self.invalidTracker,
            pendingApproval: pendingApproval ?? self.pendingApproval,
            pendingBatch: pendingBatch ?? self.pendingBatch,
            retryDeadlineMillis: retryDeadlineMillis ?? self.retryDeadlineMillis,
            liveReservations: liveReservations ?? self.liveReservations,
            cancelledPendingReservations: cancelledPendingReservations ?? self.cancelledPendingReservations,
            generation: generation ?? self.generation,
            unresolvedOperations: unresolvedOperations ?? self.unresolvedOperations,
            droppedStaleCount: droppedStaleCount ?? self.droppedStaleCount,
            lastSequence: lastSequence ?? self.lastSequence)
    }
}

public struct QueueAck: Sendable, Equatable {
    public let commandID: CommandID
    public let entryID: String
    public let sequence: SequenceNumber
    public let revision: UInt64
    public let state: QueueEntryState

    public init(commandID: CommandID, entryID: String, sequence: SequenceNumber, revision: UInt64, state: QueueEntryState) {
        self.commandID = commandID
        self.entryID = entryID
        self.sequence = sequence
        self.revision = revision
        self.state = state
    }
}

/// Per-entry delivery projection, DERIVED (R14) from the entry plus the
/// live `ActiveRequest` — never stored, never authoritative.
public enum DeliveryStatus: Sendable, Equatable {
    case queued
    case held
    case sending
    case responseComplete
    case deliveryUnknown
    case withdrawn
}

public func deliveryStatus(entry: QueueEntry, activeRequest: ActiveRequest?) -> DeliveryStatus {
    switch entry.state {
    case .withdrawn: return .withdrawn
    case .held: return .held
    case .queued: return .queued
    case .dispatched, .admittedToHistory:
        guard let active = activeRequest else { return .queued }
        switch active.delivery {
        case .sending: return .sending
        case .responseComplete: return .responseComplete
        case .deliveryUnknown: return .deliveryUnknown
        }
    }
}

public struct SessionState: Sendable, Equatable {
    public let sessionID: SessionID
    public let epoch: EpochDescriptor
    public let trustMode: TrustMode
    public let phase: SessionPhase
    public let activeRun: RunDescriptor?
    public let activeRequest: ActiveRequest?
    public let queue: [QueueEntry]
    public let queueHeld: Bool
    public let heldReason: HoldReason?
    /// Persistent admission index (R10/C2): commandID → ack, surviving
    /// dispatch/withdraw. Bounded at 512, oldest-by-sequence pruned (I24);
    /// pruned at epoch transitions. A pruned ID re-admits as a NEW entry
    /// (different entryID/sequence — the caller can tell; never silent).
    public let admittedCommands: [CommandID: QueueAck]
    /// Per-effectID consumption set (R3), pruned at each new run reservation.
    public let consumedEffects: Set<EffectID>
    /// PER-RUN model turns (SPEC run limits); reset at each fresh admission.
    public let turnsUsed: Int
    public let turnLimit: Int
    public let runDeadlineMillis: UInt64?
    public let preSendRetries: Int
    public let invalidTracker: InvalidTracker
    public let pendingApproval: ApprovalRequest?
    /// Tool batch awaiting the approval decision (set on entering
    /// authorising, cleared on grant/deny/cancel). Empty batch short-
    /// circuits back to requesting without approval.
    public let pendingBatch: ToolBatch?
    /// Armed retry deadline (M1-C backoff): set by the preSend-retry arm,
    /// consumed ONLY by the `tick` row in requesting phase, cleared on
    /// cancel/epoch/dispatch. Nil normally.
    public let retryDeadlineMillis: UInt64?
    /// Live effect reservations (source of truth; the actor mirrors for
    /// pairing). Cancel retention (C3) and consumption checks read this —
    /// never actor-side memory alone.
    public let liveReservations: [EffectReservation]
    /// Cancelled-pending executor reservations retained for late-report
    /// supersession (REV25: state-side truth for kill-switch path).
    public let cancelledPendingReservations: [EffectReservation]
    /// Current generation. Bumped on every new run admission and every
    /// cancel; completions must match it (I21).
    public let generation: UInt64
    /// Recovery markers, bounded at 64 — overflow is a visible integrity
    /// stop, never silent loss (R19). M2 reconciles; M1-B records + blocks.
    public let unresolvedOperations: [OperationRef]
    public let droppedStaleCount: Int
    public let lastSequence: UInt64

    public init(
        sessionID: SessionID, epoch: EpochDescriptor, trustMode: TrustMode,
        phase: SessionPhase, activeRun: RunDescriptor? = nil, activeRequest: ActiveRequest? = nil,
        queue: [QueueEntry] = [], queueHeld: Bool = false, heldReason: HoldReason? = nil,
        admittedCommands: [CommandID: QueueAck] = [:], consumedEffects: Set<EffectID> = [],
        turnsUsed: Int = 0, turnLimit: Int = 80, runDeadlineMillis: UInt64? = nil,
        preSendRetries: Int = 0, invalidTracker: InvalidTracker = InvalidTracker(),
        pendingApproval: ApprovalRequest? = nil, pendingBatch: ToolBatch? = nil,
        retryDeadlineMillis: UInt64? = nil,
        liveReservations: [EffectReservation] = [],
        cancelledPendingReservations: [EffectReservation] = [],
        generation: UInt64 = 0, unresolvedOperations: [OperationRef] = [],
        droppedStaleCount: Int = 0, lastSequence: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.trustMode = trustMode
        self.phase = phase
        self.activeRun = activeRun
        self.activeRequest = activeRequest
        self.queue = queue
        self.queueHeld = queueHeld
        self.heldReason = heldReason
        self.admittedCommands = admittedCommands
        self.consumedEffects = consumedEffects
        self.turnsUsed = turnsUsed
        self.turnLimit = turnLimit
        self.runDeadlineMillis = runDeadlineMillis
        self.preSendRetries = preSendRetries
        self.invalidTracker = invalidTracker
        self.pendingApproval = pendingApproval
        self.pendingBatch = pendingBatch
        self.retryDeadlineMillis = retryDeadlineMillis
        self.liveReservations = liveReservations
        self.cancelledPendingReservations = cancelledPendingReservations
        self.generation = generation
        self.unresolvedOperations = unresolvedOperations
        self.droppedStaleCount = droppedStaleCount
        self.lastSequence = lastSequence
    }
}
