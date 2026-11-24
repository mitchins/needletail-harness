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
    (SUPERSEDED by §12.2: the formal patch process replaced
    `SHA256SUMS-vendored` with `SHA256SUMS-upstream` +
    `patches/0001-*.patch` and two-direction verification — the
    manifest-rewrite narrative above is historical.)
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

## 13. Operational-safety remediation (post-authorization, maintainer-directed)

### 13.1 Operational controls

- Project OpenCode policy installed (`opencode.json`, untracked,
  excluded via `.git/info/exclude`): every shell command ASK, 30
  deny rules covering unscoped process termination (`kill`,
  `pkill`, `killall`), all tmux operations, and shutdown/reboot —
  bare, path-invoked, compound (`&&`/`;`/`|`) and env-wrapped
  forms. Built for the installed opencode 1.19.5 (`permission`
  object form, resolved and verified via `opencode debug config`:
  31 merged bash rules, reviewer agents keep their own stricter
  overrides). Acknowledged residual: the policy guards agent shell
  commands, NOT child processes — destructive-path tests (PTY/tmux,
  SIGKILL matrices) run only in isolated CI runners, never on the
  shared host.
- `dev`: `pkill -f` removed (follower reaped by recorded pid;
  pattern kills can hit unowned processes). Unverified descendant
  signalling REMOVED — the deadline killer signals only its own
  `$!` child; a pid snapshot is not an ownership guarantee. The
  proposed /proc starttime-verification scheme was REJECTED by the
  maintainer (incorrect parsing; check-then-kill insufficient).
- Output follower has a bounded lifecycle: GNU `tail --pid` where
  available (exits with the phase pid; awk EOF-exits); elsewhere NO
  follower runs (BSD tail) — log, heartbeat and failure evidence
  remain authoritative. awk `strftime` probed with an untimestamped
  fallback (Apple awk lacks it). No idle `tail -f` anywhere.
- Bounded timeout reporting, rc-124 failure status, read-only
  pre-kill diagnostics (predump) and all log evidence preserved.

### 13.2 Sonar report integrity

- `show2sonar.py` now certifies its own output: deterministic
  post-write validation over the sonar-generic-coverage.xsd
  constraints (well-formedness, root/version, structural shape,
  positive-integer line numbers, covered vocabulary, unique
  relative non-empty paths, XML 1.0 character validity in
  attributes) — the scanner's rejection is a bare "Error during
  parsing" with no diagnostics.
- `sonar.yml` uploads `coverage-generic.xml` as a pinned artifact
  even when the scanner fails (`if: always()` + hashFiles guard),
  so the actual rejected bytes are captured. RESULT: the captured
  bytes + the validator's beyond-EOF diagnostics root-caused the
  violation precisely. ROOT CAUSE (verified): `llvm-cov show` on a
  SINGLE-TU object (`NeedletailLineEditor.o`) emits NO per-file
  path header — the dump begins directly with source lines. The
  dump parser carried `cur` across dump files, so on CI (dev argv
  order: …Presentation → LineEditor → CLI) every LineEditorSession
  line landed on the previous dump's last section,
  `UndoDiffViews.swift` (114 lines): 115 lineNumbers beyond EOF.
  The scanner validates coverage line numbers against source length
  and rejects. (Locally the same bug was SILENT: an ad-hoc
  alphabetical dump order put a 324+-line Core file last, absorbing
  the lines under the length cap.) Fixes: the parser resets `cur`
  per dump file (LineEditor coverage is unaffected — the CLI-binary
  dump contains the same file WITH a header and real counts, which
  is where the artifact's own correct LineEditorSession entry came
  from); the parser also skips `|`-led expansion/instantiation
  records (defensive dedup); the validator rejects lineNumbers
  beyond a source file's real length when on disk — which converted
  this silent misattribution into the loud, precisely-diagnosed
  failure that made the root cause findable.

### 13.3 CodeRabbit round-2 corrections (24 threads)

Applied (each with its regression test): HTTPClient shutdown on
every post-creation failure path in `compose` (AHC trap-on-deinit);
queue reorder midpoint-exhaustion loud refusal
(`queue-reorder-rank-exhausted`) with a halving-to-collapse
regression test that also replays admission-time ranks + recorded
updates; mention backward-scan stops at ANY Unicode whitespace;
progress `progressShown` survives stale-pending drops (clear
suppression + scrollback-commit regression test); rg test resolvers
resolve symlinks (qualifiedRgFD refuses symlinked rg — verified
NativeToolExecutor.swift:1043-1045); trap-class index guards
(`try #require` before indexing) in ChatWidth ×6, MarkdownRenderer
×4, ChatComposition multiline (+ unique completion marker);
latch-disarm assertion counts a SECOND warning (was vacuous);
transcript marks are scalar-based (grapheme-merge shifts
Character-counted offsets); PTY-03 Tab accept is a bounded
readiness poll (positional freshness), not a 500 ms sleep; Darwin
SIGTERM/SIGHUP set SIG_IGN (kqueue EVFILT requires it) with Linux
default disposition unchanged — PENDING NATIVE QUALIFICATION.
Rejected/corrected with evidence: workflow-timeout finding cited a
stale revision (bounds already below steps; real gap was the
coverage step sum, raised 40→50 min); ChatWidth pair literal was
already decomposed (verified by hexdump) — escape + scalar-count
precondition applied as hardening; ChatPTYDriver `count < 0`
break remains REJECTED (select-timeout retry signal).

### 13.4 PTY-08 fresh-server bootstrap — findings and prepared diagnostic

Verified: CI `new-session -d` never returns (loud 30 s bound fires;
suite completes; gate fails closed; no tmux-class orphan in the
last run). Local passes ride the operator's existing server
(no spawn); the reverted `-L` experiment forced fresh-server spawn
and reproduced the hang locally — so the hang is specific to
FIRST-SERVER BOOTSTRAP under a Process-spawned, non-TTY-attached
client, independent of host.

Prepared diagnostic (NOT executed on the development host; requires
an isolated CI job or container, maintainer-approved):
1. Isolation: dedicated job/container; `env -u TMUX`;
   `TMUX_TMPDIR=$(mktemp -d)`; private socket
   `SOCKET=probe-$$`; never touches any default socket.
2. Run: `timeout 20 tmux -L "$SOCKET" -f /dev/null -vv
   new-session -d -s probe -x 80 -y 24`; record `$!` (the ONLY pid
   this run owns) and its exit status.
3. Capture: `$TMUX_TMPDIR/tmux-*.log` (server `-vv` output),
   client stdout/stderr, `ps -o pid,ppid,stat,wchan,cmd` for the
   recorded pid subtree while alive (read-only inspection).
4. Ownership/bounds: `timeout(1)` bounds everything; cleanup kills
   ONLY the recorded pid; no tmux cleanup commands; no pattern
   kills.
5. Evidence decides: server-side failure in the -vv log → tmux
   bootstrap defect (file upstream / choose wrapper); client-side
   hang with a healthy server log → client handshake defect
   (PTYShim-wrapped spawn is the leading candidate fix).

### 13.5 Verdict (unchanged)

PARTIAL. macOS native matrix remains the single outstanding M4
gate; PTY-08 fresh-server bootstrap and the Sonar scanner parsing
are the smallest open issues, both with prepared next steps.

## 14. Sonar reconciliation + coverage exception (PR ready-for-review)

Sequence per maintainer direction: diagnostic workflow + probe
removed (housekeeping commit 41b34e9 — recoverable from git history
3587161..0302436), PR #10 marked ready for review, aggregate
CodeRabbit review requested, Sonar findings resolved/documented
here while review proceeds, then the production tree freezes for
the single final macOS matrix.

### 14.1 Exact gate state (API `qualitygates/project_status`, PR #10)

| Metric | Actual | Threshold | Status |
|---|---|---|---|
| new_reliability_rating | 1 (A) | > 1 fails | OK |
| **new_security_rating** | **3 (C)** | > 1 fails | **ERROR** |
| new_maintainability_rating | 1 (A) | > 1 fails | OK |
| **new_coverage** | **62.0 %** | < 80 fails | **ERROR** |
| new_duplicated_lines_density | 0.7 % | > 3 fails | OK |
| new_security_hotspots_reviewed | 100 % | < 100 fails | OK |

### 14.2 Security rating reconciliation (the "C" is NOT Swift code)

`new_security_rating` = C is driven by exactly **3 open MAJOR
VULNERABILITIES**, all `githubactions` analyzer advisories on
workflow YAML — none in Swift product code:

1. `githubactions:S7694` (linux-ci.yml:109) — "Swift dependencies
   should be locked": FALSE POSITIVE in substance. Dependencies ARE
   locked: pinned `Package.resolved`, `swift package resolve`
   followed by `git diff --exit-code Package.resolved` (drift
   fails the job), and `--disable-automatic-resolution` on every
   build. The analyzer cannot observe SwiftPM locking from a
   workflow `swift build` line. Disposition: acknowledge-as-safe.
2. `githubactions:S7694` (sonar.yml:99) — same, same disposition.
3. `githubactions:S6506` (pty08-diagnostic.yml:68) — swiftly
   download curl without explicit `--proto '=https'`. RESOLVED:
   the diagnostic workflow was removed at 41b34e9 (the issue
   auto-resolves when the file no longer exists). The remaining
   swift/curl downloads in active workflows already use
   checksum + HTTPS or `--proto '=https'`.

Hotspots are NOT involved: `new_security_hotspots_reviewed` = 100 %
OK, hotspot index empty for this PR. The 11 MAJOR code smells
(S107 ×6 too-many-params, S3087 ×4 nested closures, S1172 ×1
unused param, S2961 ×1 backticks) are CODE_SMELL type: they feed
`new_maintainability_rating`, which is **A (OK)** — so they do not
block the gate. Dispositions recorded: S2961 is a false positive
(backticks around `continue` are REQUIRED — it is a keyword);
S107/S3087/S1172 are accepted composition-root/factory design
(single composition root + test-mirror factories; refactoring
frozen M4 code for a smell is out of scope).

Acknowledging the two S7694s requires the SonarCloud UI (issue
keys `AaHMmUqTRRK2SVoU`, `AaHMmUncRRK2SVoU`) — maintainer action
with login; the API path was not available to this session
(SONAR_TOKEN is a CI secret).

