# M3 Plan — real local coding, checkpoint and viability (lean, planning only)

- Baseline: `main` @ `1ab0aa4` (M2-D merged, tree `04cc08b` identical to qualified `9c402f1`). Local planning branch `m3-planning`.
- Authorization boundary: **planning, local documentation and independent plan review ONLY.** No live model traffic, no inference-server start/stop/reconfigure, no push/PR/merge, no M4. Live probing waits for explicit operator approval of alias/origin and synthetic traffic.
- Contract sources: COMPLETE-SPEC.md Part 8 MILESTONES M3 (¶1336–1354), Part 6 epoch / checkpoint / tool contracts, DEPENDENCIES.md, `plans/m2-d-m3-readiness.md` (10/10 preflight implemented, tested, not yet live-qualified), ACCEPTANCE.md CACHE/REAL cases, `cases/catalog.json`.
- Reuse: `NeedletailCLI` composition root, `NeedletailCore` SessionState/Transition/Actor, `NeedletailRuntime` NativeToolExecutor + GRDB store + SessionExport, `NeedletailProviders` Chat Completions transport, existing `doctor --probe`. No new agent framework, scheduler, memory, terminal UI, or dependency.

## 0. Preflight (read first)

`plans/m2-d-m3-readiness.md` documents 10 must-haves already implemented but not live-qualified: 5-tool authorization, exec receipts, durable file preimages, queue replay/unknown holds, attachment privacy, undo journal, notice ordering, quiescence, fencing, provider continuation (all synthetic). M3 qualifies them against a real local model instead of re-implementing. Track live-qualification separately from scripted evidence; never conflate.

Current local endpoint probe (1 Nov 2026, no probing performed):
- Operator config `examples/config.local.json`: alias `local-coder`, origin `http://127.0.0.1:11434`, protocol `openai-chat-completions`, served model `example-local-model` (example), locality `local`, `request_options.temperature 0.2`.
- Live check: no listener on `127.0.0.1:11434` (`ss` shows docker/wireguard listeners only; `curl` empty); `ollama` not installed; `~/.config/needletail/` absent. Historical endpoint note is not live verification. Missing authorization: operator must confirm exact alias/origin/model expectation before probing.

## 1. Goal

Qualify the M2-D machine against a genuinely running local model, then measure the existing checkpoint design and compare against Pi — all on the durable session path — and stop for the maintainer's viability decision.

**In scope:** M3-A (bind + probe), M3-B (real five-tool loop on scratch repo), M3-C (two-phase checkpoint measure), M3-D (12-task matched Pi comparison). **Out:** terminal polish, macOS qualification, cloud routes, model downloads, server reconfiguration, M4.

## 2. Slices (dependency order A→B→C→D)

### M3-A — Existing local endpoint qualification (Small)

- Identify the exact operator-configured alias/origin/served-model expectation (authorize `local-coder` @ `http://127.0.0.1:11434` or the operator-supplied alternative; record redacted alias/origin/model in plan, full detail in local evidence only).
- Check existing `doctor --probe` and Chat Completions transport capabilities: endpoint policy, deadlines (`connect 10s`, `read-idle 300s`, `request 1800s`), bounded intake, SSE bounds, classified failures (use synthetic, non-private prompts; no repo content). Existing CLI exposes `doctor --probe MODEL` (`Sources/NeedletailCLI/DoctorProbe.swift:15-18` guard + `Sources/NeedletailProviders/ProbeRoute.swift:34-42` fixed packet); additional shapes are exercised via the existing `ChatCompletionsTransport`/`SessionActor` harness, not via new `chat --dry-run-*` flags.
- Prepare bounded synthetic prompts for: single-turn text, streaming, tool-call proposals, cancellation, continuation (native continuation blocks preserved, not flattened), **plus numeric-string model-ID preservation and multi-turn replay fidelity** (REAL-01). Keep prompts deterministic, input-bounded, and reviewable. Shapes beyond `doctor --probe` run as a thin M3-A harness driving `ChatCompletionsTransport` directly (bounded output, no repo content), reusing the M1-C adapter — no new product CLI.
- Capture fingerprints where available once probing is authorized: served model ID, server identity/header, template/capability fields. Unknown fields stay `unknown` (do not infer from label or `/models`).
- No inference-server changes, model downloads, fallback routes, or interference with other sessions. `I09` local-only routing never silently becomes cloud.

Exit: authorized probe record with alias/origin/model/fingerprint (or explicit unknown) + at least one successful synthetic Chat Completions round-trip per shape above via the existing probe/harness; transport bounds honored; no live coding task yet. Cases: `NET-06` live half, `WIRE` live half, `REAL-01` replay fidelity.

### M3-B — Real five-tool coding loop (Medium)

