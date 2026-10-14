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
public actor SessionActor<Transport: ModelTransport, Executor: ToolExecutor, Store: SessionStore, Approvals: ApprovalGateway, ClockType: Clock, IDs: IDSource> {
    private var state: SessionState
    private var ids: IDs
    private let clock: ClockType
    private let transport: Transport
    private let executor: Executor
    private let store: Store
    private let approvals: Approvals
    /// Reservation table (effectID → reservation), captured pre-await.
    /// An entry is removed when its run is cancelled (after C3 retention
    /// records) or when its completion is first accepted (R3).
    private var reservations: [EffectID: EffectReservation] = [:]
    private var inFlight: Task<Void, Never>?

    public init(
        state: SessionState, ids: IDs, clock: ClockType,
        transport: Transport, executor: Executor, store: Store, approvals: Approvals
    ) {
        self.state = state
        self.ids = ids
        self.clock = clock
        self.transport = transport
        self.executor = executor
        self.store = store
        self.approvals = approvals
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
        // S2: the outer transition's records append BEFORE any pump-driven
        // follow-up — cause precedes consequence in the store log (M2 replays
        // this order).
        do {
            for record in result.records {
                try store.append(record)
            }
        } catch {
            // Integrity-visible halt (never silent divergence): the computed
            // records are unpersisted, so the run cannot continue on them.
            // M2 owns recovery; M1-B fails the run visibly here.
            state = prior.replacing(phase: .failed(.integrityStopped("store append failed; intent unpersisted")))
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
        case .reserveEffect:
            break // Recorded above; no I/O. Dispatch happens in later effects.
        case .emitUI:
            break // M1-B: projections terminate here (M1-D wires JSONL/CLI sinks).
        case .requestProvider(let invocation):
            guard reservations[invocation.effectID] != nil else { return }
            // Pinned order (M1B3-3): requestDispatched applies when the
            // actor BEGINS performing — records stored, no byte flowed yet.
            await apply(.requestDispatched(requestID: invocation.requestID, atMillis: clock.nowMillis()))
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
        case .startTimer, .cancelTimer:
            break // M1-B: deadlines evaluate on stamped ticks (scripted in tests; M1-D wires timers).
        }
    }

    private func invokeTransport(invocation: ProviderInvocation, reservation: EffectReservation) async {
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        do {
            let result = try await transport.invoke(invocation, intake: intake)
            await pairTransportResult(result, reservation: reservation)
        } catch is CancellationError {
            return // Generation invalidation already dropped this run; nothing to pair.
        } catch let failure as TransportFailure {
            // Classified at the failure site by the adapter (R2); the
            // transition policy stays the sole retry authority.
            await apply(.transportFailed(
                requestID: invocation.requestID, generation: invocation.generation,
                phase: failure.phase, error: failure.message, atMillis: clock.nowMillis()))
        } catch {
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

    /// Executor completion entry point. M1-B tests pair explicitly (calling
    /// this directly) to control cancel-vs-completion orderings
    /// deterministically; scripted fakes never auto-complete. M2 wires real
    /// execution through the same entry point.
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
