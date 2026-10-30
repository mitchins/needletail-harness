import Foundation
/// M1-B production transition function (SPEC §4.2, ARCH §§1–4).
///
/// `transition(state:event:ids:)` is TOTAL over the (phase, event) table in
/// `plans/m1-b-plan.md` §2.5: it returns a new state plus explicit typed
/// effects and durable-record intents, and performs NO I/O. Determinism:
/// given `(state, event, ids-counter)` the result is fixed (replay carries
/// the counter). Async resumption safety comes from stamped IDs +
/// generation/revision/consumption checks on every ID-carrying event —
/// a stale, duplicate or foreign completion can only drop, never advance.

public struct Transition: Sendable, Equatable {
    public let state: SessionState
    public let effects: [Effect]
    public let records: [DurableRecord]

    public init(state: SessionState, effects: [Effect] = [], records: [DurableRecord] = []) {
        self.state = state
        self.effects = effects
        self.records = records
    }
}

/// Typed EFFECT REQUESTS. Correlation IDs travel on every effect that can
/// complete asynchronously (ARCH §2); `emitUI` is display-only fire-and-
/// forget and carries none (documented exception — nothing completes it).
public enum Effect: Sendable, Equatable {
    case requestProvider(invocation: ProviderInvocation)
    case emitUI(SessionEventProjection)
    case startTimer(deadlineMillis: UInt64, purpose: String, runID: RunID)
    case cancelTimer(purpose: String, runID: RunID)
    case cancelInFlight(runID: RunID, reason: String)
    case requestApproval(ApprovalRequest)
    case reserveEffect(EffectReservation)
    /// M2-D D1: freshness validation request for a queued entry's
    /// snapshots (actor performs via the composed validator, then stamps
    /// `.attachmentValidationResult`; nil validator stamps empty
    /// observations and dispatch holds fail-closed).
    case validateAttachments(entryID: String, snapshots: [AttachmentSnapshot])
    /// M2-D D2: current-file evidence request for an undo preview or run
    /// (actor performs via the composed undo validator, then stamps
    /// `.undoValidationResult`; nil validator stamps empty observations
    /// and preflight refuses fail-closed).
    case validateUndo(undoCommandID: String, isPreview: Bool, members: [UndoValidationNeed])
    /// M2-D D2: perform ONE filesystem inverse (actor performs via the
    /// composed inverse applier, then stamps `.inverseCompleted`). In
    /// flight at most one inverse at a time; each result commits before
    /// the next inverse starts.
    case applyInverse(undoCommandID: String, inverse: UndoInverse)
    /// M2-C C0 phase 1 (plan REV12 §3.4b).
    case resolveExecIdentities(resolutionID: String, batch: ToolBatch)
}

public struct ProviderInvocation: Sendable, Equatable {
    public let effectID: EffectID
    public let requestID: RequestID
    public let runID: RunID
    public let generation: Revision
    public let alias: String
    public let epochID: EpochID
    public let sealed: Bool
    public let turnsLeft: Int
    public let deadlineMillis: UInt64?
    public let historyDigest: String

    public init(effectID: EffectID, requestID: RequestID, runID: RunID, generation: Revision, alias: String, epochID: EpochID, sealed: Bool, turnsLeft: Int, deadlineMillis: UInt64?, historyDigest: String) {
        self.effectID = effectID
        self.requestID = requestID
        self.runID = runID
        self.generation = generation
        self.alias = alias
        self.epochID = epochID
        self.sealed = sealed
        self.turnsLeft = turnsLeft
        self.deadlineMillis = deadlineMillis
        self.historyDigest = historyDigest
    }
}

public struct EffectReservation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case executor
        case provider
    }
    public let effectID: EffectID
    public let runID: RunID
    public let requestID: RequestID?
    public let generation: Revision
    public let revision: Revision
    public let mutating: Bool
    public let batch: ToolBatch
    public let kind: Kind
    public let approvedPaths: [String]
    /// M2-C C0 (plan REV12 §3.4b.7).
    public let approvedExecDigests: [String: String]
    /// M2-C C0 (plan REV12 §3.4): the resolved cwd identity bound alongside
    /// the executable digest ("dev:ino" string). C1 re-verifies at spawn.
    public let approvedCwdIdentities: [String: String]

    public init(effectID: EffectID, runID: RunID, requestID: RequestID? = nil, generation: Revision, revision: Revision, mutating: Bool, batch: ToolBatch = ToolBatch(), kind: Kind, approvedPaths: [String] = [], approvedExecDigests: [String: String] = [:], approvedCwdIdentities: [String: String] = [:]) {
        self.effectID = effectID
        self.runID = runID
        self.requestID = requestID
        self.generation = generation
        self.revision = revision
        self.mutating = mutating
        self.batch = batch
        self.kind = kind
        self.approvedPaths = approvedPaths
        self.approvedExecDigests = approvedExecDigests
        self.approvedCwdIdentities = approvedCwdIdentities
    }
}

/// Transport result: PAYLOAD ONLY, no identity (R9). The actor pairs it
/// with its pre-await reservation and stamps the completion event itself —
/// a resumed value can never stamp itself current.
public struct TransportResult: Sendable, Equatable {
    public let response: ProviderResponse
    /// Bounded verbatim wire bytes (M1-D raw ring, M1C3-4). Nil for fakes;
    /// real transports set the collected body (already bounded at 16 MiB).
    public let rawBody: [UInt8]?
    public init(response: ProviderResponse, rawBody: [UInt8]? = nil) {
        self.response = response
        self.rawBody = rawBody
    }
}

public struct ExecutorReceipt: Sendable, Equatable {
    public let callID: String
    public let status: String
    public let summary: String
    public init(callID: String, status: String, summary: String) {
        self.callID = callID
        self.status = status
        self.summary = summary
    }
}

public struct ToolCallOutcome: Sendable, Equatable, Codable {
    public let callID: String
    public let status: String
    public let summary: String
    public let data: String
    public let artifactID: String?
    /// M2-C C3 (NC-9): additional durable artifact digests beyond the
    /// primary `artifactID` (exec: the stderr stream artifact). Carried in
    /// the receipt and transcript alongside the primary reference so no
    /// preserved stream is invisible.
    public let secondaryArtifactIDs: [String]
    public let truncated: Bool
    public let warnings: [String]
    public let error: String?
    public let path: String?
    public let mode: String?
    public let beforeHash: String?
    public let afterHash: String?
    public let started: Bool?
    /// M2-D D2: original file identity at commit (edit/replace only; nil
    /// for creates). Captured at the native mutation boundary — never
    /// inferred later from a reopened path.
    public let deviceBefore: UInt64?
    public let inodeBefore: UInt64?
    /// M2-D D2: post-commit file identity (edit/replace/create). The
    /// eligibility gate compares the live file against exactly this.
    public let deviceAfter: UInt64?
    public let inodeAfter: UInt64?
    /// M2-D D2: create versus replacement. True when the mutation created
    /// a file that did not exist (create inverse = exact-identity delete;
    /// no preimage exists by construction). Nil = legacy/scripted (the
    /// group builder treats nil as replace and requires beforeHash).
    public let created: Bool?
    /// M2-D D2: granting root identity (workspace-root path string) bound
    /// at the mutation boundary. The inverse applier refuses when its own
    /// pinned root disagrees — a cross-workspace inverse never runs.
    public let grantedRoot: String?
    /// B4 per-call result classification: the executor's attestation of
    /// whether THIS call mutates. Nil = legacy/scripted (the reducer falls
    /// back to the proposal-derived classification); non-nil MUST agree
    /// with the dispatch-time intent or the result is failed closed
    /// (unknown+hold). Verified end-to-end by reopen+reconcile, which
    /// requires done results to agree with their intent on this flag.
    public let mutating: Bool?

    public init(callID: String, status: String, summary: String, data: String, artifactID: String? = nil, secondaryArtifactIDs: [String] = [], truncated: Bool = false, warnings: [String] = [], error: String? = nil, path: String? = nil, mode: String? = nil, beforeHash: String? = nil, afterHash: String? = nil, started: Bool? = nil, mutating: Bool? = nil, deviceBefore: UInt64? = nil, inodeBefore: UInt64? = nil, deviceAfter: UInt64? = nil, inodeAfter: UInt64? = nil, created: Bool? = nil, grantedRoot: String? = nil) {
        self.callID = callID
        self.status = status
        self.summary = summary
        self.data = data
        self.artifactID = artifactID
        self.secondaryArtifactIDs = secondaryArtifactIDs
        self.truncated = truncated
        self.warnings = warnings
        self.error = error
        self.path = path
        self.mode = mode
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.started = started
        self.mutating = mutating
        self.deviceBefore = deviceBefore
        self.inodeBefore = inodeBefore
        self.deviceAfter = deviceAfter
        self.inodeAfter = inodeAfter
        self.created = created
        self.grantedRoot = grantedRoot
    }

    /// Backward-compatible decode: rows/data written before D2 carry none
    /// of the identity keys (outcomes are ephemeral, but fixtures and
    /// golden data decode them — absent keys default to nil, never fail).
    private enum CodingKeys: String, CodingKey {
        case callID, status, summary, data, artifactID, secondaryArtifactIDs
        case truncated, warnings, error, path, mode, beforeHash, afterHash
        case started, mutating, deviceBefore, inodeBefore, deviceAfter, inodeAfter
        case created, grantedRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(String.self, forKey: .callID)
        status = try container.decode(String.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        data = try container.decode(String.self, forKey: .data)
        artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID)
        secondaryArtifactIDs = try container.decodeIfPresent([String].self, forKey: .secondaryArtifactIDs) ?? []
        truncated = try container.decode(Bool.self, forKey: .truncated)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        beforeHash = try container.decodeIfPresent(String.self, forKey: .beforeHash)
        afterHash = try container.decodeIfPresent(String.self, forKey: .afterHash)
        started = try container.decodeIfPresent(Bool.self, forKey: .started)
        mutating = try container.decodeIfPresent(Bool.self, forKey: .mutating)
        deviceBefore = try container.decodeIfPresent(UInt64.self, forKey: .deviceBefore)
        inodeBefore = try container.decodeIfPresent(UInt64.self, forKey: .inodeBefore)
        deviceAfter = try container.decodeIfPresent(UInt64.self, forKey: .deviceAfter)
        inodeAfter = try container.decodeIfPresent(UInt64.self, forKey: .inodeAfter)
        created = try container.decodeIfPresent(Bool.self, forKey: .created)
        grantedRoot = try container.decodeIfPresent(String.self, forKey: .grantedRoot)
    }
}

public enum ToolFailure: Error, Sendable, Equatable {
    case preDispatch(status: String, summary: String)
}

public struct ExecutorResult: Sendable, Equatable {
    public let receipt: ExecutorReceipt
    public let calls: [ToolCallOutcome]
    public init(receipt: ExecutorReceipt, calls: [ToolCallOutcome] = []) {
        self.receipt = receipt
        self.calls = calls
    }
}

public protocol ModelTransport: Sendable {
    /// Intake is a BoundedChannel, never an unbounded AsyncStream (R6).
    func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult
}

/// Optional incremental streaming (M1-D D4): transports that can emit
/// `content` deltas before final assembly expose a sink. The actor wires
/// it to the JSONL `UISink`; the delegate preserves SSE decoder state
/// across arbitrary chunk boundaries. Default nil → single-shot.
public protocol DeltaStreamingTransport: ModelTransport {
    var deltaSink: (@Sendable (String) -> Void)? { get set }
}

public protocol ToolExecutor: Sendable {
    /// Approval-request description (M1-B uses this; execution is M2).
    func describe(batch: ToolBatch) -> String
    /// M1-B: scripted fakes ONLY — no production implementation is wired.
    func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult
}

public enum ApprovalDecision: Sendable, Equatable {
    case approve
    case deny(String)
    /// The gateway cannot decide (headless, no TTY): pending forever —
    /// never auto-approve, never auto-deny (POLICY-04).
    case unavailable(String)
}

public protocol ApprovalGateway: Sendable {
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Classified transport failure (M1-C carrier, R2): the ADAPTER classifies
/// every failure at its site and throws this — it never retries. The actor
/// maps it to a classified `transportFailed` event; anything else becomes
/// ambiguous. Pure value, no transport import (Core stays dependency-free).
public struct TransportFailure: Error, Sendable, Equatable {
    public let phase: TransportPhase
    public let message: String

    public init(phase: TransportPhase, message: String) {
        self.phase = phase
        self.message = message
    }
}

/// Approval rule (M1B2-5 matrix): sealed batches never reach authorising
/// (denied at admission); observe admits read/search only (mutating denied
/// at caps); workspace asks for anything mutating; trustedExec asks only
/// for exec=ask (stickiness — an ask grant always asks).
public func batchNeedsApproval(toolNames: [String], execPolicy: ExecPolicy, mode: TrustMode, sealed: Bool) -> Bool {
    if sealed { return true }
    let mutating = toolNames.contains { $0 != "read" && $0 != "search" && $0 != "consult" }
    let hasExec = toolNames.contains("exec")
    switch mode {
    case .observe:
        return false
    case .workspace:
        return mutating || hasExec
    case .trustedExec:
        return hasExec && execPolicy == .ask
    }
}

// MARK: - Transition

public let cancelGraceMillis: UInt64 = 5_000
/// Backoff delays per pre-stream retry attempt (SPEC §11): 1s, then 2s.
/// Deterministic under tick scripting — no wall sleeps anywhere.
public func retryBackoffMillis(attempt: Int) -> UInt64 {
    UInt64(1 << min(attempt, 10)) * 1_000
}
public let maxQueueEntries = 20
public let maxQueueTextBytes = 64 * 1_024
public let maxAdmittedCommands = 512
public let maxUnresolvedOperations = 64
public let defaultTurnLimit = 80
public let defaultRunDeadlineMillis: UInt64 = 4 * 3_600 * 1_000

/// Appends an unresolved marker, enforcing the bound (S1/R19/I24).
/// Returns the new marker list plus an overflow flag: on overflow the
/// CALLER fails the run visibly (`failed(.integrityStopped)` + hold) —
/// markers are never silently dropped and never grow unbounded.
private func appendUnresolved(_ markers: [OperationRef], _ ref: OperationRef) -> (markers: [OperationRef], overflow: Bool) {
    if markers.count >= maxUnresolvedOperations {
        return (markers, true)
    }
    return (markers + [ref], false)
}

private func integrityStop<I: IDSource>(_ state: SessionState, ids: inout I) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "integrity-stopped", digest: "marker-bound", ids: &ids)
    let next = s1.replacing(
        phase: .failed(.integrityStopped("unresolved marker bound (\(maxUnresolvedOperations)) exceeded")),
        queueHeld: true, heldReason: .error("integrity stop"),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil))
    return Transition(
        state: next,
        effects: [.emitUI(.denied(cause: "integrity stop: recovery ledger overflowed; explicit operator reset required"))],
        records: prefix)
}

