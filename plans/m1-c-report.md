# M1-C closeout report — native Chat Completions streaming over loopback

> Reports attest to work already executed; never promise later evidence.

## Identity

- Milestone / slice: M1-C implementation (third M1 minor).
- Authorized baseline: `50c625b` (M1-B closed locally). Subject base: `df0b1ea` (M1-C planning closeout, planning files only — no source delta).
- Head SHA: workdir (uncommitted; slice review binds the workdir digest, commit follows READY).
- Plan digest (`plans/m1-c-plan.md` sha256, rev4): `b39618d2…` (per `plans/m1-c-receipt.md`).
- Dependency-lock digest (`Package.resolved` sha256): `de95226e…cc` (unchanged — NIOHTTP1/NIOCore/AsyncHTTPClient/OpenAPIRuntime all resolve inside the existing lock; no new package).
- OS / toolchain / architecture: Linux x86_64, Swift 6.4.0, SwiftPM `-j 4 --disable-automatic-resolution`.
- Implementer: `muse-spark-1.3-contributor`. Reviewer: `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash`.

## Scope

- Cases in scope (17): WIRE-01..10, NET-02..05, NET-06, DX-04/05. BDD-06 review-process (7 probes below). NET-01 stays M1-A (route units); STATE-02 stays PARTIAL (M2); M1-D owns the actor loop + demos.
- Invariants touched: I07 (no auto-retry — single retry authority stays actor-side; adapter never retries), I09 (local-only — authorize-before-dial + redirect/proxy floor), I21/I24 (bounded intake, stream/line/call caps).
- Changed files:
  - Added: `Sources/NeedletailCore/ChatMessage.swift`, `Sources/NeedletailProviders/{ChatAssembly,ChatTransport,TransportPolicy,SSEBounds,ProbeRoute}.swift` (5), `Sources/NeedletailTestSupport/LoopbackSSEServer.swift` (1), `Tests/NeedletailProviderTests/` (3 files, 15 tests), `Tests/NeedletailProviderIntegrationTests/` (5 files, 24 tests), `Tests/NeedletailStateTests/RetryBackoffTests.swift` (4 tests).
  - Modified: `Package.swift` (NIOHTTP1 product in Providers; AsyncHTTPClient product in the integration target), `Sources/NeedletailCore/{SessionTransition,SessionState,SessionEvent,SessionActor}.swift` (retryDeadlineMillis, tick dispatch, TransportFailure catch, probe-era DoctorProbe upgrade), `Sources/NeedletailCLI/{DoctorProbe,Doctor}.swift` (deferral stub → production `probeRoute`; corrected `--probe` help), `Tests/NeedletailConfigIntegrationTests/CredentialIntegrationTests.swift` (NET-06 deferral test → refused-honestly), `Tests/NeedletailProviderTests/{BoundsTests,StreamSemanticsTests}.swift` (wrong-precise expectations corrected), `Tests/NeedletailStateTests/RetryBackoffTests.swift` (cancel/grace disambiguation), `Tests/NeedletailPrimitiveTests/TransportCancellationTests.swift` (4 EventLoopFuture shutdown awaits), `dev` (offline +17 M1-C cases, NET-06 deduped from M1-A list).
  - Deleted: none.
- Authorization corrections honored: plan rev4 R1-R11 + M1C2-1..8/M1C3-1..3/M1C4-1/2 (single retry authority actor-side, authorize-before-dial with live snapshot, no client read-timeout duplication, `[DONE]` sentinel handling, id-keyed assembly, fixed-literal probe packet, CLI exit preservation 0/2/4).

## Evidence (verbatim commands; logs under `.needletail-dev/logs/`)

