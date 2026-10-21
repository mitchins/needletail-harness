# M2-B Plan — native file tools + ordered partial batches (REV21, planning only)

Baseline: `main` @ `e5cef23` (M2-A merged). Branch: `m2-b-tools`.
No implementation authorized in this session. No M2-C/D, no merge.
REV1 → NEEDS-EVIDENCE (19 findings, folded in REV2). REV2 →
NEEDS-EVIDENCE (9 partial + 10 new, folded below; §8 records both
rounds). This revision is the reviewable plan.

## 1. Goal

Native `read`/`search`/`edit`/`write` (+ `diff` as an operator-side
read command, not a model capability) behind descriptor-relative
containment, strict argument contracts and operator grants;
per-call outcome evidence for ordered partial batches. Certify
TOOL-01…TOOL-12 + PORT-03 with tier-correct native evidence;
STATE/POLICY/UX families stay out. SPEC §8.1–§8.4 are the
contracts. `exec` (§8.5) and `consult` (§8.6) backends are explicitly
EXCLUDED (deferred; both stay capability-denied in M2-B, enforced
by a B5 denial test covering even `--workspace` runs).

## 2. Baseline findings that constrain the plan (verified at e5cef23)

- `WorkspaceRoot` is a value type only (Runtime/WorkspaceRoot.swift:
  5–22, containment "deliberately absent"); unused, pins nothing.
  swift-system 1.8.1 + swift-crypto 5.0.0 + GRDB 7.11.1 are in
  `Package.swift`; ripgrep and git are operator-provisioned
  (DEPENDENCIES.md:42 and rg model). No new dependencies.
- `ToolExecutor.execute(batch:reservation)` returns ONE aggregate
  `ExecutorResult{receipt}` (SessionTransition.swift:107–110);
  `continueAfterEffect` fans that single string onto EVERY proposal
  as `.done` (1384–1397). The actor seam drops per-call data
  twice: `invokeExecutor` passes only `result.receipt.summary`
  into `EffectOutcome` (SessionActor.swift:480–481),
  `EffectOutcome` has only two string cases
  (SessionEvent.swift:45–48), and a non-cancellation throw goes to
  `failEffect`, fanning one `"tool-failure"` string onto every
  proposal as done (SessionActor.swift:482–486;
  SessionTransition.swift:1427–1430). `CancellationError` is
  silently dropped (SessionActor.swift:482–483).
- Dispatch intents carry ONE batch-level `mutating` flag for every
  proposal (computed SessionTransition.swift:1289, applied to all
  intents at 1301–1306;
  `batch.proposals.contains { $0.tool != "read" && ... }`).
  `cancelActive` already splits per reservation by mutating
  (1443: `where reservation.mutating`) but a mixed batch's single
  reservation is mutating if ANY call mutates — read-only calls in
  it are still marked unknown. `OperationReconcile` requires
  intent/result agreement (OperationReconcile.swift:183–186) and
  treats mutating intent-only as unknown+held vs non-mutating as
  re-runnable (14–19, 165–175). `continueAfterEffect` only refuses
  on pre-existing markers (1349–1356); it never adds them.
- `HeadlessApprovals` always returns `.unavailable`
  (RunCommand.swift:758–761); CLI exits 3 (594–599, 642–651).
  `--trusted` sets trustedExec + allAllowed (308–309); default
  workspaceGrant is `.allDenied` (308–313). `ConfigTools`
  defaults every file tool to false
  (ConfigDocument.swift:158–164) — production file caps require
  explicit userConfig opt-in; workspace designation alone grants
  nothing. `chatRequestBody` emits no `tools`/`tool_choice`
  (ChatTransport.swift:243–258); config reserves those keys
  (ConfigLoader.swift:173–190, reservedOptionKeys) — the harness
  injects advertisement, config never carries it.
- `artifactPublished(ArtifactRef)` EXISTS (SessionStore.swift:24–30;
  published post-durability, GRDBSessionStore.swift:733);
  `ArtifactRef` = digest/size/kind/operationID, NO session field
  (SessionStore.swift:173–177); session attribution lives on the
  RECORD ROW (GRDBSessionStore.swift:46–47, 755–758). No fork/
  ancestry capability exists (`SessionExportCommand.swift:7`
  explicitly has no fork; only intra-session `parentEpochID`).
- Quotas are COUNT-only (10k session / 100k global) + 32 MiB
  per-artifact cap (GRDBSessionStore.swift:57–70, 609–610); SPEC
  1 GiB/5 GiB BYTE quotas are unimplemented. `publishArtifact`
  rejects empty bytes (606–608).
- `TerminalSafety.terminalSafe` escapes only Cc/controls
  (TerminalSafety.swift:9–19); bidi Cf (U+202A–202E, U+2066–2069)
  plus Cf marks (U+200E/200F, U+061C, U+200B–200D, U+FEFF) pass
  through. (C0/C1 are Cc — already covered.)
- Case ingestion: `FAMILY_NN_rest` in NeedletailPrimitiveTests
  (= nativeProcess tier); module-pinned `requiredEvidence`
  (XUnitIngestionTests.swift:105–155, 258–289); `.coderabbit.yaml`
  TESTING §2 governs UNLABELED support oracles (no TESTING.md
  file exists). TOOL cases require `[nativeProcess, integration]`
  (integration lax per CaseLedger.swift:296–300); PORT-03
  requires `[nativeProcess]`. `./dev test quick` includes
  PrimitiveTests and `./dev coverage` reconciles it
  (dev:148–149, 248–255, 300) — TOOL native tests join those
  gates (rg/git present or fail-closed skip legs per BDD-04:
  skip ⇒ unsatisfied, never silent). No new test target.
- TOOL-01…12 + PORT-03 are due M2
  (cases/catalog.json:1360–1489, 825–831).

## 3. Critical decision: the partial-batch correction (revised)

Demonstration (accurate for the fan-out path): batch = [edit A
(ok), edit B (stale hash)]. The executor either throws — and one
`tool-failure` string lands on EVERY proposal including the
successful A (A's success evidence is lost; a same-hash replay
becomes a conflict, not a silent re-apply) — or returns one
success (B misreported done). Unstarted C gets a receipt it never
earned; a timed-out call has no vocabulary.

Correction (minimal, no workflow engine — still one executor call
per batch, calls executed sequentially in order):

- New Core `ToolCallOutcome { callID, status, summary, data,
  artifactID?, truncated, warnings[], error?, path?, mode?,
  before_hash?, after_hash?, started: Bool? = nil }`, status ∈ SPEC vocabulary only
  (success | no-match | denied | conflict | invalid-arguments |
  failed | timeout | cancelled — no `unstarted`/`no-entry`
  statuses). `data` is MANDATORY (may be `""` only with an `error`
  explaining absence): read/search carry content/results; edit/write
  carry the machine-readable receipt (path/mode/before/after
  hashes, per B4 below). `mutating` is NOT a per-call wire field:
  the reducer derives it per proposal with the same predicate
  used at dispatch (`tool != read/search/consult`), so there is
  exactly one classification rule and no executor-attested
  divergence is possible; intent/result agreement is checked
  per call by the existing reconciler. `started: Bool? = nil` is the machine-readable dispatch bit
  (the executor sets false for never-dispatched calls, true
  once dispatched; the reducer keys on IT, never on summary
  prose). A missing key decodes as nil under synthesized Codable
  (standard optional semantics — no custom init needed) and the
  reducer treats nil as true (fail-closed); an explicit
  omission leg pins this. Reducer precedence, in order: (1) deterministic
  statuses (success/no-match/denied/conflict/invalid-arguments/
  failed, plus actor-synthesized pre-dispatch receipts) with
  `started != false` → `.done`, no hold, REGARDLESS of omission
  (a claimed result with no contrary bit proves dispatch); a
  deterministic status WITH `started == false` is contradictory
  input (claims a result for a call it also claims never ran) →
  fail closed: mutating `.unknown` + marker + hold,
  non-mutating transcript-only — tested explicitly as a
  wrong-input leg; (2) cancelled/
  timeout + `started == false` → done-cancelled receipt, no hold,
  for mutating AND non-mutating alike; (3) cancelled/timeout +
  `started == true` OR started-field omitted (default true,
  fail-closed) → mutating: `.unknown` + marker + hold;
  non-mutating: transcript-only. `failed` is ALWAYS deterministic
  pre-commit (the executor must never report post-commit
  uncertainty as `failed`;   uncertain post-commit outcomes are
  `timeout`/`cancelled` with `started == true`). Cancellation is
  an async runtime event, not an executor verdict. The contract
  is: the executor CATCHES cancellation itself and reports
  per-call truth — calls it had started are reported
  cancelled with `started == true`; calls it never reached are
  reported cancelled with `started == false`. (A scripted test
  double does this by catching around a gated suspension point;
  production executors structure awaits the same way.) The
  actor's `invokeExecutor` catch is the FAIL-CLOSED fallback for
  executors that propagate instead of reporting: it synthesizes
  per-call cancelled outcomes with `started == true` for every
  proposal in the batch (unknown+hold for mutating), since a
  propagated cancellation proves nothing about dispatch. Both
  paths are tested (executor-handled mixed batch AND
  propagating-executor fallback). `observed_at_seq` is the durable stream position
  (implicit in stream order), NOT a separate field: the executor
  stamps status/summary/data/artifact/truncation/warnings/error;
  sequencing is the reducer's stream order. FLAGGED DEVIATION
  from SPEC §8 (COMPLETE-SPEC.md:356 lists it as a shared field):
  no emitter can know a record's future stream index, so M2-B
  records stream position implicitly and proposes the SPEC
  amendment for M2-C; no silent compliance is claimed.
- `ExecutorResult` KEEPS aggregate `receipt` (transcript/UI compat)
  and gains `calls: [ToolCallOutcome]`. New `EffectOutcome`
  per-call case carries the WHOLE `ExecutorResult` (payload-only)
  across the actor seam: `invokeExecutor` forwards `result`;
  `completeEffect` gains the case; an actor-forwarding test pins
  1:1 delivery.
- Throw policy with typed errors (both sides tested): `execute`
  may throw ONLY before first dispatch, and only two typed errors —
  `ToolFailure.preDispatch(status: denied | invalid-arguments |
  failed, summary)` (arg validation, capability denial) → the actor
  synthesizes per-call `.done` receipts preserving that SPEC status
  (deterministic, no side effect possible); any OTHER throw →
  mutating batches: per-call `.unknown` + marker + hold
  (fail-closed on implementation fault), non-mutating: transcript-
  only. After first dispatch the executor MUST return per-call
  outcomes, never throw (post-dispatch mismatch/exhaustion in the
  scripted backend becomes per-call failed/unknown — the no-post-
  dispatch-throw rule is enforced in the only production
  implementer).
