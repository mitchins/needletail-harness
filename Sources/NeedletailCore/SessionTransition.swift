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
    public let effectID: EffectID
    public let runID: RunID
    public let requestID: RequestID?
    public let generation: Revision
    public let revision: Revision
    public let mutating: Bool
    public let batch: ToolBatch

    public init(effectID: EffectID, runID: RunID, requestID: RequestID? = nil, generation: Revision, revision: Revision, mutating: Bool, batch: ToolBatch = ToolBatch()) {
        self.effectID = effectID
        self.runID = runID
        self.requestID = requestID
        self.generation = generation
        self.revision = revision
        self.mutating = mutating
        self.batch = batch
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

public struct ExecutorResult: Sendable, Equatable {
    public let receipt: ExecutorReceipt
    public init(receipt: ExecutorReceipt) { self.receipt = receipt }
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
        queueHeld: true, heldReason: .error("integrity stop"))
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
    switch (state.phase, event) {
    case (.idle, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitFreshRun(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.idle, .queueEdit(let entryID, let newText, let baseRevision, let at)):
        return editEntry(state, entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: at, ids: &ids)
    case (.idle, .queueWithdraw(let entryID, let at)):
        return withdrawEntry(state, entryID: entryID, atMillis: at, ids: &ids)
    case (.idle, .queueResume(let at)):
        return resumeQueue(state, atMillis: at, ids: &ids)
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
    case (.requesting, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.streaming, .providerResponse(_, _, let response, let at)):
        return handleProviderResponse(state, response: response, atMillis: at, ids: &ids)
    case (.streaming, .transportFailed(_, _, let phase, let error, let at)):
        return failTransport(state, phase: phase, error: error, atMillis: at, ids: &ids)
    case (.streaming, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.streaming, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.validatingTools, .validationCompleted(_, _, let batch, let at)):
        return enterAuthorising(state, batch: batch, atMillis: at, ids: &ids)
    case (.validatingTools, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.validatingTools, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.authorising, .approvalGrant(let requestID, _, _)):
        return grantApproval(state, requestID: requestID, ids: &ids)
    case (.authorising, .approvalDeny(_, _, _, _)):
        return denyApproval(state, ids: &ids)
    case (.authorising, .approvalUnavailable(let requestID, _, let reason, let at)):
        return holdForApproval(state, requestID: requestID, reason: reason, atMillis: at, ids: &ids)
    case (.authorising, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.authorising, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.executing, .effectCompleted(let effectID, _, _, _, _, let outcome, _)):
        return completeEffect(state, effectID: effectID, outcome: outcome, ids: &ids)
    case (.executing, .effectFailed(let effectID, _, _, _, _, let error, _)):
        return failEffect(state, effectID: effectID, error: error, ids: &ids)
    case (.executing, .operatorInput(let commandID, let text, let kind, _, let sealed, let at)):
        return admitToQueueState(state, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: at, ids: &ids)
    case (.executing, .cancelRequested(let at)):
        return cancelActive(state, atMillis: at, ids: &ids)
    case (.cancelling, .tick(let now)):
        return tickCancelling(state, nowMillis: now, ids: &ids)
    case (.cancelling, .transportFailed(_, _, _, _, let at)):
        return interruptRun(state, note: "transport confirmed cancel", atMillis: at, ids: &ids)
    case (.cancelling, .cancelRequested):
        return Transition(state: state, effects: [], records: [])
    case (.failed, .dismissRun(let at)), (.completed, .dismissRun(let at)), (.interrupted, .dismissRun(let at)):
        return dismissTerminal(state, atMillis: at, ids: &ids)
    case (.failed, .queueResume(let at)), (.completed, .queueResume(let at)), (.interrupted, .queueResume(let at)):
        return resumeQueue(state, atMillis: at, ids: &ids)
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
    case .effectCompleted(let effectID, let runID, let generation, let revision, _, _, _),
         .effectFailed(let effectID, let runID, let generation, let revision, _, _, _):
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
    case .requestDispatched(let requestID, _):
        guard state.phase == .admitting,
              let run = state.activeRun, run.requestID == requestID
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
/// is now unknowable keeps an `unknown` marker + record, appended BEFORE
/// dropping. Already-consumed duplicates never reach here (bare counter).
private func dropRetaining<I: IDSource>(_ state: SessionState, effectID: EffectID, ids: inout I) -> Transition {
    let ref = OperationRef(
        operationID: ids.nextOperationID(), callID: effectID.raw,
        state: .unknown, mutating: true)
    let (markers, overflow) = appendUnresolved(state.unresolvedOperations, ref)
    if overflow {
        return integrityStop(state, ids: &ids)
    }
    var live = state.liveReservations
    live.removeAll(where: { $0.effectID == effectID })
    let record = DurableRecord.operationResult(ref, outcome: "unknown")
    return Transition(
        state: bumped(state, unresolved: markers, live: live),
        effects: [], records: [record])
}

// MARK: - Row handlers

/// Mints a sequence + eventAppended prefix for operator-originated rows.
/// Timer/no-op system rows append nothing (history floods otherwise).
private func sequenced<I: IDSource>(_ state: SessionState, kind: String, digest: String, ids: inout I) -> (SessionState, [DurableRecord]) {
    let seq = ids.nextSequence()
    let next = state.replacing(lastSequence: seq.value)
    return (next, [.eventAppended(seq: seq, kind: kind, digest: digest)])
}

private func eventDigest(_ parts: String...) -> String {
    fnv1aHex(parts.joined(separator: "\n"))
}

// MARK: Fresh admission (idle × operatorInput, incl. terminal implicit-ack)

private func admitFreshRun<I: IDSource>(
    _ state: SessionState, commandID: CommandID, text: String, kind: QueueKind,
    sealed: Bool, atMillis: UInt64, ids: inout I
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
    // Blocked automatic continuation: unresolved markers refuse new runs
    // but still admit the text as a HELD queue entry (explicit
    // reconciliation first — POLICY-07 shape, M2 reconciles). Queuing is
    // not mutation; dispatch stays blocked.
    if !state.unresolvedOperations.isEmpty {
        let preHeld = state.replacing(
            queueHeld: true, heldReason: .error("unresolved operations block new runs"))
        let queued = admitToQueueState(preHeld, commandID: commandID, text: text, kind: kind, sealed: sealed, atMillis: atMillis, ids: &ids)
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
    let undispatchedBytes = state.queue
        .filter { $0.state == .queued || $0.state == .held }
        .reduce(0) { $0 + $1.text.utf8.count }
    guard undispatchedBytes + text.utf8.count <= maxQueueTextBytes else {
        return refuseCaps(state, commandID: commandID, cause: "queue text budget exceeded", atMillis: atMillis, ids: &ids)
    }
    guard state.admittedCommands.count < maxAdmittedCommands else {
        return refuseCaps(state, commandID: commandID, cause: "admission index full (oldest pruned at epoch change)", atMillis: atMillis, ids: &ids)
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
        generation: revision, revision: revision, mutating: false)
    let invocation = ProviderInvocation(
        effectID: effectID, requestID: requestID, runID: runID, generation: revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: sealed,
        turnsLeft: state.turnLimit, deadlineMillis: atMillis + defaultRunDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value)"))
    let ack = QueueAck(commandID: commandID, entryID: "run-\(requestID.raw)", sequence: seq, revision: revision.value, state: .dispatched)
    var index = state.admittedCommands
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
            // The dispatched operator text opens the transcript (D1).
            .transcriptAppended(.user(text)),
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
    sealed: Bool, atMillis: UInt64, ids: inout I
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
    if let prior = state.admittedCommands[commandID] {
        return Transition(state: state, effects: [.emitUI(.admitted(commandID: commandID, revision: prior.revision))], records: [])
    }
    let liveCount = state.queue.filter { $0.state != .withdrawn }.count
    guard liveCount < maxQueueEntries else {
        return refuseCaps(state, commandID: commandID, cause: "queue full (\(maxQueueEntries) entries)", atMillis: atMillis, ids: &ids)
    }
    let undispatchedBytes = state.queue
        .filter { $0.state == .queued || $0.state == .held }
        .reduce(0) { $0 + $1.text.utf8.count }
    guard undispatchedBytes + text.utf8.count <= maxQueueTextBytes else {
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
        targetEpochID: state.epoch.epochID, orderKey: seq.value, sealed: sealed)
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
    let updated = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: entry.state, revision: entry.revision + 1, text: newText,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
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
    guard entry.state == .queued || entry.state == .held else {
        let (s1, prefix) = sequenced(state, kind: "queue-withdraw-refused", digest: eventDigest("withdraw", entryID), ids: &ids)
        return Transition(state: s1, effects: [.emitUI(.denied(cause: "dispatched entries are history, not editable"))], records: prefix)
    }
    var queue = state.queue
    let tombstone = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .withdrawn, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
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
    let queue = state.queue.map { entry -> QueueEntry in
        guard entry.state == .held else { return entry }
        return QueueEntry(
            entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
            state: .queued, revision: entry.revision, text: entry.text,
            targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
    }
    let (s1, prefix) = sequenced(state, kind: "queue-resumed", digest: "resumed", ids: &ids)
    let next = s1.replacing(queue: queue, queueHeld: false, heldReason: .some(nil))
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "queue", detail: "resumed"))],
        records: prefix)
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
        effectiveCaps: state.epoch.effectiveCaps, route: .allowed(endpoint: endpointURL(for: state.epoch.configSnapshot.profiles[alias]!), alias: alias))
    var queue = state.queue
    for i in queue.indices where queue[i].targetEpochID != epoch.epochID && (queue[i].state == .queued) {
        let entry = queue[i]
        queue[i] = QueueEntry(
            entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
            state: .held, revision: entry.revision, text: entry.text,
            targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
    }
    let (s1, prefix) = sequenced(state, kind: "epoch-opened", digest: eventDigest("epoch", alias), ids: &ids)
    let next = s1.replacing(epoch: epoch, queue: queue, admittedCommands: [:])
    return Transition(state: next, effects: [.emitUI(.runUpdate(phase: "epoch", detail: "switched to \(terminalSafe(alias))"))], records: prefix + [.epochOpened(epoch)])
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
    _ state: SessionState, receipt: (RunDescriptor, UInt64) -> RunReceipt, atMillis: UInt64, ids: inout I
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
            pendingApproval: .some(nil), pendingBatch: .some(nil), liveReservations: [])
        return Transition(
            state: next,
            effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; queue held"))],
            records: prefix)
    }
    let order: [QueueKind] = [.steer, .followUp]
    for kind in order {
        if let position = state.queue.firstIndex(where: {
            $0.kind == kind && $0.state == .queued && $0.targetEpochID == state.epoch.epochID
        }) {
            var queue = state.queue
            let entry = queue[position]
            let dispatched = QueueEntry(
                entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
                state: .dispatched, revision: entry.revision, text: entry.text,
                targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
            queue[position] = dispatched
            let mid = state.replacing(
                phase: .completed(receiptValue), activeRun: .some(nil), activeRequest: .some(nil),
                queue: queue, pendingApproval: .some(nil), pendingBatch: .some(nil), liveReservations: [])
            let (s1, prefix) = sequenced(mid, kind: "completed-dispatched", digest: eventDigest("completed", run.runID.raw), ids: &ids)
            // New run, same text: reserve inline (generation+1, counters reset).
            let next = admitReservedRun(s1, entry: dispatched, atMillis: atMillis, ids: &ids)
            return Transition(
                state: next.state,
                effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished; next queued entry dispatched"))] + next.effects,
                records: prefix + [.queueUpdated(dispatched)] + next.records)
        }
    }
    let (s1, prefix) = sequenced(state, kind: "completed", digest: eventDigest("completed", run.runID.raw), ids: &ids)
    let next = s1.replacing(
        phase: .completed(receiptValue), activeRun: .some(nil), activeRequest: .some(nil),
        pendingApproval: .some(nil), pendingBatch: .some(nil), liveReservations: [])
    return Transition(
        state: next,
        effects: [.emitUI(.runUpdate(phase: "completed", detail: "run finished"))],
        records: prefix)
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
        generation: revision, revision: revision, mutating: false)
    let invocation = ProviderInvocation(
        effectID: effectID, requestID: requestID, runID: runID, generation: revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: entry.sealed,
        turnsLeft: state.turnLimit, deadlineMillis: atMillis + defaultRunDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value)"))
    let history = QueueEntry(
        entryID: entry.entryID, commandID: entry.commandID, kind: entry.kind,
        state: .admittedToHistory, revision: entry.revision, text: entry.text,
        targetEpochID: entry.targetEpochID, orderKey: entry.orderKey, sealed: entry.sealed)
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
    return Transition(
        state: next,
        effects: [
            .reserveEffect(reservation),
            .requestProvider(invocation: invocation),
        ],
        records: [
            .eventAppended(seq: seq, kind: "run-admitted", digest: eventDigest("admit", entry.commandID.raw)),
            .operationIntent(OperationRef(operationID: ids.nextOperationID(), state: .intent, mutating: false)),
            .queueUpdated(history),
            // The dispatched queued text opens the transcript (D1).
            .transcriptAppended(.user(entry.text)),
        ])
}

