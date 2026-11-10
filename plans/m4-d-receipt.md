# M4-D receipt — Interactive Terminal Integration and Acceptance

Branch `m4-a` (local; no push/PR/merge without separate authorization).
Baselines: M4-A QUALIFIED, M4-B QUALIFIED (`3e9806f`, final battery
`80cab63`), M4-C QUALIFIED (code `6e73568`, receipt `c18fa54`).
Mission: M4-D — real CLI composition, PTY acceptance, lifecycle,
closeout. No M5 work, no live model traffic, no push/PR/merge.

Plan: `plans/m4-d-plan.md` (DeepSeek-reviewed, READY after 3 rounds;
amendments recorded in-plan).

## 1. Baseline and code identity

- Qualified production baseline: `3e9806f` (M4-B).
- M4-C code HEAD: `6e73568`; M4-C receipt: `c18fa54`.
- M4-D work HEAD (M4-D closeout): `bd87724` committed locally
  (the M4-D implementation commit; `c18fa54` is the M4-C RECEIPT and
  must never be cited as the M4-D implementation SHA). Prior
  closeout fingerprint (pre-commit tree): 18 tracked-modified + 11
  untracked paths; `git diff` sha256
  `26e842ebb6662b5e54c81c57a37318c878500f0ded2575efcc5367ddc56794bb`.
- Residual closure commits (all local, no push): `ba723b0`
  (resubmission fix + evidence), `63c637d` (D4 suites + PTY legs),
  `06a9bae` (review fixes). Residual receipt updates committed as
  §11 (this section); final SHA recorded in §11.1 at closeout.
- `git diff 3e9806f -- Sources/NeedletailCore/ Sources/NeedletailRuntime/`
  is EMPTY (verified repeatedly, last at closeout): no Core/Runtime
  production change. A needed Core/Runtime change was and remains a
  plan blocker, not a drive-by edit.
- Permitted production deltas (plan D0.5), all present in the tree:
  - `Sources/NeedletailCLI/ChatCommand.swift` — shared composition
    factory + translate legs (budget transport, attach, undo run,
    inspect, preview, diff, budget, signals).
  - `Sources/NeedletailTerminal/*` — `ChatLoop.swift` (loop, submit
    gate, Tab-accept snapshot, Ctrl+C latch, signal-safe exits),
    `ComposerBridge.swift` (key matrix, queue subcommands, accept
    preview, completion identity).
  - Additive `Sources/NeedletailPresentation/{UIAction,UIReducer,UndoDiffViews}.swift`
    cases + additive `Sources/NeedletailLineEditor/LineEditorSession.swift`
    seam functions (`currentBufferText`, `addHistoryEntry`,
    history snapshot/drop-tail via the existing C
    `replxx_history_scan/clear/add` API).
  - One vendored-replxx patch (`Sources/CReplxx/replxx/replxx_impl.cxx`,
    +7 lines): bracketed-paste LF (`KEY::control('J')` → `\n`),
    mirroring the adjacent CR/TAB handling. Required by PTY-02
    (pasted newlines arrived as U+FFFD). Documented in
    `Sources/CReplxx/README.provenance`, manifest
    `SHA256SUMS-vendored` updated. `./dev vendor-check`: primary
    offline manifest check PASS; secondary clone comparison reports
    exactly this one documented file as different from pinned
    upstream `1f149bfe` (tool has no documented-patch exemption;
    exit 1 on the secondary check only — recorded, not a gate).
- Dependency graph: unchanged from M4-C (`Package.resolved`
  untouched; swift-markdown 0.9.0 + swift-cmark 0.9.0). `Package.swift`
  gains test-only deps (`NeedletailCLI`, `NeedletailTestSupport` for
  the terminal test target — factory tests build the real CLI target
  so they can never pass against a stale binary).
- `Sources/NeedletailTestSupport/LoopbackSSEServer.swift`: additive
  `holdGate` script barrier (`gate:<name>` hold points) + child-env
  isolation fix (see §7). Test-support only.
- Pre-existing working-tree modification, NOT M4-D work (present
  before this session, left untouched):
  `.needletail-dev/m4a-final/run-b6final.sh` (M4-A final hardening).

## 2. D2 handoff closure (M4-C incomplete wiring → owner)

1. `@` attach: closed. `AttachmentCaptureService` called at
   submit/enqueue (fd-pinned); stale/missing fail closed; gitignore +
   symlink-out-of-root honored; tokens display-respected.
   Evidence: `ChatCompositionTests` attach legs (accept captures +
   resubmit attaches; missing file refuses with zero provider
   traffic; cleared token never attaches).
2. Undo RUN: closed. Chat executes `SessionActor.runUndo` with Core
   approval + verification display (no more "stays headless").
   Evidence: composition undo preview + explicit run (real file
   restore); PTY smoke exercised `/undo` path manually.
3. Bare `/undo`: closed — resolves latest eligible group (read-only
   preview); runs always need an explicit group.
4. Inspect legs: closed — sessions/agents/models/context/epochs/
   compact-dry-run/diff/rewind all render `InspectionResult`
   payloads through chat (no "not yet wired").
   Evidence: composition inspect legs; D6 smoke (`/context`).
5. `/preview @path` fallback (§2.2): closed via `previewFile` edge
   (bounded 64 KiB, workspace/read-root confined, escaping refused).
   Evidence: composition preview leg.
6. `/compact`: dry-run + cancel fully covered (sole catalog case
   UX-NAV-05). Trigger remains the explicit NON-CASE deferral (no
   catalog case, no qualified authority; building one would be new
   architecture).
