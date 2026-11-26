# M4-D Plan — Interactive Terminal Integration and Acceptance

Branch `m4-a` (local; no push/PR/merge without separate authorization).
Baselines: M4-A QUALIFIED, M4-B QUALIFIED (`3e9806f`, final battery `80cab63`),
M4-C QUALIFIED (code `6e73568`, receipt `c18fa54`).
Mission: M4-D — real CLI composition, PTY acceptance, lifecycle and closeout.
No M5 work, no live model traffic, no push/PR/merge.

Contract sources: COMPLETE-SPEC.md Part 10 M4-D (§M4-D, exit ¶),
§2.1–2.2 (composer/mention/key behavior, incl. ¶751-class paste rule,
`/preview @path` fallback), ¶805 (truncation marker), §§PTY-01…08 / TERM-01…04 /
UX / DX rows; `cases/catalog.json` (M4-due rows are `DEFERRED_BY_PLAN` —
development evidence only, not acceptance); `plans/m4-c-receipt.md` (handoff
inventory §§"Known limitations" + "M4-D prerequisites");
`plans/m4-b-receipt.md` (pure qualification, G14 gates); `plans/m4-plan.md`
(slice ordering, exit rule).

## D0 — acceptance map (this section)

### D0.1 Qualified source and dependency graph (confirmed)

- Production source: `Sources/NeedletailCore/`, `Sources/NeedletailRuntime/`
  unchanged since M4-B (`git diff 3e9806f..HEAD` empty — re-verify at
  every D-commit). M4-C added `Sources/NeedletailTerminal/` (11 files),
  `Sources/NeedletailCLI/ChatCommand.swift`, additive
  `NeedletailPresentation` cases (`StyleRole`, `InputAction.replaceDraft`
  + reducer case), `NeedletailLineEditor` seam extension
  (modify/key/bracketed-paste/preload/clear/insertNewline). No other
  production deltas permitted without plan amendment + re-review.
- Dependency graph: swift-markdown `0.9.0` exact (`25cb61d34820`) +
  swift-cmark `0.9.0` (`08ddb528923`) — only transitive cmark-gfm;
  `NeedletailPresentation` dependency-free; replxx vendored as `CReplxx`
  (no new package). Any new dependency needs a C0-class gate
  (resolve/build/link/size/Linux+macOS behavior) before selection.
- Test-only graph: `PTYShim` (C, forkpty-class spawn/read/write/signal/
  resize/wait/close + SIGUSR1 pipe), `NeedletailTypingProbe`
  (debug-only fixture binary, never shipped), scripted seams
  (`Tests/NeedletailActorTests/ScriptedSeams.swift`), real SSE loopback
  (`Tests/NeedletailProviderIntegrationTests/LoopbackFixtures.swift` +
  `LoopbackSSEServer`).

### D0.2 Preserved macOS findings (full mechanism — not abbreviated)

Finding 1 — macOS stdlib `String.contains` divergence on lone
invisibles. `String.contains` with a lone invisible scalar (Cf class)
returns FALSE on macOS Foundation even when the scalar is present;
Linux finds it. Multi-scalar patterns are unaffected. Consequence:
security oracles MUST assert at `unicodeScalars` level, via
`ScalarAsserts.hasScalar` (M4-C test helper). Fixed suite-wide in M4-C
(incl. hardening of three M4-B suites whose lone-Cf assertions were
vacuous on macOS). Any new D-work assertion about invisible/control
scalar presence MUST use scalar-level asserts; a `.contains`-based
oracle on a lone invisible is a review blocker.

Finding 2 — Darwin-debug stack exhaustion (G14 class) in the Markdown
visitor. The pre-guard recursive tree walk SIGBUS'd the mac debug
runner (signal 10, 512 KiB pool stacks — same mechanism as M4-A/B G14
crashes). Resolved by a depth guard (64) on block AND inline
recursion plus trimmed adversarial test depths for Darwin-debug
(120); no new debug-only gates. Any new recursive display walk MUST
carry an explicit depth bound; any new adversarial-depth test MUST
keep Darwin-debug depths trimmable without weakening the Linux
assertion.