private func failRun<I: IDSource>(
    _ state: SessionState, failure: RunFailure, hold: Bool, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "failed", digest: "failed", ids: &ids)
    let next = s1.replacing(
        phase: .failed(failure), activeRun: .some(nil), activeRequest: .some(nil),
        queueHeld: hold ? true : s1.queueHeld,
        heldReason: hold ? .error("run failed") : s1.heldReason,
        pendingApproval: .some(nil), pendingBatch: .some(nil),
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
    // Structural shape check first: non-empty callIDs, non-empty tools, no
    // duplicate callIDs. Malformed batches fail closed (WIRE-05 spirit).
    var seenCalls: Set<String> = []
    for proposal in batch.proposals {
        guard !proposal.callID.isEmpty, !proposal.tool.isEmpty, seenCalls.insert(proposal.callID).inserted else {
            return failRun(state, failure: .providerError("malformed tool batch: empty or duplicate call identity"), hold: true, atMillis: atMillis, ids: &ids)
        }
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
            generation: run.revision, revision: run.revision, mutating: false)
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
        // silently dropped (I05).
        let denial = "tools denied by effective capabilities: \(denied.joined(separator: ", "))"
        let responses = batch.proposals.map {
            DurableRecord.transcriptAppended(.toolResponse(callID: $0.callID, text: "denied: \(denial)"))
        }
        return Transition(
            state: next,
            effects: [
                .reserveEffect(reservation),
                .requestProvider(invocation: invocation),
                .emitUI(.denied(cause: denial)),
            ],
            records: prefix + [.operationResult(ref, outcome: "denied")] + responses)
    }
    if batch.proposals.isEmpty {
        let (s1, prefix) = sequenced(state, kind: "requesting", digest: "empty-batch", ids: &ids)
        return Transition(state: s1.replacing(phase: .requesting, pendingBatch: .some(nil)), effects: [], records: prefix)
    }
    let names = batch.proposals.map(\.tool)
    let needsApproval = batchNeedsApproval(
        toolNames: names, execPolicy: state.epoch.effectiveCaps.tools.exec,
        mode: state.trustMode, sealed: state.activeRun?.sealed ?? false)
    if !needsApproval {
        return dispatchTrustedBatch(state, batch: batch, ids: &ids)
    }
    guard let run = state.activeRun else {
        return failRun(state, failure: .providerError("authorising without a run"), hold: true, atMillis: atMillis, ids: &ids)
    }
    let request = ApprovalRequest(
        requestID: run.requestID, runID: run.runID, generation: run.revision,
        operation: "tool batch: \(names.joined(separator: ", "))",
        requiredGrant: "explicit approval")
    let (s1, prefix) = sequenced(state, kind: "authorising", digest: eventDigest("approval", run.requestID.raw), ids: &ids)
    let next = s1.replacing(phase: .authorising, pendingApproval: .some(request), pendingBatch: .some(batch))
    return Transition(
        state: next,
        effects: [.requestApproval(request)],
        records: prefix)
}

