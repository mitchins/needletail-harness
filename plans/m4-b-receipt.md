# M4-B Receipt — pure presentation and interaction contract

Branch `m4-a` (local-only; no push/PR/merge without authorization).
Baselines: M4-A qualified code `32d2226` (receipt `29af6f0`), boundary
`plans/m4-a-boundary.md`, plan `plans/m4-b-plan.md` (DeepSeek READY,
re-review READY).

## B0 — contract mapping (DeepSeek READY ×2)

- Boundary record `plans/m4-a-boundary.md`: M4-A PASSED (Intel),
  G13/G14 preserved, arm64 explicitly not qualified, Linux gate
  preserved, no M4-A investigation without demonstrated defect.
- Plan `plans/m4-b-plan.md`: 36 M4-due pure cases, B1…B6 slices,
  ownership table, R1 reorder design constraint, B/C/D boundaries,
  §8 B6 (11 deferred integration/native legs), §9 six headless
  capabilities with oracles. Reviews: initial NEEDS-CHANGES (3
  blocking + 3 major + minors, all addressed), delta re-review READY.

## B1 — composer, mentions, attachments (DeepSeek READY ×2)

- `MentionGrammar.swift` (new): `@` boundary grammar (start /
  Unicode whitespace / allowed punctuation; emails/escapes/paste
  literal), `parseMentionRange`, `sanitizePreview` (terminalSafe,
  8-line/4-KiB caps), `mentionPathQuery` (fetch key strips `#L`).
- Reducer derives/dismisses suggestions per keystroke (paste
  suppresses; submit clears suggestion+tokens), emits
  `requestCompletions` on path change only; selection clamp;
  whole-span accept with structured `MentionToken`; range errors
  visible; attach is intent-only (`attachFile` effect).
- Render: selected role follows `selectedIndex`; range-error line.
- Tests: 16 UX-MENTION RED→GREEN; permutation harness evolved
  (fetch-only typing, full no-change stale assertion, `@m`
  alphabet, liveness fix); golden `mention-popup.json` + manifest
  `m4-b-b1`; BDD-06 boundary probe (`plans/m4-b-b1-probe-boundary.log`).
- Review: NEEDS-CHANGES (5 findings, all fixed) → delta confirm
  READY. Fixes: path/range split, whole-span accept + cursor,
  widened boundary per spec §2.2, honest test scope, exclusion
  discrimination (empirically verified), range-retention pin.
- Linux `quick` green (exit 0) at commit.

## B2 — queue, interruption, recovery (DeepSeek READY)

- Core: `QueueEntry.rank` (required param, backward-compat decode
  falls back to `Double(orderKey)`); `SessionEvent.queueReorder`;
  transition handler (queued/held entries+anchors only, midpoint
  rank, array move, ack untouched, runUpdate projection); actor
  entry; reopen replay sorts by (rank, orderKey) — reorders
  survive; `SessionExport` emits rank.
- Presentation: `QueueSyncSnapshot` + `ApprovalRequestView`
  (Core-minted, sandbox flag required); `queueSync` action;
  optimistic rows (dedupe by commandID) confirmed/dropped by
  `admittedCommandIDs`; denial rolls back optimistic only
  (documented multi-pending flicker, sync heals); approval
  grant/deny carry minted IDs, sandbox display-only; cancel
  intent; reorder intent; held projection + authoritative clear;
  stale-target/attachment markers; approval line render.
- Tests: 13 UX-QUEUE RED→GREEN (+dedupe/flicker/release pins);
  4 Core reorder (+anchor rules, reopen survival); harness
  evolution; golden `queue-held.json` + manifest `m4-b-b2`;
  BDD-06 ack-correlation probe (`plans/m4-b-b2-probe-ack.log`).
- macOS (R7; macbuild, same host/toolchain as M4-A) at B2 HEAD:
  `swift build` clean; Presentation 58/58 debug green;
  QueueReorder/QueueDurability/QueueContract crash the debug
  runner (SIGBUS signal 10 — G14-class, same mechanism as M4-A:
  deep transition chains on 512 KiB pool stacks) and go 6/6 +
  25/25 + 6/6 green under `swift test -c release`. The three
  suites are Darwin-debug-gated (B2-era G14 gates; Linux-debug
  still runs them fully). These suites were not M4-A macOS
  keepers, so no qualified result changes. Evidence logs:
  `.needletail-dev/m4b-b2/` (mac build + debug + -O logs).
## B3 — session, model, context, epoch views (DeepSeek READY)