- Reducer iterates reservation proposals IN ORDER, matches by
  callID; per-call `mutating` is classified at dispatch (same
  `tool != read/search/consult` predicate as today) and written
  onto EACH intent — replacing today's batch-wide stamp
  (SessionTransition.swift:1289 computes one flag; 1301–1306
  applies it to every intent) — and EACH result carries the same
  per-call `mutating` (replacing `completedMutating`'s batch-wide
  read in `continueAfterEffect`). The value is DERIVED per call
  by the reducer from the proposal's tool name (same predicate),
  never trusted from the executor — a single classification rule
  means intent/result agreement holds per call by construction,
  verified by a mixed edit+read batch reopened natively
  (reconcile passes; existing all-mutating assertions updated
  to per-tool expectations). Durable encoding per call:
  success/no-match → `.done` + toolResponse; denied/conflict/
  invalid-arguments/failed-pre-commit → `.done` with
  `tool-failure:` outcome prefix (deterministic: the file-tool
  commit protocol makes pre-commit failure side-effect-free);
  timeout-mid-execution/cancelled-mid-execution/no-entry →
  mutating: `.unknown` + marker + hold (existing unknown
  machinery, POLICY-07: never auto-retry);
  non-mutating: NO `operationResult` — transcript-only evidence
  (intent alone reconciles to unstarted, re-runnable, no hold).
  No-entry (executor reported nothing for a dispatched call —
  contract violation, testable by omission) counts as outcome-
  uncertain: same row. (`failed` is ALWAYS deterministic
  pre-commit — the executor must never report post-commit
  uncertainty as `failed`; uncertain post-commit outcomes are
  `timeout`/`cancelled` with `started == true`.) Cancel path and
  stale-retention (`dropRetaining`) split per proposal the same
  way (extending the existing mutating-only `cancelActive`
  precedent). Two cancellation sub-paths, distinguished by who
  reports first: (a) the executor ITSELF catches cancellation
  (primary path) — it reports per-call outcomes through the
  normal `completeEffect` path with truthful `started` flags
  while the reservation is still live (no external
  `cancelRequested` consumed: the executor's own
  deadline/timeout catch, or the gated scripted test calling
  `completeEffect` directly), and the reducer maps them exactly
  like any completed batch (started unstarted calls →
  done-cancelled, no hold); deterministic in tests by blocking a
  scripted executor mid-batch on a gate, then cancelling; (b) an
  external `cancelRequested` arrives while the executor is
  unresponsive (kill-switch path) — `cancelActive` marks all
  live mutating calls unknown+hold AND retains the reservations
  as `state.cancelledPendingReservations` + actor-table
  retention (REQUIRED change above: SessionState field +
  actor-table retention + `completeCancelledPending` handler +
  `checkStale`-first routing + phase rows + termination
  cleanup), so a late executor report replaces markers ONLY for
  `started == false` entries; late started/uncertain entries
  stay dropped against the already-written markers (safe
  direction: the markers subsume whatever uncertain truth
  arrives late). EITHER order
  is fail-closed: per-call truth where available, unknown+hold
  otherwise — never silent continuation and never a false
  done. `dropRetaining` takes NO structured outcome (stale
  content must never certify the current run — a superseded
  generation's results cannot pair with live intents — so its
  unknown stands honestly), but it DOES take the outcome's
  human-readable summary string and embeds it in each unknown
  marker's message (`unknown: stale completion reported '<summary>'`),
  so the evidence §9.1 requires survives for manual
  reconciliation while the hold is preserved.   `dropRetaining` gains one parameter — `summary: String?`, threaded from `checkStale`'s discarded outcome — used ONLY for the marker message, never for certification. For `effectCompleted` the summary is the aggregate `result.receipt.summary` (the per-call `EffectOutcome` case carries the whole `ExecutorResult`, which has no single payload string — the aggregate receipt summary is the defined derivation, pinned by the stale-completed test); for `effectFailed` it is the carried `error: String` (SessionEvent.swift:32) — a stale-failed leg pins the error-threaded marker. Cancel paths
  cannot consult the executor either: the actor runs one
  in-flight effect at a time and a new `reserveEffect` cancels
  the previous task, so every live reservation at cancel time is
  in-flight or was killed mid-flight — genuinely uncertain →
  existing unknown path (consistent with pre-existing crash
  semantics: intent without result reconciles unknown). REQUIRED
  state+actor change (current code has NO transition-side
  cancelled-pending truth — see Finding 1: `transition` calls
  `checkStale` first — SessionTransition.swift:213–219 — and
  `checkStale` reads only `state.liveReservations` — :414–429;
  `cancelActive` clears `state.liveReservations` — :1473–1479 —
  and the actor clears its OWN `reservations` — SessionActor.
  swift:240–250; `completeEffect` guards `reservations[effectID]`
  — :494–500; phase switch has `effectCompleted`/`effectFailed`
  only for `.executing` — :291–294 — with `.cancelling` falling
  to default no-op — :345–350; events carry no
  cancelledPending bit — SessionEvent.swift:31–32; accepted
  entries are never removed from actor `reservations` —
  SessionTransition `continueAfterEffect` removes state-only
  :1375–1376, actor guards :494–510 only). Without state-side
  retention the new `.cancelling` rows are unreachable and
  `completeCancelledPending` has no production path. SCOPE NOTE:
  the executor-handled primary path (executor reports while the
  reservation is still live — its own deadline/timeout catch)
  already works through today's `completeEffect`; this change
  serves ONLY the kill-switch path (external `cancelRequested`
  consumed, late executor report arrives after). The change, all
  in B4: (a) new `SessionState.cancelledPendingReservations:
  [EffectReservation] = []` field (state is source of truth —
  SessionState.swift:393 comment; the actor mirrors it; the
  `replacing` helper gains the new field with default `[]`,
  backward compatible); each entry is a full
  `EffectReservation` with `cancelledPending: Bool = true`
  provenance (flag on the reservation itself for legibility,
  but routing keys on STATE membership, not on the flag alone);
   (b) `cancelActive` (pure transition) MOVES only
  live EXECUTOR reservations to `cancelledPendingReservations`
  (filter `reservation.effectKind == .executor` — the actual
  `liveReservations` also contains provider reservations per
  SessionTransition.swift:1208–1219, :1542–1554, and a cancel
  during provider flight must NOT leave a dangling executor
  pending entry — Finding 1; provider reservations are dropped
  via the existing `consumedEffects` path, never retained) and
  writes unknown markers only for those executor entries —
  generation bump still blocks any new dispatch on those IDs;
  repeat `cancelRequested` is idempotent: if
  `cancelledPendingReservations` already holds the effectIDs
  and `liveReservations` has no remaining executor entries, no
  duplicate markers are emitted (filter on not-already-
  unresolved); actor's `invokeTransport` path keeps its
  existing `catch is CancellationError { return }`
  (SessionActor.swift:390–394) with no new cleanup needed
  because provider reservations are never retained — an
  additional test `cancel-during-provider-flight leaves no
  cancelledPending` proves this;   (c) actor's
  `cancelRequested` handling mirrors the same retention
  (EXECUTOR `reservations` entries moved to a `cancelledPending`
  table, NOT `= [:]`; generation bump blocks dispatch);
  `completeEffect`/`failEffect` lookup changes from
  `guard let reservation = reservations[effectID] else { return }`
  (SessionActor.swift:494–510) to
  `guard let reservation = reservations[effectID] ?? cancelledPending[effectID] else { return }`
  (new `cancelledPending: [EffectID: EffectReservation]`
  table keyed by effectID), so a late kill-switch report is
  NOT dropped in the actor before `transition`/`checkStale`
  runs — it is stamped with the retained reservation's
  runID/generation/revision and forwarded to `transition`;
  after the transition returns, `completeEffect`/`failEffect`
  prune the accepted entry from BOTH actor tables
  (`reservations` + `cancelledPending` plus `consumedEffects`
  set — the set already prevents replay, but pruning makes
  "every live entry" well-defined) and assert the state-side
   `SessionState.cancelledPendingReservations` is removed in the
  kill-switch-then-late-report actor test; (d) new pure transition handler
  `completeCancelledPending` performing SELECTIVE marker
  replacement only for `effectCompleted` — `started == false`
  entries: marker removed, done-cancelled recorded; `started ==
  true`/omitted: marker kept — `effectFailed` is NOT selective:
  it carries only `error: String` (SessionEvent.swift:31–32) with
  no per-call `started` flags, so the handler keeps ALL markers
  (fail-closed: an error during a cancelled flight cannot
  certify any call was unstarted) and embeds the error string
  in the marker message for §9.1 evidence; both cases have NO
  `continueAfterEffect` fan-out and no transcript emission
  (Finding 2); (e) routing: `checkStale` tests
  `state.cancelledPendingReservations` FIRST — if the
  effectID is in that set, route to
  `completeCancelledPending` regardless of generation and
  before the `consumedEffects`/generation/`dropRetaining`
  branches (so a stale-generation late report still reaches
  the selective handler, never `dropRetaining`); a direct
  transition test `effectFailed on cancelledPending keeps
  markers` pins this; (f) new phase-switch rows
  `(.cancelling, .effectCompleted)` and
  `(.cancelling, .effectFailed)` route to the same handler
  (kill-switch lands the run in `.cancelling`, whose rows
  today are tick/transport-failed/cancel-requested only);
  (g) termination cleanup: `invokeExecutor` removes its
  reservation from both actor tables in a `defer` on task
  end (return, throw, fallback-synthesizer paths all
  terminate the task via the existing `inFlight` handle), so
  cancelled-pending entries cannot leak after the executor
  fully terminates without a report; the `defer` also prunes
  the state-side `cancelledPendingReservations` via a
  `cancelledPendingRemoved` marker event if the transition
  did not already (so the state cannot retain a dangling
  entry after the in-flight task is gone); (h) tests: direct
  transition tests (cancelled-pending + late started-false →
  replaced; + late started-true → kept; + stale generation
  still routes to the new handler, never `dropRetaining`;
  repeat-cancel idempotence; `consumedEffects` already
  consumed → no second replacement) and an actor
  kill-switch-then-late-report test proving `SessionState.
  liveReservations` is empty but
  `cancelledPendingReservations` is retained AND that the
  late report is forwarded (lookup includes cancelledPending)
  and then pruned from both actor tables and state.
  A late per-call result arriving after cancel for a
  started/uncertain call is still dropped at `completeEffect`
  against already-written unknown markers for the same
  operationIDs — no evidence lost, no false done. No
  `performedEffects` mechanism is specified — the actor has no
  per-call start visibility inside one `execute(batch)` call,
  and effect-granular marking would lie in both directions.
  The empty-proposals fallback keeps reservation-level
  classification (no proposals to classify — documented).
  Non-mutating calls get NO record on either path (no transcript
  is emitted by cancel/stale handlers — the transcript-only
  rule is executor-path-only, §3 mapping above): the intent
  alone reconciles to unstarted. Tests: cancel-during-flight on
  a mixed batch → mutating unknown+hold with the SAME operationIDs
  as the dispatched intents (pairing check), non-mutating absent
  from the record log; stale completion with per-call outcomes →
  mutating markers carrying the stale summary in the `unknown:`
  message (never trusted as current-run done), non-mutating
  absent.
  NEVER-DISPATCHED is not unknown (R4 finding — a provably
  unexecuted call must not claim unknowability, and an unexitable
  hold would brick the session with no reconcile command
  available): the executor reports halted-remaining calls with
  status `cancelled`, summary `unstarted: halted after <callID>`,
  and the reducer records `.done` with that cancelled receipt for
  BOTH mutating and non-mutating calls — provably no side effect,
  so no hold. The cancelled-mid-execution vs cancelled-before-
  dispatch distinction is the executor's to report truthfully
  (it knows which calls started); only the former can hold.
- Dispatch policy (stated as POLICY CHOICE, not SPEC mandate):
  halt at the first outcome that is not success/no-match; the
  rest are reported by the executor as EXPLICIT unstarted entries
  — status `cancelled` with summary `unstarted: halted after
  <callID>` (cancellation of dispatch, SPEC-legal; no invented
  status), never omitted. Rationale: conflicts evidence external
  change; executing later mutations without revalidation compounds
  it. The reducer records them `.done` (no hold — see above); the
  batch COMPLETES with mixed receipts and the next turn is a new
  model decision on full evidence, never an auto-retry. The
  normative example stands as specified behavior: [A ok, B
  conflict, C unstarted-cancelled-done] with C never dispatched —
  pinned by TOOL-09 tests.
- Transcript rule (SPEC §7.2: a tool call is never cut away from
  its result — COMPLETE-SPEC.md:336): EVERY proposal in a batch
  that completes through the executor gets a transcript
  `toolResponse` in order, including calls with no
  `operationResult` (evidence ≠ state claim). Cancel-requested
  and stale batches are out of scope for this rule: they go
  through `cancelActive`/`dropRetaining`, which emit records
  only (markers for mutating, nothing for non-mutating) —
  there is no executor output to transcribe. Order-preservation
  is observed via transcript order + log scan (present
  done/failure receipts,
  explicit unstarted entries,
  absent operationResult exactly for non-mutating unknown).
- Rerun claim, scoped honestly: receipts stand durably and no
  fake atomicity is claimed; re-proposal is operator/model-driven
  with full evidence visible. No automated cross-run replay.
  Holds need no in-session clearing because sessions are single
  CLI runs (fresh session UUID per invocation, `RunCommand`
  composition root): a held queue is a terminal diagnostic for
  THAT run (exit 4 with the ambiguous-delivery message, claim
  retained), and the next run starts clean with exported evidence
  (A5-2) available. There is deliberately no in-session
  abandon/reconcile command (explicit non-goal; multi-run
  reconciliation is M2-D territory if ever). The guarantee is
  evidence preservation + never-auto-retry.
- Migration: ScriptedToolBackend emits per-call entries; existing
  `ExecutorResult(receipt:)` test callers updated deliberately
  with RED/GREEN (empty-calls + multi-proposal must reconcile to
  unknown, never done).

## 4. Slices (implement → native tests + RED probes → DeepSeek review)

