# T08 Confirmation Timeout Adjudication — INVALID_INFRA

Date: 2026-11-03. Annotates (does not alter) the frozen M3-D results and the confirmation evidence.

## Assigned verdicts

- Confirmation `T08-R1-nt`: **INVALID_INFRA** (was: FAIL exit 1).
- Confirmation `T08-R2-nt`: **INVALID_INFRA** (was: FAIL exit 1).

The frozen M3-D T08 cells (FAIL exit 4, oversized-batch terminal) are untouched — different failure mode, valid scored outcomes.

## Contemporaneous provider-health evidence (all recorded during the confirmation window)

1. **Capture-deadline overrun with zero scored requests.** Both cells: wall 254 s / 237 s against the fixed 180 s checkpoint-capture deadline (`RunCommand` `cpDeadline`); stderr shows only `checkpoint: capture failed, malformed, or timed out`, zero `usage:` lines. The main runs had completed normally first (`completed` event in-ledger, then `checkpointing` → `checkpoint-failed`).
2. **Durable budget proof of main-run traffic.** `m3c-live-budget.json`: 23 sends (R1) and 12 sends (R2), all within the per-task ceiling of 45. The traffic happened; only the reporting epilogue was skipped (fixed separately — budget line on all terminal paths).
3. **Independent same-window probe.** Trivial 8-token Halogen request during the window: **39.3 s** (frozen norms 10–25 s/turn), empty content with reasoning spillover, `finish_reason: length` — degraded model/server behavior, not a harness timeout.
4. **Corroborating walls.** T02-R1 confirmation took 382 s for 10 requests (frozen: 148 s) — same window, same direction.
5. **Non-remediation cause.** The only source delta between the passing unscored T08 diagnostic image and the confirmation image is the normalization perf rewrite (behaviorally identical on short paths; covered by 45 B1 tests). Remediation does not touch capture/transport/checkpoint paths.

## What is NOT excused

- Model non-convergence in T02-R1/T10-R1/T10-R2 (empty/wrong artifacts after full budgets): model failures, stand.
- T06-R2/T11-R1 regressions (no-edit dithering; leftover probe file): model-side failure shapes, stand as FAILs for promotion counting.
- All 13 non-T08 confirmation cells: valid coding-quality evidence regardless of direction.

## Consequence

The two T08 cells are excluded from the promotion fraction as infrastructure-contaminated (neither PASS nor FAIL for M4-gating). No replacement runs authorized under this mission (separately authorized policy only). The frozen M3-D T08 FAILs stand as the scored record.