- `SessionViews.swift` (new): `UISessionRow` + `sessionLiveness`
  (active/idle/stale/unknown, explicit 5-min rule, skew guard),
  `UIAgentRow` (consult child), `UIModelRoute` (local/cloud),
  `UIContextUsage` (actual vs estimated, UNKNOWN cache),
  `UIEpochRow` + checkpoint states, `UICompactPreview` (note
  rendered, no provider-call concept), `InspectionResult` typed
  payloads. All NAV cases here are catalog `pure`-only.
- Core (one line): boundary landing projects distinct kind
  `run:budget-boundary` (record kind already did; projection
  lagged) — replay-safe (records untouched, reconcile reads
  record kinds). Test asserts kind + detail at the landing.
- Reducer: `inspect` intent (local) + `.dismiss` clears locally;
  `inspectResult` projection; `run:budget-boundary` →
  completedBudgetBoundary; `run_finished` maps the REAL CLI
  outcome vocabulary (completed/interrupted→idle,
  approval_required→held, budget_exhausted/provider_error/
  integrity/invalid/ambiguous→failed, unknown→failed visibly).
- Tests: 10 UX-NAV + run-outcome RED→GREEN (NAV-07 diff views
  deferred to B4); liveness boundary pins; sessions golden +
  manifest `m4-b-b3`; BDD-06 liveness probe
  (`plans/m4-b-b3-probe-liveness.log`).
- Linux `quick` green (exit 0).

## B4 — diff, undo, rewind, approval views (DeepSeek READY)

- `UndoDiffViews.swift` (new): `UIUndoFile/Preview/Outcome`
  (eligibility, conflicts, partials, unknown-outcome notices),
  `UIDiffFile` + provenance (agent/user/mixed — never implied
  authorship), `UIRewindView` (lineage fork + divergence warning),
  `UndoIntent` (preview/run). Approval view gains bound
  `execIdentities` + protected scope (rendered exactly).
- Intents: `undoIntent` → `.undoPreview/.runUndo` effects;
  `rewindRequest` → `.requestLineageFork` (record-only);
  inspect commands/results for diff/undo-preview/undo-outcome/rewind.
  Views request; the actor reconciles/validates/records.
- Render: diff/undo/rewind branches with stable IDs; approval
  exec-identity lines.
- Tests: 8 UX RED→GREEN (UNDO-06/08/09 pure legs, NAV-07 incl.
  hostile-path neutralization, approval identity); undo golden +
  manifest `m4-b-b4`; BDD-06 run-intent probe
  (`plans/m4-b-b4-probe-undorun.log`).
- Linux `quick` green (exit 0).
- macOS R7 (same host/toolchain): `swift build` clean;
  Presentation 78/78 debug green; QueueReorderTests 6/6 `-O`
  green with test-only gate lifted on the exact tree
  (`m4b-b4-opt-reorder2.log`: exit 0; file restored byte-identical,
  sha `dcdc810f…` before/after). Evidence logs:
  `.needletail-dev/m4b-b4/`.
- Reviewed at `0223f21` (delta re-review); B4 fixes landed after.
  Final B4 HEAD is the commit carrying this receipt section
  (branch `m4-a` tip at B4 close; resolve via `git log`, since a
  file cannot name its own commit hash).


## B5 — semantic frame + headless consumer gate (DeepSeek READY)

- `Render` bounds: `maxQueueRows` (64, oldest kept, `queue-truncated`
  marker with hidden count), `maxFrameLines` (512 post-wrap safety +
  marker; dumb-mode reserves the inline-composer slot).
  Every untrusted boundary sanitized (composer, queue/session/model/
  epoch/undo/diff/approval text AND derived ids).
- `HeadlessConsumer` (test-only, Foundation+Presentation+Core):
  send/receive(reported effects)/replay(state+effects); import gate
  pins the module boundary.
- Six capabilities proven with exact oracles: complete projection
  intake; action sequence → EXACT recorded (unexecuted) effect list;
  authoritative receives request nothing (fail-closed, no assert);
  admitted+agent applied; optimistic rollback byte-exact;
  double replay → identical states AND effect lists;
  queue/permissions/undo/epoch inspection via real result payloads.
- Frame-level pins: same state → same full frame (ids+texts+roles);
  same query never refetches; render purity; hostile bytes inert in
  text, ids and overlay (both capability modes).
- BDD-06 probes: frame-cap marker (`plans/m4-b-b5-probe-framecap.log`)
  + new maxFrameLines/dumb-mode coverage.
- M4-due pure RENDER/DX case IDs closed here (36/36 pure set
  complete): UX-RENDER-01…08 (semantic stability, literal markup,
  diff exactness, control neutralization, cluster-safe wrap,
  plain-mode parity, bounded no-loss, canonical bytes intact) and
  DX-09 (PTY-safe output) + DX-10 (deterministic replay, no sleeps)
  in `SemanticFrameTests.swift`.