### B1 — containment, strict args, grants, lock (TOOL-07, PORT-03)
- Seams: `WorkspaceRoot` + new Runtime resolver: open workspace +
  read roots as directory fds at startup (O_DIRECTORY|O_NOFOLLOW),
  pin device/inode. Every traversal RE-OPENS the configured root
  path (O_DIRECTORY|O_NOFOLLOW), fstats the fresh fd, and
  compares dev/ino to the pinned identity — mismatch (root
  replaced, symlink-swapped) → fail closed before any descent —
  then traverses from the freshly validated fd (never the stale
  pinned fd, never string-prefix checks, never
  realpath-then-unguarded-open). Symlink root → the re-open
  with O_NOFOLLOW fails / identity mismatches → reject with
  message (use the real path).
  Descriptor-relative no-follow traversal (FileDescriptor/openat
  chain on keyed dir fds; Glibc-direct fallback — the openat
  layer itself is NEW B1 code, reviewed in the B1 slice, not
  claimed from `BoundedFileRead`, which uses path-based
  `open(O_NOFOLLOW)`). Never string-prefix checks, never
  realpath-then-unguarded-open. Byte-exact paths (PORT-03:
  case-sensitive distinct, NFC≠NFD distinct, no normalization).
  Hardlinks: treated as regular files (indistinguishable in-kernel;
  planting one presumes workspace write access = the excluded
  same-user attacker) — NO hardlink-denial claim.
- Protected paths: ABSOLUTE denials (never grantable):
  tool-private state, credential paths, artifact dir. Grantable
  ONLY via explicit per-batch operator approval with the paths
  enumerated in the approval description: `.git`, `.env`
  variants, `.ssh` (SPEC §8.1: explicit user grants suffice).
  Mechanism: new pure Core validator
  `validateBatchArguments(batch:) -> [ValidatedToolCall]` (tool
  name + extracted paths + op class per call; throws
  `ToolFailure.preDispatch` on malformed args — PRE-side-effect,
  so no FS touch precedes it). `enterAuthorising` runs it BEFORE
  building the request: validation failure → deterministic
  per-call done receipts preserving the SPEC status (B4 throw
  policy), never a generic authorising crash. `ApprovalRequest`
  gains `protectedPaths: [String]` (default `[]`, backward
  compatible); `enterAuthorising` populates it from the
  VALIDATED paths ∩ the protected set (validation, not a model
  flag, decides what is listed); `describe(batch:)` is
  re-specified as pure formatting over the same validated calls
  (a formatting failure falls back to tool names only — never a
  denial bypass); the gateway shows the list and the operator's
  approve covers exactly the listed paths (unlisted protected
  paths stay denied — tested: approved batch with listed path
  proceeds, unlisted protected path in the same batch is
  denied). Transition-level approval test: a batch naming a
  grantable protected path yields a request whose
  `protectedPaths` names it. The fixed-argv harness `git`/`rg` subprocesses are
  NOT native reads — they never traverse the containment
  boundary (see B2/B5 carve-outs), so B5's diff does not need
  a grant.
- Roots: NEW B1 options `--workspace` (must exist) + `--read-root`
  (read-only; never write roots, never exec-cwds) — both
  absent today (RunCommand.swift:20–50) and added in this slice
  with NEW exit-2 validations: `--workspace`+`--trusted` → exit 2,
  `--workspace`+`--sealed` → exit 2, `--read-root`+`--sealed` →
  exit 2 (each tested). Without `--workspace`, mutating tools are
  denied. `--read-root` works standalone (reads/searches need no
  workspace, but not with `--sealed` — see Production wiring
  matrix); mutation (edit/write, preimages, lock) requires
  `--workspace`. Grant
  derivation, per class (this resolves the blanket allDenied):
  read/search REQUIRE userConfig opt-in AND (workspace-designated
  `--workspace` OR at least one `--read-root`) AND invocation AND
  seal rules; edit/write REQUIRE userConfig opt-in AND
  `--workspace` present AND invocation AND per-batch approval;
  exec/consult are denied regardless of flags. (Flag-conflict
  rejections above are NEW validations, not "existing rules".)
- Args: strict Codable + hand validators (unknown fields, duplicate
  keys, overlong strings, int ranges, enum values fail
  PRE-side-effect). Required capabilities computed from the
  validated operation, never from a model `safe` flag.
  Advertisement is discovery-only: execution still validates via
  strict Codable/hand validators (SPEC §8:358), never a generic
  schema interpreter.
- Lock: private-state lock file keyed by workspace identity
  (`<root>/.needletail/lock`), flock LOCK_NB (fail closed on
  contention, never hang). ONE granularity, stated once:
  acquired ONCE per mutating batch, before the first mutating
  call (after arg validation), held through the last commit;
  per-call re-read + hash happen under the HELD lock. If
  acquisition fails, the call being dispatched fails closed with
  typed `failed` (deterministic: the lock precedes any mutation,
  so no side effect occurred); already-completed calls stand,
  and all later calls — including reads — are unstarted per
  the halt rule (explicit `unstarted: halted after <id>`,
  never silently skipped, never marked failed).
- Tests (native, real FS temp dirs): `TOOL_07_…` symlink/parent-
  swap/`..`-escape denials + FIFO/socket/device/directory legs
  a hardlink-inside-root behavior leg (treated as a regular
  file: read succeeds, edit replaces the link — pins sane semantics
  without a denial claim, reconciling the catalogue's
  "hardlink" aspect); `PORT_03_…` case/Unicode-
  distinct legs; protected-path denials incl. symlink-to-`.git`;
  absolute-denial legs (tool-private/credential/artifact paths
  ungrantable even when approval offers them); grant-override
  allow-path via approval (approved batch with listed protected
  path proceeds, unlisted does not); arg-shape matrix (each
  invalid shape fails before any FS touch — assert no file
  created); root-swap (replaced root dir → fstat mismatch → fail
  closed); lock contention (externally held lock → honest busy
  failure).
- Counterfactuals: prefix-check shim (must fail B1 tests);
  deterministically gated realpath-once interleave (must fail);
  normalization shim (must fail PORT-03); unknown-field
  acceptance (must fail).
- Exclusions: no exec-cwd execution; no Windows semantics.

### B2 — read/search (+artifact scoping) (TOOL-01, TOOL-02, TOOL-03, TOOL-11)
- Read: exactly one of allowed-path | session artifact ID;
  bounded lines (default 200) + result budget; exact bytes +
  line/range metadata + SHA-256 + truncation flag; binary/non-UTF-8
  → unsupported-content result (no replacement corruption); hidden
  project files included subject to B1 deny paths.
- Artifacts: REUSE existing `artifactPublished` (no new record).
  New store seam `artifactRecord(session:digest:)` — resolves an
  ID only if an `artifactPublished` row for the CURRENT session
  names that digest (row-level session attribution already
  exists). Two-session test: foreign ID → denied; same-session
  → allowed. (No fork/ancestry grants exist — no such leg.)
- Search: operator-provisioned `rg`, absolute path pinned once at
  startup + ownership (not world-writable) check + `rg --version`
  semver gate (fail closed; missing/too-old/shadowed → denied
  result, plus a PATH-shadowing test proving a shim earlier on
  PATH is never used); harness-fixed argv only (`--json`,
  `--hidden`, bounded globs, result limit, `--` separator; ignore
  files honored as user exclusions); env scrubbed
  (`RIPGREP_CONFIG_PATH` et al. removed); no `--pre`, no model
  flags, no symlink-follow outside root; harness-owned deny
  globs are part of the FIXED argv (TWO layers per protected
  area — bare directory-prune + contents — because ripgrep
  prunes a directory ONLY when the directory itself matches:
  `--glob '!.git/'`, `--glob '!**/.git/**'`; `--glob '!.env*'`,
  `--glob '!**/.env*'` plus bare `.env` variants; `--glob
  '!.ssh/'`, `--glob '!**/.ssh/**'` — rg itself never
  descends into pruned directories, not merely hides hits);
  `rg --files` for discovery (empties listed, never read). Hits
  are additionally post-filtered through the B1 protected-path
  predicate as defense-in-depth (explicitly layered: prune is
  the guarantee, post-filter catches harness bugs — never the
  sole mechanism). Continuations are single-session:
  opaque token (query hash + offset + result-hash prefix); resume
  re-executes and prefix-verifies, else restarted-label (no
  stable-offset fiction, no stale reads).
- Tests: `TOOL_01_…` over-budget/binary legs; `TOOL_02_…`
  leading-dash/regex/glob-metachar legs per mode; `TOOL_03_…`
  poisoned-env (`RIPGREP_CONFIG_PATH` + fake `--pre` shim first on
  PATH — must be ignored), shim-`rg` shadowing leg, symlink-out
  leg, `.git`-hit exclusion leg, missing/too-old-rg fail-closed
  legs; `TOOL_11_…` cross-session denial + same-session allow.
  Non-traversal proof legs (guarantee: rg never OPENS or
  reads protected paths; prune is proved, not inferred): argv-
  capture test asserting the fixed argv contains BOTH bare-prune
  (`!.git/`) and contents (`!**/.git/**`) globs for every search
  invocation; 000-DIRECTORY sentinel AT the protected directory
  itself (`.git` dir chmod 000 — `opendir` on it fails loudly
  if rg ever descends; a file INSIDE `.git/` would be pruned and
  proves nothing — corrected from the previous inside-file
  sentinel, which was invalid because its parent `.git` is
  pruned);    complementary open-audit leg where available
  (strace/open capture showing no `openat` on a protected
  path); prune-regression probe that actually goes RED:
  removing the bare `!.git/` glob (keeping `!**/.git/**`)
  must cause the 000-directory descend proof to FAIL (rg
  attempts `opendir` on `.git` and the permission error is
  observed) — the prior hit-exclusion probe with only
  `!**/.git/**` still passes even without the bare prune, so
  it cannot prove pruneness (Finding 8).
- Counterfactuals: ambient-config inheritance (must fail TOOL-03);
  model-flag passthrough (must fail); PATH-shim execution (must
  fail); unfiltered `.git` hit (must fail); artifact-ID-as-
  capability (must fail TOOL-11); replacement-char read (must
  fail TOOL-01).
- Exclusions: no semantic navigation/SCIP claims; no offset-
  stability promises; consult untouched.

### B3 — edit/write + byte quotas (TOOL-04, TOOL-05, TOOL-06, TOOL-08)
- Edit: path + expected SHA-256 + exact old bytes + replacement.
  Zero matches → no-match; multiple → invalid-arguments; stale hash
  → conflict; empty old → invalid-arguments. Byte-level ops only
  (no Unicode/line-ending normalization); preserve permissions
  (capture st_mode via fstat, fchmod tmp before rename; ownership/
  xattrs documented as limits) + newline conventions; same-dir tmp
  + checked write + fsync + rename; before-image artifact with
  `artifactPublished` metadata; re-read + hash immediately before
  commit under the B1 workspace lock. Optimistic check ONLY —
  residual same-user race documented; no multi-file atomicity.
