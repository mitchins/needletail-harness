/// M1-B session events (ARCH §§1–3). Every event is a value carrying
/// EXPLICIT stamped IDs and timestamps — the actor stamps before the
/// transition runs, so replay needs nothing but the event log plus the ID
/// counter. Model text travels ONLY in input/response payloads, which have
/// no path to grants, routes or epochs (I12, enforced by type: those fields
/// exist solely on epoch/operator-trust events).

public enum SessionEvent: Sendable, Equatable {
    // Operator input (stamped: commandID, revision, sealed mode, enqueuedAtMillis).
    // `sealed` comes from invocation flags (M1-D CLI); sealed batches never reach authorising.
    case operatorInput(commandID: CommandID, text: String, kind: QueueKind, revision: UInt64, sealed: Bool, atMillis: UInt64)
    case queueEdit(entryID: String, newText: String, baseRevision: UInt64, atMillis: UInt64)
    case queueWithdraw(entryID: String, atMillis: UInt64)
    case queueResume(atMillis: UInt64)
    /// M2-D D0: retarget a stale-epoch entry to the current epoch (with
    /// route/consent re-validation). Recorded; the hold is NOT released —
    /// resume (or reconcile, for unknown deliveries) releases separately.
    case queueRetarget(entryID: String, atMillis: UInt64)
    /// M2-D D0: explicit operator reconciliation of a held-unknown
    /// delivery (requeue for redispatch, or withdraw to drop). Recorded;
    /// never automatic, never a non-delivery proof.
    case queueReconcile(entryID: String, atMillis: UInt64)
    /// M2-D D1: operator input carrying authorized attachment snapshots
    /// (captured by Runtime BEFORE stamping; the transition never parses
    /// `@` text into snapshots). Mirrors operatorInput routing: fresh run
    /// when idle (capture-fresh, no dwell), queued otherwise. Sealed
    /// submissions carrying snapshots are refused at admission.
    case operatorInputAttachments(commandID: CommandID, text: String, kind: QueueKind, sealed: Bool, attachments: [AttachmentSnapshot], atMillis: UInt64)
    /// M2-D D1: freshness evidence for the snapshots validation was
    /// requested for (`requested`), gathered by the composed validator.
    /// Event-scoped: never stored, never replayed.
    case attachmentValidationResult(entryID: String, requested: [AttachmentSnapshot], observations: [AttachmentObservation], atMillis: UInt64)
    /// M2-D D1: explicit operator replacement of an entry's snapshots
    /// (the fix path for stale holds — never automatic, never silent).
    /// Preserves entry state; resume releases separately.
    case queueAttachmentReplace(entryID: String, snapshots: [AttachmentSnapshot], atMillis: UInt64)
    /// M2-D D2: explicit undo preview (dry run — performs no mutation).
    /// The driver reconciles the group from the durable log and attaches
    /// preimage availability; the transition runs pure preflight against
    /// validator evidence and reports eligibility.
    case undoPreview(group: ChangeGroup, preimagesAvailable: [String: Bool], atMillis: UInt64)
    /// M2-D D2: explicit undo run. `undoCommandID` is the stable O-2
    /// command key (`undo-<seq>`); duplicates return the recorded
    /// disposition, never a second inverse.
    case undoRun(undoCommandID: String, group: ChangeGroup, preimagesAvailable: [String: Bool], atMillis: UInt64)
    /// M2-D D2: validator evidence for a preview or run (event-scoped,
    /// never stored). The actor echoes the request context so the
    /// transition can bind evidence to the pending undo.
    case undoValidationResult(undoCommandID: String, isPreview: Bool, requested: [UndoValidationNeed], observations: [UndoFileObservation], atMillis: UInt64)
    /// M2-D D2: one inverse's settled outcome from the applier. The
    /// transition commits the durable inverse result and advances the
    /// chain (or halts it on unknown).
    case inverseCompleted(undoCommandID: String, inverseID: String, outcome: UndoInverseOutcome, atMillis: UInt64)
    /// M2-D D2: driver-stamped recovery for a journal whose inverses are
    /// all settled but whose disposition was never committed (crash
    /// between last result and disposition). Outcomes come reconciled
    /// from the durable log; the transition commits disposition + notice
    /// atomically (idempotent — an existing disposition wins).
    case undoFinalize(undoCommandID: String, group: ChangeGroup, fileOutcomes: [UndoFileOutcome], atMillis: UInt64)
    /// M2-D D2: rewind lineage fork request (record only). The boundary
    /// must lie in the past of the live epoch; nothing is mutated.
    case lineageForkRequest(boundary: LineageBoundary, atMillis: UInt64)
    case approvalGrant(requestID: RequestID, generation: Revision, atMillis: UInt64)
    case approvalDeny(requestID: RequestID, generation: Revision, reason: String, atMillis: UInt64)
    case approvalUnavailable(requestID: RequestID, generation: Revision, reason: String, atMillis: UInt64)
    case switchModel(alias: String, atMillis: UInt64)
    case checkpointRequested(atMillis: UInt64)
    case checkpointCommitted(newEpoch: EpochDescriptor?, atMillis: UInt64)
    case checkpointFailed(reason: String, atMillis: UInt64)
    case cancelRequested(atMillis: UInt64)
    case dismissRun(atMillis: UInt64)
    case invalidInput(fingerprint: String, cause: String, atMillis: UInt64)
    // Actor-internal + provider/transport (stamped pre-await or scripted)
    case requestDispatched(requestID: RequestID, atMillis: UInt64)
    case requestStarted(requestID: RequestID, generation: Revision, atMillis: UInt64)
    case providerResponse(requestID: RequestID, generation: Revision, response: ProviderResponse, atMillis: UInt64)
    case transportFailed(requestID: RequestID, generation: Revision, phase: TransportPhase, error: String, atMillis: UInt64)
    case validationCompleted(requestID: RequestID, generation: Revision, batch: ToolBatch, atMillis: UInt64)
    case effectCompleted(effectID: EffectID, runID: RunID, generation: Revision, expectedRevision: Revision, mutating: Bool, outcome: EffectOutcome, atMillis: UInt64)
    case effectFailed(effectID: EffectID, runID: RunID, generation: Revision, expectedRevision: Revision, mutating: Bool, error: String, atMillis: UInt64)
    case cancelledPendingRemoved(effectID: EffectID, atMillis: UInt64)
    /// M2-C C0 phase 2 (plan REV12 §3.4b): resolution replies for an
    /// in-flight `.resolveExecIdentities` effect.
    case execIdentitiesResolved(resolutionID: String, runID: RunID, generation: Revision, identities: [ResolvedExecIdentity], atMillis: UInt64)
    case execResolutionFailed(resolutionID: String, runID: RunID, generation: Revision, status: String, summary: String, atMillis: UInt64)
    case tick(nowMillis: UInt64)
}

