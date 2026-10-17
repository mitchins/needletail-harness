# M1-B plan — production transition model, session actor, queue/cancellation, pure presentation

Slice type: M1-B (second M1 minor). Planning-only; **no implementation authorized by this document.**
Status: REVISED FOR RE-REVIEW (rev4; rev3 digest `249441db…` reviewed NEEDS-EVIDENCE with M1B3-1..10; this revision pins effect ordering, closes every named (phase,event) cell, and makes cancellation client-authoritative — see §10). Prior rev3 material is unchanged except the table/§2.2/CORE-04/§10 edits listed there.
Prepared: 14 October 2026.
Baseline: `main` at `fc6ef5e` (M1-A closed locally at `778ca89` + ledger `fc6ef5e`; matches `origin/main` + 8 local-only commits, no push).
Implementer route (actual, this session): `muse-spark-1.3-contributor` (Muse Spark; Step 5 Preview Free retained only as an example, not claimed).
Reviewer (independent): `deepseek-reviewer` subagent (route resolved at review time from the installed definition; read-only; no edits; no secrets).
Baseline evidence (executed 14 Oct, this session): `git status --porcelain` clean (tracked `Archive.zip` environmentally rewritten again — restored byte-identical from HEAD before planning, unrelated); `swift --version` 6.4 (swift-6.4-RELEASE); `Package.resolved` sha256 `de95226e…cc` (unchanged — no dependency change in this slice); `./dev build` ok; `./dev test quick` 103/103 green (Primitive 14, Config 69, Behaviour 20).

Normative sources: COMPLETE-SPEC.md §§ 4 (architecture/targets), 4.1–4.2 (ownership, state machine), 5 (config/profile reuse), 6 (epochs), 8.1–8.5 (tool contracts, M2-owned), 9 (durability tables), 10 (permissions), 12 (commands/exits), 15 (targets); design/ARCHITECTURE-NOTES §§ 1–4 (pure transitions, reentrancy, queue semantics, replay ownership); UX-DX.md §§ 2.1–2.5 (composer/queue/undo/agents) + §3 (presentation contracts, fixtures, layers); MILESTONES M1-B; ACCEPTANCE CORE/POLICY/STATE/PORT/BDD/DX rows; DEVELOPMENT §§ 4–5; TESTING §§ 1–5/9; REVIEW §§ 1–2/4; DEPENDENCIES.md (no new packages).

## 1. Goal

Build the production session state machine that all later milestones drive — with **one owner, explicit effects, no resurrection, no second queue**:

- Pure `transition(_:_:_:) -> Transition` over typed state/events: new state + typed effects + durable-record intents, zero I/O.
- One `SessionActor` per session: admission serialization, reservation-before-await, revalidation-after-await, single-flight generation, explicit cancellation that invalidates (never relies on Task cancellation alone).
- Authoritative in-memory queue with idempotent admission, holds, revisions, tombstones, and safe-boundary dispatch (durability itself is M2).
- Minimal pure `NeedletailPresentation` target: composer/draft ownership, read-only projections, semantic frames (no ANSI, no replxx, no Markdown, no PTY).
- 15 cases with red-before/green-after oracles; M1-C (stream events) and M1-D (headless loop) handoffs defined as types, not code.

What this slice is NOT: model transport/SSE (M1-C), tool execution (M2-B/C), session persistence/GRDB (M2-A), queue durability/reconciliation (M2-D), headless JSONL/exit wiring (M1-D), checkpoint content (M3), terminal/replxx/ANSI/PTY (M4), cloud/consult (M5). No new packages, no macOS code, no catalogue renumbering.

Do not reimplement M1-A or change its accepted contracts. Reuse verbatim: `ConfigSnapshot`, `ProfileSnapshot` (frozen epoch fields), `EffectiveCapabilities` (tool grants), `requiresNewEpoch` (switch-model rule), `selectRoute`/`authorizeRequestDestination` (admission-time route validation), `terminalSafe` (all new diagnostic strings), bounded-read/credential rules (test seams only).

## 2. Production transition model

### 2.1 Deterministic identities (new, Core)

```swift
struct SessionID: Hashable, Sendable, Codable { var raw: String }
struct RunID / RequestID / EffectID / EpochID / OperationID // same shape
struct Revision: Sendable, Equatable, Comparable { var value: UInt64 } // per-session monotonic, actor-assigned
struct SequenceNumber // durable ordering; M1-B: in-memory counter + full shape for M2
struct CommandID // operator queue idempotence key (opaque String, never coerced)
protocol Clock: Sendable { func nowMillis() -> UInt64 }
struct SystemClock / VirtualClock(frozen + manual advance, tests)
protocol IDSource: Sendable { mutating func nextRunID() -> RunID; nextRequestID(); nextEffectID(); nextEpochID(); nextSequence() }
struct RandomIDSource (UUID-backed, production) / DeterministicIDSource(seed: UInt64, counter) (tests)
```

Timestamps and IDs are stamped onto events by the actor BEFORE the transition (reducers never read clocks/UUIDs — ARCH §1). `transition` takes `ids: inout IDSource` for effect IDs it mints; the function is pure/deterministic given `(state, event, ids)` — value semantics, no env/FS/net/clock. Replay replays the triple including the counter value (recorded per transition in test logs), so abandoned/stale transitions cannot silently shift later IDs. Resumption provenance (R9): transport/executor RESULT types carry NO identity — the actor pairs results with its pre-await reservation table (effectID → run/request/generation/revision, captured before the first `await`) and builds completion events from the reservation; unknown IDs drop before any event is built.

### 2.2 SessionState (new, Core; all `let`, value type)

```swift
// Construction pattern (R16): every field is `let`; each transition builds
// ONE new value wholesale and the actor reassigns it. Nothing mutates in
// place — reviewability comes from total construction, not access control.
struct SessionState: Sendable, Equatable {
    // Epoch-frozen inputs (M1-A, never mutated — a change means a new epoch object)
    var sessionID: SessionID
    var epoch: EpochDescriptor // epochID, parentEpochID?, configSnapshot, profile, effectiveCaps, route: Route
    var trustMode: TrustMode // .observe (default until M2 trust) | .workspace | .trustedExec; epoch-scoped, M2-owned changes
    // Live phase + active generation
    var phase: SessionPhase
    var activeRun: RunDescriptor? // runID, requestID, revision(generation), startedAt, sealed
    var activeRequest: ActiveRequest? // delivery states live HERE (R14), never on entries
    // Authoritative queue (in-memory; durable in M2)
    var queue: [QueueEntry]
    var queueHeld: Bool
    var heldReason: HoldReason?
    // Persistent admission index (R10): commandID → ack, surviving dispatch/withdraw/epoch-local lifetime.
    // Bounded at 512 entries, oldest-by-sequence pruned (I24); pruned at epoch transitions (re-admission
    // re-validates against the new route). STATE-02 marks this PARTIAL (in-memory now, durable M2).
    var admittedCommands: [CommandID: QueueAck]
    // Per-effectID consumption set (R3): marked on first acceptance, pruned at each new run reservation.
    // Bounded by construction (only the live generation's IDs are retained).
    var consumedEffects: Set<EffectID>
    // Budgets + invalid-attempt tracking. turnsUsed is PER-RUN model turns (SPEC "run limits"):
    // reset at each fresh admission; post-tool re-requests consume turns (a tool loop burns budget — intended).
    // invalidTracker is session-scoped, reset only by valid input.
    var turnsUsed: Int; turnLimit: Int // default 80, operator-configurable shape (not CLI yet — M1-D)
    var runDeadlineMillis: UInt64? // default 4h from run start; evaluated on stamped ticks
    var preSendRetries: Int // bounded re-request counter (max 2, pre-send failures only)
    var invalidTracker: InvalidTracker // fingerprint + count; limit 3
    var pendingApproval: ApprovalRequest? // set while authorising awaits a decision; cleared on grant/deny/cancel
    // Recovery markers (M2 reconciles; M1-B records + blocks). Bounded at 64; overflow is a visible
    // integrity stop, never silent loss (R19).
    var unresolvedOperations: [OperationRef]
    var droppedStaleCount: Int
    var lastSequence: UInt64
}
enum TrustMode: Sendable, Equatable { case observe, workspace, trustedExec }
enum SessionPhase: Sendable, Equatable {
    case idle, admitting, requesting, streaming
    case validatingTools, authorising, executing
    case cancelling, interrupted, failed(RunFailure), completed(RunReceipt), checkpointing
}
// Terminal-outcome mapping (R7): completed(RunReceipt) = success; failed(RunFailure) covers
// providerError | budgetStopped | invalidStopped | approvalDenied | integrityStopped; interrupted = cancelled;
// approvalRequired is NOT a phase — the outcome is reported while authorising holds pendingApproval.
// failed/completed/interrupted persist until `dismissRun` → idle (explicit receipt acknowledgement).
```

