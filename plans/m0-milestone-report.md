# Milestone closeout report — M0 (M0-A + M0-B)

Filled 12 October 2026, revision 2. Every field is attested to work already executed; nothing here promises later evidence. Subject identity for review: base `86a717b0fda17d7690ce97b3161110cd169f5d33`; slice commits `4d2805d` (M0-A/M0-B) and `1770956` (Swift 6.4.0 re-qualification + GRDB linkage); head = the commit carrying this revision (tree hash recorded in `.needletail-dev/m0-tree-hash.txt`, updated in the same commit).

## Identity

- Milestone / minor slices: M0-A (bootstrap, case ledger, independent review) + M0-B (dependency graph and native primitives).
- Base SHA `86a717b0fda17d7690ce97b3161110cd169f5d33`; head SHA: see STATUS.md after commit (the commit containing this report is the reviewed subject).
- Plan digest: `plans/m0-a-b-plan.md` sha256 `974ad35d…` (reviewed) / `4b0ee01d…` (post-disposition).
- Dependency-lock digest: `Package.resolved` sha256 `de95226ee800ecb7609e5d8083d7c14dc4bc1f1ddbb2deabf1b23f1d7a8689cc` (26 pins).
- OS / toolchain / architecture: Ubuntu 24.04.4 LTS x86_64, kernel 7.0.0-31-generic, **Swift 6.4.0 (swift-6.4-RELEASE)** — the SPEC §3 pin, installed by the operator 12 Oct 2026 and used for the final qualification of this slice; sqlite3 dev headers 3.45.1-1ubuntu2.8 installed (decision D-2).

## Scope

- Closed M0-due catalogue IDs (13, catalog status IMPLEMENTED with evidence pointers), all with executed evidence: **BDD-01, BDD-02, BDD-03, BDD-04** (pure tests), **REV-01, REV-02, REV-03, REV-04** (review receipts), **DEV-01, DEV-02, DEV-04** (route/sanitized-packets/test-owned-children evidence), **PORT-01** (Linux gates ran), **DX-08** (offline run executed).
- Due-M0 IDs reassigned by reviewed disposition (evidence cannot exist at M0): BDD-05→M2, BDD-06→M1, BDD-07→M4, BDD-08→M1, REV-05..08→M0-D, DEV-03→M0-D. Reassignment recorded in `cases/expected-index.json` provenance and in the review receipt; catalog status DEFERRED_BY_PLAN for each, enforced by the new BDD-04 rule test.
- Other executed cases (earlier than their due milestone): WIRE-01, WIRE-02, NET-04, PROC-01 (integration/nativeProcess).
- Invariants touched: I01 (offline build/test/CLI paths), I02 (no runtime downloads), process guardrails (no host modification; D-1/D-2 routed to the operator).
- Changed files: as listed in `.needletail-dev/m0-file-list.txt` — package manifest/lock, inventory, catalogue fixtures, `dev`, `.gitignore`, `LICENSE`, `NOTICE.md`, `STATUS.md`, `templates/milestone-report.md`, five source files, eight test files, plan/receipt/report docs; packet files tracked unchanged.
- Dependency delta: new package; 26-pin graph from the seven DEPENDENCIES.md candidates; replxx not a SwiftPM package (vendoring at M0-C).

## Evidence

All raw outputs retained under `.needletail-dev/logs/`:

| Command | Result | Log |
|---|---|---|
| `swift package resolve` | 26 pins incl. GRDB 7.11.1; exit 0 | `package-resolve.log` |
| 6-pin scratch build (probe) | `Build complete! (31.84s)`; exit 0 | `probe-six-pin-build.log` |
| 7-pin scratch build (probe) | `sqlite3.h` not found (GRDBSQLite) | `grdb-sqlite-failure.log` |
| `./dev build` | Build complete, exit 0 | `dev-build.log` |
| `./dev test quick` (cold) | 19 tests / 6 suites pass; 70.0 s build+test | `test-quick-cold.log` |
| `./dev test quick` (Swift 6.4.0 + GRDB, cold on toolchain switch) | 20 tests pass (incl. STORE-01); 1:43.20 build+test | `test-quick-swift64-grdb.log` |
| `./dev test native` (Swift 6.4.0) | 5 primitive tests pass incl. STORE-01 SQLite reopen | `test-native-swift64-grdb.log` |
| `./dev test quick` (offline, Swift 6.4.0) | green; proxy-blackholed, no Node/Python on PATH | `test-quick-offline-swift64.log` |
| `swift test` (bare, Swift 6.4.0) | exit 0; 25 tests; intentional failure unreachable | `bare-swift-test-swift64.log` |
| `./dev test qualification` (Swift 6.4.0) | intentional failure detected; skips reported | `test-qualification-swift64.log` |
| `./dev test quick` (warm) | 19 tests pass, 0.014 s bodies; 4.07 s cycle | `test-quick-warm.log` |
| `./dev test quick` (DX-08 offline) | 19 tests pass; proxy-blackholed network, PATH without Node/Python, fake HOME; exit 0 | `test-quick-offline.log` |
| `swift test` (bare, default path) | exit 0; intentional failure unreachable by construction | `bare-swift-test.log` |
| `./dev test native` | 4 primitive tests pass | `test-native.log` |
| `./dev test qualification` | intentional failure FAIL (intended), 2 skips, 3 parameterized, 1 pass; script exit 0 | `test-qualification.log` |
| `./dev test case BDD-01 / WIRE-01 / PROC-01` | 7 / 1 / 1 tests pass | `test-case-BDD-01.log` |
| `./dev coverage` | 15 reconciliation tests pass (M0 scope) | `coverage.log` |
| `./.build/debug/needletail --version`, `--help` | `0.3.0`; offline | `cli-version-help.log` |

- RED evidence: (1) `red-evidence-caseid-parse.log` — the spec-inventory reconciliation failed against the first `CaseID` implementation (multi-hyphen families rejected) and passed after the validator fix; intended failure for the intended reason; (2) the qualification intentional failure is a constructed RED observation, reported distinctly from passes.
- Cold on toolchain switch 1:43.20 / warm ≤4 s / slowest test 0.033 s (cancellation probe); pure vs native split by command (`quick` = pure + primitives, `native` = primitives only).

## Results by evidence layer and platform (Linux x86_64 only)

| Layer | Cases | PASS | FAIL | BLOCKED_REVIEW | UNQUALIFIED_ENVIRONMENT | DEFERRED_BY_PLAN | NOT_IMPLEMENTED |
|---|---|---|---|---|---|---|---|
| pure | BDD-01..04 | 16 | 0 | 0 | 0 | 0 | — |
| integration | WIRE-01, WIRE-02, NET-04 | 3 | 0 | 0 | 0 | 0 | — |
| nativeProcess | PROC-01 | 1 | 0 | 0 | 0 | 0 | — |
| nativeStorage | STORE-01 | 1 | 0 | 0 | 0 | 0 | 0 |
| reviewProcess | REV-01..04, DEV-01, DEV-02, DEV-04 | 7 | 0 | 0 | 0 | 0 | 0 |
| packaging | PORT-01, DX-08 | 2 | 0 | 0 | 0 | 0 | 0 |

NET-05 and CORE-02: DEFERRED_BY_PLAN (due M1) — the cancellation probe exercises NET-04's explicit-cancellation obligation and is credited to NET-04 only (slice-review finding F-1, fixed). Package-layer PKG-01..06: DEFERRED_BY_PLAN (M6/M0-D).

## Review