- Write: `create_new` exclusive (exists → error); replacement =
  same boundary/checks/artifacts as edit; explicit confined parent
  creation; no deletion tool.
 - Per-call receipt metadata (no schema change): the canonical
  outcome JSON carries path, mode, before/after hashes
  (§3 outcome mapping above); the preimage BYTES go through
  `publishArtifact` (32 MiB cap). Zero-byte originals: hash-only
  receipt (sha256-empty is constant), no empty publish.   NEW
  cross-process artifact lock (B3 — does NOT exist today:
  GRDBSessionStore.swift has only a process-local `NSLock gate`
  at :65 and no flock/LOCK_EX anywhere; `queue.write`
  serializes DB rows but NOT the artifact filesystem at
  :661–728 vs :733–759): new file `<db>-artifacts.lock` with
  `flock(LOCK_EX)` (blocking, fail-closed on error), acquired
  BEFORE the in-process `gate`, held through the entire tmp
  create → verify → rename → DB commit → conditional cleanup
  sequence, released after (acquisition order: artifact lock →
  gate → queue.write; never gate before artifact lock — total
  order prevents deadlock with `reconcileByteUsage` which
  acquires the same two locks in the same order). Order under
  BOTH locks: re-read/hash → pre-publish quota PREFLIGHT
  estimate (fail fast, nothing written — advisory only, using
  per-session logical + global physical estimates) → create tmp
  file outside the transaction but still under the artifact
  lock (so no other publisher can race the filesystem) →
  ATOMIC commit inside ONE `queue.write` under the same
  artifact lock + gate: (1) authoritative quota check
  (session logical + global physical distinct) — if over quota,
  throw BEFORE any rename/insert (tmp remains, will be
  cleaned); (2) re-verify tmp `O_NOFOLLOW`/`fstat`/`fsync`;
  (3) re-check `artifact_physical`/existing
  `artifactPublished` reference INSIDE the txn — this is the
  ONLY dedup check that matters (the earlier filesystem
  `FileManager.fileExists` at :661 is retained as a fast
  pre-check but is NOT trusted for dedup; the txn re-check is
  authoritative, so the "between tmp creation and txn" race is
  closed by definition — there is no trusted window before the
  artifact lock, so the only committed state that can appear
  "between" is a publisher that committed BEFORE this call
  acquired the artifact lock — Finding 3); if that earlier
  publisher committed, treat as dedup (no rename, no physical
  growth, only session logical reference if this session hasn't
  referenced it); (4) rename tmp→final +
  `syncArtifactDirectory`; (5) insert `artifactPublished`
  reference + upsert `artifact_physical` (insert-or-ignore) +
  increment `byte_usage` (only if this session hadn't
  referenced the digest) + envelope records. BEFORE this,
  GRDBSessionStore split verification (:661–692) and commit
  (:733–759) with file ops outside the DB txn — a second
  publisher could verify the existing file before this cleanup
  deletes it, leaving a dangling reference. Closure by joining:
  dedup re-verify, file rename, reference insert, physical
  upsert, and quota increments are inside the single
  artifact-locked `queue.write`. On quota or insert failure the
  `queue.write` throws and rolls back (no reference/physical
  row is committed); the just-written tmp (or newly renamed
  final, if rename happened before the throw) is then checked
  in a SECOND `queue.write` + SAME artifact lock STILL HELD
  across the rollback-to-cleanup boundary (the artifact lock
  is NOT released on transaction failure — it is held for the
  whole publish call), so the check sees committed state:
  delete ONLY when NO committed `artifactPublished` reference
  for this digest exists AND no committed `artifact_physical`
  row for it is live — NOT merely `createdNewFile` (the only
  committed "between" that can exist is a publisher that
  committed BEFORE this lock acquisition; the lock held across
  the two txns guarantees no third publisher commits between
  rollback and cleanup). Two serialized barrier legs (no
  impossible concurrent hold — Finding 3 corrected): (A)
  B commits fully before A acquires the artifact lock → A
  acquires, re-checks inside its txn, sees B's committed
  reference/physical, dedups and keeps B's bytes (no second
  file); (B) A creates tmp, fails quota/throws, cleans
  (deletes tmp/final because no committed reference exists)
  before B acquires → B acquires, re-verifies inside its txn,
  sees no final file / no physical row, and writes the file
  anew rather than referencing a deleted inode; plus a
  blocking leg proving B blocks while A holds the artifact
  lock (deterministic via gate). Crash between rename and
  reference commit orphans bytes that NEVER incremented
  `byte_usage` or `artifact_physical` (under-counted);
  crash-orphans are explicitly allowed (SPEC §9), documented,
  not tested as impossible. Pre-publish free-space check:
  refuse (denied result, not a crash) when the artifact
  filesystem has less than the SPEC §9.2 256 MiB reserve.
  Dedup/reference tests: two sessions publish identical bytes →
  second session's reference-commit failure must leave the
  first session's bytes and reference intact; the
  `first-publisher-fails` branch is now the serialized
  B-before-A case above (B committed before A's lock; A keeps
  B's bytes) — the prior "B commits between tmp creation and
  failure while A holds the lock" is withdrawn as impossible
  under the lock; barrier legs are the two serialized orders
  above.
 - Byte quotas (new store accounting — two-stage, coherent —
  fixes prior under-specification + double-count + missing
  paths): 1 GiB per-session logical / 5 GiB global physical
  over records + artifacts + preimages. Schema (new, explicit):
  `byte_usage(session TEXT PRIMARY KEY, bytes INTEGER NOT NULL)`
  added to the store's declared shape (per-session LOGICAL
  bytes: sum of record payload sizes already committed for that
  session + artifact sizes for digests that session's
  `artifactPublished` rows reference — same `records` session
  column used for record counts) + `artifact_physical(digest
  TEXT PRIMARY KEY, size INTEGER NOT NULL)` for GLOBAL
  physical distinct bytes (one row per distinct digest ever
  published, regardless of how many sessions reference it);
  `schemaVersion` 2→3 with a migration creating both tables
  AND backfilling BOTH via recompute-to-expected (Finding 4):
  scan all committed `records` rows — `SELECT session, payload
  FROM records` — decode each `artifactPublished` `ArtifactRef`
  (digest/size/kind per SessionStore.swift:173–187; session is
  in `records.session` per 204–214, :755–758 — NOT in the ref),
  build per-session distinct digest sets, join to
  `artifact_physical.size` to compute per-session distinct
  artifact sums + `SUM(LENGTH(payload))` for record bytes, and
  insert into `byte_usage`; insert distinct digests into
  `artifact_physical` (distinct, not raw payload sum — the prior
  "scan records payloads → sum per-session bytes" omitted
  artifacts and proved non-idempotent additive bumps; now
  recompute-to-expected is demonstrably idempotent, second run
  sets same values). Empty tables for a fresh store. A v2-
  store-with-artifact migration test seeds a v2 DB with a
  `records` row containing an `artifactPublished` digest and
  verifies the v3 open backfills `artifact_physical` and
  per-session `byte_usage` correctly. FORWARD-ONLY
  incompatibility stated honestly (old binaries fail closed on
  a newer `user_version` — GRDBSessionStore.swift:50, :109–113
  — and on shape mismatch — :121–124 declaration is the v0
  foreign-table branch while :204–245 is `assertSchemaShape`
  — so a v3 store is unreadable to v2 binaries; the v0
  foreign-table check and `assertSchemaShape` follow
  `declaredShape`, covering the new tables; an old-binary/new-
  store test pins the fail-closed integrity error). Record
  bytes: EVERY durable record-insert path updates `byte_usage`
  inside its SAME `queue.write` transaction — `append`,
  `appendBatch`, `publishArtifact` reference-commit, AND the
  direct `INSERT INTO records` at `recoverWriterOwnership`
  :540–545 (previously missed — Finding 5), plus any future
  direct inserts must follow the same rule (enforced by a
  helper `insertRecordWithQuota` used by all paths). Each path
  increments by the encoded payload size; artifact path
  increments `byte_usage` only if this session hadn't already
  referenced the digest (dedup-aware per-session) and upserts
  `artifact_physical` (insert-or-ignore) for the global
  distinct. Global physical: `artifact_physical` is inserted
  (or ignored if digest already present) inside the SAME
  transaction as the `artifactPublished` reference — global
  check reads `SUM(size) FROM artifact_physical` + sum of
  `LENGTH(payload)` from `records` (records are not deduped)
  + physical orphan files still on disk but not yet in
  `artifact_physical` (see orphan attribution), NOT
  `SUM(byte_usage)` (which would double-count cross-session
  dedup — the prior `SUM(byte_usage)` implied global was
  corrected here to `SUM(artifact_physical)` + records).
  Preflight (advisory, pre-publish): computes this call's
  logical new bytes (dedup-aware per-session) and session
  logical + global physical estimates, fails fast with nothing
  written. Authoritative session + global checks + increments
  run inside the reference-commit `queue.write` transaction
  (same fail-closed shape as count quotas), with cross-session
  dedup already accounted via `artifact_physical` distinctness
  (a second session referencing an already-physical digest
  increments `byte_usage` but NOT `artifact_physical` — no
  global double-count). Orphan attribution (split rule —
  Finding 6): an orphan file (on-disk final bytes with no
  committed `artifactPublished` reference) has no `byte_usage`
  row (no owning session) and no `artifact_physical` row
  (never committed) — it is counted ONLY in the global
  physical via the orphan scan, never in any session's
  `byte_usage`; a committed reference whose session's
  `byte_usage` was never bumped (crash between reference
  insert and `byte_usage` increment — now impossible inside
  the single txn, but historically via migration) is healed
  by `reconcileByteUsage` inserting the missing
  `artifact_physical` row and bumping THAT session's
  `byte_usage` — orphan → `artifact_physical` only,
  missing logical → that session's `byte_usage`. Orphan
  accounting: crash-orphaned bytes are UNDER-counted in both
  tables (never incremented); the orphan scan
  (`detectArtifactOrphans`, which today only reports — :787–789
  with point-in-time/offline warning — :787–796) gains a
  SEPARATE `reconcileByteUsage` step run BEFORE the read-only
  B5 gate under the store's cross-process lock + `queue.write`
  (see B5 for ordering/serialization/failure mode) — it does
  NOT call `detectArtifactOrphans` under that lock (Finding 7:
  that method pages `records(since:)` which re-enters `gate`
  + `queue.read` :378–396 and would deadlock) — instead it
  runs raw SQL inside the transaction
  (`SELECT session, payload, LENGTH(payload) FROM records` —
  Finding 5: session is in `records.session`, not in
  `ArtifactRef` — plus `SELECT digest, size FROM
  artifact_physical` plus `FileManager` directory listing, all
  inside the same `queue.write` before any re-entrant
  `records(since:)`), decodes each `artifactPublished`
  digest, joins to `artifact_physical.size`, aggregates per-
  session distinct sizes (so a missing logical attribution is
  per-session, not global), and recomputes-to-expected (Finding
  4: sets `byte_usage`/`artifact_physical` to the computed
  expected totals, not blindly "bumps additively" — second run
  is demonstrably idempotent). It is idempotent, raises toward
  physical reality, never lowers; a seeded-orphan test pins
  `artifact_physical` creation with no `byte_usage` row, and a
  two-session missing-logical test pins the per-session
  `session`/`payload` attribution. Record-byte + dedup +
  migration tests: append path increments `byte_usage`;
  `recoverWriterOwnership` audit increments; second session dedup
  does not grow `artifact_physical`; orphan has no `byte_usage`
  row; migration backfills per-session distinct artifact sizes
  via the `records.session` join.
- Tests: `TOOL_04_…` zero/one/multiple/empty legs;
  `TOOL_05_…` injected change between read and commit → conflict
  receipt, file untouched, no preimage; `TOOL_06_…` CRLF/no-final-
  newline/emoji/combining fixtures byte-preserved + mode-
  preservation leg; `TOOL_08_…` exists-refusal + stale-hash legs;
  quota legs (preflight over-quota → fail closed, nothing
  written; authoritative over-quota at commit → fail closed +
  just-written bytes cleaned up iff unreferenced, nothing
  renamed; orphan-reconcile leg (seeded orphan file →
  `artifact_physical` created, no `byte_usage` row); two-session
  missing-logical leg (committed reference without `byte_usage`
  → that session's row recomputed); migration leg (v2 store with
  artifact → v3 backfills `artifact_physical` + per-session
  `byte_usage` via `records.session` join); old-binary/new-store
  leg (v2 binary on v3 store → fail-closed integrity error);
  sub-reserve free space → denied receipt, never a crash).
- Counterfactuals: fuzzy matcher (must fail TOOL-04);
  normalization shim (must fail TOOL-06); deterministically gated
  lock-removal interleave (must lose-update without the lock,
  must conflict with it); silent overwrite (must fail).
- Exclusions: no rollback of user changes, no `git reset`, no
  deletion, no cross-filesystem atomicity promises.

### B4 — ordered partial batches (TOOL-09 + mechanism)
- Seams: `ToolExecutor` per-call contract (§3); `EffectOutcome`
  per-call case + `invokeExecutor` forwarding (no silent
  `CancellationError` drop — cancellation maps to per-call
  cancelled); per-call intent `mutating` at dispatch (replacing
  the batch-wide flag); per-call cancel split (extending the
  existing mutating-only precedent); `continueAfterEffect`
  per-call fan-out in proposal order; ScriptedToolBackend
  per-call emission (post-first-dispatch mismatch/exhaustion
  becomes per-call outcomes, enforcing the no-post-dispatch-
  throw rule in the only production implementer).
- Timeout machinery: per-tool deadlines (local I/O 30 s,
  search/diff subprocess 120 s), executor-enforced, injectable
  for tests; deadline expiry → timeout outcome; hanging-`rg`
  shim test; fault-injecting scripted delay test.