`QueueEntry`: `{ entryID, commandID, kind: followUp|steer, state: queued|held|dispatched|admittedToHistory|withdrawn, revision, text (bounded 64KiB total across undispatched, counted), targetEpochID, orderKey (reserved — reorder deferred to M2-D), enqueuedAt }`. Delivery states (`sending|responseComplete|deliveryUnknown`) live on `ActiveRequest` (R14): `struct ActiveRequest { requestID, runID, generation, delivery: DeliveryState, bytesOut }`. UI projection derives per-entry delivery via pure `deliveryStatus(entry, activeRequest) -> DeliveryStatus` (dispatched + lineage-match → sending/responseComplete; else queued/held/withdrawn display). ARCH §3 respected: history admission is transactional/idempotent; remote delivery is not promised exactly once.

`HoldReason`: cancelled | error | staleAttachment | policyChanged | checkpointBusy | budgetStopped | approvalPending. `RunFailure`: providerError | budgetExhausted | invalidStopped | approvalDenied | cancelled. `RunReceipt`: outcome + evidence refs (typed, no prose).

M1-A connection: `epoch` embeds `ConfigSnapshot` + `ModelProfile` + `EffectiveCapabilities` + the admission-time `Route`; `switchModel` reuses `requiresNewEpoch`; grants change ONLY via epoch events, never from provider content (transition asserts: no event carrying model text can alter `effectiveCaps` — enforced by type: no such field exists on those events).

### 2.3 SessionEvent (new, Core; all stamped, all replayable)

Operator: `operatorInput(commandID, text, kind, revision?)`, `queueEdit(entryID, newText, baseRevision)`, `queueWithdraw(entryID)`, `queueResume`, `approvalGrant(requestID, generation)` / `approvalDeny(requestID, generation)` (generation-bound — stale approvals drop per R1), `switchModel(alias)`, `checkpointRequested`, `cancelRequested`, `dismissRun` (explicit receipt acknowledgement → idle from failed/completed/interrupted), `newValidInputResets` (implicit via operatorInput after a stop).
Actor-internal: `requestDispatched(requestID)` (admitting → requesting once reserve records are stored), `validationCompleted(requestID, generation, batch)` (validatingTools → authorising).
Provider (M1-C feeds these; M1-B tests script them): `requestStarted(requestID, generation)` (M1B2-1: identity-bound like every async event), `providerResponse(requestID, generation, response: ProviderResponse)`, `transportFailed(requestID, generation, phase: preSend|postContent|ambiguous, error)` (R5: classification drives retry/hold rules; match-guarded + stale-covered per M1B2-4).
Effects: `effectCompleted(effectID, runID, generation, expectedRevision, outcome)`, `effectFailed(...)` (runID+generation added — R1 coverage).
Time: `tick(nowMillis)` (production timer effect; scripted in tests).
Budgets/validation: `invalidInput(fingerprint, cause)`.

`ProviderResponse` (minimal M1-C handoff, detail deferred): `{ requestID, generation, outcome: textDeltaComplete(text, toolProposals, isFinal) | failed(error) | interrupted, usage: UsageSketch? }`. `isFinal` comes from M1-C's native completion signals: proposals non-empty → validatingTools; final without proposals → completed; non-final without proposals → requesting (continue). `ToolProposal` = complete validated-shape proposal (VALIDATED shape only — field names/types; execution semantics are M2). Full native taxonomy (deltas, reasoning blocks, pairing) is M1-C's; M1-B pins only the completion boundary + generation binding. `turnsUsed++` on every requestProvider dispatch (initial + post-tool re-requests).

### 2.4 Transition output (new, Core)

```swift
struct Transition: Sendable, Equatable { var state: SessionState; var effects: [Effect]; var records: [DurableRecord] }
enum Effect: Sendable, Equatable { // typed REQUESTS with (sessionID, runID, requestID?, effectID, expectedRevision)
    case requestProvider(ProviderInvocation) // M1-C consumes; includes alias, epochID, sealed, budgets, history digest
    case emitUI(SessionEventProjection) // shared vocabulary with future JSONL (no second semantics)
    case startTimer(deadlineMillis, purpose) / cancelTimer(purpose)
    case cancelInFlight(reason) // M1-C consumes; generation already bumped
    case requestApproval(ApprovalRequest) // ApprovalGateway seam
    case reserveEffect(EffectReservation) // durable intent BEFORE dispatch (M2 executes; M1-B records)
}
// Ordering law (R8): every row emitting requestProvider or an executor dispatch emits its reserveEffect
// FIRST in the effects array (intent precedes dispatch — asserted by tests on effect order). Cancel paths
// emit explicit cancel records instead (control path, not a side effect).
// Intake budgets (R6): provider-event intake is a BoundedChannel (512 items / 4 MiB; block-then-fail on
// deadline — never silent drop for authoritative events). UI-bound spool: 128 items / 512 KiB with
// display-delta coalescing (ARCH §6: replaceable display projections may coalesce; authoritative data never drops).
enum DurableRecord: Sendable, Equatable { // SPEC §9 row shapes as values; M1-B appends to the in-memory store seam; M2 persists
    case sessionOpened, epochOpened(EpochDescriptor), eventAppended(seq, kind, digest)
    case operationIntent(OperationRef), operationResult(OperationRef, outcome)
    case queueAdmitted(QueueEntry), queueUpdated(QueueEntry), checkpointCommitted(EpochDescriptor)
}
```

### 2.5 Transition table (normative core; full matrix in code + tests)

Predicates (R7): `hasActiveRun` = requesting|streaming|validatingTools|authorising|executing|cancelling. `isBusy` = hasActiveRun | admitting | checkpointing. Terminal phases (failed/completed/interrupted) are NOT active and NOT busy — only `dismissRun` or fresh valid input moves them.