Pre-existing environment failure (NOT product): mac
`TerminalFeasibilityTests` PTY-05 `canonicalEchoRestored` fails over
ssh-session PTY environments and fails identically on the untouched
B6 tree `~/m4b`. For D3, a NEW physical release-binary failure may
NOT be waived by this old debug-only flake — clean-baseline
comparison is required (same host, same session class, B6-tree or
current-tree debug probe as control).

### D0.3 M4-C handoff triage (incomplete wiring vs tested)

TESTED (pure/unit, M4-B/C — D-work reuses, does not rebuild):
queue/submit/followUp/steer/edit/reorder/withdraw/resume/cancel/fork
intents; approval request views + exec identities; undo preview with
real preimages (`previewUndo` + `reconcileChangeGroups`); session/
agent/model/context/epoch views + `InspectionResult` payloads; diff
rendering + provenance; compact dry-run (no provider call); mention
grammar/candidates/preview-sanitize; completed-block Markdown render;
sanitizer battery; owner bounds; tap decorator; confirm protocol;
completion revision gate; hostile-candidate filter; headless `run`
+ JSONL contract.

INCOMPLETE WIRING (D2 must close — each maps to §D2 items):
1. `@` attach: tokens display-respected only; `AttachmentCaptureService`
   (`Sources/NeedletailRuntime/AttachmentCapture.swift`) +
   `AttachmentValidator` never called from chat; submission carries no
   attachment records; stale/missing-file paths untested end to end.
2. Undo RUN: `SessionActor.runUndo` exists; chat posts a "stays
   headless" notice instead of executing with Core approval +
   verification display.
3. Bare `/undo`: no latest-eligible-group resolution.
4. Inspect legs beyond queue: sessions/agents/models/context/epochs/
   compact/diff/rewind views exist pure but chat answers "not yet
   wired" for all but queue.
5. `/preview @path` fallback (§2.2 keyboard/dumb-terminal path):
   deferred; `previewFile` edge exists but unbound to a command.
6. `/compact`: the ONLY catalog case is UX-NAV-05
   (`/compact --dry-run` then cancel) — already pure-qualified
   and wired as a chat inspect view in D2.3. A real epoch-
   replacement TRIGGER has no catalog case and no qualified
   authority (no actor path, no Core record); building one is new
   architecture, out of scope. Recorded as an explicit NON-CASE
   deferral (product gap, not acceptance debt): dry-run + cancel
   fully covered, trigger explicitly not built.
7. Tool display: receipts/hunks renderers (`DiffRenderer.receipt`)
   await tool-display wiring into scrollback (start/progress/result/
   denial/unknown).
8. Key bindings: behavioral tests missing (Ctrl+C busy/idle/empty,
   Ctrl+J newline, Esc dismiss, Tab-accept exactness incl. Enter path,
   `/keys` discoverability).
9. Completion: explicit completion, budget-boundary, failure and
   held-state presentation; interactive request-budget visibility
   (`LiveRequestBudget` + `budgetReportLine` exist, unused by chat)
   and truthful exhaustion behavior (chat currently unbounded).
10. History hygiene: decision/confirm lines may enter replxx history.
11. `/rewind` + epoch inspection: intent exists (`requestLineageFork`
    wired); rewind confirmation/divergence display + epoch prefill
    visibility not exercised through chat.

No new grant engine, approval classifier, command scheduler, or
filesystem abstraction may be built to close these: every item above
resolves to calls into the already-qualified authorities
(`SessionActor`, `AttachmentCaptureService`, `GitDiff`,
`LiveRequestBudget`, store reconcile) plus rendering through the
single owner.

### D0.5 Permitted production deltas (reviewer caveat closure)

D0.5 permits: `Sources/NeedletailCLI/ChatCommand.swift`
(composition factory extraction + translate legs),
`Sources/NeedletailTerminal/*` (wiring/width), ADDITIVE
`NeedletailPresentation` cases with pure tests, and ADDITIVE
`NeedletailLineEditor` seam functions only (history snapshot/
drop-tail via the existing C `replxx_history_scan/clear/add`
API — the M4-C seam-extension precedent; no behavior change to
existing seam functions). Any other production file touched
(incl. new files outside `NeedletailTerminal/`) requires plan
amendment + re-review.
`Core`/`Runtime` stay byte-identical to `3e9806f` (verified per
commit); a needed Core/Runtime change is a plan blocker, not a
drive-by edit.