- Behavior (§3 mapping, normative example pinned):
  [write A ok, write B conflict, C unstarted] → A done stands, B
  done-with-`tool-failure:`, C done-with-cancelled-unstarted
  (never dispatched, NO hold — provably no side effect).
  Timeout injection → deadline outcome → unknown+hold for
  mutating (genuine uncertainty), transcript-only for
  non-mutating. Mixed read/write batch test pins per-class
  handling. Throw policy: pre-dispatch typed throw → actor
  synthesizes per-call done receipts preserving status; any other
  throw → mutating unknown+hold / non-mutating transcript-only.
  Post-dispatch never throws. Lock contention (B1 lock) is a
  deterministic pre-commit failure of the call being dispatched
  → that call gets typed `failed` (no side effect possible);
  already-completed calls stand and later calls are unstarted
  per the halt rule (see B4 mixed-batch lock leg).
  Migration (delib-
  erate, RED/GREEN): per-proposal intent `mutating` AND per-call
  result `mutating` (both replace their batch-wide flags, so
  intent/result agreement holds per call — verified by a mixed
  edit+read batch reopened natively: reconcile passes), per-call
  cancel split (extending the mutating-only precedent;
  empty-proposals fallback unchanged), `dropRetaining` per-proposal
  split; existing actor tests that assert all-mutating intents
  (e.g. edit+read batches) are updated to per-tool expectations.
- Tests: `TOOL_09_…` second-file-fails matrix (edit + write mixes);
  prior-success-survives leg; unstarted leg (mutating C AND
  non-mutating C variants: done-cancelled with `started == false`,
  NO hold, run continues to next turn — the old held-unstarted
  expectation must FAIL against this code); unknown-not-retried
  leg (timeout injection on a mutating call → held; second turn
  without reconcile stays held); cancelled-mid-execution leg
  (scripted executor reports started-cancelled for a mutating
  call → unknown+hold; non-mutating → transcript-only);
  order-preservation leg (transcript order + log scan);
  mixed-batch leg; no-entry leg (backend omits a dispatched call
  → mutating: marker+hold, non-mutating: transcript-only);
  pre-dispatch typed-denial leg (all done-denied, no hold);
  pre-dispatch invalid-arguments leg (all done-invalid, status
  preserved); pre-dispatch failed leg (workspace-unusable/
  lock-broken fixture → all done-failed); pre-dispatch
  untyped-throw leg (mutating unknown+hold); started-omission
  leg (executor omits `started` on a cancelled call → treated as
  true → unknown+hold for mutating); success-with-started-false
  leg (contradictory input → fail closed: mutating unknown+hold,
  non-mutating transcript-only — a result for a call claimed
  never-run proves nothing); executor-handled-cancellation leg (scripted
  executor blocks on A via gate, its own deadline fires, executor
  catches and reports A started/cancelled + B unstarted-cancelled
  through `completeEffect` with the reservation still live (no
  external `cancelRequested` consumed) → A unknown+hold, B
  done-cancelled with NO hold — the queued never-dispatched
  case, deterministic via the gate);
  propagated-CancellationError leg (executor rethrows mid-batch
  → actor synthesizes started-cancelled for all → mutating
  unknown+hold); mixed-cancel leg (cancel-during-flight on a
  mixed batch → mutating unknown+hold with the SAME operationIDs
  as the dispatched intents, non-mutating absent — no transcript
  from cancel/stale paths); late-unstarted-replacement leg
  (cancel writes markers and retains cancelled-pending
  reservations; then the executor's late report attests one call
  `started == false` + one `started == true` → the unstarted
  marker is REPLACED by done-cancelled, the started marker
  stands — proves retention, not clearing);
  cancelled-pending transition legs (direct: stale-generation
  late completion routes to `completeCancelledPending`, never
  `dropRetaining`; the handler performs no `continueAfterEffect`
  fan-out and emits no transcript); actor
  kill-switch-then-late-report test (external cancel consumed,
  then late executor report → selective replacement per above);
  stale-completion leg (superseded generation: stale per-call
  outcomes are never trusted as current-run done → mutating
  markers carrying the stale summary (existing tests asserting bare `"unknown"` markers are updated to the `unknown: stale completion reported '<summary>'` form — deliberate RED/GREEN migration), non-mutating absent); stale-failed leg
  (superseded generation `effectFailed`: the carried error string
  threads into the marker message the same way, non-mutating
  absent); post-commit-failure leg (write
  applied then timeout reported → unknown+hold despite the
  successful write: conservative and tested); mixed-batch lock
  contention leg ([read A ok, write B lock-fails, read C] → A
  done stands, B done-failed, C unstarted-cancelled with NO hold
  — halt rule applies after the failed lock acquisition).
- Counterfactuals: aggregate-receipt shim (must fail TOOL-09);
  unstarted-marked-unknown (must fail — no false unknowability);
  unknown auto-retry (must fail — second dispatch without
  reconcile); out-of-order evidence (must fail); post-dispatch
  throw (must fail); Cc-only sanitizer is B5's, not here.
- Exclusions: no workflow engine/branching, no cross-batch
  transactions, no exec/consult batches (capability-denied, B5
  denial test).