### 14.3 Coverage exception (62.0 % vs 80 %) — evidence and deferral

Evidence (computed from the captured CI artifact at 76c087a ∩ PR
diff — production Sources identical through 41b34e9):

- 3,005 new production lines total; of these **211 (7 %) carry NO
  coverage regions at all**: NativeToolExecutor.swift 150 lines =
  `#if !canImport(Glibc)` Darwin spawn primitive (excluded from
  Linux compilation) and UIAction.swift 61 lines = enum-case
  declarations (llvm-cov emits no regions for cases). These lines
  can NEVER be covered on Linux and permanently depress the
  metric. Both 0 %-files in the Sonar annotations are entirely
  this class — verified line-by-line, not assumed.
- Attributed new lines: 1,738, of which **719 uncovered (41.4 %)**.
  Concentration: ChatCommand.swift 272 (interactive `chat` wiring
  whose primary oracle is the PTY lane — green on CI),
  UIReducer 93, LineEditorSession 82 (callback glue + platform
  gates), SessionTransition 78, Render 75, UndoDiffViews 34,
  MentionGrammar 26, QueueSync 23.

Deferral decision: the 80 % condition was calibrated for small
PRs; a 3,005-line epic with 7 % structurally-uncoverable lines
cannot clear it without a blanket campaign (explicitly out of
scope). RECORDED DEFERRAL: accept the red `new_coverage` condition
for this PR with the table above as the evidence baseline;
next-milestone targets (M5 lead-in, not this PR): ChatCommand
interactive-path tests via the existing composition fixtures, and
UIReducer branch completion. The 80 % threshold itself is NOT
altered, and no SonarCloud project setting was changed.

### 14.4 Sequencing state

- PR #10 marked ready for review (draft flag cleared) BEFORE macOS
  qualification, per direction.
- CodeRabbit aggregate review requested; 3 threads intentionally
  open pending CI/native evidence; the rest resolved with
  evidence.
- After review reconciliation: production tree freezes at the
  reviewed HEAD, then the single final macOS release matrix runs
  (it also verifies the Darwin signal handling, §12/§13 pending
  item). Merge readiness is decided from the resulting evidence.

## 15. OPS-10 final review + operational-safety closure (HEAD 67c3587 → this commit)

Directive: close outstanding CodeRabbit/Codatiel findings, qualify the
corrections adversarially, prepare the final merge decision. Scope
held: no merge, no release, no M5, Core/Runtime frozen.

### 15.1 Disposition ledger

| # | Finding (reviewer) | File | Status | Evidence at final HEAD | Correction / regression |
|---|---|---|---|---|---|
| 1 | Timed-out Swift descendants survive the tracked pid, bypassing the latch (CodeRabbit Major) | `dev` stream_bounded | fixed | CI run 43514680706 S1/S2/S4 + corrected S3 rerun 43557904847 | Phase spawned `setsid` (own session/group); escalation TERMs/KILLs the group via `/bin/kill`; survivor detection = `kill -0 -- -pgid` (ownership-scoped: the group exists because we created it) on BOTH timeout and normal exits; survivor → latch → subsequent lanes refuse. No pid snapshots, no tree walks, nothing outside the phase signalled. Harness caught a real bug en route: dash's builtin `kill -0 -- -PGID` misparses negative targets (rc=2 = false "group gone") → all group ops now use `/bin/kill`. |
| 2 | stream_bounded prepends `swift test` to executable commands, breaking case-group lanes (CodeRabbit Major) | `dev` | fixed | aggregate wrapper evidence: dev:622-628 (`stream_bounded cases-mX ... "$0" test case-group mX`) executed in the full `./dev test offline` runs — local rc=0 with m1a–d stages logged, CI offline PASS (run 43532851226 at d6910ce); S5 itself verified only the INNER command's validity (it bypasses the wrapper by construction — `test case-group` is the aggregate-internal subcommand) | Runner executes commands EXACTLY as supplied; Swift composition moved to `swift_bounded` (stdbuf prefix only); case-group lanes pass `"$0" test case-group X` directly. |
| 3 | Watchdog cancellable before group SIGKILL escalation completes (CodeRabbit Major) | `dev` | fixed | CI run 43514680706 S3 (group already dissolved at runner return) | Watchdog moved into the FOREGROUND of stream_bounded (bounded 5 s poll + folded heartbeat); no background watchdog exists to cancel; escalation completes before the runner returns "CLEANUP COMPLETE". |
| 4 | Sonar timeout hierarchy incoherent: lanes sum 135–145 min inside a 45-min step, job 120 (CodeRabbit + Codatiel) | `.github/workflows/sonar.yml` | fixed | hierarchy documented in-workflow; lane budgets 145 total < step 175 < job 240 | Lane sum 145 (bulk 25 + serial 25 + timing 10 + e2e 35 + feasibility 50) < coverage step 175 (escalation + merge/export margin) < job 240 (30 build + 175 + 15 scan + setup margins). Timeouts bind on failure only — runtime unchanged on green; an interrupted lane fails the step visibly and is never certified complete. |
| 5 | PTY-08 cleanup registered before session creation can kill a pre-existing same-name session (Codatiel) | `ChatPTYTests.swift` | fixed | gate structurally verified by inspection at HEAD (flag set ONLY on the line after `new-session` returns; every throw before it leaves the flag false; the defer is registered before any creation call); CI S7 verified the SURROUNDING behavior — dedicated-socket scoping and that a failed same-name creation leaves the existing session alive (shell mirror, it does NOT execute the Swift gate) | `tmuxSessionCreated` flag gates teardown — registered only after `new-session` succeeds; a failed creation can no longer destroy anything. Inspection found no correctness defect, so no targeted regression was added (per directive); the gate executes in every PTY-08 CI run (creation success path) — what is NOT independently exercised is the failed-creation branch of the Swift code itself. |
| 6 | Detached tmux survival after forced test termination (Codatiel; corrected per CodeRabbit delta) | `ChatPTYTests.swift` + `dev` | verified, ownership-scoped; RESIDUAL LEAK RECORDED | daemon() in tmux server escapes any process group (structural); dedicated per-run socket added | Verified REAL: the tmux server daemonizes (setsid) and escapes the phase group, so a deadline kill cannot reap it. Mitigation: every tmux call uses a dedicated per-run socket (`-S`), so operations never touch the shared default server. HONEST RESIDUAL (corrected after initially overclaiming "self-exits"): on a FORCED kill the test's `defer` never runs, kill-session never happens, so the residue is a LIVE tmux server plus a running `chat` process on OUR socket — the socket limits ownership but reaps nothing. Bounded by: ephemeral CI VM teardown reaps it; locally a stale `m4d08-*.sock` + server persists until an explicit ownership-scoped `tmux -S <socket> kill-server` by the operator. Global cleanup / pattern kills remain forbidden. The server self-exits ONLY on the normal teardown path (kill-session succeeds). |
| 7 | Darwin search path-binding/TOCTOU ×2 (Codatiel) | `NativeToolExecutor.swift` | accepted limitation — G1 accurately describes residual risk | in-code docs + M4-A receipt G1 | (a) rg exec binds by validated pathname on Darwin (`/dev/fd` exec is kernel-refused): open-time checks hold (absolute, lstat non-symlink, O_NOFOLLOW, dev/ino pinned, root-owned non-group/world-writable, sanitized PATH/env); residual = pathname replacement between qualification and exec by an attacker already holding write access to the rg install location. (b) search roots bind via `F_GETPATH` canonical path (no symlink smuggling); residual = rename/replacement between resolution and child-open; every emitted path still passes the per-path classifier. Both ARE M4-A G1 ("child-side binding degrades from fd to path on Darwin"); Linux guarantee (fd-pinned exec + held root FDs) unaffected; Darwin verification lands with the release matrix. NOT silently waived — recorded here and in the PR description as an accepted limitation inside the documented G1 scope; expanding the frozen runtime was not proposed. |
| 8 | Observe-mode executor calls / duplicate launches / exit-124 false pass / queue-rank exhaustion / stale cleanup docs (previously reported) | various | verified corrected at HEAD | observe: recording-executor leg + denial receipts; duplicate launches: lane-structured aggregate; 124: CI S6 + local forced-timeout; queue exhaustion: refusal asserts; docs: §13 rewrite | No reimplementation needed; verification evidence cited. |
| 9 | e6aec129 YT2WIKI findings ×8 attributed to Needletail (Codatiel cross-repo misattribution) | — | invalid — excluded | Codatiel defect (since fixed) misattributed another repo's findings | The eight findings are removed from the Needletail ledger entirely; Codatiel itself not investigated per directive (no recurrence). |

### 15.2 Adversarial qualification (disposable CI only)

Temporary `workflow_dispatch`-class workflow (push-triggered on m4-a,
pinned actions, no secrets) ran `.github/scripts/pty-qualification.sh`
against the REAL extracted `stream_bounded` + real aggregate entry
points in an ephemeral ubuntu-24.04 VM:
**run 43514680706 — QUALIFICATION RESULT: PASS=8 FAIL=0, job success**
(evidence artifact `pty-qualification-log`, retention 14 d; earlier
runs 43507339266/43509781953 caught the S1 builtin-kill bug, the S8
bystander natural-expiry, and the runner orphan-detection interaction —
all harness defects, fixed before the green run). EVIDENCE CORRECTION
(Codatiel agent-000, accepted): S3's independent check in that run used
the shell builtin `kill -0 -- -PGID`, which misparses under dash (rc=2
even for live groups), so its "group dissolved" verdict was NOT
independent proof. Corrected rerun on a throwaway branch —
**run 43557904847: success** — uses the production `/bin/kill` form and
verifies the check itself in BOTH directions: positive control
(detects a live group, pgid 2527) then dissolution (rc=124 +
CLEANUP COMPLETE + group -2535 gone). S1/S2/S4/S6/S7/S8 were unaffected
by that defect (their verdicts do not rest on the builtin form). The
harness files are REMOVED from the tree; the receipt + run URLs are
the permanent evidence.

### 15.3 Verification state at final HEAD

- Local: full `./dev test offline` aggregate rc=0 (quick, timing, e2e,
  feasibility, coverage, cases m1a–d); latch gate verified (rc=1 +
  refusal + `latch-clear` restores).
- CI (main workflows) + Sonar: results recorded in the PR description
  and the final report (this commit is the reviewed HEAD).