private func dispatchTrustedBatch<I: IDSource>(_ state: SessionState, batch: ToolBatch, ids: inout I) -> Transition {
    guard let run = state.activeRun else {
        let (s1, prefix) = sequenced(state, kind: "failed", digest: "no-run", ids: &ids)
        return Transition(state: s1.replacing(phase: .failed(.providerError("trusted dispatch without a run"))), effects: [], records: prefix)
    }
    let effectID = ids.nextEffectID()
    let mutating = batch.proposals.contains { $0.tool != "read" && $0.tool != "search" && $0.tool != "consult" }
    let reservation = EffectReservation(
        effectID: effectID, runID: run.runID, requestID: run.requestID,
        generation: run.revision, revision: run.revision, mutating: mutating, batch: batch)
    let (s1, prefix) = sequenced(state, kind: "executing", digest: eventDigest("exec", run.requestID.raw), ids: &ids)
    let next = s1.replacing(
        phase: .executing, pendingApproval: .some(nil), pendingBatch: .some(nil),
        liveReservations: state.liveReservations + [reservation])
    return Transition(
        state: next,
        effects: [.reserveEffect(reservation)],
        records: prefix)
}

private func grantApproval<I: IDSource>(_ state: SessionState, requestID: RequestID, ids: inout I) -> Transition {
    _ = requestID
    guard let batch = state.pendingBatch else {
        let (s1, prefix) = sequenced(state, kind: "authorising", digest: "grant-no-batch", ids: &ids)
        return Transition(state: s1, effects: [], records: prefix)
    }
    return dispatchTrustedBatch(state, batch: batch, ids: &ids)
}

