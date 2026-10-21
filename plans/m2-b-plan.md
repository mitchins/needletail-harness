# M2-B Plan — native file tools + ordered partial batches (REV8, planning only)

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
  proposal (SessionTransition.swift:1291–1304;
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
  before_hash?, after_hash? }`, status ∈ SPEC vocabulary only
  (success | no-match | denied | conflict | invalid-arguments |
  failed | timeout | cancelled — no `unstarted`/`no-entry`
  statuses). `data` is MANDATORY (may be `""` only with an `error`
  explaining absence): read/search carry content/results; edit/write
  carry the machine-readable receipt (path/mode/before/after
  hashes, per B4 below). `started: Bool = true` is the
  machine-readable dispatch bit (the executor sets false for
  never-dispatched calls; the reducer keys on IT, never on
  summary prose). Reducer precedence, in order: (1) deterministic
  statuses (success/no-match/denied/conflict/invalid-arguments/
  failed, plus actor-synthesized pre-dispatch receipts) → `.done`,
  no hold, REGARDLESS of `started` (a claimed result proves
  dispatch; `success` + `started == false` is contradictory input
  and is recorded done — tested explicitly); (2) cancelled/
  timeout + `started == false` → done-cancelled receipt, no hold,
  for mutating AND non-mutating alike; (3) cancelled/timeout +
  `started == true` OR started-field omitted (default true,
  fail-closed) → mutating: `.unknown` + marker + hold;
  non-mutating: transcript-only. `failed` is ALWAYS deterministic
  pre-commit (the executor must never report post-commit
  uncertainty as `failed`; uncertain post-commit outcomes are
  `timeout`/`cancelled` with `started == true`). The actor
  never silently drops `CancellationError`: it synthesizes
  per-call cancelled outcomes with `started == true` for every
  proposal in the batch (fail-closed: unknown+hold for mutating),
  since a cancelled task may have dispatched. `observed_at_seq` is the durable stream position
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
  `tool != read/search/consult` predicate now used for the batch
  flag) and written onto EACH intent (replacing the batch-wide
  flag at SessionTransition.swift:1302–1306, computed from the
  batch predicate at 1289), so intent/result
  agreement holds per call. Durable encoding per call:
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
  precedent). `dropRetaining` signatures stay outcome-free on
  purpose: `checkStale` DISCARDS the carried `EffectOutcome`
  (SessionTransition.swift:414–425) because stale content must
  never certify the current run — a superseded generation's
  results cannot pair with live intents — so its unknown stands
  honestly, and per-proposal mutating (not the carried outcome)
  decides marker vs transcript-only. Cancel paths cannot consult
  the executor either: the actor runs one in-flight effect at a
  time and a new `reserveEffect` cancels the previous task, so
  every live reservation at cancel time is in-flight or was
  killed mid-flight — genuinely uncertain → existing unknown
  path (consistent with pre-existing crash semantics: intent
  without result reconciles unknown). A late per-call result
  arriving after cancel is dropped at `completeEffect` against
  already-written unknown markers for the same operationIDs —
  no evidence lost. No `performedEffects` mechanism is specified
  — the actor has no per-call start visibility inside one
  `execute(batch)` call, and effect-granular marking would lie
  in both directions. The empty-proposals fallback keeps
  reservation-level classification (no proposals to classify —
  documented). Tests: cancel-during-flight → mutating
  unknown+hold AND non-mutating transcript-only (existing
  semantics + per-call split, pinned).
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
  its result — COMPLETE-SPEC.md:336): EVERY proposal in an
  executed batch gets a transcript `toolResponse` in order,
  including calls with no `operationResult` (evidence ≠ state
  claim; the stale-retention path emits records only, unchanged
  and out of scope). Order-preservation is observed via
  transcript order + log scan (present done/failure receipts,
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
  pin device/inode, verify identity (fstat) on each use; symlink
  root → reject with message (use the real path).
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
  The fixed-argv harness `git`/`rg` subprocesses are NOT native
  reads — they never traverse the containment boundary (see B2/B5
  carve-outs), so B5's diff does not need a grant.
- Roots: explicit `--workspace` (must exist) + `--read-root`
  (read-only; never write roots, never exec-cwds); without
  `--workspace`, mutating tools are denied. `--read-root` works
  standalone (reads/searches need no workspace); mutation
  (edit/write, preimages, lock) requires `--workspace`. Grant
  derivation, per class (this resolves the blanket allDenied):
  read/search REQUIRE userConfig opt-in AND (workspace-designated
  `--workspace` OR at least one `--read-root`) AND invocation AND
  seal rules; edit/write REQUIRE userConfig opt-in AND
  `--workspace` present AND invocation AND per-batch approval;
  exec/consult are denied regardless of flags. The CLI rejects
  `--workspace` + `--trusted` together (exit 2).
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
  acquired ONCE per mutating batch before the first mutating
  call (after arg validation), held through the last commit;
  per-call re-read + hash happen under the HELD lock. Lock
  contention therefore fails the WHOLE batch pre-dispatch
  (typed `failed` for every proposal — nothing ran), never a
  single call mid-batch.
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
  flags, no symlink-follow outside root; `rg --files` for
  discovery (empties listed, never read). Hits are post-filtered
  through the B1 protected-path predicate (deny globs — rg output
  never bypasses the boundary). Continuations are single-session:
  opaque token (query hash + offset + result-hash prefix); resume
  re-executes and prefix-verifies, else restarted-label (no
  stable-offset fiction, no stale reads).
- Tests: `TOOL_01_…` over-budget/binary legs; `TOOL_02_…`
  leading-dash/regex/glob-metachar legs per mode; `TOOL_03_…`
  poisoned-env (`RIPGREP_CONFIG_PATH` + fake `--pre` shim first on
  PATH — must be ignored), shim-`rg` shadowing leg, symlink-out
  leg, `.git`-hit exclusion leg, missing/too-old-rg fail-closed
  legs; `TOOL_11_…` cross-session denial + same-session allow.
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
  receipt (sha256-empty is constant), no empty publish. Order
  under the lock: re-read/hash → preflight byte-quota check
  (fail fast, nothing written) → publish preimage → on reference-
  commit failure delete the just-written bytes (best-effort) →
  rename → receipt. Crash between publish and cleanup can orphan
  bytes — explicitly allowed (SPEC §9), documented, not tested
  as impossible. Pre-publish free-space check: refuse (denied
  result, not a crash) when the artifact filesystem has less
  than the SPEC §9.2 256 MiB reserve.
- Byte quotas (new store accounting, in the existing mutation
  transaction — same fail-closed shape as count quotas):
  1 GiB session / 5 GiB global over records + artifacts +
  preimages.
- Tests: `TOOL_04_…` zero/one/multiple/empty legs;
  `TOOL_05_…` injected change between read and commit → conflict
  receipt, file untouched, no preimage; `TOOL_06_…` CRLF/no-final-
  newline/emoji/combining fixtures byte-preserved + mode-
  preservation leg; `TOOL_08_…` exists-refusal + stale-hash legs;
  quota legs (preflight over-quota → fail closed, nothing
  written; ref-commit failure → bytes cleaned up, nothing
  renamed; sub-reserve free space → denied receipt, never a
  crash).
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
  deterministic pre-commit failure → every not-yet-dispatched
  proposal `failed` (already-completed calls stand; acquisition
  is batch-level, before the first mutating call), never unknown.
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
  leg (contradictory input → done: claimed results prove
  dispatch); CancellationError leg (executors throws mid-batch
  → actor synthesizes started-cancelled for all → mutating
  unknown+hold); stale-completion leg (superseded generation with
  per-call outcomes → classified per call, never trusted as
  current-run done receipts); post-commit-failure leg (write
  applied then timeout reported → unknown+hold despite the
  successful write: conservative and tested); mixed-batch lock
  contention leg ([read A ok, write B lock-fails] → A done stands,
  B+ done-failed, no hold).
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
  `diff.external` and textconv-driver cases.
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
  Grant derivation: file caps ON as build.allAllowed ∩ userConfig
  (must opt in — defaults false) ∩ workspace-designated;
  exec/consult denied even with `--workspace` (denial test).
  Approve/deny/unavailable legs at the binary level.
- Cross-run unknown guard (SPEC §9.1: mutating continuation after
  unresolved outcomes requires an explicit decision — answered
  across runs, not in-session): on startup with mutating grants,
  the CLI runs the existing `reconcileOperations` classifier over
  every session's durable stream in the state store (read-only,
  same mechanism as `session export`; no new store API beyond a
  session-listing query — sessions have no workspace binding, so
  the gate is per-state-store, documented as such); any session
  with held operations or unmatched mutating intents trips the
  gate. Without `--acknowledge-unresolved-outcomes` → fail closed
  (exit 2: operator-decision-required, like missing HOME — NOT
  exit 4, since no run/ambiguous delivery occurred), naming the
  sessions and pointing at `needletail session export` for audit.
  With the flag → append an `eventAppended` acknowledgment record
  to the NEW session citing the prior session IDs (durable,
  auditable determination — the flag alone is a bypass, the
  RECORD is the reconciliation decision), then proceed. The flag
  is per-invocation, never persisted. Tests: seeded store with
  unresolved markers → blocked without the flag (exit 2, names
  sessions); proceeds with the flag AND the acknowledgment record
  is present in the new session log; no-marker store → unaffected
  (incl. fresh/empty store bootstrap); non-mutating-only
  unmatched intents → no trip (re-runnable by design).
- `--trusted` stays demo-only: scripted backend, plus an
  ImportGate-style binary test proving `--trusted` performs zero
  real FS mutations.
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
cross-run automated replay; timeout/cancellation semantics left
unspecified (specified: B4 deadlines + wiring); M2-C/D scope;
any merge in this planning track.

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
  SUPERSEDED before review: `performedEffects` is unimplementable
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
- REV8 → deepseek-reviewer: _pending_.
- §8 convention: entries are frozen at write time and describe
  the file as of that round; only the latest entry is current.