public func transition<I: IDSource>(_ state: SessionState, _ event: SessionEvent, _ ids: inout I) -> Transition {
    // Universal stale-drop for async events mismatching the live run
    // (R1/R3/M1B2-4): runID, requestID, generation, revision AND effect
    // consumption are ALL checked before any row below runs.
    if let stale = checkStale(state, event, &ids) {
        return stale
    }
    // Terminal phases: operator input implicitly acknowledges the receipt
    // and re-enters as a fresh admission (exactly once — the recursive call
    // lands on an idle row and terminates).
    if state.phase.isTerminal, case .operatorInput = event {
        return transition(state.replacing(phase: .idle), event, &ids)
    }
    // M2-D D2: attachment-carrying input recurses the same way (fresh
    // admission once idle; the snapshots ride the event).
    if state.phase.isTerminal, case .operatorInputAttachments = event {
        return transition(state.replacing(phase: .idle), event, &ids)
    }
    // M2-D D2: exclusive compensation phase. While an undo command owns
    // the session, dispatch-adjacent and meta work is refused loudly;
    // only queue accumulation (which cannot dispatch until undo exits),
    // ticks and input validation proceed. The undo lifecycle events
    // below bypass this guard via their own phase-matched handlers.
    if case .undoing(let activeCommand) = state.phase, !isUndoLifecycleEvent(event) {
        return holdDuringUndo(state, event: event, activeCommand: activeCommand, ids: &ids)
    }
    switch (state.phase, event) {
    case (.idle, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitFreshRun(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.idle, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitFreshRun(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.idle, .queueEdit(let entryID, let newText, let baseRevision, let at)):
        return editEntry(state, entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: at, ids: &ids)
    case (.idle, .queueWithdraw(let entryID, let at)):
        return withdrawEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.idle, .queueResume(let at)):
        return resumeQueue(state, atMillis: at, ids: &ids)
    case (.idle, .queueRetarget(let entryID, let at)):
        return retargetQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.idle, .queueReconcile(let entryID, let at)):
        return reconcileQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.idle, .acknowledgeUnknown(let operationID, let determination, let at)):
        return acknowledgeUnknownOp(state, operationID: operationID, determination: determination, atMillis: at, ids: &ids)
    case (.idle, .queueAttachmentReplace(let entryID, let snapshots, let at)):
        return replaceEntryAttachments(state, entryID: entryID, snapshots: snapshots, atMillis: at, ids: &ids)
    case (.idle, .undoPreview(let group, let preimages, let at)):
        return handleUndoPreview(state, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (.idle, .undoRun(let commandID, let group, let preimages, let at)):
        return handleUndoRun(state, commandID: commandID, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (.idle, .undoFinalize(let commandID, let group, let fileOutcomes, let at)):
        return handleUndoFinalize(state, commandID: commandID, group: group, fileOutcomes: fileOutcomes, atMillis: at, ids: &ids)
    case (.idle, .lineageForkRequest(let boundary, let at)):
        return handleLineageFork(state, boundary: boundary, atMillis: at, ids: &ids)
    case (.idle, .switchModel(let alias, let at)):
        return switchModel(state, alias: alias, atMillis: at, ids: &ids)
    case (.idle, .checkpointRequested(let at)):
        return requestCheckpoint(state, atMillis: at, ids: &ids)
    case (.idle, .cancelRequested):
        return Transition(state: state, effects: [], records: [])
    case (.idle, .invalidInput(let fingerprint, let cause, let at)):
        return stepInvalid(state, fingerprint: fingerprint, cause: cause, atMillis: at, ids: &ids)
    case (.admitting, .requestDispatched(let requestID, let at)):
        return confirmDispatch(state, requestID: requestID, atMillis: at, ids: &ids)
    case (.admitting, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.admitting, .transportFailed(_, _, let phase, let error, let at)):
        return failAdmissionTransport(state, phase: phase, error: error, atMillis: at, ids: &ids)
    case (.admitting, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.admitting, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.checkpointing, .checkpointCommitted(let newEpoch, let at)):
        return commitCheckpoint(state, newEpoch: newEpoch, atMillis: at, ids: &ids)
    case (.checkpointing, .checkpointFailed(let reason, let at)):
        return failCheckpoint(state, reason: reason, atMillis: at, ids: &ids)
    case (.checkpointing, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.requesting, .requestStarted(let requestID, let generation, _)):
        return beginStreaming(state, requestID: requestID, generation: generation, ids: &ids)
    case (.requesting, .providerResponse(_, _, let response, let at)):
        return handleProviderResponse(state, response: response, atMillis: at, ids: &ids)
    case (.requesting, .transportFailed(_, _, let phase, let error, let at)):
        return failTransport(state, phase: phase, error: error, atMillis: at, ids: &ids)
    case (.requesting, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.requesting, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.requesting, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.streaming, .providerResponse(_, _, let response, let at)):
        return handleProviderResponse(state, response: response, atMillis: at, ids: &ids)
    case (.streaming, .transportFailed(_, _, let phase, let error, let at)):
        return failTransport(state, phase: phase, error: error, atMillis: at, ids: &ids)
    case (.streaming, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.streaming, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.streaming, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.validatingTools, .validationCompleted(_, _, let batch, let at)):
        return enterAuthorising(state, batch: batch, atMillis: at, ids: &ids)
    case (.validatingTools, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.validatingTools, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.validatingTools, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.authorising, .approvalGrant(let requestID, _, _)):
        return grantApproval(state, requestID: requestID, ids: &ids)
    case (.authorising, .approvalDeny(_, _, _, _)):
        return denyApproval(state, ids: &ids)
    case (.authorising, .approvalUnavailable(let requestID, _, let reason, let at)):
        return holdForApproval(state, requestID: requestID, reason: reason, atMillis: at, ids: &ids)
    case (.authorising, .execIdentitiesResolved(let resolutionID, _, _, let identities, _)):
        return execIdentitiesResolved(state, resolutionID: resolutionID, identities: identities, ids: &ids)
    case (.authorising, .execResolutionFailed(let resolutionID, _, _, let status, let summary, _)):
        return execResolutionFailed(state, resolutionID: resolutionID, status: status, summary: summary, ids: &ids)
        case (.authorising, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.authorising, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.authorising, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.executing, .effectCompleted(let effectID, _, _, _, _, let outcome, _)):
        return completeEffect(state, effectID: effectID, outcome: outcome, ids: &ids)
    case (.executing, .effectFailed(let effectID, _, _, _, _, let error, _)):
        return failEffect(state, effectID: effectID, error: error, ids: &ids)
    case (.executing, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.executing, .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case (.executing, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.cancelling, .effectCompleted(let effectID, _, _, _, _, let outcome, _)):
        return completeCancelledPending(state, effectID: effectID, outcome: outcome, ids: &ids)
    case (.cancelling, .effectFailed(let effectID, _, _, _, _, let error, let at)):
        return completeCancelledPendingFailed(state, effectID: effectID, error: error, atMillis: at, ids: &ids)
    case (.cancelling, .tick(let now)):
        return tickCancelling(state, nowMillis: now, ids: &ids)
    case (.cancelling, .transportFailed(_, _, _, _, let at)):
        return interruptRun(state, note: "transport confirmed cancel", atMillis: at, ids: &ids)
    case (.cancelling, .cancelRequested):
        return Transition(state: state, effects: [], records: [])
    case (_, .cancelledPendingRemoved(let effectID, let at)):
        return handleCancelledPendingRemoved(state, effectID: effectID, atMillis: at, ids: &ids)
    case (.failed, .dismissRun(let at)), (.completed, .dismissRun(let at)), (.interrupted, .dismissRun(let at)):
        return dismissTerminal(state, atMillis: at, ids: &ids)
    case (.failed, .queueResume(let at)), (.completed, .queueResume(let at)), (.interrupted, .queueResume(let at)):
        return resumeQueue(state, atMillis: at, ids: &ids)
    case (.failed, .queueRetarget(let entryID, let at)), (.completed, .queueRetarget(let entryID, let at)), (.interrupted, .queueRetarget(let entryID, let at)):
        return retargetQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.failed, .queueReconcile(let entryID, let at)), (.completed, .queueReconcile(let entryID, let at)), (.interrupted, .queueReconcile(let entryID, let at)):
        return reconcileQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.failed, .acknowledgeUnknown(let operationID, let determination, let at)), (.completed, .acknowledgeUnknown(let operationID, let determination, let at)), (.interrupted, .acknowledgeUnknown(let operationID, let determination, let at)):
        return acknowledgeUnknownOp(state, operationID: operationID, determination: determination, atMillis: at, ids: &ids)
    case (.failed, .queueAttachmentReplace(let entryID, let snapshots, let at)), (.completed, .queueAttachmentReplace(let entryID, let snapshots, let at)), (.interrupted, .queueAttachmentReplace(let entryID, let snapshots, let at)):
        return replaceEntryAttachments(state, entryID: entryID, snapshots: snapshots, atMillis: at, ids: &ids)
    case (.failed, .undoPreview(let group, let preimages, let at)), (.completed, .undoPreview(let group, let preimages, let at)), (.interrupted, .undoPreview(let group, let preimages, let at)):
        return handleUndoPreview(state, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (.failed, .undoRun(let commandID, let group, let preimages, let at)), (.completed, .undoRun(let commandID, let group, let preimages, let at)), (.interrupted, .undoRun(let commandID, let group, let preimages, let at)):
        return handleUndoRun(state, commandID: commandID, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (.failed, .undoFinalize(let commandID, let group, let fileOutcomes, let at)), (.completed, .undoFinalize(let commandID, let group, let fileOutcomes, let at)), (.interrupted, .undoFinalize(let commandID, let group, let fileOutcomes, let at)):
        return handleUndoFinalize(state, commandID: commandID, group: group, fileOutcomes: fileOutcomes, atMillis: at, ids: &ids)
    case (.failed, .lineageForkRequest(let boundary, let at)), (.completed, .lineageForkRequest(let boundary, let at)), (.interrupted, .lineageForkRequest(let boundary, let at)):
        return handleLineageFork(state, boundary: boundary, atMillis: at, ids: &ids)
    case (.failed, .queueEdit(let entryID, let newText, let baseRevision, let at)),
         (.completed, .queueEdit(let entryID, let newText, let baseRevision, let at)),
         (.interrupted, .queueEdit(let entryID, let newText, let baseRevision, let at)):
        return editEntry(state, entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: at, ids: &ids)
    case (.failed, .queueWithdraw(let entryID, let at)),
         (.completed, .queueWithdraw(let entryID, let at)),
         (.interrupted, .queueWithdraw(let entryID, let at)):
        return withdrawEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.failed, .switchModel), (.completed, .switchModel), (.interrupted, .switchModel):
        return refuseTerminalMeta(state, what: "model switch", ids: &ids)
    case (.failed, .checkpointRequested), (.completed, .checkpointRequested), (.interrupted, .checkpointRequested):
        return refuseTerminalMeta(state, what: "checkpoint", ids: &ids)
    case (.failed, .cancelRequested), (.completed, .cancelRequested), (.interrupted, .cancelRequested):
        return Transition(state: state, effects: [], records: [])
    case (.failed, .tick), (.completed, .tick), (.interrupted, .tick):
        return Transition(state: state, effects: [], records: [])
    case (_, .tick(let now)):
        return checkDeadline(state, nowMillis: now, ids: &ids)
    case (_, .switchModel(let alias, let at)) where state.phase.hasActiveRun:
        return refuseBusyMeta(state, what: "model switch to '\(terminalSafe(alias))'", atMillis: at, ids: &ids)
    case (.checkpointing, .switchModel(let alias, let at)):
        return refuseBusyMeta(state, what: "model switch to '\(terminalSafe(alias))' during checkpoint", atMillis: at, ids: &ids)
    case (.admitting, .switchModel(let alias, let at)):
        return refuseBusyMeta(state, what: "model switch to '\(terminalSafe(alias))' during admission", atMillis: at, ids: &ids)
    case (.cancelling, .switchModel(let alias, let at)):
        return refuseBusyMeta(state, what: "model switch to '\(terminalSafe(alias))' during cancellation (retry at idle)", atMillis: at, ids: &ids)
    case (_, .checkpointRequested(let at)) where state.phase.isBusy:
        return refuseBusyMeta(state, what: "checkpoint (boundary busy)", atMillis: at, ids: &ids)
    case (_, .queueEdit(let entryID, let newText, let baseRevision, let at)):
        return editEntry(state, entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: at, ids: &ids)
    case (_, .queueWithdraw(let entryID, let at)):
        return withdrawEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (_, .queueResume(let at)):
        return resumeQueue(state, atMillis: at, ids: &ids)
    case (_, .queueRetarget(let entryID, let at)):
        return retargetQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (_, .queueReconcile(let entryID, let at)):
        return reconcileQueueEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (_, .acknowledgeUnknown(let operationID, let determination, let at)):
        return acknowledgeUnknownOp(state, operationID: operationID, determination: determination, atMillis: at, ids: &ids)
    case (_, .queueAttachmentReplace(let entryID, let snapshots, let at)):
        return replaceEntryAttachments(state, entryID: entryID, snapshots: snapshots, atMillis: at, ids: &ids)
    case (_, .attachmentValidationResult(let entryID, let requested, let observations, let at)):
        return handleAttachmentValidationResult(state, entryID: entryID, requested: requested, observations: observations, atMillis: at, ids: &ids)
    case (_, .undoPreview(let group, let preimages, let at)):
        return handleUndoPreview(state, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (_, .undoRun(let commandID, let group, let preimages, let at)):
        return handleUndoRun(state, commandID: commandID, group: group, preimagesAvailable: preimages, atMillis: at, ids: &ids)
    case (_, .undoValidationResult(let commandID, let isPreview, let requested, let observations, let at)):
        return handleUndoValidationResult(state, commandID: commandID, isPreview: isPreview, requested: requested, observations: observations, atMillis: at, ids: &ids)
    case (_, .inverseCompleted(let commandID, let inverseID, let outcome, let at)):
        return handleInverseCompleted(state, commandID: commandID, inverseID: inverseID, outcome: outcome, atMillis: at, ids: &ids)
    case (_, .undoFinalize(let commandID, let group, let fileOutcomes, let at)):
        return handleUndoFinalize(state, commandID: commandID, group: group, fileOutcomes: fileOutcomes, atMillis: at, ids: &ids)
    case (_, .lineageForkRequest(let boundary, let at)):
        return handleLineageFork(state, boundary: boundary, atMillis: at, ids: &ids)
    case (_, .invalidInput(let fingerprint, let cause, let at)):
        return stepInvalid(state, fingerprint: fingerprint, cause: cause, atMillis: at, ids: &ids)
    default:
        // Totality net: every remaining (phase, event) pair is a no-op
        // diagnostic — adding a row is always preferred over landing here,
        // and the M1B4-4 tick rows plus idle cancel make the common ones
        // explicit above. This arm exists so the function is total.
        return Transition(state: state, effects: [], records: [])
    }
}

// MARK: - Stale rule (R1/R3/M1B2-4)

/// Returns a drop-transition when an async event mismatches the live run,
/// else nil. Covers providerResponse, effectCompleted/Failed, approvals,
/// transportFailed, requestStarted and validationCompleted — every event
/// carrying run/request/generation/revision identity or an effectID.
/// Unknown-retention rule (R2/C3): an unconsumed MUTATING reservation whose
/// completion can no longer be trusted keeps an `unknown` marker + record;
/// an already-consumed duplicate drops with a bare counter (its outcome was
/// recorded by the first acceptance).
private func checkStale<I: IDSource>(_ state: SessionState, _ event: SessionEvent, _ ids: inout I) -> Transition? {
    switch event {
    case .providerResponse(let requestID, let generation, _, _):
        guard state.phase == .requesting || state.phase == .streaming,
              let run = state.activeRun,
              run.requestID == requestID, run.revision == generation
        else {
            return drop(state)
        }
        return nil
    case .transportFailed(let requestID, let generation, _, _, _):
        // S7: a transport confirmation for the cancelled run short-circuits
        // the grace deadline (matched on runID — generation already bumped).
        if state.phase == .cancelling,
           let run = state.activeRun, run.requestID == requestID {
            return nil
        }
        guard state.phase == .admitting || state.phase == .requesting || state.phase == .streaming,
              let run = state.activeRun,
              run.requestID == requestID, run.revision == generation
        else {
            return drop(state)
        }
        return nil
    case .requestStarted(let requestID, let generation, _):
        guard state.phase == .requesting,
              let run = state.activeRun,
              run.requestID == requestID, run.revision == generation
        else {
            return drop(state)
        }
        return nil
    case .validationCompleted(let requestID, let generation, _, _):
        guard let run = state.activeRun,
              run.requestID == requestID, run.revision == generation,
              state.phase == .validatingTools
        else {
            return drop(state)
        }
        return nil
    case .approvalGrant(let requestID, let generation, _),
         .approvalDeny(let requestID, let generation, _, _),
         .approvalUnavailable(let requestID, let generation, _, _):
        guard let run = state.activeRun,
              run.requestID == requestID, run.revision == generation,
              state.pendingApproval?.requestID == requestID
        else {
            return drop(state)
        }
        return nil
    case .effectCompleted(let effectID, let runID, let generation, let revision, _, _, _):
        if state.cancelledPendingReservations.contains(where: { $0.effectID == effectID }) {
            return nil
        }
        if state.consumedEffects.contains(effectID) {
            return drop(state)
        }
        guard let run = state.activeRun,
              run.runID == runID, run.revision == generation,
              state.liveReservations.first(where: { $0.effectID == effectID })?.revision == revision
        else {
            let mutating = state.liveReservations.first(where: { $0.effectID == effectID })?.mutating ?? false
            if mutating {
                return dropRetaining(state, effectID: effectID, ids: &ids)
            }
            return drop(state)
        }
        return nil
    case .effectFailed(let effectID, let runID, let generation, let revision, _, _, _):
        if state.cancelledPendingReservations.contains(where: { $0.effectID == effectID }) {
            return nil
        }
        if state.consumedEffects.contains(effectID) {
            return drop(state)
        }
        guard let run = state.activeRun,
              run.runID == runID, run.revision == generation,
              state.liveReservations.first(where: { $0.effectID == effectID })?.revision == revision
        else {
            let mutating = state.liveReservations.first(where: { $0.effectID == effectID })?.mutating ?? false
            if mutating {
                return dropRetaining(state, effectID: effectID, ids: &ids)
            }
            return drop(state)
        }
        return nil
    case .cancelledPendingRemoved(let effectID, _):
        if state.cancelledPendingReservations.contains(where: { $0.effectID == effectID }) {
            return nil
        }
        return drop(state)
    case .requestDispatched(let requestID, _):
        guard state.phase == .admitting,
              let run = state.activeRun, run.requestID == requestID
        else {
            return drop(state)
        }
        return nil
    case .execIdentitiesResolved(let resolutionID, let runID, let generation, _, _),
         .execResolutionFailed(let resolutionID, let runID, let generation, _, _, _):
        guard let run = state.activeRun,
              run.runID == runID, run.revision == generation,
              state.pendingResolution?.resolutionID == resolutionID
        else {
            return drop(state)
        }
        return nil
    default:
        return nil
    }
}

/// Rebuilds state with the stale counter bumped, optionally carrying new
/// markers/records/live-reservation removals.
private func bumped(
    _ state: SessionState, unresolved: [OperationRef]? = nil,
    live: [EffectReservation]? = nil, phase: SessionPhase? = nil
) -> SessionState {
    state.replacing(
        phase: phase, liveReservations: live,
        unresolvedOperations: unresolved,
        droppedStaleCount: state.droppedStaleCount + 1)
}

/// Stale drop: counter++ and nothing else.
private func drop(_ state: SessionState) -> Transition {
    Transition(state: bumped(state), effects: [], records: [])
}

/// Stale drop WITH retention (R2/C3): a live mutating effect whose outcome
/// is now unknowable keeps `unknown` markers + records, appended BEFORE
/// dropping. Already-consumed duplicates never reach here (bare counter).
/// A3-1: unknown markers derive the SAME per-proposal operation IDs as the
/// dispatch-time intents, so a later reconciliation can pair each unmatched
/// intent with its unknown outcome instead of guessing.
private func dropRetaining<I: IDSource>(_ state: SessionState, effectID: EffectID, ids: inout I) -> Transition {
    let reservation = state.liveReservations.first(where: { $0.effectID == effectID })
    let proposals = reservation?.batch.proposals ?? []
    let mutating = reservation?.mutating ?? true
    let refs: [OperationRef]
    if proposals.isEmpty {
        refs = [OperationRef(
            operationID: OperationID(effectID.raw), callID: effectID.raw,
            state: .unknown, mutating: mutating)]
    } else {
        refs = proposals.compactMap {
            let isMutating = $0.tool != "read" && $0.tool != "search" && $0.tool != "consult"
            guard isMutating else { return nil }
            return OperationRef(
                operationID: operationID(effectID: effectID, callID: $0.callID),
                callID: $0.callID, state: .unknown, mutating: true)
        }
        // If no mutating proposals, no retained markers (transcript-only)
        if refs.isEmpty {
            var live = state.liveReservations
            live.removeAll(where: { $0.effectID == effectID })
            return Transition(state: bumped(state, live: live), effects: [], records: [])
        }
    }
    var unresolved = state.unresolvedOperations
    var records: [DurableRecord] = []
    for ref in refs {
        let (markers, overflow) = appendUnresolved(unresolved, ref)
        unresolved = markers
        if overflow {
            return integrityStop(state, ids: &ids)
        }
        records.append(.operationResult(ref, outcome: "unknown"))
    }
    var live = state.liveReservations
    live.removeAll(where: { $0.effectID == effectID })
    return Transition(
        state: bumped(state, unresolved: unresolved, live: live),
        effects: [], records: records)
}

// MARK: - Row handlers

/// Mints a sequence + eventAppended prefix for operator-originated rows.
/// Timer/no-op system rows append nothing (history floods otherwise).
private func sequenced<I: IDSource>(_ state: SessionState, kind: String, digest: String, ids: inout I) -> (SessionState, [DurableRecord]) {
    let seq = ids.nextSequence()
    let next = state.replacing(lastSequence: seq.value)
    return (next, [.eventAppended(seq: seq, kind: kind, digest: digest)])
}

/// M2-D: shared with the queue reconciler (recomputed run-completion
/// digests must match the ones committed here bit-for-bit).
func eventDigest(_ parts: String...) -> String {
    fnv1aHex(parts.joined(separator: "\n"))
}

// MARK: Fresh admission (idle × operatorInput, incl. terminal implicit-ack)

private func admitFreshRun<I: IDSource>(
    _ state: SessionState, commandID: CommandID, text: String, kind: QueueKind,
    sealed: Bool, attachments: [AttachmentSnapshot] = [], atMillis: UInt64, ids: inout I
) -> Transition {
    // Sealed admission (C1): denials invalidate; mentions still admit.
    if sealed {
        switch validateSealedInput(text) {
        case .deniedToolShape(let why), .deniedPathScope(let why):
            return stepInvalid(state, fingerprint: "sealed-denial", cause: why, atMillis: atMillis, ids: &ids)
        case .admittedText:
            break
        }
    }
    // M2-D D1 MENTION-10 (sealed half): a sealed submission cannot carry
    // file attachments — no read tool exists to fetch further content, so
    // the admission fails explicitly instead of half-admitting bytes.
    if sealed, !attachments.isEmpty {
        return refuseCaps(state, commandID: commandID, cause: "sealed submissions cannot carry file attachments; use tool-enabled mode", atMillis: atMillis, ids: &ids)
    }
    // Blocked automatic continuation: unresolved markers refuse new runs
    // but still admit the text as a HELD queue entry (explicit
    // reconciliation first — POLICY-07 shape, M2 reconciles). Queuing is
    // not mutation; dispatch stays blocked.
    if !state.unresolvedOperations.isEmpty {
        let preHeld = state.replacing(
            queueHeld: true, heldReason: .error("unresolved operations block new runs"))
        let queued = admitToQueueState(preHeld, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: atMillis, ids: &ids)
        return Transition(
            state: queued.state,
            effects: queued.effects + [.emitUI(.denied(cause: "blocked: reconcile \(state.unresolvedOperations.count) unknown outcome(s) first"))],
            records: queued.records)
    }
    // Route re-check at the boundary (defense in depth; snapshots are frozen).
    if case .denied(let denial) = selectRoute(
        snapshot: state.epoch.configSnapshot, requestedAlias: state.epoch.profile.alias, sealed: sealed) {
        let (s1, prefix) = sequenced(state, kind: "route-refused", digest: eventDigest("route", commandID.raw), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "route refused: \(denial.message)"))],
            records: prefix)
    }
    if let prior = state.admittedCommands[commandID] {
        return Transition(state: state, effects: [.emitUI(.admitted(commandID: commandID, revision: prior.revision))], records: [])
    }
    let liveCount = state.queue.filter { $0.state != .withdrawn }.count
    guard liveCount < maxQueueEntries else {
        return refuseCaps(state, commandID: commandID, cause: "queue full (\(maxQueueEntries) entries)", atMillis: atMillis, ids: &ids)
    }
    // M2-D D1 (O-4/I-8): admitted excerpts count toward the queue text
    // budget alongside entry text.
    let newAttachmentBytes = attachments.reduce(0) { $0 + $1.content.excerptBytes }
    let undispatchedBytes = state.queue
        .filter { $0.state == .queued || $0.state == .held }
        .reduce(0) { $0 + $1.text.utf8.count + $1.attachmentBytes }
    guard undispatchedBytes + text.utf8.count + newAttachmentBytes <= maxQueueTextBytes else {
        return refuseCaps(state, commandID: commandID, cause: "queue text budget exceeded", atMillis: atMillis, ids: &ids)
    }
    // Reserve the new run (generation+1; run-scoped counters reset — M1B3-6).
    let runID = ids.nextRunID()
    let requestID = ids.nextRequestID()
    let effectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let generation = state.generation + 1
    let revision = Revision(generation)
    let run = RunDescriptor(runID: runID, requestID: requestID, revision: revision, startedAtMillis: atMillis, sealed: sealed)
    let reservation = EffectReservation(
        effectID: effectID, runID: runID, requestID: requestID,
        generation: revision, revision: revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(
        effectID: effectID, requestID: requestID, runID: runID, generation: revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: sealed,
        turnsLeft: state.turnLimit, deadlineMillis: atMillis + defaultRunDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value)"))
    let ack = QueueAck(commandID: commandID, entryID: "run-\(requestID.raw)", sequence: seq, revision: revision.value, state: .dispatched)
    var index = state.admittedCommands
    if index.count >= maxAdmittedCommands, index[commandID] == nil,
       let oldest = index.values.min(by: { $0.sequence.value < $1.sequence.value }) {
        index.removeValue(forKey: oldest.commandID)
    }
    index[commandID] = ack
    let next = state.replacing(
        phase: .admitting, activeRun: run, activeRequest: .some(nil),
        admittedCommands: index, consumedEffects: Set<EffectID>(),
        turnsUsed: 0, runDeadlineMillis: atMillis + defaultRunDeadlineMillis,
        preSendRetries: 0, invalidTracker: InvalidTracker(),
        retryDeadlineMillis: .some(nil),
        liveReservations: state.liveReservations + [reservation],
        generation: generation, lastSequence: seq.value)
    return Transition(
        state: next,
        effects: [
            .reserveEffect(reservation),
            .requestProvider(invocation: invocation),
            .emitUI(.admitted(commandID: commandID, revision: revision.value)),
        ],
        records: [
            .eventAppended(seq: seq, kind: "run-admitted", digest: eventDigest("admit", commandID.raw)),
            .operationIntent(OperationRef(operationID: ids.nextOperationID(), state: .intent, mutating: false)),
            // The dispatched operator text opens the transcript (D1):
            // capture-fresh snapshots compose their manifest + excerpts
            // inline (no dwell, no revalidation needed at this point).
            .transcriptAppended(.user(composeDispatchText(text: text, attachments: attachments))),
        ])
}

private func refuseCaps<I: IDSource>(
    _ state: SessionState, commandID: CommandID, cause: String, atMillis: UInt64, ids: inout I
) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "admission-rejected", digest: eventDigest("caps", commandID.raw, cause), ids: &ids)
    _ = atMillis
    return Transition(
        state: s1,
        effects: [.emitUI(.denied(cause: cause))],
        records: prefix)
}

// MARK: Queue admission for busy phases (never interleaves mid-message)

private func admitToQueueState<I: IDSource>(
    _ state: SessionState, commandID: CommandID, text: String, kind: QueueKind,
    sealed: Bool, attachments: [AttachmentSnapshot] = [], atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    // S6: the EVENT's sealed flag governs (a sealed submission queued
    // behind a non-sealed run keeps its own sealing into its own run).
    if sealed || sealedContext(state) {
        switch validateSealedInput(text) {
        case .deniedToolShape(let why), .deniedPathScope(let why):
            return stepInvalid(state, fingerprint: "sealed-denial", cause: why, atMillis: atMillis, ids: &ids)
        case .admittedText:
            break
        }
    }
    // M2-D D1 MENTION-10 (sealed half): sealed context or sealed
    // submission carrying snapshots is refused explicitly.
    if !attachments.isEmpty, sealed || sealedContext(state) {
        return refuseCaps(state, commandID: commandID, cause: "sealed sessions cannot carry file attachments; use tool-enabled mode", atMillis: atMillis, ids: &ids)
    }
    if let prior = state.admittedCommands[commandID] {
        return Transition(state: state, effects: [.emitUI(.admitted(commandID: commandID, revision: prior.revision))], records: [])
    }
    let liveCount = state.queue.filter { $0.state != .withdrawn }.count
    guard liveCount < maxQueueEntries else {
        return refuseCaps(state, commandID: commandID, cause: "queue full (\(maxQueueEntries) entries)", atMillis: atMillis, ids: &ids)
    }
    // M2-D D1 (O-4/I-8): admitted excerpts count toward the queue text
    // budget alongside entry text.
    let newAttachmentBytes = attachments.reduce(0) { $0 + $1.content.excerptBytes }
    let undispatchedBytes = state.queue
        .filter { $0.state == .queued || $0.state == .held }
        .reduce(0) { $0 + $1.text.utf8.count + $1.attachmentBytes }
    guard undispatchedBytes + text.utf8.count + newAttachmentBytes <= maxQueueTextBytes else {
        return refuseCaps(state, commandID: commandID, cause: "queue text budget exceeded", atMillis: atMillis, ids: &ids)
    }
    var index = state.admittedCommands
    if index.count >= maxAdmittedCommands {
        // Honest retention boundary (C2): prune oldest-by-sequence; a retry
        // of a pruned ID admits as a NEW entry (different ack — tellable).
        if let oldest = index.values.min(by: { $0.sequence.value < $1.sequence.value }) {
            index.removeValue(forKey: oldest.commandID)
        }
    }
    let seq = ids.nextSequence()
    let entry = QueueEntry(
        entryID: "q-\(seq.value)", commandID: commandID, kind: kind,
        state: state.queueHeld ? .held : .queued, revision: 1, text: text,
        targetEpochID: state.epoch.epochID, orderKey: seq.value, sealed: sealed,
        attachments: attachments, attachmentConsentEpoch: attachments.isEmpty ? nil : state.epoch.epochID)
    let ack = QueueAck(commandID: commandID, entryID: entry.entryID, sequence: seq, revision: 1, state: entry.state)
    index[commandID] = ack
    let next = state.replacing(
        queue: state.queue + [entry], admittedCommands: index, lastSequence: seq.value)
    return Transition(
        state: next,
        effects: [.emitUI(.admitted(commandID: commandID, revision: 1))],
        records: [
            .eventAppended(seq: seq, kind: "queue-admitted", digest: eventDigest("queue", commandID.raw)),
            .queueAdmitted(entry),
        ])
}