| Phase × Event | Result | Effects / Records |
|---|---|---|
| idle × operatorInput(valid) | admitting (reserve run+request IDs, revision=gen+1, prune consumedEffects to the new run; RESET run-scoped counters turnsUsed=0, preSendRetries=0 — M1B3-6; invalidTracker resets only on valid input, never on counters) | records: eventAppended; effects: reserveEffect THEN requestProvider (R8 order) + emitUI |
| idle × operatorInput(sealed tool-JSON / absolute-path directive) | idle + invalidTracker++ (POLICY-03 denial, typed, no FS read) | emitUI denial; 3rd identical → failed(invalidStopped) |
| idle × operatorInput(over queue caps: 21st item / 64KiB+1 / admittedCommands at 512) | idle (unchanged) + structured rejection | emitUI rejection (no silent drop, no partial admission) |
| idle × operatorInput(duplicate commandID) | idle (unchanged) | SAME ack from admittedCommands index (sequence/entryID identical — idempotence proof, R10) |
| idle × switchModel(alias) | idle + NEW EpochDescriptor iff `requiresNewEpoch` else same epoch; route re-validated via `selectRoute`; admittedCommands pruned (re-admission re-validates) | records: epochOpened (only on change) |
| idle × checkpointRequested | checkpointing (boundary check passes: no active run, no unresolved markers) | — (content M3; commit/unchanged decision recorded) |
| checkpointing × checkpointCommitted(newEpoch?) / checkpointFailed | idle (new epoch descriptor or unchanged) | records: checkpointCommitted / unchanged note |
| checkpointing × cancelRequested | cancelling (uniform with every active state — no special path) | cancel records (content work is M3; boundary work is here) |
| hasActiveRun × switchModel / checkpointRequested | UNCHANGED + refusal with reason (`checkpointBusyHold` / model-switch hold; NOT queued behind work — a held meta-queue would be a second queue) | emitUI reason |
| checkpointing × switchModel / admitting × switchModel / cancelling × switchModel (M1B2-8 + §9-Q2) | UNCHANGED + typed refusal (`switchDuringBoundary`, `switchDuringAdmission`, `switchDuringCancel/retry-at-idle`) | emitUI reason (non-lossy: names the in-flight state; no auto-retry — the operator re-issues at idle) |
| ANY × queueEdit(entryID, text, baseRevision) with entry undispatched + baseRevision == current (M1B2-6) | revision+1, text replaced (bounded re-check), record updated | records: queueUpdated; emitUI fresh ack (new revision) |
| ANY × queueEdit with stale baseRevision / dispatched entry | UNCHANGED + structured rejection (old ack cannot overwrite) | emitUI rejection with current revision |
| ANY × queueWithdraw(entryID) with entry undispatched | tombstone (withdrawn) + record | records: queueUpdated; emitUI acknowledgement (withdrawn ack on retry — idempotent) |
| ANY × queueWithdraw(entryID) with entry dispatched/absent | UNCHANGED + rejection (dispatched entries are history, not editable) | emitUI reason |
| idle × queueResume with queueHeld + no active run + no policy block | unheld (hold cleared, reason archived) | records: eventAppended; emitUI resume |
| queueResume while hasActiveRun / policy-blocked / already unheld | UNCHANGED + refusal or no-op diagnostic | emitUI reason (resume never force-dispatches) |
| busy × operatorInput | queue admission (followUp/steer by kind; caps/idempotence/revision rules as idle) — NEVER interleaves mid-tool-result or mid-message | records: queueAdmitted (+index); emitUI ack |
| admitting × requestDispatched(requestID) | requesting (applied when the actor BEGINS performing the emitted requestProvider effect — records already stored, no byte has flowed yet; M1B3-3 pin) | — (transport events before this point are preSend by construction) |
| admitting × cancelRequested | cancelling (M1B2-2: admission is interruptible — bump generation, hold queue) | effects: cancelInFlight + cancelTimer + cancel records; the emitted-but-unperformed requestProvider is WITHDRAWN before perform (M1B3-9: cancel discards unperformed dispatches, never the cancel records) |
| admitting × requestStarted(match or stale) | UNCHANGED + droppedStaleCount++ (no transport is live pre-dispatch; any start is spurious) | none |
| admitting × transportFailed(preSend) | admitting while preSendRetries < 2 (re-emit requestProvider, counter++); failed(providerError) at ≥2 | effects: reserveEffect + requestProvider on retry (R8 order); records |
| admitting × transportFailed(postContent|ambiguous) | failed(providerError) / hold + deliveryUnknown (defensive: unreachable pre-invoke — fail closed, never retry; M1B3-1) | records: operationResult / operationResult(unknown) |
| requesting × requestStarted(match requestID+generation) (M1B2-1) | streaming | records: eventAppended |
| requesting × requestStarted(stale) | UNCHANGED + droppedStaleCount++ | none |
| streaming × requestStarted(any — first match already consumed) (M1B3-8) | UNCHANGED + droppedStaleCount++ | none (no double advance) |
| requesting/streaming × providerResponse(match requestID+generation, unconsumed, textDeltaComplete) | advance per outcome (proposals → validatingTools; final text → completed; interim text → requesting); mark effectID consumed (R3) | records + emitUI; tool proposals are DATA (never effects) |
| requesting/streaming × providerResponse(match, outcome failed) (M1B3-2) | failed(providerError) + receipt (provider-signalled failure has a transition) | records: operationResult; mark consumed |
| requesting/streaming × providerResponse(match, outcome interrupted) (M1B3-2) | interrupted (provider-signalled stop is inspectable, not an error) | records: partial evidence preserved; mark consumed |
| validatingTools × validationCompleted(batch) | authorising (+ approval branch below) | records: eventAppended |
| authorising × approval needed + trustMode==trustedExec + batch has no exec-op | executing (no per-batch approval in trusted-exec; sealed batches never reach here — denied at admission) | reserveEffect BEFORE dispatch (R8) |
| authorising × approval needed (workspace mode, or any exec-op) | hold with pendingApproval set; effect requestApproval | NO hang, NO auto-approval; gateway timeout leaves pending (POLICY-04) |
| authorising × approvalGrant(match requestID+generation) | executing (scripted executor in tests; M1-D effects) | reserveEffect BEFORE dispatch |
| authorising × approvalDeny | failed(approvalDenied) + receipt (POLICY-04; exit-3 shape owned by M1-D) | records: operationResult |
| executing × effectCompleted(match IDs + unconsumed, success) | requesting + continue the loop (M1B2-3) | effects: reserveEffect THEN requestProvider (R8 covers re-requests too); records: operationResult; mark consumed; turnsUsed++ |
| executing × effectCompleted(match, failure receipt) | requesting with failure receipt preserved (a failed tool is a RESULT the agent investigates, not a run failure) | effects: reserveEffect THEN requestProvider; records: operationResult (no silent merge — M1-C owns merge rules); mark consumed; turnsUsed++ |
| executing × effectFailed(match: executor-level failure) (M1B2-7/M1B3-4) | requesting with the executor failure recorded as a receipt (run continues; the agent investigates — same continuation as success) | effects: reserveEffect THEN requestProvider; records: operationResult(failed-receipt); mark consumed; turnsUsed++ |
| ANY × providerResponse / effectCompleted / effectFailed / approvalGrant / approvalDeny / transportFailed / requestStarted with stale runID/generation/revision, already-consumed effectID, or post-cancel/post-epoch (R1+R3+M1B2-4) | UNCHANGED state + droppedStaleCount++ (STATE-01) | NO dispatch, NO history append, NO draft effect, NO hold/deny side effects; IF the dropped completion's reservation was mutating → append operationResult(unknown) + set unresolvedOperations BEFORE dropping (R2 — never forget a side effect) |
| idle × approvalGrant/approvalDeny/effectCompleted/effectFailed (no matching reservation) | UNCHANGED + droppedStaleCount++ | none (approvals for nothing are not grants) |
| requesting × transportFailed(match requestID+generation, preSend) with preSendRetries < 2 | requesting again (bounded re-request, counter++) | effects: reserveEffect + requestProvider (R8 order) |
| requesting × transportFailed(match, preSend) with preSendRetries ≥ 2 | failed(providerError) + receipt | records: operationResult |
| streaming × transportFailed(match, postContent) | interrupted with partial record (never silently merge a fresh completion — M1-C) | records: partial evidence preserved |
| ANY hasActiveRun × transportFailed(match, ambiguous) | hold + deliveryUnknown (R5: no auto-resend, no retry — reconciliation is explicit) | records: operationResult(unknown); emitUI hold |
| admitting × transportFailed(any, preSend only — nothing sent yet) | admitting (retry allowed while preSendRetries < 2) or failed(providerError) | same as the requesting preSend rows |
| ANY hasActiveRun × cancelRequested | cancelling (generation bumped, queueHeld=held(cancelled), reservations + inFlight cleared for the run) → interrupted → idle via dismissRun; in-flight send marked deliveryUnknown (never auto-resent) | effects: cancelInFlight + cancelTimer(cancelGraceMillis 5000) + cancel records; late completions drop per stale rule (CORE-02) |
| cancelling × tick(past cancel deadline) (M1B3-7) | interrupted FORCED client-authoritatively (no transport confirmation required — client cancellation ≠ server-confirmed stop; record transportUnconfirmed) | records: operationResult; the operator path cancel → interrupted → dismissRun → idle → switchModel can never strand |
| cancelling × transportFailed/confirmed | interrupted (early confirmation short-circuits the deadline) | records: operationResult |
| idle × cancelRequested | idle (no-op diagnostic, no state change) | none (cancelling nothing is not an error) |
| cancelling × cancelRequested | cancelling (idempotent, same generation) | none new |
| tick past runDeadline / turnsUsed ≥ turnLimit at request boundary | failed(budgetStopped), evidence preserved, NO hidden next request (CORE-04) | records: operationResult; emitUI receipt |
| invalidInput ×3 identical fingerprint | failed(invalidStopped) + diagnostic (CORE-03); mixed fingerprints or interleaved valid input resets | records; resume requires fresh valid input |
| ANY × unresolvedOperations non-empty + mutating continuation attempt | blocked pending explicit reconciliation (marker shape + rule now; M2 reconciles) | emitUI hold reason |
| failed/completed/interrupted × dismissRun | idle (explicit receipt acknowledgement) | records: eventAppended |
| failed/completed/interrupted × operatorInput(valid) | idle-equivalent fresh admission (receipt implicitly acknowledged; run-scoped counters turnsUsed/preSendRetries reset, invalidTracker resets per valid-input rule) | same as idle × operatorInput |
| failed/completed/interrupted × operatorInput(invalid/sealed-denied/over-caps/duplicate) (M1B3-5) | idle-equivalent admission attempt under the matching input rule (implicit ack first, then the input's own outcome: invalidTracker++/denial/rejection/same-ack) | same records/effects as the corresponding idle × input row |
| failed/completed/interrupted × queueResume with queueHeld + no block | unheld, STAY in terminal phase (resume never force-dispatches; next input proceeds normally) | records: eventAppended |
| failed/completed/interrupted × queueResume while policy-blocked | UNCHANGED + refusal | emitUI reason |
| failed/completed/interrupted × queueEdit/queueWithdraw | same cells as ANY rows above (revision bump / tombstone / rejections) | same records/effects |
| admitting × checkpointRequested (M1B3-5) | UNCHANGED + refusal (`checkpointBusyHold` — admitting is busy) | emitUI reason |
| checkpointing × checkpointRequested (M1B3-5) | UNCHANGED + idempotent refusal (one checkpoint at a time) | emitUI reason |

Approval matrix (M1B2-5 — exact, replacing the prose rule): rows = trustMode, columns = batch class. Sealed batches never reach authorising (denied at admission, POLICY-03). `ExecPolicy.ask` is sticky: exec=ask always requires approval except it cannot occur in observe (denied at caps).

| trustMode \ batch | read/search only (in-grant) | edit/write | exec(allowed) | exec(ask) |
|---|---|---|---|---|
| observe | proceed, no approval | denied at caps (unreachable) | denied at caps | denied at caps |
| workspace | proceed, no approval | approval required | approval required | approval required |
| trustedExec | proceed, no approval | proceed, no approval | proceed, no approval | approval required (ask sticky) |

Trust/capability consistency (session creation refuses — fail closed, §9-Q1): `observe` requires exec==denied AND edit==denied AND write==denied; `trustedExec` requires exec != denied; `workspace` imposes no shape (approval gates). `validateTrustConsistency(mode, caps)` is pure and tested; violations fail session creation with `contradictoryFlags`-grade diagnostics, never silent downgrade.

Forbidden transitions (each with a dedicated test): dispatch-while-held; dispatch withdrawn/stale-revision entries; advance on stale completion (incl. approvals); resurrect cancelled runs (I21); grant/route/epoch mutation from model text (I12 — unrepresentable by type + asserted); effect dispatch before its durable intent record; silent queue overflow handling; in-place epoch mutation; sealed inheritance/packet-file overread (POLICY-03); model-switch mid-run; checkpoint off-boundary; caching endpoints across awaits (M1-C rule, stated here); auto-resend of deliveryUnknown; approvalGrant creating execution without reserveEffect; re-request without reserveEffect (M1B2-3).

Terminal outcomes: `completed(RunReceipt)`, `failed(RunFailure)`, `interrupted`, `approvalRequired(ApprovalRequest)`, `budgetStopped`, `invalidStopped`. Every outcome preserves history + receipts and returns to `idle` only through the explicit path (failed/interrupted keep inspectability — CORE-02).

## 3. SessionActor (Core behavior + seams; no store implementation)

```swift
actor SessionActor {
    private var state: SessionState // `let`-constructed wholesale per transition (R16 pattern)
    private var ids: DeterministicIDSource // production: RandomIDSource value; tests: seeded (replay includes the counter)
    private let clock: Clock
    private let transport: ModelTransport // M1-C implements; M1-B tests script it
    private let executor: ToolExecutor // M1-B: never wired in production; scripted in tests only
    private let store: SessionStore // M1-B: in-memory impl (TestSupport); M2: GRDB
    private let approvals: ApprovalGateway // scripted in tests (approve/deny/silent)
    private var inFlight: InFlightTask? // at most one foreground generation (ARCH §1)
    private var reservations: [EffectID: EffectReservation] // captured pre-await; pairing table (R9)
    func handle(_ input: UnstampedInput) async // stamps IDs/time, calls transition, appends records, performs effects
    func tick() async // deadline evaluation driver (production timer effect feeds this)
}
```

Reservation-before-await: `handle` runs `transition` FIRST (pure), appends ALL `records` to the store, records every emitted reservation in `reservations` (effectID → run/request/generation/revision + mutating flag), THEN performs `effects` — each effect carrying `(sessionID, runID, requestID?, effectID, expectedRevision)`. `cancelRequested` clears `reservations` AND `inFlight` for the cancelled run (M1B2-4/R9 fold-in: no stale transport event can ever be constructed afterwards — late results drop at the table, before any event exists). Dispatch (transport/executor call) happens only after its `reserveEffect` record is stored (R8 ordering asserted on the effects array). Revalidation-after-await: transport/executor RESULT types carry NO identity (payload only — M1-C/M2 rule); the actor pairs each result with `reservations[effectID]` captured pre-await and builds the completion event FROM THE RESERVATION (R9 — a stale transport value can never stamp itself current). Unknown effectID → drop + `droppedStaleCount++` WITHOUT building an event. The transition then re-checks generation/revision/consumption (R1/R3) and either advances or drops (with R2 unknown-retention for mutating reservations). Simultaneous callbacks cannot create two owners because: (a) only the actor mutates `state`/`inFlight`/`reservations`; (b) `inFlight` is set before the first `await` and cleared only by the matching completion/cancel; (c) a second completion for the same effect finds no live reservation (consumed at first acceptance) and drops. Swift Task cancellation is a DELIVERY mechanism only — invalidation is the generation bump (a task that ignores cancellation still cannot advance state: its completion mismatches).

M2 durability interfaces (defined now, implemented later):
```swift
protocol SessionStore: Sendable {
    func append(_ record: DurableRecord) throws
    func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) // paged (R15)
    func claimWriterOwnership(session: SessionID) throws // kept for M2 STORE-06; unused by the single M1-B actor (stated, not silently dropped)
    func releaseWriterOwnership(session: SessionID)
}
struct InMemorySessionStore: SessionStore // TestSupport; same append/load/ownership semantics, bounded at 10_000 records with visible overflow (R19); no crash durability (M2 proves that)
protocol ModelTransport: Sendable {
    // Intake is a BoundedChannel, never an unbounded AsyncStream (R6/ARCH §6).
    func invoke(_ invocation: ProviderInvocation, intake: BoundedChannel<ProviderResponse>) async -> TransportResult // payload only, NO identity (R9)
}
```
Transport signature detail is M1-C's; M1-B fixes only: invocation carries IDs+alias+epoch+sealed+budgets; results are payload-only and re-enter via reservation pairing; cancellation via Task + generation. `ToolExecutor`: `func describe(batch:) -> ApprovalRequest`-capable + M2 execution; M1-B uses only the typed-denial path (no production executor wired — state this so the reviewer can verify no execution sneaks in). `ApprovalGateway`: `func decide(_ request: ApprovalRequest) async -> ApprovalDecision` (approve/deny/timeout-as-pending — never auto-approve).

No event-sourcing framework: `Transition` is one struct, `handle` is one method, no middleware/registry/bus.

## 4. Queue and cancellation contracts (authoritative now, durable in M2)

- Local admission is idempotent on `commandID` against the persistent `admittedCommands` index (R10): same ID → same `QueueAck(entryID, sequence, revision)` even after dispatch, history-admission or withdrawal; a lost UI ack retried with the same ID inserts nothing (I14). Index bounded at 512 entries (oldest-by-sequence prune) + pruned at epoch transitions (re-admission re-validates). STATE-02 (due M2, durable exactly-once) is marked PARTIAL here: in-memory idempotence proven now, crash durability explicitly deferred — the M1-A NET-06 precedent for partial claims.
- States are semantically distinct and all observable: entry states queued → dispatched → admittedToHistory, held, withdrawn (tombstone — never dispatched, never deleted in M1-B memory); delivery states sending → responseComplete | deliveryUnknown live on `ActiveRequest` and project per-entry via pure `deliveryStatus` (R14 — one owner, derived projection).
- Dispatch ONLY at safe boundaries: steer FIFO after the current complete turn+tool batch, before the next request; followUp FIFO after run success/completion. Errors, cancellation, stale attachments, policy changes HOLD the queue (explicit `queueResume` required — no opportunistic skipping, no surprise follow-up).
- Editing an undispatched entry increments `revision`; effects/acks carrying older revisions drop (old ack cannot overwrite). Withdrawing an undispatched entry tombstones it; reorder is explicitly DEFERRED (orderKey reserved; M2-D owns reorder/withdraw flows — withdraw IS in M1-B, reorder is not).
- Caps: 20 entries / 64KiB undispatched text → structured rejection (never silent drop, never partial admission).
- Cancellation holds (never dispatches next), marks in-flight `deliveryUnknown`, bumps generation; `queueHeld` survives in state until explicit resume (durability of the hold across restarts is M2).
- Never claim exactly-once remote processing: admission ack ≠ delivery proof; ambiguous delivery is held for reconciliation (I14).

## 5. NeedletailPresentation (new target; deps: Foundation + NeedletailCore values only)

```swift
struct UIState: Sendable, Equatable {
    var composer: ComposerState // text (≤64KiB, reject-with-reason beyond), cursor scalar offset, revision, pasteShield
    var suggestion: MentionSuggestionState? // query, revision, candidates ≤ MaxCandidates(10) with 8-line/4KiB previews (M1B2-9 design caps; UI spool counters live in the M4 output owner, bounded 128/512KiB there)
    var queue: [QueueSummary] // read-only PROJECTION (QueueSummary(entry:) in Presentation; never authoritative)
    var activeAgent: AgentSummary? // projection of RunDescriptor (alias/locality/phase/queue count)
    var inspection: InspectionView? // context|queue|epochs (read-only views; no compaction invocation — M4)
    var status: UIStatus // idle|busy|held(reason)|failed(cause)
}
enum UIAction: Sendable { case input(InputAction) // insertText/delete/moveCursor/submitDraft/newline/pasteLiteral
    case session(SessionEventProjection) // typed core projection (shared vocabulary — no second semantics)
    case completion(CompletionResult) // queryRevision + candidates (FileCandidateSource fake in tests)
    case terminal(TerminalCapabilityChange) // width/capability fallback only
    case queueOp(QueueOperation) } // submitFollowUp/submitSteer/editEntry/withdrawEntry/resumeQueue
enum UIEffect: Sendable { case submit(OperatorInput), queue(OperatorInput, QueueKind),
    case queueEdit(entryID: String, newText: String, baseRevision: UInt64), // R4: edit/withdraw/resume are
    case queueWithdraw(entryID: String), case queueResume, // REQUESTS the actor decides — UI never mutates `queue`
    case previewFile(FileReference), case requestCompletions(Query, revision: UInt64),
    case cancelCurrent, case inspect(InspectionCommand) }
func reduce(_ state: UIState, _ action: UIAction) -> (UIState, [UIEffect])
struct RenderFrame: Sendable, Equatable { var lines: [SemanticLine]; var statusLine: StatusLine?; var composerOverlay: ComposerOverlay?; var width: Int }
enum StyleRole: Sendable, Equatable { case normal, status, composerText, candidate, candidateSelected, errorNotice } // minimal set: only roles DX-01/07 assert + errorNotice (R22 trim accepted)
struct TerminalCapabilities: Sendable, Equatable { var color: ColorLevel16_256_none; var cursorAddressing: Bool } // dumb/non-TTY → inline composer, no overlay
func render(_ state: UIState, width: Int, capabilities: TerminalCapabilities) -> RenderFrame
```

Ownership limits (asserted by tests + import gate): UIState holds NO grants/routes/history; `queue` is projection-only (actor ack IDs referenced, never minted); `UIEffect.queue*` are REQUESTS the actor may deny (DX-03); the reducer NEVER mutates `queue` — withdraw/edit/resume intents become effects (R4); renderer performs no I/O and emits semantic frames (ANSI is a future M4 adapter concern); `terminalSafe` applied to every rendered untrusted string (H2 carry-over).

Projection direction (R21): `SessionEventProjection` is constructible ONLY inside Core (`public` struct, `internal` init) — Presentation can carry it in `UIAction.session` but never mint one. A static construction-site gate test (`SessionEventProjection(` occurrences outside `Sources/NeedletailCore/`) pins this; feeding a UI-minted projection back to the actor is unrepresentable (no `UIEffect` carries one).

`FileCandidateSource` protocol (Presentation-owned, String paths): `func candidates(query: Query, revision: UInt64) -> [CandidateFile]` — M1-B: fake only (bounded synthetic catalogue, deterministic); confinement stays in Runtime at submit time (UX-DX §2.2 — `CandidateFile` carries an opaque path the UI never opens; M2-D reconciles with real roots, stated here). Product wiring M2-D/M4. `CompletionResult` carries `queryRevision`; reducer drops stale (`revision < current` → no mutation, DX-02).

## 6. Behaviour-first testing (15 cases; one variant never satisfies all)

Conventions per case: stable variant IDs, Given/When/Then, forbidden effects, layer (pure = transition/reducer/render only, frozen clock/IDs, no actor I/O; integration = production `SessionActor` + scripted seams, in-memory store, STILL no process/terminal/FS/SQLite/network), fixture boundary (scripted fakes + deterministic IDs), red/green expectation, production function exercised. Bounded permutations: length ≤ 12, fixed seeds, minimized-trace promotion.

RED honesty (R20): phase 1 runs the new oracles against minimal STUB types that compile but do nothing (empty enums/structs, transitions returning the input state with zero effects) — assertion failures, never compile failures (a missing import or broken fixture is not RED). Stub state is recorded in logs, then replaced by the implementation. Post-green, BDD-06 disposable guard-removal patches prove each security oracle fails without its guard.

- **CORE-02** (integration): variants `cancel-idle-noop`, `cancel-requesting`, `cancel-streaming`, `cancel-validating`, `cancel-authorising`, `cancel-executing(scripted)`, `cancel-cancelling-idempotent`, `cancel-checkpointing-uniform`, `completion-after-cancel-drops`, `approval-after-cancel-drops` (R1: late approve advances nothing), `cancelled-mutating-outcome-retained-unknown` (R2: scripted mutating completion post-cancel → operationResult(unknown) + marker, then drop), `queue-held-not-dispatched`, `session-inspectable-after-interrupt`. G/W/T: Given an active streaming run with one queued follow-up, When cancel arrives, Then phase=cancelling with generation+1, queue held, in-flight send marked deliveryUnknown, late completion drops, interrupted→idle keeps history. Forbidden: resurrection, auto-dispatch, dropped receipts, second owner, forgotten side effects.
- **CORE-03** (integration): `invalid-command-×3-stops`, `denied-sealed-tool-×3-stops`, `mixed-fingerprints-no-stop`, `valid-between-resets`, `resume-requires-fresh-input`. Fingerprint = FNV-1a (deterministic, in Core — no Crypto import) over (kind + normalized target); raw secrets never fingerprinted/logged.
- **CORE-04** (integration): `turn-limit-stops-at-80` (no 81st request effect), `post-tool-loop-no-81st-request` (M1B3-10: turns consumed across executing→requesting re-requests hit the same limit), `wall-clock-deadline-stops` (scripted ticks across deadline), `tick-before-deadline-continues`, `cancel-deadline-forces-interrupted` (M1B3-7: tick past cancelGraceMillis with no transport confirmation still lands interrupted + transportUnconfirmed), `evidence-preserved` (history+receipts intact, no hidden request). Budgets travel in state; time enters via stamped ticks only.
- **POLICY-03** (pure+integration): `sealed-tool-json-denied` (packet `{"tool":"read",…}` → typed denial, zero file effects), `sealed-absolute-path-denied` (`@/etc/shadow`, `/read /abs` → denial), `sealed-plain-text-admitted` (ordinary text still admits — sealing ≠ silence), `sealed-packet-file-only` (actor emits NO file-read effect except the packet's own byte range). Pure: `validateSealedInput` unit table. Integration: actor + file-effect recorder asserting zero reads.
- **POLICY-04** (pure+integration): `headless-denial-stops-typed` (deny → stopped + receipt), `headless-no-gateway-approval-required` (silent gateway → approvalRequired outcome, test completes asserting pending state — never hangs), `headless-grant-continues-scripted` (approve → authorising continues), `no-auto-approval` (gateway timeout does NOT decide), `trusted-exec-auto-allows` (mode grants dispatch without per-batch approval), `observe-denies-upfront` (exec/edit/write never reach authorising in observe mode), `workspace-reads-proceed` (read/search in-grant need no approval), `ask-always-asks` (exec=ask requires approval even in trustedExec), `trust-inconsistency-refuses-session` (observe+exec-allowed / trustedExec+exec-denied fail creation). Exit-code mapping owned by M1-D (plan carries outcome vocabulary only — R22 trim accepted); M1-B pins outcome + `ApprovalRequest` shape (operation text redacted via `terminalSafe`, required grant, requestID+generation).
- **STATE-01** (pure + actor parity rows): `late-run-completion`, `old-generation-completion`, `old-effect-revision`, `post-cancel-completion`, `post-epoch-change-completion`, `approval-after-cancel` (R1), `duplicate-effect-redelivery` (R3: same effectID twice → second drops as consumed), `mutating-completion-retained-unknown` (R2) → all drop with `droppedStaleCount++` (plus unknown-retention where mutating), zero state advance/dispatch/history/draft effects. Pure: direct transition calls (consumed-set + reservation table in state). Integration: actor rows proving seam preservation — scripted delayed completion + cancel ordering, cancel-then-new-run with late old result (dropped at the reservation table before any event is built, R9).
- **STATE-04** (pure — R12 relayer): the channel is a VALUE (`BoundedChannelState` with pure `offer/poll`), so liveness becomes finite folds over scripted input lists (no async, no sleeps — "no hang" = the fold terminates within an explicit step cap). Variants: `buffer-overflow-visible-stop` (intake caps 512 items / 4 MiB → typed overflow, authoritative receipts kept), `cancel-during-fill-bounded-teardown` (fold `[fill…, cancel, …]` → bounded drain, receipts preserved), `slow-consumer-backpressure` (offer-at-cap returns an explicit backpressure effect + zero buffer growth; display deltas coalesce while protocol events spool), `ui-spool-caps` (128 items / 512 KiB), `durable-half-deferred` (explicit non-claim: artifact quotas are M2). Catalogue layer stays pure — no async variant exists to re-layer.
- **PORT-02** (packaging + fast static — R11 chain): extend the ARCH import gate to `NeedletailPresentation` (imports: Foundation + NeedletailCore only; NO replxx/HTTP/SQLite/Darwin/Security/AppKit/SwiftUI/Combine/Glibc/transport) AND re-pin Core (no new effectful imports). Runs in the fast suite; the catalogue "packaging" layer is satisfied by CI execution on a clean checkout (the M1-B quick-filter addition flows into the existing offline CI job — no CI change needed, verified at implementation) PLUS the release-binary smoke's `doctor` run. No Apple host needed (static text check).
- **BDD-06** (reviewProcess — R13 mapping): probe→guard→oracle table (committed in the milestone report, checked by the reviewer, not by the runner): generation-check removal → STATE-01 duplicate-redelivery oracle; cancel-invalidation removal → CORE-02 completion-after-cancel oracle; ack-dedup removal → queue-admission idempotence oracle (admittedCommands); sealed-denial removal → POLICY-03 tool-JSON oracle; stale-revision acceptance → queue-edit revision oracle. Each: patch production, run the NAMED oracle, capture RED, restore byte-identical, retain log. NO committed fault switches; NO test-runner tests (a zero-match `test case BDD-06` correctly refuses — review evidence reconciles via receipt + mapping table, never via a pass).
- **BDD-08** (reviewProcess + committed replay): bounded permutation exploration (DX-06 harness) retains the shortest failing trace; the trace is frozen (clock/IDs/seed/events) into a committed regression test named `BDD_08_*` (fast, deterministic) PLUS the review record of whence it came. Fallback (R13): if exploration finds no failure, the test pins a HAND-WRITTEN hostile trace authored from the threat model and labeled as such — BDD-08 always has a committed test either way.
- **DX-01** (pure): `replay-twice-identical` (same UIAction script ×2, frozen clock/IDs → identical frames+effects), `width-change-only-layout` (same state, 40/80/120 → same content roles, different wrapping), `capability-fallback` (dumb → inline composer, no overlay; content preserved).
- **DX-02** (pure): `stale-candidate-dropped` (revision N+1 arrives before N → N ignored, composer unchanged), `tab-accepts-current-only` (accept applies the revision-visible selection, never a stale one), `catalogue-caps` (10K synthetic entries → bounded, fast; ignored/secret entries never surface — fake source).
- **DX-03** (pure): `queue-request-emits-effect` (UI emits `queue`, never dispatches), `edit-withdraw-resume-are-effects` (R4: reducer maps intents to `UIEffect.queueEdit/Withdraw/Resume`; `queue` state untouched — asserted), `projection-construction-site-gate` (R21: no `SessionEventProjection(` outside Core — static check), `actor-deny-surfaces-held` (denial projection → visibly-pending→held), `optimistic-pending-marked` (unacked submissions render pending, never committed).
- **DX-06** (pure): bounded permutation harness (`length ≤ 12`, fixed seeds) over model-delta/status/draft/cancel/completion/ack interleavings with invariants (draft byte-exact preserved; no effect without ack; stale revisions drop; single owner; queue never auto-dispatches while held); failures minimize + promote (→BDD-08).
- **DX-07** (pure + process): golden fixtures `Tests/Fixtures/render/*.json` + `manifest.json` (`reviewed_rev` + sha256 per fixture); test fails on unmanifested content change (forces explicit reviewed diff); manifest update itself requires the reviewed-diff ritual (documented, reviewer-checked — the test cannot distinguish, the reviewer does).

Hostile orderings explicitly enumerated (authorization §6): cancel-vs-completion both orders; duplicate acks (same commandID ×3, restarted ack); queue-edit-before-stale-callback (revision guard); model-switch-during-active-work (hold + epoch rule); backpressure exhaustion (STATE-04 caps); sealed-tool-JSON ×3 (CORE-03 ∩ POLICY-03).

Red-before/green-after: phase 1 runs the new oracles against minimal compilable STUBS (R20 — types exist, transitions return input state with zero effects), yielding assertion failures, retained; then green. Post-green, BDD-06 probes prove each security oracle fails when its guard is removed (union-style disposable patches, restored after).

## 7. Boundaries and handoffs

M1-C receives: `ProviderInvocation` + `ProviderResponse` shapes, `BoundedChannel` reuse contract (512/4MiB intake), deadline sources (profile timeouts via snapshot), generation/revision binding rules, `cancelInFlight` semantics, `authorizeRequestDestination` call-before-dispatch (already normative), and the no-identity RESULT rule (payloads only — actor pairs via reservations). M1-C owns: byte splitting, SSE framing, native taxonomies, signed/opaque blocks, usage dialects, transport deadlines/retries, real cancellation mechanics.
M1-D receives: `RunOutcome` terminal vocabulary (exit-code mapping owned by M1-D — R22 trim accepted), `HeadlessDecision`, `ApprovalRequest` shape, `SessionEventProjection` vocabulary (no second semantics; Core-only construction), `FileCandidateSource` protocol. M1-D owns: CLI wiring, JSONL schemas, exit behavior, scripted-effects loop (CORE-01). Note (§9-Q3 adopted): M1-D single-shot runs may treat process exit as implicit receipt ack (no state reuse); interactive/multi-session reuse requires the explicit `dismissRun` event.
M2 receives: `DurableRecord` row shapes, `SessionStore` protocol (paged) + `InMemorySessionStore` semantics (bounded 10k, same append/load/ownership), ID/sequence rules, writer-ownership API (kept for STORE-06 though the single M1-B actor never calls it), tombstone/revision rules, unresolved-marker block rule + 64-cap integrity stop, `orderKey` reservation (reorder deferred), artifact-quota half of STATE-04, admittedCommands durability upgrade (STATE-02 full).
Deferred explicitly: transport, execution, persistence/GRDB, queue durability/reconciliation, reorder UI flows, checkpoint content (M3), ANSI/replxx/PTY (M4), cloud/consult (M5).
No new dependencies (Swift Testing + Foundation only; fakes hand-written; fixtures JSON). Portability: Core/Presentation import NOTHING platform-specific (PORT-02 gate); Runtime/CLI/Providers untouched this slice (no new shims).

## 8. File/type map + commands (planned, not yet executed)

| File | Contents | Notes |
|---|---|---|
| `Sources/NeedletailCore/SessionIDs.swift` | Session/Run/Request/Effect/Epoch/Operation/Command IDs, Revision, SequenceNumber, Clock + SystemClock/VirtualClock, IDSource + Random/Deterministic | Pure values; no I/O |
| `Sources/NeedletailCore/SessionState.swift` | SessionState, SessionPhase, RunDescriptor, QueueEntry (+states/kinds), HoldReason, TurnBudget, InvalidTracker (FNV-1a), OperationRef, EpochDescriptor, RunReceipt/RunFailure/ApprovalRequest/HeadlessDecision/RunOutcome | M1-A snapshot/profile/caps embedded, never mutated |
| `Sources/NeedletailCore/SessionEvent.swift` | SessionEvent (all stamped variants), ProviderResponse (minimal handoff), ToolProposal (validated shape), SessionEventProjection | Replayable; model text never touches grants (type-enforced) |
| `Sources/NeedletailCore/SessionTransition.swift` | `transition(_:_:_:)`, Transition, Effect (+Reservation), ProviderInvocation, ApprovalGateway/ModelTransport/ToolExecutor/SessionStore protocols, FileCandidateSource? (no — Presentation; see below) | Total function; forbidden list in doc + tests |
| `Sources/NeedletailCore/SessionStore.swift` | SessionStore protocol, DurableRecord row shapes, BoundedChannel | M2 shapes; no SQL |
| `Sources/NeedletailCore/SealedInput.swift` | `validateSealedInput` + SealedAdmission | POLICY-03 pure core |
| `Sources/NeedletailCore/SessionActor.swift` | SessionActor + InFlightTask + reservation table + handle/tick (R17: the slice's core file, previously unlisted) | Only mutator of state; generation invalidation here |
| `Sources/NeedletailTestSupport/InMemorySessionStore.swift` | TestSupport in-memory store (same semantics, no crash durability) | Dev-only; M2 replaces durability, not semantics |
| `Sources/NeedletailPresentation/*.swift` | UIState.swift, UIAction.swift, UIEffect.swift, UIReducer.swift, Render.swift (frames/roles/capabilities), MentionQueries.swift (revision guard), Projections.swift (QueueSummary/AgentSummary from Core values), FileCandidateSource.swift (fake in tests, not product) | Deps: Foundation + NeedletailCore only |
| `Sources/NeedletailCLI/*` | UNTOUCHED in M1-B | No new commands in M1-B |
| `Tests/NeedletailStateTests/*` | transition matrix, queue admission, budgets, invalid tracker, epoch rules, sealed validator, bounded channel, ARCH gate (Core) | Quick gate (pure, ≤3 s with the rest) |
| `Tests/NeedletailActorTests/*` | actor + scripted transport/executor/store/approvals/clock; cancel/stale/ack/approval/budget races both orders; STATE-01 parity; POLICY-03/04 integration rows | `test case` + offline (fast, no I/O — layer=integration by seam, not by cost) |
| `Tests/NeedletailPresentationTests/*` | reducer/render/golden-manifest/DX-01/02/03/06/07 + BDD-08 frozen replay + ARCH gate (Presentation) | Quick gate (pure); name follows `Needletail*Tests` convention (R18) |
| `Tests/Fixtures/render/*.json` + `manifest.json` | semantic golden frames + reviewed_rev/hash manifest (DX-07) | Small, committed |

`Package.swift`: + `NeedletailPresentation` target (+product library), +3 test targets (State/Actor/Presentation; Actor deps Core+TestSupport; Presentation tests deps Presentation+Core; NO new packages). `dev`: quick += `--filter NeedletailStateTests --filter NeedletailPresentationTests`; offline += the 13 test-runner case IDs (BDD-06/08 excluded — review-layer, reconciled via receipt); `test case` mechanics unchanged (function-name matching).

`cases/catalog.json` + `cases/expected-index.json`: EXPLICITLY UNTOUCHED in M1-B (R17 answered with rationale, not an omission). The BDD-04 gate pins the M0 status vocabulary (`currentMilestone = "M0"` in test): flipping 15 cases to IMPLEMENTED while 30 M1-due cases remain deferred would fail reconciliation. Statuses flip once, at the M1-epic closeout, when all 45 M1-due cases are decidable. The 15 M1-B cases are tracked as in-scope by this plan + the milestone report, never counted as passes before then.

Anticipated commands (to be executed post-review, in implementation authorization):
```sh
./dev build
./dev test quick
./dev test case CORE-02 | CORE-03 | CORE-04 | POLICY-03 | POLICY-04 | STATE-01 | STATE-04 | PORT-02 | DX-01 | DX-02 | DX-03 | DX-06 | DX-07
./dev coverage
./dev test offline
./dev test native   # M0 regression (untouched paths)
```

## 9. Resolutions (rev2) and remaining questions for the reviewer

Resolved in rev2 (reviewer: confirm or break each):
1. `executing` stays WITH explicit success/failure/stale/unknown rows (R2/R7) — a dead-end phase would be worse than a scripted-seam phase; no production executor is wired (stated, grep-verifiable).
2. `ids: inout IDSource` stays: replay covers the triple; resumption provenance is fixed actor-side (payload-only results + reservation pairing, R9).
3. Refuse (not hold/queue) for off-boundary checkpoint/switch-model — a held meta-queue would be a second queue; refusal strings specified.
4. Caps are fine; escapes were elsewhere and are now bounded (intake 512/4MiB, UI spool 128/512KiB, admittedCommands 512, unresolved 64→integrity stop, store 10k visible overflow).
5. String-path seam accepted with Runtime-side confinement + opaque references + stated M2-D reconciliation.
6. No UI/session event reaches grants/routes (type-enforced); the one real leak (`queueOp` authority) is fixed via `UIEffect.queue*` + construction-site gate.
7. BDD-06 reconciles via probe→guard→oracle mapping + retained RED logs (receipt, not runner); BDD-08 always has a committed test (promoted trace or labeled authored trace).
8. Trim accepted: exit-mapping table → M1-D, StyleRole minimal; the rest kept with per-item rationale in §13.

Genuinely open (reviewer input requested):
- Does the approval matrix over-constrain future M2 execution policy (e.g., recipe-scoped auto-approval inside workspace mode), and if so which cell should carry an extension point?
- Should `dismissRun` auto-fire after a bounded retention (e.g., next input implicitly acks — already specified) or is there a headless multi-run case that needs an explicit ack timeout?

## 10. Revision log (rev3 → rev4, rev2 → rev3, rev1 → rev2)

Rev3 → rev4 (reviewer M1B3-1..10, NEEDS-EVIDENCE): M1B3-1 (admitting × transportFailed branches on classification — no "any" auto-resend); M1B3-2 (providerResponse failed/interrupted rows); M1B3-3 (requestDispatched pinned BEFORE transport perform + admitting × requestStarted stale-drop); M1B3-4 (effectFailed mirrors the success continuation); M1B3-5 (terminal × non-valid input/queueResume/edit/withdraw cells + admitting/checkpointing × checkpointRequested refusals); M1B3-6 (run-scoped counter resets at fresh admission; invalidTracker session-scoped); M1B3-7 (cancel-deadline tick forces interrupted client-authoritatively + transportUnconfirmed; no stranding); M1B3-8 (streaming × requestStarted drops); M1B3-9 (admitting-cancel emits cancelInFlight + withdraws the unperformed dispatch); M1B3-10 (post-tool-loop budget variant). turnsUsed documented per-run (tool loops burn budget, intended).

Prior Blockers R1–R4 stay closed; the re-review's residuals are folded: M1B2-1 (`requestStarted` carries identity + row + stale case); M1B2-2 (cancel covers `admitting`/busy); M1B2-3 (post-tool re-request emits reserveEffect+requestProvider; proposal/final/continue routing via `isFinal`; turnsUsed++ per dispatch); M1B2-4 (match guards on transport rows + stale coverage + cancel clears reservations/inFlight); M1B2-5 (exact approval matrix + `validateTrustConsistency` fail-closed creation rule; TrustMode stays epoch-scoped per the reviewer's Q1 — capability bits cannot express approval mode); M1B2-6 (queueEdit/Withdraw/Resume table cells); M1B2-7 (`effectFailed` row); M1B2-8 (boundary switchModel refusals incl cancelling/retry-at-idle per Q2); M1B2-9 (MaxCandidates 10 + spool-owner note). §9-Q3 adopted as the M1-D single-shot note. POLICY-04 gains `workspace-reads-proceed`, `ask-always-asks`, `trust-inconsistency-refuses-session` variants.

Rev1 → rev2 (reviewer M1B-R1..R22, NEEDS-EVIDENCE):

All four Blockers fixed: R1 (stale rule covers approvals/effects/consumed IDs + post-cancel/epoch; approval events carry generation); R2 (mutating reservations retain unknown + marker before drop); R3 (`consumedEffects` in state, pruned per run; actor reservation table); R4 (`UIEffect.queueEdit/Withdraw/Resume`; reducer never mutates `queue`).
Majors: R5 (transportFailed ×3 rows + preSend retry counter ≤2 + deliveryUnknown hold); R6 (BoundedChannel replaces AsyncStream; named budgets + overflow policies); R7 (admitting exit via `requestDispatched`; validation/authorising/executing rows incl trustedExec branch; checkpointing exits + uniform cancel; `dismissRun`; idle stale drops; active/busy predicates; outcome↔phase mapping); R8 (reserveEffect-first ordering law); R9 (payload-only results + reservation pairing; `ids: inout` retained with replay argument); R10 (persistent admittedCommands index, 512-cap + epoch prune; STATE-02 PARTIAL per NET-06 precedent); R11 (PORT-02 packaging = CI clean-checkout chain, no CI change); R12 (STATE-04 as pure value-channel folds; catalogue layer intact); R13 (probe→guard→oracle table; BDD-08 promotion-or-authored fallback); R14 (delivery states on ActiveRequest + derived projection).
Minors: R15 (paged store), R16 (`let`-construction wording), R17 (SessionActor.swift row; catalogue-untouched rationale), R18 (`NeedletailPresentationTests`), R19 (64-cap markers + 10k store overflow), R20 (stub-boundary RED honesty), R21 (internal-init projections + construction-site gate). Suggestion R22: exit table → M1-D + StyleRole minimal accepted; remainder kept with rationale.
New surface from fixes: `TrustMode`, `ActiveRequest`/`DeliveryStatus`, `requestDispatched`/`validationCompleted`/`dismissRun` events, `transportFailed` classification, `preSendRetries`/`pendingApproval`/`consumedEffects`/`admittedCommands` state, snapshot-level epoch rule unchanged (M1-A), `BoundedChannelState`, FNV-1a fingerprints.

## 11. Stop condition

M1-B planning is done when: this plan has an independent DeepSeek plan-review disposition (READY / NEEDS-EVIDENCE / BLOCKED with findings), valid findings are folded into a revision with its digest recorded, `STATUS.md` shows **M1-B PLAN REVIEWED** (not implemented), and no M1-B production/test code has been written. Implementation waits for its own authorization.

---

## Review ask (for `deepseek-reviewer`)

Baseline `fc6ef5e`; plan above; contracts: SPEC §§ 4/4.1–4.2/6/9/10/12, ARCHITECTURE-NOTES §§ 1–4, UX-DX §§ 2–3, MILESTONES M1-B, ACCEPTANCE CORE/POLICY/STATE/PORT/BDD/DX rows, M1-A types (`ConfigSnapshot`, `ProfileSnapshot`, `EffectiveCapabilities`, `requiresNewEpoch`, `selectRoute`, `authorizeRequestDestination`).

Attack the nine points in authorization §8: (1) missing/ambiguous transitions; (2) unsafe `await` boundaries; (3) cancellation races/resurrection; (4) duplicate queue admission; (5) local-vs-remote confusion; (6) UI as second authority; (7) unbounded buffering; (8) excess abstraction/framework; (9) false coverage (mock-only or missing variants). For this rev4 round, verify each M1B3-1..10 fix closes its hole (with line evidence) and re-sweep totality: pick any (phase,event) cell at random and prove it resolves to exactly one row. Concrete counterexamples with event sequences (phase × event traces), severity per REVIEW §3, smallest fixes, and a disposition (READY / NEEDS-EVIDENCE / BLOCKED) required.
