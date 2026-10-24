/// A3-2 reopen reconciliation (SPEC §9.1, ARCH §2): reconstruct durable
/// operation outcomes from a session-scoped record stream after reopening
/// the store. Pure — no I/O, no clock, no IDs minted.
///
/// Identity contract (A3-1): every tool operation carries a stable derived
/// ID (`effectID/callID`) on both its intent and its completion. Records
/// WITHOUT a callID are admission/provider markers (admission intents) or
/// denial receipts (callID-less, done, non-mutating) — never completed
/// tool work. Any OTHER callID-less result takes the orphan path: visible
/// and held when unknown or mutating, never silently absorbed.
///
/// Classification per stable ID:
/// - intent + done result → completed.
/// - intent + unknown result → explicit unknown (durable recovery evidence).
/// - intent with no result → UNMATCHED. A mutating side effect may have
///   executed with its receipt lost (SPEC §9.1: crash between effect and
///   completion), so it is unknown and HELD. A non-mutating intent is
///   side-effect-free by construction, so it is demonstrably re-runnable
///   — reported, never held. This is the unknown-vs-unstarted line.
/// - result with no intent → orphan. Our own ledger emits these (denial
///   receipts excepted below, pre-A3-1 completions, ambiguous-delivery
///   unknowns, near-unreachable fallbacks), so they never fail the
///   reopen — but an unknown-state orphan is an explicit unknowability
///   claim and always holds; a done-state orphan holds iff mutating.
/// - HOLD RULE (single principle): every `.unknown`-state record —
///   explicit, unmatched-mutating, or orphan — seeds the hold, however
///   small its blast radius. The live system holds on every such marker
///   (ambiguous delivery blocks the queue; stale/cancelled mutating work
///   blocks continuation); reopen preserves that stance instead of
///   downgrading it. Explicit reconciliation (A3-3) clears them.
/// - callID-less, non-mutating, done results are denial receipts —
///   informational only, never held, never orphaned tool work. Every
///   other callID-less result takes the orphan path above.
/// - duplicate intents, duplicate results, contradictory outcomes for one
///   ID, malformed states (non-`.intent` in an intent record, `.intent` in
///   a result record), or admission/tool ID namespace collisions →
///   `.integrity`, fail closed — including for callID-less records.
///
/// A batch-level executor receipt NEVER completes individual calls: only a
/// per-operation result record with the matching ID completes that call.
/// A partial batch failure leaves some calls completed and others
/// unmatched — classified call by call, never inferred across the batch.
///
/// Recovered state: `resumedAfterReopen` seeds exactly the held
/// (unknown-state) refs into `unresolvedOperations`. Admission
/// and continuation already refuse new work while that list is non-empty,
/// so no automatic mutating continuation or re-dispatch under a new call
/// ID is possible until an explicit reconciliation clears them.
public struct OperationReconciliation: Sendable, Equatable {
    /// Intent + done result, in first-seen order.
    public let completed: [OperationID]
    /// Intent + unknown result (durable recovery evidence; all held —
    /// `.unknown` is an explicit unknowability claim), first-seen.
    public let explicitUnknown: [OperationRef]
    /// Intent-only crashes on mutating operations (unknown + held).
    public let unmatchedMutating: [OperationRef]
    /// Intent-only crashes on side-effect-free operations (re-runnable).
    public let unmatchedNonMutating: [OperationID]
    /// Results without intents (legacy/ambiguous/fallback shapes),
    /// first-seen. Unknown-state orphans always hold; done-state orphans
    /// hold iff mutating.
    public let orphanResults: [OperationRef]
    /// Unknown-state refs seeding `unresolvedOperations`.
    public let heldOperations: [OperationRef]
    /// CallID-less intent markers (admission/provider), informational.
    public let admissionIntents: Int
    /// CallID-less non-mutating done results (denial receipts),
    /// informational, never held.
    public let nonToolResults: Int
    public let cancelledPendingErrors: [CancelledPendingError]

    public init(
        completed: [OperationID] = [], explicitUnknown: [OperationRef] = [],
        unmatchedMutating: [OperationRef] = [], unmatchedNonMutating: [OperationID] = [],
        orphanResults: [OperationRef] = [], heldOperations: [OperationRef] = [],
        admissionIntents: Int = 0, nonToolResults: Int = 0,
        cancelledPendingErrors: [CancelledPendingError] = []
    ) {
        self.completed = completed
        self.explicitUnknown = explicitUnknown
        self.unmatchedMutating = unmatchedMutating
        self.unmatchedNonMutating = unmatchedNonMutating
        self.orphanResults = orphanResults
        self.heldOperations = heldOperations
        self.admissionIntents = admissionIntents
        self.nonToolResults = nonToolResults
        self.cancelledPendingErrors = cancelledPendingErrors
    }
}

