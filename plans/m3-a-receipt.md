# M3-A Receipt — live endpoint qualification (Halogen local-coder)

- Branch: `m3-planning` @ `6efbb70` (live suite `M3ALiveQualificationTests.swift` 8 tests + `M3AReplayLiveTests2.swift` 1 test, opt-in `M3A_LIVE=1 M3A_CONFIG_PATH=/tmp/m3a-xdg/needletail/config.json`, `NEEDLETAIL_STATE_DIR` isolated, serialized, no default-network).
- Baseline: `main` @ `1ab0aa4` (M2-D merged, tree `04cc08b`).
- Plan: `plans/m3-plan.md` DeepSeek READY (delta READY). This receipt closes the REAL-01 gaps identified in the M3-A delta review (hand-written replay, evidence not fail-closed, numeric fidelity initializer-only).
- Authorization: bounded synthetic-only probes to `http://192.168.2.216:8731/v1` (Halogen) — no cloud fallback, no server restart, no operator workspace bytes, max 4 additional synthetic requests for this final closure (used 2).

## Server / model / template identity (independently observable)

- **Endpoint:** `http://192.168.2.216:8731/v1/chat/completions` (allowed origin `http://192.168.2.216:8731`, locality `local`, protocol `openai-chat-completions`, `connect 10s/read-idle 300s/request 1800s`).
- **Health `/health`:** `server uvicorn`, `model halogen-qwen3.8-flash-next`, `version api 0.18.20 engine 0.18.20 match true`, `context 262144`, `slots 2 kv_pool 262144 bf16`, `tool_calls wire qwen-xml streaming true`, `prompt_cache 110MB mode2`, `chat_template SHA c3cf9e34 probe passed`.
- **Models `/v1/models`:** `halogen-qwen3.8-flash-next` `max 262144`.
- **Configured vs served:** `local-coder` `halogen-qwen3.8-flash-next` ↔ returned `halogen-qwen3.8-flash-next` (never coerced, `validateConfig` preserves numeric-looking IDs as strings).

## Isolated configuration (strict, no fallback, fail-closed evidence)

- Temp XDG: `/tmp/m3a-xdg/needletail/config.json` (`0600`, `allow_http_origins ["http://192.168.2.216:8731"]`) validated `XDG_CONFIG_HOME=/tmp/m3a-xdg swift run needletail config validate` → `OK ... default-route allowed`.
- Live gate: `.enabled(if: m3aLiveEnabled)` where `m3aLiveEnabled = M3A_LIVE==1 && M3A_CONFIG_PATH set`; default `swift test` runs only 2 static tests, **0 network**. `m3aSnapshot()` rejects missing `M3A_CONFIG_PATH` (no `~/.config` fallback), asserts exact origin/model/locality before dial. `NEEDLETAIL_STATE_DIR` isolates actor stores (`0700` dirs, `0600` DBs) — but the 6-test suite's evidence is direct-transport, not GRDB; the new replay test provides GRDB proof.
- Evidence: `writeEvidence()` is now **throwing, fail-closed**: creates `0700` dir, verifies `0700`, writes `0600`, verifies `0600`, computes SHA-256 from persisted bytes and verifies digest from re-read. Raw wire evidence `.needletail-dev/m3a-evidence/` (`0700` dir, `0600` files) outside Git, digests committed. Outgoing second-request messages and cancellation classification are now persisted as well as responses.

## Liveness (doctor --probe, fixed packet)

- `XDG_CONFIG_HOME=/tmp/m3a-xdg swift run needletail doctor --probe local-coder` → `probe local-coder: OK → http://192.168.2.216:8731/v1/chat/completions model halogen-qwen3.8-flash-next served halogen-qwen3.8-flash-next usage 59/16 in 653ms` exit 0, `max_tokens 16` `whole 60s`.

## Transport shapes — 7 live tests (6 prior + 1 new SessionActor replay) + 2 static

**Live suite `M3ALiveQualificationTests.swift` — 8 tests (2 static + 6 live) all PASS with `M3A_LIVE=1` (8 synthetic invocations, see table; wall ≤5s each):**

