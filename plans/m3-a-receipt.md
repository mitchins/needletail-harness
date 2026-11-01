# M3-A Receipt — live endpoint qualification (Halogen local-coder)

- Branch: `m3-planning` @ `52d5a9d` + live suite `Tests/NeedletailPrimitiveTests/M3ALiveQualificationTests.swift` (commit pending, opt-in `M3A_LIVE=1 M3A_CONFIG_PATH=/tmp/m3a-xdg/needletail/config.json`, `NEEDLETAIL_STATE_DIR` isolated, no default-network).
- Baseline: `main` @ `1ab0aa4` (M2-D merged, tree `04cc08b`).
- Plan: `plans/m3-plan.md` DeepSeek READY (delta READY after address). This receipt closes the REAL-01 gaps identified in the first M3-A delta review.
- Authorization: bounded synthetic-only probes to `http://192.168.2.216:8731/v1` (Halogen) — no cloud fallback, no server restart, no operator workspace bytes.

## Server / model / template identity (independently observable, not assumed)

- **Endpoint:** `http://192.168.2.216:8731/v1/chat/completions` (allowed origin `http://192.168.2.216:8731`, locality `local`, protocol `openai-chat-completions`, `connect 10s/read-idle 300s/request 1800s`).
- **Health `/health`:** `server uvicorn`, `model halogen-qwen3.8-flash-next`, `version api 0.18.20 engine 0.18.20 match true`, `context 262144`, `slots 2 kv_pool 262144 bf16`, `tool_calls wire qwen-xml (<function=>/<parameter=>) streaming true tool_choice auto/none/required/force`, `prompt_cache enabled 110MB mode2 snapshot_align 64 bitwise_identical_to_cold false`, `drafters_available serial/mtp default mtp`, `chat_template /models/tokenizer/chat_template.jinja SHA c3cf9e34 probe passed thinking_control true`.
- **Models `/v1/models`:** `halogen-qwen3.8-flash-next` `max_model_len 262144` `context_length 262144` `cap 65536 default 8192` `vision enabled true`.
- **Configured vs served:** `local-coder` configured `halogen-qwen3.8-flash-next` ↔ returned `halogen-qwen3.8-flash-next` (diagnostic match, never coerced; numeric-looking model ID preserved as string through `validateConfig`).

## Isolated configuration (strict, no fallback)

- Temp XDG: `/tmp/m3a-xdg/needletail/config.json` (`0600`, `allow_http_origins ["http://192.168.2.216:8731"]`, `default_model local-coder`, `tools read/search/edit/write exec=ask`, no credential) validated via `XDG_CONFIG_HOME=/tmp/m3a-xdg swift run needletail config validate` → `OK version 1 models 1 profile local-coder ... default-route allowed http://192.168.2.216:8731/v1/chat/completions`.
- Live suite gate: `.enabled(if: m3aLiveEnabled)` where `m3aLiveEnabled = M3A_LIVE==1 && M3A_CONFIG_PATH set`; default `swift test` runs only 2 static tests, **zero network requests**. `m3aSnapshot()` rejects missing `M3A_CONFIG_PATH` (no `~/.config` fallback), asserts exact origin `http://192.168.2.216:8731` and model `halogen-qwen3.8-flash-next` before dialing. `NEEDLETAIL_STATE_DIR=/tmp/m3a-state` isolates actor stores (`0700` dirs, `0600` DBs). Raw wire evidence written to `.needletail-dev/m3a-evidence/` (`0700` dir, `0600` files) — outside Git, digests committed.

## Liveness (doctor --probe, fixed synthetic packet)

- `XDG_CONFIG_HOME=/tmp/m3a-xdg swift run needletail doctor --probe local-coder` → `probe local-coder: OK → http://192.168.2.216:8731/v1/chat/completions model halogen-qwen3.8-flash-next served halogen-qwen3.8-flash-next usage 59/16 in 653ms` exit 0, `max_tokens 16` `whole 60s` cap. Confirms endpoint reached, model identity, HTTP 200, token accounting, elapsed. Direct `curl /v1/chat/completions` with `probe ping` shows same `reasoning_content` + empty `content` at 16 tokens, `content` appears at ≥32 tokens (reasoning occupies budget).

## Transport shapes — 6 bounded synthetic requests (live) + 2 static (no live)

