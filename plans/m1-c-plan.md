# M1-C delta plan — streamed Chat Completions adapter over the selected transport/SSE stack

Scope: short implementation delta per the tranche authorization (not a full epic plan). Planning-only; **no implementation authorized by this document.**
Status: REVISED FOR RE-REVIEW (rev4; rev3 reviewed NEEDS-EVIDENCE with M1C3-1..3; this revision scopes the resend rule, places the tick scheduler, and retires the stale seam question — see §7).
Prepared: 14 October 2026.
Baseline: `main` at `50c625b` (M1-B closed locally; Swift 6.4; lockfile `de95226e…cc` — no dependency change in this slice).
Implementer: `muse-spark-1.3-contributor`. Reviewer: `deepseek-reviewer` (read-only).
Baseline evidence: `./dev build` ok; `./dev test quick` 174/174 green (State 52, Primitive 14, Presentation 19, Config 69, Behaviour 20).

Normative sources: COMPLETE-SPEC.md §§ 5.1–5.3 (endpoint/credential rules), 10.3 (no fallback/proxy), 11 (streaming/bounds/deadlines/retries), 12.2 (exits); MILESTONES M1-C; ACCEPTANCE WIRE-01..10, NET-02..05, NET-06, POLICY-02 (matrix reuse), DX-04/05; M1-A plan §§3–5/8 (profiles, origins, request_options, redaction); M1-B plan §§2–4/7 (ProviderInvocation/Response handoff, BoundedChannel, authorize-before-dispatch, M1-C needs); DEPENDENCIES.md (AsyncHTTPClient 1.36.2, swift-openapi-runtime 1.13.0 — already resolved, no new packages).

## 1. Goal (MILESTONES M1-C, verbatim scope)

Implement the first native adapter using the chosen transport/SSE components. Test byte splits, native completion, interleaved calls, signed/opaque/unknown blocks, resource bounds and partial-response errors. Complete tool calls are proposals; they do not execute during stream assembly. Raw record, native replay and display projection are distinct.

What this slice is NOT: Responses/Messages adapters (M5), real provider traffic beyond loopback (M3/M5), cloud routes, the headless JSONL loop (M1-D), persistence (M2), terminal work (M4). No new packages, no macOS code, no catalogue renumbering.

## 2. Design (smallest viable)

**2.1 Placement.** All production code in `NeedletailProviders` (deps today: Core; adding AsyncHTTPClient + OpenAPIRuntime products — both already resolved, no lockfile change beyond target linkage). Chat value types live in Core (R1 — a Core type cannot reference Providers; see 2.2). CLI gains a Providers dependency for the probe path only (R6 — deliberate, reviewed; the AsyncHTTPClient product stays inside Providers, never imported by CLI). No other Core changes. No lockfile version changes.

