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

## B2 — queue, interruption, recovery (review pending)

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

Branch `m4-a` (local-only; no push/PR/merge without authorization).
Baselines: M4-A qualified code `32d2226` (receipt `29af6f0`), boundary
`plans/m4-a-boundary.md`, plan `plans/m4-b-plan.md` (DeepSeek READY,
re-review READY).

## B4 — diff, undo, rewind, approval views (review pending)

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


## B5 — semantic frame + headless consumer gate (review pending)

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
  QUEUE-04 (FIFO order incl. reorder), QUEUE-05
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
  exec outcome; recorded file restores, exec-touched bytes intact);
  `UndoActorTests.UX_UNDO_08_dirtyWorktreeForkLeavesFilesIntact`
  (actor-level lineage fork with real workspace files; fork commits
  exactly one record, zero bytes change). UNDO-08 integration leg:
  no separate integration tier exists in the catalogue beyond these;
  recorded as covered via native + pure legs.
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
  - QUEUE-01/03 streaming/tool-call variants: pure tests use the busy-run admission path (same `admitToQueueState` for requesting/streaming); PTY/stream-chunk physical legs remain M4-D. Marked PARTIAL for physical streaming only.
- Linux evidence (this tree): per-suite logs under
  `.needletail-dev/m4b-b6-linux/` (QueueIntegration 10/10,
  QueueAttachment 7/7 incl. new MENTION tests, QueueContract,
  QueueDurability, QueueCrashActor, UndoFiles, UndoTests,
  UndoJournalTests, UndoActorTests) + `./dev test case` per ID.
- macOS evidence (same host/toolchain): debug crashes with SIGBUS
  (signal 10, G14-class) for QueueIntegration, QueueAttachment,
  QueueCrashActor, UndoTests, QueueContract, QueueDurability —
  all B2/B6-era gated; UndoFilesTests + UndoJournalTests pass
  natively. `-O` runs with test-only G14 lifts (see Closeout for
  final matrix). Evidence under `.needletail-dev/m4b-b6/`.
