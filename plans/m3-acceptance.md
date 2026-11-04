# M3 Acceptance Record — CONDITIONALLY ACCEPTED for continued product development

Date: 2026-11-04. Branch `m3-planning`. Maintainer decision: **M3 CONDITIONALLY ACCEPTED**.
Engineering viability gate sufficiently established. No additional inference benchmarks authorized.

Prohibited claims (not made here or anywhere in the M3 evidence):
no coding parity with Pi, no checkpoint speedups, no successful 48-run Gemma comparison.

## 1. Preserved evidence (separate, never combined)

- Frozen Halogen comparison: `plans/m3-tasks.json` REV5, `plans/m3-d-receipt.md`, `plans/m3-report.md`.
  Scored outcome **Needletail 15/24 vs Pi 24/24** stands unmodified.
- Remediation + scoped confirmation: `plans/m3-remediation-report.md`,
  `plans/m3-confirmation-cohort.md`, `plans/m3-confirmation-report.md` (STOP: 4/9 flips, 4/6 holds).
- T08 adjudication: `plans/m3-t08-adjudication.md` (confirmation T08-R1/R2 INVALID_INFRA;
  frozen M3-D T08 FAILs stand).
- Health protocol: `plans/m3-provider-health-protocol.md` (frozen).
- Gemma comparison (partial): `plans/m3-gemma-context-eligibility.md`,
  `plans/m3-gemma-report.md` (STOPPED at 6/48 — infeasible under frozen terms).
- This record: accounting reconciliation (§2) + accepted limitations (§3).

Halogen and Gemma scores are never combined; no rescoring, no oracle/fixture changes,
no reruns anywhere in this closeout.

## 2. Aggregate accounting reconciliation (offline, no provider calls)

All figures below were reconciled by reading preserved local run files only.
No scored outcome changes; no new traffic.

### 2.1 Halogen M3-D (cap 850, frozen)

- 364 verdict-bearing requests + 22 T09 leg-1 = **386 scored**.
- +10 authorized diagnostic + ~12 voided-but-counted per amendment ≈ **408 accounted**.
- All figures per `plans/m3-d-receipt.md` / `plans/m3-report.md`; unchanged.

### 2.2 Halogen confirmation (separately authorized 150)

- True provider spend **163 vs 150 authorized (+13)**, confined to the two T08 cells
  (durable per-run budget files: 23 + 12 sends; per-task ceiling 45 held in both).
- Cause: frozen-scorer blind spot (usage epilogue skipped on early exits), fixed at the
  source afterwards (durable `budget:` line on all terminal paths + scorer `budgetUsed`
  parsing + zero-traffic tests). Disclosed in the confirmation report; no replacement
  runs; no M3-D impact (no frozen cell exited via that path).

### 2.3 Gemma comparison (separate cap 850)

Per-cell authoritative counts from `/tmp/m3d-gemma/runs/*/result.json`:

| Cell | Verdict | Exit | requests | budgetUsed |
|------|---------|------|----------|------------|
| T01-R1-nt | PASS | 0 | 10 | 10 |
| T01-R1-pi | PASS | 0 | 6 | None (post-hoc) |
| T02-R1-nt | FAIL | 5 | 10 | 10 |
| T02-R1-pi | FAIL | timeout | 498 | None (post-hoc) |
| T03-R1-nt | PASS | 0 | 4 | 4 |
| T03-R1-pi | FAIL | timeout | 700 | None (post-hoc) |

True total **1228 = 10+6+10+498+4+700** against the 850 launch cap.

Reconciliation of the 498/700 observations against the 850 cap:

1. **Two different enforcement mechanisms, both by design.** Needletail runs carry
   pre-send request-budget enforcement, so `requests == budgetUsed` exactly on all
   three NT cells (10, 10, 4). Pi 1.4.0 has no turn/request cap by its own design, so
   the harness counts Pi turns post-hoc (`budgetUsed: None`); the request counter is
   the authoritative spend figure.
