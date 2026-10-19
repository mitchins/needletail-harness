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

    /// Throws when the fencing claim cannot be established: constructing a
    /// live writer against a session held by a DIFFERENT writer is a loud
    /// failure, never a silently unfenced actor.
    public init(
        state: SessionState, ids: IDs, clock: ClockType,
        transport: Transport, executor: Executor, store: Store, approvals: Approvals,
        sink: any UISink = NoopUISink(), writer: String
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

    public func editEntry(entryID: String, newText: String, baseRevision: UInt64) async {
        await apply(.queueEdit(entryID: entryID, newText: newText, baseRevision: baseRevision, atMillis: clock.nowMillis()))
    }

    public func withdrawEntry(entryID: String) async {
        await apply(.queueWithdraw(entryID: entryID, atMillis: clock.nowMillis()))
    }

    public func resumeQueue() async {
        await apply(.queueResume(atMillis: clock.nowMillis()))
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
            let reason: String
            switch event {
            case .effectCompleted, .effectFailed:
                reason = "store append failed; result unpersisted, outcome unresolved"
            default:
                reason = "store append failed; intent unpersisted"
            }
            state = prior.replacing(phase: .failed(.integrityStopped(reason)))
            return
        }
        for effect in result.effects {
            if case .reserveEffect(let reservation) = effect {
                reservations[reservation.effectID] = reservation
            }
        }
        if case .cancelRequested = event {
            // C3 order: retention records above were appended BEFORE this
            // invalidation (cancelActive emits them first). Now drop.
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
        state = state.replacing(phase: .failed(.integrityStopped("sink emit failed: \(error)")))
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
    /// completeEffect/failEffect (stale outcomes drop); CancellationError
    /// drops silently (cancelRequested already invalidated the run).
    private func invokeExecutor(reservation: EffectReservation) async {
        do {
            let result = try await executor.execute(batch: reservation.batch, reservation: reservation)
            await self.completeEffect(reservation.effectID, outcome: .success(result.receipt.summary))
        } catch is CancellationError {
            return
        } catch {
            await self.failEffect(reservation.effectID, error: String(describing: error))
        }
    }

    /// Executor completion entry point. M1-B tests pair explicitly (calling
    /// this directly) to control cancel-vs-completion orderings
    /// deterministically; scripted fakes never auto-complete. M1-D wires
    /// production execution through `invokeExecutor` above, pairing through
    /// this same entry point.
    public func completeEffect(_ effectID: EffectID, outcome: EffectOutcome) async {
        guard let reservation = reservations[effectID] else { return }
        await apply(.effectCompleted(
            effectID: effectID,
            runID: reservation.runID, generation: reservation.generation,
            expectedRevision: reservation.revision, mutating: reservation.mutating,
            outcome: outcome, atMillis: clock.nowMillis()))
    }

    public func failEffect(_ effectID: EffectID, error: String) async {
        guard let reservation = reservations[effectID] else { return }
        await apply(.effectFailed(
            effectID: effectID,
            runID: reservation.runID, generation: reservation.generation,
            expectedRevision: reservation.revision, mutating: reservation.mutating,
            error: error, atMillis: clock.nowMillis()))
    }
}