**2.2 Messages travel explicitly (R1/R3/M1C2-1).** `ChatMessage` + `NativeToolCall` are pure values in **Core** (`role: user|assistant|system|tool`, `text`, `toolCalls?`, `toolCallID?`; unknown roles/fields rejected at the mapping boundary, never coerced) — kept there deliberately as the shared session/adapter vocabulary (M1-D transcript reuses them), NOT for any invocation field: `ProviderInvocation` is UNCHANGED (no `messages` field — the rev2 draft's defaulted field is withdrawn as inert). Population seam: the M1-C transport is constructed with three Sendable closures — `messageProvider: (ProviderInvocation) async -> [ChatMessage]` (synthetic/history-backed suppliers; M1-D wires the store reader), `credentialProvider: (CredentialReference, String) async throws -> String` (operation-scoped resolution, redaction preserved; Linux: `EnvFileCredentialStore`; M1C2-6), `snapshotProvider: () -> ConfigSnapshot` (current config for authorize-before-dial; M1C2-3). Empty messages refuse with a typed error (never silent). Closures capture only explicit test/CLI values in M1-C (no mutable shared state; credential strings never enter logs — asserted). The M1-B no-ID-result rule and replay shape are untouched.

**2.3 Client policy (verified against AsyncHTTPClient 1.36.2 sources).** One shared `HTTPClient` per adapter instance on a single event-loop thread (SPEC §4.1 default; `MultiThreadedEventLoopGroup(numberOfThreads: 1)`); `redirectConfiguration: .disallow` (NET-02 — a 3xx is a typed error, no follow, no credential forwarding); `proxy: nil` always (verified: the client reads no proxy env vars — NET-03 by construction + test with hostile env); TLS default validation (custom local CAs explicitly deferred — no config field exists; unknown-CA https fails honestly); `timeout.connect/read` from the profile; whole-request + heartbeat-aware read-idle deadlines enforced at OUR layer (heartbeats/comments reset idle, never the whole timer); explicit shutdown (`syncShutdown`, no leaked threads — asserted in teardown). Compression (R5): never send `Accept-Encoding: gzip/deflate/br`; a server-sent `Content-Encoding` is a typed protocol refusal (no decompression exists, so caps measure wire bytes = decoded bytes trivially); WIRE-03 gains the gzipped-response variant. DNS/peer capture explicitly out of M1-C (diagnostic follow-up, R11).

**2.4 Bounded intake (SPEC §11, upstream of the parser).** Raw bytes flow through a bounding transform BEFORE `asDecodedServerSentEvents()`: reject unterminated lines/events over 1 MiB; cap the whole stream at 16 MiB (wire bytes; R5 — no decompression exists so there is no second dimension); tool-call argument buffers at 256 KiB per call with accumulation keyed by NATIVE id across ALL fragments sharing it (any index, interleaved or duplicate-index — R8); the 8-call bound counts DISTINCT ids (9th distinct id → typed over-limit, no silent enlarge); same id on two indices, or a changed id mid-index, → typed rejection (WIRE-05 spirit). Numbers are the SPEC §11 initial bounds, profile-adjustable later only via config edit. Error bodies bounded (8 KiB) and redacted.

**2.5 Assembly (pure, transport-free — the quick-gate core).** `assembleChatTurn(events: [ServerSentEvent]) -> AssembledTurn`: text deltas concatenate (UTF-8 lossless — raw bytes retained, never renormalized); `reasoning_content` accumulates as opaque passthrough (never interpreted, never forwarded as another provider's block); tool calls assemble by native `(id, index)` with argument-fragment concatenation (interleaved streams stay separated — WIRE-04); duplicate tool IDs → typed rejection (WIRE-05); unknown/unsigned continuation-bearing blocks → preserve-under-qualified-profile or compatibility-stop, never silently dropped (WIRE-06); numeric-looking strings preserved verbatim (WIRE-07); usage `{prompt,completion}` → optional counts (absent stays unknown, never zero); `finish_reason` → `isFinal` (stop/length/tool_calls final; anything else → explicit non-final mapping, never assumed); stream end without native completion → zero side effects + retained incomplete record (WIRE-08); mid-history user instruction appends in the adapter's qualified role with the base prefix untouched (WIRE-09); `RawTranscript` (bounded verbatim bytes) travels alongside for M1-D/M2 persistence (raw ≠ replay ≠ display, SPEC §5.2). Completion API (M1C2-4): `invoke` returns exactly ONE final `TransportResult` per call — the adapter consumes the whole stream internally; interim `isFinal:false` shapes exist only in scripted tests and the M1-B transition rows that already handle them. The intake channel is accepted (not offered into) in M1-C; display-streaming use is M4.

**2.6 Retry classification + single policy authority (R2).** New Core error `TransportFailure{phase: TransportPhase, message}` (pure value, no transport import): the ADAPTER classifies every failure at its site (connect failure pre-bytes → preSend; mid-stream break → postContent; anything unclassifiable → ambiguous) and THROWS — it never retries (no loop exists in Providers). Backoff is policy, armed by the transition (M1C3-1/2): preSend retry sets `retryDeadlineMillis = now + (1s << attempt)` (counter incremented at ARM time) + `startTimer`; ONLY the `tick` row in `SessionTransition` consumes a set deadline and dispatches (iff phase == requesting, else explicit no-op); the deadline clears on cancel, epoch change and dispatch. "No auto-resend" means no transport/actor-initiated resend outside this policy path — the tick dispatch IS the one resend path. The ACTOR catches: `CancellationError` → drop; `TransportFailure` → `transportFailed` event carrying the CLASSIFICATION (one-line additive catch arm in `SessionActor.invokeTransport`); anything else → ambiguous. The M1-B transition policy (`preSendRetries` ≤ 2, holds, no auto-resend) remains the SOLE retry authority — double-retry would require a second loop that grep can prove absent. Idempotency keys only where an endpoint documents one (never claimed otherwise). NET-05 end-to-end: a test-only `FlakyTransport` (scripted preSend failure once, then delegates to the REAL adapter against loopback with synthetic messages) drives the production actor — classification, policy and real HTTP bytes in one deterministic run — plus the mid-stream RST case (partial retained, never merged/replayed).

**2.7 `doctor --probe` traffic (NET-06 full, R9).** `DoctorProbe` builds a synthetic packet from FIXED LITERALS ONLY (system "needletail probe", user "probe ping", max_tokens 16; total serialized body ≤ 4 KiB — exact cap asserted): never from workspace bytes or session history (M1C3-3: no such invocation field exists). It resolves credentials via the Runtime store (per-operation, redacted), dials ONLY the `authorizeRequestDestination` endpoint (R4 — see 2.8), and prints endpoint/model/returned-model/fingerprint/result. The returned `model` field is recorded and mismatch-flagged as a diagnostic (never fails, never coerced). Exit 0 on qualified success, 2 on config/alias errors (unchanged), 4 on honest provider failure. Test asserts the exact packet bytes contain no workspace canary planted alongside.

**2.8 Shared test server + authorize-before-dial (R4/M1C2-3).** `LoopbackSSEServer` in `NeedletailTestSupport` (test-only, POSIX sockets + bounded poll/wakeup pipe — the M0-B pattern, no new dependency): scripted status/headers/chunk plans (per-chunk bytes + delays), request capture (method/path/headers/body for assertions — Authorization redaction asserted), connection counting (the mutated-snapshot oracle asserts server-side connection count == 0 — M1C2-7, stronger than "zero bytes"). Linux-only like its M0 predecessor (macOS parity is M4). The transport calls `snapshotProvider()` + `authorizeRequestDestination` immediately before dialing and dials ONLY the returned endpoint (M1-A H1 seam, now wired) — so epoch changes are always current at dial time with no reconstruction and no stale cache. In-flight streams keep their dial-time epoch (correct per I03 — admitted material is immutable); their completions land-or-drop via the existing generation rule, so no mid-stream re-check is needed or wanted. A mutated-snapshot test (allow-list with the origin removed post-validation) refuses before connect.

## 3. Cases (17; one variant never satisfies all)

- **WIRE-01/02** (integration): every-byte-boundary splits (small fixtures, exhaustive) + sampled splits (large fixtures) over the REAL adapter+loopback path (not just the parser Liu — M0 proved the parser; M1-C proves the adapter preserves it); CRLF/comments/heartbeats/multiline/empty-lines; truncated streams yield complete-prefix events only.
- **WIRE-03** (integration): over-limit unterminated line/event + 9th tool call + 17 MiB stream → bounded typed errors BEFORE parser accumulation (memory assertions via allocation caps where measurable, error-kind assertions always).
- **WIRE-04** (integration): two interleaved tool-call argument streams assemble by native id/index in provider order.
- **WIRE-05** (integration): malformed/incomplete/duplicate-ID/missing-completion tool calls → zero proposals, typed compatibility/protocol errors.
- **WIRE-06** (integration): unknown continuation-bearing + signed/opaque reasoning blocks → preserved replay or compatibility-stop, never dropped.
- **WIRE-07** (integration): numeric strings (`001234`, huge digits), CRLF source, Unicode-equivalent-but-different bytes → lossless raw record + stable replay bytes.
- **WIRE-08** (integration): stream ends after tool data without authoritative completion → zero side effects, incomplete record retained for diagnosis.
- **WIRE-09** (integration): mid-history user instruction appends in the qualified role; base prompt bytes identical pre/post (prefix-stability assertion on the serialized body).
- **WIRE-10** (integration): slow consumer (bounded intake pauses) vs fast provider → bounded backpressure without dropped protocol events.
- **NET-02** (integration): 302 to another origin → not followed; second request never sent (server connection count == 1); no Authorization forwarding (captured headers asserted).
- **NET-03** (integration): hostile `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` + `RIPGREP_CONFIG`-style CA injection env → route/decision byte-identical; connection goes direct (loopback server sees it); invalid TLS rejected (self-signed https fixture → typed TLS error).
- **NET-04** (integration): very slow prefill with heartbeat comments → idle timer resets on heartbeat, whole-request deadline still enforced; explicit cancellation mid-prefill drains bounded and reaps (M0 primitive + adapter deadlines composed).
- **NET-05** (integration): transient pre-stream conn-refused → backoff-armed retry (1s tick) then success via `FlakyTransport` driving the production actor (single authority: transition counter + tick dispatch); mid-stream RST → partial retained, no merge/replay, typed interruption.
- **NET-06** (integration): `doctor` offline (existing) vs `doctor --probe` against loopback (exit 0 + fingerprint) vs unreachable route (exit 4 honest) vs unknown alias (exit 2).
- **DX-04** (pure): scripted provider emitting every SSE byte as an independent chunk through the adapter consumer → identical assembled turn (adapter-level twin of the M0 parser probe).
- **DX-05** (pure): scripted tool start/progress/failure/retry/cancellation event scripts → typed outcomes with no execution (proposals stay data).
- Forbidden everywhere: silent enlargement, discovery traffic, cloud fallback, proxy inheritance, redirects, credential leakage into logs/headers/exports, executing proposals during assembly, merging partial streams, dropping unknown continuation blocks.

Red-before/green-after: oracles run against the M1-B baseline first (no adapter → actionable `notImplemented`, retained), then green via compilable stubs (R20), then implementation. BDD-06 method continues (probe→guard→oracle table extended: bound-bypass, redirect-follow, fallback-to-cloud, strip-unknown-block, merge-partial, last-wins-assembler, prefix-guessing-joiner, 9th-call-evasion — R7 — each RED then restored).

## 4. Files, targets, commands (planned, not executed)

| File | Contents |
|---|---|
| `Sources/NeedletailCore/ChatMessage.swift` | `ChatMessage/ChatRole/NativeToolCall` pure values (R1 — Core-owned so the graph stays acyclic) |
| `Sources/NeedletailCore/SessionTransition.swift` | ADDITIVE ONLY: `TransportFailure{phase,message}` error (R2 classification carrier) |
| `Sources/NeedletailCore/SessionActor.swift` | ADDITIVE ONLY: catch arm mapping `TransportFailure` → classified `transportFailed` event (R2; `CancellationError` → drop unchanged) |
| `Sources/NeedletailProviders/ChatCompletionsAdapter.swift` | `ChatCompletionsRequest` + exact JSON mapping; `AssembledTurn/RawTranscript`; `assembleChatTurn` (pure); `ChatCompletionsTransport` (message/credential/snapshot closures, authorize-before-dial, no retry loops) + `ModelTransport` conformance |
| `Sources/NeedletailProviders/TransportPolicy.swift` | Single-thread group, `.disallow`, nil proxy, TLS default, deadline sources, shutdown (no retry predicate anywhere — transition owns retries; M1C2-2) |
| `Sources/NeedletailProviders/SSEBounds.swift` | Upstream bounding transform (1MiB/16MiB/256KiB/8-call) + typed bound errors |
| `Sources/NeedletailCore/SessionState.swift` | ADDITIVE ONLY: `retryDeadlineMillis: UInt64?` state field (M1C2-5 backoff arming; cleared on cancel/epoch/dispatch) |
| `Sources/NeedletailTestSupport/LoopbackSSEServer.swift` | Scripted loopback (status/headers/chunks/delays + request capture) — test-only |
| `Sources/NeedletailCLI/DoctorProbe.swift` | Real probe traffic (bounded synthetic packet), exits 0/2/4 |
| `Tests/NeedletailProviderTests/*` | Pure: mapping/assembly/bounds/backoff-arming/redaction/request-shape (joins quick) |
| `Tests/NeedletailProviderIntegrationTests/*` | Loopback: splits/completion/interleave/malformed/unknown/fidelity/incomplete/history/backpressure/redirect/proxy/deadlines/retry/probe-spawn |
| `schemas/config.schema.json` | UNCHANGED (no new config surface in M1-C) |

`Package.swift`: Providers gains AsyncHTTPClient + OpenAPIRuntime products (resolved, no version change); CLI gains Providers (probe path only — R6, deliberate); +2 test targets (pure→quick, integration→case/offline). `dev`: quick += provider-pure filter; offline += the 15 test-runner case IDs (WIRE×10 + NET×5; DX-04/05 run under quick via the pure target); `test case` mechanics unchanged.

Anticipated commands: `./dev build`, `./dev test quick`, `./dev test case WIRE-01 … NET-06`, `./dev coverage`, `./dev test offline`, `./dev test native` (M0 regression), release-bundle + packaging smoke.

## 5. Risks and open questions for the reviewer (rev2 status)

Rev2 answers Q1 (closures instead of any invocation field — no inert state), Q2 (id-keyed accumulation specified), Q3 (userinfo rejected at config; peer capture deferred), Q4 (no second loop exists by construction), Q5 (4 KiB fixed-literal packet + canary test). Genuinely open: is the closure-injected `messageProvider`/`credentialProvider` shape the right M1-D handoff, or should M1-D pass messages/credentials per-call instead of at construction? Is refusing (vs downgrading) compressed responses operator-hostile for real servers?

1. (Retired in rev3 — answered: closures, no invocation field. M1C3-3.)
2. Can any bounded-check be bypassed by adversarial chunking (e.g., a 1 MiB+1 line split to evade the unterminated-line guard, or argument-size smuggling across interleave boundaries)?
3. Does `.disallow` + nil-proxy + no-env-reading fully close NET-02/03, or is there a client path (e.g., `Authorization` on redirect, `Proxy-Authorization` from URL userinfo — already rejected at config) we missed?
4. Is adapter-no-retry + actor-policy-retry provably single-authority (name the code location that would have to change to double-retry)?
5. Is the `doctor --probe` synthetic packet sufficiently non-private and bounded (exact byte cap + content audit)?
6. What would you delete as unnecessary for the first local adapter?


## 6. Stop condition

M1-C planning is done when: this delta has an independent DeepSeek plan-review disposition (READY / NEEDS-EVIDENCE / BLOCKED), valid findings are folded with digests recorded, `STATUS.md` shows **M1-C PLAN REVIEWED** (not implemented), and no M1-C production/test code exists. Implementation waits for its own authorization (already granted conditionally by the tranche authorization upon plan READY).

## 7. Revision log (rev1 → rev2 → rev3)

Rev2 → rev3 (reviewer M1C2-1..8, NEEDS-EVIDENCE): M1C2-1 (dropped-field clauses removed; ChatMessage stays Core as shared vocabulary); M1C2-2 (`shouldRetryPreStream` dropped everywhere); M1C2-3 (`snapshotProvider` closure + in-flight-epoch rule — no reconstruction, no stale cache); M1C2-4 (single-shot completion API stated: interim stays scripted-only); M1C2-5 (real backoff arming via `retryDeadlineMillis` + tick dispatch + clearing rules); M1C2-6 (operation-scoped credential closure); M1C2-7 (connection-count oracle); M1C2-8 (NET-06 single-filter coverage noted).

Rev3 → rev4 (reviewer M1C3-1..3): M1C3-1 (tick dispatch IS the one policy resend path — "no auto-resend" scoped to transport/actor-initiated resends); M1C3-2 (dispatch location = `tick` row in `SessionTransition`; explicit no-op otherwise; counter increments at ARM time); M1C3-3 (Q1 retired; probe packet reworded — no such invocation field exists).

Rev1 → rev2 (reviewer M1C-R1..R11, NEEDS-EVIDENCE):

- R1 (Blocker): `ChatMessage`/`NativeToolCall` moved to Core (`ChatMessage.swift`); Providers maps to wire JSON; §2.1/2.2/4 updated — the graph compiles.
- R2 (Major): retry seam decided — adapter classifies (`TransportFailure`, no loops) + actor catch maps to the classified event; transition policy stays the sole retry authority; NET-05 end-to-end via test-only `FlakyTransport` (preSend failure once, then real adapter) driving the production actor. `shouldRetryPreStream` as a third locus is dropped.
- R3 (Major): population seam decided — closures (`messageProvider`, `credentialProvider`, `snapshotProvider`) injected at transport construction; synthetic/history-backed suppliers in tests/CLI, store reader in M1-D. `ProviderInvocation.messages` defaulted field dropped from the plan (no inert fields).
- R4 (Major): transport reads per-invoke `snapshotProvider()` + `authorizeRequestDestination` immediately before dial, endpoint-only dialing; mutated-snapshot refusal test (M1-A H1 precedent re-pinned).
- R5 (Major): identity-only `Accept-Encoding`; server-sent `Content-Encoding` refused; caps measure wire bytes; gzipped-response variant added.
- R6 (Major): CLI→Providers dep added to the Package row (AsyncHTTPClient stays inside Providers).
- R7 (Minor): actor-in-loop named (NET rows via closures+flaky; WIRE via adapter-direct; DX via scripted); probes add last-wins, prefix-guessing, 9th-call evasion.
- R8 (Minor): keys = native id; per-call cap accumulates across fragments/indices; 8-counts-distinct-ids; id-reuse-across-indices and mid-index id-change rejected; variants added.
- R9 (Minor): probe packet exact cap 4 KiB + fixed-literal audit + canary test.
- R10 (Suggestion): reasoning passthrough + WIRE-09 + DX-05 retained with tightened scope (capture-only, no cross-provider replay semantics).
- R11 (Suggestion): DNS/peer explicitly out of M1-C.