### D0.4 Case → executable-test map

Conventions: `L` = Linux x86_64, `M` = qualified Intel macOS host
(§D5). `dbg`/`-O` reported separately. PTY tests drive the ACTUAL
binary under a `PTYShim`-class PTY (extended harness, §D3); loopback
provider = test-owned local HTTP SSE server + temp config + temp
`NEEDLETAIL_STATE_DIR` — the release binary is NEVER modified for
tests (composition-root fidelity). Every PTY/case runner verifies
EXPECTED NONZERO test counts (a zero-test pass is FAIL, per B6
precedent); failure transcripts are preserved under
`.needletail-dev/m4d-*`.

| Case | Due evidence (spec) | Executable test (new unless noted) | Platform |
|---|---|---|---|
| PTY-01 | open/close editor, Ctrl+C, clean restore | `ChatPTYTests.testPTY01_openCancelExitRestores` — spawn release `chat` (loopback), assert prompt; busy Ctrl+C cancels; idle-nonempty Ctrl+C clears; idle-empty with zero queued/unsent work EXITS 0 (spec §2.1 ¶746 — this CHANGES the M4-C idle-empty hint, authorized in D2.5 with exact tests); idle-empty with queued/unsent work asks; termios/bracketed-paste echo functional check post-exit | L dbg/-O, M -O (+M dbg report) |
| PTY-02 | multiline paste while streaming, exact-once submit | `testPTY02_pasteDuringStreamSubmitsOnce` — bracketed paste of multiline+shell-looking text during synthetic stream; exact-bytes submit oracle; no execution during paste | L dbg/-O, M -O |
| PTY-03 | `@` candidates + bounded preview during output | `testPTY03_completionDuringOutput` — type `@`, assert candidate popup + 8-line/4-KiB preview intact during streamed tool output; no ghost cursor/interleaved escapes; Tab-accept exactness oracle | L dbg/-O, M -O |
| PTY-04 | queue during 100s streamed chunks; interrupt | `testPTY04_queueInterruptNoLostDraft` — 100-chunk deterministic stream, mid-stream follow-up + Ctrl+C; held queue visible, no auto-send, draft intact | L dbg/-O, M -O |
| PTY-05 | TIOCSWINSZ 40→120→80, cursor in multiline composer | `testPTY05_realResizeRedraw` — release binary (NOT probe): exact 40→120→80 + redraw/cursor oracle via the test-only VT projection (§D3.1: cursor-address + prompt-row assertions, not ANSI substrings); compare against B6-tree debug-probe control on same host/session class | L dbg/-O, M -O |
| PTY-06 | hostile OSC/title/cursor/control stream | `testPTY06_hostileStreamCannotControlTerminal` — loopback emits OSC title + cursor-motion + C0/C1/Cf battery; oracles: (a) untrusted bytes never appear unsanitized in the transcript, (b) every ESC byte in the transcript belongs to the owner/replxx allowlist (SGR `m`, cursor `G/H/f`, `ED/EL`, bracketed-paste markers — `VTAllowlist` scanner), (c) the test-only `VTProjection` OSC 0/2 title model still equals baseline after the hostile stream | L dbg/-O, M -O |
| PTY-07 | catchable SIGTERM/EOF vs SIGKILL; recovery | `testPTY07_catchableExitRestoresAndRecovers` — SIGTERM/EOF: modes restored, owned children cleaned, durable session reopens via `run`/reconcile; SIGKILL: no in-process cleanup claimed; exercised recovery = `reset`/`stty sane` in a FRESH shell + usable-shell check + session reopen, documented as the external-reset procedure | L dbg/-O, M -O |
| PTY-08 | tmux/SSH-like TERM + plain fallback | `testPTY08_termModesAndRealSSH` — matrix NO_COLOR/TERM=dumb/non-TTY/narrow (simulated) + ONE separately-labelled REAL path: `ssh` to the mac host driving `tmux` + release binary (label REAL-SSH). If the mac real path is unreachable, fallback = Linux `tmux` real-path + mac simulated-TERM, the row marked PARTIAL with the exact label of what ran where (never silently promoted) | L dbg, M -O real-path |
| TERM-01 | bracketed paste newlines + shell text | covered by PTY-02 + `ComposerBridgeTests` paste-literal pins (existing) | L dbg (exist), PTY L/M |
| TERM-02 | unicode/resize/long-line/SSH/tmux | covered by PTY-05/PTY-08 + existing wrap tests | L dbg (exist), PTY L/M |
| TERM-03 | Ctrl+C input/provider/exec | covered by PTY-01/PTY-04 + `ChatLoopTests` cancel pins (existing) | L dbg (exist), PTY L/M |
| TERM-04 | non-TTY/dumb | existing `TerminalCapsTests` + new `chat --help`/refusal + non-TTY loopback run of release binary asserting plain output, zero ANSI | L dbg/-O, M -O |
| UX-QUEUE-01…05,07,12 (physical variants) | stream/interrupt interleavings | PTY-04 + loopback composition tests `ChatCompositionTests` (scripted SSE: 500-chunk stream, busy-Enter, steer-at-boundary, FIFO, edit/withdraw, cancel-hold, failure-held) | L dbg/-O |
| UX-QUEUE-06/08/09/10/11 | crash/stale/caps/epoch/sealed | existing B6 actor/integration (no re-proof) + chat-surface spots: caps-refuse notice (`ChatCompositionTests.testQueueCapsRefuseNotice`), stale-head hold notice, and the QUEUE-11 analog — sandbox-policy row display-only with zero human-approval path (`testSandboxApprovalDisplayOnly`, since chat is never sealed) | L dbg (exist) + new chat-surface |
| UX-MENTION-01…08 (interactive legs) | live completion/preview/accept | PTY-03 + `ChatCompositionTests` (revision race, 100K catalogue caps, preview sanitize, binary/symlink/denied/missing, range validation) | L dbg/-O, PTY L/M |
| UX-MENTION-09…12 (attach lifecycle) | snapshot/stale/sealed/route-change | D2 wiring + `ChatAttachTests` (capture/stale-hold/sealed-refuse/re-consent via `AttachmentCaptureService` + actor; zero provider requests on cancel) | L dbg/-O |
| UX-UNDO-01…05,07,10/11 | preview/conflict/partial/compacted/unstored/inode | existing pure/native (no re-proof) + chat-surface: preview render + conflict display via loopback | L dbg (exist) |
| UX-UNDO-06/08/09 (interactive legs) | exec-ledger honesty, rewind fork, duplicate-run safety | D2 `runUndo` wiring + `ChatUndoTests`: exec-touched refusal display; rewind with a DIRTY worktree → lineage fork, worktree files byte-identical, divergence warning rendered; INTERRUPTED reversal → idempotent-safe error/reconciliation display, no second destructive inverse (actor-level cancel-mid-inverse + chat-surface notice) | L dbg/-O |
| BDD-07 | golden regenerated from production in same run | `GoldenRegenerationProbe` (BDD-06 pattern): regenerate a golden copy from current production output with one expectation deliberately corrupted; assert the manifest/case-reconcile gate REJECTS it; restore. Proves independently-reviewed expectations, not auto-pass | L dbg |
| PORT-06 | macOS patch regresses Linux case | Process gate with receipt evidence: full Linux offline gate re-run green at EVERY D-commit (no macOS-pass override); any macOS-shim production edit re-runs Linux first. Recorded per commit in the receipt | L per-commit |
| UX-NAV-01…07 | inspect legs through chat | D2 inspect wiring + `ChatInspectTests` per leg (agents/sessions/models/context/epochs/compact-diff/diff) incl. NAV-02 consult child, NAV-04 UNKNOWN cache, NAV-05 no-provider-call | L dbg/-O |
| UX-RENDER-01…04,06…08 | render parity interactive | existing pure (100/100) + PTY-disagreement guard: `ChatRenderParityTests` (same completed text → identical spans PTY vs pipe; DX-09 gate) | L dbg/-O, PTY L |
| UX-RENDER-05 | combining/emoji widths 40/80/120 | D4 wcwidth qualification: measure real cell widths; fix layout if incorrect (M4-C limitation closure) — `ChatWidthTests` + PTY-05 dependency | L dbg/-O, M -O |
| DX-09 | frame vs PTY disagree → interactive fails | parity tests above are FAIL-closed (unit-only pass insufficient) | L |
| DX-10 | stress seeds, no sleeps | D4 deterministic adversarial interleavings (seeded, barrier-sync, no sleeps) | L dbg/-O |
| DX-01…08 | replay/determinism/loopback/offline | existing (no re-proof); loopback SSE reuse for composition tests | L (exist) |
| STATE-01…06 | stale/cancel/delivery/budget/cleanup | D4 stress + PTY-07 (STATE-06 external-reset boundary documented) | L dbg/-O |

