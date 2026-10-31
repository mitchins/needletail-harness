import Foundation
import Foundation
import NeedletailCore

/// M2-D D3: the single authoritative headless reopening sequence.
///
/// Production startup (and the D3 integration harness) reopens a session
/// through exactly this composition — never through a parallel
/// implementation:
///
/// 1. Open and validate the existing store (the GRDB convenience opens +
///    shape-checks; a corrupt/foreign/future store fails closed there).
/// 2. Establish writer ownership (`claimWriterOwnership`: idempotent for
///    the same writer = crash-recovery re-acquire; a competing live
///    holder throws `.alreadyOwned`). Explicit operator-authorized
///    recovery (`recoverWriterOwnership`) is a separate driver step taken
///    BEFORE this sequence, never a silent branch inside it.
/// 3. Reconstruct session, queue, acknowledgements and effect linkage
///    (`resumeSession`: entries + acks + holds + unknown/failed
///    dispatches, allocator seeded past every durable watermark).
/// 4. Reconcile operations and incomplete undo journals (holds reseeded;
///    no inverse ever re-executes on reopen).
/// 5. Restore attachment snapshots, consent and hold state (carried on the
///    reconstructed queue entries; nothing refetched, nothing downgraded).
/// 6. Materialize required durable workspace-change notices
///    (`recoverUndoJournal`: settled-but-undispositioned journals finalize
///    to disposition + notice, atomically; unknown journals keep holding).
/// 7. Return the live actor plus a blocked/ready report. The driver must
///    not admit, dispatch, checkpoint or undo while `report.blocked` —
///    the actor enforces the same gates transitionally, but startup must
///    not even attempt external effects until recovery is reviewed.
///
/// If any step fails or the report is blocked, the sequence stops before
/// external effects: no silent queue release, no automatic inverse replay,
/// no provider resend. There is exactly one recovery implementation —
/// this function composes `resumeSession` + `recoverUndoJournal`, both of
/// which are also directly unit-testable, and adds no reconciliation
/// logic of its own.
public struct HeadlessReopenReport: Sendable, Equatable {
    /// Reconstructed queue length (all states, in first-admission order).
    public let queueEntries: Int
    /// Any queue hold stands (unknown delivery, failure, stale head,
    /// unknown inverse, unresolved markers).
    public let queueHeld: Bool
    /// Live unknown-operation recovery markers.
    public let unknownOperations: Int
    /// Durable dispositions reseeded into the live idempotency mirror.
    public let dispositionsReseeded: Int
    /// Boundary-5 journals finalized by this reopen's sweep.
    public let journalsRecovered: Int
    /// Settled journals whose finalize was refused (still notice-less).
    public let journalsUnrecovered: Int
    /// True when no admission, dispatch, checkpoint or undo may proceed:
    /// any hold, any unknown, or any unrecovered journal blocks.
    public var blocked: Bool {
        queueHeld || unknownOperations > 0 || journalsUnrecovered > 0
    }

    public init(
        queueEntries: Int, queueHeld: Bool, unknownOperations: Int,
        dispositionsReseeded: Int, journalsRecovered: Int, journalsUnrecovered: Int
    ) {
        self.queueEntries = queueEntries
        self.queueHeld = queueHeld
        self.unknownOperations = unknownOperations
        self.dispositionsReseeded = dispositionsReseeded
        self.journalsRecovered = journalsRecovered
        self.journalsUnrecovered = journalsUnrecovered
    }
}

public func reopenHeadlessSession<
    Transport: ModelTransport, Executor: ToolExecutor, Store: SessionStore,
    Approvals: ApprovalGateway, ClockType: Clock, IDs: IDSource