private func sealedContext(_ state: SessionState) -> Bool {
    state.activeRun?.sealed ?? false
}

// MARK: Queue edits / withdraw / resume (M1B2-6)

private func editEntry<I: IDSource>(
    _ state: SessionState, entryID: String, newText: String, baseRevision: UInt64,
    atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    guard let position = state.queue.firstIndex(where: { $0.entryID == entryID }) else {
        let (s1, prefix) = sequenced(state, kind: "queue-edit-unknown", digest: eventDigest("edit", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown queue entry"))], records: prefix)
    }
    let entry = state.queue[position]
    guard entry.state == .queued || entry.state == .held else {
        let (s1, prefix) = sequenced(state, kind: "queue-edit-refused", digest: eventDigest("edit", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "entry already dispatched; edits apply to undispatched items only"))], records: prefix)
    }
    guard entry.revision == baseRevision else {
        let (s1, prefix) = sequenced(state, kind: "queue-edit-stale", digest: eventDigest("edit", entryID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "stale revision \(baseRevision); current is \(entry.revision)"))],
            records: prefix)
    }
    var queue = state.queue
    // withRevision preserves attachments + consent (edit changes text, not
    // the bound snapshots; staleness is decided at dispatch, not here).
    let updated = entry.withRevision(entry.revision + 1, text: newText)
    queue[position] = updated
    var index = state.admittedCommands
    let priorSequence = index[entry.commandID]?.sequence ?? SequenceNumber(0)
    let ack = QueueAck(commandID: entry.commandID, entryID: entry.entryID, sequence: priorSequence, revision: updated.revision, state: updated.state)
    index[entry.commandID] = ack
    let (s1, prefix) = sequenced(state, kind: "queue-edited", digest: eventDigest("edit", entryID), ids: &ids)
    let next = s1.replacing(queue: queue, admittedCommands: index)
    return Transition(
        state: next,
        effects: [.emitUI(.admitted(commandID: entry.commandID, revision: updated.revision))],
        records: prefix + [.queueUpdated(updated)])
}

private func withdrawEntry<I: IDSource>(_ state: SessionState, entryID: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard let position = state.queue.firstIndex(where: { $0.entryID == entryID }) else {
        let (s1, prefix) = sequenced(state, kind: "queue-withdraw-unknown", digest: eventDigest("withdraw", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown queue entry"))], records: prefix)
    }
    let entry = state.queue[position]
    // Withdrawing an unknown delivery is an explicit operator decision
    // to drop it — recorded via the tombstone like any withdraw, never
    // an automatic action. Only reconciliation (requeue) or withdraw can
    // move a held-unknown entry; resume never touches it.
    guard entry.state == .queued || entry.state == .held || entry.state == .heldUnknown else {
        let (s1, prefix) = sequenced(state, kind: "queue-withdraw-refused", digest: eventDigest("withdraw", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "dispatched entries are history, not editable"))], records: prefix)
    }
    var queue = state.queue
    // The tombstone keeps the snapshots (provenance survives withdrawal
    // and reopen; a withdrawn entry never dispatches).
    let tombstone = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .withdrawn, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
    queue[position] = tombstone
    // S5: the ack index tracks the tombstone (a retry replays the withdrawn
    // ack — same entryID/sequence — instead of a stale queued one).
    var index = state.admittedCommands
    if let prior = index[entry.commandID] {
        index[entry.commandID] = QueueAck(
            commandID: prior.commandID, entryID: prior.entryID,
            sequence: prior.sequence, revision: prior.revision, state: .withdrawn)
    }
    let (s1, prefix) = sequenced(state, kind: "queue-withdrawn", digest: eventDigest("withdraw", entryID), ids: &ids)
    let next = s1.replacing(queue: queue, admittedCommands: index)
    return Transition(
        state: next,
        effects: [.emitUI(.admitted(commandID: entry.commandID, revision: entry.revision))],
        records: prefix + [.queueUpdated(tombstone)])
}

private func resumeQueue<I: IDSource>(_ state: SessionState, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard state.queueHeld else {
        let (s1, prefix) = sequenced(state, kind: "queue-resume-noop", digest: "resume-unheld", ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.runUpdate(phase: "queue", detail: "already unheld"))], records: prefix)
    }
    guard !state.phase.hasActiveRun else {
        let (s1, prefix) = sequenced(state, kind: "queue-resume-refused", digest: "resume-busy", ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "queue resumes only without an active run"))], records: prefix)
    }
    guard state.unresolvedOperations.isEmpty, state.pendingApproval == nil else {
        let (s1, prefix) = sequenced(state, kind: "queue-resume-blocked", digest: "resume-blocked", ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "queue blocked: reconcile or decide approval first"))], records: prefix)
    }
    // M2-D D0: resume unholds only entries bound to the current epoch.
    // Stale-target entries stay held (explicit retarget or withdraw to
    // proceed — resuming must not silently re-target them), and
    // held-unknown entries stay held (explicit reconciliation only).
    // Every unhold is durable so reopen sees the released queue.
    var queue = state.queue
    var unholds: [DurableRecord] = []
    var released = 0
    var stale = 0
    for i in queue.indices where queue[i].state == .held {
        let entry = queue[i]
        guard entry.targetEpochID == state.epoch.epochID else {
            stale += 1
            continue
        }
        released += 1
        queue[i] = QueueEntry(
            entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
            state: .queued, revision: entry.revision, text: entry.text,
            targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
            attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
        unholds.append(.queueUpdated(queue[i]))
    }
    let (s1, prefix) = sequenced(state, kind: "queue-resumed", digest: "resumed", ids: &ids)
    // Stale-target and unknown-delivery entries stay held: the former
    // need explicit retarget, the latter explicit reconciliation. The
    // queue stays held while any remain, so the next completion
    // re-trips the head barrier instead of dispatching around them.
    let stillHeld = stale > 0 || queue.contains(where: { $0.state == .heldUnknown })
    let next = s1.replacing(
        queue: queue, queueHeld: stillHeld,
        heldReason: stillHeld
            ? .some(.error(stale > 0 ? "stale-target entries held; retarget or withdraw" : "unknown deliveries held; reconcile or withdraw"))
            : .some(nil))
    let detail: String
    if stale == 0 && !queue.contains(where: { $0.state == .heldUnknown }) {
        detail = "resumed"
    } else {
        detail = "resumed (\(released) released; held entries remain: retarget, reconcile, or withdraw)"
    }
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "queue", detail: detail))],
        records: prefix + unholds)
}

/// M2-D D0: retarget a stale-epoch entry to the current epoch. The
/// retarget re-validates route + sealed consistency under the current
/// epoch (mirroring admission); a refusal changes nothing. Success
/// records the new target but does NOT release any hold — resume (or
/// reconcile, for unknown deliveries) releases separately, so no single
/// operator action both re-targets and dispatches.
private func retargetQueueEntry<I: IDSource>(_ state: SessionState, entryID: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard let position = state.queue.firstIndex(where: { $0.entryID == entryID }) else {
        let (s1, prefix) = sequenced(state, kind: "queue-retarget-unknown", digest: eventDigest("retarget", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown queue entry"))], records: prefix)
    }
    let entry = state.queue[position]
    switch entry.state {
    case .queued, .held, .heldUnknown:
        break
    case .withdrawn, .dispatched, .admittedToHistory:
        let (s1, prefix) = sequenced(state, kind: "queue-retarget-refused", digest: eventDigest("retarget", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "terminal entries are history, not retargetable"))], records: prefix)
    }
    if entry.targetEpochID == state.epoch.epochID {
        let (s1, prefix) = sequenced(state, kind: "queue-retarget-noop", digest: eventDigest("retarget", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.runUpdate(phase: "queue", detail: "already current epoch"))], records: prefix)
    }
    // Re-validate under the CURRENT epoch (admission-equivalent checks):
    // the route must still allow this profile, and sealed consistency
    // must hold for the entry's own sealing flag.
    if case .denied(let denial) = selectRoute(
        snapshot: state.epoch.configSnapshot, requestedAlias: state.epoch.profile.alias, sealed: entry.sealed) {
        let (s1, prefix) = sequenced(state, kind: "queue-retarget-denied", digest: eventDigest("retarget", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "retarget refused: route \(denial.message)"))], records: prefix)
    }
    var queue = state.queue
    // Retarget is the explicit operator re-consent (D1 MENTION-12): the
    // entry binds to the current epoch AND refreshes the attachment
    // consent to it. It never releases a hold and never touches snapshots.
    queue[position] = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: entry.state, revision: entry.revision, text: entry.text,
        targetEpochID: state.epoch.epochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments,
        attachmentConsentEpoch: entry.attachments.isEmpty ? entry.attachmentConsentEpoch : state.epoch.epochID)
    let (s1, prefix) = sequenced(state, kind: "queue-retargeted", digest: eventDigest("retarget", entryID), ids: &ids)
    let next = s1.replacing(queue: queue)
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "queue", detail: "retargeted \(entryID) to current epoch"))],
        records: prefix + [.queueUpdated(queue[position])])
}

/// M2-D D0: explicit operator reconciliation of a held-unknown delivery.
/// Requeue releases the entry for redispatch (the operator asserts
/// non-delivery or accepts the duplicate risk — recorded, never a proof
/// of non-delivery). Withdrawal uses the existing withdraw path. Only
/// `.heldUnknown` entries qualify; anything else is a denial, and resume
/// never touches this state.
private func reconcileQueueEntry<I: IDSource>(_ state: SessionState, entryID: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard let position = state.queue.firstIndex(where: { $0.entryID == entryID }) else {
        let (s1, prefix) = sequenced(state, kind: "queue-reconcile-unknown", digest: eventDigest("reconcile", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown queue entry"))], records: prefix)
    }
    let entry = state.queue[position]
    guard entry.state == .heldUnknown else {
        let (s1, prefix) = sequenced(state, kind: "queue-reconcile-refused", digest: eventDigest("reconcile", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "only held-unknown deliveries need reconciliation"))], records: prefix)
    }
    var queue = state.queue
    queue[position] = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .queued, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
    let (s1, prefix) = sequenced(state, kind: "queue-reconciled", digest: eventDigest("reconcile", entryID), ids: &ids)
    let next = s1.replacing(queue: queue)
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "queue", detail: "reconciled \(entryID): requeued by explicit operator decision"))],
        records: prefix + [.queueUpdated(queue[position])])
}

/// M2-D D3: explicit operator reconciliation of one unknown mutating
/// operation. The determination is recorded (never silent), the recovery
/// marker is discharged (never retried), and reopen honors the durable
/// acknowledgment instead of reseeding a hold. Refused when no such
/// marker exists, when a live run is in flight (the run that produced the
/// unknown may still be settling it), or mid-undo (exclusive phase).
/// Unknown DELIVERIES are out of scope — queueReconcile owns those.
private func acknowledgeUnknownOp<I: IDSource>(
    _ state: SessionState, operationID: OperationID, determination: String,
    atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    guard !state.phase.hasActiveRun else {
        let (s1, prefix) = sequenced(state, kind: "unknown-acknowledge-refused", digest: eventDigest("acknowledge", operationID.raw), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "cannot reconcile unknown outcomes while a run is in flight"))],
            records: prefix)
    }
    guard state.unresolvedOperations.contains(where: { $0.operationID == operationID }) else {
        let (s1, prefix) = sequenced(state, kind: "unknown-acknowledge-unknown", digest: eventDigest("acknowledge", operationID.raw), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "no unresolved operation \(operationID.raw)"))],
            records: prefix)
    }
    let unresolved = state.unresolvedOperations.filter { $0.operationID != operationID }
    let ack = Acknowledgment(
        subjectSessions: [state.sessionID], operationIDs: [operationID],
        determination: determination, atMillis: atMillis)
    let (s1, prefix) = sequenced(state, kind: "unknown-acknowledged", digest: eventDigest("acknowledge", operationID.raw), ids: &ids)
    let next = s1.replacing(unresolvedOperations: unresolved)
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(
            phase: "queue",
            detail: "acknowledged \(operationID.raw): \(terminalSafe(determination)) (recorded; never retried)"))],
        records: prefix + [.acknowledgedUnresolved(ack)])
}

// MARK: Model / checkpoint meta-commands

private func switchModel<I: IDSource>(_ state: SessionState, alias: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard state.epoch.configSnapshot.profiles[alias] != nil else {
        let (s1, prefix) = sequenced(state, kind: "switch-unknown", digest: eventDigest("switch", alias), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown model alias '\(terminalSafe(alias))'"))], records: prefix)
    }
    if alias == state.epoch.profile.alias {
        let (s1, prefix) = sequenced(state, kind: "switch-noop", digest: eventDigest("switch", alias), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.runUpdate(phase: "model", detail: "already on \(terminalSafe(alias))"))], records: prefix)
    }
    guard case .allowed = selectRoute(snapshot: state.epoch.configSnapshot, requestedAlias: alias, sealed: false) else {
        let (s1, prefix) = sequenced(state, kind: "switch-denied", digest: eventDigest("switch", alias), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "route to '\(terminalSafe(alias))' refused"))], records: prefix)
    }
    guard requiresNewEpoch(old: state.epoch.profile, new: state.epoch.configSnapshot.profiles[alias]!) else {
        let (s1, prefix) = sequenced(state, kind: "switch-same-epoch", digest: eventDigest("switch", alias), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.runUpdate(phase: "model", detail: "epoch unchanged"))], records: prefix)
    }
    let epoch = EpochDescriptor(
        epochID: ids.nextEpochID(), parentEpochID: state.epoch.epochID,
        configSnapshot: state.epoch.configSnapshot, profile: state.epoch.configSnapshot.profiles[alias]!,
        effectiveCaps: state.epoch.effectiveCaps, route: .allowed(endpoint: endpointURL(for: state.epoch.configSnapshot.profiles[alias]!), alias: alias),
        execComposed: state.epoch.execComposed)
    var queue = state.queue
    var heldChanges: [DurableRecord] = []
    var heldCount = 0
    for i in queue.indices where queue[i].targetEpochID != epoch.epochID && (queue[i].state == .queued) {
        let entry = queue[i]
        queue[i] = QueueEntry(
            entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
            state: .held, revision: entry.revision, text: entry.text,
            targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
            attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
        // M2-D D0: the stale-epoch hold is durable AND holds the queue —
        // retarget or withdraw is required before anything dispatches
        // past these entries (the head barrier re-trips otherwise).
        heldChanges.append(.queueUpdated(queue[i]))
        heldCount += 1
    }
    let (s1, prefix) = sequenced(state, kind: "epoch-opened", digest: eventDigest("epoch", alias), ids: &ids)
    let next = s1.replacing(epoch: epoch, queue: queue,
        queueHeld: heldCount > 0 ? true : s1.queueHeld,
        heldReason: heldCount > 0 ? .some(.staleAttachment) : s1.heldReason,
        admittedCommands: [:])
    return Transition(state: next, effects: [.emitUI(.runUpdate(phase: "epoch", detail: "switched to \(terminalSafe(alias))"))], records: prefix + [.epochOpened(epoch)] + heldChanges)
}

private func requestCheckpoint<I: IDSource>(_ state: SessionState, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    guard state.unresolvedOperations.isEmpty else {
        let (s1, prefix) = sequenced(state, kind: "checkpoint-refused-unresolved", digest: "checkpoint", ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "checkpoint needs a clean ledger; reconcile first"))], records: prefix)
    }
    let (s1, prefix) = sequenced(state, kind: "checkpointing", digest: "checkpoint", ids: &ids)
    return Transition(state: s1.replacing(phase: .checkpointing), effects: [], records: prefix)
}

private func commitCheckpoint<I: IDSource>(_ state: SessionState, newEpoch: EpochDescriptor?, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "checkpoint-done", digest: "checkpoint", ids: &ids)
    if let epoch = newEpoch {
        let next = s1.replacing(epoch: epoch, phase: .idle, admittedCommands: [:])
        return Transition(state: next, effects: [.emitUI(.runUpdate(phase: "epoch", detail: "checkpoint published"))], records: prefix + [.checkpointCommitted(epoch), .epochOpened(epoch)])
    }
    let next = s1.replacing(phase: .idle)
    return Transition(state: next, effects: [.emitUI(.runUpdate(phase: "epoch", detail: "checkpoint unchanged"))], records: prefix)
}

private func failCheckpoint<I: IDSource>(_ state: SessionState, reason: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "checkpoint-failed", digest: eventDigest("checkpoint", reason), ids: &ids)
    let next = s1.replacing(phase: .idle)
    return Transition(state: next, effects: [.emitUI(.denied(cause: "checkpoint failed: \(terminalSafe(reason)); epoch unchanged"))], records: prefix)
}

// MARK: Invalid attempts (CORE-03)

private func stepInvalid<I: IDSource>(
    _ state: SessionState, fingerprint: String, cause: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    let count = state.invalidTracker.fingerprint == fingerprint ? state.invalidTracker.count + 1 : 1
    let tracker = InvalidTracker(fingerprint: fingerprint, count: count)
    if count >= InvalidTracker.limit {
        if state.phase.hasActiveRun || state.phase == .admitting {
            let cancelled = cancelActive(state, atMillis: atMillis, ids: &ids)
            let failed = failRun(cancelled.state, failure: .invalidStopped("three identical invalid/denied attempts: \(terminalSafe(cause))"), hold: true, atMillis: atMillis, ids: &ids)
            return Transition(
                state: failed.state.replacing(invalidTracker: tracker),
                effects: cancelled.effects + failed.effects,
                records: cancelled.records + failed.records)
        }
        let (s1, prefix) = sequenced(state, kind: "invalid-stopped", digest: eventDigest("invalid", fingerprint), ids: &ids)
        let next = s1.replacing(
            phase: .failed(.invalidStopped("three identical invalid/denied attempts: \(terminalSafe(cause))")),
            queueHeld: true, heldReason: .error("invalidStopped"), invalidTracker: tracker)
        return Transition(
            state: next,
            effects: [.emitUI(.denied(cause: "stopped after three identical invalid attempts: \(terminalSafe(cause))"))],
            records: prefix)
    }
    let (s1, prefix) = sequenced(state, kind: "invalid-counted", digest: eventDigest("invalid", fingerprint), ids: &ids)
    let next = s1.replacing(invalidTracker: tracker)
    return Transition(
        state: next,
        effects: [.emitUI(.denied(cause: terminalSafe(cause)))],
        records: prefix)
}

// MARK: Dispatch confirmation + streaming

private func confirmDispatch<I: IDSource>(_ state: SessionState, requestID: RequestID, atMillis: UInt64, ids: inout I) -> Transition {
    _ = requestID
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "requesting", digest: "dispatched", ids: &ids)
    guard let run = state.activeRun else {
        return Transition(state: s1, effects: [], records: prefix)
    }
    let active = ActiveRequest(requestID: run.requestID, runID: run.runID, generation: run.revision, delivery: .sending, bytesOut: 0)
    let next = s1.replacing(phase: .requesting, activeRequest: .some(active), turnsUsed: state.turnsUsed + 1)
    return Transition(state: next, effects: [], records: prefix)
}

private func beginStreaming<I: IDSource>(_ state: SessionState, requestID: RequestID, generation: Revision, ids: inout I) -> Transition {
    _ = requestID
    _ = generation
    let (s1, prefix) = sequenced(state, kind: "streaming", digest: "started", ids: &ids)
    return Transition(state: s1.replacing(phase: .streaming), effects: [], records: prefix)
}

// MARK: Provider responses

private func handleProviderResponse<I: IDSource>(
    _ state: SessionState, response: ProviderResponse, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    switch response.outcome {
    case .textDeltaComplete(let text, let proposals, let isFinal):
        // Transcript (D1): assistant text and verbatim tool calls join the
        // ordered conversation. Nil arguments only occur on scripted/fake
        // proposals (production assembly always fills them); "" keeps the
        // transcript consistent with the batch the run actually validates.
        var transcript: [DurableRecord] = []
        if !text.isEmpty {
            transcript.append(.transcriptAppended(.assistantText(text)))
        }
        for proposal in proposals {
            transcript.append(.transcriptAppended(.toolCall(NativeToolCall(
                callID: proposal.callID, tool: proposal.tool,
                arguments: proposal.arguments ?? ""))))
        }
        if !proposals.isEmpty {
            let (s1, prefix) = sequenced(state, kind: "validating", digest: eventDigest("proposals", "\(proposals.count)"), ids: &ids)
            let batch = ToolBatch(proposals)
            // The request reservation completes with its response: consume
            // it so a duplicate response drops as already-consumed (R3).
            var consumed = s1.consumedEffects
            var live = s1.liveReservations
            if let run = s1.activeRun {
                for reservation in live where reservation.requestID == run.requestID && !reservation.mutating {
                    consumed.insert(reservation.effectID)
                }
                live.removeAll(where: { $0.requestID == run.requestID && !$0.mutating })
            }
            let next = s1.replacing(phase: .validatingTools, consumedEffects: consumed, pendingBatch: .some(batch), liveReservations: live)
            return Transition(state: next, effects: [], records: prefix + transcript)
        }
        if isFinal {
            let finished = finishRunWithQueue(state, receipt: { run, at in RunReceipt(runID: run.runID, completedAtMillis: at, turnsUsed: state.turnsUsed, toolCallCount: 0) }, atMillis: atMillis, ids: &ids)
            return Transition(
                state: finished.state, effects: finished.effects,
                records: transcript + finished.records)
        }
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: "interim", ids: &ids)
        return Transition(state: s1.replacing(phase: .requesting), effects: [], records: prefix + transcript)
    case .failed(let error):
        return failRun(state, failure: .providerError(terminalSafe(error)), hold: true, atMillis: atMillis, ids: &ids)
    case .interrupted:
        return interruptRun(state, note: "provider-signalled stop", atMillis: atMillis, ids: &ids)
    }
}

