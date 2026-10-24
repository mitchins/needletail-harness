import Foundation
import NeedletailCore

/// B5-B cross-run unresolved-outcome gate (SPEC §9.1, REV25 §4/B5):
/// a new mutating run must not proceed while the durable state store
/// holds unresolved mutating operations from ANY session — unless the
/// operator explicitly acknowledges that risk for THIS run.
///
/// Pure over the `SessionStore` seam: read-only (the gate performs NO
/// writes and introduces NO new store API beyond `sessions()`), bounded
/// session-scoped pagination, existing `reconcileOperations` classifier.
/// An unreadable session ledger throws (fail closed — never treated as
/// clean, and no acknowledgment can cure it); only the CLI assigns exit
/// codes (3 gate trip without authorization, 6 integrity).
public struct CrossSessionHold: Sendable, Equatable {
    /// The dirty session.
    public let session: SessionID
    /// Unknown-state refs seeding the hold: explicit unknowns, unmatched
    /// mutating intents (synthesized unknown refs), held orphans, and
    /// unsuperseded cancelled-pending markers.
    public let heldOperations: [OperationRef]
    /// Subset view: intent-only crashes on mutating operations.
    public let unmatchedMutating: [OperationRef]
    /// `heldOperations` operation IDs, first-seen order, deduped — the
    /// audit subject list recorded on acknowledgment.
    public let operationIDs: [OperationID]

    public init(
        session: SessionID, heldOperations: [OperationRef],
        unmatchedMutating: [OperationRef], operationIDs: [OperationID]
    ) {
        self.session = session
        self.heldOperations = heldOperations
        self.unmatchedMutating = unmatchedMutating
        self.operationIDs = operationIDs
    }
}

public enum CrossRunGate {
    /// Bounded page size for the per-session stream scan (matches the
    /// A3-2 reopen page: history is never loaded wholesale).
    public static let pageLimit = 500

    /// Read-only cross-store scan: enumerate every session, page its
    /// durable stream, classify with `reconcileOperations`. Returns one
    /// hold per session with held operations or unmatched mutating
    /// intents; unmatched NON-mutating intents never block (re-runnable
    /// by design); existing acknowledgments are not evidence of
    /// completion (the classifier already ignores them) and are never
    /// consumed. Throws on corrupt/unreadable ledgers or store I/O
    /// faults — both fail closed upstream.
    public static func unresolvedHolds(store: any SessionStore) throws -> [CrossSessionHold] {
        let ids = try store.sessions()
        var holds: [CrossSessionHold] = []
        for session in ids {
            var stream: [DurableRecord] = []
            var cursor: UInt64 = 0
            while true {
                let (page, next) = try store.records(
                    session: session, since: cursor, limit: pageLimit)
                stream += page.map(\.record)
                guard let advanced = next else { break }
                cursor = advanced
            }
            let report = try reconcileOperations(stream)
            guard !report.heldOperations.isEmpty || !report.unmatchedMutating.isEmpty else {
                continue
            }
            var seen = Set<OperationID>()
            var opIDs: [OperationID] = []
            for ref in report.heldOperations where seen.insert(ref.operationID).inserted {
                opIDs.append(ref.operationID)
            }
            holds.append(CrossSessionHold(
                session: session, heldOperations: report.heldOperations,
                unmatchedMutating: report.unmatchedMutating, operationIDs: opIDs))
        }
        return holds
    }

    /// Commits an explicit operator acknowledgment to the NEW session
    /// under its fenced writer identity and VERIFIES persistence with a
    /// read-back of that session's stream. A flag without this committed
    /// record is not authorization: any append or verification failure
    /// throws (the CLI maps it to exit 6). Original unresolved markers
    /// are preserved — the record adds a decision, erases nothing.
    public static func appendAcknowledgment(
        store: any SessionStore, as identity: WriterIdentity,
        acknowledgment: Acknowledgment
    ) throws {
        try store.append(.acknowledgedUnresolved(acknowledgment), as: identity)
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(
                session: identity.session, since: cursor, limit: pageLimit)
            if page.contains(where: { $0.record == .acknowledgedUnresolved(acknowledgment) }) {
                return
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        throw StoreError.integrity(
            "acknowledgment did not persist; refusing to proceed without a durable decision record")
    }
}
