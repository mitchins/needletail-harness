# M1-B closeout report — production transition model, session actor, queue/cancellation, pure presentation

> Reports attest to work already executed; never promise later evidence.

## Identity

- Milestone / slice: M1-B implementation (second M1 minor).
- Authorized baseline: `fc6ef5e` (M1-A closed locally). Subject base for this slice: `ee0b36a` (M1-B planning closeout, planning files only — no source delta).
- Head SHA: `c011a0f` (local-only ledger tip; implementation `bf4708b`, S-fixes `a5dd9d7`, recovery `231743c`; final review binds `c011a0f`).
- Plan digest (`plans/m1-b-plan.md` sha256, rev4): `a60997aaedabfce59094f885dbf3d49ff3fc2b0884a30d959bc52f3457e10e25` (407 lines).
- Dependency-lock digest (`Package.resolved` sha256): `de95226e…cc` (unchanged — no dependency delta; Crypto product reused in ONE test target only).
- OS / toolchain / architecture: Linux x86_64, Swift 6.4.0, SwiftPM `-j 4 --disable-automatic-resolution`.
- Implementer: `muse-spark-1.3-contributor`. Reviewer: `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash`.

## Scope

- Cases in scope (15): CORE-02, CORE-03, CORE-04, POLICY-03, POLICY-04, STATE-01, STATE-04, PORT-02, BDD-06, BDD-08, DX-01, DX-02, DX-03, DX-06, DX-07. DX-04/05 stay M1-C. BDD-06 review-process only (no runner tests by design); BDD-08 committed frozen replay. STATE-02 marked PARTIAL (in-memory now, durable M2).
- Invariants touched: I03 (epoch stability), I05 (grants gate tools), I06 (sealed/tools-none), I07 (no auto-retry), I09 (local-only), I12 (no grant mutation), I13 (draft preservation), I14 (queue idempotence), I21 (no resurrection), I24 (bounded queues).
- Changed files:
  - Added: `Sources/NeedletailCore/{SessionIDs,SessionState,SessionEvent,SessionTransition,SessionStore,SealedInput,SessionActor}.swift` (7), `Sources/NeedletailPresentation/{UIState,UIAction,UIReducer,Render}.swift` (4), `Sources/NeedletailTestSupport/InMemorySessionStore.swift` (1), `Tests/{NeedletailStateTests (11 files),NeedletailActorTests (7 files),NeedletailPresentationTests (7 files)}`, `Tests/Fixtures/render/{basic-chat.json,manifest.json}`.
  - Modified: `Package.swift` (Presentation target+product, 3 test targets, Crypto product in presentation tests only), `dev` (quick filters, offline +13 cases, case-guard singular/plural+sum fix), `Sources/NeedletailCore/SessionEvent.swift` (approvalUnavailable event — part of this slice, not M1-A drift).
  - Deleted: none.
- Authorization corrections honored: C1 (mentions admit, actions deny — pinned both sides), C2 (512-cap + epoch prune + full-scale honest-boundary test), C3 (unknown-retention before table clear — transition + actor order).
- M1B4-1..4 follow-ups implemented as focused tests (terminal meta rows, stale-list additions, single admitting-preSend row, tick no-ops).

## Evidence (verbatim commands; logs under `.needletail-dev/`)

