# M3 Scoped Remediation Confirmation Report (UNSCORDED)

Date: 2026-11-03. Branch `m3-planning`, local only. No push/PR/merge.
This experiment does not replace the frozen M3-D benchmark (Needletail 15/24 vs Pi 24/24 stands).

## 1. Identity and review

- Baseline sources: frozen `f4fef24`; baseline image `m3d-needletail:1` = `b7c2336bc8aa`.
- Remediation sources: HEAD `9e83398` (R1–R4 + CLOSURE_10 + review fixes); remediation image `m3d-needletail:remediation` = `781ccf795709` (built from `9e83398`; `git diff 9e83398 HEAD -- Sources Tests` empty at run time — post-freeze commits touch only plans/docker).
- Endpoint/model/networking/limits/grant flow identical to M3-D scoring.
- Independent delta review (adversarial, pre-run): verdict **BLOCKED** on one demonstrated defect — O(n²) `./` stripping reachable with a 512 KiB path (model-triggered CPU DoS) — plus one non-blocking twin-skeleton note and test gaps. **All blocking items fixed before the first confirmation request**: index-based O(n) strip + 4096-byte length gate before normalization (validator and executor funnel); new negative tests (`./../x`, `/workspace/../x`, 200 KiB adversarial path, undecodable base64, skeleton-read loud failure, search-"." end-to-end, oversized no-result assertion). Twin-skeleton hazard accepted as documented residual (requires a planted U+FFFD twin; unprotected-only; receipts show exact bytes; CLOSURE_10 recall wins). Updated-test assessment from the review: all four established-test updates are legitimate policy changes, none masks a regression.

## 2. Cohort and budget (frozen pre-request in `plans/m3-confirmation-cohort.md`)

15 cells in fixed order: 9 historic FAILs (T02-R1, T03-R2, T06-R1, T07-R1, T07-R2, T10-R1, T10-R2, T08-R1, T08-R2) + 6 exit-5 PASSes (T02-R2, T05-R1, T05-R2, T06-R2, T11-R1, T11-R2). One run each, fresh container/workspace/state, no Pi traffic, no repeats.

Budget: 150 additional requests authorized. Pre-launch check per cell (spent + ceiling must fit) + per-run `NEEDLETAIL_REQUEST_BUDGET` pre-send enforcement. Retries/malformed/failed/aborted counted.

**Accounting outcome: true provider spend 163 vs 150 authorized (+13).** Cause: a frozen-scorer blind spot — when checkpoint capture fails, the CLI exits before the usage epilogue, so `result.json` records 0 while the durable per-run budget files record the main-run sends (T08-R1: 23, T08-R2: 12; per-task ceiling 45 held in both). All other cells agree exactly between `result.json` and budget files. The overrun was unintentional, confined to the two T08 cells, and no further provider calls will be made. The M3-D frozen accounting is unaffected (no frozen cell exited via this path).

## 3. Before/after table

| Cell | Frozen | Confirm | Δ |
|------|--------|---------|---|
| T02-R1 (F) | FAIL ex5 10r | FAIL ex0 10r boundary | exit honest; still no convergence |
| T03-R2 (F) | FAIL ex5 10r | **PASS ex0** 10r boundary | FLIP ✓ |
| T06-R1 (F) | FAIL ex5 10r | **PASS ex0** 10r boundary | FLIP ✓ |
| T07-R1 (F) | FAIL ex5 10r | **PASS ex0** 10r boundary | FLIP ✓ |
| T07-R2 (F) | FAIL ex5 10r | **PASS ex0** 10r boundary | FLIP ✓ |
| T10-R1 (F) | FAIL ex5 10r | FAIL ex0 10r boundary | exit honest; still no convergence |
| T10-R2 (F) | FAIL ex5 10r | FAIL ex0 10r boundary | exit honest; still no convergence |
| T08-R1 (F) | FAIL ex4 8r | FAIL ex1 0r(scored)/23r(true) | capture timeout (infra), main run completed normally |
| T08-R2 (F) | FAIL ex4 3r | FAIL ex1 0r(scored)/12r(true) | capture timeout (infra), main run completed normally |
| T02-R2 (P5) | PASS ex5 10r | PASS ex0 10r boundary | holds |
| T05-R1 (P5) | PASS ex5 10r | PASS ex0 normal | holds, model terminated |
| T05-R2 (P5) | PASS ex5 8r | PASS ex0 normal | holds, model terminated |
| T06-R2 (P5) | PASS ex5 10r | **FAIL ex0** 10r boundary | REGRESSION (empty diff — model never edited) |
| T11-R1 (P5) | PASS ex5 10r | **FAIL ex0** 10r boundary | REGRESSION (leftover `.list_files.py` probe) |
| T11-R2 (P5) | PASS ex5 10r | PASS ex0 boundary | holds |

(ex = exit code, r = provider requests; "boundary" = `completed-budget-boundary`.)

## 4. Promotion questions answered

