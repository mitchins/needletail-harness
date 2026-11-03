# M3 Gemma 4 Comparison Report (matched comparison INFEASIBLE as specified)

Date: 2026-11-03/04. Branch `m3-planning`, local only. No push/PR/merge.
Never combined with Halogen runs. Original scored M3-D (15/24 vs 24/24) stands unmodified.

## 1. Endpoint

vLLM at `http://192.168.1.14:8000/v1`, model `reinforce20001/gemma4-26b-a4b-it-qat-w4a16-ct`, `max_model_len: 110000` (server-advertised, verified via `/v1/models`). No download/reload/restart/reconfiguration — verified only. Access from containers via dedicated `m3d-gemma-forwarder:1` (socat, same pattern as M3-D), internal-net only.

## 2. Qualification: PASSED (both harnesses)

`docker/m3d-gemma-qual.py`, evidence under `/tmp/m3d-gemma/qual/` (stdout/stderr/logs per check):

- Identity + text + streaming + usage: NT (`GEMMA-NT-OK`, exit 0, usage + budget lines present), Pi (equivalent) — PASS.
- Genuine model-generated tool call: NT read of seeded file verbatim, Pi read of seeded file verbatim — PASS.
- Pairing + continuation: read-then-write-derived-value completed by both harnesses (NT `b.txt` correct; Pi `b.txt == 2×a.txt` after the model rewrote `a.txt` first — mechanism correct, relational check) — PASS.
- Exact request/response evidence + usage: recorded per check — PASS.
- Stable repeated latency: 6 harness runs 0.46–1.6 s — PASS (also the first health-protocol canary).

One incompatibility found and fixed during qualification: vLLM emits `reasoning` delta keys (not `reasoning_content`); Needletail's strict assembler failed closed (terminal `unknownDeltaKey`). Fix: accept `reasoning` as an accumulate-only alias with identical handling; non-string still malformed; allowlist otherwise unchanged. Covered by `WIRE-06b` RED/GREEN test. Minimal interop, no harness redesign. Pi needed no changes.

## 3. Context eligibility: all 12 tasks COMPARABLE

Projection = 2× max observed `usage_in` (48 scored M3-D runs, both harnesses) + 16K output + 8K tool reserves. Worst: T02-NT 74468 < 110000 (32% headroom). Full table in `plans/m3-gemma-context-eligibility.md`. No fixture shortening, no oracle modification.

## 4. Matched comparison: STOPPED at 6/48 — infeasible under frozen constraints

Design (frozen): 12 tasks × 2 reps × 2 harnesses, AB/BA, fresh containers, sandbox approval, same model/settings, separate 850 budget, health gating active. Runner `docker/m3d-gemma-matrix.sh` with budget-aware ledger (`max(requests, budgetUsed)`) and canary gating (initial triple-probe HEALTHY 0.07 s; periodic gates).

Results (6 cells, then cap exhaustion):

| Cell | NT | Pi |
|------|----|----|
| T01-R1 | PASS ex0 10r | PASS ex0 6r |
| T02-R1 | FAIL ex5 10r | FAIL timeout 498r (448-edit loop, never converges) |
| T03-R1 | PASS ex0 4r | FAIL timeout 700r (698-bash loop, never converges) |

Spent: **1228/850** (NT pre-send enforced per run; Pi post-hoc per design). Matrix halted per protocol — no further cells launched.

Why infeasible, precisely: Pi 1.4.0 has **no turn/iteration cap** (verified via `--help`), and Gemma 4 under Pi does not terminate on these tasks — 498- and 700-request unbounded loops vs the 15-request per-task ceiling, each terminated only by the 1200 s wall timeout (post-hoc `BUDGET_EXCEEDED` FAIL, working as designed). Two Pi cells consumed the entire comparison budget. NT stayed bounded throughout (4–10 requests, decisive exits). Raising the cap or bounding Pi would revise frozen comparison terms — not authorized, not done.

No infrastructure invalidations: provider HEALTHY throughout (0.07 s canaries, fast correct NT runs interleaved). The two Pi FAILs are model×harness-interaction outcomes (counted, preserved), not infra. No safety/authorization/containment regressions: zero denials, zero holds, zero integrity stops; exit codes truthful.

## 5. Four questions

1. **Does Needletail complete coding tasks reliably with a healthy provider?** Partial evidence, leaning positive: 3/3 NT Gemma cells decisive (2 PASS, 1 turn-budget FAIL with the frozen failure shape); provider verified healthy throughout. N too small for reliability claims.
2. **Does remediation genuinely improve outcomes?** Unassessable on Gemma (comparison incomplete). Halogen confirmation evidence stands (4/9 flips, rejection volume halved, node works, no regressions attributable to a defect).
3. **Does the performance gap to Pi persist on Gemma 4?** Task-success gap unmeasurable (comparison incomplete). Reliability gap decisively favors Needletail: NT bounded and decisive on every cell; Pi catastrophically non-terminating on 2/3 cells (timeout FAILs after 498/700 requests).
4. **Failure attribution:** model behaviour (Gemma non-convergence loops under Pi) × harness interaction (Pi: no turn bound → unbounded spend; NT: turn budget bounds waste to ≤ ceiling) × environment (healthy) × infra (none in Gemma runs; one gate bug found and fixed pre-scoring with both-directions verification).

## 6. Budget

True provider spend 1228 (NT 24 pre-send-enforced; Pi 1204 post-hoc-counted per design). All counted; no hidden traffic. The 850 cap functioned as designed (halted new launches). No M3-D Halogen budget touched.

## 7. Recommendation: STOP

Do not run the remaining 42 cells without maintainer acceptance of revised terms, which must explicitly authorize (a) a higher comparison cap AND (b) a Pi turn-bound protocol amendment — both change the frozen comparison and neither is granted. The deliverables stand as: qualified endpoint, eligible task set, 6 scored cells, the Pi-non-termination finding, and the preserved Halogen results. No M4, no rerun, no push/PR/merge.