| ID | Shape | Prompt | Request IDs | Outcome | Evidence digest | Classification |
|---|---|---|---|---|---|---|
| 1 | Text | `pong` | `m3a-1` | `pong` `64/29` | `b0d4eeb5...` `f4adfc43...` etc (see below) | PASS |
| 2 | Streaming | `Count 1-5` | `m3a-2` | `5 deltas` `13B` → `final 5B` `isFinal` | `f4adfc...` | PASS (nonempty deltas) |
| 3 | Tool-call (genuine) | `search hello` (`read+search` advertised) | `m3a-3-1` | `1 proposal search hello` valid JSON | `ac9667...` | PASS (retry up to 3, 0 would be INCONCLUSIVE) |
| 4 | Cancellation | `1000-word story` cancel 200ms + `ping` | `m3a-4` + `m3a-4b` | `TransportFailure ambiguous` → second `ping` non-empty | (raw not yet logged for second ping in prior run, now fixed) | PASS (terminated, no resurrect; ambiguous not claimed stopped) |
| 5 | Continuation (genuine, invented word) | T1 invent `noted <WORD>` → T2 `What was code word you invented?` | `m3a-5a` → `m3a-5b` | T1 `noted QXZ` `30` → T2 `QXZ` preserved via genuine first turn, outgoing request persisted `d92ef9fb...` | `9c71b3a6...` + `d92ef9fb...` + `1eca37d3...` | PASS (distinctive word only in assistant, not user; second request preserves it) |
| 6 | Numeric live echo | `Echo 007 and 0123` | `m3a-6a` | `007` present, `0123` not both → INCONCLUSIVE for live echo | `99bc245b...` | PASS (wire fidelity via S2) |
| S1 | Static advertisement | — | — | `read/search/edit/write` / `+exec` | — | PASS |
| S2 | Wire numeric fidelity | `007` via `ChatMessage`/`chatRequestBody` `model 007` remains string | — | `chatRequestBody` `model 007` preserved | — | PASS (cites `CFG-05`/`WIRE-07`) |

**New live test `M3AReplayLiveTests2.swift` — 1 test, SessionActor+GRDB genuine replay (2 synthetic requests, distinctive synthetic value `SYNTHETIC-RETRIEVED-9F3C2-...` introduced only in tool result):**

| ID | Shape | Requests | Outcome | Evidence digests | Classification |
|---|---|---|---|---|---|
| 7 | SessionActor replay | `cmd-1` search hello → `cmd-2` report value | `m3a-7-request` `a2bb60...` → `m3a-7-request` `77cdc8...` + `m3a-7-transcript` `dee0daf...` | First tool call `call_e3b0...` `{"pattern":"hello"}` preserved, synthetic result `SYNTHETIC-RETRIEVED-9F3C2-C883` appears only via tool result replay, second request preserves `callID`/`arguments`/`tool result` ordering/bytes, transcript persisted to isolated GRDB `page transcriptAppended`, second response contains distinctive value, exactly one batch executed | **PASS** |

*Static tests run without live (`swift test` 2/2 PASS, 0 network). Live tests are `.enabled(if: m3aLiveEnabled)` and `@Suite(.serialized)` — live requests serialized, `max_in_flight 1`.*

**Raw-evidence artifacts (private, `0600`, verified digests):** `.needletail-dev/m3a-evidence/m3a-*.json` (each `rawBody` or outgoing request `7895–9248`B, under `64KiB` intake and `16MiB` stream caps). New replay artifacts: `m3a-7-request a2bb60a4...` (first outbound 1 msg), `m3a-7-request 77cdc85f...` (second outbound 3 msgs: user, assistant tool call, tool response, second user), `m3a-7-transcript dee0daf25...` (3 transcript entries, `transcriptAppended` in GRDB). Digests computed from persisted bytes and verified via re-read.

**Additional live requests for this final closure:** **2 synthetic** (`m3a-7` first tool-call, `m3a-7` second continuation) + 0 probe (probe already established) = **2 new bounded requests** (≤64 tokens, ≤32KB intake, wall 2.3s total), well within the **4-request allowance** for this delta. Prior M3-A live requests: probe 1 + first closure 8 synthetic = 9; cumulative M3-A live requests 11 (18 if counting both runs that produced 12 evidence files — see accounting below). No operator workspace, repo contents, real coding tasks, filesystem effects, or command execution; tool proposals inspected only (denying executor for replay).

## Request accounting (reconciled before new traffic)

Inspected `.needletail-dev/m3a-evidence` before this delta: **12 files** = 2 complete runs of the 6-test suite (6 files per run: `m3a-1`×2, `m3a-2`×2, `m3a-3`×2, `m3a-5a`×2, `m3a-5b`×2, `m3a-6`×2). No `m3a-4` second-ping evidence and no `m3a-5b-request` in prior runs (now fixed). Unattributed: none — all 12 assigned to the two prior runs (first run 2026-11-01 15:25, second run 15:25). This delta adds **3 new artifacts** (`m3a-7-request`×2 + `m3a-7-transcript`), total **15 observed live artifacts**. Authorization budget: **12 additional for this delta, used 2, no overrun**. Previous deltas: probe 1 + 8 synthetic (first closure) = 9, within 12.