Deferred with explicit mapping (NOT silently dropped): none of the
above is waived. M4-C `/preview`-as-file-command, latest-eligible
`/undo`, Tab-Enter-accept exactness, budget exhaustion, history
hygiene are all owned above; the `/compact` TRIGGER is the single
explicit non-case deferral (no catalog case, no qualified
authority — D0.3 item 6). Anything else found unclosable during
D2 gets a case-mapped deferral entry in the receipt with the
exact case ID and the pure-leg evidence that stands.

## D1 — real CLI composition

1.1 Loopback provider fixture (test-owned, no binary change):
extend the M1-C `LoopbackSSEServer` pattern to a deterministic
`ChatLoopbackServer` script language: text deltas (chunk-split
controlled), `tool_calls` proposals, finish reasons, error/usage
frames, plus `gate:<name>` hold points (server withholds subsequent
chunks until the test hits a release endpoint — the mid-stream
injection barrier for PTY-02/03/04, §D3.1; no sleeps). Temp config
profile pointing at `http://127.0.0.1:<port>` with a dummy bearer
credential in a temp env-file. The loopback server ASSERTS the
expected dummy `Authorization` header on every request — proving
config/profile/`EnvFileCredentialStore` composition through the
real path. Residual risk stated in the receipt: TLS/redirect/
live-auth negotiation remain covered only by existing provider
tests, never by loopback. Per-test ephemeral ports + temp
`NEEDLETAIL_STATE_DIR`; PTY suites serialized. Temp
`NEEDLETAIL_STATE_DIR` per test. Chat runs with `--workspace`
temp dir (native executor, real tool receipts) for tool-display
legs, and without roots (scripted backend) for pure-stream legs.