public enum TransportPhase: Sendable, Equatable {
    /// No byte of this request left the process.
    case preSend
    /// Streamed content was produced (partial evidence may exist).
    case postContent
    /// Bytes may or may not have been sent — hold for reconciliation, never auto-resend.
    case ambiguous
}

public enum EffectOutcome: Sendable, Equatable {
    case success(String)
    case failureReceipt(String)
    case perCall(ExecutorResult)
    case preDispatchFailure(ToolFailure)
}

/// Minimal M1-C handoff (detail deferred to M1-C): the completion boundary
/// plus generation binding. `isFinal` comes from native completion signals:
/// proposals → validatingTools; final text → completed; interim → requesting.
public struct ProviderResponse: Sendable, Equatable {
    public let requestID: RequestID
    public let generation: Revision
    public let outcome: ProviderOutcome
    public let usageInput: Int?
    public let usageOutput: Int?
    /// Served model identity as returned on the wire (M1-C additive: exact
    /// passthrough for probe/usage records; mismatch is a diagnostic flag,
    /// never a failure or coercion).
    public let returnedModel: String?

    public init(requestID: RequestID, generation: Revision, outcome: ProviderOutcome, usageInput: Int? = nil, usageOutput: Int? = nil, returnedModel: String? = nil) {
        self.requestID = requestID
        self.generation = generation
        self.outcome = outcome
        self.usageInput = usageInput
        self.usageOutput = usageOutput
        self.returnedModel = returnedModel
    }
}