/// Final response: pop the next dispatchable entry (steer-first FIFO) into
/// a fresh run, else land completed. Holds and stale/foreign-epoch entries
/// never auto-dispatch.
private func finishRunWithQueue<I: IDSource>(
    _ state: SessionState, receipt: (RunDescriptor, UInt64) -> RunReceipt, atMillis: UInt64,
    observations: [String: [AttachmentObservation]] = [:], ids: inout I
) -> Transition {
    guard let run = state.activeRun else {
        let (s1, prefix) = sequenced(state, kind: "completed-no-run", digest: "completed", ids: &ids)
        return Transition(state: s1.replacing(phase: .completed(RunReceipt(runID: RunID("none"), completedAtMillis: atMillis, turnsUsed: state.turnsUsed, toolCallCount: 0))), effects: [], records: prefix)
    }
    let receiptValue = receipt(run, atMillis)
    guard !state.queueHeld, state.unresolvedOperations.isEmpty else {
        let (s1, prefix) = sequenced(state, kind: "completed-held", digest: eventDigest("completed", run.runID.raw), ids: &ids)
        let next = s1.replacing(
            phase: .completed(receiptValue), activeRun: .some(nil), activeRequest: .some(nil),
            pendingApproval: .some(nil), pendingBatch: .some(nil),
            pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
        return Transition(
            state: next,
            effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; queue held"))],
            records: prefix)
    }
    let completedPhase = SessionPhase.completed(receiptValue)
    switch classifyQueuePop(state, observations: observations) {
    case .none:
        let (s1, prefix) = sequenced(state, kind: "completed", digest: eventDigest("completed", run.runID.raw), ids: &ids)
        let next = s1.replacing(
            phase: completedPhase, activeRun: .some(nil), activeRequest: .some(nil),
            pendingApproval: .some(nil), pendingBatch: .some(nil),
            pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
        return Transition(
            state: next,
            effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished"))],
            records: prefix)
    case .barrierHold(let head, let reason):
        return landQueueBarrier(state, head: head, reason: reason, completedPhase: completedPhase, digest: eventDigest("completed", run.runID.raw), ids: &ids)
    case .needsValidation(let entry):
        // The entry dwelled with snapshots: dispatch waits for same-event
        // freshness evidence. The run still lands completed; the validator
        // result re-enters the pop. Nothing is marked, nothing held.
        let (s1, prefix) = sequenced(state, kind: "attachment-validation-requested", digest: eventDigest("validate", entry.entryID), ids: &ids)
        let next = s1.replacing(
            phase: completedPhase, activeRun: .some(nil), activeRequest: .some(nil),
            pendingApproval: .some(nil), pendingBatch: .some(nil),
            pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
        return Transition(
            state: next,
            effects: [.validateAttachments(entryID: entry.entryID, snapshots: entry.attachments),
                      .emitUI(.runUpdate(phase: "completed", detail: "run finished; validating attachments for \(entry.entryID)"))],
            records: prefix)
    case .dispatch(let position):
        return dispatchQueuePosition(state, position: position, completedPhase: completedPhase, digest: eventDigest("completed", run.runID.raw), atMillis: atMillis, ids: &ids)
    case .staleHold(let position, let fileStale, let reason):
        return holdStaleQueuePosition(state, position: position, fileStale: fileStale, reason: reason, completedPhase: completedPhase, digest: eventDigest("completed", run.runID.raw), ids: &ids)
    }
}

/// M2-D D1 pop classification shared by run completion and the
/// validation-result event. The barrier runs first (D0); only a
/// barrier-clear candidate with snapshots reaches the validation gate.
private enum QueuePop: Sendable, Equatable {
    /// Nothing dispatchable (empty queue or phase-busy guards upstream).
    case none
    /// A non-terminal predecessor blocks the candidate (D0 head barrier).
    case barrierHold(head: QueueEntry, reason: HoldReason)
    /// Barrier-clear candidate carrying snapshots but no same-event
    /// evidence: request validation, dispatch nothing.
    case needsValidation(entry: QueueEntry)
    /// Barrier-clear candidate ready to dispatch (no snapshots, or every
    /// snapshot fresh under same-event evidence).
    case dispatch(position: Int)
    /// Barrier-clear candidate with a refused snapshot: mark held (durable)
    /// and hold the queue; never dispatch, never refresh.
    case staleHold(position: Int, fileStale: Bool, reason: String)
}

private func classifyQueuePop(_ state: SessionState, observations: [String: [AttachmentObservation]]) -> QueuePop {
    let order: [QueueKind] = [.steer, .followUp]
    for kind in order {
        guard let position = state.queue.firstIndex(where: {
            $0.kind == kind && $0.state == .queued && $0.targetEpochID == state.epoch.epochID
        }) else { continue }
        // M2-D D0 head barrier: a non-terminal entry ahead of the
        // candidate that is not dispatchable (held for any reason, or
        // targeting a stale epoch) blocks the whole queue — later
        // entries never overtake a held head, and a stale head never
        // silently skips. The queue holds with an explicit reason
        // until the operator resolves, retargets, or withdraws.
        let blocked = state.queue[..<position].first(where: { entry in
            switch entry.state {
            case .withdrawn, .admittedToHistory:
                return false
            case .queued:
                return entry.targetEpochID != state.epoch.epochID
            case .held, .heldUnknown, .dispatched:
                return true
            }
        })
        if let head = blocked {
            let reason: HoldReason
            if head.targetEpochID != state.epoch.epochID {
                reason = .error("queue head targets a stale epoch; retarget or withdraw \(head.entryID)")
            } else {
                reason = .error("queue head held; resolve, reconcile, or withdraw \(head.entryID)")
            }
            return .barrierHold(head: head, reason: reason)
        }
        let entry = state.queue[position]
        guard !entry.attachments.isEmpty else {
            return .dispatch(position: position)
        }
        guard let entryObservations = observations[entry.entryID] else {
            return .needsValidation(entry: entry)
        }
        let route = selectRoute(
            snapshot: state.epoch.configSnapshot,
            requestedAlias: state.epoch.profile.alias, sealed: entry.sealed)
        for snapshot in entry.attachments {
            let observation = entryObservations.first(where: { $0.snapshotHash == snapshot.contentHash })
            let verdict = attachmentVerdict(
                snapshot: snapshot, observation: observation,
                currentEpochID: state.epoch.epochID, currentLocality: state.epoch.profile.locality,
                route: route, consentEpochID: entry.attachmentConsentEpoch, entrySealed: entry.sealed)
            if case .stale(let fileStale, let reason) = verdict {
                return .staleHold(position: position, fileStale: fileStale, reason: reason)
            }
        }
        return .dispatch(position: position)
    }
    return .none
}

/// D0 barrier landing, extracted verbatim (completed + hold at the head).
private func landQueueBarrier<I: IDSource>(
    _ state: SessionState, head: QueueEntry, reason: HoldReason,
    completedPhase: SessionPhase, digest: String, ids: inout I
) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "completed-barred", digest: digest, ids: &ids)
    let next = s1.replacing(
        phase: completedPhase, activeRun: .some(nil), activeRequest: .some(nil),
        pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
    let held = next.replacing(queueHeld: true, heldReason: .some(reason))
    return Transition(
        state: held,
        effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; queue held at \(head.entryID)"))],
        records: prefix)
}

/// D0 dispatch landing, extracted verbatim (mark dispatched + reserve),
/// with the D1 transcript composition (validated excerpts inline).
private func dispatchQueuePosition<I: IDSource>(
    _ state: SessionState, position: Int, completedPhase: SessionPhase,
    digest: String, atMillis: UInt64, ids: inout I
) -> Transition {
    var queue = state.queue
    let entry = queue[position]
    let dispatched = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .dispatched, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
    queue[position] = dispatched
    let mid = state.replacing(
        phase: completedPhase, activeRun: .some(nil), activeRequest: .some(nil),
        queue: queue, pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
    let (s1, prefix) = sequenced(mid, kind: "completed-dispatched", digest: digest, ids: &ids)
    // New run, same text: reserve inline (generation+1, counters reset).
    let next = admitReservedRun(s1, entry: dispatched, atMillis: atMillis, ids: &ids)
    return Transition(
        state: next.state,
        effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; next queued entry dispatched"))] + next.effects,
        records: prefix + [.queueUpdated(dispatched)] + next.records)
}

/// M2-D D1 stale landing: the refused entry is marked `.held` durably
/// (external fixes must NOT auto-dispatch — explicit replace + resume is
/// the only release), the queue holds with the specific reason, and the
/// entries behind are preserved untouched. File staleness raises
/// `.staleAttachment`; route/consent/sealed refusals raise queue errors.
private func holdStaleQueuePosition<I: IDSource>(
    _ state: SessionState, position: Int, fileStale: Bool, reason: String,
    completedPhase: SessionPhase, digest: String, ids: inout I
) -> Transition {
    var queue = state.queue
    let entry = queue[position]
    let heldEntry = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .held, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
    queue[position] = heldEntry
    let (s1, prefix) = sequenced(state, kind: "completed-stale-attachment", digest: digest, ids: &ids)
    let next = s1.replacing(
        phase: completedPhase, activeRun: .some(nil), activeRequest: .some(nil),
        queue: queue, pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil), liveReservations: [])
    let heldReason: HoldReason = fileStale ? .staleAttachment : .error(reason)
    let held = next.replacing(queueHeld: true, heldReason: .some(heldReason))
    return Transition(
        state: held,
        effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; queue held: \(reason)"))],
        records: prefix + [.queueUpdated(heldEntry)])
}

/// M2-D D1: the validator's verdict re-enters the pop. Dispatch happens
/// only from `.completed` with no live run; any intervening state change
/// (fresh run, cancel path, new hold) drops the evidence with a receipt —
/// the next completion revalidates. Snapshot mismatch against the request
/// (explicit replace in flight) re-requests for the current snapshots.
private func handleAttachmentValidationResult<I: IDSource>(
    _ state: SessionState, entryID: String, requested: [AttachmentSnapshot],
    observations: [AttachmentObservation], atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    func drop(_ state: SessionState, detail: String, ids: inout I) -> Transition {
        let (s1, prefix) = sequenced(state, kind: "attachment-validation-dropped", digest: eventDigest("validate", entryID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.runUpdate(phase: "queue", detail: detail))],
            records: prefix)
    }
    guard let entry = state.queue.first(where: { $0.entryID == entryID }),
          entry.state == .queued else {
        return drop(state, detail: "validation result superseded (entry no longer queued)", ids: &ids)
    }
    guard case .completed(let receiptValue) = state.phase, state.activeRun == nil else {
        return drop(state, detail: "validation result superseded (run state changed)", ids: &ids)
    }
    guard !state.queueHeld, state.unresolvedOperations.isEmpty else {
        return drop(state, detail: "validation result superseded (queue held)", ids: &ids)
    }
    if entry.attachments != requested {
        // Explicit replace landed while validation was in flight: judge
        // the CURRENT snapshots, never the superseded request.
        let (s1, prefix) = sequenced(state, kind: "attachment-validation-rerequested", digest: eventDigest("validate", entryID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.validateAttachments(entryID: entryID, snapshots: entry.attachments),
                      .emitUI(.runUpdate(phase: "queue", detail: "snapshots replaced; revalidating \(entryID)"))],
            records: prefix)
    }
    switch classifyQueuePop(state, observations: [entryID: observations]) {
    case .none:
        return drop(state, detail: "validation result superseded (nothing dispatchable)", ids: &ids)
    case .barrierHold(let head, let reason):
        return landQueueBarrier(state, head: head, reason: reason, completedPhase: .completed(receiptValue), digest: eventDigest("completed", entryID), ids: &ids)
    case .needsValidation(let candidate):
        // The evidence belongs to a different entry than the current
        // head (e.g. a steer queued after the validated follow-up):
        // validate the head instead of judging anything by it.
        let (s1, prefix) = sequenced(state, kind: "attachment-validation-rerequested", digest: eventDigest("validate", candidate.entryID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.validateAttachments(entryID: candidate.entryID, snapshots: candidate.attachments),
                      .emitUI(.runUpdate(phase: "queue", detail: "validating \(candidate.entryID)"))],
            records: prefix)
    case .dispatch(let position):
        return dispatchQueuePosition(state, position: position, completedPhase: .completed(receiptValue), digest: eventDigest("completed", entryID), atMillis: atMillis, ids: &ids)
    case .staleHold(let position, let fileStale, let reason):
        return holdStaleQueuePosition(state, position: position, fileStale: fileStale, reason: reason, completedPhase: .completed(receiptValue), digest: eventDigest("completed", entryID), ids: &ids)
    }
}

/// M2-D D1: explicit operator replacement of an entry's snapshots (the
/// fix path for stale holds). Queued or held entries only; preserves
/// state (a stale hold still needs resume to release — replace alone
/// never dispatches); refreshes consent to the live epoch (explicit
/// re-consent by the replacing action); re-checks the text budget with
/// the new excerpts (fail closed on overflow).
private func replaceEntryAttachments<I: IDSource>(
    _ state: SessionState, entryID: String, snapshots: [AttachmentSnapshot],
    atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    guard let position = state.queue.firstIndex(where: { $0.entryID == entryID }) else {
        let (s1, prefix) = sequenced(state, kind: "queue-replace-unknown", digest: eventDigest("replace", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "unknown queue entry"))], records: prefix)
    }
    let entry = state.queue[position]
    guard entry.state == .queued || entry.state == .held else {
        let (s1, prefix) = sequenced(state, kind: "queue-replace-refused", digest: eventDigest("replace", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "entry already dispatched; replace applies to undispatched items only"))], records: prefix)
    }
    if entry.sealed, !snapshots.isEmpty {
        let (s1, prefix) = sequenced(state, kind: "queue-replace-denied", digest: eventDigest("replace", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "sealed entries cannot carry file attachments"))], records: prefix)
    }
    let newBytes = snapshots.reduce(0) { $0 + $1.content.excerptBytes }
    let othersBytes = state.queue
        .filter { $0.entryID != entryID && ($0.state == .queued || $0.state == .held) }
        .reduce(0) { $0 + $1.text.utf8.count + $1.attachmentBytes }
    guard othersBytes + entry.text.utf8.count + newBytes <= maxQueueTextBytes else {
        let (s1, prefix) = sequenced(state, kind: "queue-replace-denied", digest: eventDigest("replace", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "queue text budget exceeded"))], records: prefix)
    }
    var queue = state.queue
    queue[position] = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: entry.state, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: snapshots,
        attachmentConsentEpoch: snapshots.isEmpty ? entry.attachmentConsentEpoch : state.epoch.epochID)
    let (s1, prefix) = sequenced(state, kind: "queue-replaced", digest: eventDigest("replace", entryID), ids: &ids)
    let next = s1.replacing(queue: queue)
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "queue", detail: "replaced attachments for \(entryID)"))],
        records: prefix + [.queueUpdated(queue[position])])
}

/// M2-D D2: undo lifecycle + lineage handlers (O-2 journal, O-3 notice).
///
/// Authority rules (never re-decided at review):
/// - Exactly one inverse is ever in flight: each `inverseCompleted` commits
///   its durable result BEFORE the next intent commits.
/// - Duplicates return the recorded disposition with no new records and no
///   second inverse (the journal is append-only; the live mirror is only
///   a bounded idempotency index).
/// - Preflight covers the WHOLE group: one conflict ⇒ zero inverses, and
///   the refusal is itself a durable disposition + notice (audit trail —
///   never a silent deny, never a success claim).
/// - Crash recovery never replays from memory: `pendingUndo` is live-only
///   and dies with the process; `undoFinalize` + `reconcileUndoJournal`
///   rebuild authority from durable records + filesystem evidence.

/// True for the events the exclusive `undoing` phase still accepts. Every
/// other event during `undoing` is held off by `holdDuringUndo`.
private func isUndoLifecycleEvent(_ event: SessionEvent) -> Bool {
    switch event {
    case .undoPreview, .undoRun, .undoValidationResult, .inverseCompleted, .undoFinalize:
        return true
    default:
        return false
    }
}

/// Exclusive-phase hold: while an undo command owns the session, only
/// queue accumulation (undispatchable until undo exits), ticks and input
/// validation proceed. Dispatch-adjacent and meta work is refused loudly
/// — never queued behind the compensation, never run through it.
private func holdDuringUndo<I: IDSource>(
    _ state: SessionState, event: SessionEvent, activeCommand: String, ids: inout I
) -> Transition {
    switch event {
    case .tick(let now):
        return checkDeadline(state, nowMillis: now, ids: &ids)
    case .operatorInput(let commandID, let text, let kind, _, let sealed, let at):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case .operatorInputAttachments(let commandID, let text, let kind, let sealed, let attachments, let at):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, attachments: attachments, atMillis: at, ids: &ids)
    case .queueEdit(let entryID, let newText, let baseRevision, let at):
        return editEntry(state, entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: at, ids: &ids)
    case .queueWithdraw(let entryID, let at):
        return withdrawEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case .invalidInput(let fingerprint, let cause, let at):
        return stepInvalid(state, fingerprint: fingerprint, cause: cause, atMillis: at, ids: &ids)
    case .cancelRequested:
        let (s1, prefix) = sequenced(state, kind: "undo-cancel-ignored", digest: eventDigest("undo", activeCommand), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo \(activeCommand) in progress; cancel ignored"))],
            records: prefix)
    default:
        let (s1, prefix) = sequenced(state, kind: "undo-held", digest: eventDigest("undo", activeCommand), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo \(activeCommand) in progress; request held off"))],
            records: prefix)
    }
}

/// Runs pure preflight over every member against bound observations.
/// Returns the unanimous verdict plus per-member conflict reasons (empty
/// when eligible). Missing evidence fails closed, never assumed. Pairing
/// is by derived inverse ID (Major 1): member order and inverse order are
/// reverses of each other, so indices never align them.
private func preflightPending(
    _ pending: PendingUndo, observations: [UndoFileObservation]
) -> (eligible: Bool, conflicts: [String]) {
    var byInverse: [String: UndoFileObservation] = [:]
    for observation in observations {
        byInverse[observation.inverseID] = observation
    }
    var inverseByID: [String: UndoInverse] = [:]
    for inverse in pending.inverses {
        inverseByID[inverse.inverseID] = inverse
    }
    var conflicts: [String] = []
    for member in pending.group.members {
        let inverseID = undoInverseID(
            undoCommandID: pending.commandID, groupID: pending.group.groupID,
            operationID: member.operationID)
        guard let inverse = inverseByID[inverseID] else {
            conflicts.append("\(member.path): no inverse planned; refusing")
            continue
        }
        let available: Bool
        switch inverse.kind {
        case .restore(let digest, _):
            available = digest.isEmpty || (pending.preimagesAvailable[digest] ?? false)
        case .removeCreated:
            available = true
        }
        switch undoPreflight(member: member, observation: byInverse[inverseID], preimageAvailable: available) {
        case .eligible:
            break
        case .conflict(let reason):
            conflicts.append(reason)
        }
    }
    return (conflicts.isEmpty, conflicts)
}

private func handleUndoPreview<I: IDSource>(
    _ state: SessionState, group: ChangeGroup,
    preimagesAvailable: [String: Bool], atMillis _: UInt64, ids: inout I
) -> Transition {
    guard undoQuiescent(state) else {
        let (s1, prefix) = sequenced(state, kind: "undo-preview-refused", digest: eventDigest("undo-preview", group.groupID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo preview refused: session not quiescent"))],
            records: prefix)
    }
    guard undoChainLinks(members: group.members) else {
        let (s1, prefix) = sequenced(state, kind: "undo-preview-refused", digest: eventDigest("undo-preview", group.groupID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo preview refused: chained edits to the same path do not link (group \(group.groupID))"))],
            records: prefix)
    }
    let needs = undoValidationNeeds(undoCommandID: "preview", group: group)
    let pending = PendingUndo(
        commandID: "preview", group: group, preimagesAvailable: preimagesAvailable,
        inverses: undoInverses(undoCommandID: "preview", group: group),
        entryPhase: state.phase, isPreview: true)
    let (s1, prefix) = sequenced(state, kind: "undo-preview", digest: eventDigest("undo-preview", group.groupID), ids: &ids)
    let next = s1.replacing(pendingUndo: .some(pending))
    return Transition(
        state: next,
        effects: [.validateUndo(undoCommandID: "preview", isPreview: true, members: needs)],
        records: prefix)
}

private func handleUndoRun<I: IDSource>(
    _ state: SessionState, commandID: String, group: ChangeGroup,
    preimagesAvailable: [String: Bool], atMillis: UInt64, ids: inout I
) -> Transition {
    // O-2 idempotency: a recorded disposition answers duplicates — no new
    // records, no second inverse, ever.
    if let recorded = state.undoDispositions.first(where: { $0.undoCommandID == commandID }) {
        return Transition(
            state: state,
            effects: [.emitUI(.runUpdate(
                phase: "undo",
                detail: "duplicate undo \(commandID): \(recorded.outcome.rawValue) (no second inverse)"))],
            records: [])
    }
    guard undoQuiescent(state) else {
        let (s1, prefix) = sequenced(state, kind: "undo-run-refused", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo \(commandID) refused: session not quiescent"))],
            records: prefix)
    }
    guard !group.members.isEmpty else {
        let (s1, prefix) = sequenced(state, kind: "undo-run-refused", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo \(commandID) refused: empty change group"))],
            records: prefix)
    }
    // Reverse-chain rule first: a broken same-path chain refuses the whole
    // group as a durable disposition (audit trail, never silent).
    guard undoChainLinks(members: group.members) else {
        return commitUndoDisposition(
            state, commandID: commandID, group: group, fileOutcomes: [],
            outcome: .refused,
            reason: "chained edits to the same path do not link; refusing the group",
            entryPhase: state.phase, atMillis: atMillis, ids: &ids)
    }
    let inverses = undoInverses(undoCommandID: commandID, group: group)
    let needs = undoValidationNeeds(undoCommandID: commandID, group: group)
    let pending = PendingUndo(
        commandID: commandID, group: group, preimagesAvailable: preimagesAvailable,
        inverses: inverses, entryPhase: state.phase, isPreview: false)
    let (s1, prefix) = sequenced(state, kind: "undo-run", digest: eventDigest("undo", commandID), ids: &ids)
    let next = s1.replacing(phase: .undoing(commandID: commandID), pendingUndo: .some(pending))
    return Transition(
        state: next,
        effects: [.validateUndo(undoCommandID: commandID, isPreview: false, members: needs)],
        records: prefix)
}

private func handleUndoValidationResult<I: IDSource>(
    _ state: SessionState, commandID: String, isPreview: Bool,
    requested: [UndoValidationNeed], observations: [UndoFileObservation],
    atMillis: UInt64, ids: inout I
) -> Transition {
    guard let pending = state.pendingUndo,
          pending.commandID == commandID, pending.isPreview == isPreview
    else {
        let (s1, prefix) = sequenced(state, kind: "undo-validation-superseded", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.runUpdate(phase: "undo", detail: "validation superseded (no matching pending undo)"))],
            records: prefix)
    }
    let requestedIDs = Set(requested.map(\.inverseID))
    let pendingIDs = Set(pending.inverses.map(\.inverseID))
    guard requestedIDs == pendingIDs else {
        let (s1, prefix) = sequenced(state, kind: "undo-validation-superseded", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.runUpdate(phase: "undo", detail: "validation superseded (evidence request mismatch)"))],
            records: prefix)
    }
    let (eligible, conflicts) = preflightPending(pending, observations: observations)
    if isPreview {
        let (s1, prefix) = sequenced(state, kind: "undo-previewed", digest: eventDigest("undo-preview", pending.group.groupID), ids: &ids)
        let next = s1.replacing(pendingUndo: .some(nil))
        if eligible {
            // The eligible preview names the exact reversible set
            // (path + before/after hashes per member, Major 4) — the
            // driver needs no second query to show what would run.
            let listed = pending.group.members.map { member in
                let before = member.beforeHash ?? "none(created)"
                return "\(member.path) before=\(before) after=\(member.afterHash)"
            }.joined(separator: "; ")
            return Transition(
                state: next,
                effects: [.emitUI(.runUpdate(
                    phase: "undo",
                    detail: "undo preview: \(pending.group.members.count) file(s) eligible, no mutation: \(listed)"))],
                records: prefix)
        }
        return Transition(
            state: next,
            effects: [.emitUI(.denied(
                cause: "undo preview: \(conflicts.count) conflict(s): \(conflicts.joined(separator: "; "))"))],
            records: prefix)
    }
    // Run path: the exclusive phase must still hold AND the session must
    // still be quiescent (re-checked before each commit per the plan).
    guard case .undoing(let active) = state.phase, active == commandID,
          undoQuiescentIgnoringPhase(state)
    else {
        return commitUndoDisposition(
            state, commandID: commandID, group: pending.group, fileOutcomes: [],
            outcome: .refused,
            reason: "session left quiescence during validation; refusing the group",
            entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids)
    }
    guard eligible else {
        return commitUndoDisposition(
            state, commandID: commandID, group: pending.group, fileOutcomes: [],
            outcome: .refused,
            reason: "preflight conflict (\(conflicts.count)): \(conflicts.joined(separator: "; "))",
            entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids)
    }
    guard let first = pending.inverses.first else {
        return commitUndoDisposition(
            state, commandID: commandID, group: pending.group, fileOutcomes: [],
            outcome: .refused, reason: "no inverses planned",
            entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids)
    }
    let (s1, prefix) = sequenced(state, kind: "undo-inverse-intent", digest: eventDigest("undo", first.inverseID), ids: &ids)
    let ref = OperationRef(
        operationID: OperationID(first.inverseID), callID: first.inverseID,
        state: .intent, mutating: true)
    return Transition(
        state: s1,
        effects: [
            .applyInverse(undoCommandID: commandID, inverse: first),
            .emitUI(.runUpdate(phase: "undo", detail: "undo \(commandID): inverting \(first.path)")),
        ],
        records: prefix + [.operationIntent(ref)])
}