- Plan review (pre-implementation, REV-01): `deepseek-reviewer` route `opencode-go/deepseek-v4.1-flash`, packet `974ad35d…`, disposition READY; findings DR-01…DR-14 all folded (receipt `plans/m0-a-b-receipt.md`).
- Completed-slice review: disposition **NEEDS_EVIDENCE** with findings F-1…F-10; dispositions applied before closure:
  - F-1 (Major, case misassignment): probe relabeled NET-04; report crediting corrected; NET-05/CORE-02 remain deferred.
  - F-2 (Major, failing probe reachable from default path): intentional failure gated by `.enabled(if: NEEDLETAIL_QUALIFICATION=1)`; bare `swift test` now exit 0 (`bare-swift-test.log`); `./dev test qualification` still detects it.
  - F-3 (Major, unsatisfied M0-due cases): 13 M0-due IDs now executed with evidence or reassigned by reviewed disposition (see Scope).
  - F-4 (Minor, subject identity): tree hash recorded; head SHA filled at commit.
  - F-5 (Minor, missing raw evidence): all command outputs now retained.
  - F-6 (Minor, DX-08): executed offline under proxy blackhole + Node/Python-free PATH (formerly only claimed).
  - F-7 (Minor, coverage scope): M0-scope reconciliation documented; full tier/due-aware coverage deferred with the results-ingestion work.
  - F-8 (Minor, STORE-01 labels): during the D-2 window the catalog carried `status_detail` with both `test_status: DEFERRED_BY_PLAN` and `environment_status: UNQUALIFIED_ENVIRONMENT`; after D-2 resolved, STORE-01 executed PASS on Swift 6.4.0 and `cases/catalog.json` records that executed evidence.
  - F-9 (Minor, swift-crypto linkage): inventory and Package.swift comments record declared-but-not-linked.
  - F-10 (Suggestion, server teardown): readiness wait bounded by a deadline; teardown is a timed semaphore wait, no polling loop.