1.2 Composition root sharing (anti-skew invariant): D2
requires editing `ChatCommand.executeStatic`; to keep tests on the
REAL composition, extract the post-gate composition
(config/store/gates/executor/transport/gateway/loop/sink wiring)
into a shared factory (e.g. `ChatSession.compose`) that BOTH the
`chat` command and the tests call. The test-injected seam is the
`ModelTransport` (loopback vs production
`ChatCompletionsTransport`); the executor backend is config-
selected exactly as in production (composition smokes run BOTH
the scripted/no-roots and native/`--workspace` backends —
whichever the binary would select for the same argv); every other
element is identical by construction. Review must verify the
factory is actually shared (not a parallel reimplementation). D1 composition tests
(`Tests/NeedletailTerminalTests/ChatCompositionTests.swift`,
Linux dbg/-O) call the factory with loopback transport and prove:
submit → streaming deltas render incrementally; tool proposal →
approval prompt with exact identities → `y` approves → receipt
renders; second instruction while busy queues (not sent);
Ctrl+C-equivalent cancel holds queue; EOF exits cleanly;
transcript/store reconcile clean. D3 additionally runs ≥1
release-binary smoke per D2-closed surface (attach, undo-run,
inspect, budget, tool display) so composition-root divergence in
D2 surfaces is caught against the shipped product, not only the
factory.

1.3 Single-owner audit: static + runtime proof that every display
byte in chat flows through the one `TerminalOutputOwner` (no direct
`lineEditor.emit`/stdout writes on the chat path — extend the
import-gate pattern if a new file risks it).

