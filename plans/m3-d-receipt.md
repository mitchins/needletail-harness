# M3-D Receipt — Docker-executed matched comparison (Needletail vs Pi)

Date: 2026-11-03. Branch `m3-planning`, local only. No push/PR/merge.

## 1. Frozen benchmark identity

- `plans/m3-tasks.json` frozen `2026-11-03 REV5` (12 tasks T01–T12, 2 reps, 2 harnesses, AB/BA order; T09 trigger clarified to first durable tool CALL; no fixture/oracle/budget changes across REVs).
- Protocol: `plans/m3-d-protocol.md`. Docker amendment: `plans/m3-d-docker-amendment.md` (prospective; no results existed when adopted).
- Model/endpoint (both harnesses, via `m3d-forwarder` on internal `m3d-internal` net): `http://192.168.2.216:8731/v1`, `halogen-qwen3.8-flash-next`, same version/template. Forwarder pinned `alpine:3.21`, image `4acb4add598f`.
- Global ceiling 850 scored provider requests. Per-run: checkpoint `max(12, NEEDLETAIL_REQUEST_BUDGET)`, others `NEEDLETAIL_REQUEST_BUDGET`; per-task ceilings (default 15; T08 45); T08/T09 timeouts 3600/1800s.

## 2. Execution images (local builds, IDs)

- `m3d-needletail:1` = `b7c2336bc8aa` (builder `swift:6.4-bookworm@sha256:d1bbd90…`, runtime `node:24-bookworm-slim@sha256:c86ecea…`; production Needletail binary + Swift runtime; no host checkout mounted).
- `m3d-pi:1` = `55e429c5be47` (Pi 1.4.0, `halogen-local` verified, extensions/MCP/context-files off; whole Pi process in-container).
- `php:8.4-cli` = `838e7699f1b5` (digest `sha256:7e7413ed31b8c42b31c939cc83b3758b1cd618f7bf3803f5a0c39f98d4adcbee`), oracle-only, `--network none`.
- Confinement per run: fresh container, disposable `/workspace`, private `/state`, non-root, dropped caps + `no-new-privileges`, read-only root FS, no host/docker-sock mounts, internal-net only (negative probes passed in preflight). Logs/results/diffs/state exported before `rm`.

## 3. Sandbox approval (container only)

- `SandboxPolicyGateway` + launcher-issued immutable grant (`runID/containerID/workspace/allowedTools/allowedExec`, hostname-bound, read-only `/grant` outside workspace). Evaluates the validated `ToolBatch` (args, paths, capabilities, identities), never display text.
- Host policy unchanged: TTY approval retained, `--trusted` untouched, no piped-y.
- Evidence: all 24 NT cells log `sandbox approval policy composed (grant /grant/grant.json…)`; **zero human approvals** for eligible ops; **zero denials** (models stayed in-bounds; absolutely-denied ops never triggered). `SandboxPolicyTests` 17/17 + preflight denial/escape/negative-probe checks pass.

## 4. Matrix results (48/48 verdicts, 364/850 scored requests)

Full per-cell table: `python3 docker/m3d-analyze.py` (raw results under `/tmp/m3d/runs/<TASK>-R<rep>-<harness>/{result.json,stdout.log,stderr.log,workspace diff,state}`; T09 legs `result-leg{1,2}.json`).

| Task | NT R1 | NT R2 | Pi R1 | Pi R2 |
|------|-------|-------|-------|-------|
| T01 | PASS | PASS | PASS | PASS |
| T02 | FAIL¹ | PASS | PASS | PASS |
| T03 | PASS | FAIL¹ | PASS | PASS |
| T04 | PASS | PASS | PASS | PASS |
| T05 | PASS | PASS | PASS | PASS |
| T06 | FAIL¹ | PASS | PASS | PASS |
| T07 | FAIL¹ | FAIL¹ | PASS | PASS |
| T08 | FAIL² | FAIL² | PASS | PASS |
| T09 | PASS³ | PASS³ | PASS⁴ | PASS⁴ |
| T10 | FAIL¹ | FAIL¹ | PASS | PASS |
| T11 | PASS⁶ | PASS⁶ | PASS | PASS |
| T12 | PASS⁷ | PASS⁷ | PASS | PASS |