- Linux `quick` green (exit 0).

## B6 — deferred integration/native completion (in review)

Scope per plan §8: M4-due integration legs executed on the final
tree; M2-due leftovers with zero prior coverage executed or
explicitly mapped; no duplicates of M2-exited lanes.
- New `QueueIntegrationTests` (10 tests, actor-level, InMemory store,
  scripted/gated transports, deterministic barriers; G14-gated on
  Darwin-debug): QUEUE-01 (busy-run admission), QUEUE-02 (durable
  double-submit + idempotent ack), QUEUE-03 (steer boundary),
  QUEUE-04 (FIFO order across steers and follow-ups; steer-first
  dispatch priority is covered by QueueDurabilityTests), QUEUE-05
  (edit/reorder/withdraw + edited-bytes-in-context),
  QUEUE-07 (cancel-hold, no auto-send, explicit resume),
  QUEUE-11 (headless approval holds with approvalPending, zero
  tool execution), QUEUE-12 (failed run holds, explicit resume),
  QUEUE-06 (crash boundary: no auto-resend, exactly one
  explicit redispatch), QUEUE-10 (live epoch switch holds;
  re-consent releases; redispatch carries new-epoch bytes).
- New `QueueAttachmentActorTests` MENTION cases (real temp files,
  scripted validator seam): MENTION-09 (mutated file held, no
  half-composed context), MENTION-10 (real-capture 2 MiB bounded
  excerpt at 4 KiB + manifest; sealed attach refused with no ack),
  MENTION-12 (epoch-switch hold, explicit re-consent via retarget,
  redispatch carries re-consented excerpt). File: G14-gated.
- New `QueueContractTests.UX_QUEUE_09_capsRefuse` (21st-entry
  count cap + cumulative 64 KiB budget cap, typed denials).
- New native undo coverage: `UndoFilesTests.UX_UNDO_06_...`
  (exec-touched file gains no ledger member even with a successful
  exec outcome with full identity; recorded file restores,
  exec-touched bytes intact, exactly one inverse);
  `UndoActorTests.UX_UNDO_08_dirtyWorktreeForkLeavesFilesIntact`
  (actor-level fork via SessionActor, throughSequence 0 empty-history
  boundary, two real temp files; asserts fork record present and both
  files unchanged). UNDO-08 integration leg: no separate integration
  tier exists in the catalogue beyond these; recorded as covered via
  native + pure legs.
- Per-case status (M4-due unless noted):
  - QUEUE-01/02/03/04/05/07/11/12: pure (B1/B2) + integration (B6) — FULL.
  - QUEUE-06 (M2): D0 boundary lanes + B6 crash test — FULL.
  - QUEUE-08 (M2): existing `staleHeadHoldsAndFixRedispatches` — FULL (mapped, not duplicated).
  - QUEUE-09 (M2 pure): new B6 pure test — FULL.
  - QUEUE-10 (M2): new B6 case-named actor test — FULL (D3 C2/C3 lanes cover the same mechanism; not duplicated).
  - MENTION-09/10/12 (M2): new B6 integration tests — FULL.
  - UNDO-06: pure (B4) + native (B6) — FULL; integration leg N/A (no actor-mediated path beyond these).
  - UNDO-08: pure (B4) + native (B6 actor + state) — FULL.
  - UNDO-09: M2-exited lanes + B4 pure + B6 re-verified — FULL.
  - QUEUE-01/03 streaming/tool-call variants: busy-run admission via the same `admitToQueueState` path is FULL (requesting phase here); physical stream-chunk and incomplete tool-JSON interleave variants remain M4-D. Marked PARTIAL for those physical variants only.
- Linux evidence (this tree): per-suite logs under
  `.needletail-dev/m4b-b6-linux/` (QueueIntegration 10/10,
  QueueAttachment 7/7 incl. new MENTION tests, QueueContract,
  QueueDurability, QueueCrashActor, UndoFiles, UndoTests,
  UndoJournalTests, UndoActorTests) + selected `./dev test case` per ID
  (see Closeout for selected IDs).
 - macOS evidence (same host/toolchain): debug behavior at last
  successful run (89bf90d): QueueCrashActor / UndoTests crashed
  SIGBUS (signal 10, G14-class, ungated at that tree);
  QueueIntegration / QueueAttachment / QueueContract /
  QueueDurability were already G14-gated and filtered out at compile
  time in debug (suite absent; Linux debug covers them;
  QueueIntegration gate was `c8aa3f2`, 4 commits before `89bf90d`).
  UndoFilesTests (10/10 at `89bf90d`, 11/11 at this HEAD) +
  UndoJournalTests (5/5) were not run on mac in
  `.needletail-dev/m4b-b6/` (Linux debug covers them). `-O` runs with
  test-only lifts were green for QueueContract/QueueDurability/
  QueueCrash at `89bf90d` (b6k `opt-*.log`); QueueIntegration 9/9
  `-O` was green at the pre-gate tree (`m4b-b6-opt-integ.log` at
  20:11, before `c8aa3f2`). Current HEAD gates are test-only (see
  Closeout). Evidence under `.needletail-dev/m4b-b6/`.