7. Tool display: closed — start/progress/result/denial/unknown rows
   into scrollback via tone roles + `DiffRenderer.receipt`.
   Evidence: composition tool legs; PTY-03/04 streams; D6 smoke.
8. Key bindings: closed per §2.1 map (busy/idle/empty Ctrl+C incl.
   the D2.5 idle-empty-exit behavior change authorized with exact
   tests; Ctrl+J newline; Esc dismiss-first; Tab-accept exactness
   incl. the Enter path; `/keys` discoverability).
   Evidence: `ChatLoopTests` cancel pins, `ComposerBridgeTests`
   paste-literal pins, PTY-01/02/03/04/07, D2.7 hygiene oracle.
9. Completion: closed — explicit completion, budget-boundary,
   failure and held-state presentation; `LiveRequestBudget` enforced
   pre-send via `BudgetEnforcingTransport` (durable same-as-headless:
   same state-dir counter file, same limit selection, same
   fail-closed consume; exhaustion refuses + holds; sticky per state
   dir; startup `budgetReportLine`; unset = unbounded + notice).
   Evidence: composition budget legs (refusal, cross-invocation
   stickiness, unset notice), PTY matrix runs under budgets.
10. History hygiene: closed as implementable (D2.7). Decision lines
    are dropped post-accept via the scan/verify/clear/re-add seam;
    confirm-armed bracketed paste cannot auto-confirm.
    Evidence: `LineEditorHistoryTests` (seeded contract), live PTY
    oracle `testConfirmHygieneNoDecisionInHistory` (D7 finding: the
    prior "replxx auto-commits" assumption was false — replxx only
    stages a scratch entry; the input loop now commits every
    accepted non-empty line via `addHistoryEntry`, which the hygiene
    drop then removes; verified empirically with Ctrl+R + Up-arrow).
11. `/rewind` + epoch inspection: closed — rewind confirms fork (no
    file mutation) + divergence display; epoch prefill visible.
    Evidence: composition undo/inspect legs.

## 3. PTY-01…08 executable evidence (Linux x86_64, release binary)

Runner: `run-m4d-pty.sh` (B6 precedent: release build, nonzero-count
gate per case, transcript preservation). Final:
`M4D-PTV-OK: ChatPTYTests 11 tests green, all PTY-01…08 started`
(log `.needletail-dev/logs/m4d-pty-run.log`).

