# M1-A closeout report — strict configuration, capabilities, immutable profiles

> Reports attest to work already executed, never promise later evidence.
> M1-A implementation per plan rev5 (`71d91dac…59e0`) under the M1-A
> implementation authorization (test-first, 10 cases, no push/PR/M1-B).

## Identity

- Milestone / slice: M1-A implementation (first M1 minor).
- Base SHA: `e3c0527` (M0-merged `main`; working tree at slice start held only the prior planning files).
- Head SHA: (S-fix commit hash — filled at commit; final review binds it; recorded in `plans/m1-a-receipt.md`).
- Plan digest (`plans/m1-a-plan.md` sha256, rev5): `71d91dacde132077a6ffb8e5a2f1d4320c417e79387983184d6e6a5ec89659e0` (381 lines).
- Dependency-lock digest (`Package.resolved` sha256): `de95226ee800ecb7609e5d8083d7c14dc4bc1f1ddbb2deabf1b23f1d7a8689cc` (unchanged — no dependency delta).
- OS / toolchain / architecture: Linux 7.0.0-31-generic x86_64, Swift 6.4.0 (swift-6.4-RELEASE), SwiftPM `-j 4 --disable-automatic-resolution`.
- Implementer: `muse-spark-1.3-contributor`. Reviewer: `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash`.

## Scope

- Cases in scope (10): CFG-01, CFG-02, CFG-03, CFG-04, CFG-05, CFG-06, POLICY-02, POLICY-05, NET-01, NET-06 (offline half only — PARTIAL).
- Invariants touched: I01 (no network on inspection), I03 (epoch stability), I06 (sealed/tools-none monotone over tools, rev4-B), I09 (local-only never cloud), I12 (repo text cannot move grants/credentials/routes).
- Changed files:
  - Added: `Sources/NeedletailCore/{ConfigError,ConfigLimits,ConfigDuplicatePreflight,ConfigDocument,ConfigLoader,ModelProfile,Capabilities,RouteDecision,CredentialReference}.swift` (9), `Sources/NeedletailRuntime/{EnvFileCredentialStore,KeychainCredentialStore}.swift` (2), `Sources/NeedletailProviders/LocalChatProfile.swift` (1), `Sources/NeedletailCLI/{ConfigValidate,DoctorProbe}.swift` (2), `Tests/NeedletailConfigTests/*.swift` (12 files), `Tests/NeedletailConfigIntegrationTests/*.swift` (3 files), `schemas/config.schema.json`, `examples/config.local.json`.
  - Modified: `Package.swift` (2 test targets), `dev` (quick filter, case product-build + NEEDLETAIL_BIN, offline aggregate, usage), `Sources/NeedletailCLI/{NeedletailCLI,Doctor}.swift` (subcommand + probe option), `STATUS.md`, `plans/m1-a-plan.md` (rev4/rev5), `plans/m1-a-receipt.md`.
  - Deleted: none. `Archive.zip` was found deleted mid-session by unknown cause and restored byte-identical from HEAD (see receipt addendum).
- Dependency delta vs M0: none. New targets reuse pinned `swift-subprocess` (spawn) and `swift-system` (binary path); no new packages.

## Evidence (verbatim commands; logs under `.needletail-dev/logs/`)