## D2 — close user-facing wiring (in `ChatCommand.translate` + loop)

For each: call the qualified authority, render the qualified view
through the owner, add executable tests (§D0.4), keep deterministic
authz/ledger semantics. Displayed undo NEVER performs filesystem
reversal without `actor.runUndo` (Core approval + verification);
cancel/deny paths fail closed with explicit notices.
1. Attach: `@` token → `AttachmentCaptureService.capture` at
   submit/enqueue (fd-pinned, hash, range, manifest); preview via
   existing candidate previews + `/preview @path`; cancel/withdraw →
   zero provider requests, no epoch mutation; stale → `stale @file`
   hold + reselect; sealed → typed refusal; route-switch → hold +
   re-consent. Candidates honor gitignore/exclusions (reuse
   resolver rules; symlink-out-of-root refused).
2. Undo: bare `/undo` resolves latest eligible group (or reports
   none); `/undo <group>` previews (existing) then Y/N runs
   `actor.runUndo` and renders outcome + truthful paths/hashes
   notice (STATE-05: append notice BEFORE next request).
3. Inspect: wire sessions/agents/models/context/epochs/compact/
   diff/rewind result payloads already produced by
   `InspectionResult`; `/diff` via `GitDiff` bounded hunks;
   `/rewind` confirms fork (no file mutation) + divergence.
4. Tool display: start/progress/result/denial/unknown rows into
   scrollback via tone roles + `DiffRenderer.receipt` for hunks.
5. Keys/submission: behavioral tests for the §2.1 map —
   busy Ctrl+C cancels+holds; idle-nonempty Ctrl+C clears;
   idle-empty with zero queued/unsent work EXITS 0 (aligns the
   M4-C hint to spec ¶746 — the authorized behavior change);
   idle-empty with queued/unsent work asks (or exits only after
   explicit discard); Ctrl+J newline; Esc dismisses popup first;
   Tab/Enter accept exactness; `/keys` + `/help` discoverability;
   paste never executes slash commands (existing pin + PTY-02).
6. States: explicit completion / budget-boundary / failure /
   held rows. Budget semantics (CHOSEN, durable-same-as-headless):
   chat uses the IDENTICAL mechanism — same state-dir counter
   file (`run-request-budget.json`), same `LiveRequestBudget.limit`
   selection from `NEEDLETAIL_REQUEST_BUDGET`, same pre-send
   `consume` discipline (fail-closed `exhausted`/
   `counterUnreadable`, no provider byte sent). Enforcement point:
   a `BudgetEnforcingTransport` wrapper at the CLI composition
   (new struct in the permitted `ChatCommand.swift` edit — NOT in
   Runtime/Core, which stay frozen). On exhaustion the loop
   REFUSES new submits with an explicit notice and HOLDS the
   queue (no auto-send, no silent continue). Exhaustion is STICKY
   per state dir across invocations (identical to headless —
   "re-running can never reset it"); operator recourse is a fresh
   state dir (documented, same as headless) or withdraw/export of
   queued items — a budget-held queue NEVER auto-resumes in the
   same state dir. A visible budget line (`budgetReportLine`)
   renders in status output; unset budget = unbounded with a
   startup notice. Tests: consume-to-exhaustion via loopback
   (refusal + held queue + notice), cross-invocation stickiness
   (shared state dir across two sessions — D1.1's per-test temp
   dirs do NOT mask this because this test explicitly shares),
   unset-budget notice, held-queue recovery procedure.
   `/queue` shows budget/hold state.