| Case | Evidence (release `.build/release/needletail`) |
|---|---|
| PTY-01 | open/prompt, busy Ctrl+C cancel, idle-nonempty clear, idle-empty exit 0, queued-work warn-then-exit, termios + bracketed-paste echo restore |
| PTY-02 | bracketed multiline+shell paste mid-stream submits exactly once, literally (vendored LF patch) |
| PTY-03 | `@` candidates + bounded preview during streamed output; Tab-accept exactness; no ghost popup |
| PTY-04 | 100-chunk stream + mid-stream queue + interrupt; no lost draft, no auto-send |
| PTY-05 | real TIOCSWINSZ 40→120→80 redraw; no unknown sequences; no off-viewport cursor address (`sawOutOfRange`, D7 fix for a tautological bound) |
| PTY-06 | hostile OSC/title/cursor/C0/C1/Cf battery: untrusted bytes never unsanitized; every transcript ESC in the owner/replxx allowlist; OSC title model unchanged; scalar-level Cf battery (ZWJ survives, lone Cf → FFFD) |
| PTY-07 | SIGTERM/EOF restore + exit 143/0; SIGKILL kills without cleanup; durable session reopens; export proves pre-kill turn; terminal restored (canonical echo functional check) |
| PTY-08 | TERM=dumb / NO_COLOR / narrow matrix (prompt + turn + SIGTERM-143 exit + restore + bearer proof each); REAL live-tmux path (prompt + turn + cleanup; unique session, kills only it — never the shared server) |
| +2 | PTY-07 EOF (Ctrl+D) clean exit; D2.7 hygiene Up-arrow recall oracle (approval → Up recalls draft, never `y`; resubmit proves via provider body) |
| TERM-04 | as-built delta: `chat` fail-closes non-TTY (exit 2 + exact guidance + zero ANSI + zero provider traffic); `--help` documents chat. (Plan text envisioned a non-TTY loopback *run*; the product's qualified refusal supersedes it — dumb-TERM plain output is proven by the PTY-08 dumb leg instead.) |

Debug/release split: `swift test` builds the debug runner; EVERY
PTY leg drives the release product (no debug-binary PTY claims).
Debug-only macOS PTY-05 `canonicalEchoRestored` ssh-session flake is
pre-existing (reproduces on untouched B6 tree) and is NOT used to
waive any release result (no macOS release runs exist — see §5).

## 4. Case → evidence map (plan §D0.4 rows)

- UX-QUEUE-01…05,07,12 + physical variants: PTY-04 + composition
  (busy-queue FIFO, gate-hold, cancel-hold, caps-refuse notice,
  stale-head hold, budget hold, queue state display).
- UX-QUEUE-06/08/09/10/11: existing B6 actor/integration (not
  re-proved) + chat-surface spots (caps-refusal, stale-hold, silent
  sandbox-policy row; QUEUE-11 analog = sandbox row display-only).
- UX-MENTION-01…08: PTY-03 + composition (revision race, 100K
  catalogue caps, preview sanitize incl. binary/symlink/denied/
  missing/range).
- UX-MENTION-09…12: composition attach legs (capture/stale-hold/
  sealed-refuse/re-consent; zero provider requests on cancel).
- UX-UNDO-01…05,07,10/11 + 06/08/09: existing pure/native + chat
  surface (preview render, conflict display, exec-touched refusal,
  rewind fork with byte-identical worktree + divergence warning,
  interrupted-reversal idempotent-safe display).
- UX-NAV-01…07: composition inspect legs (all views incl. consult
  child, UNKNOWN cache, no-provider-call legs).
- UX-RENDER-01…04,06…08: M4-C pure parity + PTY-disagreement guard
  via PTY transcripts + allowlist scanner (no separate
  render-parity file; parity enforced per-leg, DX-09 fail-closed by
  construction — a frame/PTY mismatch fails the leg).
- UX-RENDER-05: NO dedicated wcwidth fixture file (D4 gap, §8);
  covered behaviorally by PTY-05 resize storm + ZWJ/CJK/emoji
  composition legs (Cf battery, multiline, ZWJ survival).
- TERM-01…03: PTY-02 + paste-literal pins; PTY-05/08 + wrap tests;
  PTY-01/04 + ChatLoop cancel pins.
- TERM-04: as-built delta above.
- DX-01…08: existing (loopback reuse, offline, determinism).
- DX-09: parity enforced per PTY leg (unit-only pass insufficient —
  every leg runs the release product).
- DX-10: deterministic gates/barriers throughout (gate-armed waits,
  marker waits, bounded polls; no sleeps-as-oracles; seeded
  loopback scripts).
- STATE-01…06: composition queue/cancel/delivery/budget legs +
  PTY-07 external-reset boundary (documented + exercised: fresh
  shell + `stty sane` + usable-shell check + session reopen).
- BDD-07: NOT built (no `GoldenRegenerationProbe`; §8 gap).
- PORT-06: Linux offline gate re-run at close (§6); no macOS-shim
  production edits (shim untouched; only test-harness C changes).
- Catalog: all 51 M4-due rows remain `DEFERRED_BY_PLAN`
  (development evidence only per plan D0 contract — not acceptance).
  No waivers; no silent promotions.

## 5. D5 platform matrix

- Linux x86_64: debug runner + release product acceptance green —
  composition 21/21, terminal combined 126/17, presentation
  100/14, PTY runner 11/11, full `./dev test offline` (see §6).
- macOS (Builds-Mac-Pro.local): BLOCKED on environment. Single
  reachability check performed (no repeated polling, no network
  changes): hostname does not resolve (`Name or service not known`)
  and `192.168.2.106` has no route. No host identity, no tree
  parity, no mac evidence this session. Real-SSH/tmux path
  outstanding; Linux real-tmux path green stands as the labelled
  fallback per plan PTY-08 (marked exactly as such).
- No Apple Silicon claim (M4-A boundary stands).
- Provider-integration suite: intermittently red under parallel
  load (WIRE-02 `ECONNREFUSED`, HEAD-01 once) — reproduced on the
  PRISTINE `6e73568` worktree (fail + pass across runs), i.e.
  pre-existing harness flake, unrelated to M4-D changes (M4-D
  TestSupport diff is additive gate plumbing; bind/listen paths
  untouched). Documented as a flake; no required gate is claimed
  green without exact-head evidence (see §6 for the at-HEAD result).

## 6. Linux regressions (exact-HEAD evidence)

- `NeedletailTerminalTests` combined: **126 tests / 17 suites,
  all green** (log `.needletail-dev/logs/m4d-terminal-final.log`).
  Includes 21 composition, 11 PTY (release-driven), loop/bridge/
  history/VT-projection/sanitizer/caps/feasibility suites.
- `NeedletailPresentationTests`: **100 tests / 14 suites green**.
- `run-m4d-pty.sh`: **11/11 green** (release rebuild + nonzero
  gate, all PTY-01…08 started).
- Full `./dev test offline`: **OFFLINE OK — all scheduled offline
  layers passed** (log `.needletail-dev/logs/m4d-offline-final.log`:
  quick, native, timing, e2e, feasibility, coverage, and every
  CFG/CORE/POLICY/STATE/PORT/DX/WIRE/NET/HEAD case filter — zero
  failures, re-verified at the exact closeout tree).
- `NeedletailProviderIntegrationTests` at HEAD: **35/36 pass** —
  NET-03 fails with `TransportFailure(preSend, "connection reset
  (error set): Connection refused (errno: 111)")` after a 5 s
  retry (log `.needletail-dev/logs/m4d-provint-final.log`). Same
  signature as the WIRE-02/HEAD-01 flakes in this session; the
  flake reproduces intermittently on the pristine `6e73568`
  worktree (1 fail in 3 runs) and never in isolation (3/3 green
  alone). Verdict: pre-existing parallel-load harness flake, NOT
  an M4-D regression — reported as a FAILED required-adjacent
  gate with exact-head evidence, not waived.
- Core/Runtime byte-identity vs `3e9806f`: EMPTY diff (final check
  at closeout).

## 7. D7 reviews and dispositions

- Plan review: DeepSeek, 3 rounds → READY (recorded in-plan).
- Implementation reviews (D1/D2 batches): DeepSeek blockers were
  applied during implementation (transport streaming, Ctrl+C exit,
  stale tap, budget, undo-run gate, Tab-accept race) with targeted
  tests; suites green.
- D7 focused review (implementation): NEEDS-CHANGES with 6
  blockers — ALL addressed with targeted regression tests:
  1. PTY-06 lone-Cf `.contains` → scalar `hasScalar` (plan D0.2).
  2. Hygiene unverified (`_ =` discard, dangling oracle ref) →
      mismatch now warns; seeded seam tests; live PTY
      Up-arrow oracle. Review note: the "replxx auto-commits"
      assumption was FALSE (verified in vendored source:
      `get_input_line` stages a scratch entry, `commit_line`
      drops it; history only grows via explicit `history_add`).
      Fix: the input loop commits every accepted non-empty line;
      the hygiene drop then removes the decision line. Without
      this fix the live oracle proved history stayed empty
      (Ctrl+R found nothing).
  3. Tab-accept race (stale snapshot accept + trailing-mirror
      clobber + main-thread `replxx_set_state`) → on-thread
      live-buffer check with silent ignore; recompute-equality
      main gate; echo suppression with park kept for
      mirror/submit reconcile; main-thread buffer writes removed.
      Plus composition stale-accept test. Counterfactuals observed
      during development (three distinct wrong-submit shapes
      before the final form).
  4. Inspect/denied retire (`denied` treated terminal; retire on
      every submit) → `denied` removed from the terminal set
      (Core emits ~20 mid-run denial sites — verified); retire
      lives only on terminal projections + explicit cancel;
      `owner.invalidate` only on real post-gate submits;
      inspect-during-gated-stream lock test + `denied`-excluded
      unit test (existing test updated to the corrected
      contract). Analysis note: per-delta progress re-registers
      liveness, so the retire bug could only drop commits in the
      last-delta→complete window; the denied half (spurious turn
      hook + progress hide) was the deterministically pinnable
      defect.
  5. Bearer oracle missing on PTY-08 matrix legs → added (all
      three legs).
  6. Tautological cursor bound + missing timeout transcripts →
      `sawOutOfRange` (absolute-address only, unit-pinned) replaces
      the clamped bound; `preserveTranscript` hook armed on all 11
      PTY drivers (verified firing in the wild).
- Delta re-review: B6 remainder (SIGKILL driver unarmed) FIXED;
  non-blocking notes dispositioned — scripted-confirm spurious
  warning gated to the live path (fixed); stale Tab comments
  corrected (fixed); PTY-05 per-phase projection noted as future
  robustness (open); `run-b6final.sh` modification confirmed
  pre-existing/out-of-scope; no new debug prints, no weakened
  assertions, Core/Runtime still byte-identical.

## 8. D6 usability smoke (Linux release + synthetic loopback)

Operator-driven via tmux, server 127.0.0.1-only scripted SSE
(`.needletail-dev/m4d-smoke/`: server logs with per-request
`Bearer` proof, config, trace; notes in `SMOKE-NOTES.md`).
PASS: launch (idle + unbounded-budget notice) → submit/stream →
`/context` inspect → approval with exact tool identity → `y` →
receipt + byte-exact file write → follow-up → mid-stream Ctrl+C
(held, prompt back) → resubmit → queue inspect → idle-empty Ctrl+C
clean exit → shell alive, canonical echo on, command echoed once →
`session export` contains user/model turns + cancelling/interrupted
events. Zero non-loopback traffic (server logs prove it).
Recorded defects (minor, non-blocking, no redesign):
(a) answering an approval with `/queue` (non-y) denies, then
`held: queue held: run failed` reads as if something is held while
`/queue` shows empty — noisy but truthful, no loss, no wedge;
(b) startup says "unbounded", `/queue` says "unbudgeted" (wording
inconsistency only).
RESIDUAL CLOSURE — FIXED (was a known limitation, §11.2):
resubmitting a byte-identical completed line reused the command ID
(via the adapter's `CommandIDStore` same-text branch) and the actor
replayed the prior admission WITHOUT dispatching. Root cause was
adapter-tier, NOT Core: each `.inputLine` is one explicit submission
event, so the store now mints fresh per call. Core
`admittedCommands` idempotency is untouched (same-ID retries still
replay). Two explicit identical submits now admit twice; the silent
no-op is gone, proven deterministic + release-PTY.

## 9. Known limitations and explicit deferrals

1. macOS evidence: none (environment-blocked, §5).
2. D4 named suites: BUILT in residual closure (§11.3):
   `ChatStressTests` (concurrent owner stress + boundedness, seeded
   fuzz), `ChatWidthTests` (grapheme-rule width fixtures —
   wcwidth-2 stays out of scope by the M4-B rule, pinned +
   recorded), `ChatRenderParityTests` (+ PTY parity leg),
   `ChatLifecycleTests` (draft/cursor + stale callbacks).
   `ChatAttachTests`/`ChatUndoTests`/`ChatInspectTests` remain
   covered inside `ChatCompositionTests` (named-file split not
   required by the residual scope). `GoldenRegenerationProbe`
   executed as disposable BDD-07 probes P1/P2 (§11.5), not a
   committed suite (review-process evidence per BDD-06 precedent).
3. `/compact` trigger: explicit non-case (plan D0.3.6).
4. Resubmit-identical-text silent no-op: FIXED in residual
   closure (§11.2) — was an adapter defect, not a Core semantic.
5. Stale-Tab ignore requires re-tab (no flicker, no clobber; the
   divergence reconcile covers buffer/state convergence).
6. TERM-04 as-built delta (§3 table).
7. Provider-integration parallel flake (§5; at-HEAD result in §6).
8. `dev vendor-check` secondary clone check reports the single
   documented replxx patch (primary manifest check passes).

## 10. Verdict: M4 PARTIAL — STOP (SUPERSEDED by §11 below; retained for history)

Linux M4-D evidence is complete and green (PTY-01…08 on the
release product, 126-test terminal suite, composition, smoke,
regressions, two adversarial review rounds closed). PARTIAL
because: (a) macOS acceptance is missing (environment, not
product); (b) D4 named stress/width/parity/probe suites are
unbuilt (behaviors partially covered, rows open); (c) BDD-07
probe unbuilt. No M5, no live traffic, no push/PR/merge.

## 11. Residual acceptance closure

Branch `m4-a`, all commits LOCAL (no push/PR/merge). No live model
traffic. macOS policy (revised): Linux is primary; no repeated
polling; one native gate when accessible.

### 11.1 Commit map and identity

- `bd87724` M4-D terminal adapter implementation + M4-D evidence and
  receipts (29 files). This — not `c18fa54` — is the M4-D
  implementation commit (`c18fa54` is the M4-C receipt).
- `ba723b0` Residual resubmission fix + deterministic/release-PTY
  evidence (6 files).
- `63c637d` Residual D4 suites + PTY legs (6 files).
- `06a9bae` Residual review fixes: quota-test writer barrier,
  width-comment count (2 files).
- this residual section + `plans/m4-report.md` §§7–9 (committed on
  `m4-a` as the residual receipt commit closing this section; hash
  reported at closeout in §11.9). Final tree clean.
- `git diff 3e9806f -- Sources/NeedletailCore Sources/NeedletailRuntime`
  EMPTY at residual closeout (re-verified): Core/Runtime untouched
  end to end, including the resubmission fix (adapter-tier only).

### 11.2 Identical-prompt resubmission — FIXED

- Reproduction (TDD, pre-fix RED through the real adapter):
  `ChatCompositionTests.identicalTextResubmitsAdmitTwice` failed
  with "identical resubmit never dispatched — silent no-op",
  `admitted.count == 1`, `server.requests.count == 1`.
- Root cause: `ComposerBridge.CommandIDStore` returned the SAME
  command ID for same text. Each `.inputLine` is exactly one
  explicit submission event (serialized main task; single input
  thread; stale-arm posts once with the slot taken), so the reuse
  branch was pure defect — no retry path ever consults the store
  (retries reuse the already-minted ID below this layer; Core
  `SessionTransition.swift:940` replay intact).
- Fix (smallest adapter defect):
  `ComposerBridge.swift` `id(for:)` mints fresh per call; store
  keeps only a diagnostic `lastSubmission` record. Doc comments
  corrected (header + MARK + call-site semantics). Core untouched.
- Verified contract:
  - Two explicit identical submits → two genuine admissions (2
    provider dispatches, 2 distinct admitted command IDs).
  - Same-ID retry through the same actor replays the identical ack
    with zero new dispatch (Core contract preserved).
  - Up-arrow recall submits via Enter as a new event with a fresh
    ID (store keeps no text→ID map); hygiene PTY leg proves the
    4th request dispatches.
  - Exactly 2 requests for 2 events: no drop, no double (delivery
    is structurally single per event).
- Evidence: composition test (above) + `ComposerBridgeTests`
  `commandIDs` rewritten (fresh per call incl. non-consecutive
  repeat) + `ChatLoopTests.retryReusesID` rewritten (distinct
  `cmd-1`/`cmd-2` effects) + PTY `identicalResubmitAdmitsTwice`
  (release binary, byte-identical second Enter after first answer,
  2 requests both carrying the text, clean exit, allowlist +
  bearer clean) + hygiene comment refreshed.

### 11.3 D4 suites built

Deterministic tests live in `Tests/NeedletailTerminalTests`; PTY
evidence lives in `ChatPTYTests`/runners — never mixed.

- `ChatStressTests.swift` (4 tests, D4.1/D4.4):
  `concurrentControlStormExact` (8 tasks × 50 control emits: all
  400 written exactly once, stale generation drops);
  `droppableQuotaGatedWriter` (gated writer + 2×300 producers:
  exact accounting `written + truncated == 600 + markerDrops`,
  marker iff engaged; writer-park barrier added per delta review);
  `concurrentSubmitsDistinct` (64 concurrent posts → 64 effects,
  64 distinct IDs); `seededSubmissionFuzz` (frozen 200-event
  interleaving: one effect batch per non-empty line, submits ==
  plain lines, all IDs distinct).
- `ChatWidthTests.swift` (6 tests, D4.2): the as-built
  grapheme-cluster rule through `render()` status-busy carrier —
  CJK counts 1 unit (not wcwidth-2; edge moves whole), combining
  pairs never split, flags wrap whole, mixed-script exact
  boundary, TAB renders as visible `\u{9}` counted literally.
  wcwidth-2 stays OUT of scope by the M4-B rule (limitation
  recorded, UX-RENDER-05 closed as grapheme-rule fixtures).
- `ChatLifecycleTests.swift` (1 test, D4.4): superseded
  completions drop with draft byte-exact and gate closed; live
  revision populates the gate.
- `ChatRenderParityTests.swift` (3 tests, D4.3 semantic side) +
  PTY `parityFixedScenario` (release side): the SAME hand-written
  strings (`parity probe`, `parity line one`, `parity line two`)
  asserted against `render()`/tap-block/candidate rows AND in
  ordered containment in the release transcript (+ exactly one
  request). Parity by construction, never generation. Soft-break
  join is the pinned markdown contract.
- `run-m4d-pty.sh` required-legs extended: PTY-01…08 start gate
  plus `confirm hygiene`, `byte-identical second Enter`,
  `TERM-04`, `PARITY fixed scenario`. Final runner result at
  closeout tree: **M4D-PTV-OK: ChatPTYTests 13 tests green, all
  PTY-01…08 started** (11 M4-D legs + resubmit + parity).

### 11.4 Terminal-control and lifecycle counterfactuals (BDD-06 method)

Disposable patches, NAMED oracles, RED captured, byte-identical
restore verified by sha256, oracle re-run green. Full logs in
`.needletail-dev/logs/cf-{a,b,c}-red.log` (local retention);
verbatim RED cores below.

| Probe | Guard removed | Named oracle | RED (verbatim core) | Restore |
|---|---|---|---|---|
| CF-A | non-TTY refusal bypass (`ChatCommand.swift:67` → `if false`) | TERM-04 contract (exit 2 + guidance + zero traffic) | shell `chat </dev/null`: exit **0** (not 2), no guidance; session machinery engaged (`note: proceeding read-only with history in session(s) …`, status + budget lines) — refusal proven load-bearing (non-TTY boot even scans the session store) | `bd2c790d…e300dc3f2` match; `term04NonTTYRefusalAndHelp` green |
| CF-B | EOF `shutdown = true` removed (`ChatLoop.swift:820`) | `scriptedSubmit` (["hello", nil] must terminate) | `timeout 90 swift test --filter scriptedSubmit` → exit **124** (run never terminates without the guard) | `7b287fee…217eb0b7` match; `scriptedSubmit` green (<1 s) |
| CF-C | stale-strip removed (`ChatLoop.swift:812-816` → `if false`) | `staleTabAcceptDropsCleanly` body oracles | `body.contains("@hex plus")` FAIL (stale preview submitted as text); `!body.contains(snap.display + " plus")` FAIL | `7b287fee…217eb0b7` match; oracle green |

### 11.5 BDD-07 deliberately-wrong golden fixture probes

Baselines (`.needletail-dev/cf-baseline-digests.txt`):
`ChatLoop.swift 7b287fee…217eb0b7`,
`ChatCommand.swift bd2c790d…e300dc3f2`,
`basic-chat.json fc54d113…9dbf2d`,
`manifest.json 80e5cb9c…3a5a5e5`,
`GoldenTests.swift fc7ea2a4…f32513`.

- P1 (wrong fixture): `admitted q-1:1` → `q-1:2`. RED: frame
  test (`actual.runs… == expected.runs…` fail) AND manifest test
  (`digest == entry.sha256` fail). Log
  `.needletail-dev/logs/bdd07-p1-red.log`. Restored digest-identical.
- P2 (same-run regeneration): keys reordered
  (`{"lines":…,"width":80}`, indent 1) — same semantics, new
  bytes. Single run: frame test **PASSED** (regeneration
  self-certifies — the hazard, demonstrated) AND manifest test
  **FAILED** (`digest == entry.sha256` — the guard catches it).
  Log `.needletail-dev/logs/bdd07-p2-mixed.log`. Restored
  digest-identical; `GoldenTests` 6/6 green.
- Verdict: the manifest sha256 pin is the ONLY barrier between
  regeneration and silent certification. No auto-regenerated
  golden certifies itself; baseline restored after every probe.

### 11.6 Review closure and regressions

- Focused DeepSeek delta verification (new work + SIGKILL arming;
  no broad-review repeat): items 1 (fresh-mint soundness) and 2
  (SIGKILL arming holds; new legs non-vacuous) PASS. Item 3 found
  one real flake (quota-test first-grab race) — FIXED with the
  writer-park barrier (sentinel + `didEnter`), stable 5/5; width
  comment count fixed; lifecycle sleeps acknowledged as
  settling-only. Item 4 (receipt/probe-evidence mismatch) fixed
  by this section. Overall: NEEDS-CHANGES(minor) → all items
  addressed with evidence; no product-code issue found.
- Targeted regressions at residual closeout tree:
  `NeedletailTerminalTests` **143 tests / 21 suites green** (126
  M4-D + 1 composition resubmit + 4 stress + 6 width + 1
  lifecycle + 3 parity + 13 PTY legs, incl. resubmit + parity);
  `NeedletailPresentationTests` **100 / 14 green** (incl.
  `GoldenTests` 6/6).
- Full `./dev test offline` at closeout tree: **OFFLINE OK: all
  scheduled offline layers passed** (93 executed test-run lines,
  zero `✘`/failures; log
  `.needletail-dev/logs/m4d-residual-offline.log`). HEAD-01 green
  in this run.
- NET-03 provider-integration parallel flake: did NOT manifest in
  this gate run (HEAD-01 green); REMAINS a standing known issue
  from M4-D closeout (35/36 at HEAD then, reproduced on pristine
  `6e73568`) — kept visible, never green-washed.

### 11.7 macOS release acceptance

Single availability check per revised policy (no polling, no
network/security changes): `Builds-Mac-Pro.local` now resolves
but fails host-key verification; `192.168.2.106` is reachable but
denies auth (`Permission denied (publickey…)` in BatchMode).
Reached-but-inaccessible ≠ acceptance-capable; key/host-key
handling is out of scope to touch. Verdict: ENVIRONMENT-BLOCKED
(reachable-but-inaccessible). Linux remains the qualified
primary; the one complete macOS release-acceptance matrix stays
outstanding against the frozen candidate (see §11.9). G14
debug limitations and Intel-vs-Apple-Silicon qualification stay
as recorded in M4-A/B/C (no macOS evidence added or altered).

### 11.8 Remaining limitations (corrected)

1. macOS release acceptance: outstanding (environment-blocked).
2. `ChatAttachTests`/`ChatUndoTests`/`ChatInspectTests` as named
   files: behaviors covered in composition; split not required.
3. `/compact` trigger: explicit non-case (unchanged).
4. wcwidth-2 layout: out of scope by M4-B rule; grapheme rule
   pinned by `ChatWidthTests` (limitation, not a gap).
5. Provider-integration parallel flake (NET-03 class): visible,
   pristine-reproducible, never green-washed.
6. `dev vendor-check` secondary: single documented replxx patch
   (unchanged).
7. Stale-Tab ignore needs re-tab (unchanged); resubmit finding
   from smoke is FIXED (§11.2).

### 11.9 Verdict: M4 PARTIAL — STOP

Linux acceptance is COMPLETE: identical-resubmit fixed with
deterministic + release-PTY proof; D4 stress/width/lifecycle/
parity suites built and green (143 terminal, 100 presentation,
13 PTY, offline OFFLINE OK); counterfactuals CF-A/B/C and BDD-07
P1/P2 executed with byte-identical restores; focused delta
review closed (no product-code issue); Core/Runtime still
byte-identical to `3e9806f`. PARTIAL — not READY — for one
reason only: the macOS release-acceptance matrix never executed
(environment-blocked: reachable-but-inaccessible, §11.7). That
single native gate is the remaining M4 requirement; run it once
against the frozen candidate when the Mac is accessible, then
rerun only affected tests. The branch is READY FOR PUSH/PR (separate
authorization required — NOT performed here) and for aggregate
CodeRabbit review; merge/close waits on the macOS gate.

No M5, no live traffic, no push/PR/merge.

## 12. CI + CodeRabbit remediation (PR #10, post-§11)

Authorization: M4 epic PR authorization (push branch, open draft PR
#10, reconcile CI + aggregate CodeRabbit review; no M5, live
traffic, merge or release).

### 12.1 The six-hour stall — identified cause

CI run `42606665708` (HEAD `2a6f3ea`): the `offline` job spent
5 h 39 min (11:30:28 → 17:09:20Z) inside
`== offline aggregate: feasibility ==` with zero further output,
then hit the 6 h job cap. Last completed phases: quick 3m03s,
native 59s, timing 12s, e2e 8m35s. Kill-time orphans:
`NeedletailTerminalTests-test-runner` + `tmux: server` — the stall
is inside the terminal suite with a tmux session live (PTY-08's
tmux leg is the only tmux user).

Three compounding causes, all demonstrated:
1. Logging defect (construction): `run_swift_test` redirected the
   whole runner output to a file and catted it only at completion —
   a stall is invisible by design. The CI log cannot name the
   in-suite site; the orphans place it in feasibility/PTY-08.
2. Unbounded waits in the PTY-08 tmux helper (`waitUntilExit` +
   `readDataToEndOfFile` with no deadline) plus success-path-only
   `kill-session` cleanup — a wedged tmux server hangs the runner
   forever and leaks the session + live chat child (the exact
   orphan fingerprint).
3. One serial 6 h job with no per-phase bounds: quick/native/
   timing/e2e/feasibility/coverage/cases ran as a single step, so
   one stuck suite consumed the whole budget silently.

Fixes (§12.3, §12.4): streaming logs, per-phase hard bounds with
diagnostics + owned-process cleanup, bounded tmux waits + defer
cleanup (test tier), phase split into individually bounded CI
steps (same job — branch protection unchanged).

### 12.2 CodeRabbit 27 findings — dispositions

Critical + Major, both fixed with regression cover:
- Darwin `tcflag_t` (LineEditorSession): genuine macOS build break
  (`UInt32` into `tcflag_t`==`UInt` fields); fixed with the fields'
  own type on both branches (Linux compile-verified; Darwin branch
  compiles on the final native matrix).
- Vendored replxx edit: restored provenance honesty via a formal
  patch process — upstream bytes untouched, `patches/0001-*.patch`
  + `SHA256SUMS-upstream`, `vendor-check` verifies BOTH directions
  (tree−patch == upstream hash; patch+pristine == tree bytes).
  PTY-02 (exact submitted text) still green on identical tree bytes.

Product-code minors (all with regression tests):
stale-rangeError clear (UIReducer), input-thread shutdown race
removed (ChatLoop), duplicate `/compact` arm removed, bare
`/queue reorder` anchors on the first live entry (was: tail),
stale-arm history drop on the confirm path, progress-line clear
before content batches.

Test-oracle minors: vacuous file legs stripped from the pure
UndoTests (actor test carries the violable inverse-op assertion);
QueueReorder replay seeds pre-move admissions + withdrawn-entry
refusal leg; TOOL10 `binary()` rejects directories on every
candidate; diffLeg Glibc-gated + hermetic git; PTYDriver EOF-hit
fix (the `count < 0` break REJECTED: `nt_pty_read` returns −1 on
routine select-timeout per `nt_pty.c:114-116` — breaking would fail
every >250 ms output gap; all expect paths are deadline-bounded);
tmux `kill-session` deferred (registered before `new-session`) +
PATH-resolved + bounded `tmux()` (caller-side 30 s poll, SIGTERM
then SIGKILL escalation, then loud throw — no spawned watchdog
thread on the hang path) with stdout captured to a FILE, never a
pipe (a daemonized tmux server can inherit the client's stdout
and hold a pipe open forever — the actual CI orphan mechanism;
verified: file capture cannot block) + 10 min leg deadline that
throws to the loud catch path (validated locally against a
wedged-tmux stub: loud failure in 31 s);
coalescing assertion timing-independent; CSI empty params
positional; ChatLoop/ChatLifecycle sleeps converted to readiness
waits (markers, effect batches, gate snapshots, bounded joins);
PTY-04 7 s sleep → bounded resume-retry; 8 settle-then-exit sleeps
→ `settleThenExit` readiness helper (exit probe + positional
fresh-idle/warning poll + bounded final join).

Docs/scripts: m4-c diff verified empty (recorded), m4-d §10 marked
superseded, m4-a toolchain comparison + full tarball digest
corrected from `transfer.log`, run-b6final trap-restore,
run-m4d-pty mkdir order + `#!/usr/bin/env bash`.

### 12.3 CI schedule changes (`dev` + workflows)

- `stream_bounded`: every phase streams live (`tail -f` with
  wall-clock prefixes), heartbeats every 5 min, and dies on a hard
  per-phase deadline (set BELOW the step timeout so diagnostics land
  first) with pre-kill forensics (process tree + threads + wchan +
  fd counts + log tail) plus best-effort cleanup of owned children
  (pid-snapshot tree kill — verified: rc 124, zero strays). A stale
  timeout flag can never fail a later run (deleted at phase start).
  All test invocations route through one line-buffered runner
  (`stdbuf` where available), so a hang always names its last test.
  In-test unbounded joins eliminated: ChatLoopTests/ChatLifecycleTests/
  ChatStressTests use bounded joins; ChatPTYTests uses settleThenExit
  with positional freshness polling + non-recording drain reads and
  file-captured (never piped) tmux output; ChatCompositionTests uses
  bounded joinRun (the CI feasibility stall was an unbounded
  `await task.value` in finishRun/requireReady — now a loud ≤50 s
  failure naming the wedged test instead of a silent hang).
- Redundancy removed: `test native` dropped from the aggregate
  (strict filter-subset of `quick`); `coverage` split so timing/e2e
  execute EXACTLY once per gate (`coverage-from-lanes` reuses the
  lanes' xunit; standalone `coverage` unchanged).
- `coverage-sonar` lane-structured (same test set as the old serial
  run: parallel bulk + serialized actor/integration, timing, e2e,
  feasibility; NEEDLETAIL_BIN wrapper on every lane): genuine
  instrumented report in one local run (78 files, 12773 covered).
- Workflows: one step per phase with `timeout-minutes` (same
  `offline` job — no branch-protection change); Sonar coverage 45
  + scanner 15 within the 60 min job.

### 12.4 Validation (Linux, 4-core `taskset -c 0-3`)

Full revised gate OFFLINE OK (rc 0). Lane durations (4-core):
quick 83 s, timing 17 s, e2e 532 s, feasibility 189 s,
cases m1a/m1b/m1c/m1d 108/54/215/50 s. CI step timeouts are 3–6x
measured. Full terminal 143/143, presentation 100/100, PTY 13/13
(`run-m4d-pty.sh` green), composition + TOOL10 green, standalone
`coverage` + `coverage-sonar` green. One gate flake root-caused
and fixed during validation (beyond the 27 findings): POLICY-04
`trustedExec` raced a TRANSIENT `.executing` phase — the canned
executor auto-completes in one burst, so under load the test task
missed the observation window and the single-response non-final
script then wedged the continuation pump (2nd transport invoke →
`.outOfScript` → stuck in `.requesting`, never `.executing`).
Fix: hold the executor gate (stable end state, the established
`POLICY_04_grantContinues` idiom) + `isFinal: true` (no phantom
continuation); barrier helpers (`awaitPhase`, `awaitInvocations`,
B0's two barriers) converted from yield-count bounds (which expire
in microseconds under a starved pool) to 60 s wall-clock deadlines.
8/8 constrained re-runs green, actor suites green. Two remaining
observed load flakes in files outside this diff, both green on
re-run and documented, not blockers: UX-UNDO-01 preflight, and
the M0-C PTY-05 probe (`narrowerResizeRewrapsComposer` — async
SIGWINCH-vs-Ctrl+C processing order under shared-box load; 9/9
standalone green, file untouched by this change).

Remaining M4 requirement: macOS native matrix only (unchanged).
Targeted Darwin `tcflag_t` correction does not authorize another
Mac campaign — single final matrix against the frozen tree.

### 12.5 Independent adversarial review (DeepSeek, post-remediation)

Two read-only review passes ran over the finished remediation;
both sets of findings were actioned before push:

- Operational review: the bare `tmux kill-server` incidents were
  diagnosed as a capability-retention failure (promises without
  enforcement, tail-end habit completion, no pre-execution check).
  Standing rule adopted: no unscoped destructive commands, ever —
  no bare `tmux kill*`, no `pkill -f` patterns (also removed as a
  pattern from `dev`), one destructive action per invocation max,
  confirm-before-destroy with ownership proof.
- Code review: found one CRITICAL self-inflicted defect — the
  streaming edit had duplicated the phase command launch in
  `stream_bounded`, so every bounded phase ran its suite TWICE
  (second PID untracked; the bare `wait` could block on the
  untracked copy and defeat the phase bound). Fixed by deleting
  the duplicate line; verified single-launch by inspection.
  Also corrected: `readTmuxPipe`'s `availableData` is a blocking
  read (the 10 s deadline could never fire mid-block), so tmux
  output capture moved to a temp file (files never block);
  no SIGKILL escalation after `terminate()`; the kill-session
  `defer` was registered only after `new-session` (moved before
  it); `-L` hermetic tmux investigated and REVERTED (deterministic
  local new-session hang with test-spawned tmux, mechanism
  unproven — default socket retained; CI hang occurs without it,
  so `-L` was not the CI fix).