- `./dev build` rc=0.
- `./dev test quick` → `m1b-precommit-quick.log`, rc=0: StateTests 52, PrimitiveTests 14, PresentationTests 19, ConfigTests 69, BehaviourTests 20 (= 174 tests; slowest suite ~2.08 s ≤ 3 s warm). (An earlier `m1b-final-quick.log` run predates the reconstructed snapshot suite at 49 state tests and is superseded — not cited as evidence.)
- `./dev test case` ×13 (+BDD-08) → `m1b-final-case-*.log`, all rc=0 with zero-match guards (BDD-08 via frozen replay; BDD-06 correctly refuses — review-process evidence below, never a pass).
- Actor suites: 18 tests (gated transport, scripted approvals/executor, yield barriers — zero sleeps).
- `./dev coverage` rc=0 (catalogue untouched per BDD-04 M0-vocabulary pin).
- `./dev test native` rc=0 (14 tests — M0 regression).
- `./dev test feasibility` rc=0 (6 tests × 4 consecutive green runs; one PTY-05 resize failure mid-day under box load 43+ — see Limitations).
- `./dev vendor-check` rc=0.
- `./dev test offline` → `m1b-final2-offline.log`, OFFLINE OK (all stages incl. 13 M1-B cases at 52 state tests; supersedes the 49-state `m1b-final-offline.log`).
- `./dev release-bundle` rc=0 (dynamic, 7790776 bytes) + `./dev test packaging` clean-host smoke OK (`m1b-final-bundle.log`, `m1b-final-packaging.log`).
- RED: stub-phase assertion failures (retained) + 5 BDD-06 guard-removal probes, each RED then verified restore (no PROBE markers remain; Transition/SealedInput digests match pre-probe snapshots).
- BDD-06 probe→guard→oracle mapping with DISTINCT FAILING TESTS per probe (S4 reconciled — units are failing test functions, counted once each):
  - generation-check removal → `STATE-01 old-generation and post-cancel completions drop` (1 test; `m1b-probe-bdd06-gen.log` + wide re-run `m1b-probe-gen-wide.log`).
  - cancel-invalidation removal → `CORE-02 cancel in requesting, streaming, admitting holds and bumps` (1 test; `m1b-probe-bdd06-cancel.log` + wide re-run `m1b-probe-cancel-wide.log`, which additionally proves the phase gate holds post-cancel drops as defense-in-depth).
  - ack-dedup removal → `CORE-02 queue admission is idempotent per commandID` + `CORE-02 queue withdraw tombstones` (2 tests; `m1b-probe-bdd06-ack.log`).
  - sealed-denial removal → `POLICY-03 whole-message tool JSON denies as an action` + `POLICY-03 sealed tool-JSON denies with no reservation` (2 tests; `m1b-probe-bdd06-sealed.log`).
  - stale-revision acceptance → `CORE-02 queue edits bump revisions` (1 test; `m1b-probe-bdd06-revision.log`).
- GREEN: state 52 + presentation 19 + actor 19 (incl. S2 order test) + DX-06 40-seed harness clean (BDD-08 uses the labeled authored fallback per R13).

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
- Completed-slice review: NEEDS-EVIDENCE at `bf4708b` (M1B-S1 Blocker + S2–S4 Majors + S5–S11 minors/suggestions) → all fixed below → final verification pending.
- S-fix implementation: `appendUnresolved` cap helper + integrity stop (S1); records-before-pump reorder (S2); DX-06 full five-invariant assertions (S3); probe recount above (S4); withdraw ack tracking (S5); sealed QueueEntry + auto-dispatch inheritance (S6); cancelling transportFailed carve-out (S7); continuation marker guard (S9); factory-use gate extension (S10); S8 recorded as M1-C handoff; S11 doc fixes in this report.
- Final review: (pending — binds the S-fix commit below).

## Workspace integrity incident + recovery (recorded honestly)

During the S-fix round, two uncommitted artifacts were lost: `Tests/NeedletailStateTests/SnapshotEpochTests.swift` vanished from disk (never staged — authoring oversight in an explicit-path `git add`), and the validation-pump block + S2 reorder in `SessionActor.swift` regressed (an edit replaced the region without re-emitting the tail). A third loss class (tracked `Archive.zip` rewritten/deleted mid-session, twice) points at environmental churn on this shared box rather than any single tool call. No committed content was ever lost or altered (`git` objects intact throughout).
Recovery: reconstructed the test file from retained history, re-applied the pump + reorder with read-back verification, added an S2 store-order actor test, re-ran the full suite green, and committed immediately (`231743c`). Correction to an earlier draft of this note: the pre-existing suite did NOT pass without the pump — `m1b-audit-green-3.log` shows 16/18 actor tests failing in that state. The S2 order test's unique value is catching record-order inversions specifically (cause-before-consequence), which no prior test asserted. Prevention: commit after every green evidence run; verify structural edits by read-back, not by tool receipt. The slice reviewer confirmed the recovered files via test evidence (`m1b-precommit-quick.log`, `m1b-actor-final.log`), not provenance.

## Limitations and gate status

- PTY-05 resize: 1 failure in 5 runs, the failure occurring under box load 43+ (foreign python tenants saturating all cores; 3 consecutive greens after, load still 45+). PTY path byte-identical to M1-A — no slice file touches CReplxx/LineEditor/TerminalTests/PTYShim. Verdict: load flake, not a regression; oracle untouched. Logs `m1b-ev-feas*.log` + `dev-feasibility.log` retained.
- S-1 bidi/zero-width follow-up still owned by M4 (unchanged).
- `switchModel` to an unroutable alias refuses (no auto cloud); `dismissRun` explicit-ack (M1-D single-shot note stands).
- No transport, execution, persistence, headless CLI, checkpoint content, TUI, cloud in this slice (all deferred per plan).
- Gate status: implementation complete with evidence; **held for feasibility re-run + bundle/packaging + independent completed-slice review**.
