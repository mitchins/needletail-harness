# M0-A / M0-B plan — Linux build foundation and dependency primitives

Slice type: minor milestones M0-A (bootstrap, case ledger, review) + M0-B (dependency graph and native primitives).
Status: PLAN REVIEWED by `deepseek-reviewer` (receipt: plans/m0-a-b-receipt.md); READY with dispositions folded in. Baseline commit: 86a717b0fda17d7690ce97b3161110cd169f5d33 (tree: spec packet files untracked).
Prepared: 12 October 2026 by implementer route `opencode-go/step-5-preview-free` (verified from `opencode models`).

## 1. Goal

Establish the actual Linux x86_64 / Ubuntu 24.04 build/test foundation for Needletail with recorded evidence:

- M0-A: source layout, `./dev` entry points, native Swift Testing bootstrap, frozen 200-case ledger with reconciliation that can never report a missing/skipped/unexecuted case as passing, `STATUS.md`, MIT licence/notices scaffolding, `.gitignore`.
- M0-B: resolve the seven candidate pins on Linux, commit the real `Package.resolved`, and qualify minimal native primitives (streamed HTTP + SSE framing + cancellation; subprocess dual-pipe drain; SQLite reopen) against the selected production libraries.

What this slice is NOT: the replxx PTY spike (M0-C), the clean-runtime bundle/CI/CodeRabbit epic review (M0-D), any terminal UI work, macOS work, or any product behaviour beyond bootstrap scaffolding. Consistency with START-HERE: "do not spend the first milestone drawing the finished terminal."

## 2. Recorded baseline (already executed, evidence retained)