- `./dev build` rc=0.
- `./dev test quick` rc=0 (178 tests: State 56 incl. 4 RetryBackoff + Primitive 14 + Presentation 19 + Config 69 + Behaviour 20; slowest suite ~2.14 s).
- `./dev test case` ×17 (new M1-C list) — all rc=0 with zero-match guards; run inside the offline aggregate (`m1c-final-offline.log`).
- Pure provider suites: 15/15 (`m1c-final-pure.log`).
- Loopback integration suites: 24/24 — Wire 11 (incl. gzip + 16 MiB refusal), Net 8 (incl. hostile-env, pre-dial preSend pin), DX 3, Actor 2 (production-actor end to end). Full-target greens pre- and post-review; the gate runs each case ID in its own process.
- BDD-06 probes extended for the review fixes: P8 (probe override removed → both R9 wire asserts RED, `m1c-probe-p8.log`) and P9 (verdict box bypassed → both deadline asserts RED, `m1c-probe-p9.log`); both restored byte-identical.
- `./dev coverage` rc=0 (catalogue untouched per BDD-04 M0-vocabulary pin).
- `./dev test native` rc=0, `./dev test feasibility` rc=0 (M0 regression, inside offline).
- `./dev test offline` → `m1c-final-offline.log`, OFFLINE OK (quick + native + feasibility + coverage + M1-A 9 + M1-B 13 + M1-C 17 cases; re-run on the reviewed workdir after the delta fixes).
- `./dev release-bundle` rc=0 (dynamic, 58264000 bytes; `m1c-final-bundle.log`) + `./dev test packaging` clean-host smoke OK (`m1c-final-packaging.log`).
- No-leak: `--network none` container, release binary, canary-laden config (`canary-model-qqq`, `options-canary-qqq`, `credential-canary-zzz`) → `doctor --probe` exit 4 with typed preSend refusal and **0 canary hits** (`m1c-canary-probe.log`).
- BDD-06 wrong-implementation probes, each RED then verified restore (no PROBE markers remain; four source files diffed byte-identical against pre-probe snapshots):
  - P1 `[DONE]` skip removed → WIRE-01 `malformedEvent` RED (`m1c-probe-p1.log`).
  - P2 duplicate identity laundered as parse error → WIRE-05 identity assert RED (`m1c-probe-p2b.log`).
  - P3 call bound 8→80 → WIRE-03 ninth-call refusal RED (`m1c-probe-p3.log`).
  - P4 client read timeout restored (duplicate authority) → NET-04 untyped `HTTPClientError.readTimeout` RED (`m1c-probe-p4b.log`).
  - P5 redirect follow → NET-02b phase+identity asserts RED (`m1c-probe-p5.log`).
  - P6 whole deadline +1000 s → NET-04 whole-cap overrun RED (`m1c-probe-p6.log`).
  - P7 credential truncation → NET-05 wire-exactness RED (`m1c-probe-p7.log`).
- GREEN: pure 15 + loopback 24 + state-retry 4 + CLI probe honesty (spawn, incl. secret-absence) + canary 0/0/0 (audit block inside `m1c-canary-probe.log`).

## Results by evidence layer and platform

| Layer | Platform | Cases | PASS | FAIL | BLOCKED | UNQUALIFIED | DEFERRED | NOT_IMPL |
|---|---|---|---|---|---|---|---|---|
| pure | Linux x86_64 | WIRE-03/04/05/06/07/09/10*, DX-04/05*, NET-05* | 9 | 0 | 0 | 0 | 0 | 0 |
| integration | Linux x86_64 | WIRE-01..10, NET-02..06, DX-04/05 | 17 | 0 | 0 | 0 | 0 | 0 |
| reviewProcess | Linux x86_64 | BDD-06 (7 probes+logs) | 1 | 0 | 0 | 0 | 0 | 0 |
| packaging | Linux x86_64 | canary probe + clean-host smoke | 1 | 0 | 0 | 0 | 0 | 0 |

\* Pure rows where applicable (mapping/assembly/bounds/framing); loopback rows run the production transport over POSIX loopback with per-test ephemeral ports.

## RED→GREEN ledger (behavioral findings fixed forward, not test-weakening)

1. `shutdown()` returns `EventLoopFuture`: awaiting without `.get()` discards it; debug builds trap on un-shut-down deinit, masking the real failure. Fixed at all 6 call sites (production `ProbeRoute` + loopback fixtures + 4 pre-existing `TransportCancellationTests` sites). Unwind-safe `defer` shutdown in every test helper.
2. `[DONE]` terminator rejected as non-JSON: assembler now skips the exact sentinel (terminator ≠ completion — streams ending there without `finish_reason` still fail incomplete).
3. Duplicate deadline authority: client-level read timeout removed (`read: nil`); the supervisor is the sole read-idle/whole authority with typed phases. Supervisor gained a first-wins verdict box so cancellation echoes map back to the typed deadline deterministically.
4. Legacy AHC API: delegate-based `execute` only accepts `HTTPClient.Request` (added NIOHTTP1 product dep); `decodeBounded` yields `ArraySlice<UInt8>`; `ProbeRoute` Swift-6 capture fix.
5. Stale M1-A deferral test: `doctor --probe` really dials now — test rewritten to the refused-honestly contract (exit 4 + secret-absence at CLI layer).
6. Three wrong-precise expectations corrected (9th-call indices, non-final proposal visibility, cancel/grace boundary) — each now pins the actual contract plus the adjacent mechanism.
7. Hand-rolled SSE JSON literals banned from tests (`eventLine` dictionary builder) after an unbalanced-brace escape-layer bug; unused `toolCall`/`awaitConnections` helpers removed.
8. Parallel-only ECONNREFUSED flake (1 in 4 runs, test-support listen lifecycle, never product path): the three loopback suites are `@Suite(.serialized)` with rationale inline; owned follow-up M1C3-3 re-examines the server lifecycle.