- Run Needletail against a **disposable scratch repository** (temp dir, git init, no operator workspace) and the authorized running local model from M3-A, **isolated from operator durable state via `NEEDLETAIL_STATE_DIR` pointing at a temp store** (default `RunCommand` store `Sources/NeedletailCLI/RunCommand.swift:297-309` would otherwise mix scratch runs with the operator's ledger and cross-run holds `718-777` could block them). Scratch runs also use interactive TTY approval for ask-gated `exec` (no implicit grant).
- Verify real model-driven invocations of all five native tools: `read`, `search`, `edit`, `write`, `exec` (exec only on explicitly approved `ask`-gated operations; existing `ExecIdentityResolver` + per-call grant). No scripted provider responses may count toward this gate.
- Use the existing native tool executor and durable session path (GRDB store, operation intents/results, change groups, preimages) **within the isolated store**. Keep every diff, request `toolCall`, tool receipt, test output, and failure classification (denied/invalid/timeout/cancelled/failed). User edits remain preserved (undo eligibility still governs).
- Preserve exact execution boundaries: no `--trusted` shortcut, no implicit exec approval, no unsupervised host commands. `trusted-exec` only via explicit operator grant bound to canonical root identity.
- Tasks are bounded, small, and undoable where the ledger permits; shell effects remain explicit (disclaimer notice). No arbitrary project optimization or long-horizon tasks that would obscure loop correctness.

Exit: at least one real-loop session per tool class with retained receipts + at least one bounded multi-turn task whose file edits + test run are model-driven (not canned); existing D3/M2-C lanes stay green. Cases: `REAL-*` coding loop subset.

### M3-C — Two-phase checkpoint (Medium)

Implement/qualify the already-designed contract (SPEC §7, no new design). **Composition path:** existing `needletail run` always mints a fresh session `Sources/NeedletailCLI/RunCommand.swift:468` and `session` is export-only; checkpoint does **not** reuse that path. Instead, a bounded `SessionActor.checkpoint` / `SessionTransition.checkpoint` operation (new, analogous to undo's write-ahead journal) branches the **existing native history** from the M3-B scratch session's GRDB ledger, blocks tool execution in the executor during the probe, validates, and transactionally publishes the new epoch pointer while retaining the original history via the `epochs.parent_epoch_id` link (no mutation of old rows). The current `SessionActor.checkpoint` stub `270-272` / `SessionTransition` 1293-1319 is extended to this branch/validate/publish transaction; no new CLI beyond the checkpoint entry point is invented.

1. **Phase A — capture a warm checkpoint:** at a safe quiescent boundary (no in-flight tool/stream, no unresolved outcome, no deliveryUnknown), branch the native conversation, append a bounded checkpoint instruction, and **block actual tool execution in the executor** (do not change `tool_choice`). Validate returned JSON shape (`task_goal`, `user_constraints[]`, `completed_work[]` with evidence IDs, `current_files[]` with `path+hash+seq`, etc.) and merge operator-pinned constraints locally. On malform/timeout/cancel/missing evidence/disk-full, old epoch remains active.
2. **Phase B — publish a shorter epoch:** build new epoch from base + validated checkpoint + pinned constraints + bounded recent tail (no cut of `call` from `result`), transactionally commit checkpoint + epoch pointer only after artifacts durable; retain original history recoverably (reversible, not mutated — parent link preserves it).

Measure separately and report honestly: (a) checkpoint-generation latency + actual cache reuse, (b) first new-epoch prefill latency + reuse, (c) subsequent warm requests, **(d) total time/cost over the whole checkpoint transition** (`SPEC §7.2` ¶346). Do not claim reuse from prefix equality alone; observe provider-reported cache fields where available — current `ChatAssembly` only exposes prompt/completion tokens `Sources/NeedletailProviders/ChatAssembly.swift:106-109` so cache reuse will be `unknown` unless provider cache fields are captured and wired through, which this slice adds as observable (not inferred).

Failed/cancelled/tool-only checkpoint and queue-interaction legs are required.

Exit: one successful warm checkpoint + rollover on a real native history (from M3-B scratch tasks) with retained artifacts; four numbers (a–d) plus failure/cancel legs green. Cases: `CACHE-01..10,12` (explicitly defer `CACHE-11` + `CACHE-13` consultation cases to M5 per `COMPLETE-SPEC.md:1170,1631-1633`).

### M3-D — Pi comparison and viability decision (Small + measurement discipline)

- Freeze the specified **12-task** comparison **before running as `plans/m3-tasks.json`**: each entry lists prompt, repo template SHA, exact oracle (e.g., exact edit conflict, test repair green, quoted identifier preserved), and required receipt fields. No basket/oracle change after observing results.
- Use the **same actual model, inference server, and comparable settings** (alias/origin/model, temperature 0.2, context/output limits, deadlines) for Needletail and the installed Pi baseline. Record installed Pi/server versions and comparable invocation (same scratch repo template per task).
- Run **paired repetitions, 2 matched runs per harness per task** (24 runs per harness), fixed budgets (80 turns / 4h per run per spec), **counterbalanced harness order (AB/BA per pair), cold/warm request tagging, and honestly observational cache state** — never evict another session's cache to force a cold start (`COMPLETE-SPEC.md:1670`), report `REAL-03` cold/warm as observed, not controlled. Record completed-task evidence, tool failures, tokens, cache observations (honest, `unknown` where not reported), and end-to-end latency. Do not cherry-pick successes or count repeats as independent tasks; repeats are variance controls.
- Do not change evaluation criteria after results; preserve raw logs (requests, diffs, receipts, outputs) for audit. A scripted success is not counted as a real-model success.

Exit: frozen `m3-tasks.json` + paired-evidence table + benefit/cost report covering correctness (completed tasks with receipts), tool-failure classes, token/turn cost, cache observations (honest), and latency; `MILESTONES.md` exit fulfilled. **STOP for viability decision** — M4 not automatically authorized.

## 3. Constraints carried from M2-D readiness

- Reuse existing CLI/Core/Runtime/Providers; no framework, scheduler, memory, or terminal invention.
- Model privacy + explicit endpoint routing intact (`I09`, `I15`); no fallback to cloud, no silent origin change.
- Do not probe `127.0.0.1:11434` (or any origin) until operator explicitly approves alias/origin and synthetic traffic. Do not restart/reconfigure any inference service.
- No live coding tasks yet (M3-A/B require authorized running server); never conflate scripted-test evidence (`C2ExecDurableTests` 41, `C3ExecQualificationTests` 18) with real-model qualification.
- Keep unknown capabilities unknown; do not infer tool support, context size, or cache behavior from labels or `/models`.

## 4. Evidence mapping

| Slice | Cases | Tier |
|---|---|---|
| M3-A | `NET-06` live, `WIRE` live, `REAL` probe | native transport + `doctor --probe` (synthetic, bounded) |
| M3-B | `REAL-*` coding loop subset, `TOOL`/`PROC` live legs | real model + native executor on scratch repo + GRDB receipts |
| M3-C | `CACHE-01..10,12` checkpoint (11/13 deferred to M5) | real model, two-phase branch/block/validate/publish, 4 metrics incl total transition |
| M3-D | `REAL`/`CACHE` comparison set (`plans/m3-tasks.json` 12 tasks ×2, counterbalanced, observational cache) | paired real runs, frozen oracles, retained receipts |

M2-D lanes preserved throughout: `NeedletailStateTests` 180, `Undo*` 53, `D3IntegrationTests` 15, etc.

## 5. Smallest executable M3-A qualification procedure (requires operator authorization first)

```sh
# 1. Operator authorizes exact alias/origin/model (example below is from the repo example, not yet authorized).
# Expected: alias=local-coder origin=http://127.0.0.1:11434 model=example-local-model locality=local
# If operator supplies different alias/origin/model, use that verbatim and record it.

# 2. With authorization, probe once via existing CLI (bounded, synthetic):
needletail doctor --probe local-coder
# Captures: endpoint, server identity, model ID, template/capability fingerprint; unknown stays unknown.
# Doctor's probe is the only existing CLI probe path (single fixed packet). Additional shapes below
# are exercised via a thin M3-A harness driving the existing ChatCompletionsTransport/SessionActor
# with bounded synthetic prompts — no new product `chat` CLI invented.

# 3. Synthetic transport shapes via harness (bounded output, no repo content, NEEDLETAIL_STATE_DIR isolated):
#   - text: single-turn user text -> assistant text
#   - streaming: incremental delta + usage + bounded intake verification
#   - tool-call: assistant proposes read/search/edit/write/exec, validate schemas, no execution unless approved
#   - cancellation: midpoint cancel, verify no resurrect
#   - continuation: second turn preserving native blocks from first (REAL-01 numeric-string + multi-turn replay fidelity)
# Each shape runs against the authorized alias/origin with temperature 0.2, same deadlines as deployed, and records raw payloads + fingerprints.
```

All steps are no-ops until the operator says "probe `local-coder` @ `http://127.0.0.1:11434` with synthetic traffic is authorized." Do not execute before that. Scratch harness sets `NEEDLETAIL_STATE_DIR=/tmp/m3a-$UUID` to avoid operator store contamination.

## 6. Missing operator authorization

- Explicit approval to probe `local-coder` @ `http://127.0.0.1:11434` (or the true provisioned alias/origin) and to send the bounded synthetic prompts above. Without it, M3-A/B/C/D remain planning only.
- If a different local alias/origin/model is provisioned, its exact values.
- Confirmation that synthetic traffic may be sent and that no inference-server restart/reconfigure should be performed.

## 7. Review plan

One focused DeepSeek planning review of this plan. Check blockers: missing real-model composition, unsafe exec approvals, incorrect provider assumptions (prefix-equals-cache, etc.), invalid Pi comparisons, or cache measurement errors. Address substantive blockers/majors; avoid wording rounds.

## 8. Stop condition

At M3 completion, stop and return the report for the maintainer's viability decision. Do not start M4 (terminal/PTY, macOS, cloud) without explicit continuation.