### B5 — diff, advertisement, production wiring, qualification (TOOL-10, TOOL-12)
- Diff: OPERATOR-side read command (`needletail diff`), NOT a
  model capability (no `ToolCapabilities` bit; model-invoked diff
  stays denied — tested). Fixed argv (`--no-color --no-ext-diff
  --no-textconv --no-pager --no-optional-locks`, worktree cwd) +
  minimal env allowlist (LANG, TZ only; `GIT_DIR`,
  `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
  `GIT_EXTERNAL_DIFF`, `GIT_CONFIG_PARAMETERS` each scrubbed and
  covered by a test) + absolute pinned `git` (same provisioning
  model as rg). Dirty worktree supported natively; output bounded
  into artifacts. TOOL_10_ native + binary legs incl.
  `diff.external` and textconv-driver cases. Missing git
  (DEPENDENCIES.md:44 — git-specific features disable with a clear
  explanation): when the absolute pin is absent/unexecutable, diff
  → denied result explaining git is unavailable (not a crash,
  not silent); all non-git tools unaffected — a dedicated leg
  with git removed from PATH pins this.
- Advertisement: harness-owned strict JSON Schema tool
  definitions for read/search/edit/write (exact-schema tests);
  config reservation stands (harness injects, config never
  carries); scripted round-trip proving a model proposal reaches
  the executor. Execution still validates via strict Codable/hand
  validators — advertisement is discovery-only.
- Production wiring: full (read + mutating) real file-tool
  executor composed ONLY with explicit `--workspace` + per-mutating-
  batch interactive `ApprovalGateway` approval (new TTY gateway
  over the existing line editor; selection: TTY + workspace mode
  + mutating batch → prompt). A read-only composition (read/search
  only, no mutating tools) is allowed with `--read-root` alone. `--workspace` + `--trusted` conflict → reject
  (exit 2). Headless → unavailable → exit 3 (existing path).
  Composition seam (named, current code has none: `RunCommand`
  hard-codes `ScriptedToolBackend` + `HeadlessApprovals` at
  552–560 while `ToolExecutor.execute`/`EffectReservation` carry
  no session/store/writer — SessionTransition.swift:62–79,
  125–129 — yet `publishArtifact` requires a session and
   `WriterIdentity` — GRDBSessionStore.swift:596–599): new
  `FileToolRuntime` enum (`scripted(ScriptedToolBackend)` |
  `native(NativeToolExecutor)`) + `NativeToolExecutor` struct
  capturing the claimed session, store writer identity, artifact
  publisher closure, and workspace resolver at construction.
  Construction order (durable path only — after
  `claimWriterOwnership`, before actor init; sealed runs use
  `EphemeralStore` with `grdb == nil` and NO claim block —
  RunCommand.swift:391–398, :484–519 — so there is no writer
  identity and no durable artifact publisher to capture; sealed
  mode forces `ToolCapabilities.allDenied` —
  Capabilities.swift:109–110, `SealedRestrictions` doc :71–76).
  Full selection matrix (NEW B1/B5 options — see Roots below;
  `--workspace` + `--read-root` do not exist today —
  RunCommand.swift:20–50 defines only config/prompt/trace/
  format/tools/alias/max-turns/sealed/trusted): `--workspace`
  without `--trusted` without `--sealed` → native full;
  `--workspace` + `--sealed` → reject (exit 2: sealed runs are
  tool-free by `SealedRestrictions` — the invocation is malformed
  for a file-tool run, NEW validation); `--workspace` +
  `--trusted` → reject (exit 2, NEW validation — not an
  "existing rule"); `--trusted` without `--workspace` → scripted;
  `--read-root` without `--workspace` (and without `--trusted`
  and without `--sealed`) → native READ-ONLY (read/search only,
  composed against whichever store is active; preimages and
  artifact publication never occur in read-only mode, so no
  writer identity is needed); `--read-root` + `--sealed` →
  reject (exit 2: sealed runs are tool-free — file capabilities
  are denied regardless of read roots; NEW validation); neither
  flag → scripted with file caps denied (existing behavior
  preserved); `--sealed` alone → scripted/tool-free (always —
  sealed never composes native, even read-only). No native under
  sealed: sealed path has no durable artifact publisher and
  resolves no artifacts (the previous "ephemeral native
  read-only under --sealed" is withdrawn as vacuous and
  contradictory — a sealed run is never native). Composition
  tests (binary legs): flag-selection matrix (`--workspace`
  composes native, `--read-root`-only (without sealed) composes
  native read-only with mutating denied, `--workspace`+`--sealed`
  → exit 2, `--read-root`+`--sealed` → exit 2, `--trusted`
  composes scripted with zero real mutations, `--sealed` alone →
  scripted/tool-free, neither → mutating denied);
  construction-order test (native executor holds the claimed
  writer identity — artifact publish under a foreign session
  fails); ephemeral test (sealed run never touches the durable
  store or the artifact root, and any file-tool proposal is
  denied at validation).
  Grant derivation: file caps ON as build.allAllowed ∩ userConfig
  (must opt in — defaults false) ∩ workspace-designated;
  exec/consult denied even with `--workspace` (denial test).
  Approve/deny/unavailable legs at the binary level.
 - Cross-run unknown guard (SPEC §9.1: mutating continuation after
  unresolved outcomes requires an explicit decision — answered
  across runs, not in-session): SEPARATED into (i) a WRITE
  reconciliation step and (ii) a READ-ONLY gate (correcting the
  prior conflation — Finding 6). (i) BEFORE the gate, a
  distinct `reconcileByteUsage` write runs under the NEW
  artifact-root lock + in-process `gate` + `queue.write`
  transaction (the artifact lock is the same `<db>-artifacts.lock`
  defined in B3 — acquired before `gate`, held through the
  `queue.write` — Finding 2): it does NOT call
  `detectArtifactOrphans` (Finding 7: that method pages
  `records(since:)` which re-enters `gate` + `queue.read`
  :378–396 and would deadlock under the lock) — instead it
   runs raw SQL inside the transaction
  (`SELECT session, payload, LENGTH(payload) FROM records`
  scanning for `artifactPublished` digests — Finding 5: session
  is in `records.session`, not in `ArtifactRef` per
  SessionStore.swift:173–187 — plus a
  `SELECT digest, size FROM artifact_physical` plus a
  `FileManager` directory listing of the artifact root, all
  inside the single `queue.write` before any re-entrant
  `records(since:)` call), decodes each digest, joins to
  `artifact_physical.size`, aggregates per-session distinct
  sizes, and recomputes-to-expected (Finding 4: sets
  `byte_usage`/`artifact_physical` to the computed expected
  totals, not blindly "bumps additively"; second run is
  demonstrably idempotent) — an uncommitted orphan file →
  `artifact_physical` only (never a `byte_usage` row), a
  committed reference whose `byte_usage` is missing → that
  session's row via the `records.session` join (Finding 6,
  Finding 5).
  This step SERIALIZES with live `publishArtifact` callers via
  the same artifact lock + `gate` + `queue.write` (the lock
  that B3's publish holds for its entire tmp→rename→commit
  sequence), so a live publication racing the scan cannot be
  double-counted or lost: either the publication's transaction
  commits first (then the scan's raw SQL sees the new
  reference/physical row and does nothing) or the scan inserts
  first (then the publication's physical insert is a no-op
  dedup). Failure of this step fails the run closed (exit 6:
  store integrity — the quota tables are unwritable) and the
  gate does not run. Ordering: claim → sessionOpened →
  reconcileByteUsage → gate. (ii) THEN the gate runs READ-ONLY:
  the CLI runs the existing `reconcileOperations` classifier over
  every session's durable stream in the state store (read-only,
  same mechanism as `session export`). Sessions are enumerated
  via a new read-only store seam, `sessions() -> [SessionID]`
  (`SELECT DISTINCT session`, no row data; implemented for GRDB
  + InMemory + EphemeralStore + CLIStore + test doubles — a new
  protocol requirement, so every conformance is updated in the
  same slice; unit-tested incl. empty store), then each session
  is paged through the existing per-session
  `records(session:since:limit:)` + in-memory reconcile — the
  gate itself performs NO writes and introduces NO new store API
  beyond `sessions()` (the prior "no other new store API" now
  applies strictly to the gate; `reconcileByteUsage`'s writes are
  accounted separately in B3). If `reconcileOperations` throws
  (corrupt/undecodable session) the gate trips for that session
  (fail closed: an unreadable ledger is never treated as clean).
  Sessions have no workspace binding, so
  the gate is per-state-store (documented as such, with a
  cross-workspace test: dirty store blocks, clean store
  proceeds). Any session with held operations or unmatched
  mutating intents trips the gate. Without `--acknowledge-unresolved-outcomes` → fail closed
  (exit 3: an explicit operator decision is required before any
  mutating work — the same code as approval-required, since this
  gate IS an approval check (non-interactive form), not a usage
  error: the invocation is well-formed and no TTY interaction
  can satisfy it, only the explicit flag. NOT exit 4, since no
  run/ambiguous delivery occurred; NOT exit 6, since nothing is
  corrupt; NOT exit 2, since the invocation is not malformed),
  naming the sessions and pointing at `needletail session export`
  for audit.
  With the flag → append a new
  `DurableRecord.acknowledgedUnresolved(Acknowledgment)` record
  to the NEW session (fields: subject sessions, operation IDs,
  determination [`operator-accepted-risk` |
  `manually-reconciled:<note>`], atMillis; RecordCodec case +
  schema-note; old binaries fail closed on the unknown case per
  the M2-A foreign-row contract) and proceed. The new case
  requires an explicit `SessionExport.project` arm (the switch
  is exhaustive): subject session/operation IDs export as
  structural metadata; the `determination` free-text field is
  treated like other free text — redacted by default, included
  only with `--include-content` — and the export schema test
  gains the new keys. Append happens
  AFTER claiming the session and writing its `sessionOpened`
  record (ordering: claim → sessionOpened → acknowledgment →
  dispatch); append failure fails the run closed (exit 6:
  integrity — the session ledger itself is unwritable). The
  RECORD is the reconciliation decision — the flag alone would
  be a bypass. The flag is per-invocation, never persisted, and
  does NOT exempt future runs: every mutating run with
  unresolved history requires its own acknowledgment (no
  consumption — a stale exemption would re-open silent
  continuation). Tests: seeded store with unresolved markers →
  blocked without the flag (exit 3, names sessions); proceeds
  with the flag AND the acknowledgment record is present in the
  new session log;
  no-marker store → unaffected (incl. fresh/empty store
  bootstrap); non-mutating-only unmatched intents → no trip
  (re-runnable by design).
- `--trusted` stays demo-only: it composes ONLY the scripted
  backend (the real file-tool executor requires `--workspace`
  AND the absence of `--trusted`; composition is exclusive —
  no flag combination composes both), plus an ImportGate-style
  binary test proving `--trusted` performs zero real FS
  mutations.
- TOOL-12: extend `terminalSafe` (or a sibling display filter)
  to neutralize Cf/bidi (U+202A–202E, U+2066–2069) + Cf marks
  (U+200E/200F, U+061C, U+200B–200D, U+FEFF) + C0/C1 (Cc already
  covered) — replace with U+FFFD; stored bytes unchanged
  (display boundary only); per-class tests; wrong-impl probe
  (Cc-only escaping) must fail; binary byte proofs (0 ESC bytes).
- Qualification: register TOOL-01…12 (+PORT-03) certifying
  variants in `requiredEvidence` (1–2 native variants each,
  module-pinned) + maps invariant pin (M2-A precedent);
  coverage reconcile (all 12 + PORT-03 satisfied; STATE/POLICY/UX
  untouched); BDD-02/03/04 invariants preserved; per-slice
  DeepSeek deltas; M2-B epic receipt; CodeRabbit epic review as
  the B5 closing gate (invoked by a later session, not this one).
  Certifying binary CLI legs use `TOOL_NN_…` names (M2-A
  precedent); pure composition legs stay UNLABELED support.
- Counterfactuals: ambient git-config inheritance (must fail
  TOOL-10); trusted-mutation (binary test must fail if --trusted
  ever touches the workspace); unsanitized output bytes incl.
  bidi (must fail TOOL-12); unwitnessed-variant satisfaction
  (maps pin must fail); exec-composed-with-workspace (denial
  test must fail if it ever dispatches).
- Exclusions: exec/consult backends, live provider traffic
  (loopback/scripted approvals + temp workspaces only),
  background/detached processes, SBOM/packaging changes.

## 5. Cross-cutting rules

- Authorization path (the ONLY production-mutation path):
  explicit `--workspace` + userConfig opt-in + intact capability
  intersection + per-mutating-batch interactive approval, with
  protected paths enumerated in the approval description. Demo
  `--trusted` never composes the production executor
  (binary-test pinned). Production exec/consult are denied;
  headless is unavailable.
- Test vocabulary: `FAMILY_NN_rest` names for certifying tests
  (NeedletailPrimitiveTests = nativeProcess tier; real temp-dir
  FS); B5 adds named binary CLI legs. UNLABELED support oracles
  per TESTING §2 — no manufactured labels.
- RED/GREEN per slice: each load-bearing claim gets a wrong-impl
  probe that must fail, then passes on the real code;
  deterministic barrier-coordinated interleavings for races (no
  sleep races); probes listed in slice receipts, not deleted.
  Special files (FIFO/socket/device/dir) refused via fstat gating
  (B1 legs); hardlinks intentionally NOT denied (documented
  out-of-model).
- Review gates: DeepSeek delta review per slice with production
  changes (NEEDS_CHANGES folded → APPROVED before next slice);
  test-only changes covered by gates. Final: M2-B epic receipt +
  (later session) CodeRabbit epic review. No merge in slice
  sessions.

## 6. Explicit non-goals / forbidden

exec/consult backends (denied in M2-B, tested); new dependencies
(only approved swift-system/swift-crypto/GRDB/operator rg+git);
generic workflow engine; multi-file atomicity or same-user-race
immunity promises; fuzzy/Unicode-normalizing/silent-newline
edits; string-prefix containment or realpath/open races;
ambient-config inheritance (rg/git/env); model-controlled
flags/preprocessors/diff drivers; reads of tool-private state,
credentials, or artifact-dir contents (absolute denials);
workspace `.git`/`.env`/`.ssh` without explicit per-batch
operator approval; real mutations via demo `--trusted`; live
provider traffic; background/detached processes; deletion tool;
cross-run automated replay; M2-C/D scope;
any merge in this planning track. (Timeout/cancellation semantics
are specified in B4 — deadlines, synthesis, started rule — and are
NOT non-goals.)

## 7. Risks

- swift-system 1.8.1 descriptor API surface on Linux: openat
  with O_NOFOLLOW on keyed dir fds is NEW B1 code (reviewed in
  the B1 slice); path-based `open(O_NOFOLLOW)` per
  `BoundedFileRead` is the existing precedent, not a proof of
  the new traversal. Glibc-direct fallback, not a new dep.
- Operator rg/git missing/too old/shadowed on CI: fail-closed
  legs skip loudly per BDD-04 (skip ⇒ unsatisfied), absolute
  pinning + ownership checks neuter shadowing.
- Interactive approval is TTY-only; headless production runs stay
  out of scope (exit 3 path preserved).
- Byte quotas are new store accounting: kept in the existing
  mutation transaction (same fail-closed shape as count quotas);
  DeepSeek reviews the store delta.
- Mixed-batch UX: only genuine outcome uncertainty holds the queue
  (mutating timeout/cancelled-mid-execution/no-entry/contract-
  violation/untyped-throw); deterministic incompleteness
  (conflict, denial, unstarted, failed-pre-commit) completes with
  full per-call evidence and no hold. `failed` is never an
  uncertainty category. Documented, not tuned.
- Review load: 19-finding rounds are expensive; slices stay small
  so each delta review covers one contract area.

## 8. Review history

- REV1 → deepseek-reviewer: NEEDS-EVIDENCE (19 findings: actor-
  seam drops, throw-path fan-out, mutating-mapping, halt/rerun
  policy, artifact API, advertisement, authorization, preimage/
  quota, timeout producers, bidi, diff, search gaps, grants,
  §8 shape, lock pinning, mode preservation, probes, wording,
  wiring).
- REV2: folded all 19 (EffectOutcome case, throw policy, per-call
  mapping, halt-on-unknown, session check, advertisement,
  gateway, preimage order, deadlines, Cf ranges, diff surface,
  hidden/ignore model, grant-via-approval, shape table, fd
  pinning, fchmod, gated probes, wording, gate wiring).
- REV2 → deepseek-reviewer: NEEDS-EVIDENCE (9 partial + 10 new:
  per-call intents/cancel, halt contradictions, unstarted
  representation, protected override breadth, rg bypass,
  hardlink rule, artifactPublished ambiguity, advertisement
  boundary, scripted throw migration).
- REV3 (this revision): folds round 2 — per-call intent
  `mutating` at dispatch; per-call cancel split; halt at first
  non-success (no-match continues) with the [A ok, B conflict, C
  unstarted] example as specified behavior; explicit unstarted
  entries + transcript-for-all + scoped rerun claim; absolute
  vs grantable protected classes; rg deny-glob post-filter;
  hardlink claim dropped with rationale; artifactPublished
  REUSED (no new record) + session lookup seam + outcome-JSON
  metadata; advertisement discovery-only boundary; scripted
  post-dispatch rule; full grant derivation table; Cf marks
  added; U+FFFD replacement; exec/consult denial test.
  (Omission here is evidence-modeling; BDD-04 skip semantics are
  a separate mechanism and are not invoked by it.)
- REV3 → deepseek-reviewer: NEEDS-EVIDENCE (6 residuals: R1
  unstarted emitter/status, R2 pre-dispatch status preservation,
  R3 dropRetaining + intent migration, R4 orphan on quota
  failure, R5 hardlink aspect test, R6 shape/citation fixes).
- REV4 (this revision): folds round 3 — executor reports every
  proposal incl. never-dispatched as `cancelled`/`unstarted:
  halted after <id>`; typed pre-dispatch errors preserve SPEC
  status (untyped → fail-closed unknown+hold); dropRetaining +
  intent emission per-proposal with deliberate actor-test
  migration; halt-at-first-non-success kept with compounding
  rationale; transcript-for-all scoped to executed batches
  (stale-retention unchanged); hardlink behavior leg;
  `artifactRecord(session:digest:)` lookup seam; outcome-JSON
  metadata in the §3 shape table; `data` mandatory; preflight
  quota + delete-on-ref-failure + SPEC-allowed crash residual;
  --read-root standalone rule; citation fixes (SPEC §7.2,
  1304/1443, shape-table home section).
- REV4 → deepseek-reviewer: NEEDS-EVIDENCE (R1 unstarted-as-unknown false claim + unexitable hold, R2 pre-dispatch status legs, R3 line refs, R4 preflight wording [fixed], R5 hardlink wording [fixed], R6 shape/citation/title fixes; new N1-N3 on C-status wording, explicit abandon, §3/B4 wording).
- REV5 (this revision): holds ONLY for genuine uncertainty — never-dispatched calls complete as done-cancelled (no hold, provably no side effect); timeout-mid-execution/cancelled-mid-execution stay unknown+hold; pre-dispatch typed throws preserve status with invalid-arguments/failed/workspace-unusable legs; preflight quota + delete-on-ref-failure; hardlink behavior leg; `data` mandatory; observed_at_seq deviation flagged; §3 mapping/throw/halt/throw-policy wording aligned with B4 legs; title/refs/citations fixed.
- REV5 → deepseek-reviewer: NEEDS-EVIDENCE (false-unknowability
  partially fixed but cancel/stale paths still mark
  never-dispatched unknown; N2 unaddressed — no abandon/reconcile
  path; pre-dispatch `failed`/workspace-unusable legs, R3 line
  refs, `data`/observed_at_seq/WIRE-05/BDD-04 citation fixes,
  §3-vs-B4 status wording).
- REV6 (this revision): per-call DISPATCH TRUTH via new
  in-memory `performedEffects` (cancel/retention consult it;
  never-performed → done-cancelled, no markers); holds are
  terminal-for-the-session BY DESIGN (single-CLI-run sessions,
  exit-4 diagnostic, next run starts clean — no in-session
  abandon/reconcile command, explicit non-goal); pre-dispatch
  `failed` leg incl. lock-contention as deterministic failure;
  stale `mixed-batch` risk entry rewritten; per-class grant
  derivation (`--read-root` standalone for reads); R3 refs fixed
  (computed 1289, applied 1302; `cancelActive` `where` at 1443);
  `observed_at_seq` deviation flagged with SPEC reference +
  amendment proposal; WIRE-05 cite replaced by SPEC §7.2:336;
  hardlink behavior leg (treated as regular file).
  SUPERSEDED before the REV6 review (sub-proposal withdrawn, not
  the whole revision — the revision itself WAS reviewed, next
  line): `performedEffects` is unimplementable
  as specified (actor has no per-call start visibility in one
  `execute(batch)`; no dispatch-truth mechanism exists for
  cancel/stale paths).
- REV6 → deepseek-reviewer: NEEDS-EVIDENCE (7 residuals: cancel/
  stale never-dispatched marking; N2 unaddressed; no machine-
  readable discriminator; --read-root contradiction; lock
  granularity; missing legs; citations).
- REV7 (this revision): drops `performedEffects` — cancel/stale
  paths keep unknown+hold HONESTLY (kill at arbitrary point, no
  executor consult possible, consistent with crash semantics;
  dropRetaining receives no outcome to classify); executor-
  attested unstarted stays done-cancelled (attestation boundary
  stated); `started: Bool` discriminator added (+failed always
  deterministic pre-commit); holds terminal-for-session +
  B5 startup unresolved-marker gate with per-invocation
  --acknowledge-unresolved-outcomes (explicit §9.1 decision);
  per-class grant derivation fixed; lock granularity unified
  (batch-level acquisition); cancelled-mid-execution +
  non-mutating-unstarted legs added; failed-ambiguous category
  removed; openat overclaim + R3 refs fixed.
- REV7 → deepseek-reviewer: NEEDS-EVIDENCE (7 residuals:
  cancel/stale never-dispatched marking; N2 unaddressed; no
  machine-readable discriminator; read-root contradiction; lock
  granularity; missing legs incl. post-commit-failure mapping;
  citations).
- REV8 (this revision): cancel/stale keep unknown+hold HONESTLY
  (kill at arbitrary point, no executor consult, stale content
  must never certify; completeEffect drops late results against
  already-written markers — no evidence lost); N2 answered by
  terminal-for-session + B5 startup unresolved-marker gate
  (reconcile-per-session via existing classifier; recorded
  acknowledgment appended to the NEW session; exit 2 with
  justification; per-state-store scope; empty/non-mutating
  bootstrapping legs); `started: Bool` discriminator + reducer
  precedence (deterministic statuses win; cancelled/timeout key
  on started; omission defaults true fail-closed) + success-with-
  started-false + CancellationError-synthesis + started-omission
  legs; per-class grant derivation (--read-root standalone for
  reads); unified batch-level lock + mixed-batch contention leg;
  cancelled-mid-execution + non-mutating-unstarted +
  post-commit-failure (applied-then-timed-out) + stale-completion
  legs; dropRetaining keeps outcome-free signature honestly;
  §7 failed-ambiguous removed; openat overclaim fixed;
  per-call result `mutating` + mixed-batch reopen + existing
  test updates specified; free-space reserve check + leg;
  R3 refs (1302–1306/1443/1289) verified.
- REV8 → deepseek-reviewer: NEEDS-EVIDENCE (7 residuals:
  cancel/stale never-dispatched marking + no dispatch-truth
  mechanism; N2 unaddressed + gate has no seam/record/exit
  justification; CancellationError vs started contradiction;
  started precedence/default/validation; per-call result mutating;
  lock granularity mixed case; missing legs; stale citations).
- REV9 (this revision): dropRetaining outcome-free BY DESIGN
  (stale content must not certify; summaries threaded into
  unknown-marker messages); cancel paths honest about no
  executor consult; `started` precedence total order + omission
  fail-closed + success-wins + CancellationError synthesis;
  per-call RESULT mutating + mixed-batch reopen + existing test
  updates; batch-level lock with mixed-batch rule; startup gate
  with session-listing seam + recorded `acknowledgedUnresolved`
  determination + exit-2 justification + bootstrapping legs;
  free-space 256 MiB reserve; WIRE-05/SPEC-§7.2,
  BDD-04, openat, §8-convention, R3-ref hygiene; performedEffects
  removal stated once, in §8 history only.
- REV9 → deepseek-reviewer: NEEDS-EVIDENCE (7 residuals + new:
  cancel/stale never-dispatched marking + no dispatch-truth
  mechanism; N2 unaddressed + gate has no seam/decision/record;
  CancellationError contradiction; started precedence/default/
  validation; per-call result mutating; lock granularity mixed
  case; missing legs incl. post-commit-timeout; citations).
- REV10 (this revision): cancel/stale keep unknown+hold HONESTLY
  (kill at arbitrary point; dropRetaining outcome-free as
  certifying input BUT threads the stale summary string into
  unknown-marker messages — `unknown: stale completion
  reported '<summary>' — with a test-migration note for
  exact-`unknown` assertions); mixed cancel/stale tests assert
  same operationIDs / listed-summary / non-mutating absent;
  `started: Bool? = nil` (omissible under synthesized Codable,
  reducer treats nil as true) + precedence order incl.
  success-wins + CancellationError synthesis at
  `invokeExecutor` catch; per-call result `mutating` replacing
  batch `completedMutating` + mixed-batch reopen test + existing
  all-mutating test updates; startup gate with
  `reconcileOperations`-per-session seam, new
  `DurableRecord.acknowledgedUnresolved(Acknowledgment)` case
  (sessions, operation IDs, determination, atMillis; codec +
  fail-closed note), recorded per invocation (no consumption —
  every mutating run re-acknowledges), exit 2 as conditional-
  required-argument (explicit 3/4/6 rejections with reasons),
  cross-workspace documented, bootstrapping + non-mutating legs;
  unified batch-level lock + mixed-batch rule + test;
  ApprovalRequest.protectedPaths + describe + enterAuthorising;
  --trusted carve-out (scripted only, real executor requires
  --workspace AND NOT --trusted); §7 failed-ambiguous removed;
  openat §7 fixed; WIRE-05→SPEC-§7.2 reword; B1 lock mixed-case
  wording; B4 cancel/stale/transcript-only scoping;
  B5 acknowledgment case + exit-code justification.