## Independent slice review + fixes

Independent review (`deepseek-reviewer` / `opencode-go/deepseek-v4.1-flash`) returned **NEEDS-EVIDENCE**: 4 Majors + 8 Minors, all substantive, all worked (no rejections):

- **NET-03 specified as hostile-env, implemented as status-no-retry.** Added `NET_03_hostileEnvIgnored`: blackholed proxy env (AHC reads proxy only from configuration — verified in its sources) with direct-loopback success pinned server-side, plus https-against-plaintext TLS refusal typed preSend with zero valid requests. A dedicated self-signed-cert fixture is not added: the classification path is identical (handshake failure before any head byte → preSend through the same `classify`), so it would pin no new behavior; recorded here, not as a follow-up.
- **NET-05 end-to-end missing.** Added `ActorLoopbackTests` (2 tests): `FlakyTransport` fail-once decorator over the REAL adapter driving the PRODUCTION actor — submit → classified preSend → armed with zero bytes → explicit `tick(at:)` → single delegated retry → completed over one connection (turnsUsed 2); plus mid-stream FIN → failed outcome → actor fails with no armed deadline and silent post-ticks. `SessionActor.perform` timer no-ops are untouched (M1-D wires timers; explicit-time ticks drive all of this).
- **RawTranscript unmet.** Decision (reviewer-permitted): verbatim-byte RETENTION is deferred to the consuming layer (new follow-up **M1C3-4**, owned by M1-D/M2 session-record design) — no consumer exists in M1-C, the frozen `TransportResult` shape carries none, and per-turn retention has lifecycle implications for the actor to design. Wire FIDELITY (exact strings/ids/ numerics, no normalization) is implemented and pinned by WIRE-07 + pure rows; only retention is deferred. No report claim asserted otherwise.
- **Probe packet not fixed-literal on the real path.** Added `ChatRequestOverride` (transport field, default nil); `probeRoute` injects max_tokens 16 + empty options; deleted the dead `probePacketBody` (wrong hardcoded model); DX-04 loopback now asserts the captured bytes exactly (max_tokens 16, no operator keys, ≤ 4 KiB, fixed message literals) against a profile carrying options + budget; pure test rebuilt on the same constants.
- Minors: whole-deadline branches on `sawHead` (pre-head trip is preSend; unreachable except ties under connect ≤ read_idle ≤ request — defensive, no dedicated test by construction); all four pre-dial throws wrapped preSend at site (+ `NET_02a_preDialPreSend` pin); gzip-refusal + 16 MiB-stream tests added (`WIRE_03_gzipAndStreamCapRefuse`); mismatch surfaces via `returnedModel` (dead construction removed, channel documented); `returnedModel` passed through on the incomplete branch; `ChatCompletionsRequest` + `unterminatedTailLength` deleted; Doctor `--probe` help corrected; NET-06 removed from the M1-A offline list (fully covered by the M1-C list — no double execution).
- Serialization risk (reviewer Minor 11): accepted explicitly. The GATE (`dev test case` per CASE-ID) runs each case in its own process, so cross-test contention cannot occur where it counts; in-target `@Suite(.serialized)` covers repeated `swift test` runs (4 consecutive greens). Root-cause re-examination stays with M1C3-3.

## Limitations / follow-ups

- M1C3-3 (server productionization) owns the parallel-lifecycle re-examination above.
- M1C3-4 (new): RawTranscript retention design for the consuming session-record layer (M1-D/M2).
- NET-06 CLI spawn asserts refusal (nothing listens in CI); qualified-success output shape is pinned by the DX-04 loopback test instead.
- Whole-request floor is supervisor-enforced (no client equivalent exists); supervisor starvation degrades to later — never wrong — failure.
- STATE-02 remains PARTIAL (M2); M1-D owns actor wiring, demos, and epic PR.