| Fact | Value | Source |
|---|---|---|
| Git state | commit 86a717b, untracked: COMPLETE-SPEC.md, DEPENDENCIES.md, ._* (AppleDouble junk, do not commit) | `git status` |
| Remote | `git@github.com:mitchins/needletail-harness.git` configured; push/PR NOT authorized this session | `git remote -v` |
| OS | Ubuntu 24.04.4 LTS x86_64, kernel 7.0.0-31-generic (24 cores, 80 GiB RAM; `/` 93% full, `/data` 1%) | `uname`, `free`, `df` |
| Swift | 6.3.3 via swiftly at `/home/mitch/.local/share/swiftly`; **6.4.0 available, not installed** | `swiftly list-available` |
| Implementer model | `opencode-go/step-5-preview-free` (exact entry from installed listing; `opencode/step-5-preview-free` also listed — do not assume interchangeability) | `opencode models` |
| Reviewer | `deepseek-reviewer` subagent, model `opencode-go/deepseek-v4.1-flash`, edit deny, bash allowlist git/status/log/npm only. Independent of implementer; no secrets copied. | `~/.config/opencode/opencode.jsonc` |
| rg / git / sqlite3 | rg 14.1.0, git 2.43.0, sqlite3 CLI 3.45.1; **no `sqlite3.h` anywhere; `libsqlite3-dev` not installed** | `which`, `dpkg -l` |
| Permitted scratch roots | repo-local `.needletail-dev/` (gitignored, raw evidence), repo-local `.build/` (gitignored), `/tmp/opencode/` (this session's probe scratch). No other scratch roots; no home/mail/private-repo traversal. | this slice, recorded in STATUS.md |

Dependency evidence already established (scratch graph in `/tmp/opencode/needletail-probe`, log `/tmp/opencode/probe-build*.log`):

1. Seven candidate pins resolve on Linux → **26-pin transitive graph** including GRDB 7.11.1 (nio 2.104.0, nio-ssl 2.37.5, swift-certificates 1.21.0, http-types 1.8.0, etc.).
2. replxx revision `1f149bfe…` is NOT a SwiftPM package (no `Package.swift` at that ref; C++/CMake project). It cannot be a package dependency; it must be vendored with a SwiftPM C/C++ bridge target exactly as DEPENDENCIES.md says ("vendored C/C++ code"). Deferred to M0-C; recorded here so the plan is not surprised by it.
3. Six of seven pins **build and link on Linux** with Swift 6.3.3 (32.3 s warm, incremental; probe executable runs `ok`; links libswift*, libdispatch, libstdc++, libz, glibc). The build-verified subset's on-disk lock holds **25 pins** (held-out GRDB drops back out on re-resolution); the full 7-pin resolution is 26 pins and will be re-established and recorded in the workspace during this slice.
4. **GRDB 7.11.1 fails to build**: its `GRDBSQLite` system-library target requires `<sqlite3.h>` (`Sources/GRDBSQLite/shim.h:1`). Builder lacks `libsqlite3-dev`. No fabricated graph, no downgrade: recorded as finding **F-1**, decision routed to operator (D-2). While D-2 is open, GRDB is **declared in the manifest but product-linked by no target**, so no build failure is induced and no SQLite pass is implied (DR-01).

## 3. Decisions required from the human maintainer (routed, not assumed)

- **D-1 Swift toolchain:** spec pins Swift 6.4 / Swift 6 language mode; installed is 6.3.3, with 6.4.0 available via `swiftly install 6.4` (user-local under `$HOME/.local/share/swiftly`, no sudo). Options: (a) install 6.4.0 and build on the pinned toolchain; (b) continue on 6.3.3 and record a documented deviation for M0–M3, re-qualify before release. Implementation starts under the installed 6.3.3 only if the operator declines (a); nothing in this slice requires 6.4-only language features.
- **D-2 SQLite for GRDB:** (a) operator installs `libsqlite3-dev` on the builder (matches GRDB's declared provider; release then links target-OS SQLite, which DEPENDENCIES.md permits when documented); (b) vendor a pinned SQLite amalgamation and add a documented build-time include path (`-Xcc -I…`) plus an amalgamation target for release bundles (self-contained, no OS dev package); (c) hold GRDB out of the graph until a decision, keeping the rest of M0-B moving. Recommend (a) now, revisit (b) at M0-D/M6 packaging qualification. Until ruled, the SQLite-reopen primitive probe carries `UNQUALIFIED_ENVIRONMENT` (missing OS headers; separate from test verdicts) and the D-2 request itself is `BLOCKED_REVIEW` — never skipped-into-pass.
- **Status vocabulary (DR-06):** all slice records use the official set `PASS`, `FAIL`, `BLOCKED_REVIEW`, `UNQUALIFIED_ENVIRONMENT`, `DEFERRED_BY_PLAN`, `NOT_IMPLEMENTED`, with test/review/environment status kept as separate fields (DEVELOPMENT §6).

These do not block M0-A implementation or the non-GRDB M0-B probes.

## 4. Case IDs in scope (from the frozen catalogue)

In scope now (M0-A/M0-B portions): **BDD-01** (catalog↔spec ID reconciliation), **BDD-02** (variant vs semantic-case counting), **BDD-03** (no executed body ⇒ not covered), **BDD-04** (skipped/filtered ⇒ due gate unsatisfied), **PORT-01** (Linux gates run; macOS DEFERRED_BY_PLAN), **DX-08** (offline `swift test` with no Node/Python), **DEV-01** (implementer route availability recorded), **REV-01/REV-02** (plan review before implementation; reviewer independence).
Feeding later milestones (evidence captured now, not claimed passed): PKG-03/PKG-04 (locked-graph build, inventory), PORT-02 (no platform leakage), STORE-01/02 (SQLite reopen — blocked by D-2), WIRE-01/WIRE-02/WIRE-04 (SSE framing probes), PROC-01 (dual-pipe drain), NET-05 (cancellation).
All remaining catalogue entries: `NOT_IMPLEMENTED` or `DEFERRED_BY_PLAN` in `cases/catalog.json`, never counted as passes.

## 5. Invariants the bootstrap itself must not violate

I01 (no network on startup/build/test paths), I02 (no runtime downloads), I12 (repo files cannot change grants/credentials — at this stage: no repo-controlled config paths exist yet), plus PROCESS guardrails: no sudo/host reconfiguration, no Node/Python install, no provider calls, no touching the model-serving workloads.

## 6. Given/When/Then outcomes (behaviour contracts)

1. **BDD-01:** Given the 200-ID catalogue frozen from ACCEPTANCE.md, when a test or catalog entry references an unknown or missing ID, then reconciliation fails with the exact identifier and nothing is silently counted.
2. **BDD-02:** Given ten seeded variants of one behaviour, when coverage is reconciled, then one distinct semantic case is counted and variants are reported separately.
3. **BDD-04/BDD-03:** Given a case whose only test is skipped, filtered, or has no executed body, when `./dev coverage` runs, then the due gate is reported unsatisfied (FAIL/BLOCKED), never PASS.
4. **REV-01:** Given no completed independent review of this plan, when implementation would start, then the slice gate blocks (this document's review receipt is that gate).
5. **Dependency evidence:** Given the committed `Package.resolved`, when the graph is rebuilt in a clean checkout, then the same revisions are resolved (PKG-03 path; full clean-host proof deferred to M0-D).
6. **SSE framing:** Given raw wire bytes split at every boundary (including multi-byte UTF-8), when the OpenAPIRuntime parser consumes them, then decoded events match the unsplit reference (WIRE-01/WIRE-02 at primitive tier).
7. **Cancellation:** Given an in-flight request against a synthetic loopback server, when the client cancels, then the request task finishes bounded, descriptors close, no retry occurs (NET-05 path).
8. **Subprocess:** Given a child flooding both pipes, when drained via Subprocess, then both streams complete without deadlock and output is bounded (PROC-01 at primitive tier).
9. **SQLite reopen:** Given a GRDB database written and closed, when reopened natively, then records persist (STORE-01) — `UNQUALIFIED_ENVIRONMENT` while D-2 is open, visible in evidence with its own field, not skipped-into-pass and not counted toward any gate.

## 7. Forbidden effects

Any network call outside the synthetic loopback tests; automatic retry after cancellation; installing dev packages/Node/Python; modifying the shared SwiftPM cache checksouts; claiming replxx qualified at M0; claiming SQLite qualified while `UNQUALIFIED_ENVIRONMENT`; committing secrets; regenerating fixtures from the code under test; treating reviewer absence as self-review; pushing to the remote.

## 8. Proposed seams (architecture gates §8, ARCHITECTURE-NOTES §1)

SwiftPM package `needletail` with targets that match the v0.3 architecture, created as thin, real seams — no frameworks:

- `NeedletailCore` — one real pure value type at M0-A (`NeedletailVersion`, used by the CLI entry and by reporter tests); no I/O, no platform imports. `NeedletailProviders` and `NeedletailRuntime` are created with one real value type each (`ProviderIdentity`, `WorkspaceRoot`) so the layout exists without fabricating behaviour (architecture §4; architecture gate: no Core import of terminal/HTTP/SQLite implementations).
- `NeedletailPresentation` is **deferred to M1-B** (DR-03): SPEC §4 says the fifth target begins in M1, so M0-A does not create it.
- `NeedletailCLI` — composition root; M0-A gives it a minimal real `--version` entry used later by the M0-D smoke.
- `NeedletailTestSupport` — the behaviour-case ledger (`CaseLedger`: caseID, variantID, evidenceLayer, status vocabulary) and the results-reconciliation helpers (DR-09: ledger types live here, not in Core). Target review threshold 500 hand-written lines (TESTING §2).
- Tests: `BehaviourTests` (case-labelled Swift Testing), `NeedletailPrimitiveTests` (M0-B native probes), and `QualificationProbes` (intentional pass/fail/skip/parameterized demonstrations, excluded from the default green run by tag).

`./dev` is a POSIX `sh` script (no Python/Node; Swift Testing is toolchain-provided) implementing, per TESTING §4 (DR-02/DR-08):

- real now: `build`, `test quick`, `test native` (runs the M0-B primitive probe subset: SSE/cancel/subprocess), `coverage`, `test case CASE-ID`;
- present but explicitly disabled with a recorded reason: `test integration` (M2), `test terminal`, `test pty` (M4), `test live` (M5/release, disabled by default), `test offline` (aggregate, due at M0-D).

Result-format qualification (DR-11): before adopting any reporter, empirically qualify the installed toolchain's documented machine-readable route (`swift test` flags for listing/filtering/exit codes) with intentional fixtures; record which route exists; if no stable per-case machine format exists on the pinned toolchain, fall back to bounded per-case invocation/exit records (TESTING §2) — no invented flags or undocumented SPI.

## 9. Changed files (planned)

`Package.swift` (GRDB declared, not product-linked while D-2 open); `Package.resolved` (real, from resolution in this workspace); `dependency-inventory.json` (draft M0-B inventory per DEPENDENCIES.md: package URL, exact revision, version, licence, target/product, build-only vs runtime-linked where measurable, vendored notices; DR-05); `Sources/NeedletailCore/NeedletailVersion.swift`; `Sources/NeedletailCLI/*` (minimal main); `Sources/NeedletailProviders/ProviderIdentity.swift`; `Sources/NeedletailRuntime/WorkspaceRoot.swift`; `Sources/NeedletailTestSupport/*`; `Tests/BehaviourTests/*`; `Tests/NeedletailPrimitiveTests/*` (SSE framing, cancellation, subprocess drain; SQLite-reopen probe compiled out while `UNQUALIFIED_ENVIRONMENT`, with the blocker recorded); `Tests/QualificationProbes/*`; `cases/catalog.json` (generated from the ACCEPTANCE tables embedded in COMPLETE-SPEC.md, provenance + digest recorded); `cases/expected-index.json` (the frozen, hand-audited 200-ID fixture used as the independent expectation, DR-04); `templates/milestone-report.md` (minimal, per MILESTONES "Required report at every closeout"; the packet template file is absent from this workspace — provenance recorded); `dev`; `.gitignore` (incl. `.build/`, `.needletail-dev/`, `._*`); `LICENSE` (MIT); `NOTICE.md` (dependency notices scaffold + provenance); `STATUS.md`; `plans/m0-a-b-plan.md`; `plans/m0-a-b-receipt.md` (review receipts). No edits to COMPLETE-SPEC.md/DEPENDENCIES.md/README.md (packet is read-only input), except adding them to git tracking in the first commit with provenance noted.

## 10. Tests to be written (RED first)

- `CatalogReconciliationTests`: frozen `cases/expected-index.json` (hand-audited from the ACCEPTANCE tables in COMPLETE-SPEC.md Part 10, digest recorded, ACCEPTANCE.md-standalone-unavailable provenance noted) reconciles **both directions** against `cases/catalog.json` and against a generated index of Part 10's ID inventory (DR-04); unknown-ID and missing-ID detection produce failure; duplicate case key rejected; 200 unique IDs verified.
- `ReporterTests`: synthetic per-case results — pass/skip/undiscovered/no-op-body — are classified PASS/FAIL/BLOCKED_REVIEW correctly; the anti-inflation guard rejects example/placeholder identities, digest mismatch, and stale results (TESTING §11: "a valid-looking JSON object written by the implementer cannot certify its own run").
- `VariantCountingTests`: 10 seeded variants of one behaviour count as one semantic case with variants listed separately (BDD-02).
- `QualificationProbes`: one intentional-fail, one skip, one parameterized, one passing test used to qualify runner discovery/reporting; excluded from the `./dev test quick` default filter; qualification evidence shows the runner distinguishes them (M0-A: "Prove the reporter cannot treat a missing/skipped/unexecuted case as passing").
- Primitive tests (run by `./dev test native`): SSE byte-split equivalence against the unsplit reference (raw bytes as well as decoded events); cancellation bounded completion against a synthetic loopback server; subprocess dual-pipe flood drain; SQLite reopen — compiled out while `UNQUALIFIED_ENVIRONMENT`, never skipped-as-pass.
- All probes use explicit readiness handshakes and bounded deadlines; **no sleeps** stand in for readiness (DR-12).
- RED evidence: for each, first execution shows the intended assertion failing for the intended reason (recorded per slice in `.needletail-dev/` evidence log).

## 11. Fault points (named, deterministic)

- `catalog.spec-mismatch`, `catalog.unknown-id`, `catalog.duplicate-key`, `catalog.expected-index-drift`, `results.example-identity`, `results.digest-mismatch`, `results.skipped-as-pass` (the anti-inflation probe), `sse.split-at-every-byte`, `cancel.mid-stream`, `child.dual-pipe-flood`, `grdb.unqualified-environment` (blocked while D-2 open).

## 12. Finish conditions

1. `./dev build` and `./dev test quick` green on Linux x86_64 with real output retained under `.needletail-dev/` (gitignored); `./dev test native` green for the unblocked M0-B probes with the SQLite probe explicitly `UNQUALIFIED_ENVIRONMENT` while D-2 is open.
2. Reporter/qualification evidence shows: intentional failure detected, skipped/undiscovered never counted as pass; cold-build vs warm-suite timings and pure-vs-native result split recorded separately (DR-07).
3. `cases/expected-index.json` frozen (200 IDs, digest recorded); `cases/catalog.json` reconciles with it in both directions; unimplemented entries visible as NOT_IMPLEMENTED/DEFERRED.
4. `Package.resolved` committed with real identities; `dependency-inventory.json` draft records the resolved graph with licences/notices (DR-05); M0-B probe results recorded per case with the official status vocabulary, test/review/environment fields separate.
5. `STATUS.md` records: current milestone, findings F-1…F-n, decisions pending D-1/D-2, evidence commands + exit codes, reviewer receipts, scratch-root allowlist.
6. deepseek-reviewer has reviewed THIS plan (receipt with route, packet digest, subject digests, timestamp); must-fix findings DR-01/02/03/05 dispositioned in this document (REV-01), fix-in-slice items owned in §10–§12.
7. Milestone closeout uses `templates/milestone-report.md`; no commits containing secrets; first commit message records the frozen packet provenance.

## 13. Review dispositions (from plans/m0-a-b-receipt.md)

- Must-fix-before-implementation — folded in: **DR-01** (GRDB declared-but-not-linked; §2 item 4, §9, §12.1), **DR-02** (`./dev test native` real for probes; §8), **DR-03** (`NeedletailPresentation` deferred to M1-B; §8), **DR-05** (draft `dependency-inventory.json`; §9, §12.4).
- Fix-in-slice — folded in: **DR-06** (official status vocabulary; §3, §6.9, §10–12), **DR-07** (cold/warm + pure/native evidence split; §12.2), **DR-08** (dev entry points incl. disabled-with-reason stubs; §8), **DR-09** (ledger in TestSupport; §8), **DR-10** (scratch-root allowlist; §2), **DR-11** (result-format qualification before reporter adoption; §8), **DR-12** (`grdb.reopen` key + no-sleep readiness invariant; §10–11), **DR-14** (25 vs 26 pin wording; §2 item 3).
- Accept-with-documentation: **DR-04** (expected-index fixture + both-direction reconciliation + ACCEPTANCE.md-unavailable provenance; §9, §10), **DR-13** (combined two-minor-milestone slice rationale: M0-A ≈ 10 files / ≤ 400 hand-written lines, M0-B ≈ 12 files / ≤ 500 lines counting generated artifacts; each individually within the DEVELOPMENT §5 guide).
- Original open questions resolved by review: no Presentation stub at M0-A (DR-03); catalogue freezes against a hand-audited fixture, not a generated index alone (DR-04); SQLite probe label is `UNQUALIFIED_ENVIRONMENT` (D-2 open) rather than a generic BLOCKED (DR-06).
