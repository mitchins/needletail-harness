/// M1-B session actor (SPEC §4.1, ARCH §§1–2). ONE authoritative actor per
/// session: it serializes admission, reservations, queue acknowledgements
/// and completion acceptance. At most one foreground async operation runs
/// per session (transport during requesting/streaming, gateway during
/// authorising, executor during executing — a single `inFlight` slot).
/// The actor owns NO business logic — every decision is the pure
/// `transition` function; the actor stamps IDs/time, appends records,
/// performs effects, and pairs payload-only results with its pre-await
/// reservation table (R9). Swift Task cancellation is delivery only:
/// invalidation is the generation bump. Effect tasks are NEVER awaited
/// inline — `handle` always returns promptly so `cancel` can interleave.
public struct RawProviderRecord: Sendable, Equatable {
    public let requestID: RequestID
    public let rawBody: [UInt8]
    public let returnedModel: String?
    public let usageInput: Int?
    public let usageOutput: Int?

    public init(requestID: RequestID, rawBody: [UInt8], returnedModel: String? = nil, usageInput: Int? = nil, usageOutput: Int? = nil) {
        self.requestID = requestID
        self.rawBody = rawBody
        self.returnedModel = returnedModel
        self.usageInput = usageInput
        self.usageOutput = usageOutput
    }
}

