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
/// Highest counter-derived numeric ID in a session-scoped record
/// stream: eventAppended sequence numbers, queue orderKeys and entry-ID
/// suffixes (`q-<n>`), change-group IDs (`chg-<n>`), undo-command sequence
/// numbers (`undo-<n>`, from derived inverse IDs and dispositions) and
/// fork IDs (`fork-<n>`). Non-numeric or foreign-prefixed IDs contribute
/// nothing (never parsed, never minted past — a corrupt shape fails
/// closed at decode, not here).
public func durableIDHighWater(_ records: [DurableRecord]) -> UInt64 {
    var mark: UInt64 = 0
    func foldPrefixed(_ raw: String, prefix: String) {
        guard raw.hasPrefix(prefix),
              let value = UInt64(raw.dropFirst(prefix.count)) else { return }
        mark = max(mark, value)
    }
    for record in records {
        switch record {
        case .eventAppended(let seq, _, _):
            mark = max(mark, seq.value)
        case .queueAdmitted(let entry), .queueUpdated(let entry):
            mark = max(mark, entry.orderKey)
            foldPrefixed(entry.entryID, prefix: "q-")
        case .operationIntent(let ref),
             .operationResult(let ref, _),
             .cancelledPendingMarker(let ref, _):
            if let parsed = parseUndoInverseID(ref.operationID.raw) {
                mark = max(mark, undoCommandSequence(parsed.command))
            }
        case .undoDisposition(let disposition):
            mark = max(mark, undoCommandSequence(disposition.undoCommandID))
        case .changeGroup(let group):
            foldPrefixed(group.groupID, prefix: "chg-")
        case .lineageFork(let fork):
            foldPrefixed(fork.forkID, prefix: "fork-")
        default:
            break
        }
    }
    return mark
}

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
    // M2-D D3 (CodeRabbit): the watermark must cover every
    // counter-derived identity, not just envelope sequences and queue
    // order keys. Group ("chg-<n>"), undo-command ("undo-<n>") and fork
    // ("fork-<n>") IDs all mint from the shared ID counter, as do the
    // eventAppended sequence numbers — but none of them is an envelope
    // sequence or an orderKey, so envelope/orderKey alone can reseed the
    // counter BELOW a durable ID and a post-reopen mint can collide with
    // it (duplicate group swallowed by first-wins reconcile; duplicate
    // undo command returning another command's recorded disposition).
    // Folding every numeric suffix keeps post-reopen mints strictly above
    // durable ones.
    highWater = max(highWater, durableIDHighWater(stream))
    // M2-D D2: reseed the bounded live disposition mirror from the durable
    // journal (never deleted from the log — only this mirror prunes) and
    // hold every inverse whose intent committed without a settled result.
    // No inverse ever re-executes on reopen: unknown refs hold the queue
    // until explicit reconciliation.
    let (undoEntries, unknownInverses) = reconcileUndoJournal(stream)
    var dispositions = undoEntries.values.compactMap(\.disposition)
    // Prune by numeric command suffix (undo-<n> mints from the shared
    // sequence counter, so higher is newer), never lexicographically
    // ("undo-10" sorts before "undo-9" as strings).
    dispositions.sort {
        undoCommandSequence($0.undoCommandID) < undoCommandSequence($1.undoCommandID)
    }
    if dispositions.count > maxUndoDispositions {
        dispositions.removeFirst(dispositions.count - maxUndoDispositions)
    }
    var heldOperations = report.heldOperations
    // Dedupe by operation ID: an intent-only mutating inverse is held by
    // BOTH the durable classifier (unmatched mutating) and the journal
    // (intent without result) — one marker, never two, and the bound
    // counts distinct operations only.
    var heldIDs = Set(heldOperations.map(\.operationID))
    for ref in unknownInverses {
        guard !heldIDs.contains(ref.operationID) else { continue }
        guard heldOperations.count < maxUnresolvedOperations else {
            throw StoreError.integrity(
                "reopen: unknown inverse backlog exceeds unresolved bound")
        }
        heldOperations.append(ref)
        heldIDs.insert(ref.operationID)
    }
    ids.advance(past: highWater)
    var state = SessionState.resumedAfterReopen(
        sessionID: session, epoch: epoch, trustMode: trustMode,
        heldOperations: heldOperations)
    // Hold reason: an existing unresolved-operations reason wins (more
    // urgent); otherwise a queue hold gets an explicit reopen reason.
    // (Tested: `state.heldReason` here is `HoldReason?`, so a plain nil
    // check applies — do NOT lift to `HoldReason??` first, as `.some(nil)`
    // would make a `case .none` match unreachable.)
    var heldReason: HoldReason? = state.heldReason
    if heldReason == nil, recon.queueHeld {
        heldReason = .error("reopen: \(recon.unknownLinks.count) uncompleted dispatch(es), \(recon.failedLinks.count) failed, \(recon.entries.filter { $0.state == .held }.count) held")
    }
    if heldReason == nil, !unknownInverses.isEmpty {
        heldReason = .error("reopen: \(unknownInverses.count) unsettled undo inverse(s); reconcile before dispatch")
    }
    return state.replacing(
        queue: recon.entries,
        queueHeld: state.queueHeld || recon.queueHeld || !unknownInverses.isEmpty,
        heldReason: heldReason,
        admittedCommands: recon.acks,
        undoDispositions: dispositions)
}