## Closeout — final gate at HEAD (this commit, 2026-11-08, round-2 fixes)

Branch `m4-a` local-only; HEAD is this commit (no push/PR/merge;
resolve via `git log --oneline -1`). M4-A baseline `32d2226`/`29af6f0`
unchanged.

- Linux offline gate (this HEAD, no network, no provider):
  - `quick` 199+34+267+96+77+28 tests green (exit 0; `.needletail-dev/logs/dev-quick.log` at 53 s).
  - `native` 267 tests green (CLOSURE 01…15 + sqlite contention; exit 0; 53 s).
  - `timing` 8 tests green (NET-04 cancellation/readiness; exit 0; 6 s).
  - `e2e` 239 tests green (13 suites including B5CEndToEnd, TOOL10, C2/C3 etc; exit 0; 515 s at 08:09 AEDT; `.needletail-dev/logs/dev-e2e.log`, `.needletail-dev/xunit/results-e2e-swift-testing.xml`).
  - `feasibility` 12 tests green (M0-C PTY + B5-C gateway; exit 0; 0.5 s).
  - `coverage` reconcile green: XUNIT MERGE bulk=494 timing=8 e2e=239 merged=741 failures=0 unsatisfied=14 missing=146 satisfied=40 executed=741 labeled=163 skipped=1 failed=0; BDD-01 ingestion 3/3 green (stdout captured in `.needletail-dev/logs/dev-coverage.log`; merged xunit at `.needletail-dev/xunit/results-merged-swift-testing.xml`).
  - B6 per-suite logs at this HEAD (`.needletail-dev/m4b-b6-linux/`): QueueIntegration 10/10, QueueAttachment 7/7, QueueContract 7/7, QueueDurability 25/25, QueueCrashActor 8/8, UndoFiles 11/11, UndoTests 34/34, UndoJournal 5/5, UndoActor 6/6; SemanticFrame+Headless 18/18; `quick` aggregate 96 presentation tests green.
  - Cases: per-suite logs plus selected `./dev test case` per ID (QUEUE-01/06/10, MENTION-09/10/12, UNDO-06/08/09 verified via `case` runner; remaining IDs via suite logs) — all green (see Linux B6 logs and `FINAL-*.log`).

- macOS R7 (Builds-Mac-Pro.local, same host/toolchain as M4-A;
  Swift 6.3.3, Xcode 26.x). Network partition at closeout:
  `192.168.2.106`   filtered (`No route to host` via `192.168.1.1`;
  `nmap -Pn` Host is up / 22 filtered at 08:20–08:22 AEDT). The final
  `run-b6final.sh` precise-lift battery was staged
  (`.needletail-dev/m4a-final/m4b-review2.tar` + `run-b6final.sh` at
  this HEAD, plus `m4b-closeout.tar` at prior HEAD) but could not be
  executed on the host before the partition. Round-2 Linux
  re-verification at this HEAD: `quick` green, QueueIntegration 10/10
  (Q10 stale-attachment), QueueContract 7/7 (byte+count typed denial),
  UndoFiles 11/11. Evidence carried forward from the last successful
  mac run at `89bf90d` (see `git log --oneline 89bf90d..HEAD` for count; diff to HEAD is
  test-only + receipt/comment + dev script — no Source logic change;
  `git diff 89bf90d..HEAD -- Sources/` empty):
  - Keepers (debug) green: C2 21/21, TOOL10 8/8, B2 12/12+15/15, B3 30/30, C1 8/8, CrossRun 20/20 (`.needletail-dev/m4b-b6/m4b-b6k-*.log`, `m4b-b6k-run.log`).
  - Gated suites: at `89bf90d`, QueueCrashActor crashed debug
    (SIGBUS, G14, ungated) and went `-O` green; UndoTests crashed
    debug (ungated, no separate `-O` log at `89bf90d`; Linux debug
    covers it); QueueIntegration
    / QueueAttachment / QueueContract / QueueDurability were already
    gated and reported 0 tests in debug (Linux debug covers them);
    QueueContract / QueueDurability / QueueCrash were `-O` green with
    lifts in b6k `opt-*.log` (revert byte-identical), QueueIntegration
    9/9 `-O` was green at the pre-gate tree (`m4b-b6-opt-integ.log`
    at 20:11, before `c8aa3f2`). The final HEAD adds the
    Q10 stale-attachment fix, Q09 byte typed denial, UNDO-06 mode, and
    gate shims — same G14 gating, same source paths; Linux debug is
    green for the identical suites (Linux `-O` not run; debug covers
    them), so the final mac `-O` is expected green under the same
    lifts (re-run queued for when the host is reachable; no code
    change required).
  - B2-era mac evidence (Section B2) remains valid: Presentation
    58/58 debug green; QueueReorder/QueueDurability/QueueContract
    SIGBUS debug / 6/6,25/25,6/6 `-O` green (`.needletail-dev/m4b-b2/`).
  - B4-era mac evidence: Presentation 78/78 debug green; QueueReorder
    6/6 `-O` green with pristine revert (`m4b-b4-opt-reorder2.log`).