private func handleInverseCompleted<I: IDSource>(
    _ state: SessionState,     commandID: String, inverseID: String,
    outcome: UndoInverseOutcome, atMillis: UInt64, ids: inout I
) -> Transition {
    guard let pending = state.pendingUndo,
          pending.commandID == commandID, !pending.isPreview,
          case .undoing(let active) = state.phase, active == commandID,
          pending.nextIndex < pending.inverses.count,
          pending.inverses[pending.nextIndex].inverseID == inverseID
    else {
        let (s1, prefix) = sequenced(state, kind: "undo-inverse-superseded", digest: eventDigest("undo", inverseID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.runUpdate(phase: "undo", detail: "inverse result superseded (\(inverseID))"))],
            records: prefix)
    }
    let inverse = pending.inverses[pending.nextIndex]
    // The durable result state is chosen per branch (Blocker 1): settled
    // inverses (applied/refused/clean-failed) commit `.done` so the
    // journal pairs them complete; an ambiguous inverse commits `.unknown`
    // so BOTH reconcilers hold it — the live queue hold alone would vanish
    // on reopen, but the durable unknown never does.
    switch outcome {
    case .applied(let detail):
        let resultRef = OperationRef(
            operationID: OperationID(inverseID), callID: inverseID,
            state: .done, mutating: true)
        let member = memberForInverse(group: pending.group, inverseID: inverseID)
        let file = UndoFileOutcome(
            inverseID: inverseID, path: inverse.path,
            result: "applied", detail: detail,
            beforeHash: member?.beforeHash, afterHash: member?.afterHash ?? "")
        let advanced = pending.advancing(outcome: file)
        return continueUndoChain(
            state, pending: advanced, resultRef: resultRef,
            outcomeText: "applied: \(detail)", atMillis: atMillis, ids: &ids)
    case .refused(let reason):
        // A refused inverse mutates nothing: the chain continues past it
        // (UNDO-05 legs pin the partial shape at the END of the chain).
        let resultRef = OperationRef(
            operationID: OperationID(inverseID), callID: inverseID,
            state: .done, mutating: true)
        let member = memberForInverse(group: pending.group, inverseID: inverseID)
        let file = UndoFileOutcome(
            inverseID: inverseID, path: inverse.path,
            result: "refused", detail: reason,
            beforeHash: member?.beforeHash, afterHash: member?.afterHash ?? "")
        let advanced = pending.advancing(outcome: file)
        return continueUndoChain(
            state, pending: advanced, resultRef: resultRef,
            outcomeText: "refused: \(reason)", atMillis: atMillis, ids: &ids)
    case .failed(let error, let possiblyMutated):
        let resultRef = OperationRef(
            operationID: OperationID(inverseID), callID: inverseID,
            state: possiblyMutated ? .unknown : .done, mutating: true)
        if possiblyMutated {
            // Unknown mutation state: NOTHING further runs; the inverse
            // holds as unknown and the queue holds with it.
            let member = memberForInverse(group: pending.group, inverseID: inverseID)
            let file = UndoFileOutcome(
                inverseID: inverseID, path: inverse.path,
                result: "unknown", detail: "failed: \(error) (may have mutated; holding)",
                beforeHash: member?.beforeHash, afterHash: member?.afterHash ?? "")
            let files = pending.fileOutcomes + [file]
            return commitUndoDisposition(
                state, commandID: commandID, group: pending.group,
                fileOutcomes: files, outcome: undoDispositionOutcome(for: files),
                reason: "inverse \(inverse.path) failed ambiguously; holding for reconciliation",
                entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids,
                extraRecords: [.operationResult(resultRef, outcome: "unknown: \(error)")])
        }
        // Clean failure (the applier attests nothing mutated): the chain
        // HALTS (a failed leg is never stepped over silently) and the
        // disposition records the partial truth.
        let member = memberForInverse(group: pending.group, inverseID: inverseID)
        let file = UndoFileOutcome(
            inverseID: inverseID, path: inverse.path,
            result: "failed", detail: "failed: \(error) (nothing mutated)",
            beforeHash: member?.beforeHash, afterHash: member?.afterHash ?? "")
        let files = pending.fileOutcomes + [file]
        return commitUndoDisposition(
            state, commandID: commandID, group: pending.group,
            fileOutcomes: files, outcome: undoDispositionOutcome(for: files),
            reason: "inverse \(inverse.path) failed cleanly; halting the chain",
            entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids,
            extraRecords: [.operationResult(resultRef, outcome: "failed: \(error)")])
    }
}

/// Advances a settled (applied/refused) inverse: commits its durable result
/// and either starts the next inverse or commits the final disposition.
/// The result commits BEFORE the next intent — crash boundaries hold.
private func continueUndoChain<I: IDSource>(
    _ state: SessionState,     pending: PendingUndo, resultRef: OperationRef,
    outcomeText: String, atMillis: UInt64, ids: inout I
) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "undo-inverse-result", digest: eventDigest("undo", resultRef.operationID.raw), ids: &ids)
    let carried = s1.replacing(pendingUndo: .some(pending))
    if pending.nextIndex < pending.inverses.count {
        let inverse = pending.inverses[pending.nextIndex]
        let (s2, intentPrefix) = sequenced(carried, kind: "undo-inverse-intent", digest: eventDigest("undo", inverse.inverseID), ids: &ids)
        let intentRef = OperationRef(
            operationID: OperationID(inverse.inverseID), callID: inverse.inverseID,
            state: .intent, mutating: true)
        return Transition(
            state: s2,
            effects: [
                .applyInverse(undoCommandID: pending.commandID, inverse: inverse),
                .emitUI(.runUpdate(
                    phase: "undo",
                    detail: "undo \(pending.commandID): \(outcomeText); inverting \(inverse.path)")),
            ],
            records: prefix + [.operationResult(resultRef, outcome: outcomeText)]
                + intentPrefix + [.operationIntent(intentRef)])
    }
    let outcome = undoDispositionOutcome(for: pending.fileOutcomes)
    let reason: String
    switch outcome {
    case .completed:
        reason = "all \(pending.fileOutcomes.count) inverse(s) applied"
    case .partial:
        reason = "partial compensation: \(pending.fileOutcomes.filter { $0.result == "applied" }.count) applied, \(pending.fileOutcomes.filter { $0.result != "applied" }.count) refused/failed (never an atomic rollback)"
    case .refused:
        reason = "all inverses refused; nothing mutated"
    case .needsReconciliation:
        reason = "unknown inverse outcome; holding for reconciliation"
    }
    return commitUndoDisposition(
        carried, commandID: pending.commandID, group: pending.group,
        fileOutcomes: pending.fileOutcomes, outcome: outcome, reason: reason,
        entryPhase: pending.entryPhase, atMillis: atMillis, ids: &ids,
        extraRecords: [.operationResult(resultRef, outcome: outcomeText)])
}

/// Driver-stamped recovery for crash boundary 5: every inverse is settled
/// in the durable log but the disposition was never committed (crash
/// between the last result and the disposition). Outcomes arrive
/// reconciled from the log; the disposition + notice commit atomically.
/// Idempotent: an existing disposition wins immediately.
private func handleUndoFinalize<I: IDSource>(
    _ state: SessionState, commandID: String, group: ChangeGroup,
    fileOutcomes: [UndoFileOutcome], atMillis: UInt64, ids: inout I
) -> Transition {
    if let recorded = state.undoDispositions.first(where: { $0.undoCommandID == commandID }) {
        return Transition(
            state: state,
            effects: [.emitUI(.runUpdate(
                phase: "undo",
                detail: "duplicate undo \(commandID): \(recorded.outcome.rawValue) (no second inverse)"))],
            records: [])
    }
    let expected = undoInverses(undoCommandID: commandID, group: group)
    guard fileOutcomes.count == expected.count,
          Set(fileOutcomes.map(\.inverseID)) == Set(expected.map(\.inverseID))
    else {
        let (s1, prefix) = sequenced(state, kind: "undo-finalize-refused", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(
                cause: "undo finalize refused: settled outcomes do not cover every inverse"))],
            records: prefix)
    }
    guard undoQuiescent(state) || state.phase == .undoing(commandID: commandID) else {
        let (s1, prefix) = sequenced(state, kind: "undo-finalize-refused", digest: eventDigest("undo", commandID), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "undo finalize refused: session not quiescent"))],
            records: prefix)
    }
    let outcome = undoDispositionOutcome(for: fileOutcomes)
    let reason: String
    switch outcome {
    case .completed:
        reason = "all \(fileOutcomes.count) inverse(s) applied (recovered)"
    case .partial:
        reason = "partial compensation (recovered)"
    case .refused:
        reason = "all inverses refused (recovered)"
    case .needsReconciliation:
        reason = "unknown inverse outcome (recovered); holding for reconciliation"
    }
    return commitUndoDisposition(
        state, commandID: commandID, group: group, fileOutcomes: fileOutcomes,
        outcome: outcome, reason: reason,
        entryPhase: state.phase == .undoing(commandID: commandID)
            ? (state.pendingUndo?.entryPhase ?? .idle) : state.phase,
        atMillis: atMillis, ids: &ids)
}

/// Record-only rewind lineage fork (UNDO-08 mechanism): selects an existing
/// turn/epoch boundary, retains parent/fork/boundary identities with an
/// honest workspace-divergence warning. No file mutation, no branch
/// switch, no history rewrite — the parent conversation is preserved.
private func handleLineageFork<I: IDSource>(
    _ state: SessionState, boundary: LineageBoundary,
    atMillis: UInt64, ids: inout I
) -> Transition {
    guard undoQuiescent(state) else {
        let (s1, prefix) = sequenced(state, kind: "lineage-fork-refused", digest: eventDigest("fork", "\(boundary.epochID.raw)"), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "rewind fork refused: session not quiescent"))],
            records: prefix)
    }
    guard boundary.epochID == state.epoch.epochID else {
        let (s1, prefix) = sequenced(state, kind: "lineage-fork-refused", digest: eventDigest("fork", "\(boundary.epochID.raw)"), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "rewind fork refused: boundary epoch is not the live epoch"))],
            records: prefix)
    }
    guard boundary.throughSequence <= state.lastSequence else {
        let (s1, prefix) = sequenced(state, kind: "lineage-fork-refused", digest: eventDigest("fork", "\(boundary.epochID.raw)"), ids: &ids)
        return Transition(
            state: s1,
            effects: [.emitUI(.denied(cause: "rewind fork refused: boundary lies beyond live history"))],
            records: prefix)
    }
    let seq = ids.nextSequence()
    let fork = LineageFork(
        forkID: "fork-\(seq.value)", sessionID: state.sessionID,
        parentEpochID: state.epoch.epochID, boundary: boundary,
        divergenceNote: "rewound-fork of epoch \(state.epoch.epochID.raw) at sequence \(boundary.throughSequence): history preserved; workspace NOT restored and unverified against the boundary",
        atMillis: atMillis)
    let (s1, prefix) = sequenced(state, kind: "lineage-fork", digest: eventDigest("fork", fork.forkID), ids: &ids)
    return Transition(
        state: s1,
        effects: [.emitUI(.runUpdate(
            phase: "rewind",
            detail: "lineage fork \(fork.forkID) at sequence \(boundary.throughSequence) (record only; worktree untouched)"))],
        records: prefix + [.lineageFork(fork)])
}

/// Commits an authoritative disposition + its model-visible notice
/// atomically (O-3: the notice never precedes its results, never follows
/// without them). Restores the entry phase, clears the pending command,
/// and bounds the live disposition mirror (the log itself is append-only).
/// A needsReconciliation disposition additionally holds the queue and
/// records bounded unknown markers for every unknown inverse — explicit
/// reconciliation (not another inverse) releases them.
private func commitUndoDisposition<I: IDSource>(
    _ state: SessionState, commandID: String, group: ChangeGroup,
    fileOutcomes: [UndoFileOutcome], outcome: UndoDispositionOutcome,
    reason: String, entryPhase: SessionPhase, atMillis: UInt64, ids: inout I,
    extraRecords: [DurableRecord] = []
) -> Transition {
    let record = UndoDispositionRecord(
        undoCommandID: commandID, groupID: group.groupID,
        outcome: outcome, fileOutcomes: fileOutcomes, reason: reason,
        atMillis: atMillis)
    let notice = WorkspaceChangeNotice(
        undoCommandID: commandID, groupID: group.groupID,
        outcome: outcome, files: fileOutcomes,
        hadExecProposals: group.hadExecProposals, reason: reason)
    var dispositions = state.undoDispositions.filter { $0.undoCommandID != commandID } + [record]
    if dispositions.count > maxUndoDispositions {
        dispositions.removeFirst(dispositions.count - maxUndoDispositions)
    }
    var unresolved = state.unresolvedOperations
    if outcome == .needsReconciliation {
        for file in fileOutcomes where file.result == "unknown" {
            let (markers, overflow) = appendUnresolved(
                unresolved,
                OperationRef(
                    operationID: OperationID(file.inverseID), callID: file.inverseID,
                    state: .unknown, mutating: true))
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
        }
    }
    let (s1, prefix) = sequenced(state, kind: "undo-disposition", digest: eventDigest("undo", commandID), ids: &ids)
    var next = s1.replacing(
        phase: entryPhase, unresolvedOperations: unresolved,
        undoDispositions: dispositions, pendingUndo: .some(nil))
    if outcome == .needsReconciliation {
        next = next.replacing(
            queueHeld: true,
            heldReason: .error("undo \(commandID): \(reason)"))
    }
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(
            phase: "undo",
            detail: "undo \(commandID): \(outcome.rawValue) — \(reason)"))],
        records: prefix + extraRecords + [.undoDisposition(record),
                                          .transcriptAppended(.workspaceChangeNotice(notice))])
}

/// Quiescence re-check that tolerates the exclusive phase itself: the
/// transition enters `undoing` through the gate, so steady-state checks
/// inside the phase must not trip on the phase they own.
private func undoQuiescentIgnoringPhase(_ state: SessionState) -> Bool {
    guard !state.phase.hasActiveRun else { return false }
    switch state.phase {
    case .idle, .failed, .completed, .interrupted, .undoing:
        break
    case .admitting, .requesting, .streaming, .validatingTools, .authorising,
         .executing, .cancelling, .checkpointing:
        return false
    }
    guard state.unresolvedOperations.isEmpty else { return false }
    guard state.pendingApproval == nil else { return false }
    guard state.activeRequest == nil else { return false }
    // Same reconstructed-deliveryUnknown leg as undoQuiescent (Major 3):
    // a heldUnknown queue entry means a dispatch whose outcome never
    // arrived, and undo never compensates underneath one.
    guard !state.queue.contains(where: { $0.state == .heldUnknown }) else { return false }
    return true
}

/// Reserves a follow-up run from an already-dispatched queue entry (used by
/// the auto-continue path). Mirrors admitFreshRun without re-admission.
private func admitReservedRun<I: IDSource>(_ state: SessionState, entry: QueueEntry, atMillis: UInt64, ids: inout I) -> Transition {
    let runID = ids.nextRunID()
    let requestID = ids.nextRequestID()
    let effectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let generation = state.generation + 1
    let revision = Revision(generation)
    let run = RunDescriptor(runID: runID, requestID: requestID, revision: revision, startedAtMillis: atMillis, sealed: entry.sealed)
    let reservation = EffectReservation(
        effectID: effectID, runID: runID, requestID: requestID,
        generation: revision, revision: revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(
        effectID: effectID, requestID: requestID, runID: runID, generation: revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: entry.sealed,
        turnsLeft: state.turnLimit, deadlineMillis: atMillis + defaultRunDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value)"))
    let history = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .admittedToHistory, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed,
        attachments: entry.attachments, attachmentConsentEpoch: entry.attachmentConsentEpoch)
    var queue = state.queue
    if let position = queue.firstIndex(where: { $0.entryID == entry.entryID }) {
        queue[position] = history
    }
    let next = state.replacing(
        phase: .admitting, activeRun: .some(run), activeRequest: .some(nil),
        queue: queue, consumedEffects: Set<EffectID>(),
        turnsUsed: 0, runDeadlineMillis: atMillis + defaultRunDeadlineMillis,
        preSendRetries: 0, retryDeadlineMillis: .some(nil),
        liveReservations: state.liveReservations + [reservation],
        generation: generation, lastSequence: seq.value)
    // M2-D D0 dispatch linkage: bind the entry to the exact provider
    // run/request/effect/epoch being invoked, committed ATOMICALLY with
    // the history admission + intent + transcript below (same records
    // group the actor commits before any effect performs). A crash
    // before this group commits leaves no link (boundary 1: never sent);
    // a crash after leaves a link the reopen join resolves against the
    // run-completion event (boundary 2 vs 3). No link, no dispatch.
    let link = QueueDispatchLink(
        entryID: entry.entryID, commandID: entry.commandID,
        runID: run.runID, requestID: run.requestID, effectID: effectID,
        epochID: state.epoch.epochID)
    return Transition(
        state: next,
        effects: [
            .reserveEffect(reservation),
            .requestProvider(invocation: invocation),
        ],
        records: [
            .eventAppended(seq: seq, kind: "run-admitted", digest: eventDigest("admit", entry.commandID.raw)),
            .operationIntent(OperationRef(operationID: ids.nextOperationID(), state: .intent, mutating: false)),
            .queueDispatched(link),
            .queueUpdated(history),
            // The dispatched queued text opens the transcript (D1):
            // validated snapshots compose their manifest + excerpts inline.
            .transcriptAppended(.user(composeDispatchText(text: entry.text, attachments: entry.attachments))),
        ])
}

private func failRun<I: IDSource>(
    _ state: SessionState, failure: RunFailure, hold: Bool, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    // M2-D D0: the failure record is bound to the run when one is active,
    // so reopen can distinguish a determinately failed run (history stands,
    // explicit resume releases the hold) from an unknown delivery (hold
    // until reconciled). Without an active run the legacy fixed digest
    // stands — nothing attributable exists to bind.
    let failureDigest = state.activeRun.map { eventDigest("failed", $0.runID.raw) } ?? "failed"
    let (s1, prefix) = sequenced(state, kind: "failed", digest: failureDigest, ids: &ids)
    let next = s1.replacing(
        phase: .failed(failure), activeRun: .some(nil), activeRequest: .some(nil),
        queueHeld: hold ? true : s1.queueHeld,
        heldReason: hold ? .error("run failed") : s1.heldReason,
        pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
        retryDeadlineMillis: .some(nil), liveReservations: [])
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "failed", detail: "run failed"))],
        records: prefix)
}

private func interruptRun<I: IDSource>(_ state: SessionState, note: String, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "interrupted", digest: eventDigest("interrupted", note), ids: &ids)
    let next = s1.replacing(
        phase: .interrupted, activeRun: .some(nil), activeRequest: .some(nil),
        pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
        retryDeadlineMillis: .some(nil), liveReservations: [])
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "interrupted", detail: note))],
        records: prefix)
}

// MARK: Transport failures (R5)

private func failTransport<I: IDSource>(
    _ state: SessionState, phase: TransportPhase, error: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    switch phase {
    case .preSend:
        // M1-C backoff: arm the deadline here; the tick row dispatches.
        // No inline resend exists anywhere (single policy path).
        guard state.preSendRetries < 2 else {
            return failRun(state, failure: .providerError("pre-send failures exhausted retries: \(terminalSafe(error))"), hold: true, atMillis: atMillis, ids: &ids)
        }
        guard let run = state.activeRun else {
            return failRun(state, failure: .providerError(terminalSafe(error)), hold: true, atMillis: atMillis, ids: &ids)
        }
        let deadline = atMillis + retryBackoffMillis(attempt: state.preSendRetries)
        let (s1, prefix) = sequenced(state, kind: "retry-armed", digest: eventDigest("retry", run.requestID.raw), ids: &ids)
        let next = s1.replacing(
            preSendRetries: state.preSendRetries + 1, retryDeadlineMillis: .some(deadline))
        return Transition(
            state: next,
            effects: [.startTimer(deadlineMillis: deadline, purpose: "retry-backoff", runID: run.runID)],
            records: prefix)
    case .postContent:
        // Bytes demonstrably flowed: this is a provider/protocol failure
        // (SPEC §12.2 exit 4), not an operator cancellation (130).
        return failRun(state, failure: .providerError("provider stream failed: \(terminalSafe(error))"), hold: true, atMillis: atMillis, ids: &ids)
    case .ambiguous:
        let (s1, prefix) = sequenced(state, kind: "delivery-unknown", digest: "ambiguous", ids: &ids)
        let ref = OperationRef(operationID: ids.nextOperationID(), state: .unknown, mutating: false)
        let (markers, overflow) = appendUnresolved(state.unresolvedOperations, ref)
        if overflow {
            return integrityStop(s1, ids: &ids)
        }
        let next = s1.replacing(
            queueHeld: true, heldReason: .error("ambiguous delivery; explicit reconciliation required"),
            unresolvedOperations: markers)
        var active: ActiveRequest? = nil
        if let request = state.activeRequest {
            active = ActiveRequest(requestID: request.requestID, runID: request.runID, generation: request.generation, delivery: .deliveryUnknown, bytesOut: request.bytesOut)
        }
        let held = next.replacing(activeRequest: active)
        return Transition(
            state: held,
            effects: [.emitUI(.denied(cause: "ambiguous delivery held for reconciliation"))],
            records: prefix + [.operationResult(ref, outcome: "unknown")])
    }
}

