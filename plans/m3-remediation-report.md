# M3 Post-Benchmark Remediation Report

Date: 2026-11-03. Branch `m3-planning`, local only. No push/PR/merge.
Scope: the three demonstrated M3-D issues + CLOSURE_10. No benchmark scoring, no oracle/fixture changes, no rescoring of the frozen matrix. Sandbox execution architecture preserved and untouched.

## 1. Diagnostic method (frozen evidence)

All 48 frozen run dirs under `/tmp/m3d/runs/` were mined read-only: per-turn tool calls, preDispatch rejections, and outcomes from NT ledgers; Pi JSON traces for the matched cells. The 15 NT cells of interest (7 exhausted FAILs, 6 exit-5 PASSes, 2 T08 exit-4s) yielded **101 tool-failure outcomes** — the complete waste surface. (Erratum 2026-11-04: first stated as 100 with a category table summing to 102. Re-mined from the preserved GRDB ledgers — `operationResult` rows with `tool-failure` outcomes across the 15 cells, mutually-exclusive reason-text buckets — the ground truth is 101: 100 validation rejections plus 1 execution-time directory open. The table below is corrected; the R1/R2 remediation mapping is unchanged.)

Pi contrast (same tasks): 6–11 turns, 8–14 tool calls per run, **zero rejections** — `bash` for everything, one edit (3 for T11), natural paths. NT same cells: 10–19 calls with **30–60% preDispatch rejections**, learning path conventions by trial per run.

## 2. Turn efficiency — model vs harness split

Categorized all 101 rejections (reason text + arguments, callIDs stripped):

| Category | Count | Owner | Remediation |
|---|---|---|---|
| `search "."` (root search spelled dot) | 25 | harness | R1: normalize to root search |
| `search ""` (empty path) | 8 | harness | R1: empty = root search |
| `/workspace/…`-prefixed paths (prompt-induced) | 8 | harness | R1: strip exact prefix |
| `argv[0]` bare basename == executable basename | 11 | harness | R1: rewrite argv[0] |
| exec `cwd` dot/empty forms | 4 | harness | R1: dot cwd = root |
| node binaries blocked by 64 MiB hash bound | 3 | harness | R2: 256 MiB unified bound |
| bare executable names (`node`, `git`, …; no PATH search) | 14 | deliberate boundary | kept (message improved) |
| nonexistent absolute guesses (`/usr/bin/git`, …) | 10 | model (friction-contributed) | kept; better guidance text |
| bare absolute paths (`/`, `/etc/passwd`-class) | 8 | deliberate boundary | kept (wrong-file trap) |
| control bytes / bad argv shape / missing hash | 7 | deliberate boundary | kept |
| read of workspace root / directory open | 3 | correct rejection | kept, clearer message |

Harness-shape waste: **~60 of 101 rejections** (R1-normalizable 56 + R2 3 = 59); the rest are deliberate boundaries or model-side. Estimated turn saving where the model behaves identically: up to ~40% fewer wasted calls on path-heavy tasks. Not claimed as a score delta — the model adapts per run.

**Replay check (unscored, frozen arguments through the remediated validator): 62/101 now validate** (read 7, search 29, exec 26); with the `""`-means-root addition, ~69/101. Residual 30+ are deliberate rejections (bare executables, bare absolutes, control bytes, missing hash) or model-side wrong-path guesses. (Numerators from the original replay run against the mined set; denominator corrected to the re-mined 101.)

## 3. Fixes

**R1 — Path normalization + argv[0] rewrite** (`ToolValidator.normalizeWorkspacePath`, `baseName`; wired into validateRead/Search/Edit/Write, exec cwd, `parseExecArguments`, and the executor `executeOne` funnel so validation and execution agree — no split-brain). Normalizes only unambiguous root spellings (`.`, `./x`, `/workspace/x`); bare absolutes still fail loudly (wrong-file trap); inner dots still fail; bare argv[0] rewrites only on exact basename match; bare executable names still require absoluteness (no PATH search). Tests: `R1_pathNormalization`, `R1_normalizedPathsValidate`, `R1_argvZeroRewrite`, `R1_executorAgreesWithValidation` (B1).

**R2 — Exec hash bound 64→256 MiB**: root cause of node unusability (node 126 MB). Found a SECOND, independent gate at spawn re-verification (`ExecRunner`, "executable too large") — the live probe caught it. Both gates now reference the single `ExecArguments.maxExecBytes` / `maxExecAggregateBytes` (256/512 MiB); they cannot drift again. Tests: `R2 identity hash bound…` value-pin (C0), `R2_largeInterpreterResolves` (100 MiB sparse binary through the production resolver, B1).

**R3 — Oversized batches**: terminal exit-4 → bounded typed rejection + continuation. Provider tags the assembly failure with the single-definition marker `oversizedBatchMarker` (+ exact bound for the model notice); the reducer relays it as a `.user("[harness notice] …")` message and re-requests (max 2 continuations/run, turn budget still consumed, else terminal as before). No batch existed, so no intents/results to reconcile; the verdict still comes from the oracle. Tests: 5 in `OversizedBatchTests` (continue, bound, non-marker untouched, past-budget still exhausts, counter resets on admission); `WireLoopbackTests` updated to the new contract.