- CodeRabbit delta review requested on the consolidated correction;
  dispositions checked from actual review state, not workflow success.

### 15.4 Merge decision inputs

Blockers remaining (explicit, none silent):
1. macOS release matrix against this frozen HEAD — operator-gated
   (§11.7: reachable-but-inaccessible host); also verifies the Darwin
   signal split and the G1 search bindings.
2. Sonar quality gate: `new_security_rating` C from 2 documented
   S7694 false-positive advisories (maintainer UI acknowledgment
   required) + `new_coverage` 61.9 % vs 80 (recorded deferral, §14.3).

### 15.5 Core/Runtime freeze accounting (correction to this section)

`git diff 3e9806f -- Sources/NeedletailCore Sources/NeedletailRuntime`
at this HEAD is NOT empty: it contains exactly one hunk — the 12-line
queue-reorder midpoint-exhaustion loud refusal
(`queue-reorder-rank-exhausted`, SessionTransition.swift), applied in
`41998d4` as a verified CodeRabbit round-2 finding with its regression
test (replay-inclusive), documented in §13.3. This is the sole
Core/Runtime delta of the entire epic post-freeze; it was part of the
authorized round-2 remediation, but is restated here explicitly because
the freeze accounting in earlier sections said "byte-identical", which
was true at `06a9bae` and STALE after `41998d4`. The PR description
was corrected accordingly. If the maintainer judges the round-2
authorization not to cover a Core change, reverting this single hunk
(plus its test) restores byte-identity without touching any OPS-10
work.

### 15.6 Codatiel final-review dispositions (comment 6868778244; evidence-quality findings, no runtime defects)

1. **S3 process-group check (agent-000) — CONFIRMED evidence defect; production unaffected.**
   The base harness's independent check used the dash-builtin
   `kill -0 -- -PGID` (misparse → rc=2 = false "group gone"), so S3's
   original verdict was not independent proof. The PRODUCTION runner
   was always correct (`/bin/kill` — the same defect was caught and
   fixed in the product path during the harness's own green-run
   cycle). Corrected rerun: throwaway branch, **CI run 43557904847 —
   success**: positive control (check detects a live group) then
   dissolution verified (rc=124, CLEANUP COMPLETE, group gone).
   Remaining risk: none beyond the recorded §15.1 residuals.
2. **S7 vs Swift teardown gate (agent-001) — CONFIRMED scope overclaim; no correctness defect.**
   S7 verified socket isolation and that a failed same-name creation
   leaves the existing session alive (shell mirror); it never executed
   the Swift `tmuxSessionCreated` gate. Inspection at HEAD: flag flips
   only after `new-session` returns; every throw before it leaves the
   gate closed; defer registered before any creation call — no defect,
   so no targeted regression added (per directive; no harness
   refactor). Receipt wording corrected: the gate's failed-creation
   branch is structurally verified, not independently executed.
   Remaining risk: negligible (two-line structural gate; success path
   exercised in every PTY-08 CI run).
3. **S5 aggregate bypass (agent-002) — CONFIRMED scope overclaim; wrapper evidence rests elsewhere.**
   S5 invoked the aggregate-INTERNAL subcommand directly
   (`test case-group` runs "under the caller's stream_bounded"),
   bypassing the wrapper — it verified the inner command's validity,
   not wrapper composition. Genuine wrapper evidence: the aggregate
   itself (dev:622-628) runs each case-group through
   `stream_bounded ... "$0" test case-group mX`, and the FULL
   `./dev test offline` passed locally (m1a–d stages logged) and in
   CI (offline PASS at d6910ce, run 43532851226). Receipt wording
   corrected. Remaining risk: none attributable to the wrapper.
   The 6 duplication/refactoring suggestions: explicitly DEFERRED
   (reuse opportunities, not correctness findings; no PTY fixture
   extraction).

### 15.7 Native macOS matrix — FIRST REAL EXECUTION (partial; host dropped mid-run)

Access SUPERSEDES §11.7: `build@192.168.2.106` authenticates with the
`mitch@betalab` identity (operator confirmed the provisioned keys,
including `macbuild-dispatch`); host key pinned
`SHA256:nz7Y2Oqriobes8hyWTVPeNzCNdNgD7YMVFewDp5gfoo` (ED25519, TOFU,
operator-directed). Host: Builds-Mac-Pro.local, macOS 26.7.1 (25G241),
**x86_64 Intel**, Apple Swift 6.3.3 (Xcode 26.6 toolchain; Linux gate
pins 6.4 — a toolchain-version delta to note, tools-version 6.1
satisfied). The earlier "reachable-but-inaccessible" record reflects
host flakiness, not missing provisioned access: the host worked ~40
minutes, then dropped off the network mid-matrix and stayed down
(~55 min at recording).

Executed (exact tree, `git archive` of the push HEAD):
- Release build PASS (503.94 s); `needletail --version` 0.3.0 PASS.
- `doctor` PASS with CORRECT fail-closed search provisioning
  (`rg: NOT FOUND — disables the search tool (denied, never a
  synthetic substitute)`) — the Darwin denial path verified natively.
- Test build needed ONE test-infra fix (`bc091fc`):
  `String(validating:as:)` is macOS 15+ and broke the macOS 14-floor
  test target compilation; replaced with the equivalent strict
  `String(bytes:encoding:)`. Linux CI unaffected (gated API missing on
  Glibc).
- `NeedletailTerminalTests`: 13 tests, 21 issues — TERM-04 PASS;
  10 FAIL in three classes:
  - **A (probe soundness, suspected driver artifact)**:
    `canonicalEchoRestored()` failed post-mortem in D2.7/RESUBMIT/
    PARITY/PTY-08-simulated rows. The probe writes to the pty master
    AFTER the child exited; on Darwin the slave tears down at child
    exit, so the kernel cannot echo regardless of the product's
    restore. Preserved transcripts (pty-02/04/06-hex) show the product
    rendering and working correctly natively. Discriminator pending:
    wrapper-`stty` check on the live slave after product exit.
  - **B (genuine product finding — the §15/§13 PENDING NATIVE
    QUALIFICATION item)**: PTY-07 catchable SIGTERM leg FAILED
    (no exit in 3.8 s). Darwin sets SIGTERM/SIGHUP to SIG_IGN so the
    kqueue EVFILT source can deliver; the DispatchSource handler did
    not produce the restore+exit on macOS 26.7.1.
  - **C (genuine product finding)**: PTY-07 EOF (Ctrl+D on empty line)
    leg FAILED (no exit in 15.8 s) — shim/EOF path on Darwin.
  - PTY-08 real-tmux leg NOT executable: no tmux on the host (empty
    preserved logs); the simulated rows' failures are class A.
- One transient `swiftpm-testing-helper` SIGBUS during a filtered
  run; not reproduced in the full-suite run. Noted, unassigned.
- Suites NOT reached before the host dropped: presentation, state,
  actor, config/provider integration, behaviour; macOS packaging
  smoke (per §11.9 scope: build + suites + PTY evidence).

Verdict: macOS matrix **INCOMPLETE — 3 findings recorded (A/B/C), no
disposition yet**. The product builds and runs correctly natively
(build/smoke/doctor/rendering transcripts); the terminal lifecycle
legs are where the Darwin deltas live, exactly as the PENDING NATIVE
QUALIFICATION markers anticipated. B and C cannot be dispositioned
without the host; A needs the wrapper-stty discriminator. No
production code changed in this session; `bc091fc` is test-infra only.

### 15.8 macOS matrix — continued execution (host restarted; release-config sweep)

Resumed after host restart. Redeployed exact HEAD; release + test
builds PASS (550s / 364s). Diagnostics run natively on the Mac
(bounded probes through script(1); no global cleanup, no pattern
kills, nothing outside self-spawned processes touched):

- **Finding A (echo probe) — DRIVER ARTIFACT, product correct.**
  Native stty probe on the live slave: after clean exit the product
  leaves `lflag=200005cb` (ECHO|ICANON|ISIG all set; sole delta
  NOKERNINFO) and after SIGTERM exit `lflag=1cf` (ECHO|ICANON|ISIG
  set, IEXTEN dropped — minor fidelity divergence worth a follow-up).
  The suite's post-mortem `canonicalEchoRestored()` cannot observe a
  torn-down pty on Darwin; every "termios restored" failure in the
  suite is this artifact. Product restore verified directly.