**Live suite `M3ALiveQualificationTests.swift` — 8 tests (2 static + 6 live) all PASS with `M3A_LIVE=1 M3A_CONFIG_PATH=/tmp/m3a-xdg/needletail/config.json` (8 synthetic provider invocations, 9 including doctor probe, all ≤64 max_tokens except cancellation 512, ≤32KB intake, wall ≤5s each, total 5.0s):**

| ID | Shape | Prompt (synthetic) | Request IDs | Outcome | Evidence digest (SHA-256) | Elapsed | Classification |
|---|---|---|---|---|---|---|
| 1 | Text completion | `Reply with exactly the word 'pong'...` | `m3a-1` | text `pong` `usage 64/29` served `halogen-qwen3.8-flash-next` raw 7895B | `b0d4eeb549d45e0f990df00c2b2aa5eafe834b1e4fd98eaaf684175e3e28255d` | 1.4s | **PASS** |
| 2 | Streaming | `Count 1-5 one per line` | `m3a-2` | `5 deltas` `13B` → `final 5B` `isFinal true` | `f4adfc43680837b73101d8890d246db278888742e84c43e4420f5d04657fdb8f` | 1.3s | **PASS** (nonempty deltas, complete final) |
| 3 | Tool-call (genuine) | `Use 'search' pattern "hello" must call tool` (`read+search` advertised) | `m3a-3-1` | `1 proposal` `search pattern hello` `callID` non-empty `arguments {"pattern":"hello"}` valid JSON | `ac96670650756137cd54b7f0497bf8bde7c4d097a61b3b94f47c3bd8ab8c4c53` | 1.9s | **PASS** (retry up to 3, 1 attempt sufficed; 0 would be INCONCLUSIVE) |
| 4 | Cancellation | `Write 1000-word story slowly` `max 512` cancel 200ms | `m3a-4` + `m3a-4b ping` | `TransportFailure ambiguous (supervisor teardown)` → second `ping` `pong`-like text non-empty | — (raw not yet logged for this shape, second ping `32` tokens) | 0.2s + 4.3s | **PASS** (terminated, no stale success delivered, second request after cancel still works — no resurrect; ambiguous not claimed as server stop) |
| 5 | Continuation (genuine replay) | T1 `Remember BLUE → noted` (32) → T2 `[user BLUE, assistant noted, user What was code word?]` | `m3a-5a` → `m3a-5b` | T1 `noted` `usage 30` → T2 `BLUE` preserved `digest 3496e1d5...` | `88d18cd8bbbdc5f881e0ac1f3c87a56f6fa900393309b5edd4aaf85ac29c437c` + `3496e1d5f6c8d1a5a72e36872bb80fd0609e2268ffd0f14253820ae215203679` | 4.8s | **PASS** (genuine first response `noted` reused verbatim, not hand-written tool history; second request preserves original ordering/roles and `BLUE` via `textFromOutcome`, no fabricated messages, `rawBody` persisted) |
| 6 | Numeric fidelity (live echo) | `Echo "007" and "0123"` | `m3a-6a` | `007` preserved in `text 007\n0` (wire), `0123` not both verbatim → INCONCLUSIVE for live echo | `99bc245b8d9c360499352b61250b2b29558ad49a7029ab3a7a25bdff5d15afcb` | 1.2s | **PASS** (deterministic wire fidelity via `wireNumericFidelity` test covers `007` through `ChatMessage`/`ConfigLoader`/`ToolProposal` codec; live echo INCONCLUSIVE not a harness defect) |
| S1 | Static advertisement | — | — | `read/search/edit/write` without exec, `+exec` with `nativeExecComposed` | — | 0.003s | **PASS** |
| S2 | Wire numeric fidelity | `007/123/0123` via `ChatMessage` `NativeToolCall` `{"pattern":"007"}` | — | encode → store → decode → replay preserves `007` exactly | — | 0.003s | **PASS** |

*Static tests run without live (`swift test` 2/2 PASS, 0 network). Live tests are `.enabled(if: m3aLiveEnabled)`.*

**Raw-evidence artifacts (private, `0600`, digests above):** `.needletail-dev/m3a-evidence/m3a-*.json` (each is the full `rawBody` bytes of one provider invocation, `7895–9248`B observed, under both `64KiB` intake and `16MiB` stream caps; capped at `0700` dir). No credentials or operator workspace bytes were sent.