¹ `budgetExhausted` (exit 5): model burned all turns without converging — model-efficiency failure.
² `providerError: malformedEvent: more than 8 tool calls` (exit 4): model emitted an oversized tool batch; harness hard-fails instead of truncating — model protocol violation + harness brittleness note (M4 candidate).
³ NT legs exited early (task completes in ~9s; no mid-run interrupt landed — honest T09 limitation for the fast harness); leg-2 re-run PASS.
⁴ Genuine mid-run SIGINT after first durable tool CALL (`interruptObserved=true`), resume via `--continue` → PASS. True interruption-recovery data points.
⁶ PASS on oracle artifacts but ended exit 5 (`budgetExhausted`): artifact-complete yet non-converging. 6 of 13 non-T09 NT PASSes (T02-R2, T05×2, T06-R2, T11×2) ended this way vs Pi 24/24 exit 0 — a material asymmetry: NT "PASS" is not run-cleanliness comparable to Pi "PASS".
⁷ Originally FAIL on empty extracted answer; root cause was a harness extractor bug (`nt_final_text` missed the ledger's `_0` wrapping, so ALL NT answers extracted as ""). Model answers on disk contained the expected sha in both reps. Corrected by read-only rescore with the fixed extractor against the frozen oracle (no container re-run, no provider calls), marked `rescored-no-new-traffic`.

Totals: **Needletail 15/24 (62.5%), Pi 24/24 (100%)**. NT wins/parity cells: T01, T04, T05, T09, T11, T12 (12 cells). All 9 NT FAILs classify as model-side (7 turn-budget exhaustion, 2 oversized-batch protocol violations) on evidence; the single harness-side scoring error found (T12 extractor) was corrected read-only and is marked. T02-R1-nt's oracle record retains `.needletail/` byproduct noise in its untracked list, but its FAIL is sustained independently by model-created `_probe.py` plus exit-5 non-convergence. No reruns to improve scores; cells marked `rescored-no-new-traffic` were rescored without new provider calls after scorer fixes, per protocol.

Efficiency (scored means over 48 runs): NT ~2–3k in-tokens per request with full-transcript re-send vs Pi ~1–3k per run compact; NT wall 18–156s, Pi 8–254s. Container overhead not separated (single-digit seconds against task walls; recorded as-is).

Checkpoint (M3-C carryover, T04/T05-class runs): capture/rollover costs included in scored totals; cache metrics UNKNOWN (provider exposes no cache counters) — savings unproven, as declared in M3-C.

## 5. Budget accounting

- Scored provider requests: **386 / 850** = 364 verdict-bearing + 22 T09 leg-1 (scored spend, no verdict weight). Analyzer prints the split.
- Diagnostic allowance: 10/10 spent (pre-scoring).
- Voided spend counted against the ceiling per the amendment: ~12 (stale-image T01-R1-nt/T02-R1-nt, discarded as harness-invalid). REV-voided T09 attempts are unquantified-small (crashed Pi legs spent 0; NT voided leg files were deleted with their run dirs — a bookkeeping gap, bounded by per-task ceilings).
- Accounted total ≈ 408, well under 850. No cap exceeded; per-task ceilings enforced pre-call; Pi counted post-hoc, abort-on-exceed armed (never tripped).
- No Halogen cache clears; shared-cache state observational only.
- REV note: REV5 (T09 trigger clarification) postdates the first scored run, but all REV2→REV5 changes were scorer/procedure-only — fixtures, oracles, budgets byte-stable — and only T09 cells were voided (no valid interruption had ever been delivered). Disclosed, not post-result tuning.

## 6. Known limitations

- T09 interrupt never landed mid-run for NT (task too fast); NT T09 = idempotent re-run, not a recovery test. Pi T09 is genuine.
- T08 NT failure exposes harness brittleness (>8 tool calls = hard fail); protocol-correct behavior is model-side, but graceful truncation is future work.
- Token/wall asymmetry partly reflects harness verbosity (NT full-transcript re-send), not just model quality. NT PASS ≠ clean run (see ⁶).
- Model-reported exec-gate friction appears once (T12-R2-nt final text: several argv/cwd rejections before one command passed); the run still PASSED — anecdote, not a counted finding; validator strictness stays as-is.
- Cache benefit remains unproven (UNKNOWN); checkpoint value shown is correctness/epoch-hygiene, not measured savings.
- T08 oracle asymmetry is by design (NT must demonstrate REDUCED/NOT-APPLICABLE context reduction; Pi defaults NOT-ASSESSED) — T08 tests the checkpoint feature, which Pi lacks. Moot for these cells (both NT T08 failed before answer stage).
- Single model version, single day, 2 reps — wide confidence intervals; paired design mitigates but does not eliminate noise.

## 7. Verdict data location

Per-cell evidence: `/tmp/m3d/runs/` (must be archived before any cleanup). Analyzer: `docker/m3d-analyze.py`. Scorer: `docker/m3d-run.py` (+ `m3d-matrix.sh`, `m3d-seed.py`, `m3d-config.json`). Amendment history: git log on `docker/` + `plans/m3-d-*`.