private func denyApproval<I: IDSource>(_ state: SessionState, ids: inout I) -> Transition {
    let (s1, prefix) = sequenced(state, kind: "failed", digest: "approval-denied", ids: &ids)
    let next = s1.replacing(
        phase: .failed(.approvalDenied("operator denied the tool batch")),
        pendingApproval: .some(nil), pendingBatch: .some(nil))
    return Transition(
        state: next,
        effects: [.emitUI(.denied(cause: "tool batch denied by operator"))],
        records: prefix)
}

private func holdForApproval<I: IDSource>(
    _ state: SessionState, requestID: RequestID, reason: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = requestID
    _ = atMillis
    let (s1, prefix) = sequenced(state, kind: "approval-required", digest: "unavailable", ids: &ids)
    return Transition(
        state: s1,
        effects: [.emitUI(.runUpdate(phase: "authorising", detail: "approval required: \(terminalSafe(reason))"))],
        records: prefix)
}

// MARK: Effect completion (M1B2-3 continuation)

private func continueAfterEffect<I: IDSource>(
    _ state: SessionState, effectID: EffectID, receipt: String, atMillis: UInt64, ids: inout I
) -> Transition {
    _ = effectID
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
        generation: run.revision, revision: run.revision, mutating: false)
    let invocation = ProviderInvocation(
        effectID: nextEffectID, requestID: run.requestID, runID: run.runID, generation: run.revision,
        alias: state.epoch.profile.alias, epochID: state.epoch.epochID, sealed: run.sealed,
        turnsLeft: state.turnLimit - state.turnsUsed, deadlineMillis: state.runDeadlineMillis,
        historyDigest: fnv1aHex("\(state.sessionID.raw):\(seq.value):continue"))
    var consumed = state.consumedEffects
    consumed.insert(effectID)
    var live = state.liveReservations
    live.removeAll(where: { $0.effectID == effectID })
    let ref = OperationRef(operationID: ids.nextOperationID(), callID: effectID.raw, state: .done, mutating: false)
    let (s1, prefix) = sequenced(state, kind: "requesting", digest: eventDigest("continue", run.requestID.raw), ids: &ids)
    let next = s1.replacing(
        phase: .requesting, consumedEffects: consumed,
        turnsUsed: state.turnsUsed + 1, liveReservations: live, lastSequence: seq.value)
    // Each proposal in the completed batch gets its tool response carrying
    // the receipt text — pairing is callID-keyed, so multi-call batches
    // stay exact. Stale completions (reservation gone) record nothing.
    let responses = (state.liveReservations.first(where: { $0.effectID == effectID })?.batch.proposals ?? []).map {
        DurableRecord.transcriptAppended(.toolResponse(callID: $0.callID, text: receipt))
    }
    return Transition(
        state: next,
        effects: [.reserveEffect(reservation), .requestProvider(invocation: invocation)],
        records: prefix + [
            .eventAppended(seq: seq, kind: "effect-consumed", digest: eventDigest("consumed", effectID.raw)),
            .operationResult(ref, outcome: receipt),
        ] + responses)
}