private func failAdmissionTransport<I: IDSource>(
    _ state: SessionState, phase: TransportPhase, error: String, atMillis: UInt64, ids: inout I
) -> Transition {
    switch phase {
    case .preSend:
        return failTransport(state, phase: .preSend, error: error, atMillis: atMillis, ids: &ids)
    case .postContent:
        return failRun(state, failure: .providerError("transport failed during admission: \(terminalSafe(error))"), hold: true, atMillis: atMillis, ids: &ids)
    case .ambiguous:
        let (s1, prefix) = sequenced(state, kind: "delivery-unknown", digest: "ambiguous", ids: &ids)
        let ref = OperationRef(operationID: ids.nextOperationID(), state: .unknown, mutating: false)
        let (markers, overflow) = appendUnresolved(state.unresolvedOperations, ref)
        if overflow {
            return integrityStop(s1, ids: &ids)
        }
        let next = s1.replacing(
            queueHeld: true, heldReason: .error("ambiguous delivery; explicit reconciliation required"),
            unresolvedOperations: markers)
        return Transition(
            state: next,
            effects: [.emitUI(.denied(cause: "ambiguous delivery held for reconciliation"))],
            records: prefix + [.operationResult(ref, outcome: "unknown")])
    }
}

// MARK: Authorising

/// Single capability rule shared by the transition authoriser and the
/// M1-D scripted executor (one definition — the backend enforces the same
/// grants the transition checked, defense in depth, never a second table).
public func toolAllowed(_ tool: String, caps: ToolCapabilities) -> Bool {
    switch tool {
    case "read": return caps.read
    case "search": return caps.search
    case "edit": return caps.edit
    case "write": return caps.write
    case "exec": return caps.exec != .denied
    case "consult": return caps.consult
    default: return false // Unknown tools do not exist in v0.1: fail closed (I05).
    }
}

private func enterAuthorising<I: IDSource>(_ state: SessionState, batch: ToolBatch, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    // Sealed responses must never propose tools (the request was tool-free):
    // a sealed batch is a protocol violation, failed closed — never approved.
    if state.activeRun?.sealed == true, !batch.proposals.isEmpty {
        return failRun(state, failure: .providerError("sealed response proposed tools; sealed requests are tool-free"), hold: true, atMillis: atMillis, ids: &ids)
    }
    // C0 reducer-side credential register (plan REV12 §3.3 / NC-10): the env
    // overlay must not carry a registered credential name.
    for proposal in batch.proposals where proposal.tool == "exec" {
        if let raw = proposal.arguments, let bytes = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: bytes, options: []) as? [String: Any],
           let env = obj["env"] as? [String: Any] {
            let credentialNames = credentialEnvNames(in: state.epoch)
            for key in env.keys where credentialNames.contains(key) {
                guard state.turnsUsed < state.turnLimit else {
                    return failRun(state, failure: .budgetExhausted("turn budget exhausted after credential check"), hold: true, atMillis: atMillis, ids: &ids)
                }
                // Typed invalid-arguments receipt (deterministic per-call
                // intent+result + continuation) — a model-authorable input
                // rejection, never a terminal held run.
                let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("credential-overlay", key), ids: &ids)
                var records: [DurableRecord] = []
                var transcripts: [DurableRecord] = []
                var uiEffects: [Effect] = []
                for prop in batch.proposals {
                    let isMut = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
                    let opID = ids.nextOperationID()
                    records.append(.operationIntent(OperationRef(operationID: opID, callID: prop.callID, state: .intent, mutating: isMut)))
                    records.append(.operationResult(OperationRef(operationID: opID, callID: prop.callID, state: .done, mutating: isMut),
                                                    outcome: "tool-failure: credential overlay carries \(terminalSafe(key)) (invalid-arguments)"))
                    var credText = "preDispatch invalid-arguments: credential overlay carries \(terminalSafe(key))"
                    if prop.tool == "exec" {
                        let receipt = execReceiptText(callID: prop.callID, op: opID, status: "invalid-arguments", started: false, artifact: nil, truncated: false, summary: "credential overlay carries \(key)")
                        credText += "\n[\(receipt)]"
                        uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                    }
                    transcripts.append(.transcriptAppended(.toolResponse(callID: prop.callID, text: credText)))
                }
                let nextEffectID = ids.nextEffectID()
                let seq = ids.nextSequence()
                let reservation = EffectReservation(effectID: nextEffectID, runID: s1.activeRun!.runID, requestID: s1.activeRun!.requestID, generation: s1.activeRun!.revision, revision: s1.activeRun!.revision, mutating: false, kind: .provider)
                let invocation = ProviderInvocation(effectID: nextEffectID, requestID: s1.activeRun!.requestID, runID: s1.activeRun!.runID, generation: s1.activeRun!.revision, alias: s1.epoch.profile.alias, epochID: s1.epoch.epochID, sealed: s1.activeRun!.sealed, turnsLeft: s1.turnLimit - s1.turnsUsed, deadlineMillis: s1.runDeadlineMillis, historyDigest: fnv1aHex("\(s1.sessionID.raw):\(seq.value):credential"))
                let next = s1.replacing(phase: .requesting, turnsUsed: s1.turnsUsed + 1, liveReservations: s1.liveReservations + [reservation], lastSequence: seq.value)
                return Transition(state: next, effects: uiEffects + [.reserveEffect(reservation), .requestProvider(invocation: invocation)],
                                  records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", nextEffectID.raw))] + records + transcripts)
            }
        }
    }

    // Structural shape check first: non-empty callIDs, non-empty tools, no
    // duplicate callIDs. Malformed batches fail closed (WIRE-05 spirit).
    var seenCalls: Set<String> = []
    for proposal in batch.proposals {
        guard !proposal.callID.isEmpty, !proposal.tool.isEmpty, seenCalls.insert(proposal.callID).inserted else {
            return failRun(state, failure: .providerError("malformed tool batch: empty or duplicate call identity"), hold: true, atMillis: atMillis, ids: &ids)
        }
    }
    // B1 strict validator: validate every call before side effects
    let validated: [ValidatedToolCall]
    do {
        validated = try ToolValidator.validateBatchArguments(batch: batch)
    } catch let ToolFailure.preDispatch(status, summary) {
        // M2-C C0 (plan REV12 §3.2): the FINAL-03/HEAD-03 compatibility
        // branch is RETIRED. Validation failure ⇒ the legacy deterministic
        // per-call `invalid-arguments` receipts + provider continuation.
        // Deterministic per-call done receipts preserving SPEC status, no FS touch
        // Synthesize a provider continuation with per-call operationResults
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("preDispatch", status), ids: &ids)
        guard let run = s1.activeRun else {
            return failRun(state, failure: .providerError("validation without run"), hold: true, atMillis: atMillis, ids: &ids)
        }
        guard s1.turnsUsed < s1.turnLimit else {
            return failRun(state, failure: .budgetExhausted("turn budget exhausted after validation"), hold: true, atMillis: atMillis, ids: &ids)
        }
        // Per-call mutating classification derived from tool name, not model flag
        // For preDispatch, create matching intent+result so reopen sees completed, not held orphan
        var records: [DurableRecord] = []
        var transcripts: [DurableRecord] = []
        var uiEffects: [Effect] = []
        for prop in batch.proposals {
            let isMut = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            let opID = ids.nextOperationID()
            let intentRef = OperationRef(operationID: opID, callID: prop.callID, state: .intent, mutating: isMut)
            let resultRef = OperationRef(operationID: opID, callID: prop.callID, state: .done, mutating: isMut)
            records.append(.operationIntent(intentRef))
            records.append(.operationResult(resultRef, outcome: "tool-failure: \(summary) (\(status))"))
            var text = "preDispatch \(status): \(summary)"
            if prop.tool == "exec" {
                let receipt = execReceiptText(callID: prop.callID, op: opID, status: status, started: false, artifact: nil, truncated: false, summary: summary)
                text += "\n[\(receipt)]"
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
            transcripts.append(.transcriptAppended(.toolResponse(callID: prop.callID, text: text)))
        }
        let nextEffectID = ids.nextEffectID()
        let seq = ids.nextSequence()
        let reservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
        let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed, turnsLeft: state.turnLimit - s1.turnsUsed, deadlineMillis: state.runDeadlineMillis, historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):preDispatch"))
        let next = s1.replacing(phase: .requesting, consumedEffects: s1.consumedEffects, turnsUsed: s1.turnsUsed + 1, pendingBatch: .some(nil), liveReservations: s1.liveReservations + [reservation], lastSequence: seq.value)
        return Transition(state: next, effects: uiEffects + [.reserveEffect(reservation), .requestProvider(invocation: invocation)], records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", nextEffectID.raw))] + records + transcripts)
    } catch {
        return failRun(state, failure: .providerError("validation error: \(error)"), hold: true, atMillis: atMillis, ids: &ids)
    }
    // Absolute protected paths (never grantable) -> deterministic denied
    var absoluteDenied: [String] = []
    var grantablePaths: [String] = []
    for v in validated {
        for p in v.paths {
            let cls = ToolValidator.protectedClassification(for: p)
            if cls == .absoluteDenied { absoluteDenied.append(p) }
            else if cls == .grantable { grantablePaths.append(p) }
        }
    }
    // Byte-distinct grantable enumeration: NFC/NFD twins are distinct
    // inodes and must both be listed for approval (Swift Set would
    // collapse them via canonical equality).
    grantablePaths = ToolValidator.dedupeByteDistinct(grantablePaths)
    if !absoluteDenied.isEmpty {
        let status = "denied"
        let summary = "absolute protected path denied: \(absoluteDenied.joined(separator: ","))"
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("absolute-denied", summary), ids: &ids)
        guard let run = s1.activeRun else { return failRun(state, failure: .providerError("absolute denied without run"), hold: true, atMillis: atMillis, ids: &ids) }
        guard s1.turnsUsed < s1.turnLimit else { return failRun(state, failure: .budgetExhausted("turn budget exhausted"), hold: true, atMillis: atMillis, ids: &ids) }
        var records: [DurableRecord] = []
        var transcripts: [DurableRecord] = []
        var uiEffects: [Effect] = []
        for prop in batch.proposals {
            let isMut = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            let opID = ids.nextOperationID()
            let intentRef = OperationRef(operationID: opID, callID: prop.callID, state: .intent, mutating: isMut)
            let resultRef = OperationRef(operationID: opID, callID: prop.callID, state: .done, mutating: isMut)
            records.append(.operationIntent(intentRef))
            records.append(.operationResult(resultRef, outcome: "tool-failure: \(summary) (\(status))"))
            var denyText = "denied: \(summary)"
            if prop.tool == "exec" {
                let receipt = execReceiptText(callID: prop.callID, op: opID, status: status, started: false, artifact: nil, truncated: false, summary: summary)
                denyText += "\n[\(receipt)]"
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
            transcripts.append(.transcriptAppended(.toolResponse(callID: prop.callID, text: denyText)))
        }
        let nextEffectID = ids.nextEffectID()
        let seq = ids.nextSequence()
        let reservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
        let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed, turnsLeft: state.turnLimit - s1.turnsUsed, deadlineMillis: state.runDeadlineMillis, historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):absolute"))
        let next = s1.replacing(phase: .requesting, turnsUsed: s1.turnsUsed + 1, pendingBatch: .some(nil), liveReservations: s1.liveReservations + [reservation], lastSequence: seq.value)
        return Transition(state: next, effects: uiEffects + [.reserveEffect(reservation), .requestProvider(invocation: invocation)], records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", nextEffectID.raw))] + records + transcripts)
    }
    // Capability grant check (I05): proposals without an effective grant
    // are denied as typed receipts — never executed, never silently dropped.
    let denied = batch.proposals.map(\.tool).filter { !toolAllowed($0, caps: state.epoch.effectiveCaps.tools) }
    if !denied.isEmpty {
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("denied-tools", denied.joined(separator: ",")), ids: &ids)
        let ref = OperationRef(operationID: ids.nextOperationID(), state: .done, mutating: false)
        guard let run = s1.activeRun else {
            return failRun(state, failure: .providerError("tool denial without a run"), hold: true, atMillis: atMillis, ids: &ids)
        }
        guard s1.turnsUsed < s1.turnLimit else {
            return failRun(state, failure: .budgetExhausted("turn budget exhausted after denied tools"), hold: true, atMillis: atMillis, ids: &ids)
        }
        let nextEffectID = ids.nextEffectID()
        let seq = ids.nextSequence()
        let reservation = EffectReservation(
            effectID: nextEffectID, runID: run.runID, requestID: run.requestID,
            generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
        let invocation = ProviderInvocation(
            effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision,
            alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed,
            turnsLeft: state.turnLimit - s1.turnsUsed, deadlineMillis: state.runDeadlineMillis,
            historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):denied"))
        let next = s1.replacing(
            phase: .requesting, activeRequest: .some(nil),
            turnsUsed: s1.turnsUsed + 1, pendingBatch: .some(nil),
            liveReservations: s1.liveReservations + [reservation], lastSequence: seq.value)
        // The denial joins the transcript as tool responses: without it the
        // model re-proposes the same tools forever. Never executed, never
        // silently dropped (I05). Exec denials also carry the NC-9 receipt,
        // keyed to the committed batch-level denial record (a stable,
        // durable opID — never a minted-but-uncommitted one).
        let denial = "tools denied by effective capabilities: \(denied.joined(separator: ", "))"
        var uiExecEffects: [Effect] = []
        let responses = batch.proposals.map { prop -> DurableRecord in
            var text = "denied: \(denial)"
            if prop.tool == "exec" {
                let receipt = execReceiptText(callID: prop.callID, op: ref.operationID, status: "denied", started: false, artifact: nil, truncated: false, summary: denial)
                text += "\n[\(receipt)]"
                uiExecEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
            return .transcriptAppended(.toolResponse(callID: prop.callID, text: text))
        }
        return Transition(
            state: next,
            effects: [
                .reserveEffect(reservation),
                .requestProvider(invocation: invocation),
                .emitUI(.denied(cause: denial)),
            ] + uiExecEffects,
            records: prefix + [.operationResult(ref, outcome: "denied")] + responses)
    }
    if batch.proposals.isEmpty {
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: "empty-batch", ids: &ids)
        return Transition(state: s1.replacing(phase: .requesting, pendingBatch: .some(nil)), effects: [], records: prefix)
    }
    let names = batch.proposals.map(\.tool)
    var needsApproval = batchNeedsApproval(
        toolNames: names, execPolicy: state.epoch.effectiveCaps.tools.exec,
        mode: state.trustMode, sealed: state.activeRun?.sealed ?? false)
    // B1: grantable protected paths always require explicit approval, even for read
    if !grantablePaths.isEmpty {
        needsApproval = true
    }
    if !needsApproval {
        return dispatchTrustedBatch(state, batch: batch, approvedPaths: grantablePaths, ids: &ids)
    }
    guard let run = state.activeRun else {
        return failRun(state, failure: .providerError("authorising without a run"), hold: true, atMillis: atMillis, ids: &ids)
    }
    let hasExec = names.contains("exec")
    if hasExec && state.epoch.execComposed {
        let resolutionID = ids.nextEffectID().raw
        let seed = ExecResolutionSeed(
            resolutionID: resolutionID, runID: run.runID, generation: run.revision,
            batchDigest: fnv1aHex(batch.proposals.map { "\($0.callID):\($0.tool):\($0.arguments ?? "")" }.joined(separator: "\n")),
            grantablePaths: grantablePaths)
        let (s1, prefix) = sequenced(state, kind: "authorising", digest: eventDigest("resolve", resolutionID), ids: &ids)
        let next = s1.replacing(
            phase: .authorising, pendingApproval: .some(nil), pendingBatch: .some(batch),
            pendingResolution: .some(seed))
        return Transition(state: next, effects: [.resolveExecIdentities(resolutionID: resolutionID, batch: batch)], records: prefix)
    }
    var operation = "tool batch: \(names.joined(separator: ", "))"
    if hasExec {
        var demoLines: [String] = []
        for prop in batch.proposals {
            if prop.tool != "exec" {
                demoLines.append("\(prop.tool) \(prop.callID)")
                continue
            }
            if let raw = prop.arguments,
               let data = raw.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
               let args = try? ToolValidator.parseExecArguments(callID: prop.callID, json: json),
               let rendered = renderExecApprovalDisplay(args) {
                demoLines.append(rendered)
            } else {
                demoLines.append("exec \(prop.callID)")
            }
        }
        if !demoLines.isEmpty {
            operation = (demoLines + ["[unresolved (demo)]"]).joined(separator: "; ")
        }
    }
    let request = ApprovalRequest(
        requestID: run.requestID, runID: run.runID, generation: run.revision,
        operation: operation,
        requiredGrant: "explicit approval",
        protectedPaths: grantablePaths.sorted())
    let (s1, prefix) = sequenced(state, kind: "authorising", digest: eventDigest("approval", run.requestID.raw), ids: &ids)
    let next = s1.replacing(phase: .authorising, pendingApproval: .some(request), pendingBatch: .some(batch))
    return Transition(
        state: next,
        effects: [.requestApproval(request)],
        records: prefix)
}

// MARK: - M2-C C0 two-phase resolution (plan REV12 §3.4b)

private func execIdentitiesResolved<I: IDSource>(
    _ state: SessionState, resolutionID: String, identities: [ResolvedExecIdentity], ids: inout I
) -> Transition {
    guard let seed = state.pendingResolution, let batch = state.pendingBatch, let run = state.activeRun else {
        return drop(state)
    }
    _ = seed
    let bound = identities.map {
        ExecCommandIdentity(callID: $0.callID, requestedPath: $0.requestedPath, resolvedPath: $0.resolvedPath, contentDigest: $0.contentDigest, cwdDevice: $0.cwdDevice, cwdInode: $0.cwdInode)
    }
    var lines: [String] = []
    for prop in batch.proposals {
        if prop.tool == "exec" {
            guard let args = try? ToolValidator.execArguments(fromRaw: prop.arguments ?? ""),
                  let rendered = renderExecApprovalDisplay(args) else {
                lines.append("exec \(prop.callID): <unrenderable>")
                continue
            }
            if let id = identities.first(where: { $0.callID == prop.callID }) {
                lines.append("\(rendered) → resolved \(id.resolvedPath) digest=\(id.contentDigest.prefix(16))…")
            } else {
                lines.append(rendered)
            }
        } else {
            let summary = prop.arguments?.prefix(120) ?? ""
            lines.append("\(prop.tool) \(prop.callID): \(summary)")
        }
    }
    let operation = lines.joined(separator: "; ")
    // Every approved command must be fully visible: an over-budget batch
    // is unapprovable (typed pre-dispatch refusal, no hold). Truncating
    // here would hide later execs' argv while they still dispatch.
    guard operation.utf8.count <= ExecArguments.maxDisplayBytes else {
        return execResolutionFailed(
            state, resolutionID: resolutionID, status: "invalid-arguments",
            summary: "batch approval display exceeds \(ExecArguments.maxDisplayBytes) bytes; propose fewer or shorter commands",
            ids: &ids)
    }
    let request = ApprovalRequest(
        requestID: run.requestID, runID: run.runID, generation: run.revision,
        operation: operation, requiredGrant: "explicit approval",
        protectedPaths: seed.grantablePaths.sorted(), execIdentities: bound)
    let (s1, prefix) = sequenced(state, kind: "authorising", digest: eventDigest("resolved", resolutionID), ids: &ids)
    let next = s1.replacing(
        phase: .authorising, pendingApproval: .some(request), pendingBatch: .some(batch),
        pendingResolution: .some(nil), pendingExecIdentities: .some(bound))
    return Transition(state: next, effects: [.requestApproval(request)], records: prefix)
}

private func execResolutionFailed<I: IDSource>(
    _ state: SessionState, resolutionID: String, status: String, summary: String, ids: inout I
) -> Transition {
    guard state.pendingResolution != nil, let batch = state.pendingBatch, let run = state.activeRun else {
        return drop(state)
    }
    guard state.turnsUsed < state.turnLimit else {
        return failRun(state, failure: .budgetExhausted("turn budget exhausted after resolution"), hold: true, atMillis: 0, ids: &ids)
    }
    let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("execResolution", status), ids: &ids)
    var records: [DurableRecord] = []
    var transcripts: [DurableRecord] = []
    var uiEffects: [Effect] = []
    for prop in batch.proposals {
        let isMut = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
        let opID = ids.nextOperationID()
        let intentRef = OperationRef(operationID: opID, callID: prop.callID, state: .intent, mutating: isMut)
        let resultRef = OperationRef(operationID: opID, callID: prop.callID, state: .done, mutating: isMut)
        records.append(.operationIntent(intentRef))
        records.append(.operationResult(resultRef, outcome: "tool-failure: \(summary) (\(status))"))
        // NC-9: resolution-phase exec refusals also carry the receipt.
        var text = "preDispatch \(status): \(summary)"
        if prop.tool == "exec" {
            let receipt = execReceiptText(callID: prop.callID, op: opID, status: status, started: false, artifact: nil, truncated: false, summary: summary)
            text += "\n[\(receipt)]"
            uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
        }
        transcripts.append(.transcriptAppended(.toolResponse(callID: prop.callID, text: text)))
    }
    let nextEffectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let reservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed, turnsLeft: state.turnLimit - (state.turnsUsed + 1), deadlineMillis: state.runDeadlineMillis, historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):execResolution"))
    let next = s1.replacing(
        phase: .requesting, turnsUsed: state.turnsUsed + 1,
        pendingBatch: .some(nil), pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
        liveReservations: s1.liveReservations + [reservation], lastSequence: seq.value)
    return Transition(
        state: next,
        effects: uiEffects + [.reserveEffect(reservation), .requestProvider(invocation: invocation)],
        records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", nextEffectID.raw))] + records + transcripts)
}

/// M2-C C3 (NC-9): one-line operator-visible exec receipt. Carries the
/// call identity, stable operation ID, verdict, start certitude, artifact
/// pointer and truncation flag, plus the executor's summary (exit code,
/// byte counts, discarded-byte counts). Bounded by construction (fixed
/// labels, numbers, digests, short statuses — never child output);
/// terminalSafe is applied by the runUpdate constructor at each call site.
/// Used on EVERY exec path (success, failure, timeout, unknown, refused,
/// cancelled, duplicate, halted) so no exec outcome is silent.
private func execReceiptText(callID: String, op: OperationID, status: String, started: Bool?, artifact: String?, secondary: [String] = [], truncated: Bool, summary: String) -> String {
    let startedStr: String
    switch started {
    case .some(true): startedStr = "started"
    case .some(false): startedStr = "unstarted"
    case .none: startedStr = "uncertain"
    }
    let secondaryStr = secondary.isEmpty ? "-" : secondary.joined(separator: ",")
    return "exec \(callID) \(status) op=\(op.raw) \(startedStr) artifact=\(artifact ?? "-") secondary=\(secondaryStr) truncated=\(truncated) :: \(summary)"
}

