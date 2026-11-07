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
## B3 — session, model, context, epoch views (review pending)

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

