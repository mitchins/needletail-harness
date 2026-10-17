# M1-D implementation delta (integration choices only)

Baseline `8c3ce24`. Architecture per COMPLETE-SPEC + M1-A/B/C slices. Cases due: CORE-01, HEAD-01/02/03, BDD-06, BDD-08 (regression). No new deps, no new frameworks, no transport stack changes.

## D1. Transcript (DurableRecords in the store, paged — ARCH §1)

ARCH §1 forbids duplicating canonical history into `SessionState`. New additive `DurableRecord.transcriptAppended(TranscriptEntry)` with `TranscriptEntry`: user(text) / assistantText(text) / toolCall(NativeToolCall verbatim) / toolResponse(callID, result text). Emitted by transitions at: admission (user), provider-response handling (assistant text + calls), effect completion (responses) — alongside existing records, same store-append path. The transport's `messageProvider` reads `store.records(since: 0, limit: 1024)` (InMemorySessionStore in M1; M2 optimizes with cursors), filters transcript cases in seq order, and maps via pure `transcriptMessages(_:) -> [ChatMessage]` (assistant+toolCalls → `tool_calls`; tool responses → role `tool` + `tool_call_id`; existing `messageJSON` encodes both). Over-limit pages fail honest (never silent truncation; unreachable at the 80-turn budget). No synthetic system preamble — the transcript starts with the operator prompt. `SessionState` gains nothing transcript-shaped (its `lastSequence` remains the only cursor).

## D2. Full arguments through provider → actor → executor

`ToolProposal` gains `arguments: String? = nil` (existing constructions unaffected). `assembleChatTurn` fills it from the validated buffer; digest stays for records. Executor backend reads `arguments` verbatim — digests never feed execution. Proposals with invalid (non-JSON-object) arguments fail at assembly (existing `invalidArguments`); executor re-validates shape before dispatch (defense in depth, same rule).

## D3. Scripted tool backend (fixture-driven, no real FS)

New `ScriptedToolBackend: ToolExecutor` (product target, clearly labeled fixture): constructed from a JSON script of ordered `{tool, arguments, result}` triples plus the run's `EffectiveCapabilities` (injected at construction — the transition's authorising check stays authoritative; this is defense in depth). `execute` checks caps first (denied → refusal, never executed), then matches the batch's (tool, arguments) against the script head EXACTLY (mismatch = honest throw → `effectFailed`, proving exactness at runtime); returns canned text (file content / edit receipt / test output). Script mismatch, unknown tool, and cap-denial are typed failures, never silent. M2 owns real effects.

Dispatch gap (no production caller invokes `execute` today): `SessionActor.perform(.reserveEffect)` with a NON-EMPTY batch spawns exactly one `Task` calling `executor.execute` once, then pairs the outcome through the existing `completeEffect`/`failEffect` entry points (generation + revision re-checked before pairing, per ARCH §2; stale outcomes drop). Empty-batch reservations stay record-only (current behavior for provider retries). Cancellation drops the task; late completions cannot resurrect (existing reservation table).

## D4. JSONL sink + timers + incremental deltas

- `emitUI` currently terminates in `perform`. Actor gains a `UISink` seam: newline-delimited JSON envelopes `{format_version, session_id, seq, kind, payload}` (seq stamped sink-side; delta envelopes also carry the request ID per §12.2). Sink targets: stdout in `--format jsonl` mode (stdout carries ONLY events; diagnostics go to stderr; a terminal `run_finished` with outcome/reason/usage/evidence closes the stream) or `--trace` file (same bytes). Write-through, no unbounded memory; write failure cancels the run honestly (closed stdout pipe → exit 130 per §12.2 "a closed consumer pipe cancels the run"). Projection vocabulary extended additively ONLY (`delta(requestID:text:)` factory; `kind`/`detail` strings unchanged, terminalSafe preserved).
- `startTimer`/`cancelTimer` currently no-op. Actor schedules real `Task.sleep` timers keyed by (purpose, runID); on fire, applies `.tick` only if the run generation is still current (stale ticks drop — same rule as `tickCancelling`). Cancel drops the task. Existing stamped-tick transition logic untouched.
- Incremental output: transport gains optional `eventSink: @Sendable (ProviderEvent) -> Void` (default nil → current single-shot behavior). The delegate keeps a rolling leftover buffer; on each body chunk it runs the PRODUCTION SSE decoder over newly-completed event texts only and forwards `textDelta` fragments; tool proposals still complete atomically at `finish_reason`. Deltas are display-hints (never state); malformed mid-stream events emit nothing (final assembly still fails closed). Actor wires the sink to `emitUI` delta projections → JSONL. Bounds unchanged (deltas are substrings of already-capped bytes; nothing retained).

## D5. Session-scoped raw record (answers M1C3-4 for M1)

`TransportResult` gains `rawBody: [UInt8]? = nil` (default keeps all existing constructions compiling). Transport sets it to the bounded collected body. Actor keeps a session-scoped ring bounded by count AND bytes (8 records, 16 MiB total — ARCH §6; evict-oldest; a single capped turn always fits). Each record: requestID + verbatim body + returned model + usage; exposed read-only for CLI/demo inspection. Durable persistence stays M2. Secret posture unchanged (records are memory-only, never logged; redaction tests extended).

## D6. `needletail run` CLI

New `RunCommand`: `needletail run --config <path> --prompt <text> [--trace <out.jsonl>] [--format jsonl] --tools <script.json> [--alias <a>] [--max-turns N]`. Wires: validated snapshot → SessionState → SessionActor with REAL `ChatCompletionsTransport` + `ScriptedToolBackend` + JSONL sink + timer scheduling. `--format jsonl` (SPEC §12.2): stdout carries ONLY versioned events; without it, stdout carries the human final answer and `--trace` (or stdout-captured JSONL) stays inspectable. Exits per §12.2: 0 completed / 2 config / 3 approval-held / 4 provider-or-tool failure / 5 budget exhausted / 6 integrity / 130 cancelled (typed redacted stderr; failed tool results are DATA for the agent, not exit 4, per §12.2). No discovery, no fallback, no real FS writes.

## D7. Acceptance demo + negatives (outside the product)

- Demo endpoint: `demo/m1d-server.py` (host python3, NOT shipped) — scripted 10-step coding dialogue (read → content → edit → receipt → test → failure diagnostics → repair → success → final answer), SSE with paced chunks, captures every request body to a file.
- Demo assertion (`demo/m1d-check.py`): replays the captured bodies, verifying ordered conversation, exact call IDs/names/arguments, tool-result pairing, and transcript growth across turns; verifies the JSONL trace event order; asserts exit 0. Scripted effects touch no workspace files (assert).
- Negatives (same `run` entry point, scripted servers/scripts): cancel-mid-stream + late completion; queue-while-busy + cancel-held; denied proposals; approval-required headless hold; FIN vs preSend; unknown delivery (raw error → ambiguous, no resend); turn/time/buffer exhaustion; closed stdout (`>&-`) + slow consumer; malformed/incomplete arguments; sealed tool-free inference; secret/control-byte audit of all diagnostics.
- Tests: pure/fast majority (transcript mapping, backend matching, sink bounds, timer generation checks, raw ring); scripted-transport actor tests; few loopback + spawned-release-binary tests. BDD-06 probes for the new boundaries (digest-vs-arguments execution, transcript bypass, delta-before-completion, raw-record bound). BDD-08 frozen replay re-run as regression.

## D8. Epic closeout (authorized)

Aggregate M1 evidence → push `m1-epic` branch → open PR → Linux CI → CodeRabbit full review → bounded remediation → STOP for merge approval. No auto-merge.
