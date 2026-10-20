/// A3-2 reopen reconciliation (SPEC §9.1, ARCH §2): reconstruct durable
/// operation outcomes from a session-scoped record stream after reopening
/// the store. Pure — no I/O, no clock, no IDs minted.
///
/// Identity contract (A3-1): every tool operation carries a stable derived
/// ID (`effectID/callID`) on both its intent and its completion. Records
/// WITHOUT a callID are admission/provider markers (admission intents) or
/// denial receipts — never tool operations (requirement: they must not be
/// misclassified as orphaned tool work).
///
/// Classification per stable ID:
/// - intent + done result → completed.
/// - intent + unknown result → explicit unknown (durable recovery
///   evidence; mutating members hold continuation).
/// - intent with no result → UNMATCHED. A mutating side effect may have
///   executed with its receipt lost (SPEC §9.1: crash between effect and
///   completion), so it is unknown and HELD. A non-mutating intent is
///   side-effect-free by construction, so it is demonstrably re-runnable
///   — reported, never held. This is the unknown-vs-unstarted line.
/// - result with no intent → orphan. Our own ledger can emit these (deny
///   receipts, pre-A3-1 completions, near-unreachable fallbacks), so they
///   never fail the reopen; a mutating orphan is held as unknown, the rest
///   are reported.
/// - duplicate intents, duplicate results, contradictory outcomes for one
///   ID, malformed states (non-`.intent` in an intent record, `.intent` in
///   a result record), or a callID-less intent sharing an ID with tool
///   records (namespace collision) → `.integrity`, fail closed.
///
/// A batch-level executor receipt NEVER completes individual calls: only a
/// per-operation result record with the matching ID completes that call.
/// A partial batch failure leaves some calls completed and others
/// unmatched — classified call by call, never inferred across the batch.
///
/// Recovered state: `resumedAfterReopen` seeds exactly the held
/// (unknown-state, mutating) refs into `unresolvedOperations`. Admission
/// and continuation already refuse new work while that list is non-empty,
/// so no automatic mutating continuation or re-dispatch under a new call
/// ID is possible until an explicit reconciliation clears them.
public struct OperationReconciliation: Sendable, Equatable {
    /// Intent + done result, in first-seen order.
    public let completed: [OperationID]
    /// Intent + unknown result (durable recovery evidence), first-seen.
    public let explicitUnknown: [OperationRef]
    /// Intent-only crashes on mutating operations (unknown + held).
    public let unmatchedMutating: [OperationRef]
    /// Intent-only crashes on side-effect-free operations (re-runnable).
    public let unmatchedNonMutating: [OperationID]
    /// Results without intents (legacy/deny/fallback shapes), first-seen.
    public let orphanResults: [OperationRef]
    /// Unknown-state mutating refs seeding `unresolvedOperations`.
    public let heldOperations: [OperationRef]
    /// CallID-less intent markers (admission/provider), informational.
    public let admissionIntents: Int
    /// CallID-less results (denial receipts), informational, never held.
    public let nonToolResults: Int

    public init(
        completed: [OperationID] = [], explicitUnknown: [OperationRef] = [],
        unmatchedMutating: [OperationRef] = [], unmatchedNonMutating: [OperationID] = [],
        orphanResults: [OperationRef] = [], heldOperations: [OperationRef] = [],
        admissionIntents: Int = 0, nonToolResults: Int = 0
    ) {
        self.completed = completed
        self.explicitUnknown = explicitUnknown
        self.unmatchedMutating = unmatchedMutating
        self.unmatchedNonMutating = unmatchedNonMutating
        self.orphanResults = orphanResults
        self.heldOperations = heldOperations
        self.admissionIntents = admissionIntents
        self.nonToolResults = nonToolResults
    }
}

public func reconcileOperations(_ records: [DurableRecord]) throws -> OperationReconciliation {
    var intents: [OperationID: OperationRef] = [:]
    var intentOrder: [OperationID] = []
    var results: [OperationID: (ref: OperationRef, outcome: String)] = [:]
    var resultOrder: [OperationID] = []
    var admissionIntents = 0
    var nonToolResults: [OperationRef] = []
    var toolIDs: Set<OperationID> = []
    var admissionIDs: Set<OperationID> = []

    for record in records {
        switch record {
        case .operationIntent(let ref):
            guard ref.callID != nil else {
                // Admission/provider marker, not a tool operation.
                admissionIntents += 1
                admissionIDs.insert(ref.operationID)
                continue
            }
            guard ref.state == .intent else {
                throw StoreError.integrity("operation intent \(ref.operationID.raw) carries non-intent state")
            }
            guard intents[ref.operationID] == nil else {
                throw StoreError.integrity("duplicate intent for operation \(ref.operationID.raw)")
            }
            intents[ref.operationID] = ref
            intentOrder.append(ref.operationID)
            toolIDs.insert(ref.operationID)
        case .operationResult(let ref, let outcome):
            guard ref.callID != nil else {
                // Denial receipt shape (callID-less, non-mutating, done):
                // informational only, never held, never an orphaned tool op.
                nonToolResults.append(ref)
                continue
            }
            guard ref.state != .intent else {
                throw StoreError.integrity("operation result \(ref.operationID.raw) carries intent state")
            }
            guard results[ref.operationID] == nil else {
                throw StoreError.integrity("duplicate result for operation \(ref.operationID.raw)")
            }
            results[ref.operationID] = (ref, outcome)
            resultOrder.append(ref.operationID)
            toolIDs.insert(ref.operationID)
        default:
            continue
        }
    }
    // Namespace discipline: admission (minted, callID-less) and tool
    // (derived, callID-bearing) IDs must never collide — a collision is
    // corruption, not a coincidence (A3-1: minted IDs never contain "/").
    if !admissionIDs.isDisjoint(with: toolIDs) {
        throw StoreError.integrity("admission/tool operation ID namespace collision")
    }

    var completed: [OperationID] = []
    var explicitUnknown: [OperationRef] = []
    var unmatchedMutating: [OperationRef] = []
    var unmatchedNonMutating: [OperationID] = []
    var orphanResults: [OperationRef] = []
    var held: [OperationRef] = []

    for id in intentOrder {
        let intent = intents[id]!
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
            completed.append(id)
            continue
        }
        // Only `.unknown` reaches here (`.intent` in a result record is
        // rejected above): durable recovery evidence.
        explicitUnknown.append(result.ref)
        // Conservative union: hold if EITHER side claims mutating.
        let heldRef = OperationRef(
            operationID: id, callID: result.ref.callID,
            state: .unknown,
            mutating: intent.mutating || result.ref.mutating)
        if heldRef.mutating {
            held.append(heldRef)
        }
    }
    for id in resultOrder where intents[id] == nil {
        let result = results[id]!
        orphanResults.append(result.ref)
        // No intent to pair with: the operation may have executed with its
        // intent lost. Conservative unknown — hold iff mutating.
        if result.ref.mutating {
            held.append(OperationRef(
                operationID: id, callID: result.ref.callID,
                state: .unknown, mutating: true))
        }
    }

    return OperationReconciliation(
        completed: completed, explicitUnknown: explicitUnknown,
        unmatchedMutating: unmatchedMutating, unmatchedNonMutating: unmatchedNonMutating,
        orphanResults: orphanResults, heldOperations: held,
        admissionIntents: admissionIntents, nonToolResults: nonToolResults.count)
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