2. **The 850 cap is a launch gate, not a pre-emption mechanism.** It decides whether
   a new cell may start; it cannot terminate a running Pi cell (same semantics as the
   frozen Halogen amendment). T03-R1-pi was lawfully launched (projected 15 fit the
   remaining budget) and spent 700 before the 1200 s wall timeout stopped it.
3. **No verdict depends on the overrun.** Both looping cells are FAIL by timeout
   regardless of counting; all NT cells are within their per-task ceilings. The halt
   (no further cells launched) functioned as designed.
4. **No double counting with Halogen.** The Gemma 1228 sits under its own separate
   authorization; the M3-D 386/408 figures are untouched.

### 2.4 Totals

- Halogen scored/accounted: ≈408/850 (frozen) + 163 true (confirmation, +13 disclosed).
- Gemma: 1228 true under a separate 850 launch cap (halted at 6/48).
- No hidden traffic. No M3-D Halogen budget touched by any later phase.

## 3. Accepted M3 limitations

1. **No coding parity.** NT 15/24 vs Pi 24/24; all 9 NT losses are model-side
   efficiency/robustness (7 turn-budget exhaustions, 2 oversized-batch hard fails);
   the 6/13 exit-5 asymmetry is disclosed; Pi 24/24 exit 0.
2. **No cache/speedup claim.** Checkpoint generation + rollover qualified
   functionally (M3-C); cache reuse UNKNOWN — the provider exposes no counters
   (carried from M3-C).
3. **No 48-run Gemma comparison.** 6/48 partial; infeasible under frozen terms
   (Pi non-termination + no turn bound + fixed cap). Delivered instead: qualified
   endpoint, full context eligibility, 6 scored cells, the non-termination finding.
4. **Confirmation STOP stands.** 4/9 flips, 4/6 holds; remediation demonstrates
   genuine friction reduction (rejections halved, node works, exits honest) but does
   not clear the promotion bar. The two regressions are model-side failure shapes
   with no demonstrated harness mechanism.
5. **T08 record.** Frozen M3-D T08 FAILs stand as scored; confirmation T08 cells are
   INVALID_INFRA and excluded from promotion math; no replacements authorized.
6. **Pre-existing timing-sensitive test issues** (reproduced on clean baseline, not
   caused by M3 changes): `NeedletailActorTests` yield-budget timeouts under bulk
   parallelism (certified in the serialized `timing` lane instead); TOOL_08 / C1 /
   CLOSURE_14 flakes under parallel load (certified in the serialized `e2e` lane).
   Documented in the remediation report §5 and owned by the `./dev` lane design.
7. **Method bounds.** Single model/day, 2 reps (wide CIs); container overhead not
   separated; T09-NT degenerate (task too fast to catch); oversized-batch truncation
   missing (future work); NT transcript verbosity inflates in-tokens; boundary-PASSes
   are oracle-verified but weaker evidence than model-finalized passes.
8. **Output-token cap asymmetry (disclosed, frozen protocol untouched).** The frozen
   comparison ran Needletail with `max_output 4096` (`docker/m3d-config.json`) against
   Pi `halogen-local` with `maxTokens 65536` (`docker/pi-models.json`) on the same
   model and temperature. A completion needing >4096 output tokens truncates under
   Needletail while Pi may finish it — a like-for-like caveat on output behavior,
   recorded here rather than in the frozen protocol (which cannot be revised
   post-result). No frozen cell's verdict is attributed to truncation on current
   evidence; the asymmetry stands as a method bound, not a score adjustment.

## 4. Merge readiness (this closeout)

- Finalized reports + code committed on `m3-planning`; full offline regressions
  (`./dev test offline`), vendor check, qualification, release bundle + clean-host
  smoke executed locally; CI + aggregate CodeRabbit review on the epic PR.
- Demonstrated blockers resolved without reopening settled milestone decisions
  (frozen benchmark, scored outcomes, STOP verdicts). No merge without maintainer
  release authorization — PR opened as do-not-merge.