**R4 — Quiescent-at-boundary completion**: the 6 exit-5 PASSes' demonstrated defect (finishing turn consumes the last turn → `budgetExhausted` mislabels a quiescent run). The four after-batch continuations now land `.completed` (telemetry `completed-budget-boundary`) via the normal queue-draining path when the batch fully resolved; unknown outcomes still hold the queue (`completed-held`); mid-pipeline budget guards (validation/denial/resolution/credential — model never saw results) still fail terminally. Tests: `BoundaryCompletionTests` ×3; `B0SpineTests.budgetExhaustionPreserves` and `BudgetInvalidTests.CORE_04_turnLimitStops` updated to the deliberate policy change (still no 81st request).

**CLOSURE_10** (pre-existing failure, reproduced on clean baseline): unprotected non-UTF-8 search matches were silently dropped — a recall defect, not a security requirement. Lossy skeletons in unprotected paths are now surfaced (U+FFFD path, exact match text); grantable+lossy still drops (approval-collision guard); undecodable base64 still fails closed. This forced a deliberate refinement of `B2ReadSearchTests.searchProtectedUnicodeLossy` (same scenario, opposite expectation): updated to the split policy with rationale + a grantable-lossy counterpart — not a blanket skip. Full `./dev test quick` now green, including CLOSURE_10.

## 4. Before/after evidence (unscored diagnostics, remediation image `3b2f8f0731d5`)

- **Node probe**: `/usr/local/bin/node --version` → `v24.22.2`, exit 0 (was: unresolvable in scoring, then spawn-refused pre-twin-fix). Both gates agree.
- **T02-shape rerun** (was: exit-5 FAIL): exit 0 with `completed-budget-boundary`; normalization engaged live (`search /workspace`, `search .` proceeded; `read /workspace` rejected with the clearer message); batch-level attribution unchanged. Oracle FAIL (model didn't converge this instance — n=1, variance, not a score claim).
- **T08-shape rerun** (was: terminal exit-4 on turn 1): **PASS exit 0**; the R3 notice fired live once (`oversized notices: 1`); zero shape rejections; model terminated cleanly (`completed`, not boundary); checkpoint flow ran. n=1 — mechanism demonstration, not a score claim.
- Replay: 62→~69/100 frozen rejections now validate; residual are deliberate boundaries.

Diagnostic spend: 10 (T02) + 3 + 2 (probes) + 17 (T08) = 32 requests; accounted total ≈ 440/850. No matrix cells touched; diagnostics live under `/tmp/m3d-remediation/` with UNSCORED markers.

## 5. Test deltas (all deliberate, each with rationale)

- Updated (policy changes, not relaxations): `B0SpineTests.budgetExhaustionPreserves`, `BudgetInvalidTests.CORE_04_turnLimitStops` (R4 landing), `B2ReadSearchTests` lossy section (R2 split policy), `WireLoopbackTests` oversized message (R3 contract).
- New: R1 ×4 (B1), R2 ×2 (B1+C0), R3 ×5, R4 ×3.
- Pre-existing flakes (reproduced on clean baseline, serial and parallel): full-suite `NeedletailActorTests` yield-budget timeouts (pass in small-filter runs on both versions), `TOOL_08_replaceSuccess` + C1/CLOSURE_14 timing flakes under parallel load (pass alone). Not caused by this change set; not modified.

## 6. Remaining risks

- R1 normalization widens accepted spellings; the bare-absolute refusal is the load-bearing guard against wrong-file traps — covered by RED tests, but review the exact-prefix rule (`/workspace2` must not strip) on every future validator change.
- 256 MiB hashing costs ~1–2 s per unique executable per batch; cross-turn re-hashing is accepted (cross-turn caching would weaken the TOCTOU binding). Watch turn latency on node-heavy tasks.
- R3/R4 add run-continuation paths: both bounded (2 continuations; budget still consumed; unknowns still hold). The boundary `completed` phase is oracle-neutral by construction, but any future consumer of `completed` that assumes model-finalization must key on the event kind.
- Model-side waste remains dominant (wrong-path guesses, redundant searches, non-termination): harness can only reduce friction, not enforce convergence. Exit-5 FAIL→completed relabeling changes exit codes for 7 historic FAIL cells if re-run — verdicts unchanged (oracle FAIL stays FAIL).

## 7. Confirmation-run recommendation

**Yes — a frozen-matrix confirmation run is warranted**, but scoped, not full: re-run the 9 historic NT FAIL cells + T02-R2/T05/T06-R2/T11 (the exit-5 PASS cohort) with the remediated image under the existing Docker amendment (no fixture/oracle/prompt changes; same ceilings; results recorded separately, never merged into M3-D). Expected signal: fewer shape rejections per ledger, node-based verification appearing in traces, R3/R4 markers where triggered, and any PASS flips decided by the frozen oracles. If ≥2 flips or rejection-rate drops >30% with no new failure modes, promote the remediation to the M4 baseline; otherwise keep it as diagnostic evidence only. Estimated cost: ~150 requests, inside the 850 ceiling headroom.