public func reconcileOperations(_ records: [DurableRecord]) throws -> OperationReconciliation {
    var intents: [OperationID: OperationRef] = [:]
    var intentOrder: [OperationID] = []
    var results: [OperationID: (ref: OperationRef, outcome: String)] = [:]
    var resultOrder: [OperationID] = []
    var admissionIntents = 0
    var nonToolResults = 0
    var toolIDs: Set<OperationID> = []
    var admissionIDs: Set<OperationID> = []
    var denialIDs: Set<OperationID> = []

    var pendingMarkers: [OperationID: OperationRef] = [:]
    var pendingMarkerOrder: [OperationID] = []
    var cancelledErrors: [CancelledPendingError] = []
    for record in records {
        switch record {
        case .operationIntent(let ref):
            // State validity is checked BEFORE the callID branch: a corrupt
            // shape fails closed however it is addressed.
            guard ref.state == .intent else {
                throw StoreError.integrity("operation intent \(ref.operationID.raw) carries non-intent state")
            }
            guard intents[ref.operationID] == nil else {
                throw StoreError.integrity("duplicate intent for operation \(ref.operationID.raw)")
            }
            intents[ref.operationID] = ref
            intentOrder.append(ref.operationID)
            if ref.callID == nil {
                // Admission/provider marker, not a tool operation.
                admissionIntents += 1
                admissionIDs.insert(ref.operationID)
            } else {
                toolIDs.insert(ref.operationID)
            }
        case .operationResult(let ref, let outcome):
            guard ref.state != .intent else {
                throw StoreError.integrity("operation result \(ref.operationID.raw) carries intent state")
            }
            // Last-record-wins for cancelledPendingMarker supersession: only proven unstarted or termination promotion may supersede,
            // and the state must match the proof (done ↔ unstarted, unknown ↔ terminated).
            if let _ = pendingMarkers[ref.operationID] {
                let valid = (ref.state == .done && outcome == "cancelled: unstarted")
                    || (ref.state == .unknown && outcome == "unknown: cancelled pending terminated")
                guard valid else {
                    throw StoreError.integrity("marker supersession requires state-matching proof 'cancelled: unstarted' (done) or 'unknown: cancelled pending terminated' (unknown) for \(ref.operationID.raw), got state=\(ref.state) outcome='\(outcome)'")
                }
                pendingMarkers.removeValue(forKey: ref.operationID)
            } else {
                guard results[ref.operationID] == nil else {
                    throw StoreError.integrity("duplicate result for operation \(ref.operationID.raw)")
                }
            }
            results[ref.operationID] = (ref, outcome)
            if !resultOrder.contains(ref.operationID) {
                resultOrder.append(ref.operationID)
            }
            if ref.callID == nil, ref.state == .done, !ref.mutating {
                // Denial receipt shape: informational only, never held,
                // never an orphaned tool operation.
                nonToolResults += 1
                denialIDs.insert(ref.operationID)
            } else {
                // Every other callID-less result (ambiguous-delivery
                // unknowns, legacy shapes, corruption-adjacent) takes the
                // orphan path: visible, and held when unknown or mutating.
                toolIDs.insert(ref.operationID)
            }
        case .cancelledPendingMarker(let ref, _):
            guard ref.state != .intent else {
                throw StoreError.integrity("cancelledPendingMarker \(ref.operationID.raw) carries intent state")
            }
            // Marker is HOLD-equivalent but supersedable; store separately and do not treat as duplicate result yet.
            // If a result already exists for this ID, marker is ignored (result wins — last-record-wins).
            if results[ref.operationID] != nil {
                continue
            }
            guard pendingMarkers[ref.operationID] == nil else {
                throw StoreError.integrity("duplicate cancelledPendingMarker for operation \(ref.operationID.raw)")
            }
            pendingMarkers[ref.operationID] = ref
            pendingMarkerOrder.append(ref.operationID)
            toolIDs.insert(ref.operationID)
        case .cancelledPendingError(let err):
            cancelledErrors.append(err)
        case .acknowledgedUnresolved, .artifactPublished, .transcriptAppended, .eventAppended, .queueAdmitted, .queueUpdated, .checkpointCommitted, .writerRecovered, .sessionOpened, .epochOpened:
            continue
        }
    }
    // Namespace discipline: admission markers and denial receipts (minted
    // IDs) must never collide with tool operation IDs (derived IDs) — a
    // collision is corruption, not a coincidence (A3-1: minted IDs never
    // contain "/").
    if !admissionIDs.isDisjoint(with: toolIDs) {
        throw StoreError.integrity("admission/tool operation ID namespace collision")
    }
    if !denialIDs.isDisjoint(with: toolIDs) {
        throw StoreError.integrity("denial/tool operation ID namespace collision")
    }

    var completed: [OperationID] = []
    var explicitUnknown: [OperationRef] = []
    var unmatchedMutating: [OperationRef] = []
    var unmatchedNonMutating: [OperationID] = []
    var orphanResults: [OperationRef] = []
    var held: [OperationRef] = []

    for id in intentOrder {
        let intent = intents[id]!
        // Admission markers were counted above; they never pair.
        guard intent.callID != nil else { continue }
        if let marker = pendingMarkers[id], results[id] == nil {
            // Cancelled-pending marker without superseding result: HOLD-equivalent.
            explicitUnknown.append(marker)
            held.append(marker)
            continue
        }
        guard let result = results[id] else {
            if intent.mutating {
                let unknown = OperationRef(
                    operationID: id, callID: intent.callID,
                    state: .unknown, mutating: true)
                unmatchedMutating.append(unknown)
                held.append(unknown)
            } else {
                unmatchedNonMutating.append(id)
            }
            continue
        }
        if result.ref.state == .done {
            // A matching ID alone certifies nothing: the done result must
            // agree with its intent on callID and operation classification
            // (mutating). Contradictory metadata is corruption, not
            // completion — fail closed. (`.unknown` pairs keep the
            // conservative handling: no agreement required.)
            guard result.ref.callID == intent.callID,
                  result.ref.mutating == intent.mutating else {
                throw StoreError.integrity(
                    "done result for \(id.raw) contradicts its intent (callID/classification mismatch)")
            }
            completed.append(id)
            continue
        }
        // Only `.unknown` reaches here (`.intent` in a result record is
        // rejected above): durable recovery evidence. Unknown-state always
        // holds — it is an explicit unknowability claim, not mere absence.
        explicitUnknown.append(result.ref)
        held.append(result.ref)
    }
    for id in resultOrder where intents[id] == nil && !denialIDs.contains(id) {
        let result = results[id]!
        orphanResults.append(result.ref)
        // No intent to pair with: the operation may have executed with its
        // intent lost. Unknown-state orphans always hold (explicit claim);
        // done-state orphans hold iff mutating (possible side effect).
        if result.ref.state == .unknown {
            held.append(result.ref)
        } else if result.ref.mutating {
            held.append(OperationRef(
                operationID: id, callID: result.ref.callID,
                state: .unknown, mutating: true))
        }
    }
    for id in pendingMarkerOrder where intents[id] == nil {
        guard let marker = pendingMarkers[id] else { continue }
        orphanResults.append(marker)
        held.append(marker)
    }
    // Include cancelledPendingErrors in held reason via count already in held; actual strings aggregated by caller via new field.
    // Hold reason at call sites should append cancelledErrors strings if present.

    return OperationReconciliation(
        completed: completed, explicitUnknown: explicitUnknown,
        unmatchedMutating: unmatchedMutating, unmatchedNonMutating: unmatchedNonMutating,
        orphanResults: orphanResults, heldOperations: held,
        admissionIntents: admissionIntents, nonToolResults: nonToolResults,
        cancelledPendingErrors: cancelledErrors)
}

extension SessionState {
    /// Post-reopen resume: idle phase, empty live tables, and exactly the
    /// reconciled held operations as recovery markers. While they stand,
    /// admission refuses new runs (held queue entries) and continuation
    /// refuses to proceed — no automatic mutating work until an explicit
    /// reconciliation clears them (A3-3 owns recovery decisions).
    public static func resumedAfterReopen(
        sessionID: SessionID, epoch: EpochDescriptor, trustMode: TrustMode,
        heldOperations: [OperationRef]
    ) -> SessionState {
        SessionState(
            sessionID: sessionID, epoch: epoch, trustMode: trustMode, phase: .idle,
            queueHeld: !heldOperations.isEmpty,
            heldReason: heldOperations.isEmpty ? nil : .error(
                "reopen: \(heldOperations.count) unresolved operation(s); reconcile before dispatch"),
            unresolvedOperations: heldOperations)
    }
}
