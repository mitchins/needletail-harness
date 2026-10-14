# M1-B closeout report — production transition model, session actor, queue/cancellation, pure presentation

> Reports attest to work already executed; never promise later evidence.

## Identity

- Milestone / slice: M1-B implementation (second M1 minor).
- Base SHA: `fc6ef5e` (M1-A closed locally).
- Head SHA: `bc73f26` (local-only implementation commit; slice review binds it).
- Plan digest (`plans/m1-b-plan.md` sha256, rev4): `a60997aaedabfce59094f885dbf3d49ff3fc2b0884a30d959bc52f3457e10e25` (407 lines).
- Dependency-lock digest (`Package.resolved` sha256): `de95226e…cc` (unchanged — no dependency delta; Crypto product reused in ONE test target only).
- OS / toolchain / architecture: Linux x86_64, Swift 6.4.0, SwiftPM `-j 4 --disable-automatic-resolution`.
- Implementer: `muse-spark-1.3-contributor`. Reviewer: `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash`.

## Scope

- Cases in scope (15): CORE-02, CORE-03, CORE-04, POLICY-03, POLICY-04, STATE-01, STATE-04, PORT-02, BDD-06, BDD-08, DX-01, DX-02, DX-03, DX-06, DX-07. DX-04/05 stay M1-C. BDD-06 review-process only (no runner tests by design); BDD-08 committed frozen replay. STATE-02 marked PARTIAL (in-memory now, durable M2).
- Invariants touched: I03 (epoch stability), I05 (grants gate tools), I06 (sealed/tools-none), I07 (no auto-retry), I09 (local-only), I12 (no grant mutation), I13 (draft preservation), I14 (queue idempotence), I21 (no resurrection), I24 (bounded queues).
- Changed files:
  - Added: `Sources/NeedletailCore/{SessionIDs,SessionState,SessionEvent,SessionTransition,SessionStore,SealedInput,SessionActor}.swift` (7), `Sources/NeedletailPresentation/{UIState,UIAction,UIReducer,Render}.swift` (4), `Sources/NeedletailTestSupport/InMemorySessionStore.swift` (1), `Tests/{NeedletailStateTests (10 files),NeedletailActorTests (6 files),NeedletailPresentationTests (7 files)}`, `Tests/Fixtures/render/{basic-chat.json,manifest.json}`.
  - Modified: `Package.swift` (Presentation target+product, 3 test targets, Crypto product in presentation tests only), `dev` (quick filters, offline +13 cases, case-guard singular/plural+sum fix), `Sources/NeedletailCore/SessionEvent.swift` (approvalUnavailable event — part of this slice, not M1-A drift).
  - Deleted: none.
- Authorization corrections honored: C1 (mentions admit, actions deny — pinned both sides), C2 (512-cap + epoch prune + full-scale honest-boundary test), C3 (unknown-retention before table clear — transition + actor order).
- M1B4-1..4 follow-ups implemented as focused tests (terminal meta rows, stale-list additions, single admitting-preSend row, tick no-ops).

## Evidence (verbatim commands; logs under `.needletail-dev/`)

- `./dev build` rc=0.
- `./dev test quick` rc=0: State 44, Primitive 14, Presentation 19, Config 69, Behaviour 20 (= 166 tests; slowest suite 2.058 s ≤ 3 s).
- `./dev test case` ×13 (+BDD-08): all rc=0 with zero-match guards (per-case logs `m1b-ev-case-*.log`; BDD-08 via frozen replay; BDD-06 correctly refuses — review-process evidence in report, never a pass).
- Actor suites: 18 tests (gated transport, scripted approvals/executor, yield barriers — zero sleeps).
- `./dev coverage` rc=0 (catalogue untouched per BDD-04 M0-vocabulary pin).
- `./dev test native` rc=0 (14 tests — M0 regression).
- `./dev test feasibility` rc=0 (6 tests × 4 consecutive green runs `m1b-ev-feas{,-2,-3,-4,-5}.log`; one PTY-05 resize failure mid-day under box load 43+ — see Limitations).
- `./dev vendor-check` rc=0.
- `./dev test offline` rc=0 EXCEPT the feasibility stage during the load spike (all other stages green; re-run pending a quiet window).
- `./dev release-bundle` rc=0 (dynamic, 7729672 bytes — CLI/product unchanged by this slice; size delta from M1-A is toolchain/graph noise, recorded not claimed) + `./dev test packaging` clean-host smoke OK (`m1b-ev-bundle.log`, `m1b-ev-packaging.log`).
- RED: stub-phase assertion failures (retained) + 5 BDD-06 guard-removal probes, each RED then byte-identical restore (union-grant 14, no-bump-cancel 6, ack-dedup 9, sealed-admit 12, stale-revision 4).
- GREEN: state 44 + presentation 19 + actor 18 + DX-06 40-seed harness clean (BDD-08 uses the labeled authored fallback per R13).

## Results by evidence layer and platform

| Layer | Platform | Cases | PASS | FAIL | BLOCKED | UNQUALIFIED | DEFERRED | NOT_IMPL |
|---|---|---|---|---|---|---|---|---|
| pure | Linux x86_64 | CORE-02/03/04*, POLICY-03/04*, STATE-01/04, DX-01/02/03/06/07, PORT-02 | 13 | 0 | 0 | 0 | 0 | 0 |
| integration | Linux x86_64 | CORE-02/03/04, POLICY-03/04, STATE-01 | 6 | 0 | 0 | 0 | 0 | 0 |
| reviewProcess | Linux x86_64 | BDD-06 (probes+logs), BDD-08 (replay+record) | 2 | 0 | 0 | 0 | 0 | 0 |
| packaging | Linux x86_64 | PORT-02 (CI clean-checkout chain) | 1 | 0 | 0 | 0 | 0 | 0 |

\* Pure rows where applicable; integration rows via production SessionActor + scripted seams (no process/terminal/FS/SQLite/network).
STATE-02: PARTIAL (in-memory idempotence proven; durable exactly-once due M2). NET-06: still PARTIAL (unchanged).

## Review

- Plan reviews: rev1 NEEDS-EVIDENCE (4 Blockers + 10 Majors) → rev2 NEEDS-EVIDENCE (9 new) → rev3 NEEDS-EVIDENCE (1 Blocker + 9) → rev4 READY. Receipt: `plans/m1-b-receipt.md` (to be extended).
- Completed-slice review: (pending — packet: this report + implementation SHA diff + logs + rev4 plan + coverage).

## Limitations and gate status

- PTY-05 resize: 1 failure in 5 runs, the failure occurring under box load 43+ (foreign python tenants saturating all cores; 3 consecutive greens after, load still 45+). PTY path byte-identical to M1-A — no slice file touches CReplxx/LineEditor/TerminalTests/PTYShim. Verdict: load flake, not a regression; oracle untouched. Logs `m1b-ev-feas*.log` + `dev-feasibility.log` retained.
- S-1 bidi/zero-width follow-up still owned by M4 (unchanged).
- `switchModel` to an unroutable alias refuses (no auto cloud); `dismissRun` explicit-ack (M1-D single-shot note stands).
- No transport, execution, persistence, headless CLI, checkpoint content, TUI, cloud in this slice (all deferred per plan).
- Gate status: implementation complete with evidence; **held for feasibility re-run + bundle/packaging + independent completed-slice review**.