1. **Historic FAILs now passing: 4 of 9** (T03-R2, T06-R1, T07-R1, T07-R2). T02-R1/T10-R1/T10-R2 still fail by non-convergence (model-side, same disease as frozen); T08s fail by capture timeout (infra, §5).
2. **Previously passing still passing: 4 of 6.** T06-R2 (no-edit dithering) and T11-R1 (untracked probe file) regressed. Both failure modes are model-side and match frozen failure shapes; no harness mechanism for either was demonstrated (boundary completion cannot cut runs short — it fires exactly where `budgetExhausted` fired; normalization only widened accepted spellings, and neither regression involves a normalized path succeeding wrongly).
3. **Oversized recovery: no terminal oversized-batch failure occurred in any of the 15 cells** (zero `malformedEvent` exits; zero oversized notices). The R3 mechanism was demonstrated live in the unscored T08 diagnostic (notice → continuation → PASS), but this cohort did not trigger it. T08's failures here are checkpoint-capture timeouts, a different mode — recovery neither demonstrated nor refuted in-cohort.
4. **Node executes: yes, in-experiment.** Two successful `/usr/local/bin/node` executions in T02-R1's ledger (resolve + spawn agree); zero size-limit refusals across all 15 cells (no "too large"/"exceeds" anywhere). Probe: `v24.22.2`, exit 0.
5. **Formerly rejected calls now execute: yes.** Cohort rejections ≈44 vs ≈100 frozen for the same cells; dot-component rejections 30+→0; `/workspace`-prefixed 8→0; bare `argv[0]`-match 11→0 (rewritten). Residual rejections are deliberate boundaries (bare executables, bare absolutes, wrong-path guesses, control bytes) plus clearer root messages. Replay analysis: ~69/100 frozen rejections validate under remediation.
6. **Turns: same volume, different composition.** 13 non-T08 cells used 8–10 requests, as frozen. No turn savings demonstrated — models fill the budget either way. What changed is where turns go (fewer shape rejections) and how runs land (exit 5→0).
7. **New failures: none demonstrated.** Zero denials, zero queue holds, zero integrity stops, zero approval exits (3), zero invalid stops (2), zero provider errors (4) across 15 cells. Exit codes: thirteen 0s (all oracle-decided), two 1s (capture timeouts). Approval/authorization/containment code paths untouched by the remediation except the reviewed additions.
8. **Boundary landings among passes: 6 of 8** confirmation PASSes (T02-R2, T03-R2, T06-R1, T07-R1, T07-R2, T11-R2); T05-R1/R2 terminated normally. Same pattern as frozen (models rarely terminate). All boundary PASSes are oracle-verified artifacts with the landing kind recorded — honest but weaker evidence than model-finalized passes, disclosed as such.

## 5. T08 capture timeouts (infra, not remediation)

Both T08 main runs **completed normally** (not boundary) then failed the 180 s checkpoint-capture wait: `checkpoint: capture failed, malformed, or timed out`. Contributing evidence for environmental causation: a trivial 8-token probe took 39 s with degraded output (empty content + reasoning spillover) during the confirmation window; several cells ran 2–3× frozen walls (T02-R1 148→382 s). The remediation does not touch capture/transport/checkpoint paths, and the only source delta between the passing unscored T08 diagnostic image and the confirmation image is the normalize perf rewrite (behaviorally identical on short paths; proven by the 45-test B1 suite). The 180 s capture deadline vs 39 s+/request latency fully explains the timeouts. Recorded as infra failures; the main-run completions are evidence the task flow itself proceeds under remediation.

## 6. Recommendation: STOP (criteria not met)

- Zero safety/containment/authorization/durability regressions: **MET**.
- All six previously passing still pass: **NOT MET (4/6)**.
- ≥5 of 9 historic FAILs now pass: **NOT MET (4/9)**.
- No Node-size refusal recurrence: **MET**.
- No terminal oversized-batch failure: **MET** (no occurrence; mechanism proven only in the unscored diagnostic).
- No misleading clean-success: **MET with disclosed caveat** (all verdicts oracle-decided; boundary kind recorded; boundary-PASSes are weaker evidence).

Per the mission rule (exact distribution + one justified correction or STOP): **no single code correction is justified** — the two regressions show model-side failure modes with no demonstrated harness mechanism, the T08s show infra timeouts against a fixed 180 s deadline, and n=1-per-cell variance (both directions: 4 flips up, 2 flips down) dominates any signal. Re-running cells is prohibited, and another correction without a demonstrated defect would be tuning. **STOP: do not proceed to M4 on this evidence.** The remediation shows genuine friction reduction (rejections halved, node works, exits honest) but does not clear the promotion bar; the frozen M3-D result (15/24 vs 24/24) stands unmodified.

Raw evidence: `/tmp/m3d-confirm/runs/` (15 cells, UNSCORED markers, ledgers + logs preserved); measurement script `docker/m3d-confirm-measure.py`; cohort freeze `plans/m3-confirmation-cohort.md`.