- Final verification at `1770956`/tree `6de5ddf…` returned NEEDS_EVIDENCE: F-3 PARTIAL (reassigned IDs carried `NOT_IMPLEMENTED` while the report claimed `DEFERRED_BY_PLAN`; the catalog's own status rule was violated and no test read the status fields) plus stale text N2–N4 (STATUS milestone counts, F-8 wording, inventory note, dangling pre-fix hash reference). Corrections in revision 2: catalog statuses fixed and the vocabulary extended with `IMPLEMENTED` for executed M0-due cases; a new BDD-04 rule test enforces status↔due-milestone agreement and requires evidence pointers for IMPLEMENTED entries; `status`/`status_detail` added to the Codable model so they round-trip; STATUS/receipt/inventory stale text corrected; the pre-fix tree-hash recording gap recorded in the receipt; one surviving F-8 sentence (receipt row + report bullet) corrected in this revision. Re-verification at the head carrying this revision is the closure gate (appended to `plans/m0-a-b-receipt.md`). M0 epic CodeRabbit review remains due at M0-D when the remote is authorized.

## Limitations and gate status

- F-1 (STATUS): RESOLVED 12 Oct 2026 — operator installed libsqlite3-dev; GRDB linked; STORE-01 passes.
- F-2 (STATUS): RESOLVED 12 Oct 2026 — Swift 6.4.0 installed by operator; slice re-qualified on the pinned toolchain.
- F-3 (STATUS): replxx is not a SwiftPM package; vendored at M0-C (unchanged).
- Catalogue provenance: ACCEPTANCE.md exists only embedded in COMPLETE-SPEC.md Part 10; `expected-index.json` is the frozen hand-audited expectation; digests recorded (accepted DR-04 disposition).
- Gate status: M0-A closed for scope; M0-B closed including the native SQLite-reopen probe (STORE-01 PASS on Swift 6.4.0). Next authorized action: operator rulings (D-2), then M0-C (replxx PTY feasibility) and M0-D (clean-runtime bundle, CI, CodeRabbit epic review). Stop at M3 for the viability decision (no M4+ work).

## Closure

Final review chain recorded in `plans/m0-a-b-receipt.md`: plan READY → slice NEEDS_EVIDENCE (F-1…F-10 fixed) → re-qualification NEEDS_EVIDENCE (F-3 + stale text fixed) → closure NEEDS_EVIDENCE (F-8 sentence + test count fixed) → final doc-only review **READY TO CLOSE** at head `07e0269b5254194a73f65928f8f32f03aa3c06bf` (base `86a717b0…`). Slice closed; next authorized action: M0-C (replxx PTY feasibility) per the reviewed plan.

---

# M0-C / M0-D closeout (12 October 2026, revision 1)

Attests to executed work only. Slice plan `plans/m0-c-d-plan.md` (revision 2, plan review READY); receipts `plans/m0-c-d-receipt.md`.

## M0-C — replxx line-editor feasibility: PASS (development evidence, not interactive acceptance)

- Vendored target `Sources/CReplxx` at the pinned upstream commit `1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2`: upstream sources byte-identical (offline `sha256sum -c SHA256SUMS-vendored`, manifest generated from upstream blob hashes; optional byte-for-byte clone check), licence preserved, bridge files limited to `shim.h` + `include/module.modulemap` + provenance + manifest. Evidence: `logs/vendor-check.log`, `logs/creplxx-swiftpm-build.log`.
- `NeedletailLineEditor` wraps only the C API (`replxx_init/end/input/write`, completion callback); `NeedletailTypingProbe` is a debug-only fixture executable never shipped; `Tests/PTYShim` is a test-only C shim (fork/setsid/TIOCSCTTY, bounded select reads, TIOCSWINSZ, signal trampoline, owned-child teardown).
- ONE bounded Linux PTY scenario (`./dev test feasibility`, 5/5 stable runs): editor live during synthetic streamed output; an unsent multiline Unicode draft (combining mark + 4-byte emoji) submitted byte-identically after streaming and resizes 40→120→80; completion callback invoked with its candidates; Ctrl+C cancel returning to clean input; clean exit code 0; canonical echo restored after exit. Evidence: `logs/m0c-feasibility-final.log`; oracle probe `logs/m0c-oracle-probe-wrong-expectation.log` (a wrong expectation fails — the oracle is real).
- Findings kept for M4 (not blockers): replxx Ctrl+C returns NULL like EOF; Tab inserts the common candidate prefix (the exactness oracle therefore precedes any completion invocation); SIGUSR1 needed explicit unblocking in the child because the Swift Testing runner blocks it and `fork` inherits the mask; `replxx_print` is variadic and not Swift-callable (the seam uses `replxx_write`).

## M0-D — local release foundations

| Item | Result | Evidence |
|---|---|---|
| Release bundle (`./dev release-bundle`) | dynamic bundle, 3,646,992-byte binary, 15 bundled runtime libs, pure-shell launcher, linkage manifest | `logs/release-bundle-final.log`, `logs/linkage-manifest.txt`, `logs/size.txt` |
| Static Swift stdlib | FAILS on Swift 6.4.0 (`Synchronization._MutexHandle` undefined) — toolchain finding; dynamic bundle is the documented path | `logs/release-build-static-FAILED.log` |
| Clean-host smoke (`./dev test packaging`) | PASS: digest-pinned `ubuntu:24.04`, `--network none`, swift/node/python3 asserted absent, `--version`/`--help`/`doctor` green | `logs/cleanhost-smoke.log` |
| Offline inspection | `needletail doctor` reports build identity, platform and git/rg presence with the exact capability each absence disables (PKG-05 machinery) | run under normal and restricted PATH |
| CI preparation | `.github/workflows/linux-ci.yml` (pinned action SHA, `persist-credentials: false`, no `pull_request_target`, `contents: read`, swiftly toolchain pin, SQLite headers provision, false-pass guard steps) — NOT ACTIVATED | file + plan |
| CodeRabbit config | `.coderabbit.yaml` prepared; epic-label/knowledge-base keys deferred to the installed schema (BLOCKED_REVIEW) | file + receipt |
| `./dev` hardening | every `swift test` requires a result line; `test case` validates the exact catalogue ID and refuses zero-match; qualification distinguishes crash from expected failure | `logs/dev-guard-*.log`, `logs/dev-*.log` |

## Results

- M0-C: 1 native PTY scenario PASS (development evidence for PTY-01…08/TERM-*, which stay `DEFERRED_BY_PLAN`).
- M0-D: PKG-01 thin smoke executed; PKG-03/04 preparation only (no activation, no CI evidence); PKG-05 machinery early; DX-08 re-executed offline with a minimal PATH; DEV-03/REV-05…08 remain `DEFERRED_BY_PLAN` pending remote authorization.
- Toolchain: Swift 6.4.0; `NEEDLETAIL_SWIFT` override used because the shared swiftly shim was replaced by another session on this builder (STATUS F-4).

## Gate status

M0-C and local M0-D are implemented and evidenced; the slice's completed-review findings are folded (receipt table). Remote-dependent items (push/PR/CodeRabbit activation, epic review) remain an explicit maintainer gate. The M0 epic CodeRabbit review is still the M0 closeout gate and awaits authorization.
