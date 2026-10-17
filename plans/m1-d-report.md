# M1-D closeout report — headless `needletail run`, JSONL, transcript, raw ring (integration)

> Reports attest to work already executed; never promise later evidence.

## Identity

- Milestone / slice: M1-D implementation (fourth M1 minor). This report covers the work from `8c3ce24`.
- Authorized baseline: `8c3ce24` (M1-C closed locally). Subject base: uncommitted workdir; no separate M1-D plan digest; implementation contract is `plans/m1-d-delta.md`.
- Head SHA: workdir (uncommitted; treat the diff against `8c3ce24` as the reviewable digest).
- Dependency-lock digest (`Package.resolved` sha256): `de95226e…cc` (unchanged).
- OS / toolchain / architecture: Linux x86_64, Swift 6.4.0, SwiftPM `-j 4 --disable-automatic-resolution`, single test worker.
- Implementation scope: headless `needletail run`, JSONL envelopes, transcript-backed messages, bounded raw ring, timers, incremental deltas, fail-closed CLI auth, scripted tool backend, demos, tests.

## Scope

- Cases in scope: CORE-01, HEAD-01, HEAD-02, HEAD-03. Regression: BDD-06 (review process), BDD-08 replay under `./dev test quick`, M0/M1-A/B/C layers via `dev test offline`.
- Changed artifacts:
  - Added: `Sources/NeedletailCLI/RunCommand.swift`, `Sources/NeedletailCore/Transcript.swift`, `Sources/NeedletailCore/UISink.swift`, `Sources/NeedletailRuntime/FileHandleUISink.swift`, `Sources/NeedletailProviders/ScriptedToolBackend.swift`, tests (BoundaryVerificationTests, M1DCasesTests, TimerLoopbackTests, BackendTests, Transcript*Tests) and demos (`demo/m1d-*.py`, `demo/tools.json`).
  - Modified: `RunCommand` behavior (fail-closed default auth, explicit `--trusted`, sealed mode, max-turn validation, structured run_finished, numbered transcript paging); `ChatTransport` (throwing message provider mapped to preSend); `Package.swift` (AsyncHTTPClient/NIOCore direct edges for CLI); `dev` (single-worker test serialization); existing tests described above for flake margins.
- Invariants touched: no duplicate canonical history in `SessionState`; DurableRecord transcript records stay store-paged; exact native arguments through proposals; bounded JSONL sinks (8 records, 16 MiB ring); closed consumer → exit 130; default authorization denied.

## Evidence

- `swift build --build-tests` rc=0.
- `swift build --product needletail` rc=0.
- `swift test --parallel --num-workers 1` rc=0 on the reviewed/fixed workdir.
- `./dev test offline` → OFFLINE OK.
- `./dev release-bundle` → dynamic bundle, `NeedletailCLI` version 0.3.0; static build recorded as failed and fell back.
- `./dev test packaging` → CLEAN-HOST SMOKE OK.
- `demo/m1d-negatives.py` → NEGATIVE DEMOS PASSED (10 scenarios).
- `demo/m1d-bdd06-probes.py` → BDD-06 probes pass (p10-p14) and baseline restored.
- Independent review: one GLM whole-system review (DeepSeek request was cancelled by the tool scheduler) returned NEEDS-CHANGES initially. B1 and several majors were then fixed; the remaining non-blocking follow-ups are listed.

## Results

### Gate matrix

| Gate | Result |
|---|---|
| Core fast suite | green |
| `swift test --parallel --num-workers 1` | green |
| `./dev test offline` | green |
| Release bundle | green (dynamic fallback) |
| Clean-host smoke | green |
| 10 negative scenarios | green |
| BDD-06 5 probes | green (each red-to-green-confirmed then restored) |
| BDD-08 replay | green |

### Blockers fixed after review

- **B1** `RunCommand` no longer substitutes the bare prompt for `TranscriptError.pageOverflow`; the paging error now surfaces as a preSend `TransportFailure`, and the direct code-level swap is removed.
- **M1** run wall timeout scales with per-turn request timeout and turn limit instead of a flat 60 s.
- **M2** `run_finished` payloads are now structured (`outcome` + `reason`) in both sinks.
- **m1** `--max-turns` help now says default 80.
- **M5** `Package.swift` declares AsyncHTTPClient and NIOCore as direct edges for NeedletailCLI.
- **m7** `EphemeralStore` records no longer report a false next cursor at an exact page edge.
- **m10** unknown `--format` values fail as argument errors.
- Defense-in-depth JSON-object argument shape check added to `ScriptedToolBackend`.
- **m12** report/receipt closeout created.

### Known residual follow-ups (non-blocking for local evidence, disclose in PR)

- SIGINT now drives production cancellation, emits terminal `run_finished` where the JSONL sink remains writable, and returns exit 130; closed-pipe cancellation remains distinct.
- Incremental JSONL delivery uses a single bounded queue with sink locking; delta delivery drains before pairing, and the queue owns its consumer (H1).
- `InMemoryUISink` sequence locking and minor emitter same path can still be tightened.
- `terminalSafe` preserves NUL/ESC/newline escape semantics; human final text newline layout is conservative (single line).
- Trace file close is invoked after a deferred close with ignored errors; double-close is harmless but can be tightened with ownership transfer if desired.

## Independent review + fixes

- Independent review: GLM whole-system review returned ready-with-changes before the above parent scope fixes.
- Disposition after this report's changes:
  - B1, M1, M2, M1, M5, m7, m10, and the argument-shape defense remain coded and locally verified.
  - Minor polish calls remain available for a follow-up patch, none of which corrupt the accepted M1-D evidence matrix.

## Recommendation

Locally ready for the prep-and-merge-approval posture, after one final review on the re-scoped diff. Do not merge without owner approval.
