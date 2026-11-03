# M3 Confirmation Cohort Freeze (pre-request record)

Frozen: 2026-11-03, before the first confirmation provider request.
Branch: `m3-planning`, HEAD `9e83398` (remediation + review fixes).
Baseline sources: frozen `f4fef24` (per Docker amendment Addendum B).
Images: baseline `m3d-needletail:1` = `b7c2336bc8aa`; remediation `m3d-needletail:remediation` = `781ccf795709`.
Endpoint/model/networking/limits/grant flow: identical to M3-D scoring (Halogen `halogen-qwen3.8-flash-next` via `m3d-forwarder`, internal net, non-root, read-only root, sandbox grant, no human approval).

## Cohort: 15 historical Needletail cells (fixed order)

## Cohort: 15 cells in fixed execution order (9 historic FAILs + 6 exit-5 PASSes)

| # | Cell | Cohort | Frozen verdict | Frozen exit | Frozen req |
|---|------|--------|---------------|-------------|------------|
| 1 | T02-R1-nt | FAIL | FAIL | 5 | 10 |
| 2 | T02-R2-nt | PASS5 | PASS | 5 | 10 |
| 3 | T03-R2-nt | FAIL | FAIL | 5 | 10 |
| 4 | T05-R1-nt | PASS5 | PASS | 5 | 10 |
| 5 | T05-R2-nt | PASS5 | PASS | 5 | 10 |
| 6 | T06-R1-nt | FAIL | FAIL | 5 | 10 |
| 7 | T06-R2-nt | PASS5 | PASS | 5 | 10 |
| 8 | T07-R1-nt | FAIL | FAIL | 5 | 10 |
| 9 | T07-R2-nt | FAIL | FAIL | 5 | 10 |
| 10 | T08-R1-nt | FAIL | FAIL | 4 | 8 |
| 11 | T08-R2-nt | FAIL | FAIL | 4 | 3 |
| 12 | T10-R1-nt | FAIL | FAIL | 5 | 10 |
| 13 | T10-R2-nt | FAIL | FAIL | 5 | 10 |
| 14 | T11-R1-nt | PASS5 | PASS | 5 | 10 |
| 15 | T11-R2-nt | PASS5 | PASS | 5 | 10 |

Task IDs, REV5 fixtures, frozen prompts, oracles, model settings, per-task limits (default 15; T08 45), Docker boundaries: unchanged from M3-D.
No new Pi traffic. Frozen Pi 24/24 remains the historical comparison.

## Budget

150 additional provider requests maximum (separate diagnostic allowance; M3-D's 386+10+12 accounting untouched). Pre-launch check per cell: spent + cell ceiling must fit; stop otherwise. Per-run enforcement via the existing `NEEDLETAIL_REQUEST_BUDGET` + LiveRequestBudget pre-send gate. Count retries/malformed/failed/aborted. One run per cell; no repeats.

## Method per cell

`M3D_RUNS=/tmp/m3d-confirm/runs M3D_NT_IMAGE=m3d-needletail:remediation python3 docker/m3d-run.py <TASK> <REP> nt` — fresh container/workspace/state/grant per cell, UNSCORED marker file in each run dir, results never merged into `/tmp/m3d/runs/`.