private func completeEffect<I: IDSource>(
    _ state: SessionState, effectID: EffectID, outcome: EffectOutcome, ids: inout I
) -> Transition {
    switch outcome {
    case .success(let summary):
        return continueAfterEffect(state, effectID: effectID, receipt: summary, atMillis: 0, ids: &ids)
    case .failureReceipt(let summary):
        return continueAfterEffect(state, effectID: effectID, receipt: "tool-failure: \(summary)", atMillis: 0, ids: &ids)
    }
}

private func failEffect<I: IDSource>(_ state: SessionState, effectID: EffectID, error: String, ids: inout I) -> Transition {
    // The carried error text reaches the transcript (tool-failure receipt)
    // so the model sees WHAT failed — a fixed string would blind the loop.
    continueAfterEffect(state, effectID: effectID, receipt: "tool-failure: \(terminalSafe(error))", atMillis: 0, ids: &ids)
}

// MARK: Cancellation (C3: retention BEFORE invalidation)

private func cancelActive<I: IDSource>(_ state: SessionState, atMillis: UInt64, ids: inout I) -> Transition {
    // C3: every live MUTATING reservation keeps its unknown marker + record
    // FIRST; only then are the tables cleared and the generation bumped.
    var unresolved = state.unresolvedOperations
    var records: [DurableRecord] = []
    for reservation in state.liveReservations where reservation.mutating {
        let ref = OperationRef(
            operationID: ids.nextOperationID(), callID: reservation.effectID.raw,
            state: .unknown, mutating: true)
        let (markers, overflow) = appendUnresolved(unresolved, ref)
        unresolved = markers
        if overflow {
            return integrityStop(state, ids: &ids)
        }
        records.append(.operationResult(ref, outcome: "unknown"))
    }
    let (s1, prefix) = sequenced(state, kind: "cancelling", digest: "cancel", ids: &ids)
    var active: ActiveRequest? = nil
    if let request = state.activeRequest {
        active = ActiveRequest(
            requestID: request.requestID, runID: request.runID,
            generation: request.generation, delivery: .deliveryUnknown, bytesOut: request.bytesOut)
    }
    // liveReservations cleared HERE (after the retention loop above):
    // invalidation follows preservation, never precedes it (C3).
    let next = s1.replacing(
        phase: .cancelling, activeRequest: active,
        queueHeld: true, heldReason: .cancelled(sinceMillis: atMillis),
        pendingApproval: .some(nil), pendingBatch: .some(nil),
        retryDeadlineMillis: .some(nil), liveReservations: [],
        generation: state.generation + 1,
        unresolvedOperations: unresolved)
    var effects: [Effect] = [.emitUI(.runUpdate(phase: "cancelling", detail: "cancelled; queue held"))]
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
        generation: run.revision, revision: run.revision, mutating: false)
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