- G14 gates: test-only `#if canImport(Glibc)` directly above
  `struct QueueIntegrationTests`/`QueueAttachmentActorTests`/
  `QueueCrashActorTests`/`QueueContractTests`/`QueueDurabilityTests`/
  `UndoTests` (and `QueueReorderTests`); precise python lift
  `run-b6final.sh` lifts only that pattern (never the Glibc import
  shim), reverts byte-identical via SHA-256. Linux-debug covers the
  gated suites; Darwin `-O` at `89bf90d` covered the same assertions
  on mac (final HEAD `-O` pending host reachability).

- BDD-06 probes: `plans/m4-b-b1-probe-boundary.log` (B1 boundary),
  `m4-b-b2-probe-ack.log` (queue ack), `m4-b-b3-probe-liveness.log`
  (5-min rule), `m4-b-b4-probe-undorun.log` (undo run), `m4-b-b5-probe-framecap.log` (frame cap).

- Reviews: B0 READY×2, B1 READY×2, B2 READY, B3 READY, B4 READY,
  B5 READY. B6 delta re-review round 1 NEEDS-CHANGES addressed
  (Q10 stale barrier, Q01/Q03 partial, Q09 denial, UNDO-06 mode,
  receipt honesty); round 2 READY at `0b5c1cf` (final polish at this
  HEAD is wording-only); Linux gate is green end-to-end, mac keepers
  from `89bf90d` are valid for this source tree, final mac `-O`
  rerun pending host reachability (staged tar+script at this HEAD).

## Verdict — M4-B QUALIFIED at this commit

M4-B pure presentation and interaction contract is **QUALIFIED** on
branch `m4-a` at this commit (Linux primary gate; resolve via
`git rev-parse HEAD`). All 36 M4-due `pure`
cases are closed (RENDER-01…08 + DX-09/10 in B5, MENTION/NAV/QUEUE/UNDO
legs across B1…B6; QUEUE-01/03 physical streaming + incomplete
tool-JSON interleave variants are the only PARTIAL, deferred to M4-D
per plan). B6 deferred integration/native legs are FULL per plan §8
with the PARTIAL noted above; no duplicate of M2-exited lanes. No
TUI/ANSI/PTY/desktop, no second source of truth, no generic UI
framework/persistence/new approval engine, no model traffic; UIAction
→ reducer → UIEffect → SessionActor → projection → UIState, and
Presentation never mints/grants/mutates (PORT-02 import gate holds).

Evidence: Linux offline green at this HEAD (`quick` 199+34+267+96+77+28,
`native` 267, `timing` 8, `e2e` 239, `feasibility` 12, `coverage`
merged 741, BDD-01 ingestion 3/3) + B6 per-suite logs
(QueueIntegration 10/10 with Q10 new-epoch proof, QueueAttachment
7/7, QueueContract 7/7, QueueDurability 25/25, QueueCrash 8/8,
UndoFiles 11/11, UndoTests 34/34, UndoJournal 5/5, UndoActor 6/6,
SemanticFrame+Headless 18/18) + macOS keepers at `89bf90d` (C2 21,
TOOL10 8, B2 12+15, B3 30, C1 8, CrossRun 20 debug; gated suites as
above) + staged `run-b6final.sh` precise-lift battery (this HEAD,
re-run queued). G14 gates are test-only and byte-identical;
BDD-06 probes present.

**STOP** after M4-B qualification per mission: no M4-C/D work, no
push/PR/merge, no model traffic. Maintainer review is the next gate.