- `./dev build` → `m1a-ev-build.log`, rc=0 (3.5 s incremental; full-graph cold build not re-measured — graph unchanged since M0).
- `./dev test quick` → `m1a-fix-quick.log`, rc=0: PrimitiveTests 14/5 suites 2.071 s, ConfigTests 63/11 suites 0.024 s, BehaviourTests 20/3 suites 0.013 s. Quick stays ≤3 s warm.
- `./dev test case CFG-01|CFG-02|CFG-03|CFG-04|CFG-05|CFG-06|POLICY-02|POLICY-05|NET-01|NET-06` → `m1a-fix-case-<ID>.log`, all rc=0, zero-match guard satisfied (15/19/10/3/7/6/7/3/8/2 test executions; CFG-05 includes the M0 `VersionIdentityTests.CFG-05` precedent oracle).
- Spawn integration: `m1a-fix-int.log`, 18 tests in 2 suites, all green (binary `.build/debug/needletail`).
- `./dev coverage` → `m1a-ev-coverage.log`, rc=0 (catalogue untouched: BDD-04 pins M0 vocabulary until the M1 epic).
- `./dev test native` → `m1a-ev-native.log`, 14 tests green (M0 regression).
- `./dev test feasibility` → `m1a-ev-feasibility.log`, 6 tests green (M0 regression).
- `./dev vendor-check` → `m1a-ev-vendor.log`, rc=0.
- `./dev release-bundle` → `m1a-ev-bundle.log`, dynamic bundle, 4497432 bytes (larger than M0's 3646992 — new M1-A code, expected).
- `./dev test packaging` → clean-host smoke OK (digest-pinned ubuntu, `--network none`).
- `./dev test offline` → `m1a-ev-offline.log`, OFFLINE OK (new aggregate: quick+native+feasibility+coverage+10 cases).
- No-leak: canary-laden `config validate [--sealed]` → 0 canary hits on stdout+stderr (`m1a-fix-noleak.log`); release binary in `--network none` container runs validate+doctor cleanly with 0 canary hits and `NONET-OK` (`m1a-noleak-nonet.log`); live FIFO/conflict probes exit 2 with exact kinds, no hang.
- S-fix series (`m1a-fix-*.log`): pure 63/63, integration 18/18, quick/coverage/native/feasibility green, bundle dynamic, packaging smoke OK, offline aggregate OFFLINE OK.
- RED: `m1a-red-compile.log` + `m1a-red-pure.log` (tests reference absent APIs — compile failure, recorded as such, not an assertion pass); `m1a-green-pure-*.log` assertion failures drove fixes (optional-port rendering, path whitespace, byte-exact dup checks, toolchain JSONError quirk, test-literal bugs — each fixed, none waived).
- GREEN: `m1a-green-pure-9.log` (60/60), integration 16/16.
- Wrong-impl probes (disposable production patches, each RED then byte-identical restore; no PROBE markers remain): P1 union-grant (14 failures), P2 strip-reserved (13), P3 cloud-fallback (8), P4 zero-strip IDs (10), P5 unconditional-/v1-prepend (10), P6 prefix-drop (6), P8 last-flag-wins (7). Logs `m1a-probe-p*.log`.
- Toolchain probes: `/tmp/opencode/probe-*.swift` (float-to-Int `JSONError` → `dataCorrupted` quirk that forced the `decodeInt` catch-all).

## Results by evidence layer and platform

| Layer | Platform | Cases | PASS | FAIL | BLOCKED_REVIEW | UNQUALIFIED_ENVIRONMENT | DEFERRED_BY_PLAN | NOT_IMPLEMENTED |
|---|---|---|---|---|---|---|---|---|
| pure | Linux x86_64 | CFG-01..06, POLICY-02/05, NET-01 | 9 | 0 | 0 | 0 | 0 | 0 |
| pure (tooling) | Linux x86_64 | ARCH-import-gate (non-case) | 2 tests | 0 | 0 | 0 | 0 | 0 |
| integration | Linux x86_64 | CFG-01..06, POLICY-02/05, NET-01 | 9 | 0 | 0 | 0 | 0 | 0 |
| integration | Linux x86_64 | NET-06 offline half | PARTIAL | 0 | 0 | 0 | traffic half | 0 |
| packaging | Linux x86_64 | clean-host smoke | pass | 0 | 0 | 0 | 0 | 0 |
| (all) | Linux x86_64 | other 35 M1 cases | 0 | 0 | 0 | 0 | 35 (M1-B/C/D) | 0 |

One passing variant never satisfies all variants: per-variant IDs, G/W/T, forbidden effects and RED/GREEN are in `plans/m1-a-plan.md` §7/§9 and the test bodies.

## Focused deviations from rev5 plan (for slice review)

- D-a. Two test targets (pure + spawn-integration) instead of one tagged suite — `swift test --filter` cannot split one target, and quick must stay ≤3 s without spawns.
- D-b. `WireProtocol`/`Locality` mirror enums in Core (Providers' `NativeProtocol`/`LocalityClass` untouched) — otherwise Core→Providers inversion; vocabularies pinned equal by an integration test.
- D-c. Empty `models:[]` rejected (`missingField`) — R13 requiredness (`default_model` must reference) beats the vague tool-less sentence.
- D-d. Canonical-collision refusal (aliases + object keys): byte-distinct but canonically-equivalent names are rejected loudly, never merged — a snapshot dictionary could not hold both.
- D-e. `ToolCapabilities.grant(fromUntrustedSource:)` throwing helper — the R9 refusal mechanism made testable.
- D-f. `test offline` aggregate implemented (dormant since M0-D) + `test case` product build with `NEEDLETAIL_BIN` — required by the run-evidence authorization.
- D-g. `decodeInt` catch-all — toolchain throws private `JSONError` (not `DecodingError`) for fractions-as-Int, re-wrapped as misleading `dataCorrupted`; probe-verified.
- D-h. `requestOptionsRaw` via preflight ranges; epoch compare on raw bytes; canonical serializer for determinism (typed numbers canonicalize; raw stays verbatim).
- D-i. Doctor probe: unknown alias → exit 2; known alias → exit 4 deferred; `config validate` prints an advisory `default-route` line at exit 0.

## Review

- Plan reviews: rev1 NEEDS-EVIDENCE (15 findings) → rev2 NEEDS-EVIDENCE (3 minor residuals) → rev3 READY → rev4 targeted delta NEEDS-EVIDENCE (D1 Major + D2–D4) → rev5 corrections implemented. Receipt: `plans/m1-a-receipt.md`; raw: `.needletail-dev/logs/m1a-plan-review-*.md`.
- Completed-slice review (head `0ec46ed`): NEEDS-EVIDENCE — S1 Major (FIFO hang) + S2–S7 Minor + S8–S11 Suggestions; D-a..D-i all ACCEPTED (D-c with plan correction). Raw: `.needletail-dev/logs/m1a-slice-review.md`.
- S-fix implementation: S1 Runtime `readBoundedFile` + O_NONBLOCK credential open + FIFO/symlink tests; S2 snapshot `requiresNewEpoch` overload + tests; S3 real-escape + lone-surrogate oracles; S4 (this series re-runs the full 18-test integration target); S5 normalized identity + test; S6 `<= maxFileBytes`; S7 `validate --sealed/--tools` production caller + `invocation:` echo + spawn conflict tests; S8 decoded-backslash rejection + tests; S9 snippet-free refusal; S11 locality assertion. Plan rev6 (`eb322bee…73041d`) documents all of the above and supersedes the empty-models sentence.
- H1/H2 hardening (post-closeout inspection): immutable validated state + re-derived route authorization + `authorizeRequestDestination` M1-C seam (NET-01 `mutated-profile-denied`, red→green in `m1a-h1-red.log`); `terminalSafe` display boundary (CFG-02/CFG-05 variants + CLI byte assertions, red→green in `m1a-h2-red-pure.log`). Evidence: pure 67, integration 20, quick/coverage/native/feasibility/vendor/bundle/packaging/offline green (`m1a-h-ev-*.log`); bundle 6175248 bytes dynamic; no-leak byte counts 0/0/0 (`m1a-h-noleak.log`). Plan rev7 (`44995364…5bf9b33`) §16. Targeted review below.
- Final review: **READY TO CLOSE** bound to head `a76022c` on baseline `e3c0527` (S8-only delta verified: two `%5C` inputs, 18+1 CFG-02 green, 97-test quick green; S1 Major stays closed; tree clean). Implementation commits: `f7f2628` (slice) + `0ec46ed` (report) + `130176e` (S-fixes) + `a76022c` (S8 test). No push/PR/merge.

## Limitations and gate status

- Known limitations: ACLs beyond mode bits undetected (documented); `workspaceGrant` deny-all default until M2 `trust`; exit-4 reuse for probe deferral (no SPEC deferral code; labeled deferred-not-failed); canonical-collision pairs refused (D-d); empty-models refused (D-c); M1-A routes local-only, cloud denied; probe traffic + transport are M1-C; session/actor/epoch transition is M1-B (types handed off: `ConfigSnapshot`, `ProfileSnapshot`, `EffectiveCapabilities`, `requiresNewEpoch`).
- No macOS code, no new dependencies, no provider traffic, no M1-B state machine.
- Gate status: implementation complete with evidence; **held for independent completed-slice review** (authorization step 5), then STATUS update. No push/PR/merge (M1-epic CodeRabbit is the later aggregate gate).