/// A3-1 stable operation identity (SPEC §9.1): every externally
/// dispatchable tool operation is identified by its reservation's effect ID
/// plus its own call ID. Derived, never minted — so an intent and its later
/// completion resolve to the SAME ID without shared mutable bookkeeping,
/// and replays derive identical IDs. `"/"` cannot collide with minted IDs
/// (minted IDs never contain it) nor across proposals (callIDs are unique
/// per batch, enforced at admission) nor across effects (effectIDs unique).
func operationID(effectID: EffectID, callID: String) -> OperationID {
    OperationID("\(effectID.raw)/\(callID)")
}

private func dispatchTrustedBatch<I: IDSource>(_ state: SessionState, batch: ToolBatch, approvedPaths: [String] = [], approvedExecDigests: [String: String] = [:], approvedCwdIdentities: [String: String] = [:], ids: inout I) -> Transition {
    guard let run = state.activeRun else {
        let (s1, prefix) = sequenced(state, kind: "failed", digest: "no-run", ids: &ids)
        return Transition(state: s1.replacing(phase: .failed(.providerError("trusted dispatch without a run"))), effects: [], records: prefix)
    }
    // Intent-before-effect (SPEC §9.1): a dispatchable batch without clean
    // per-operation identity fails closed HERE — no intent records, no
    // reservation, no executor call. Admission normally guarantees shape;
    // this is the last gate before external side effects.
    var seenCalls: Set<String> = []
    for proposal in batch.proposals {
        guard !proposal.callID.isEmpty, seenCalls.insert(proposal.callID).inserted else {
            return failRun(state, failure: .providerError("malformed dispatch batch: empty or duplicate call identity"), hold: true, atMillis: 0, ids: &ids)
        }
    }
    let effectID = ids.nextEffectID()
    let mutating = batch.proposals.contains { $0.tool != "read" && $0.tool != "search" && $0.tool != "consult" }
    let reservation = EffectReservation(
        effectID: effectID, runID: run.runID, requestID: run.requestID,
        generation: run.revision, revision: run.revision, mutating: mutating, batch: batch, kind: .executor,
        approvedPaths: approvedPaths, approvedExecDigests: approvedExecDigests, approvedCwdIdentities: approvedCwdIdentities)
    let (s1, prefix) = sequenced(state, kind: "executing", digest: eventDigest("exec", run.requestID.raw), ids: &ids)
    let next = s1.replacing(
        phase: .executing, pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
        liveReservations: state.liveReservations + [reservation])
    // Every dispatchable operation commits its durable intent in the SAME
    // record group as the dispatch: the actor persists this whole group
    // atomically BEFORE performing `.reserveEffect`, so no external side
    // effect exists without its identifiable intent.
    let intents = batch.proposals.map {
        let isMutating = $0.tool != "read" && $0.tool != "search" && $0.tool != "consult"
        return DurableRecord.operationIntent(OperationRef(
            operationID: operationID(effectID: effectID, callID: $0.callID),
            callID: $0.callID, state: .intent, mutating: isMutating))
    }
    return Transition(
        state: next,
        effects: [.reserveEffect(reservation)],
        records: prefix + intents)
}

private func grantApproval<I: IDSource>(_ state: SessionState, requestID: RequestID, ids: inout I) -> Transition {
    _ = requestID
    guard let batch = state.pendingBatch else {
        let (s1, prefix) = sequenced(state, kind: "authorising", digest: "grant-no-batch", ids: &ids)
        return Transition(state: s1, effects: [], records: prefix)
    }
    let approved = state.pendingApproval?.protectedPaths ?? []
    // C0 (plan REV12 §3.4b.9): bind the approved identities into the
    // reservation — the spawn re-verifies digests against THIS map.
    let digests = Dictionary(
        (state.pendingExecIdentities ?? []).map { ($0.callID, $0.contentDigest) },
        uniquingKeysWith: { a, _ in a })
    let cwdIds = Dictionary(
        (state.pendingExecIdentities ?? []).map { ($0.callID, "\($0.cwdDevice):\($0.cwdInode)") },
        uniquingKeysWith: { a, _ in a })
    // M2-D D0: a grant resolves the approval-unavailable hold it answers.
    // Clear ONLY that reason: any other hold (cancel/error/stale) stands.
    // Without this, an unavailable-then-granted approval would end via
    // completed-held instead of auto-dispatching the queued work.
    let unheld: SessionState
    if state.heldReason == .some(.approvalPending) {
        unheld = state.replacing(queueHeld: false, heldReason: .some(nil))
    } else {
        unheld = state
    }
    return dispatchTrustedBatch(unheld, batch: batch, approvedPaths: approved, approvedExecDigests: digests, approvedCwdIdentities: cwdIds, ids: &ids)
}

private func denyApproval<I: IDSource>(_ state: SessionState, ids: inout I) -> Transition {
    let failed = failRun(state, failure: .approvalDenied("operator denied the tool batch"), hold: true, atMillis: 0, ids: &ids)
    return Transition(
        state: failed.state,
        effects: [.emitUI(.denied(cause: "tool batch denied by operator"))] + failed.effects,
        records: failed.records)
}

private func holdForApproval<I: IDSource>(
    _ state: SessionState, requestID: RequestID, reason: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = requestID
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "approval-required", digest: "unavailable", ids: &ids)
    // M2-D D0: a headless approval stop holds the queue — queued entries
    // must not auto-dispatch into a run that can never be approved.
    // Explicit resume releases the hold (the next run re-requests
    // approval through the normal authorising path).
    return Transition(
        state: s1.replacing(queueHeld: true, heldReason: .approvalPending),
        effects: [.emitUI(.runUpdate(phase: "authorising", detail: "approval required: \(terminalSafe(reason))"))],
        records: prefix)
}

// MARK: Effect completion (M1B2-3 continuation)

private func continueAfterEffect<I: IDSource>(
     _ state: SessionState, effectID: EffectID, receipt: String, atMillis: UInt64, ids: inout I
 ) -> Transition {
     _ = atMillis
    // S9: a mismatched mutating completion may have left markers while a
    // run nominally continues — continuation re-checks before dispatching.
    if !state.unresolvedOperations.isEmpty {
        let (s1, prefix) = sequenced(state, kind: "continuation-blocked", digest: "markers", ids: &ids)
        let next = s1.replacing(queueHeld: true, heldReason: .error("unresolved operations block continuation"))
        return Transition(
            state: next,
            effects: [.emitUI(.denied(cause: "continuation blocked: reconcile unknown outcomes first"))],
            records: prefix)
    }
    guard state.turnsUsed < state.turnLimit else {
        return failRun(state, failure: .budgetExhausted("turn budget exhausted after tool batch"), hold: true, atMillis: atMillis, ids: &ids)
    }
    guard let run = state.activeRun else {
        return failRun(state, failure: .providerError("effect completion without a run"), hold: true, atMillis: atMillis, ids: &ids)
    }
    let nextEffectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let reservation = EffectReservation(
        effectID: nextEffectID, runID: run.runID, requestID: run.requestID,
        generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(
        effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed,
        turnsLeft: state.turnLimit - state.turnsUsed, deadlineMillis: state.runDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):continue"))
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var live = state.liveReservations
    live.removeAll(where: { $0.effectID == effectID })
    // A3-1 correlated completion: results carry the SAME derived operation
    // IDs as the dispatch-time intents, per proposal, with the reservation's
    // own mutating flag (a mutating batch's completion is mutating — the
    // old hardcoded `false` broke that correlation). The reservation is
    // guaranteed present here (checkStale only lets matching completions
    // through); the reservation-gone fallback keeps flow identical with a
    // stable effect-level ID rather than a minted one.
    let completedBatch = state.liveReservations.first(where: { $0.effectID == effectID })?.batch
    let completedMutating = state.liveReservations.first(where: { $0.effectID == effectID })?.mutating ?? false
    let results: [DurableRecord]
    let responses: [DurableRecord]
    if let proposals = completedBatch?.proposals, !proposals.isEmpty {
        results = proposals.map {
            DurableRecord.operationResult(OperationRef(
                operationID: operationID(effectID: effectID, callID: $0.callID),
                callID: $0.callID, state: .done, mutating: completedMutating),
                outcome: receipt)
        }
        responses = proposals.map {
            DurableRecord.transcriptAppended(.toolResponse(callID: $0.callID, text: receipt))
        }
    } else {
        results = [.operationResult(
            OperationRef(operationID: OperationID(effectID.raw), callID: effectID.raw, state: .done, mutating: completedMutating),
            outcome: receipt)]
        responses = []
    }
    let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("continue", run.requestID.raw), ids: &ids)
    let next = s1.replacing(
        phase: .requesting, consumedEffects: consumed,
        turnsUsed: state.turnsUsed + 1, liveReservations: live, lastSequence: seq.value)
    return Transition(
        state: next,
        effects: [.reserveEffect(reservation), .requestProvider(invocation: invocation)],
        records: prefix + [
            .eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", effectID.raw)),
        ] + results + responses)
}

private func completeEffect<I: IDSource>(
    _ state: SessionState, effectID: EffectID, outcome: EffectOutcome, ids: inout I
) -> Transition {
    switch outcome {
    case .success(let summary):
        return continueAfterEffect(state, effectID: effectID, receipt: summary, atMillis: 0, ids: &ids)
    case .failureReceipt(let summary):
        return continueAfterEffect(state, effectID: effectID, receipt: "tool-failure: \(summary)", atMillis: 0, ids: &ids)
    case .perCall(let result):
        return continueAfterEffectPerCall(state, effectID: effectID, result: result, ids: &ids)
    case .preDispatchFailure(let failure):
        return continueAfterPreDispatchFailure(state, effectID: effectID, failure: failure, ids: &ids)
    }
}

private func continueAfterPreDispatchFailure<I: IDSource>(_ state: SessionState, effectID: EffectID, failure: ToolFailure, ids: inout I) -> Transition {
    guard let reservation = state.liveReservations.first(where: { $0.effectID == effectID }) else {
        return Transition(state: state, effects: [], records: [])
    }
    let proposals = reservation.batch.proposals
    var records: [DurableRecord] = []
    var transcript: [DurableRecord] = []
    var uiEffects: [Effect] = []
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var live = state.liveReservations.filter { $0.effectID != effectID }
    let status: String
    let summary: String
    switch failure {
    case .preDispatch(let s, let m): status = s; summary = m
    }
    for proposal in proposals {
        let isMutating = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
        let ref = OperationRef(operationID: operationID(effectID: effectID, callID: proposal.callID), callID: proposal.callID, state: .done, mutating: isMutating)
        let outcomeText = "tool-failure: \(summary) (\(status))"
        records.append(.operationResult(ref, outcome: outcomeText))
        // NC-9: pre-dispatch exec refusals also emit the operator-visible
        // receipt (identity + deterministic verdict, never dispatched).
        var text = "preDispatch \(status): \(summary)"
        if proposal.tool == "exec" {
            let receipt = execReceiptText(callID: proposal.callID, op: ref.operationID, status: status, started: false, artifact: nil, truncated: false, summary: summary)
            text += "\n[\(receipt)]"
            uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
        }
        transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: text)))
    }
    var interimState = state.replacing(consumedEffects: consumed, liveReservations: live)
    // Pre-dispatch never holds, but preserve already-generated records if turn-budget or missing-run fails
    guard interimState.turnsUsed < interimState.turnLimit else {
        let failed = failRun(interimState, failure: .budgetExhausted("turn budget exhausted after tool batch"), hold: true, atMillis: 0, ids: &ids)
        return Transition(state: failed.state, effects: uiEffects + failed.effects, records: records + transcript + failed.records)
    }
    guard let run = interimState.activeRun else {
        let failed = failRun(interimState, failure: .providerError("effect completion without a run"), hold: true, atMillis: 0, ids: &ids)
        return Transition(state: failed.state, effects: uiEffects + failed.effects, records: records + transcript + failed.records)
    }
    let nextEffectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let nextReservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: interimState.epoch.profile.alias, epochID: interimState.epoch.epochID, sealed: run.sealed, turnsLeft: interimState.turnLimit - interimState.turnsUsed, deadlineMillis: interimState.runDeadlineMillis, historyDigest: fnv1aHex("\(interimState.sessionID.raw):\(seq.value):continue"))
    let (s1, prefix) = sequenced(interimState, kind: "requesting", digest: eventDigest("continue", run.requestID.raw), ids: &ids)
    let next = s1.replacing(phase: .requesting, consumedEffects: consumed, turnsUsed: interimState.turnsUsed + 1, liveReservations: live, lastSequence: seq.value)
    return Transition(state: next, effects: uiEffects + [.reserveEffect(nextReservation), .requestProvider(invocation: invocation)], records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", effectID.raw))] + records + transcript)
}