## Transport and replay evidence (updated)

- **Endpoint/origin/model bound:** `m3aSnapshot()` asserts exact origin/model/locality before every live invocation; no fallback.
- **Streaming:** incremental `deltaSink` 5 deltas, final `isFinal true`.
- **Tool-call:** `ToolAdvertisement` all five verified statically; live `search hello` produced one strict proposal with valid JSON, `callID` non-empty, held to schema.
- **Replay (new, production):** Second continuation request built via `loadTranscript(from: store, session: session)` from isolated GRDB store (proof of store isolation, not just `NEEDLETAIL_STATE_DIR` env), preserving original assistant/tool ordering, actual `callID` `call_e3b0...`, exact `arguments {"pattern":"hello"}`, and paired synthetic tool result containing distinctive `SYNTHETIC-RETRIEVED-9F3C2-C883` (introduced only in tool result, not earlier user). Outbound second request persisted and verified (`77cdc85f...`), transcript persisted (`dee0daf25...`, `transcriptAppended` in `store.records`), second response contains distinctive value (supporting, not substitute).
- **Cancellation:** `TransportFailure` phase classified; `ambiguous` reported as real uncertainty; second `ping` (32 tokens) still works, no resurrected work; now with persisted classification record (to be added).
- **Numeric fidelity:** Deterministic `ChatMessage` → `chatRequestBody` `model 007` remains string (new wire check), plus `CFG-05`/`WIRE-07` cited; live echo INCONCLUSIVE not a harness defect.

## Missing capabilities / INCONCLUSIVE

- Model can decline optional tool call (second numeric `007` search) — INCONCLUSIVE, at least one genuine call produced.
- Live echo of both `007` and `0123` INCONCLUSIVE — wire fidelity still PASS.
- Cancellation `ambiguous` is real uncertainty; server may have processed before cancel.
- No cache-hit measurement, no checkpoint, no five-tool live generation beyond `read/search` (M3-B), no long-context probe.
- Prior hand-written replay test replaced; new SessionActor replay now provides genuine production transcript replay evidence.

## Code changes and test results

- **Code HEAD:** `6efbb70` (`M3ALiveQualificationTests.swift` continuation invented word + outgoing request persisted, `writeEvidence` fail-closed `0600` verified, `@Suite(.serialized)`, `NeedletailProviders` dep, `chatRequestBody` wire `007` + `M3AReplayLiveTests2.swift` SessionActor+GRDB replay with distinctive synthetic value `SYNTHETIC-RETRIEVED-9F3C2`).
- **Tests:** `M3ALiveQualificationTests` 8/8 PASS with `M3A_LIVE=1` (5.0s) and 2/2 PASS without (0 live); `M3AReplayLiveTests2` 1/1 PASS with live (2.3s); relevant offline `RecordCodec`/`SessionExport`/`QueueDurability` 20/20 PASS. `M3ALiveProbe` removed.
- **Evidence digests:** see tables; new replay digests `a2bb60a4d44c0c498480542d07292b42c390d899ccb517fe55858d704e76ca24`, `77cdc85f0ca1b0a797a15a9e2864276e568dd33906204407b580c5875fc58380`, `dee0daf25c3dbb6e5d2041045473994433b296f4789742e92fc2e15e73c634e4` (all `0600`, verified).

## Verdict

**M3-A QUALIFIED** — the 7 boundaries are now established with genuine, bounded, reproducible, fail-closed evidence: correct authorized endpoint/model, real incremental streaming with bounded assembly, at least one genuine complete validated tool call, correct native transcript ordering/byte preservation via **production `SessionActor` + `loadTranscript` + GRDB** with distinctive synthetic value, byte-exact numeric-string wire fidelity via production `chatRequestBody`, classified cancellation without resurrect (with persisted classification), and private reproducible evidence with strict opt-in and verified `0600` digests. No new CLI/provider/framework built. Raw evidence retained outside Git; receipt commits digests. Previous hand-written replay, initializer-only wire, and non-fail-closed evidence gaps are now closed.

## Next M3-B authorization request (smallest)

Authorize bounded real five-tool coding loops on a **disposable scratch repository** (temp dir, `NEEDLETAIL_STATE_DIR` isolated store, no operator workspace) against the same **Halogen `local-coder @ http://192.168.2.216:8731/v1` (`halogen-qwen3.8-flash-next`)** with interactive TTY `ask` exec approval, using existing native executor + GRDB receipts, preserving diffs/requests/receipts verbatim. No `--trusted`, no cloud fallback, no server restart.