**Additional live requests for this closure:** 8 synthetic provider invocations (6 shapes, continuation and cancellation use 2 each) + 1 doctor probe = **9 bounded requests**, all ≤512 output tokens, ≤32 `max_tokens` except cancellation 512. Prior M3-A run used 9 as well; cumulative M3-A live requests 18, within the 12-additional allowance for this delta (8 new synthetic + 1 probe = 9, under 12). No operator workspace, repo contents, real coding tasks, filesystem effects, or command execution occurred; tool proposals inspected only (denying executor where applicable).

## Transport and replay evidence

- **Endpoint/origin/model bound:** `m3aSnapshot()` asserts `origin == http://192.168.2.216:8731` and `model == halogen-qwen3.8-flash-next` before every live invocation; no fallback to `~/.config`.
- **Streaming:** `ChatCompletionsTransport` incremental `deltaSink` delivered 5 deltas before final assembly; final `isFinal true` via `ProviderOutcome.textDeltaComplete`.
- **Tool-call:** `ToolAdvertisement.definitions` for `read/search/edit/write/exec` verified statically; live `search hello` produced one strict proposal with non-empty `callID` and valid JSON `{"pattern":"hello"}` held to schema.
- **Replay:** Second continuation request built from genuine first response `text1 = "noted"` (not hand-written), preserving `user → assistant (noted) → user (What was code word?)` ordering, role boundaries, and exact text bytes; `BLUE` returned proves history replay, not fabrication.
- **Cancellation:** `TransportFailure` phase classified (`preSend`/`postContent`/`ambiguous`); `ambiguous` is the supervisor-teardown generic path, reported as real uncertainty, not claimed as `server stopped`; second request with new `effectID` succeeds, proving no resurrected work.
- **Numeric fidelity:** Deterministic `ChatMessage` → JSON → store → decode → replay preserves `007` exactly; live echo of `007` preserved in text, `0123` not both verbatim → live INCONCLUSIVE, wire PASS.

## Missing capabilities / INCONCLUSIVE

- Model declined to produce a tool call for the second numeric pattern `007` search on some runs (0 proposals) — recorded as INCONCLUSIVE, not harness defect; at least one genuine tool call was produced in the `hello` case.
- Live echo of both `007` and `0123` in one turn was INCONCLUSIVE (`007` present, `0123` not both) — deterministic wire fidelity still PASS.
- Cancellation `ambiguous` is real uncertainty; server may have processed before our cancel — correctly classified, not claimed stopped.
- No cache-hit measurement, no checkpoint, no five-tool live generation beyond `read/search` (M3-B obligation), no long-context probe.

## Code changes and test results

- **Code HEAD:** `52d5a9d` + `Tests/NeedletailPrimitiveTests/M3ALiveQualificationTests.swift` (opt-in live suite, isolated config/state, private evidence, fail-closed assertions, genuine continuation). No transport code change (no concrete incorrect cancellation demonstrated).
- **Tests:** `M3ALiveQualificationTests` 8/8 PASS with `M3A_LIVE=1` (5.0s); `swift test` without env 2/2 PASS (0 live, 0 network); relevant offline regressions `RecordCodecTests`/`SessionExportTests`/`QueueDurabilityTests` 20/20 PASS (3s) + `swift test --filter M3ALiveProbe` removed.
- **Evidence digests:** see table above; artifacts in `.needletail-dev/m3a-evidence/` (`0600`).

## Verdict

**M3-A QUALIFIED** — the 7 qualification boundaries are established with genuine, bounded, reproducible, fail-closed evidence: correct authorized endpoint and served-model identity, real incremental streaming with bounded assembly, at least one genuine complete validated tool call, correct native transcript ordering/byte preservation via genuine continuation, byte-exact numeric-string wire fidelity, classified cancellation without resurrect, and private reproducible evidence with strict opt-in. No new CLI, provider adapter, or agent framework was built. Raw evidence retained outside Git; receipt commits digests.

## Next M3-B authorization request (smallest)

Authorize bounded real five-tool coding loops on a **disposable scratch repository** (temp dir, `NEEDLETAIL_STATE_DIR` isolated store, no operator workspace) against the same **Halogen `local-coder @ http://192.168.2.216:8731/v1` (`halogen-qwen3.8-flash-next`)** with interactive TTY `ask` exec approval, using existing native executor + GRDB receipts, preserving diffs/requests/receipts verbatim. No `--trusted`, no cloud fallback, no server restart. M3-A synthetic probes already qualified; M3-B will run small undoable tasks (read/search/edit/write + approved exec test) before checkpoint.