7. History hygiene: REQUIREMENT (no documentation opt-out) —
   confirm/decision lines (the `y`/`yes` line and any line typed
   while confirm is armed) MUST NOT persist in replxx history.
   Mechanism (implementable in the permitted additive seam —
   the C API already exposes `replxx_history_scan/clear/add`,
   `LineEditorSession` just doesn't forward them): after the
   armed line is consumed, snapshot history via scan, REQUIRE the
   tail to equal the decision line (fail the hygiene check if
   absent — the test asserts tail presence first, so it cannot
   pass vacuously; replxx auto-commits accepted lines), clear,
   re-add the prefix (O(history) on confirm only — rare and
   bounded). Test asserts post-confirm history contents lack the
   decision line.
   Confirm-armed bracketed paste (M4-C handoff, receipt
   "confirm disables neither history nor bracketed paste"):
   `testConfirmArmedPasteNoAutoConfirm` — paste multi-line text
   while confirm is armed → no submit, no confirm, draft
   preserved, decision still required, then `y` approves.

## D3 — physical PTY qualification

3.1 Harness: extend `ProbeProcess`/`TranscriptCursor` into a
`ChatPTYDriver` (spawn argv-configurable: release `needletail chat`
with env + args; same expect/send/signal/resize/waitExit/exit-
status-decode semantics; 15 s-class deadlines; FULL transcript
preserved to `.needletail-dev/m4d-pty/<case>.log` on ANY failure).
Mid-stream injection uses loopback `gate:<name>` hold points
(§D1.1): the test waits for the pre-gate chunk marker, injects
keystrokes/paste/completions, then releases — provably
during-stream, no sleeps. Deterministic loopback scripts only
(assert on markers/prompts/echo reports, never on chunk arrival
counts). Cursor-layout assertions use a small TEST-ONLY VT screen
projection (`VTProjection` helper: tracks cursor row/col over
CUP/CUU/CUD/CUF/CUB/ED/EL + SGR passthrough + an OSC 0/2 title
model — spec ¶871/1134 sanction; bounded, no production
rendering, no new dependency). `VTProjection` is itself
unit-tested over a fixture corpus (cursor moves, erases, SGR,
OSC title set, wrap); its unsupported-sequence policy is
ignore-AND-record (`sawUnsupported` flag) — PTY-05 AND PTY-06
fail if the flag is set (both consume the projection), so their
oracles can never silently misproject.
An ANSI substring alone never proves draft/cursor state (§1134:
output-byte vs screen-state correctness distinguished).
New target file `Tests/NeedletailTerminalTests/
ChatPTYTests.swift` (Linux-first; mac-gated only where G14-class
stack risk is demonstrated, never pre-emptively).

3.2 Release binary under test: `.build/release/needletail`
(Linux `-O`; mac `-O` Intel). Debug binary additionally on Linux
(debug/release reported separately). PTY-01…08 per §D0.4; TERM-04
non-TTY leg runs the release binary with stdin/stdout pipes.

3.3 Count verification: a `run-m4d-pty.sh`-class runner (B6
`run-b6final.sh` precedent) asserts every required suite/case
executed its expected nonzero count; zero-test pass = FAIL.

3.4 Clean-baseline comparison (PTY-05/mac + any new flake):
same-host, same-session-class control run (debug probe or B6 tree)
recorded alongside; a new physical release failure is NEVER waived
by the old debug flake.

## D4 — lifecycle and output-owner stress

4.1 Concurrency fuzz (`ChatStressTests`, seeded, barrier-sync, no
sleeps): model deltas × tool receipts × approval prompts × editor
redraws in adversarial interleavings; oracles: single-writer
invariant (all bytes via owner), no lost input, no unexpected
effect, allowed-outcome determinism (DX-06/DX-10).
4.2 Backpressure: adversarial volume (gigabyte-equivalent
synthetic, UX-RENDER-07 physical leg) — bounded memory/queue,
control-lane responsiveness (STATE-04), no starvation; tap 1 MiB +
owner quotas hold.
4.3 Cancellation: late-callback discipline — callbacks after
destroy/interrupt/revision NEVER redraw dead editor, revive runs,
or submit stale input (existing generation/request gates +
targeted new tests for the chat edge: confirm-box late resume,
tap-complete after cancel, completion after revision bump).
4.4 History integrity: three SEPARATE invariants (never one
equality): (i) raw tool/model bytes == stored bytes (byte-exact);
(ii) displayed projection == sanitize(raw) (sanitizer is a pure
function of the stored bytes); (iii) no render/truncation/preview
path ever mutates the store. End-to-end loopback test asserts all
three independently.
4.5 Cleanup: termios/bracketed-paste/owned-children restore on all
catchable paths (exit, Ctrl+C-empty, EOF, SIGTERM, SIGHUP);
document SIGKILL/external-reset boundary (STATE-06) with the
recovery procedure actually exercised.
4.6 Width: FAIL-CLOSED qualification of combining marks/emoji/
ZWJ/real cell widths (UX-RENDER-05): `ChatWidthTests` fixtures
(CJK wide, emoji presentation, ZWJ sequences, combining marks) at
40/80/120 with EXPLICIT expected-cell assertions per fixture.
ANY mismatch forces a local wcwidth-class measurement
implementation (table in `NeedletailTerminal`, no new package);
the row stays open until fixtures pass. Re-run PTY-05 + RENDER-05
as the closure gate.

## D5 — platform and release-binary gates

- Linux x86_64: debug + release acceptance (composition, PTY,
  stress, regressions). Full `./dev test offline` green at close.
- Intel macOS (Builds-Mac-Pro.local): NATIVE release acceptance
  (PTY-01…08 release, composition smoke incl. tool call + visible
  result, width, SSH/tmux real-path). FIRST attempt mac-local
  tmux-driven runs (tmux allocates its own pty on the host, which
  may avoid the ssh-session `canonicalEchoRestored` environment
  failure); every mac PTY row carries its same-host,
  same-session-class control comparison. If the environment
  failure reproduces on the control, the affected row is marked
  PARTIAL with the exact label (ssh-session limitation, local-
  terminal qualification deferred) — a new physical release
  failure is NEVER waived by the old debug flake. Debug results
  reported separately with G14 limits. NO Apple Silicon claim (M4-A
  boundary stands).
- Regressions: existing Linux core/checkpoint/storage/execution/
  security suites green; headless `run` contract byte-identical
  (JSONL fixtures re-run).
- Real SSH/tmux path: ≥1 actual `ssh` (mac host, loopback-bound)
  + `tmux` session driving the release binary; labelled
  REAL-SSH vs simulated-TERM; transcript preserved.
- Release-binary proof: every PTY case that "requires it" (all
  PTY-01…08 per mission) runs the release product; debug binary
  only where the matrix says so.

## D6 — human usability smoke

Operator-driven session on the qualified terminal environment
(Linux release binary + loopback provider with a scripted
multi-turn tool task; mac release if reachable): launch → task →
streaming + tool activity → diff/context inspect → approval
respond → follow-up queue → interrupt → clean exit → durable
session reopen/inspect. Record each step PASS/awkward-FAIL with
the exact defect; fix genuine integration problems in D2/D4
scope; anything deferred gets a case-mapped receipt entry.

## D7 — review and closeout

- One focused DeepSeek plan review of THIS plan before
  substantial implementation (blockers only; rebroadcast if the
  plan changes materially).
- Focused DeepSeek code reviews of each substantive change batch
  (D1/D2 wiring, D3/D4 harness+stress, platform deltas); verdicts
  recorded with dispositions in the receipt.
- `plans/m4-d-receipt.md`: exact code HEAD/tree/dependency
  identities; M4-A/B/C retained qualifications; PTY-01…08
  executable evidence per platform (debug vs release split);
  release-binary composition proof; UX/DX/TERM reconciliation;
  security/hostile-terminal tests; regressions; known limits +
  explicit case-mapped deferrals; review dispositions; remaining
  usability issues.
- Aggregate M4 milestone report (A+B+C+D retained + D evidence).
- As-built delta log (incl. the M4-C idle-empty Ctrl+C hint→exit
  alignment authorized in D2.5, recorded here as an M4-C as-built
  delta, not just a D2 authorization).
- Verdict READY / PARTIAL / BLOCKED; STOP (no M5, no push/PR/merge).

## Guardrails (binding)

Pure-before-terminal order stands; no new agent framework,
scheduler, memory/indexer, MCP catalogue, approval engine/classifier,
or filesystem abstraction. No live model traffic (loopback only).
No benchmark claims. Settled M4-A/B/C decisions are not reopened
without a demonstrated defect + review. BDD-04/05: skipped tiers
stay visible; no evidence-layer promotion. REV-01…08 honored.