public enum ProviderOutcome: Sendable, Equatable {
    case textDeltaComplete(text: String, toolProposals: [ToolProposal], isFinal: Bool)
    case failed(String)
    case interrupted
}

/// Validated-shape tool proposal. Field names/types only — a proposal is
/// DATA (never an effect) until authorising + approval + reservation.
/// `arguments` carries the VERBATIM native arguments for the executor
/// (M1-D scripted backend reads this — digests must never feed execution);
/// `argumentsDigest` stays for secret-safe records and logs. Defaulted so
/// every pre-M1-D construction site keeps compiling.
public struct ToolProposal: Sendable, Equatable {
    public let callID: String
    public let tool: String
    public let argumentsDigest: String
    public let arguments: String?

    public init(callID: String, tool: String, argumentsDigest: String, arguments: String? = nil) {
        self.callID = callID
        self.tool = tool
        self.argumentsDigest = argumentsDigest
        self.arguments = arguments
    }
}

public struct ToolBatch: Sendable, Equatable {
    public let proposals: [ToolProposal]
    public init(_ proposals: [ToolProposal] = []) {
        self.proposals = proposals
    }
}

/// Terminal run outcomes. Exit-code mapping is M1-D's; the vocabulary is M1-B's.
public enum RunOutcome: Sendable, Equatable {
    case completed(RunReceipt)
    case failed(RunFailure)
    case interrupted
    case approvalRequired(ApprovalRequest)
}

/// Typed projection of session occurrences for UI + future JSONL — ONE
/// shared vocabulary, never a second output semantics (UX-DX §3.1).
/// Constructible ONLY inside Core (`internal` init): Presentation can carry
/// projections but never mint them (R21, pinned by a construction-site gate).
public struct SessionEventProjection: Sendable, Equatable {
    public let kind: String
    public let detail: String
    /// Structured terminal outcome for `run_finished` envelopes (optional;
    /// other kinds leave it `nil`).
    public let outcome: String?

    internal init(kind: String, detail: String, outcome: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.outcome = outcome
    }

    public static func admitted(commandID: CommandID, revision: UInt64) -> SessionEventProjection {
        SessionEventProjection(kind: "admitted", detail: "\(commandID.raw):\(revision)")
    }

    public static func denied(cause: String) -> SessionEventProjection {
        SessionEventProjection(kind: "denied", detail: terminalSafe(cause))
    }

    public static func runUpdate(phase: String, detail: String) -> SessionEventProjection {
        SessionEventProjection(kind: "run:\(phase)", detail: terminalSafe(detail))
    }

    /// Agent-activity projection. Fields join with newlines (never commas —
    /// aliases may contain them); the reducer splits leniently and ignores
    /// malformed payloads instead of crashing.
    public static func agent(alias: String, locality: String, phase: String) -> SessionEventProjection {
        SessionEventProjection(kind: "agent", detail: "\(alias)\n\(locality)\n\(phase)")
    }

    /// Incremental streaming delta (M1-D): the provider produced `text`
    /// for `requestID` before final completion. Display-hint only (never
    /// state); terminalSafe preserved. Kind is "delta" per envelope spec.
    public static func delta(requestID: RequestID, text: String) -> SessionEventProjection {
        SessionEventProjection(kind: "delta", detail: "\(requestID.raw)\n\(terminalSafe(text))")
    }

    /// Terminal `run_finished` envelope payload carrier (M1-D JSONL).
    public static func terminalSignal(outcome: String, detail: String) -> SessionEventProjection {
        return runFinished(outcome: outcome, detail: detail)
    }

    public static func runFinished(outcome: String, detail: String) -> SessionEventProjection {        SessionEventProjection(kind: "run_finished", detail: terminalSafe(detail), outcome: outcome)
    }
}
