# M3 Milestone Report — Checkpoint + matched comparison

Date: 2026-11-03. Branch `m3-planning`, local only. No push/PR/merge (awaiting review + CI).

## 1. What M3 set out to prove

M3 hypothesis: Needletail's checkpoint/epoch mechanism (M3-C) delivers reliable long-run state hygiene, and the Needletail harness + model is viable against a matched Pi baseline (M3-D) under a frozen benchmark.

## 2. M3-A / M3-B / M3-C (carried in)

- M3-A qualified `7c3d4f8`; M3-B complete `cc4e197` (31/40 budget).
- M3-C QUALIFIED: capture/validation/tail-cut, atomic publication with `parentEpochID`, denial/commit/fail paths, throwing `checkpointLedgerFacts`, full-field transcript projection. `M3CCheckpointTests` 18/18, `D3IntegrationTests` 15/15, `LiveRequestBudget` 7/7. Live Halogen rollover: exit 0, 5/12 budget. DeepSeek pre-live NEEDS-CHANGES → all fixed → READY TO CLOSE. Committed `9bdfd94` (`24dc471`), receipt `plans/m3-c-receipt.md`.
- Carried limitation: cache savings unproven (provider exposes no counters; metrics UNKNOWN).

## 3. M3-D method (frozen + Docker amendment)

- Benchmark `plans/m3-tasks.json` REV5 frozen 2026-11-03: 12 tasks, 2 reps, 2 harnesses, AB/BA, 48 runs, 850-request global ceiling. No results existed when the Docker amendment (`plans/m3-d-docker-amendment.md`) was adopted → prospective methodology change, not tuning.
- Both agents containerized (images §2 of M3-D receipt), fresh container/run, disposable workspace, private state, non-root, dropped caps, read-only root, internal-net-only via forwarder (negative probes passed). Same model/version/template both sides.
- Needletail unattended approval via launcher-issued immutable sandbox grant evaluating the validated `ToolBatch`; host TTY policy unchanged. Zero human approvals, zero denials in scoring. Pi run whole-process in-container with matched fixtures/endpoints/budgets.

## 4. Results

**Needletail 15/24 (62.5%) vs Pi 24/24 (100%).** Full table + failure classes in `plans/m3-d-receipt.md`.

- NT wins/parity: T01, T04, T05, T09, T11, T12 (12 cells).
- NT losses: 7 turn-budget exhaustion (T02-R1, T03-R2, T06-R1, T07×2, T10×2), 2 oversized tool batch hard-fails (T08×2).
- One harness-side scoring error found and corrected (T12 answer extractor; read-only rescore, marked).
- Material asymmetry: 6 of 13 non-T09 NT PASSes ended exit 5 — artifact-complete but non-converging — vs Pi 24/24 exit 0. NT "PASS" is not run-cleanliness comparable to Pi "PASS".
- All 9 NT FAILs classify model-side on evidence; one harness-brittleness finding (T08 >8-call hard fail; graceful truncation = future work) plus one corrected harness scoring bug (T12 extractor).
- Efficiency: NT ~2–3k in-tokens per request with full-transcript re-send vs Pi ~1–3k per run compact; NT walls mostly lower per run but success-gated — and 6 NT passes burned full turn budgets anyway.
- T09: genuine interrupt-recovery demonstrated for Pi (SIGINT after first tool CALL → `--continue` → PASS ×2); NT task too fast to catch (documented limitation).
- Budget: 386/850 scored (364 verdict-bearing + 22 T09 leg-1), 10/10 diagnostic, ~12 voided counted per amendment ≈ 408 accounted. No reruns, no cache manipulation.

## 5. Safety evidence (approval policy)

Sandbox grant path active in all 24 NT cells; no human approvals; no denials; absolutely-denied ops never triggered. `SandboxPolicyTests` 17/17; preflight denial/escape/negative-probe suite passed; host TTY behavior unchanged; focused review findings fixed pre-scoring. Container images unprivileged, no host/docker-sock mounts.

## 6. Model-vs-harness classification

| Class | Cells | Owner |
|---|---|---|
| Turn-budget exhaustion without convergence | T02-R1, T03-R2, T06-R1, T07-R1/R2, T10-R1/R2 | model efficiency |
| Oversized tool batch (>8 calls) | T08-R1/R2 | model violation; harness truncation missing (M4) |
| Interrupt recovery | T09 Pi ×2 genuine; NT ×2 degenerate (fast task) | harness limitation noted |

## 7. Known limitations (carried + new)

M3-C cache savings unproven; T09-NT degenerate; T08 truncation missing; NT transcript verbosity inflates tokens; single model/day, 2 reps (wide CIs); container overhead not separated.

## 8. Recommendation: CONDITIONAL (proceed to M4 with conditions)

Rationale: the checkpoint mechanism is qualified and the sandbox/Docker methodology is sound and evidenced — the comparison itself is the success of M3-D as an instrument. But the headline outcome (15/24 vs 24/24, all NT losses model-side efficiency/robustness) does not support an unqualified viability claim for the current harness+model pairing on this task class.

Conditions for M4: (a) turn-efficiency work (transcript compaction for re-send bloat; progress-aware budgeting); (b) graceful oversized-batch truncation instead of hard fail; (c) re-run the frozen matrix (new REVs only for harness changes, fixtures/oracles untouched) to confirm gains; (d) keep Docker/sandbox methodology and zero-human-approval discipline.

STOP respects: no M4 started, no push/PR/merge. Required before merge recommendation: final implementation/CodeRabbit review + normal CI qualification.