- REV10 → deepseek-reviewer: NEEDS-EVIDENCE (10 findings:
  cancel/stale never-dispatched marking + no dispatch-truth
  mechanism + queued-batch test; N2 gate seam/decision/record/
  cross-workspace/exit-code; CancellationError contradiction +
  started precedence/default/validation; per-call result
  mutating; lock granularity mixed case; missing legs incl.
  post-commit-timeout; citations incl. performedEffects body
  mentions, §7 failed-ambiguous, openat, §8 accuracy).
- REV11 (this revision): no `performedEffects` mechanism
  anywhere (the single body mention explicitly rejects it with
  rationale); §3 cancel/stale path
  pins the attested/unattested line (executor-reported unstarted
  → done-cancelled; everything else unknown+hold for mutating);
  mixed-cancel + stale tests with same-IDs/summary assertions;
  `started: Bool? = nil` with omission-is-nil semantics +
  precedence order incl. success-wins + CancellationError
  synthesis at `invokeExecutor` catch; per-call result
  `mutating` replacing batch `completedMutating` + mixed-batch
  reopen test + existing test updates; startup gate with
  `reconcileOperations`-per-session seam, new
  `DurableRecord.acknowledgedUnresolved(Acknowledgment)` case
  (sessions, operation IDs, determination, atMillis; codec +
  fail-closed note), recorded per invocation with no consumption
  (every mutating run re-acknowledges), exit 3 as
  operator-decision gate (explicit 2/4/6 rejections with
  reasons), cross-workspace documented, bootstrapping +
  non-mutating legs; unified batch-level lock + mixed-batch rule
  + test; ApprovalRequest.protectedPaths + describe +
  enterAuthorising; --trusted carve-out (scripted only, real
  executor requires --workspace AND NOT --trusted); §7
  failed-ambiguous removed; openat overclaim fixed;
  WIRE-05→SPEC-§7.2 reword; B1 lock mixed-case wording;
  B4 cancel/stale/transcript-only scoping; B5 acknowledgment
  case + exit-code justification.
- REV11 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings:
  cancel/stale never-dispatched marking + no dispatch-truth
  mechanism + queued-batch test; N2 gate seam/decision/record/
  cross-workspace/exit-code; CancellationError contradiction +
  started precedence/default/validation; per-call result
  mutating; lock granularity mixed case; missing legs incl.
  post-commit-timeout; citations incl. performedEffects body
  mentions, §7 failed-ambiguous, openat, §8 accuracy).
- REV12 (this revision): dropRetaining keeps unknown+hold
  HONESTLY (kill at arbitrary point; no executor consult
  possible; stale content must not certify — with the stale
  summary threaded into the marker message and a
  test-migration note for bare-`unknown` assertions); mixed
  cancel test asserts same operationIDs, non-mutating absent;
  `started: Bool? = nil` (omissible under synthesized Codable,
  reducer treats nil as true) + full precedence incl.
  success-wins + CancellationError synthesis at
  `invokeExecutor` catch; per-call result `mutating` replacing
  batch `completedMutating` + mixed-batch reopen test + existing
  test updates; startup gate with `reconcileOperations`-
  per-session seam, new `DurableRecord.acknowledgedUnresolved`
  (sessions, operation IDs, determination, atMillis; codec +
  fail-closed note), recorded per invocation with no consumption
  (every mutating run re-acknowledges), exit 3 as
  operator-decision gate (explicit 2/4/6 rejections with
  reasons), cross-workspace documented, bootstrapping +
  non-mutating legs; unified batch-level lock (fails
  not-yet-dispatched only) + mixed-batch rule + test;
  ApprovalRequest.protectedPaths + describe + enterAuthorising;
  --trusted carve-out (scripted only, real executor requires
  --workspace AND NOT --trusted); §7 failed-ambiguous removed;
  openat §7 fixed; WIRE-05→SPEC-§7.2 reword; B1 lock mixed-case
  wording; B4 cancel/stale/transcript-only scoping;
  B5 acknowledgment case + exit-code justification; line refs
  corrected to 1289/1301–1306/1443; `performedEffects` appears
  only as an explicit rejection with rationale, never as a
  mechanism.
