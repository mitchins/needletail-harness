/// M2-D D0: the single production entry point for reopening a session
/// from its durable store. Composes, in order: writer-fencing claim,
/// session-scoped record paging, operation reconciliation, queue
/// reconstruction (entries, acks with retention bound, holds, unknown and
/// failed dispatches), ID-allocator seeding past the durable high-water
/// mark, and idle-state assembly.
///
/// Contract:
/// - Fencing is respected, not bypassed: the caller names the writer it
///   resumes as; `claimWriterOwnership` is idempotent for the same writer
///   (crash recovery re-acquire) and throws `.alreadyOwned` for a live
///   different writer — a competing owner fails here, before any state.
/// - Any malformed, duplicate, contradictory, or incomplete replay
///   evidence throws `.integrity` via the reconciler (fail closed).
/// - No provider or tool dispatch can happen before this function
///   returns: there is no actor yet, and the returned state carries no
///   live reservations — dispatch requires a fresh admission afterwards.
/// - The allocator is advanced past every sequence the log contains, so
///   post-reopen admissions can never collide with replayed entry IDs
///   (which would fail the next reconcile as duplicates).
/// - The CLI keeps creating fresh sessions; no CLI resume command is
///   required. Cross-session visibility stays with `CrossRunGate`.
public func resumeSession<IDs: IDSource>(
    store: any SessionStore,
    session: SessionID,
    epoch: EpochDescriptor,
    trustMode: TrustMode,
    as writer: String,
    ids: inout IDs
) throws -> SessionState {
    try store.claimWriterOwnership(session: session, writer: writer)
    var stream: [DurableRecord] = []
    var cursor: UInt64 = 0
    var highWater: UInt64 = 0
    while true {
        let (page, next) = try store.records(session: session, since: cursor, limit: 500)
        for rec in page {
            highWater = max(highWater, rec.sequence.value)
            stream.append(rec.record)
        }
        guard let advanced = next else { break }
        cursor = advanced
    }
    let report = try reconcileOperations(stream)
    let recon = try reconcileQueue(stream)
    for entry in recon.entries {
        highWater = max(highWater, entry.orderKey)
    }
    ids.advance(past: highWater)
    var state = SessionState.resumedAfterReopen(
        sessionID: session, epoch: epoch, trustMode: trustMode,
        heldOperations: report.heldOperations)
    let heldCount = recon.entries.filter { $0.state == .held }.count
    var held: HoldReason?? = state.heldReason
    if case .none = held, recon.queueHeld {
        let heldCount = recon.entries.filter { $0.state == .held }.count
        held = .some(.error("reopen: \(recon.unknownLinks.count) uncompleted dispatch(es), \(recon.failedLinks.count) failed dispatch(es), \(heldCount) held"))
    }
    return state.replacing(
        queue: recon.entries,
        queueHeld: state.queueHeld || recon.queueHeld, heldReason: held,
        admittedCommands: recon.acks)
}