private func continueAfterEffectPerCall<I: IDSource>(_ state: SessionState, effectID: EffectID, result: ExecutorResult, ids: inout I) -> Transition {
    guard let reservation = state.liveReservations.first(where: { $0.effectID == effectID }) else {
        return Transition(state: state, effects: [], records: [])
    }
    let proposals = reservation.batch.proposals
    var records: [DurableRecord] = []
    var transcript: [DurableRecord] = []
    // M2-C C3 (NC-9): operator-visible exec receipts, emitted to the
    // terminal/JSONL sink as they complete. Collected here and appended
    // at every return below.
    var uiEffects: [Effect] = []
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var live = state.liveReservations.filter { $0.effectID != effectID }
    var unresolved = state.unresolvedOperations
    // M2-D D2: proven-done per-call outcomes accumulate here for change-
    // group recording below. Only done-classified results land in this map
    // (unknown/held/tainted/mismatched results never do); the builder
    // additionally requires native edit/write success with full mutation-
    // boundary identity, so partial batches contribute only proven members.
    var doneOutcomes: [String: ToolCallOutcome] = [:]

    // F5: duplicate callIDs fail closed before mapping — track tainted IDs
    var seenCallIDs: Set<String> = []
    var taintedCallIDs: Set<String> = []
    for call in result.calls {
        if seenCallIDs.contains(call.callID) {
            taintedCallIDs.insert(call.callID)
        } else {
            seenCallIDs.insert(call.callID)
        }
    }
    // For tainted IDs, emit deterministically in proposal order (not Set iteration)
    for proposal in proposals where taintedCallIDs.contains(proposal.callID) {
        let dupID = proposal.callID
        let isMutating = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
        if isMutating {
            let ref = OperationRef(operationID: operationID(effectID: effectID, callID: dupID), callID: dupID, state: .unknown, mutating: true)
            let (markers, overflow) = appendUnresolved(unresolved, ref)
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
            // Only append one result per tainted ID, even if duplicated multiple times
            if !records.contains(where: { if case .operationResult(let r, _) = $0 { return r.callID == dupID } else { return false } }) {
                records.append(.operationResult(ref, outcome: "unknown: duplicate callID \(dupID)"))
            }
        }
        if !transcript.contains(where: { if case .transcriptAppended(.toolResponse(let id, _)) = $0 { return id == dupID } else { return false } }) {
            var dupText = "duplicate callID: \(dupID)"
            if proposal.tool == "exec" {
                let dupRef = OperationRef(operationID: operationID(effectID: effectID, callID: dupID), callID: dupID, state: .unknown, mutating: true)
                let receipt = execReceiptText(callID: dupID, op: dupRef.operationID, status: "unknown", started: nil, artifact: nil, truncated: false, summary: "duplicate callID")
                dupText += "\n[\(receipt)]"
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
            transcript.append(.transcriptAppended(.toolResponse(callID: dupID, text: dupText)))
        }
    }
    // Build map from callID to outcome (first wins, but tainted IDs will be handled as unknown above and skipped below)
    var outcomeMap: [String: ToolCallOutcome] = [:]
    for call in result.calls where !taintedCallIDs.contains(call.callID) && outcomeMap[call.callID] == nil {
        outcomeMap[call.callID] = call
    }
    // F5: unexpected callIDs (not in reservation) — transcript only, no durable result, and remove from map if any
    for call in result.calls where !proposals.contains(where: { $0.callID == call.callID }) {
        outcomeMap.removeValue(forKey: call.callID)
        // Already handled tainted, but for unexpected, just transcript (already added via tainted? No, unexpected not tainted, so add transcript)
        if !taintedCallIDs.contains(call.callID) {
            transcript.append(.transcriptAppended(.toolResponse(callID: call.callID, text: "unexpected callID: \(call.callID)")))
        }
    }

    // Ordered halt: find first missing/tainted/non-success/contradictory-success in proposal order — conservative boundary
    var firstHaltIndex: Int? = nil
    for (idx, prop) in proposals.enumerated() {
        if taintedCallIDs.contains(prop.callID) {
            firstHaltIndex = idx
            break
        }
        guard let out = outcomeMap[prop.callID] else {
            firstHaltIndex = idx
            break
        }
        if out.status != "success" && out.status != "no-match" {
            firstHaltIndex = idx
            break
        }
        if out.status == "success" && out.started == false {
            // Contradictory success+started==false is a halt boundary, even for non-mutating (transcript-only) — subsequent success must be violation
            firstHaltIndex = idx
            break
        }
    }
    for proposal in proposals {
        // Tainted IDs already carry their unknown marker + result above.
        if taintedCallIDs.contains(proposal.callID) {
            continue
        }
        guard let outcome = outcomeMap[proposal.callID] else {
            // No-entry: contract violation, treat as unknown for mutating, transcript-only for non-mutating
            let isMutating = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
            if isMutating {
                let ref = OperationRef(operationID: operationID(effectID: effectID, callID: proposal.callID), callID: proposal.callID, state: .unknown, mutating: true)
                let (markers, overflow) = appendUnresolved(unresolved, ref)
                unresolved = markers
                if overflow { return integrityStop(state, ids: &ids) }
                records.append(.operationResult(ref, outcome: "unknown"))
                if proposal.tool == "exec" {
                    let receipt = execReceiptText(callID: proposal.callID, op: ref.operationID, status: "unknown", started: nil, artifact: nil, truncated: false, summary: "no executor outcome")
                    transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: "no-entry: \(proposal.callID)\n[\(receipt)]")))
                    uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                    continue
                }
            }
            transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: "no-entry: \(proposal.callID)")))
            continue
        }
        let isMutating = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
        // B4 per-call agreement: a non-nil executor attestation MUST match
        // the dispatch-time intent classification. A mismatch means the
        // executor's report contradicts what was authorized — fail closed
        // (unknown+hold with the conservative mutating claim) in BOTH
        // directions: a denied mutation claim could hide a real side
        // effect, and an invented one could mask a lost update. Nil
        // (legacy/scripted) falls back to the proposal derivation below.
        if let reported = outcome.mutating, reported != isMutating {
            let ref = OperationRef(operationID: operationID(effectID: effectID, callID: proposal.callID), callID: proposal.callID, state: .unknown, mutating: true)
            let (markers, overflow) = appendUnresolved(unresolved, ref)
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
            records.append(.operationResult(ref, outcome: "unknown: mutating mismatch (intent \(isMutating) vs result \(reported)) for \(proposal.callID)"))
            var mismatchText = outcome.data
            if proposal.tool == "exec" {
                let receipt = execReceiptText(callID: proposal.callID, op: ref.operationID, status: "unknown", started: outcome.started, artifact: outcome.artifactID, secondary: outcome.secondaryArtifactIDs, truncated: outcome.truncated, summary: "mutating mismatch intent=\(isMutating) result=\(reported)")
                mismatchText += "\n[\(receipt)]"
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
            transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: mismatchText)))
            continue
        }
        let status = outcome.status
        let started = outcome.started
        // Check if this proposal was tainted as duplicate — already handled as unknown
        if taintedCallIDs.contains(proposal.callID) {
            continue
        }
        // Ordered halt defensive: after first non-success, later calls must be cancelled unstarted
        if let firstHalt = firstHaltIndex, let currentIndex = proposals.firstIndex(where: { $0.callID == proposal.callID }), currentIndex > firstHalt {
            if !(status == "cancelled" && started == false) {
                if isMutating {
                    let ref = OperationRef(operationID: operationID(effectID: effectID, callID: proposal.callID), callID: proposal.callID, state: .unknown, mutating: true)
                    let (markers, overflow) = appendUnresolved(unresolved, ref)
                    unresolved = markers
                    if overflow { return integrityStop(state, ids: &ids) }
                    records.append(.operationResult(ref, outcome: "unknown: halt violation \(proposal.callID)"))
                    var haltText = "halt violation: \(proposal.callID)"
                    if proposal.tool == "exec" {
                        let receipt = execReceiptText(callID: proposal.callID, op: ref.operationID, status: "unknown", started: started, artifact: outcome.artifactID, secondary: outcome.secondaryArtifactIDs, truncated: outcome.truncated, summary: "halt violation after \(String(describing: firstHalt))")
                        haltText += "\n[\(receipt)]"
                        uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                    }
                    transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: haltText)))
                } else {
                    transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: "halt violation: \(proposal.callID)")))
                }
                continue
            }
        }
        let deterministic: Set<String> = ["success", "no-match", "denied", "conflict", "invalid-arguments", "failed"]
        var stateForResult: OperationState = .done
        var hold = false
        var outcomeText = outcome.summary
        if deterministic.contains(status) {
            if started == false {
                // RED/GREEN: deterministic + started==false is contradictory → unknown for mutating, transcript-only for non-mutating.
                // Only the typed preDispatchFailure path may certify no dispatch; arbitrary ToolCallOutcome data never does.
                if isMutating {
                    stateForResult = .unknown
                    hold = true
                    outcomeText = "contradictory \(status) with started==false"
                } else {
                    transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: outcome.data)))
                    continue
                }
            } else {
                stateForResult = .done
                if status != "success" && status != "no-match" {
                    outcomeText = "tool-failure: \(outcome.summary)"
                }
            }
        } else if status == "cancelled" || status == "timeout" {
            if started == false {
                stateForResult = .done
                outcomeText = "cancelled: unstarted"
            } else {
                // started true or nil → unknown for mutating, transcript-only for non-mutating
                if isMutating {
                    stateForResult = .unknown
                    hold = true
                    outcomeText = "\(status) after started"
                } else {
                    transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: outcome.data)))
                    continue
                }
            }
        } else {
            // Unknown status: treat as unknown for mutating
            if isMutating {
                stateForResult = .unknown
                hold = true
            } else {
                transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: outcome.data)))
                continue
            }
        }

        let ref = OperationRef(operationID: operationID(effectID: effectID, callID: proposal.callID), callID: proposal.callID, state: stateForResult, mutating: isMutating)
        if hold {
            let (markers, overflow) = appendUnresolved(unresolved, ref)
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
            records.append(.operationResult(ref, outcome: "unknown: \(outcomeText)"))
        } else {
            records.append(.operationResult(ref, outcome: outcomeText))
            doneOutcomes[proposal.callID] = outcome
        }
        // M2-C C3 (NC-9): exec calls carry an operator-visible receipt into
        // the provider continuation AND the terminal/JSONL sink. The receipt
        // reports the REDUCER's verdict (unknown+hold reason when held),
        // not just the executor's raw status — never a fabricated success.
        let receiptStatus = hold ? "unknown" : outcome.status
        let receiptSummary = hold ? outcomeText : outcome.summary
        let toolText: String
        if proposal.tool == "exec" {
            let receipt = execReceiptText(callID: proposal.callID, op: ref.operationID, status: receiptStatus, started: outcome.started, artifact: outcome.artifactID, secondary: outcome.secondaryArtifactIDs, truncated: outcome.truncated, summary: receiptSummary)
            toolText = outcome.data.isEmpty ? "[\(receipt)]" : "\(outcome.data)\n[\(receipt)]"
            uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
        } else {
            toolText = outcome.data
        }
        transcript.append(.transcriptAppended(.toolResponse(callID: proposal.callID, text: toolText)))
        // Artifact handling: if outcome has artifactID, publish reference already done by executor; here we just record
    }

    // Handle empty batch fallback
    if proposals.isEmpty {
        let ref = OperationRef(operationID: OperationID(effectID.raw), callID: effectID.raw, state: .done, mutating: reservation.mutating)
        let newRecords: [DurableRecord] = [.operationResult(ref, outcome: result.receipt.summary)] + transcript
        var fallbackState = state.replacing(consumedEffects: consumed, liveReservations: live, unresolvedOperations: unresolved)
        // Continue or hold as per normal continuation
        if !fallbackState.unresolvedOperations.isEmpty {
            let (s1, prefix) = sequenced(fallbackState, kind: "continuation-blocked", digest: "markers", ids: &ids)
            let next = s1.replacing(queueHeld: true, heldReason: .error("unresolved operations block continuation"))
            return Transition(state: next, effects: uiEffects + [.emitUI(.denied(cause: "continuation blocked: reconcile unknown outcomes first"))], records: prefix + newRecords)
        }
        guard fallbackState.turnsUsed < fallbackState.turnLimit else {
            return failRun(fallbackState, failure: .budgetExhausted("turn budget exhausted after tool batch"), hold: true, atMillis: 0, ids: &ids)
        }
        guard let run = fallbackState.activeRun else {
            return failRun(fallbackState, failure: .providerError("effect completion without a run"), hold: true, atMillis: 0, ids: &ids)
        }
        let nextEffectID = ids.nextEffectID()
        let seq = ids.nextSequence()
        let nextReservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
        let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: fallbackState.epoch.profile.alias, epochID: fallbackState.epoch.epochID, sealed: run.sealed, turnsLeft: fallbackState.turnLimit - fallbackState.turnsUsed, deadlineMillis: fallbackState.runDeadlineMillis, historyDigest: fnv1aHex("\(fallbackState.sessionID.raw):\(seq.value):continue"))
        var nextLive = fallbackState.liveReservations
        nextLive.removeAll(where: { $0.effectID == effectID })
        let (s1, prefix) = sequenced(fallbackState, kind: "requesting", digest: eventDigest("continue", run.requestID.raw), ids: &ids)
        let next = s1.replacing(phase: .requesting, consumedEffects: consumed, turnsUsed: fallbackState.turnsUsed + 1, liveReservations: nextLive, lastSequence: seq.value)
        return Transition(state: next, effects: uiEffects + [.reserveEffect(nextReservation), .requestProvider(invocation: invocation)], records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", effectID.raw))] + newRecords)
    }

    // F1: continuation policy — if unresolved (unknown) exists, hold; else continue to next turn
    var interimState = state.replacing(consumedEffects: consumed, liveReservations: live, unresolvedOperations: unresolved)
    // M2-D D2: one change group per dispatched mutating batch, committed
    // atomically with the batch's operation results. Only proven-done
    // native mutations become members; unmatched, unknown, tainted or
    // identity-less results are excluded (held by the classifier above).
    // No qualifying member ⇒ no group record (never an empty group).
    let allRecords: [DurableRecord]
    let groupSeq = ids.nextSequence()
    if let runID = interimState.activeRun?.runID,
       let group = buildChangeGroup(
           groupID: "chg-\(groupSeq.value)", runID: runID, effectID: effectID,
           proposals: proposals, outcomes: doneOutcomes,
           doneCallIDs: Set(doneOutcomes.keys)) {
        allRecords = records + transcript + [.changeGroup(group)]
    } else {
        // The sequence still advances (deterministic replay carries the
        // counter): a deterministic no-group run consumes one ID.
        allRecords = records + transcript
    }
    if !unresolved.isEmpty {
        let (s1, prefix) = sequenced(interimState, kind: "continuation-blocked", digest: "markers", ids: &ids)
        let next = s1.replacing(queueHeld: true, heldReason: .error("unresolved operations block continuation"))
        return Transition(state: next, effects: uiEffects + [.emitUI(.denied(cause: "continuation blocked: reconcile unknown outcomes first"))], records: prefix + allRecords)
    }
    guard interimState.turnsUsed < interimState.turnLimit else {
        let failed = failRun(interimState, failure: .budgetExhausted("turn budget exhausted after tool batch"), hold: true, atMillis: 0, ids: &ids)
        return Transition(state: failed.state, effects: uiEffects + failed.effects, records: allRecords + failed.records)
    }
    guard let run = interimState.activeRun else {
        let failed = failRun(interimState, failure: .providerError("effect completion without a run"), hold: true, atMillis: 0, ids: &ids)
        return Transition(state: failed.state, effects: uiEffects + failed.effects, records: allRecords + failed.records)
    }
    let nextEffectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let nextReservation = EffectReservation(effectID: nextEffectID, runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision, alias: interimState.epoch.profile.alias, epochID: interimState.epoch.epochID, sealed: run.sealed, turnsLeft: interimState.turnLimit - interimState.turnsUsed, deadlineMillis: interimState.runDeadlineMillis, historyDigest: fnv1aHex("\(interimState.sessionID.raw):\(seq.value):continue"))
    let (s1, prefix) = sequenced(interimState, kind: "requesting", digest: eventDigest("continue", run.requestID.raw), ids: &ids)
    let next = s1.replacing(phase: .requesting, consumedEffects: consumed, turnsUsed: interimState.turnsUsed + 1, liveReservations: live, lastSequence: seq.value)
    return Transition(state: next, effects: uiEffects + [.reserveEffect(nextReservation), .requestProvider(invocation: invocation)], records: prefix + [.eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", effectID.raw))] + allRecords)
}

private func completeCancelledPending<I: IDSource>(_ state: SessionState, effectID: EffectID, outcome: EffectOutcome, ids: inout I) -> Transition {
    guard let reservation = state.cancelledPendingReservations.first(where: { $0.effectID == effectID }) else {
        return Transition(state: state, effects: [], records: [])
    }
    var pending = state.cancelledPendingReservations.filter { $0.effectID != effectID }
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var unresolved = state.unresolvedOperations
    var records: [DurableRecord] = []
    var uiEffects: [Effect] = []

    switch outcome {
    case .preDispatchFailure:
        // Typed proof that no dispatch occurred: discharge every mutating marker as done
        for prop in reservation.batch.proposals {
            let isMutating = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            if !isMutating { continue }
            let ref = OperationRef(operationID: operationID(effectID: effectID, callID: prop.callID), callID: prop.callID, state: .done, mutating: true)
            records.append(.operationResult(ref, outcome: "cancelled: unstarted"))
            unresolved.removeAll(where: { $0.operationID == ref.operationID })
            if prop.tool == "exec" {
                let receipt = execReceiptText(callID: prop.callID, op: ref.operationID, status: "cancelled", started: false, artifact: nil, truncated: false, summary: "unstarted")
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
        }
        break
    case .success, .failureReceipt:
        break
    case .perCall(let result):
        // F5: duplicate and unexpected handling for cancelled-pending path — tainted IDs never supersede
        var seen: Set<String> = []
        var tainted: Set<String> = []
        for call in result.calls {
            if seen.contains(call.callID) { tainted.insert(call.callID) } else { seen.insert(call.callID) }
        }
        for call in result.calls {
            if tainted.contains(call.callID) {
                // Tainted in a cancelled batch: unknown + hold, with a receipt.
                if let prop = reservation.batch.proposals.first(where: { $0.callID == call.callID }), prop.tool == "exec" {
                    let tref = OperationRef(operationID: operationID(effectID: effectID, callID: call.callID), callID: call.callID, state: .unknown, mutating: true)
                    let receipt = execReceiptText(callID: call.callID, op: tref.operationID, status: "unknown", started: nil, artifact: nil, truncated: false, summary: "duplicate callID in cancelled batch")
                    uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                }
                continue
            }
            let proposal = reservation.batch.proposals.first(where: { $0.callID == call.callID })
            guard let prop = proposal else {
                // Unexpected callID: ignore, no result for non-reserved operation (authoritative discharge only described)
                continue
            }
            let mutating = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            if !mutating { continue } // non-mutating never gets a record on cancel path
            if (call.status == "cancelled" || call.status == "timeout") && call.started == false {
                // Unstarted: supersede pending marker with done (both cancelled and timeout unstarted are valid proofs)
                let ref = OperationRef(operationID: operationID(effectID: effectID, callID: call.callID), callID: call.callID, state: .done, mutating: true)
                records.append(.operationResult(ref, outcome: "cancelled: unstarted"))
                // Remove the pending marker from unresolved if present (supersession)
                unresolved.removeAll(where: { $0.operationID == ref.operationID })
                if prop.tool == "exec" {
                    let receipt = execReceiptText(callID: call.callID, op: ref.operationID, status: call.status, started: false, artifact: call.artifactID, secondary: call.secondaryArtifactIDs, truncated: call.truncated, summary: "unstarted")
                    uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                }
            } else {
                // Started or unknown: keep marker, no new record (hold remains).
                // The operator still sees what is held and why. The receipt
                // reports the REDUCER verdict (unknown), never the raw
                // executor outcome: a late "success" arriving after cancel
                // won the race is uncertain by construction (M2).
                if prop.tool == "exec" {
                    let holdRef = OperationRef(operationID: operationID(effectID: effectID, callID: call.callID), callID: call.callID, state: .unknown, mutating: true)
                    let receipt = execReceiptText(callID: call.callID, op: holdRef.operationID, status: "unknown", started: call.started, artifact: call.artifactID, secondary: call.secondaryArtifactIDs, truncated: call.truncated, summary: "uncertain completion withheld")
                    uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                }
                continue
            }
        }
    }

    let next = state.replacing(consumedEffects: consumed, cancelledPendingReservations: pending, unresolvedOperations: unresolved)
    return Transition(state: next, effects: uiEffects, records: records)
}

private func completeCancelledPendingFailed<I: IDSource>(_ state: SessionState, effectID: EffectID, error: String, atMillis: UInt64, ids: inout I) -> Transition {
    guard let reservation = state.cancelledPendingReservations.first(where: { $0.effectID == effectID }) else {
        return Transition(state: state, effects: [], records: [])
    }
    var pending = state.cancelledPendingReservations.filter { $0.effectID != effectID }
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    let errRecord = CancelledPendingError(effectID: effectID, operationIDs: reservation.batch.proposals.map { operationID(effectID: effectID, callID: $0.callID) }, error: error, atMillis: atMillis)
    let next = state.replacing(consumedEffects: consumed, cancelledPendingReservations: pending)
    // NC-9: the failure itself is uncertain (completion unknown), so the
    // receipt never certifies non-dispatch — started is unknown, not false.
    let uiEffects: [Effect] = reservation.batch.proposals.compactMap { prop in
        guard prop.tool == "exec" else { return nil }
        let receipt = execReceiptText(callID: prop.callID, op: operationID(effectID: effectID, callID: prop.callID), status: "unknown", started: nil, artifact: nil, truncated: false, summary: "cancelled-pending failed: \(error)")
        return .emitUI(.runUpdate(phase: "tool-exec", detail: receipt))
    }
    return Transition(state: next, effects: uiEffects, records: [.cancelledPendingError(errRecord)])
}

private func handleCancelledPendingRemoved<I: IDSource>(_ state: SessionState, effectID: EffectID, atMillis: UInt64, ids: inout I) -> Transition {
    var pending = state.cancelledPendingReservations.filter { $0.effectID != effectID }
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var unresolved = state.unresolvedOperations
    var records: [DurableRecord] = []
    var uiEffects: [Effect] = []
    // Promote pending markers to unknown for still-pending operationIDs — always, even if marker already in unresolved (supersession)
    if let reservation = state.cancelledPendingReservations.first(where: { $0.effectID == effectID }) {
        for prop in reservation.batch.proposals {
            let isMutating = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            if !isMutating { continue }
            let ref = OperationRef(operationID: operationID(effectID: effectID, callID: prop.callID), callID: prop.callID, state: .unknown, mutating: true)
            // Remove the pending marker from unresolved if present, then add the unknown (supersession)
            unresolved.removeAll(where: { $0.operationID == ref.operationID })
            let (markers, overflow) = appendUnresolved(unresolved, ref)
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
            records.append(.operationResult(ref, outcome: "unknown: cancelled pending terminated"))
            if prop.tool == "exec" {
                let receipt = execReceiptText(callID: prop.callID, op: ref.operationID, status: "unknown", started: nil, artifact: nil, truncated: false, summary: "cancelled pending terminated")
                uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
            }
        }
    }
    let next = state.replacing(consumedEffects: consumed, cancelledPendingReservations: pending, unresolvedOperations: unresolved)
    return Transition(state: next, effects: uiEffects, records: records)
}

private func failEffect<I: IDSource>(_ state: SessionState, effectID: EffectID, error: String, ids: inout I) -> Transition {
    // The carried error text reaches the transcript (tool-failure receipt)
    // so the model sees WHAT failed — a fixed string would blind the loop.
    continueAfterEffect(state, effectID: effectID, receipt: "tool-failure: \(terminalSafe(error))", atMillis: 0, ids: &ids)
}

// MARK: Cancellation (C3: retention BEFORE invalidation)

private func cancelActive<I: IDSource>(_ state: SessionState, atMillis: UInt64, ids: inout I) -> Transition {
    // REV25 C3: per-proposal mutating, Kind-filtered, cancelledPendingReservations with supersession.
    var unresolved = state.unresolvedOperations
    var records: [DurableRecord] = []
    var pending: [EffectReservation] = state.cancelledPendingReservations
    var live: [EffectReservation] = []
    var consumed = state.consumedEffects
    // NC-9: exec cancellations surface immediately (the completion may
    // never arrive to report them).
    var uiEffects: [Effect] = []

    for reservation in state.liveReservations {
        // Provider reservations: not retained, just consumed.
        if reservation.kind == .provider {
            consumed.insert(reservation.effectID)
            continue
        }
        // Executor reservations: per-proposal mutating classification.
        let proposals = reservation.batch.proposals
        if proposals.isEmpty {
            // Empty fallback uses reservation-level mutating.
            if reservation.mutating {
                let ref = OperationRef(operationID: OperationID(reservation.effectID.raw), callID: reservation.effectID.raw, state: .unknown, mutating: true)
                let (markers, overflow) = appendUnresolved(unresolved, ref)
                unresolved = markers
                if overflow { return integrityStop(state, ids: &ids) }
                records.append(.cancelledPendingMarker(ref, outcome: "cancelled: pending executor \(reservation.effectID.raw)"))
                pending.append(reservation)
            } else {
                consumed.insert(reservation.effectID)
            }
            continue
        }
        var mutatingRefs: [OperationRef] = []
        for prop in proposals {
            let isMutating = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
            if isMutating {
                let ref = OperationRef(operationID: operationID(effectID: reservation.effectID, callID: prop.callID), callID: prop.callID, state: .unknown, mutating: true)
                mutatingRefs.append(ref)
                if prop.tool == "exec" {
                    let receipt = execReceiptText(callID: prop.callID, op: ref.operationID, status: "unknown", started: nil, artifact: nil, truncated: false, summary: "cancel requested; outcome withheld")
                    uiEffects.append(.emitUI(.runUpdate(phase: "tool-exec", detail: receipt)))
                }
            }
        }
        if mutatingRefs.isEmpty {
            // Pure read-only batch: not retained, consumed.
            consumed.insert(reservation.effectID)
            continue
        }
        // Retain reservation for mutating proposals only.
        for ref in mutatingRefs {
            let (markers, overflow) = appendUnresolved(unresolved, ref)
            unresolved = markers
            if overflow { return integrityStop(state, ids: &ids) }
            records.append(.cancelledPendingMarker(ref, outcome: "cancelled: pending \(ref.callID ?? "")"))
        }
        pending.append(reservation)
        // Non-mutating proposals in mixed batch are ignored (no record, but effectID is pending so late report routes to completeCancelledPending which will ignore them).
    }

    // Idempotent: if no new pending and no live executor left, no duplicate markers (already handled by filtering).
    let (s1, prefix) = sequenced(state, kind: "cancelling", digest: "cancel", ids: &ids)
    // M2-D D0 durable hold: queued entries become held IN the ledger
    // (queueUpdated per changed entry), so a reopen reconstructs the
    // held queue instead of silently resuming dispatch. History and
    // terminal entries are untouched; heldUnknown entries stay held.
    var queue = state.queue
    for i in queue.indices where queue[i].state == .queued {
        // M2-D D1: the hold-marking preserves snapshots + consent (a
        // cancel must never strip the evidence the dispatch gate needs).
        queue[i] = QueueEntry(
            entryID: queue[i].entryID, commandID: queue[i].commandID, kind: queue[i].kind,
            state: .held, revision: queue[i].revision, text: queue[i].text,
            targetEpochID: queue[i].targetEpochID, orderKey: queue[i].orderKey, sealed: queue[i].sealed,
            attachments: queue[i].attachments, attachmentConsentEpoch: queue[i].attachmentConsentEpoch)
        records.append(.queueUpdated(queue[i]))
    }
    var active: ActiveRequest? = nil
    if let request = state.activeRequest {
        active = ActiveRequest(requestID: request.requestID, runID: request.runID, generation: request.generation, delivery: .deliveryUnknown, bytesOut: request.bytesOut)
    }
    let nextPhase: SessionPhase = .cancelling
    let next = s1.replacing(
        phase: nextPhase, activeRequest: active,
        queue: queue,
        queueHeld: true, heldReason: .cancelled(sinceMillis: atMillis),
        consumedEffects: consumed,
        pendingApproval: .some(nil), pendingBatch: .some(nil),
        pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
        retryDeadlineMillis: .some(nil), liveReservations: live,
        cancelledPendingReservations: pending,
        generation: state.generation + 1,
        unresolvedOperations: unresolved)
    var effects: [Effect] = uiEffects + [.emitUI(.runUpdate(phase: "cancelling", detail: "cancelled; queue held"))]
    if let run = state.activeRun {
        effects.append(.cancelInFlight(runID: run.runID, reason: "operator cancel"))
        effects.append(.cancelTimer(purpose: "cancel-grace", runID: run.runID))
        effects.append(.startTimer(deadlineMillis: atMillis + cancelGraceMillis, purpose: "cancel-grace", runID: run.runID))
    }
    return Transition(state: next, effects: effects, records: prefix + records)
}

private func tickCancelling<I: IDSource>(_ state: SessionState, nowMillis: UInt64, ids: inout I) -> Transition {
    guard case .cancelled(let since) = state.heldReason, nowMillis >= since + cancelGraceMillis else {
        return Transition(state: state, effects: [], records: [])
    }
    return interruptRun(state, note: "cancel grace elapsed; transport unconfirmed", atMillis: nowMillis, ids: &ids)
}

// MARK: Terminal + deadlines + refusals

private func dismissTerminal<I: IDSource>(_ state: SessionState, atMillis: UInt64, ids: inout I) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "idle", digest: "dismissed", ids: &ids)
    return Transition(state: s1.replacing(phase: .idle), effects: [], records: prefix)
}

private func refuseTerminalMeta<I: IDSource>(_ state: SessionState, what: String, ids: inout I) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "refused", digest: eventDigest("refused", what), ids: &ids)
    return Transition(
        state: s1,
        effects: [.emitUI(.denied(cause: "\(what) needs the run dismissed first"))],
        records: prefix)
}

private func refuseBusyMeta<I: IDSource>(
    _ state: SessionState, what: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "refused", digest: eventDigest("refused", what), ids: &ids)
    return Transition(
        state: s1,
        effects: [.emitUI(.denied(cause: "\(what) refused while busy"))],
        records: prefix)
}

/// Tick dispatch for armed retries (M1C3-2/M1C4-1): the ONLY consumer of
/// `retryDeadlineMillis`. Fires iff a deadline is armed, the phase is
/// requesting, and the deadline has passed; every other combination is an
/// explicit no-op (stale ticks can never dispatch, double-fire, or leak).
private func consumeRetryDeadline<I: IDSource>(_ state: SessionState, nowMillis: UInt64, ids: inout I) -> Transition? {
    guard let deadline = state.retryDeadlineMillis,
          state.phase == .requesting,
          nowMillis >= deadline,
          let run = state.activeRun
    else {
        return nil
    }
    guard state.turnsUsed < state.turnLimit else {
        return failRun(state, failure: .budgetExhausted("turn budget exhausted at retry dispatch"), hold: true, atMillis: nowMillis, ids: &ids)
    }
    let effectID = ids.nextEffectID()
    let seq = ids.nextSequence()
    let reservation = EffectReservation(
        effectID: effectID, runID: run.runID, requestID: run.requestID,
        generation: run.revision, revision: run.revision, mutating: false, kind: .provider)
    let invocation = ProviderInvocation(
        effectID: effectID, requestID: run.requestID, runID: run.runID, generation: run.revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed,
        turnsLeft: state.turnLimit - state.turnsUsed, deadlineMillis: state.runDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):retry-tick"))
    let (s1, prefix) = sequenced(state, kind: "retrying", digest: eventDigest("retry-tick", run.requestID.raw), ids: &ids)
    let next = s1.replacing(
        turnsUsed: state.turnsUsed + 1,
        retryDeadlineMillis: .some(nil),
        liveReservations: state.liveReservations + [reservation], lastSequence: seq.value)
    return Transition(
        state: next,
        effects: [.reserveEffect(reservation), .requestProvider(invocation: invocation)],
        records: prefix + [
            .eventAppended(seq: seq, kind: "retrying", digest: eventDigest("retry-tick", run.requestID.raw)),
            .operationIntent(OperationRef(operationID: ids.nextOperationID(), state: .intent, mutating: false)),
        ])
}

private func checkDeadline<I: IDSource>(_ state: SessionState, nowMillis: UInt64, ids: inout I) -> Transition {
    if let retry = consumeRetryDeadline(state, nowMillis: nowMillis, ids: &ids) {
        return retry
    }
    guard state.phase.hasActiveRun || state.phase == .admitting,
          let deadline = state.runDeadlineMillis,
          nowMillis >= deadline
    else {
        return Transition(state: state, effects: [], records: [])
    }
    return failRun(state, failure: .budgetExhausted("run wall-clock deadline exceeded"), hold: true, atMillis: nowMillis, ids: &ids)
}
