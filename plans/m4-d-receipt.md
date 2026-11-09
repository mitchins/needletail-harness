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
- M4-D work HEAD: `c18fa54` + uncommitted working tree (this receipt
  describes the tree, not a commit; STOP rule — no commit/push).
  Closeout fingerprint: 18 tracked-modified + 11 untracked paths;
  `git diff` sha256
  `26e842ebb6662b5e54c81c57a37318c878500f0ded2575efcc5367ddc56794bb`.
  Untracked: 7 terminal-test files + `run-m4d-pty.sh` +
  `plans/m4-d-plan.md` + this receipt + `plans/m4-report.md`.
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
New finding from smoke preparation (integration-relevant, kept):
resubmitting a byte-identical completed line reuses the command ID
and the actor replays the prior admission WITHOUT dispatching
(Core `admittedCommands` idempotency, qualified M4-B). Up-arrow
recall PROVES the draft returns; Enter on the identical text is a
silent no-op by that qualified semantic — recorded as a known
limitation, not changed (Core change = plan blocker).

## 9. Known limitations and explicit deferrals

1. macOS evidence: none (environment-blocked, §5).
2. D4 named suites unbuilt: `ChatStressTests` (seeded fuzz),
   `ChatWidthTests` (wcwidth fixtures), `ChatRenderParityTests`
   (dedicated parity file — parity enforced per PTY leg instead),
   `ChatAttachTests`/`ChatUndoTests`/`ChatInspectTests` (behaviors
   covered in `ChatCompositionTests`, not as named files),
   `GoldenRegenerationProbe` (BDD-07). D4.2 backpressure and D4.4
   full history-integrity triple are open rows.
3. `/compact` trigger: explicit non-case (plan D0.3.6).
4. Resubmit-identical-text silent no-op (§8 finding; qualified
   Core semantic).
5. Stale-Tab ignore requires re-tab (no flicker, no clobber; the
   divergence reconcile covers buffer/state convergence).
6. TERM-04 as-built delta (§3 table).
7. Provider-integration parallel flake (§5; at-HEAD result in §6).
8. `dev vendor-check` secondary clone check reports the single
   documented replxx patch (primary manifest check passes).

## 10. Verdict: M4 PARTIAL — STOP

Linux M4-D evidence is complete and green (PTY-01…08 on the
release product, 126-test terminal suite, composition, smoke,
regressions, two adversarial review rounds closed). PARTIAL
because: (a) macOS acceptance is missing (environment, not
product); (b) D4 named stress/width/parity/probe suites are
unbuilt (behaviors partially covered, rows open); (c) BDD-07
probe unbuilt. No M5, no live traffic, no push/PR/merge.