- **Finding B (SIGTERM) — REFUTED; the Darwin signal split is PROVEN
  natively.** Manual probe: TERM while chat runs → exits 143
  (conventional code) with termios restored; the in-suite PTY-07 leg
  itself passed turn-commit → TERM → waitExit → code-143 (its only
  issue is the class-A echo artifact at ChatPTYTests.swift:635). The
  kqueue/EVFILT SIG_IGN design (§15.1 in-code note "PENDING NATIVE
  QUALIFICATION") is now QUALIFIED on macOS 26.7.1.
- **Finding C — CONFIRMED (2 genuine Darwin input defects, unfixed):**
  (C1) idle Ctrl+C (0x03) does not exit (PTY-01 leg deterministic;
  manual probe corroborates — two 0x03 presses did nothing, exit only
  at master-close EOF). (C2) raw-mode Ctrl+D on an empty line does
  not exit (PTY-07-EOF leg, 15.8s no exit). The replxx control-code
  mapping is platform-independent C++ (verified in-tree); the
  divergence sits deeper in the Darwin read/event path — NOT
  root-caused in this closeout. These are terminal-safety defects
  (raw mode must not survive an idle Ctrl+C/EOF exit path).
- **Finding D — dispatch latency exceeds in-suite budgets.** PTY-02's
  full transcript proves the complete flow WORKS (input renders,
  bracketed paste literal + /cancel not executed, admission ranks,
  gated stream completes, second dispatch+stream completes): the
  failures are the 20s gate/expect budgets expiring before the first
  provider request lands on macOS (first-dispatch latency 20-40s
  in-suite; manual probes with identical config dispatch within
  seconds). PTY-03 likewise failed only gate(280) + echo(321). Not
  root-caused (URLSession/SystemConfiguration warm-up suspected);
  budgets were calibrated on Linux.
- PTY-04 anomaly (one observation): transcript 33 bytes — its typed
  input never rendered; single observation, likely the same
  stall/init window; needs its own repro when investigation resumes.
- **Debug-config SIGBUS (signal 10)** in the Xcode 26.6
  swiftpm-testing-helper on macOS 26.7 Intel — reproducible with
  filtered swift-testing runs (State/Actor/PTY); NO crash report
  captured (reporter appears disabled). **Release config is CLEAN**:
  NeedletailStateTests 105/105 PASS in `-c release`. Toolchain
  infrastructure issue, not product.
- **Remaining suites (release config)**: Presentation 102/102 ✓
  (debug), ConfigIntegration 21/21 ✓ (debug), State 105/105 ✓
  (release). ActorTests 63/65: two loopback-script legs
  (`.outOfScript` after 60s waits — plausibly finding-D latency
  exhausting the scripted economy; unproven). PrimitiveTests: B2
  search-evidence legs FAIL LOUDLY by design — `rg` is not installed
  on this host (`rg required for B2 search evidence; silent skip is
  not evidence`). ProviderIntegration/Provider/Config-pure/Behaviour/
  QualificationProbes: not completed this session (probe session
  ended before those lanes ran). TerminalTests release-config sweep:
  not rerun (debug evidence above stands).
- Environment gaps for FULL acceptance: `rg` (search evidence legs)
  and `tmux` (PTY-08 real-tmux leg) are not installed on the host.

### 15.9 macOS acceptance verdict (updated)

Native evidence now EXISTS: build, bundle, doctor fail-closed, prompt/
editing/paste/admission/streaming/rendering, TERM restore+143,
SIGKILL boundary, durable export recovery, resize redraw, hostile-
stream containment, credential fail-closed — all verified natively on
macOS 26.7.1 x86_64. The Darwin signal-split pending item (§13) is
QUALIFIED. Remaining BEFORE macOS acceptance can be declared:
1. **C1/C2 (idle Ctrl+C exit; raw-mode Ctrl+D exit)** — genuine
   product defects on Darwin; require a targeted fix + the two legs
   going green. (Production change → separate authorization per the
   freeze rules; NOT executed in this closeout.)
2. **Finding D** first-dispatch latency vs 20s budgets — root-cause
   or budget recalibration decision for the maintainer.
3. Install `rg` + `tmux` on the host; rerun the search-evidence legs
   + PTY-08 real-tmux leg.
4. Complete the un-run lanes (ProviderIntegration, Provider-pure,
   Config-pure, Behaviour, QualificationProbes; Actor's two legs).
5. Xcode 26.6 debug-config SIGBUS — use `-c release` for macOS test
   evidence until the toolchain issue is dispositioned.

## 16. M4-MAC-02 — Darwin input-path correction (authorized narrow production fix)

Directive: root-cause and fix C1 (idle Ctrl+C) / C2 (empty-line
Ctrl+D), correct the echo oracle, include the IEXTEN termios delta,
diagnose dispatch timing (D), provision rg/tmux, finish native
acceptance. No M5, no scope expansion.

### 16.1 Root cause (native, instrumented, sampled)

Instrumented the input path (temporary env-gated diagnostics, removed
post-investigation) and sampled hung children with source-line
symbols. The chain through the bound key handler is CORRECT on Darwin
(byte 0x03 → mapped control('C') → handler → .exit → BAIL — traced
end-to-end). The hang is in the unwind: **every raw-mode transition —
the per-keystroke IOModeGuard re-apply around the modify callback AND
the read-loop unwind — calls tcsetattr(0, TCSADRAIN, ...), and on
Darwin that waits for the tty output queue to settle. The composer
output pipeline (writer thread + per-event renders) keeps the queue
fed, so the transition blocks indefinitely**; the loop then re-blocks
in read_char (sampled: input thread in wait_for_input/select after
the handler returned BAIL; main thread alive on the shutdown
semaphore). Non-deterministic from the outside (hangs exactly when
output was in flight) — which is why manual probes sometimes passed
and in-suite runs always failed. **Finding D is the same defect**: the
per-keystroke IOModeGuard drains stalled input processing, producing
the 20-40 s first-dispatch latencies that exhausted the 20 s gate
budgets.

### 16.2 Corrections (our layers + one sanctioned upstream patch)

1. **`0002-darwin-raw-mode-transitions-tcsanow.patch`** (vendored
   replxx, `__APPLE__`-scoped, registered per the provenance model —
   vendor-check passes offline (R)+(F) and clone): raw-mode
   transitions use TCSANOW on Darwin; other platforms keep TCSADRAIN.
   TCSANOW applies immediately; queued output was already processed
   under the flags in effect at write time.
2. **`TerminalOutputOwner.quiesce()`**: stops queued + future
   emissions; ChatLoop calls it before every BAIL (Ctrl+C exit, and
   the new Ctrl+D binding) so the unwind runs against a quiet tty.
3. **Ctrl+D bound in ChatLoop** (replaces replxx's default send_eof):
   empty buffer → quiesce + abort (the C2 path, symmetric with C1);
   non-empty → delete-forward via get/set_state, preserving the
   default semantics.
4. **`restoreSaneTermios()` restores the terminal's own pre-raw
   state** (lflag/oflag/iflag captured at session init): IEXTEN is
   restored exactly (raw-mode entry clears it; the synthetic sane
   subset dropped it — the post-SIGTERM lflag delta). OR-ed sane
   subset (incl. IEXTEN) remains as fallback.
5. **Echo oracle replaced**: the shim keeps the slave fd open in the
   parent (never used for I/O) and exposes `nt_pty_slave_termios` +
   `nt_pty_have_initial_termios`; the driver oracle compares the
   post-exit slave termios EXACTLY (lflag/iflag/oflag/cflag) against
   the spawn-time capture — the initial-versus-final comparison the
   acceptance requires, which also catches partial restores such as a
   dropped IEXTEN. The old post-mortem echo-probe could never observe
   a torn-down pty on Darwin and mis-measured every restore as failed
   (11 false failures).
6. **`dev vendor-check` scoping fix**: its temp `git apply` ran inside
   the real repo and silently no-oped (a/ b/ paths resolved against
   the repo root); the temp dir is now its own repository so patch
   verification is contained and real.

### 16.3 Native verification (macOS 26.7.1 Intel)

- C1 probe (0x03 at idle, post-fix binary): exits cleanly, no orphan.
- C2 probe (0x04 on empty line): exits cleanly, no orphan.
- In-suite post-fix run (before the oracle swap): exit-path collapse —
  PTY-01 15.9 s → **2.9 s**, PTY-04 21 s → **4.9 s**, PTY-02 53 s →
  **33 s with the gate ARMING** (finding D's latency GONE — the TCSANOW
  patch removed the per-keystroke stalls). Every remaining failure was
  exactly one issue: the invalid post-mortem oracle (11 legs), now
  replaced.
- PTY-04 zero-render anomaly: did not recur post-fix (the leg's only
  failure was the oracle), consistent with the stalls having been the
  cause.
- Suite-level rerun after the oracle swap: **BLOCKED by host
  infrastructure** — the host's swift-testing launch path degraded
  mid-session (the toolchain helper spawns the runner, the runner dies
  at spawn — the SIGBUS family seen earlier — and the helper waits in
  `__wait4` forever; reproduced in release and debug configs, after
  full process cleanup, at load average 1.5; earlier the same host ran
  three full suites). Host remediation (reboot / toolchain reset) is
  operator-side; the rerun is one command on the fixed tree.

### 16.4 Remaining macOS acceptance steps

1. Host remediation → rerun `swift test -c release --filter
   ChatPTYTests` (and the debug fallback if the helper still wedges):
   expected green on all exit-path legs with the exact-restore oracle.
2. Provision rg (pinned release binary) + tmux; rerun the B2 search
   evidence legs + the PTY-08 real-tmux leg.
3. Complete ProviderIntegration / Provider / Config-pure / Behaviour /
   QualificationProbes lanes (release config; Actor's two outOfScript
   legs expected green post-0002 — same stall class).
4. Linux regression qualification (CI on the fix commits).
5. Sonar dispositions (unchanged, §14).

Freeze accounting: NeedletailTerminal, NeedletailLineEditor,
NeedletailCLI untouched by the freeze contract (Core/Runtime hold —
re-verified: the only Core delta remains the accepted
`queue-reorder-rank-exhausted` guard). Vendored replxx changes are
confined to the registered patch.

### 16.5 MAC-02 verification close-out (HEAD 803a604)

- **Linux regression: GREEN.** `swift test -c release --filter
  ChatPTYTests` (debug bundle + release product; stable runner path)
  executed the full terminal suite with the new oracle.
- **The exact oracle proved itself immediately on Linux**: it caught a
  REAL partial restore the old probe could never see — the Linux
  SIGTERM path left replxx's raw c_cc (VMIN=1/VTIME=0) in place,
  and the first fix (flags-only restore) still failed because the
  pre-raw capture was a lazily-touched static whose first access
  happened INSIDE restoreSaneTermios (i.e. captured the raw state).
  Final form: eager capture at session init + full-termios restore
  (lflag/oflag/iflag/cflag/c_cc). Both caught and fixed within this
  correction, exactly the before/after qualification the directive
  required.
- **rg 14.1.1 + tmux 3.4 provisioned on the host** (official release
  artifacts; rg binary + libevent/tmux built from pinned tarballs
  into ~/.local + ~/bin); the PTY-08 real-tmux leg and B2 search
  evidence legs can run once the suite launches again.
- **Suite rerun status**: the host's swift-testing launch path remains
  wedged (helper spawns the runner, runner dies at spawn, helper waits
  in `__wait4`; reproduced in release and debug configs, after a full
  process cleanup AND a from-scratch `.build` rebuild, at load ~1.5 —
  host-side remediation required; the same host ran three full suites
  earlier in the session). One command on the fixed tree once the
  host is remediated:
  `swift build -c release --product needletail && PATH="$HOME/.local/bin:$HOME/bin:$PATH" swift test --filter ChatPTYTests`
  Expected: all exit-path legs green (C1/C2 fixed, verified by direct
  probes; D latency gone — the gate armed in the first post-fix suite
  run); remaining verdicts come from the exact-restore oracle.
- Freeze accounting unchanged: Core/Runtime hold except the accepted
  queue-reorder guard; replxx deltas confined to registered patches
  (0001, 0002); vendor-check passes offline (R)+(F) and clone.

### 16.6 Final native qualification attempt (exact HEAD 558a5ed, no implementation changes)

Environment: Builds-Mac-Pro.local, macOS 26.7.1 (25G241), x86_64,
Xcode 26.6.0 (Swift 6.3.3), fresh tree from `git archive 558a5ed`,
release product rebuilt (491.74 s), rg 14.1.1 + tmux 3.4 provisioned
(~/bin, ~/.local/bin on the runner PATH), stale processes cleaned,
one-at-a-time suite invocations.

- **Toolchain-health control: PASS.** `swift test -c release --filter
  ChatWidthTests` → rc=0, "Test run with 6 tests in 1 suite passed"
  (the runner launches and executes when no test spawns child
  processes).
- **Any suite that spawns product children: ENVIRONMENT FAILURE.**
  The swift-testing runner process enters exit-blocked limbo
  (ps STAT `?NEs` — attempting exit, stuck — sampled at 21+ min in
  release and 4+ min in debug), produces ZERO test-result lines, and
  the toolchain helper (`swiftpm-testing-helper`) waits in `__wait4`
  forever. Reproduced: release ChatPTYTests (21 min), debug
  ChatPTYTests (4 min), after full process cleanup and a from-scratch
  `.build` rebuild, at load ~1.5, host uptime 1d13h. The same host ran
  three full debug suites earlier in the session; the degradation is
  host/toolchain-side (Xcode 26.6 helper + runner exit path), not
  product: the product children themselves exit cleanly (verified by
  probe and by the absence of orphans post-run) and the equivalent
  full suite + oracle is GREEN on Linux at the same HEAD.
- **Standing native evidence for the exit paths** (from the earlier
  working window + probes, recorded in §15.8/§16.3): C1/C2 exit
  cleanly post-fix (deterministic hangs pre-fix); PTY-01 15.9 s →
  2.9 s; PTY-02 gate armed (D latency gone); PTY-04 anomaly gone;
  all 11 residual failures were the replaced post-mortem oracle.

**Verdict: macOS qualification remains HOST-BLOCKED (environment,
not product).** Operator remediation: reboot the Mac (or reset the
Xcode 26.6 toolchain), then run ~/nb-matrix.sh (persisted in the
operator home; a copy also at /tmp/nb-matrix.sh) — it executes the control + all twelve lanes in release config and writes
/tmp/matrix-summary.log. No code changes are needed or pending for
the macOS verdict; Linux carries the identical suite + oracle green
at this HEAD.

### 16.7 Post-reboot qualification (final)

Operator rebooted the host. Control lane **PASS** (ChatWidthTests
6/6, rc=0) on the fresh boot. The twelve-lane matrix then ran; the
runner-exit wedge RECURRED and is now fully characterized:

- **Every child-spawning suite runs its tests to completion (results
  stream to the per-lane log) and then wedges: the runner enters
  exit-blocked limbo (STAT ?NEs, unsampleable even by sudo sample and
  invisible to lsof) and `swiftpm-testing-helper` waits in `__wait4`
  forever.** The wedge survives a full OS reboot, a from-scratch
  `.build`, release and debug configs, and `--disable-xctest`. The
  no-child-spawning control passes every time.
- Matrix results (harvested from the per-lane logs; rc missing where
  the runner wedged at exit): ChatWidth 6/6 ✓; **ConfigTests 77/77 ✓;
  PresentationTests 102/102 ✓; StateTests 105/105 ✓;
  ProviderTests 34/34 ✓; ConfigIntegrationTests 21/21 ✓;
  BehaviourTests 28/28 ✓; QualificationProbes 5/5 ✓** (all release);
  ActorTests 63/65 (two loopback legs outOfScript at 60 s); ChatPTYTests
  PTY-01 **did not exit after idle-empty Ctrl+C in-suite** (recorded
  twice — the in-suite exit remains NONDETERMINISTIC across runs even
  with 0002 + quiesce: the same leg exited in 2.9 s in an earlier
  post-fix suite run and in every manual probe); ProviderIntegration
  lane died with the helper wedge; PrimitiveTests killed mid-run by
  process cleanup — its visible failures were the rg-missing B2 legs.
- **rg cannot be provisioned for the search-evidence legs on this
  host**: the product's sanitized search PATH is pinned to
  /usr/bin:/bin by design (fail-closed) and macOS SIP makes both
  read-only. The B2 legs' loud failure is the CORRECT product
  behavior; the legs are environment-blocked pending an operator
  decision on rg placement (SIP/configuration change — outside this
  correction).

### 16.8 Final verdict (M4-MAC-02)

FIXED AND NATIVELY VERIFIED: C1/C2 manual-probe exits (deterministic
pre-fix hangs → clean exits), D dispatch latency (0002 removed the
per-keystroke drains — the PTY-02 gate armed and latencies collapsed
in the post-fix suite run), the oracle replacement, the IEXTEN-precise
restoration, Linux green at HEAD (offline gate + terminal suite + the
exact oracle).

UNRESOLVED (each precisely scoped, none partially fixed):
1. **In-suite exit nondeterminism**: PTY-01's idle Ctrl+C exit hangs
   in some in-suite runs and succeeds in others (and in every manual
   probe). All fixes so far addressed the identified deadlock; a
   residual race remains — sample next occurrence (the process tree
   was cleared before a sample could be captured this run).
2. **Xcode 26.6 helper/runner exit-limbo** (infrastructure): blocks
   suite-level result reporting on this host. Operator remediation
   (reboot did NOT clear it; toolchain reset or runner bypass is
   required).
3. rg placement decision (SIP) for the search-evidence legs.
4. Actor's two outOfScript legs (60 s budgets) — retest after 1.

MERGE verdict: **HOLD** — macOS native acceptance cannot be declared
with the in-suite exit nondeterminism unresolved and the suite-level
reporting blocked; Linux remains green at HEAD (offline gate +
terminal suite + oracle).

## 17. M4-MAC-03 — bounded correctness closeout (HEAD fe8d470 → this commit)

Five Codatiel findings dispositioned (all five individual verdicts
below); three actionable items fixed; targeted native verification
done on the Mac.

**A — Terminal snapshot (confirmed, FIXED):** the pre-raw capture is
one optional value (`termios?`); a non-TTY or failed tcgetattr yields
nil and the restore path takes the sane fallback (IEXTEN included) —
a failed capture can no longer masquerade as a valid zero snapshot.
Capture remains eager at session init (before raw mode).
`captureTermiosFrom(fd:)` is fd-parameterized for the failure-path
regression: pipe → nil (refused), real pty slave (via the shim) →
canonical capture. Regression: `mac03CaptureRefusesNonTTY`.

**B — Output-owner deadlock (credible, FIXED):** confirmed as the
in-suite intermittent PTY-01 hang mechanism — quiesce() waited for
the writer's in-flight batch while that batch's writes could block on
replxx's notification pipe, which only the input thread drains — a
circular wait. Fix: the writer DROPS a captured batch instead of
writing once quiesced (no tty write, no notification write during the
unwind; ordering/cleanup semantics unchanged for live operation).
Regressions: `mac03CtrlCUnderBackpressure` (Ctrl+C during a 40-chunk
streamed turn → exit + exact restore) and repeated native probes.

**C — Oracle comparator (fixed):** the shim comparator now compares
MEANINGFUL settings — all four flag fields, every NCCS control
character, and both speeds — explicitly; no memcmp, no struct-padding
dependence. Proof regression
(`mac03TermiosComparatorProof`): identical → equal; IEXTEN flip,
VMIN flip, VTIME flip, c_cflag flip → each caught (platform-constant
indices, no literals).

**D — Buffered replxx messages (verified safe):** `finalize_input()`
drains `_messages` through `_terminal.write8` BEFORE
`disable_raw_mode()` — pending output always flushes before the mode
restore. No correctness gap; documentation stands (receipt §16
ordering note).

**E — rg qualification (receipt corrected; remediation done):** the
earlier SIP explanation was wrong. `locateRg()` supports
`/usr/local/bin/rg`; the actual failure was provisioning rg at
`~/bin/rg` — outside locateRg's candidate list — so `locateRg()` →
nil → the B2 legs' loud fail. Remediation: the pinned release rg
(14.1.1) installed at **/usr/local/bin/rg** (writable, no SIP
involvement; the product launches rg by absolute path so the
sanitized env PATH is unaffected — no environment weakening).
Verified: the B2 search-evidence legs no longer report locateRg
failures.

### 17.1 Native verification (macOS 26.7.1 Intel, post-delta build)

- C1 probe (idle Ctrl+C): exit rc=0, no orphan ✓ (repeated).
- C2 probe (empty-line Ctrl+D): exit rc=0, no orphan ✓.
- Backpressure regression + oracle proof + capture regression run in
  the terminal-suite lane (Linux CI executes them at this HEAD; the
  macOS suite attempts hit the helper wedge documented in §16.7 —
  the helper wedged mid-lane during the Primitive run even after the
  reboot, truncating it post-B2).
- **The host's runner exit-limbo persists post-reboot for
  child-spawning suites** (helper wedges; per-lane logs still stream
  results until the wedge). Suite-level macOS reporting therefore
  remains environment-blocked; targeted verification above is the
  authoritative native evidence for this correction.

### 17.2 Verdict

A/B/C fixed with regressions; D verified safe; E corrected +
remediated (rg at /usr/local/bin). Linux CI green at this HEAD
executes every new regression. Remaining macOS blockers are the
documented environment items (helper exit-limbo; in-suite exit
nondeterminism to be sampled on next occurrence). M4 stays HOLD; no
merge, no M5.

### 16.9 Post-reboot full matrix (post-0003 tree)

Control PASS again (ChatWidth 6/6). The full ChatPTYTests release run
**wedged the swift-testing runner at exit again** (STAT ?NEs, ~22 min,
zero test-output lines) — reproduced identically post-reboot, with all
MAC-02/03 fixes in the binary, after process cleanup, and with the
wedge-discriminator suite (2 trivial shim spawns: slave-closed vs
slave-retained to exit) **passing cleanly both ways** (2/2, rc=0, the
runner exits normally). The wedge therefore requires the FULL PTY
suite context (13 legs + loopback servers + streamed turns + oracle
reads) and is not explained by the simplest cleanup hypothesis; the
wedged runner cannot be inspected on this host (sample/lsof/ptrace all
refused — the process is in an uninterruptible exit state).

Lanes completed this session (release): ChatWidth 6/6 ✓, Config 77/77 ✓,
Presentation 102/102 ✓, State 105/105 ✓, Provider 34/34 ✓,
ConfigIntegration 21/21 ✓, Behaviour 28/28 ✓, QualificationProbes 5/5 ✓;
Actor 63/65 (two outOfScript legs); Primitive truncated (B2 search legs
GREEN post-rg-provisioning before truncation). ChatPTYTests: blocked by
the runner wedge (its exit-path/flow verdicts stand from the earlier
completed run + the repeated native probes).

### 16.10 Final verdict

M4-MAC-03 completed: A/B/C fixed with regressions (Linux-green),
D/E dispositions recorded (D verified safe; E remediated — rg at
/usr/local/bin, B2 search legs green). Linux CI green at HEAD.
**Remaining merge blocker: the macOS suite-level ChatPTYTests
verification is blocked by the Xcode 26.6 runner exit-limbo — an
environment/toolchain issue requiring an operator decision (Xcode
reset, runner bypass, or a macOS/toolchain update), with the
in-suite nondeterminism already reduced to a single named defect
class by the MAC-02/03 corrections.** No implementation changes were
made beyond the authorized bounded corrections.

## 18. M4-MAC-04 — immediate correctness correction (HEAD 0b85927/995d271 lineage)

Three current-head defects dispositioned and fixed; targeted native +
Linux verification complete.

**P0 (Codatiel 6961747626 finding 1, CONFIRMED — my defect):** the 5 s
bounded wait started at session LAUNCH and force-exited healthy
interactive sessions ~5 s in. FIXED: the teardown watchdog moved
INSIDE executeStatic — armed after session.run() returns, cancelled
at return — bounding ONLY the post-run cleanup; the outer wait is
unbounded again. REGRESSIONS: `mac04IdleSurvival` (3 rounds × 16 s
idle survival → Ctrl+C → exit 0 → exact restore — 48.6 s total,
green ×3 locally) and `mac04StreamingSurvival` (60-chunk stream,
16 s mid-stream survival → settle-then-exit → exact restore — green).

**P1-B (Codatiel 6963052000 window, partially addressed then
reverted):** the input-drain writer gate (drop batches when the input
thread is not draining replxx) eliminated the blocked-write entry —
but dropped legitimate renders in edge windows (D1's initial frame,
CI-proven) and did not fix the raw-at-exit. REVERTED. The remaining
protection: drop-on-quiesce + the bounded shutdown + the input
thread's last-word exact restore (the restore runs after the unwind
completes — before the teardown hang window).

**P1-C (Codatiel d4089bfbd133 finding 1, CONFIRMED):** the pre-raw
capture is per-SESSION (instance property captured at init) — a
process-wide static held the first session's capture. Regression:
`mac03CaptureRefusesNonTTY` continues to cover the nil path.

**0003 extension (EINTR retry registered):** terminal.cxx raw-mode
transitions retry tcsetattr on EINTR (a swallowed signal-interrupted
restore left the terminal raw forever — the in-suite exit
nondeterminism mechanism). Folded into the unified
`0002-darwin-terminal-transitions.patch` (one patch per file);
vendor-check passes offline (R)+(F) and clone; provenance registry
updated. The bounded shutdown applies the exact captured termios as
the LAST terminal transition before a forced exit.

**Native verification (final build, macOS 26.7.1 Intel):**
- C1 idle Ctrl+C ×5: clean exits, zero orphans.
- C2 empty-line Ctrl+D ×2: clean exits, zero orphans.
- PTY-02-style dispatch probe: admission → dispatch → server receipt
  (requests=1) → streaming render ✓.
- Feasibility suite (Linux, final): 9/9 incl. the comparator proof,
  the capture regression, the backpressure settle-then-exit, both P0
  survival legs. Linux offline gate: GREEN at 995d271 (the terminal
  suite + exact oracle included).

**Full macOS matrix: still blocked by the toolchain runner.** The
swift-testing runner wedges at launch/exit (STAT ?NEs, zero test
lines, unsampleable) for the ChatPTYTests filter — reproduced
identically after the OS reboot, on release and debug configs, with
a from-scratch `.build`, and with all product fixes in the binary.
**The directive-required discrimination is recorded**: a minimal
independent child-spawning swift-testing suite (the shim spawn,
slave-closed AND slave-retained variants) PASSES cleanly both ways
(2/2, rc=0, the runner exits normally) — the toolchain runner
handles minimal child-spawning; the wedge requires the FULL PTY
suite context. The runner is uninspectable on this host (sample,
lsof and ptrace all refused; the process sits in an uninterruptible
exit state), so the exact blocking frame cannot be captured without
host-level remediation (Xcode/toolchain reset or update — operator
decision).

## 19. M4-MAC-04B — terminal lifecycle closure (final head 2066bb8)

**Linux final-head qualification: PASS.** Offline gate (build + full
test suite incl. the terminal/PTY oracle, the MAC-02/03/04
regressions and the feasibility legs): 35m38s, green at 2066bb8.
Release bundle smoke (clean host): green. Sonar: the two known
policy conditions (new_security_rating from the 2 documented S7694
false positives; new_coverage deferral) — unchanged, operator UI
actions.

**Focused native tests (final head rebuilt from the 2066bb8
tarball, release config, macOS 26.7.1 Intel):**
- C1 idle-empty Ctrl+C ×2: exit 0, prompt cycle rendered (boot +
  re-prompt), zero `NEs` orphans.
- C2 empty-line Ctrl+D ×1: exit 0, prompt cycle rendered, zero
  orphans.
- Probe-harness notes: BSD `script(1)` requires the child command
  unquoted; `mktemp` requires the XXXXXX template without a
  suffix; chat configs are JSON (the ConfigSnapshot schema with a
  `tools` object and `allow_http_origins` entries equal to real
  origins) — three harness iterations were spent discovering these;
  recorded here so future probes start from the working form:
  `(sleep N; printf "\003") | script -q /dev/null BIN chat --config CFG`.
- The PTY-02-style dispatch leg was exercised at this head but the
  external python loopback harness proved fragile under the ssh
  timeout regime (the server lifecycle vs the session HUP);
  seen=NO with the chat alive. The dispatch/admission evidence at
  this code is §16.9's recorded probe run (identical product
  sources; 2066bb8 differs only by receipt/test files — CI green at
  both 995d271 and 2066bb8). A native in-suite dispatch run remains
  blocked by the toolchain runner wedge (§18).

**The full-suite macOS runner wedge: unchanged** (§18's
discrimination stands: the minimal child-spawning suite passes; the
full PTY suite wedges the runner at launch/exit, unsampleable).

**Verdict: HOLD.** All four immediate corrections from the MAC-04
directive remain fixed and Linux-qualified at the final head; the
focused native legs re-confirm the idle-exit and Ctrl+D lifecycle
paths. No merge, no release, no M5.

## 20. M4-MAC-04B implementation gaps (HEAD 37b5bbb)

**1. Watchdog lifecycle — fixed.** The input thread reads
`confirmArmed` BEFORE arming: a nil readLine while an approval is
armed settles the approval (deny) and posts the D2 busy-cancel (the
denied run must release the queue — Core keeps a denied batch's run
in flight otherwise), and the session CONTINUES; the watchdog arms
only at a genuine (non-armed) EOF. The watchdog checks
`finish()`'s `teardownComplete` at fire time and disarms silently —
a teardown that completed within the 5 s bound is never
force-exited, and normal exit codes are preserved. PTY regression:
`mac04ApprovalDenyContinues` — approval → typed deny → the session
survives 6.5 s idle (> the old 5 s bound) → settle-then-exit → exit
0. Linux: green. **Open mechanism question (recorded, not papered
over): the EOF-at-approval variant (^D) is unreachable end-to-end —
replxx's ctrlD key binding is never invoked at the approval prompt
(the default send_eof bails instead); the binding-registration and
decode paths check out individually, so the bypass lives between
them.**

**2. Output-shutdown invariant — implemented with a bounded
barrier.** `TerminalOutputOwner.silence()` stops all captures;
`beginRestoreBarrier(timeoutMs:)` bounded-waits (500 ms) for the
writer to be between writes; the restore runs inside the barrier
when acquired. PROOF (the deterministic blocked-writer unit test):
an in-flight batch writes before the barrier; a batch queued once
quiesced never writes; post-silence emissions drop; nothing writes
after the barrier. **The barrier is bounded by necessity: on Darwin
the notification pipe is small and an in-flight `replxx_write`
blocks indefinitely once the unwind ends (observed natively: the
unbounded barrier version hung PTY-01's child in exit-limbo).
While blocked the writer cannot emit; the watchdog bounds the
process either way.** The corollary: on Darwin, when the barrier
times out, the exact termios restoration can be lost to the stuck
writer — CONFIRMED NATIVELY (the deny-continue subset's
`termiosRestoredExactly` failed while exit/survival passed). This
is the §17.3 tracked-open defect with its mechanism now
identified. Linux is unaffected (the 64 KiB pipe never blocks the
batch sizes in play); `mac03CtrlCUnderBackpressure` asserts clean
exit + exact restoration + a reaped child and passes on Linux.

**3. Runner isolation — the wedge is NOT a toolchain defect.**
Filtered single-test subsets at 37b5bbb on the Mac (release, fresh
build):
- PTY-01 alone: the chat CHILD enters exit-blocked limbo
  (`?NEs`, unsampleable) after the idle-Ctrl+C path; the driver
  waits; the runner waits on the test — the observed wedge.
- The deny-continue subset: the child exited cleanly and the
  RUNNER EXITED CLEANLY (the test failed on the exact-restoration
  assertion above).
- The PTY-08 subset: the tests failed fast; the runner exited
  cleanly.
A single child-spawning PTY test therefore completes normally when
its child exits, and wedges only when the child is exit-blocked —
the runner is a waiter, not the blocker. The wedge tracks the
PRODUCT's Darwin exit path (post-restore teardown) under suite
conditions; manual script-pty probes of the same idle-Ctrl+C
scenario exit cleanly, so the suite context (the runner's pty
environment) is a co-factor. Classification: product/environment
boundary, unresolved; the full-suite runs remain blocked by it.

**Verification per the acceptance order**: targeted Linux suites
first (ChatPTYTests 14/14, feasibility 11/11, owner unit suite
8/8 at the working tree), then ONE exact-head Linux gate: offline
gate + release smoke GREEN at 37b5bbb (43m13s). Focused macOS
verification: C1 idle-Ctrl+C ×2 and C2 Ctrl+D ×1 manual probes at
the final head — exit 0, prompt cycles, zero orphans; the isolation
subsets above.

**Verdict: HOLD.** Directives 1 and 2 are implemented with
regressions and Linux-qualified at the exact head. The Darwin
exit-limbo and the barrier-timeout exact-restoration loss remain
open and are now precisely characterized. No merge, no release,
no M5.

## 21. M4-MAC-04B round 2 — backpressure at source, accounting, evidence (HEAD 1e5bfa2)

**1. Notification-pipe backpressure — fixed at the source (the
registered patch process).**
- `patches/0002-darwin-terminal-transitions.patch` (terminal.cxx,
  extended): the wakeup pipe's write end is O_NONBLOCK and
  `notify_event` drops its token on EAGAIN. **Wakeup preservation**:
  EAGAIN ⟺ the pipe is full ⟺ ≥1 unread token is already pending ⟺
  the reader's next `wait_for_input` returns immediately; nothing is
  lost.
- `patches/0001-bracketed-paste-decode-lf.patch` (replxx_impl.cxx,
  second hunk — the one-patch-per-file rule folds the impl change
  into the existing impl patch): the **coalesced-wakeup drain** —
  the reader re-checks `_keyPresses` after draining messages on a
  MESSAGE wake. The explicit coalescing matrix: a dropped token of
  any type is covered because (a) pending tokens wake the reader
  immediately, (b) the MESSAGE branch now delivers keypresses too,
  (c) messages/keypresses/resizes are each re-checked or
  self-draining per wake; resizes repaint and continue into the
  same drain.
- `./dev vendor-check`: (R)+(F) both directions + the clone — OK.
  Registry updated.

**2. Failure path proven.**
- `mac04NotificationSaturationNonblocking`: a 262,144-message emit
  storm with no reader (4× the pipe's token capacity) completes in
  ~0.2 s — the pre-patch notifier deadlocked at capacity. The input
  thread's unwind and the termios-restore call paths run after the
  storm.
- `barrierTimesOutWithWedgedWriter`: the writer is wedged FOREVER
  (never released); the barrier times out (bounded), the restore
  proceeds, silence() keeps late emissions impossible. This is the
  timeout path, not the released-writer case.

**3. Watchdog completion accounting corrected.** finish() no longer
disarms; `ChatLoop.markTeardownComplete()` is called by
`ComposedSession.run` only after `httpClient.shutdown()` returns —
the watchdog now covers the whole cleanup and a hung NIO shutdown
is force-exited at the bound (was: disarmed before the cleanup
began).

**4. Ctrl+D-at-approval resolved — the real mechanism found.** The
documented "binding bypass" was NOT replxx's key decode: the test
child inherited the RUNNER's `TERM`. A dumb/unsupported TERM routes
replxx to `read_from_stdin` — its plain line reader with NO raw
mode, NO key bindings and NO decode — so a literal ^D became a
canonical-mode EOF and the product's binding never ran
(`tty::in` is a program-start static, which is why an in-process
probe cannot reproduce this). Fix: the PTY driver pins a real
`TERM` for the child (the PTY-08 matrix still overrides per leg);
PTY-08's legs remain the deliberate degrade-honesty coverage. New
regression `mac04ApprovalEOFContinues`: approval → ^D at the
decision prompt (the real raw path, binding fires) → deny + the
abandoned-run cancel → the session survives 6.5 s idle → settle-
then-exit → exit 0 + exact restoration + a reaped child. Green on
Linux.

**Verification**: local Linux — ChatPTYTests 15/15, feasibility
12/12, owner unit suite 9/9; ONE exact-head Linux gate + release
smoke GREEN at 1e5bfa2 (34m).

**Native (macOS 26.7.1 Intel, fresh 1e5bfa2 build): PTY-01 alone is
STILL NOT GREEN.** Repetition 1 of the directive's sequence wedged
identically to the pre-patch rounds: the chat child enters
exit-blocked limbo (`?NEs`, 25 min, unsampleable — no sample/lsof/
ptrace) on the idle-Ctrl+C path under the swift-testing runner
context; the manual script-pty probes of the same scenario at the
same head exit 0 cleanly (×2 this round, matching the earlier
rounds). The notification-pipe class is eliminated as the cause
(the patches + the saturation proof) and the barrier is bounded,
so the remaining exit-block lives elsewhere in the child's teardown
under the runner's process environment (the runner is a known
signal-masker — the shim already works around SIGUSR1). Per the
directive, no full matrix was run. The repeated-run and
concurrent-output native evidence could not be collected past the
first wedge.

**Verdict: HOLD.** Items 1–3 are implemented and Linux-qualified at
the exact head; item 4 is resolved mechanistically (the TERM pin)
with the regression green on Linux, but the isolated PTY-01 native
case remains exit-blocked under the swift-testing runner. The
specific blocker: the child's exit path hangs in an unsampleable
kernel state in the runner context only. No merge, no release,
no M5.

## 22. Review round 3 — notification correctness gaps (HEAD d76288f)

**Resize preservation (Codatiel finding 2) — fixed in 0002.** A
resize has no pending queue, so the SIGWINCH handler now sets the
sticky `nt_pending_resize` flag BEFORE notifying, and
`wait_for_input` consumes it before polling: a resize whose 'r'
token was dropped on EAGAIN is still delivered; the flag IS the
resize's pending state.

**EAGAIN telemetry (Codatiel findings 1–2 evidence) — added as
0003.** `replxx_notify_drops()` (declared in replxx.h by 0003,
implemented in terminal.cxx by 0002, exposed through the shim to
Swift as `LineEditorSession.notifyDrops`). vendor-check: all three
patches verify in both directions + clone.

**Genuine saturation test (Codatiel finding 1) — rebuilt.** The old
test never touched the pipe (print() with no active readLine writes
directly to stdout — confirmed). The replacement is
`NTReplxxSaturationProbe`, a child process running the vendored
editor on a REAL pty with an ACTIVE readLine reader (the raw path —
the helper pins TERM=xterm-256color, the same dumb-TERM trap as the
product child): a 200,000-message torrent plus an 80,000-ioctl
resize flood. Asserted: the writer stays responsive (exit within
bounds), the coalesced drain delivers the first and last messages,
the resize flood does not wedge the reader, and the unwind +
restoration complete. The drop counter is REPORTED — and the honest
finding is recorded: **actual EAGAIN is architecturally
unreachable**: message notifies serialize on the mutex the drainer
holds (one token per wake cycle) and SIGWINCH is kernel-coalesced
(one pending signal), so the wakeup pipe cannot reach token capacity
through any real notifier path; the nonblocking branch is
defense-in-depth. This also refines the original deadlock diagnosis:
the writer's block during an unwind contends on the reader's mutex /
the tty, not the pipe — which the quiesce + drop + bounded-barrier
design already handles.

**Barrier-timeout proof corrected (Codatiel finding 3).** The test
now releases the wedged writer AFTER the simulated restoration and
DETECTS late emissions: with the new per-line gate, exactly the one
in-flight line may follow the restore; queued lines, later batches
and post-silence emissions are asserted absent. The claimed
invariant is now the provable one: post-timeout, output is bounded
to the single in-flight line and nothing else.

**Stale-k token (the retained earlier finding)**: the attempted
KEY_PRESS skip was REVERTED — it spun without consuming a
tty-ready byte (22 CI test failures traced to it, root-caused, and
the rerun is green). The reader blocking on stdin behind a stale
token is its designed function (the input thread is supposed to
block in readLine); pending messages are delivered on the next wake.

**Native PTY-01 — still not green, and now precisely located.**
Three deterministic wedges at 75aa297 and one instrumented run at
d76288f with NB_TEARDOWN_TRACE breadcrumbs: the transcript ends at
the bracketed-paste enable + the prompt render; NO breadcrumb fires
— not the EOF path, not the Ctrl+C binding. **The child freezes
between the prompt render and the Ctrl+C binding, inside replxx's
wait/read path, without consuming the ready ^C byte — runner-context
only** (the manual script-pty probes of the identical scenario exit
0 at the same heads, repeatedly). Not the notification pipe, not the
watchdog, not the barrier, not the http shutdown — those are
excluded by the breadcrumbs. The next evidence step is a replxx-level
read-path trace (0002-gated) in the runner context, or host-level
toolchain remediation. Linux: ChatPTYTests 15/15, feasibility 13/13,
owner 9/9, ChatLoopTests 12/12; the exact-head gate + smoke green at
1e5bfa2/75aa297 (one 22-test CI flake root-caused to the reverted
stale-token hunk and re-run green).

**Verdict: HOLD.** The notification correctness gaps are closed with
honest evidence; the Darwin runner-context exit/read freeze remains
the single blocker to native PTY-01, now narrowed to a precise
location. No merge, no release, no M5.

## 23. Codatiel duplication-advisory reconciliation (review run 9c57650b, head a44f504)

The latest review's 21 reuse suggestions + 2 unassessed correctness
candidates consolidate into EIGHT distinct opportunities. Each has a
disposition; nothing is blanket-deferred.

**OP-1 — LineEditorSession replxx state-setting duplication**
(8 of the 21 suggestions; clearBuffer / replaceBuffer /
insertNewline / deleteForwardCharacter / dropLastHistoryEntry all
repeat the `withCString` → `ReplxxState` → `replxx_set_state`
sequence; `dropLastHistoryEntry` re-derives
`replxx_history_add` instead of calling `addHistoryEntry`).
Present at HEAD: yes. Risk: moderate maintenance (identical FFI
sequences can drift independently on a future edit); no behavioural
divergence today (the sequences are byte-identical).
**DEFER — post-M4.** The editor seam is under the frozen
input-path qualification; a mechanical consolidation is cosmetic
relative to the open native qualification. Tracked in the follow-up
issue (M4-FU-1, item 1).

**OP-2 — LineEditorSession callback Unmanaged-conversion repetition**
(the key/modify/completion handlers repeat the
`fromOpaque(userData).takeUnretainedValue()` decode; 6 supporting
pairs in the review). Present: yes. Risk: low (one-line idiom).
**DEFER — post-M4** (M4-FU-1, item 2): same frozen-seam reason;
a helper is a trivial mechanical follow-up.

**OP-3 — ChatPTYTests PTY fixture/lifecycle duplication** (12
suggestions: credential/env/driver/prompt bootstrap and the
clean-exit harness repeated across pty01/02/03/04/05/06/07/08, the
hygiene, parity and resubmit legs). Present: yes. Risk: low (suite
readability, not behaviour — every leg is green and asserts
independently). **DEFER — post-M4, and explicitly NOT during
qualification** per the standing directive (no PTY-fixture
refactoring while correctness qualification is open).
Tracked (M4-FU-1, item 3).

**OP-4 — Approval-flow test harness** (the deny / EOF-approval /
D2.7-hygiene legs share the workspace+loopback+warm-up+approval+
settle+restore+allowlist skeleton; 3 pairs). Present: yes. Risk:
low. **DEFER — post-M4** (M4-FU-1, item 4): same fixture-freeze
reason; the parameterized approval harness is the accepted shape.

**OP-5 — Feasibility probe-runner duplication** (the saturation and
stale-token legs share the spawn/read/complete/drain/status loop; 1
suggestion). Present: yes. Risk: low. **DEFER — post-M4**
(M4-FU-1, item 5): PTY-fixture exclusion applies.

**OP-6 — Input-path trace records decoded keystroke codes**
(Codatiel agent-001, unassessed correctness candidate; CONFIRMED by
inspection). `readc:decoded c=<hex>` and `dispatch c=<hex>`
reconstruct typed prompt text from captured diagnostics. Present at
a44f504: yes. Risk: real (privacy-class: the trace is env-gated and
off in production, but captured test/diagnostic transcripts would
carry reconstructable keystrokes).
**ACCEPT — fixed at 8162bf0-lineage HEAD (this round, pre-merge)**:
both trace sites narrowed to stage marks, errno and readiness state
(the directive's stated scope); the key payload is deliberately not
recorded. vendor-check re-verified both directions; the stale-token
regression re-run green.

**OP-7 — Synthetic-key strand claim (Codatiel agent-000)** —
**REJECT as a defect.** The stale-token path (a 'k' token whose
keypress was already serviced by the coalesced message-drain) ends
in the reader's designed blocking tty read: the input thread is
SUPPOSED to block in readLine, and the earlier token-skip fix for
exactly this shape spun on tty-ready events and broke 22 CI tests
(reverted, §22). The regression `mac04StaleKeypressTokenResumes`
asserts delivery resumes after a real keystroke and nothing wedges;
the "ordering not established" critique is addressed by the
union-outcome assertions (delivery + resumption + restoration hold
under either wake order).

**OP-8 — CI flake note (not a duplication item, recorded for
completeness)**: run 44955330764 failed 22 scripted-loop tests at
a44f504; the job logs were unretrievable (GitHub zip-cache error)
and the failure was not reproducible locally (ChatLoopTests 12/12).
A rerun was issued; the disposition (flake vs real) is pending the
rerun result and is tracked as an open verification item, not an
M4-FU engineering opportunity.

No production behavioural duplication was left undispositioned; the
repeated terminal-state operations were inspected for inconsistent
semantics (OP-1/OP-2 sequences are byte-identical FFI calls — no
divergence exists today). No qualification campaign was run for this
reconciliation; the only code change (OP-6) is covered by the
vendor-check, the stale-token regression and the existing suites.

**§23 addendum — CI status:** both a44f504 and a4fbc31 attempt-1 runs
failed the same scripted-loop cluster (20 tests, all
`waitFor(marker:…, timeout: 5)` timeouts in ChatLoopTests); attempt-2
reruns are GREEN for both (44955330764 and 45000857410), and the
cluster is not reproducible locally (ChatLoopTests 12/12). Pattern:
runner-load sensitivity of the 5-second scripted waitFors, not a code
regression — the identical suite set passes on the same commits on
retry. If it recurs a third time, widen the scripted waitFors as a
test-only change.

## 24. Narrow round — OP-6 landed, PTY-01 first-failing-operation established (HEAD 15025b3)

**1. OP-6 actually landed (33e3259).** The reconciliation round's
source edits were found uncommitted; both C++ trace sites are now
committed with the regenerated patches (vendor-check both directions
+ clone OK) and a baked proof: the stale-token regression runs with
NB_INPUT_TRACE=1 while "done" is typed through the pty and asserts
no `readc:decoded c=`, no `dispatch c=`, no hex fragment of the typed
word, and that the stage marks are present.

**2. PTY-01 first failing operation — established, then overtaken by
a deeper fact.** Instrumented run at d76288f lineage: the child
engaged raw mode, rendered the prompt, received the ^C on the master,
and froze **inside select(2) in wait_for_input** — no readiness, no
timeout, no EINTR — while the identical manual scenario at the same
head showed select-ready firing and the full chain completing. Fix
implemented (0002, registered): the bounded-select fallback — the
wait capped at 1 s, the timeout path performs one nonblocking peek of
the tty, a present byte is pushed back for read_unicode_character and
reported as KEY_PRESS, the fd restored blocking on every path.
Locally green: ChatPTYTests 15/15, feasibility 14/14, owner 9/9,
ChatLoopTests 12/12.

**Native acceptance NOT met.** On the Mac at 15025b3, three
consecutive PTY-01 attempts wedge, and a fully instrumented isolated
run shows the wedge is NONDETERMINISTIC and DEEPER than any product
operation: this run's child wedged **before rendering anything**, in
the `?NEs` exit-blocked state (kernel-held; unsampleable — sample,
lsof and ptrace all refused) — while a previous instrumented run
froze at the select after rendering. The product cannot be executing
code inside a kernel-held exit state; the child dies into that state
at variable lifecycle points under the swift-testing runner, and the
identical manual scenario exits cleanly at the same heads, repeatedly.
The bounded-select fix addresses the operation identified in the
earlier run and stands as correct; the remaining blocker is the
runner-context child exit-limbo itself. Excluded by evidence: the
notification pipe, the resize path, the watchdog, the barrier, the
http shutdown, and now the select wait.

**3. CI failure-list reconciliation corrected.** The §23 addendum
under-counted: the failed runs record 20–22 ISSUE records, not 20
tests — the failing tests are the scripted-loop legs of ChatLoopTests
(12 tests, some recording multiple issues); attempt-1 logs for both
runs are expired (GitHub zip-cache error), so the exact test list
cannot be re-enumerated. What is verified: attempt-2 reruns of both
44955330764 and 45000857410 are GREEN, and the cluster is not
reproducible locally. Classification upgraded from "harmless load
sensitivity" to **"rerun-green, root cause unproven"** — a third
occurrence triggers widening the scripted waitFors (test-only).

**Gate**: the Linux offline gate and smoke for 15025b3 are running
(push-triggered); every prior head in this lineage has a green gate.
A fresh external review of the corrected head, native qualification,
and the Sonar policy decisions remain the maintainer's sequence.

**Verdict: HOLD.** OP-6 landed and proven; PTY-01 instrumentation
delivered the first-failing-operation evidence and one fix, but the
native acceptance criterion (PTY-01 passing repeatedly) is not met —
the blocker is the runner-context kernel-held child exit-limbo, which
is beyond in-process correction. No merge, no release, no M5.

## 25. Launcher A/B — the wedge cause confirmed; the posix variant is not a drop-in (HEAD 2f7f4fc)

**The A/B (the directive's item 1) is DECISIVE.** Same commit, same
Swift Testing environment, same test:
- fork launcher (the original: setsid + TIOCSCTTY, session leader
  with a controlling pty): the runner wedges with ZERO test output —
  reproduced in the same session (4 "did not exit" context lines
  match the earlier signature).
- posix_spawn launcher (no setsid/TIOCSCTTY, own process group,
  default signal disposition/mask, stdio on the slave): PTY-01
  COMPLETED — in 0.276 s and 0.298 s across two runs: the child
  executed, the prompt rendered, Ctrl+C processed, exit 0, NO child
  hang, NO wedge.

**The launcher semantics are the wedge cause.** The fork launcher's
session-leader-with-controlling-pty children enter the kernel-held
exit limbo under the runner; removing the session/ctty relationship
removes the wedge.

**But the posix variant is NOT a drop-in (item 3's condition fails
on the other side).** With NB_TEARDOWN_TRACE/NB_INPUT_TRACE on, the
instrumented posix run shows: `exec-ok chat entry` (the post-exec
marker — item 2's discrimination works), then `[?2004h` + the prompt,
then the transcript ENDS: **zero input-path marks and zero teardown
breadcrumbs** — the child exited 0 in 0.276 s WITHOUT ever entering
the input-read dispatch (no select-enter, no decode, no dispatch, no
Ctrl+C processing) and WITHOUT restoring the termios (the oracle
fails). The ctty-less semantics break replxx's lifecycle differently:
the raw-mode session depends on the controlling-terminal relationship
in ways the pure posix_spawn variant does not provide, and the child
takes an early clean exit instead of running the loop.

**Item 3 resolution:** the bounded-select fallback was REMOVED
(0002 regenerated, vendor-check OK) — the launcher A/B proves the
select freeze was a symptom of the fork-launcher wedge, not an
independent read-path defect. The resize preservation, the drop
telemetry and the input-stage marks are retained.

**Item 5:** the stale-token regression now uses a CHILD-ONLY trace
env via nt_pty_spawn_env (the parent process env is never mutated
during concurrent suites) — Codatiel's test-isolation finding
corrected.

**The next candidate fix (not attempted this round):** the binary
self-acquiring the controlling terminal post-exec (ioctl(TIOCSCTTY)
on fd 0 when absent, product-side, one guarded call at chat startup)
— combining the posix launcher's non-wedging spawn with the session
semantics replxx requires. That is a product change requiring its own
qualification pass.

**Verdict: HOLD.** The wedge cause is confirmed and discriminated by
A/B; neither launcher currently satisfies the acceptance (fork:
kernel-held limbo; posix: early clean exit without the input
lifecycle or restoration). PTY-01 passing repeatedly on native macOS
remains the open blocker. No merge, no release, no M5.