public actor SessionActor<Transport: ModelTransport, Executor: ToolExecutor, Store: SessionStore, Approvals: ApprovalGateway, ClockType: Clock, IDs: IDSource> {
    private var state: SessionState
    private var ids: IDs
    private let clock: ClockType
    private var transport: Transport
    private let executor: Executor
    private let store: Store
    private let approvals: Approvals
    private let sink: any UISink
    /// Durable-mutation writer identity (A2 fencing): identifies THIS live
    /// actor instance; the session side comes from the actor's state.
    private let writer: String
    /// Reservation table (effectID → reservation), captured pre-await.
    /// An entry is removed when its run is cancelled (after C3 retention
    /// records) or when its completion is first accepted (R3).
    private var reservations: [EffectID: EffectReservation] = [:]
    private var cancelledPending: [EffectID: EffectReservation] = [:]
    private var inFlight: Task<Void, Never>?
    private var deltaDelivery: DeltaDeliveryQueue?
    private var deltaDeliveryTask: Task<Void, Never>?
    /// Live deadline timers keyed by purpose + run (M1-D real scheduling).
    /// Separate from inFlight: the cancel-grace timer must SURVIVE cancel()
    /// (it implements the grace), while provider/approval flights die.
    /// Fired-or-cancelled entries are removed; stale fires drop on the
    /// generation check, so overwrites can never double-dispatch.
    private var timerTasks: [String: Task<Void, Never>] = [:]
    /// Session-scoped raw provider ring (M1-D D5, M1C3-4). Bounded by count
    /// (8) and bytes (16 MiB); evict-oldest on overflow. Native fidelity,
    /// separate from display output, never logged.
    private var rawRing: [RawProviderRecord] = []
    private var rawRingBytes: Int = 0
    private var rawRingMaxCount: Int { 8 }
    private var rawRingMaxBytes: Int { 16 * 1024 * 1024 }
    /// M2-C C0 (plan REV12 §3.4b.1): the injected identity resolver.
    private let execResolver: (any ExecIdentityResolver)?

    /// M2-D D1: the composed attachment validator (Runtime filesystem
    /// validator in production; scripted/temp-fs in tests). Nil means
    /// uncomposed: validation requests stamp empty observations and the
    /// transition holds fail-closed.
    private let attachmentValidator: (any AttachmentValidator)?

    /// Throws when the fencing claim cannot be established: constructing a
    /// live writer against a session held by a DIFFERENT writer is a loud
    /// failure, never a silently unfenced actor.
    public init(
        state: SessionState, ids: IDs, clock: ClockType,
        transport: Transport, executor: Executor, store: Store, approvals: Approvals,
        sink: any UISink = NoopUISink(), writer: String,
        execResolver resolver: (any ExecIdentityResolver)? = nil,
        attachmentValidator: (any AttachmentValidator)? = nil
    ) throws {
        self.state = state
        self.ids = ids
        self.clock = clock
        self.transport = transport
        self.executor = executor
        self.store = store
        self.approvals = approvals
        self.sink = sink
        self.writer = writer
        self.execResolver = resolver
        self.attachmentValidator = attachmentValidator
        // A2 fencing: this live actor instance establishes its writer
        // identity BEFORE any durable mutation. Idempotent for a same-
        // identity restart; a competing live writer fails here, loudly —
        // never silently unfenced.
        try store.claimWriterOwnership(session: state.sessionID, writer: writer)
    }

    public var rawRecords: [RawProviderRecord] { rawRing }

    private func appendRawRecord(_ record: RawProviderRecord) {
        rawRing.append(record)
        rawRingBytes += record.rawBody.count
        while rawRing.count > rawRingMaxCount || rawRingBytes > rawRingMaxBytes {
            guard let removed = rawRing.first else { break }
            rawRingBytes -= removed.rawBody.count
            rawRing.removeFirst()
            // Single record larger than the byte cap is kept (already
            // bounded by SSE stream cap 16 MiB); eviction stops after it.
            if rawRing.count == 1 && rawRingBytes <= rawRingMaxBytes { break }
        }
    }

    public func currentState() -> SessionState { state }

    // MARK: Operator entry points (stamp, then apply)

    public func submitText(commandID: CommandID, text: String, kind: QueueKind, sealed: Bool) async {
        await apply(.operatorInput(
            commandID: commandID, text: text, kind: kind, revision: 1,
            sealed: sealed, atMillis: clock.nowMillis()))
    }

    /// M2-D D1: operator input carrying authorized attachment snapshots
    /// (captured by Runtime before stamping — the actor never reads files).
    public func submitTextWithAttachments(commandID: CommandID, text: String, kind: QueueKind, sealed: Bool, attachments: [AttachmentSnapshot]) async {
        await apply(.operatorInputAttachments(
            commandID: commandID, text: text, kind: kind,
            sealed: sealed, attachments: attachments, atMillis: clock.nowMillis()))
    }

    /// M2-D D1: explicit operator replacement of an entry's snapshots.
    public func replaceEntryAttachments(entryID: String, snapshots: [AttachmentSnapshot]) async {
        await apply(.queueAttachmentReplace(entryID: entryID, snapshots: snapshots, atMillis: clock.nowMillis()))
    }

    public func editEntry(entryID: String, newText: String, baseRevision: UInt64) async {
        await apply(.queueEdit(entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: clock.nowMillis()))
    }

    public func withdrawEntry(entryID: String) async {
        await apply(.queueWithdraw(entryID: entryID, atMillis: clock.nowMillis()))
    }

    public func resumeQueue() async {
        await apply(.queueResume(atMillis: clock.nowMillis()))
    }

    public func retargetQueueEntry(entryID: String) async {
        await apply(.queueRetarget(entryID: entryID, atMillis: clock.nowMillis()))
    }

    public func reconcileQueue(entryID: String) async {
        await apply(.queueReconcile(entryID: entryID, atMillis: clock.nowMillis()))
    }

    public func cancel() async {
        await apply(.cancelRequested(atMillis: clock.nowMillis()))
        inFlight?.cancel()
    }

    public func dismissRun() async {
        await apply(.dismissRun(atMillis: clock.nowMillis()))
    }

    public func switchModel(alias: String) async {
        await apply(.switchModel(alias: alias, atMillis: clock.nowMillis()))
    }

    public func requestCheckpoint() async {
        await apply(.checkpointRequested(atMillis: clock.nowMillis()))
    }

    public func tick() async {
        await apply(.tick(nowMillis: clock.nowMillis()))
    }

    /// Explicit-time tick (tests, replays). Production timers call `tick()`.
    public func tick(at nowMillis: UInt64) async {
        await apply(.tick(nowMillis: nowMillis))
    }

    /// C0 replay/test seam (plan REV12 §3.4b.5): drive a stamped event
    /// through the SAME transition path — a replayed resolution reply must
    /// drop as stale via checkStale.
    public func applyExternalEvent(_ event: SessionEvent) async {
        await apply(event)
    }

    /// Invalid/denied input note (M1-D CLI feeds parse failures here;
    /// tests drive CORE-03 through it).
    public func noteInvalidInput(fingerprint: String, cause: String) async {
        await apply(.invalidInput(fingerprint: fingerprint, cause: cause, atMillis: clock.nowMillis()))
    }

    public func decideApproval(_ decision: ApprovalDecision, requestID: RequestID, generation: Revision) async {
        switch decision {
        case .approve:
            await apply(.approvalGrant(requestID: requestID, generation: generation, atMillis: clock.nowMillis()))
        case .deny(let reason):
            await apply(.approvalDeny(requestID: requestID, generation: generation, reason: reason, atMillis: clock.nowMillis()))
        case .unavailable(let reason):
            await apply(.approvalUnavailable(requestID: requestID, generation: generation, reason: reason, atMillis: clock.nowMillis()))
        }
    }

    // MARK: Core loop

    private func apply(_ event: SessionEvent) async {
        let prior = state
        let result = transition(state, event, &ids)
        state = result.state
        // S2 + A3-1: the transition's whole record group commits ATOMICALLY
        // before ANY effect performs — cause precedes consequence, and an
        // intent group either commits whole (dispatch may proceed) or not
        // at all (no external side effect exists). A failed RESULT commit
        // after a possible side effect stops here: no success asserted, no
        // continuation performed — the earlier-committed intents stand
        // alone, which is exactly the evidence later reconciliation needs
        // to classify them unknown.
        do {
            if !result.records.isEmpty {
                try store.appendBatch(result.records, as: WriterIdentity(
                    session: state.sessionID, writer: writer))
            }
        } catch {
            // Integrity-visible halt (never silent divergence): the computed
            // records are unpersisted, so the run cannot continue on them.
            // M2 owns recovery; M1-B fails the run visibly here.
            // A3-1: the reason is classified from the UNPERSISTED GROUP, not
            // the event kind — any group carrying an operation result (done
            // completions, failure receipts, cancel/ambiguous unknowns)
            // means a possible side effect's outcome is now unresolved,
            // while a pure intent group means nothing executed yet.
            let leftResultUnpersisted = result.records.contains {
                switch $0 {
                case .operationResult, .cancelledPendingMarker, .cancelledPendingError: return true
                default: return false
                }
            }
            let reason = leftResultUnpersisted
                ? "store append failed; result unpersisted, outcome unresolved"
                : "store append failed; intent unpersisted"
            if leftResultUnpersisted {
                // Unpersisted MUTATING results are possible side effects
                // with no durable outcome: each becomes an unknown marker
                // (bounded like every other marker site) and the queue
                // holds, so a later fresh admission cannot silently proceed
                // past them (admitFreshRun blocks on unresolvedOperations,
                // and the terminal-phase reset to idle does not clear
                // markers). Non-mutating results (read-only outcomes,
                // callID-less denial receipts) carry no side effect: the
                // durable classifier treats them as re-runnable, so they
                // take no markers — and with no markers the run fails
                // plainly instead of holding an empty queue. An
                // intent-only group means nothing executed: failed phase
                // alone, no markers. Volatile run fields are cleared like
                // failRun: nothing resumes behind the held queue.
                var markers = prior.unresolvedOperations
                for record in result.records {
                    let ref: OperationRef?
                    switch record {
                    case .operationResult(let r, _): ref = r.mutating ? r : nil
                    case .cancelledPendingMarker(let r, _): ref = r.mutating ? r : nil
                    default: ref = nil
                    }
                    guard let ref = ref else { continue }
                    guard markers.count < maxUnresolvedOperations else { break }
                    markers.append(OperationRef(
                        operationID: ref.operationID, callID: ref.callID,
                        state: .unknown, mutating: ref.mutating))
                }
                if markers.count > prior.unresolvedOperations.count {
                    state = prior.replacing(
                        phase: .failed(.integrityStopped(reason)),
                        activeRun: .some(nil), activeRequest: .some(nil),
                        queueHeld: true, heldReason: .error(reason),
                        pendingApproval: .some(nil), pendingBatch: .some(nil),
                        pendingResolution: .some(nil), pendingExecIdentities: .some(nil),
                        retryDeadlineMillis: .some(nil),
                        liveReservations: [],
                        unresolvedOperations: markers)
                } else {
                    state = prior.replacing(phase: .failed(.integrityStopped(reason)), pendingResolution: .some(nil), pendingExecIdentities: .some(nil))
                }
            } else {
                state = prior.replacing(phase: .failed(.integrityStopped(reason)), pendingResolution: .some(nil), pendingExecIdentities: .some(nil))
            }
            return
        }
        for effect in result.effects {
            if case .reserveEffect(let reservation) = effect {
                reservations[reservation.effectID] = reservation
            }
        }
        if case .cancelRequested = event {
            // REV25: retain mutating executor reservations in cancelledPending, mirroring state.
            for (id, res) in reservations where res.kind == .executor {
                let hasMutating = res.batch.proposals.contains { $0.tool != "read" && $0.tool != "search" && $0.tool != "consult" } || (res.batch.proposals.isEmpty && res.mutating)
                if hasMutating {
                    cancelledPending[id] = res
                }
            }
            reservations = [:]
            inFlight?.cancel()
        }
        for effect in result.effects {
            await perform(effect)
        }
        // Pump pure follow-ups: a validatingTools landing carries its batch
        // in state, so validation completes deterministically without a new
        // async edge (bounded — validationCompleted always leaves the phase).
        for _ in 0..<4 {
            guard case .validatingTools = state.phase,
                  let batch = state.pendingBatch,
                  let run = state.activeRun
            else { break }
            await apply(.validationCompleted(
                requestID: run.requestID, generation: run.revision,
                batch: batch, atMillis: clock.nowMillis()))
        }
    }

    private func perform(_ effect: Effect) async {
        switch effect {
        case .reserveEffect(let reservation):
            // Recorded above (no I/O). A NON-EMPTY batch is a dispatchable
            // tool batch (M1-D): exactly one executor call under the
            // generation/revision check, paired through completeEffect /
            // failEffect. Empty-batch reservations (provider retries) stay
            // record-only. The executing phase admits no transport flight,
            // so the inFlight slot is free here — and cancelRequested drops
            // whichever action is live through the same slot.
            guard !reservation.batch.proposals.isEmpty else { break }
            guard reservations[reservation.effectID] != nil else { return }
            inFlight?.cancel()
            inFlight = Task {
                await self.invokeExecutor(reservation: reservation)
            }
        case .emitUI(let projection):
            // M2-C C3: a late run:tool-exec must never land after the
            // terminal run_finished (a deferred cancellation/completion can
            // otherwise reorder the stream and flip UI back to busy). Only
            // the tool-exec kind is suppressed post-terminal: every other
            // terminal-adjacent projection (denied/run:completed/run:failed
            // etc.) is part of the terminal transition itself and must
            // still be delivered.
            if state.phase.isTerminal, projection.kind == "run:tool-exec" { break }
            do {
                try await sink.emit(projection)
            } catch {
                await handleSinkError(error)
            }
        case .requestProvider(let invocation):
            guard reservations[invocation.effectID] != nil else { return }
            // Only admission requests count busy work; stale/denial dispatches
            // must not increment requesting latency or be treated as drops.
            if case .admitting = state.phase {
                await apply(.requestDispatched(requestID: invocation.requestID, atMillis: clock.nowMillis()))
            }
            guard let reservation = reservations[invocation.effectID] else { return }
            inFlight?.cancel()
            inFlight = Task {
                await self.invokeTransport(invocation: invocation, reservation: reservation)
            }
        case .requestApproval(let request):
            inFlight?.cancel()
            inFlight = Task {
                let decision = await self.approvals.decide(request)
                await self.decideApproval(decision, requestID: request.requestID, generation: request.generation)
            }
        case .resolveExecIdentities(let resolutionID, let batch):
            guard state.pendingResolution?.resolutionID == resolutionID else { return }
            let identities: [ResolvedExecIdentity]
            do {
                if let resolver = execResolver {
                    identities = try resolver.resolveIdentities(batch: batch)
                } else {
                    throw ExecResolutionError.unavailable("resolution unavailable: no identity resolver composed")
                }
                let expected = Set(batch.proposals.filter { $0.tool == "exec" }.map(\.callID))
                let got = Set(identities.map(\.callID))
                guard expected == got, identities.count == expected.count else {
                    throw ExecResolutionError.unavailable("resolver reply does not match the batch exec callIDs")
                }
            } catch let error as ExecResolutionError {
                await apply(.execResolutionFailed(
                    resolutionID: resolutionID, runID: state.activeRun?.runID ?? RunID("none"),
                    generation: state.activeRun?.revision ?? Revision(0),
                    status: error.preDispatchStatus, summary: error.preDispatchSummary,
                    atMillis: clock.nowMillis()))
                return
            } catch {
                let mapped = ExecResolutionError.unavailable("resolver failure: \(error)")
                await apply(.execResolutionFailed(
                    resolutionID: resolutionID, runID: state.activeRun?.runID ?? RunID("none"),
                    generation: state.activeRun?.revision ?? Revision(0),
                    status: mapped.preDispatchStatus, summary: mapped.preDispatchSummary,
                    atMillis: clock.nowMillis()))
                return
            }
            guard let run = state.activeRun else { return }
            await apply(.execIdentitiesResolved(
                resolutionID: resolutionID, runID: run.runID, generation: run.revision,
                identities: identities, atMillis: clock.nowMillis()))
        case .validateAttachments(let entryID, let snapshots):
            // M2-D D1: freshness evidence is gathered by the composed
            // validator (filesystem I/O the pure transition cannot do) and
            // stamped onto the result event. Uncomposed validator (nil) or
            // an empty reply stamps empty observations — the transition
            // holds fail-closed on missing evidence.
            let observations = await attachmentValidator?.validate(entryID: entryID, snapshots: snapshots) ?? []
            await apply(.attachmentValidationResult(
                entryID: entryID, requested: snapshots,
                observations: observations, atMillis: clock.nowMillis()))
        case .cancelInFlight:
            inFlight?.cancel()
        case .startTimer(let deadlineMillis, let purpose, let runID):
            scheduleTimer(deadlineMillis: deadlineMillis, purpose: purpose, runID: runID)
        case .cancelTimer(let purpose, let runID):
            cancelTimer(purpose: purpose, runID: runID)
        }
    }

    /// Display deltas (D4) leave the actor as fire-and-forget tasks so the
    /// NIO delegate never blocks. A sink failure must still be observed by
    /// the session — never swallowed — so the SAME recovery path used for
    /// authoritative projections applies.
    private func emitDeltaProjection(_ projection: SessionEventProjection) async {
        do {
            try await sink.emit(projection)
        } catch {
            await handleSinkError(error)
        }
    }

    /// Closed consumer → cancel the run (§12.2 exit 130). Bounded overflow
    /// or any underlying sink failure → honest integrity stop; display
    /// deltas are hints and must never silently replace authoritative events.
    private func handleSinkError(_ error: Error) async {
        if case UISinkError.brokenPipe = error {
            await apply(.cancelRequested(atMillis: clock.nowMillis()))
            inFlight?.cancel()
            return
        }
        await apply(.cancelRequested(atMillis: clock.nowMillis()))
        inFlight?.cancel()
        reservations = [:]
        state = state.replacing(phase: .failed(.integrityStopped("sink emit failed: \(error)")), pendingResolution: .some(nil), pendingExecIdentities: .some(nil))
    }

    private func invokeTransport(invocation: ProviderInvocation, reservation: EffectReservation) async {
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        // Wire incremental deltas through a single bounded delivery queue
        // (H1): ordered by arrival, one consumer emits through the sink,
        // overflow is an honest UISinkError rather than unbounded tasks.
        let deliveryQueue = DeltaDeliveryQueue(
            itemCap: 512, byteCap: 4 << 20, onDeliver: { item in
                await self.emitDeltaProjection(.delta(requestID: item.requestID, text: item.text))
            })
        deltaDelivery = deliveryQueue
        let deliveryTask = Task { @Sendable in
            await deliveryQueue.run()
        }
        deltaDeliveryTask = deliveryTask
        var activeTransport: Transport = transport
        if var deltaTransport = transport as? any DeltaStreamingTransport {
            let requestID = invocation.requestID
            deltaTransport.deltaSink = { text in
                switch deliveryQueue.enqueue(DeltaDeliveryQueue.Item(requestID: requestID, text: text)) {
                case .closed:
                    break
                case .overflow(let itemCount, let byteCount):
                    deliveryQueue.finish()
                    Task { await self.handleSinkError(UISinkError.overflow(itemCount: itemCount, byteCount: byteCount)) }
                case .accepted:
                    break
                }
            }
            if let cast = deltaTransport as? Transport {
                activeTransport = cast
            }
        }
        do {
            let result = try await activeTransport.invoke(invocation, intake: intake)
            // Raw ring (D5): bounded, native-fidelity, separate from display
            if let raw = result.rawBody {
                appendRawRecord(RawProviderRecord(
                    requestID: invocation.requestID, rawBody: raw,
                    returnedModel: result.response.returnedModel,
                    usageInput: result.response.usageInput,
                    usageOutput: result.response.usageOutput))
            }
            deliveryQueue.finish()
            await deliveryTask.value
            if deltaDelivery === deliveryQueue { deltaDelivery = nil }
            await pairTransportResult(result, reservation: reservation)
        } catch is CancellationError {
            deliveryQueue.finish()
            await deliveryTask.value
            if deltaDelivery === deliveryQueue { deltaDelivery = nil }
            return // Generation invalidation already dropped this run; nothing to pair.
        } catch let failure as TransportFailure {
            deliveryQueue.finish()
            await deliveryTask.value
            if deltaDelivery === deliveryQueue { deltaDelivery = nil }
            // Classified at the failure site by the adapter (R2); the
            // transition policy stays the sole retry authority.
            await apply(.transportFailed(
                requestID: invocation.requestID, generation: invocation.generation,
                phase: failure.phase, error: failure.message, atMillis: clock.nowMillis()))
        } catch {
            deliveryQueue.finish()
            await deliveryTask.value
            if deltaDelivery === deliveryQueue { deltaDelivery = nil }
            await apply(.transportFailed(
                requestID: invocation.requestID, generation: invocation.generation,
                phase: .ambiguous, error: String(describing: error), atMillis: clock.nowMillis()))
        }
    }

    /// Pairs a payload-only result with the pre-await reservation (R9) and
    /// builds stamped events FROM THE RESERVATION: `requestStarted` first
    /// (stream opened), then the `providerResponse` (data). Unknown
    /// effectIDs drop here — no event is ever built for them.
    private func pairTransportResult(_ result: TransportResult, reservation: EffectReservation) async {
        guard reservations[reservation.effectID] != nil else { return }
        guard let requestID = reservation.requestID else { return }
        await apply(.requestStarted(
            requestID: requestID, generation: reservation.generation, atMillis: clock.nowMillis()))
        await apply(.providerResponse(
            requestID: requestID, generation: reservation.generation,
            response: result.response, atMillis: clock.nowMillis()))
    }

    private func timerKey(purpose: String, runID: RunID) -> String {
        "\(purpose)#\(runID.raw)"
    }

    /// Real deadline scheduling (M1-D): sleeps until the deadline, then
    /// applies a stamped tick ONLY if the same run generation is still
    /// active (stale fires drop — overwrites and completions can never
    /// double-dispatch; deadline evaluation itself stays in the pure
    /// transition via checkDeadline). Virtual-clock tests see real-time
    /// delays derived from frozen stamps; the tick is stamped at the
    /// DEADLINE (not the frozen now) so the deadline check `now >= deadline`
    /// actually fires. Explicit tick(at:) tests remain deterministic because
    /// deadline consumption is state-idempotent.
    private func scheduleTimer(deadlineMillis: UInt64, purpose: String, runID: RunID) {
        let key = timerKey(purpose: purpose, runID: runID)
        timerTasks[key]?.cancel()
        let generation = state.activeRun?.revision
        // Cap the sleep: far-future deadlines must not overflow the
        // nanosecond conversion, and a stale task must not sleep forever.
        let now = clock.nowMillis()
        let delayMillis = min(deadlineMillis > now ? deadlineMillis - now : 0, 3_600_000)
        timerTasks[key] = Task {
            try? await Task.sleep(nanoseconds: delayMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            let current = await self.currentGeneration(runID: runID)
            guard !Task.isCancelled, current == generation else { return }
            await self.applyTick(at: deadlineMillis)
        }
    }

    private func cancelTimer(purpose: String, runID: RunID) {
        let key = timerKey(purpose: purpose, runID: runID)
        timerTasks[key]?.cancel()
        timerTasks.removeValue(forKey: key)
    }

    private func currentGeneration(runID: RunID) -> Revision? {
        guard let run = state.activeRun, run.runID == runID else { return nil }
        return run.revision
    }

    private func applyTick(at millis: UInt64? = nil) async {
        let now = millis.map { max(clock.nowMillis(), $0) } ?? clock.nowMillis()
        await apply(.tick(nowMillis: now))
    }

    /// Production executor dispatch (M1-D): exactly one `execute` call per
    /// batch reservation. Generation/revision pairing happens in
    /// completeEffect/failEffect (stale outcomes drop).
    private func invokeExecutor(reservation: EffectReservation) async {
        defer {
            let stillPending = cancelledPending[reservation.effectID] != nil || state.cancelledPendingReservations.contains(where: { $0.effectID == reservation.effectID })
            reservations.removeValue(forKey: reservation.effectID)
            cancelledPending.removeValue(forKey: reservation.effectID)
            if stillPending {
                Task { await self.apply(.cancelledPendingRemoved(effectID: reservation.effectID, atMillis: self.clock.nowMillis())) }
            }
        }
        do {
            let result = try await executor.execute(batch: reservation.batch, reservation: reservation)
            await self.completeEffect(reservation.effectID, outcome: .perCall(result))
        } catch let err as ToolFailure {
            // Actor-verified pre-dispatch failure: typed, not arbitrary ToolCallOutcome data
            await self.completeEffect(reservation.effectID, outcome: .preDispatchFailure(err))
        } catch is CancellationError {
            // Synthesize per-call cancelled with started==true for every proposal (fail-closed fallback)
            let calls = reservation.batch.proposals.map { ToolCallOutcome(callID: $0.callID, status: "cancelled", summary: "cancelled: fallback", data: "", started: true) }
            let receipt = ExecutorReceipt(callID: reservation.effectID.raw, status: "cancelled", summary: "cancelled")
            let synth = ExecutorResult(receipt: receipt, calls: calls)
            await self.completeEffect(reservation.effectID, outcome: .perCall(synth))
            return
        } catch {
            // Untyped throw → per-call unknown+hold for mutating (must not be done). Synthesize timeout+started true which the reducer treats as unknown for mutating.
            let calls = reservation.batch.proposals.map { prop in
                let isMutating = prop.tool != "read" && prop.tool != "search" && prop.tool != "consult"
                if isMutating {
                    return ToolCallOutcome(callID: prop.callID, status: "timeout", summary: "untyped throw: \(error)", data: "", error: "\(error)", started: true)
                } else {
                    return ToolCallOutcome(callID: prop.callID, status: "timeout", summary: "untyped throw", data: "", started: true)
                }
            }
            let receipt = ExecutorReceipt(callID: reservation.effectID.raw, status: "timeout", summary: "untyped throw")
            let synth = ExecutorResult(receipt: receipt, calls: calls)
            await self.completeEffect(reservation.effectID, outcome: .perCall(synth))
        }
    }

    /// Executor completion entry point. M1-B tests pair explicitly (calling
    /// this directly) to control cancel-vs-completion orderings
    /// deterministically; scripted fakes never auto-complete. M1-D wires
    /// production execution through `invokeExecutor` above, pairing through
    /// this same entry point.
    public func completeEffect(_ effectID: EffectID, outcome: EffectOutcome) async {
        guard let reservation = reservations[effectID] ?? cancelledPending[effectID] else { return }
        // Prune from both tables after forwarding (R3)
        reservations.removeValue(forKey: effectID)
        cancelledPending.removeValue(forKey: effectID)
        await apply(.effectCompleted(
            effectID: effectID,
            runID: reservation.runID, generation: reservation.generation,
            expectedRevision: reservation.revision, mutating: reservation.mutating,
            outcome: outcome, atMillis: clock.nowMillis()))
    }

    public func failEffect(_ effectID: EffectID, error: String) async {
        guard let reservation = reservations[effectID] ?? cancelledPending[effectID] else { return }
        reservations.removeValue(forKey: effectID)
        cancelledPending.removeValue(forKey: effectID)
        await apply(.effectFailed(
            effectID: effectID,
            runID: reservation.runID, generation: reservation.generation,
            expectedRevision: reservation.revision, mutating: reservation.mutating,
            error: error, atMillis: clock.nowMillis()))
    }
}