- REV12 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings: cancel/stale never-dispatched marking + no dispatch-truth mechanism + queued-batch test; N2 gate seam/decision/record/cross-workspace/exit-code; CancellationError contradiction + started precedence/default/validation; per-call result mutating; lock granularity mixed case; missing legs incl. post-commit-timeout; citations).
- REV13 (this revision): executor-handled cancellation as primary path (per-call truth incl. unstarted, deterministic via gate), actor synthesis demoted to fail-closed fallback for propagating executors; `dropRetaining` takes an explicit `summary: String?` param threaded from `checkStale`; per-call result `mutating` replacing batch `completedMutating`; session-listing seam named (`sessions() -> [SessionID]`); exit 2→3 with approval-gate justification; mixed-cancel test with same-IDs; stale-completion summary threading + test migration; started-omission + success-wins + CancellationError legs; no-consumption rule stated; cross-workspace + bootstrapping tests.
- REV13 → deepseek-reviewer: NEEDS-EVIDENCE (8 findings: cancel/stale path never-dispatched marking + queued-batch test + dropRetaining outcome threading; N2 gate seam/record/cross-workspace/exit-code; CancellationError primary-vs-fallback + started precedence/default/validation; per-call result mutating derivation; lock granularity mixed-batch contradiction; missing legs incl. post-commit-timeout; §7/§8/citation accuracy).
- REV14 (this revision): executor-handled cancellation as PRIMARY path with gate determinism + actor synthesis demoted to explicit fallback (both tested); `dropRetaining` summary param with honest framing (no structured outcome, summary string only for the marker) + mixed-cancel same-IDs test + stale-completion test migration note; `started: Bool?` with full precedence incl. success-wins + CancellationError/omission legs; per-call intent+result `mutating` with derivation stated + mixed-batch reopen test; batch-level lock with mixed-batch rule (failing call done-failed, rest unstarted-cancelled) + mixed lock leg; session-listing seam with all conformances + reconcile-throw trips gate + recorded acknowledgment + no-consumption + cross-workspace + exit-3 justification + bootstrapping legs; ApprovalRequest.protectedPaths + describe/enterAuthorising; --trusted carve-out; explicit abandon/reconcile rejection with rationale (single in-flight slot, async boundary, fail-closed); B1 mixed-case wording; §7 cleanup; citations corrected to 1289/1301–1306/1443.
- REV14 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings: cancel/stale path never-dispatched marking + queued-batch test + dropRetaining outcome threading + transcript rule; N2 gate seam/record/cross-workspace/exit-code; CancellationError primary-vs-fallback + started precedence/default/validation; per-call result mutating derivation; lock granularity mixed case; missing legs incl. post-commit-timeout; §7/§8/citation accuracy).
- REV15 (this revision): cancel/stale paths keep unknown markers for mutating calls only (honest: no executor consult possible; single in-flight slot verified in actor source) with the summary string threaded through an explicit `summary: String?` param; executor-handled cancellation as the primary path (deterministic via gated test double) with actor synthesis as documented fail-closed fallback; dropRetaining outcome-free-as-certifier (summary string only); mixed-cancel + no-transcript tests with same-IDs; started precedence incl. success-wins + omission fail-closed; per-call result mutating with mixed-batch reopen test; batch-level lock with mixed-batch rule + test; session-listing seam with all conformances + reconcile-throw trips gate + recorded acknowledgment + no-consumption + cross-workspace + bootstrapping legs (exit 3 with approval-code justification); ApprovalRequest.protectedPaths + describe + enterAuthorising; --trusted carve-out; explicit abandon/reconcile rejection; citations corrected to 1289/1301–1306/1443; `performedEffects` appears only as an explicit rejection.
- REV15 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings: cancel/stale never-dispatched marking + queued-batch test + dropRetaining outcome threading + transcript rule scope; N2 gate seam/record/cross-workspace/exit-code; CancellationError primary-vs-fallback + started precedence/default/validation; per-call result mutating derivation; lock granularity mixed case; missing legs incl. post-commit-timeout; §7/§8/citation accuracy).
- REV16 (this revision): two-path cancellation made explicit (executor-handled primary via gated scripted test + kill-switch fallback with race analysis showing either order is fail-closed); `dropRetaining` takes ONLY a human-readable summary (no structured outcome) with same-operationIDs pairing test + non-mutating absent; transcript rule scoped to executor paths (cancel/stale emit records only); session-listing seam with full conformance list (GRDB/InMemory/EphemeralStore/CLIStore/test doubles) + reconcile-throw trips gate (fail-closed); recorded acknowledgment with determination + no-consumption rule + cross-workspace tests; exit 3 with approval-code justification; per-call result `mutating` replacing batch `completedMutating` + mixed-batch reopen test; batch-level lock with mixed-batch rule (failing call done-failed, rest unstarted-cancelled); ApprovalRequest.protectedPaths + describe + enterAuthorising; --trusted carve-out; explicit abandon/reconcile rejection; citations corrected; B4/B5 test lists completed (mixed-cancel same-IDs, started-omission, success-wins, CancellationError both paths, stale-completion, post-commit, mixed lock, no-entry, pre-dispatch typed/untyped, bootstrapping, non-mutating).
- REV16 → deepseek-reviewer: NEEDS-EVIDENCE (11 findings:
  actor ordering blocks primary path; no runtime composition
  seam/executor injection; protectedPaths uncomputable at
  authorising; success+started-false recorded executed; rg
  post-filter does not prevent opens; root-swap test impossible
  on pinned fd; cleanup can delete shared dedup bytes; byte
  quota has no schema; stale effectFailed has no summary source;
  missing-git behavior uncovered; REV6 history contradiction).
- REV17 (this revision): REQUIRED actor change — `cancelActive`
  writes markers but RETAINS cancelled-pending reservations
  (generation bump still blocks dispatch); `completeEffect`
  replaces markers ONLY for late `started == false` entries
  (started/omitted late reports stay dropped); primary path
  re-scoped to still-reserved effects (executor's own
  deadline/timeout catch, gated scripted test) + kill-switch
  retention semantics + late-unstarted-replacement leg; §3
  precedence (1) keys on `started != false`, contradictory
  success+started-false fails closed (wrong-input leg); pure
  Core `validateBatchArguments` consumed by `enterAuthorising`
  before request construction + `describe` re-specified as
  validated formatting + transition-level approval test; fixed
  rg argv gains harness-owned deny globs (non-traversal) +
  argv-capture + 000-sentinel non-open proofs; root traversal
  RE-OPENS and revalidates dev/ino per use, traverses from the
  fresh fd; preimage cleanup only after atomic re-verify (see §3)
  + cross-session dedup tests; `byte_usage(session PK, bytes)`
  schema + migration + same-transaction preflight + dedup-aware
  counting + orphan over-count documented; stale-failed summary
  = carried error string + stale-failed leg; missing-git denial
  leg (TOOL-10); named `FileToolRuntime` enum +
  `NativeToolExecutor` (session/store/writer/artifact/resolver
  captured post-claim) + flag-selection matrix + construction-
   order tests; REV6 note clarified to sub-proposal withdrawal.
- REV17 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings:
  actor change missing actor-table/flag/handler/rows/cleanup +
  primary-path scope; matrix omits --read-root/--sealed +
  ephemeral claim order; 000-file proves no-open not no-descend
  + post-filter contradiction; quota preflight-vs-commit
  contradiction + orphan under-count; createdNewFile TOCTOU vs
  second-session dedup; EffectOutcome case has no payload string;
  old binaries reject new table (forward-only)).
- REV18 (this revision): actor change completed —
  `EffectReservation.cancelledPending` flag, actor-table
  retention (not just transition state), `completeCancelledPending`
  handler with no fan-out/transcript, `checkStale`-first routing
  + `(.cancelling, effectCompleted/effectFailed)` rows,
  `invokeExecutor`-defer termination cleanup, transition + actor
  legs; scope note (primary path already works live — change
  serves kill-switch late reports); stale-completed summary =
  aggregate `result.receipt.summary`; selection matrix completed
  (`--read-root`-only → native read-only, `--workspace`+`--sealed`
  → exit 2, neither → scripted denied, `--sealed` alone →
  scripted) + ephemeral no-publisher rule + matrix/ephemeral
  legs; 000-DIRECTORY descend-proof + prune-pattern leg +
  guarantee restated as never-open/read with post-filter as
  layered defense; two-stage quota (advisory preflight +
  authoritative in-txn check with conditional cleanup) +
  orphan UNDER-count + `reconcileByteUsage` at gate +
  seeded-orphan leg; cleanup conditioned on no-reference-exists
  under same gate/txn + first-fails-after-dedup leg;
  `schemaVersion` 2→3 + forward-only incompatibility +
  old-binary/new-store leg.
- REV18 → deepseek-reviewer: NEEDS-EVIDENCE (7 findings:
  transition has no cancelled-pending source of truth (only
  actor retains; `state.liveReservations` cleared; `checkStale`
  sees no live reservation → `drop(state)`; `.cancelling` rows
  unreachable; accepted entries never pruned; routing ignores
  generation/consumed); sealed read-only contradicts
  `SealedRestrictions` + matrix omits `--read-root`+`--sealed`
  + ephemeral publisher vacuous; `--workspace`/`--read-root`
  + conflict rule do not exist; rg contents globs do not prune
  + 000-file sentinel inside pruned dir invalid; byte quota
  double-counts cross-session dedup + no record-byte path +
  orphan no-session; `reconcileByteUsage` write contradicts
  read-only gate + point-in-time race; dedup cleanup TOCTOU
  (verify+commit not atomic; first-fails-after-dedup leg
  insufficient)).
- REV19 (this revision): state-side `SessionState.
  cancelledPendingReservations` (+ `replacing` default) with
  `cancelActive` moving live → cancelledPending, idempotent
  repeat-cancel filter, actor mirroring + `consumedEffects`
  pruning; `checkStale`-first cancelled-pending routing
  regardless of generation + `.cancelling` effect rows +
  `completeCancelledPending` selective handler (no fan-out/
  transcript) + termination-defer cleanup + direct transition +
  actor retention tests; sealed always scripted/tool-free
  (`SealedRestrictions` allDenied — Capabilities.swift:109–110),
  `--read-root`+`--sealed` → exit 2, no native under sealed
  (withdrawn vacuous claim), matrix + construction-order +
  ephemeral tests; `--workspace`/`--read-root` declared NEW
  B1/B5 options (RunCommand.swift:20–50) with NEW exit-2
  validations; rg bare-prune + contents globs (`!.git/` +
  `!**/.git/**` etc.), sentinel AT the `.git` dir itself (not
  inside) + open-audit + prune-regression probe; byte quotas
  split into per-session logical `byte_usage` + global physical
  `artifact_physical` (distinct dedup), record-byte paths in
  SAME txn, orphan no-session/UNDER-count attributed to
  physical; `reconcileByteUsage` separated as pre-gate WRITE
  under cross-process lock + serialized with publish (scan sees
  commit or publish re-verifies) + exit-6 vs exit-3 failure
  modes + point-in-time fix; dedup TOCTOU closed by joining
  verify+rename+insert+quota+cleanup into ONE `queue.write`
  under the file lock with re-verify inside txn + barrier
  gate-test proving both orders (A cleans/B verifies re-creates
  and B commits/A keeps).
- REV19 → deepseek-reviewer: NEEDS-EVIDENCE (8 findings:
  actor lookup still drops late report before transition;
  store gate is NSLock not cross-process; barrier test
  impossible interleaving; post-failure check not same txn;
  `recoverWriterOwnership` record path + migration backfill
  missing; orphan `byte_usage` attribution contradiction;
  `detectArtifactOrphans` re-enters gate/queue.read; prune-
  regression via hit-exclusion never goes RED).
- REV20 (this revision): actor `completeEffect`/`failEffect`
  lookup `reservations[effectID] ?? cancelledPending[effectID]`
  with new `cancelledPending` actor table + pruning of both
  tables + state-side `cancelledPendingReservations` + deferred
  marker-event cleanup + forwarded-lookup test; NEW artifact-
  root file lock `<db>-artifacts.lock` `flock(LOCK_EX)` BEFORE
  `gate` through the whole tmp→verify→rename→commit→cleanup
  sequence (ordering artifact→gate→queue.write) for both
  publish and `reconcileByteUsage`; serialized barrier legs
  (B-before-A and A-before-B, no impossible concurrent hold) +
  blocking leg; post-failure cleanup in SECOND `queue.write`
  but SAME artifact lock held across rollback boundary with
  committed-state check (`artifact_physical` ground truth);
  quota check before physical insert with dedicated ordering;
  `recoverWriterOwnership` :540–545 added as
  `insertRecordWithQuota` path + migration backfills
  `artifact_physical` distinct + per-session `byte_usage`;
  orphan split (orphan→`artifact_physical` only,
  missing-logical→that session `byte_usage`); `reconcileByteUsage`
  raw SQL inside txn (no `detectArtifactOrphans` re-entry) with
  raw `SELECT payload`/`FileManager` listing; prune-regression
  via 000-directory descend failure (not hit-exclusion).
- REV20 → deepseek-reviewer: NEEDS-EVIDENCE (5 findings:
  cancelled-pending retains provider reservations (no cleanup in
  `invokeTransport`); `effectFailed` has no `started` flags but
  is routed selective; artifact lock makes "between tmp and txn"
  branches impossible; migration only sums records not per-session
  distinct artifacts + not recompute-to-expected; raw SQL omits
  `records.session` so missing-logical unattributable).
- REV21 (this revision): `cancelActive` filters
  `executor`-only reservations + `invokeTransport` no-retention
  + cancel-during-provider test; `effectFailed` on
  cancelledPending keeps all markers with error-string evidence
  + dedicated test; artifact lock pre-check withdrawn as
  fast-path only — authoritative dedup is txn re-check, sole
  race is pre-lock commit (B-before-A) — barrier recast to two
  serialized orders + blocking leg; migration/reconcile
  recompute-to-expected via `SELECT session, payload` join to
  `artifact_physical.size` per-session distinct (ArtifactRef has
  no session — SessionStore.swift:173–187) + v2-with-artifact
  migration test; orphan split stated once
  (orphan→`artifact_physical` only, missing→that session's
  `byte_usage`); B3+B5 raw SQL `SELECT session, payload,
  LENGTH(payload)` inside txn, no `detectArtifactOrphans` re-entry,
  per-session aggregation.
- REV21 → deepseek-reviewer: _pending_.
- §8 convention: entries are frozen at write time and describe
  the file as of that round; only the latest entry is current.