>(
    store: Store,
    session: SessionID,
    epoch: EpochDescriptor,
    trustMode: TrustMode,
    as writer: String,
    ids: inout IDs,
    clock: ClockType,
    transport: Transport,
    executor: Executor,
    approvals: Approvals,
    sink: any UISink = NoopUISink(),
    execResolver: (any ExecIdentityResolver)? = nil,
    attachmentValidator: (any AttachmentValidator)? = nil,
    undoValidator: (any UndoFileValidator)? = nil,
    inverseApplier: (any UndoInverseApplier)? = nil
) async throws -> (
    actor: SessionActor<Transport, Executor, Store, Approvals, ClockType, IDs>,
    report: HeadlessReopenReport
) {
    // Steps 1-2: fencing first. A competing live holder throws here —
    // no state is built, no actor exists, nothing can dispatch.
    try store.claimWriterOwnership(session: session, writer: writer)
    // Steps 3-5: durable reconstruction (queue, acks, linkage, holds,
    // unknowns, allocator watermark, attachment snapshots + consent).
    let resumed = try resumeSession(
        store: store, session: session, epoch: epoch,
        trustMode: trustMode, as: writer, ids: &ids)
    // Fencing re-claim inside actor construction (same-identity re-acquire
    // is idempotent; a stolen session fails loudly here, never unfenced).
    let actor = try SessionActor(
        state: resumed, ids: ids, clock: clock,
        transport: transport, executor: executor, store: store,
        approvals: approvals, sink: sink, writer: writer,
        execResolver: execResolver,
        attachmentValidator: attachmentValidator,
        undoValidator: undoValidator,
        inverseApplier: inverseApplier)
    // Step 6: materialize boundary-5 notices before any external effect
    // can be attempted on the returned actor. Unknown journals are
    // excluded (they need reconciliation, not a disposition).
    let recovery = try await actor.recoverUndoJournal()
    // Step 7: blocked/ready report over the post-recovery live state.
    let state = await actor.currentState()
    let report = HeadlessReopenReport(
        queueEntries: state.queue.count,
        queueHeld: state.queueHeld,
        unknownOperations: state.unresolvedOperations.count,
        dispositionsReseeded: state.undoDispositions.count,
        journalsRecovered: recovery.recovered.count,
        journalsUnrecovered: recovery.unrecovered.count)
    return (actor, report)
}

/// GRDB convenience: opens (and shape-validates) the store at `storePath`,
/// then runs the single authoritative sequence above. A missing store
/// file fails closed here — `DatabaseQueue` would otherwise CREATE an
/// empty database, letting a "reopen" silently start from nothing. A
/// corrupt/foreign/future store fails closed at open, never overwritten,
/// never silently replaced with memory.
public func reopenHeadlessSessionAtPath<
    Transport: ModelTransport, Executor: ToolExecutor,
    Approvals: ApprovalGateway, ClockType: Clock, IDs: IDSource
>(
    storePath: String,
    session: SessionID,
    epoch: EpochDescriptor,
    trustMode: TrustMode,
    as writer: String,
    ids: inout IDs,
    clock: ClockType,
    transport: Transport,
    executor: Executor,
    approvals: Approvals,
    sink: any UISink = NoopUISink(),
    execResolver: (any ExecIdentityResolver)? = nil,
    attachmentValidator: (any AttachmentValidator)? = nil,
    undoValidator: (any UndoFileValidator)? = nil,
    inverseApplier: (any UndoInverseApplier)? = nil
) async throws -> (
    actor: SessionActor<Transport, Executor, GRDBSessionStore, Approvals, ClockType, IDs>,
    report: HeadlessReopenReport
) {
    guard FileManager.default.fileExists(atPath: storePath) else {
        throw StoreError.integrity("no store at \(storePath): reopen refuses to create one")
    }
    let store = try GRDBSessionStore(path: storePath)
    return try await reopenHeadlessSession(
        store: store, session: session, epoch: epoch, trustMode: trustMode,
        as: writer, ids: &ids, clock: clock, transport: transport,
        executor: executor, approvals: approvals, sink: sink,
        execResolver: execResolver,
        attachmentValidator: attachmentValidator,
        undoValidator: undoValidator,
        inverseApplier: inverseApplier)
}
