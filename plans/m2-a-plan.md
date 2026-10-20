# M2-A plan — durable store, operation ledger, artifact ordering, crash reconciliation

Slice type: M2-A (first M2 minor). Planning-only; **no implementation authorized by this document.**
Status: REV3 READY FOR AUTHORIZATION (rev2 delta review: F-01…F-07/F-09/F-10 confirmed fixed first-hand; G-01…G-06 folded here — §9; all G-fixes are textual against reviewer-verified facts).
Prepared: 19 October 2026.
Baseline: `main` at `0cd5d7d` (M2-0 squash of PR #4; local main reconciled; CI on the exact SHA).
Reviewer (independent): `deepseek-reviewer` subagent (read-only).

Normative sources: COMPLETE-SPEC.md M2-A ("GRDB migrations, session ownership, paging, artifact commit ordering, quotas, intents/results and reopen reconciliation. First in-memory tests, then real temporary databases and named process-kill faults. No transaction held over an await; no automatic re-execution of unknown side effects."), SPEC §9 (durability shapes), ARCH §§1/7, TESTING §§3–5, ACCEPTANCE STORE/PORT rows, DEVELOPMENT §§4–6, DEPENDENCIES.md (GRDB already in graph — no new packages).

## 1. Goal

Replace the M1-B store seam's dev backends with a production GRDB store that survives kill −9 and reopen, without inventing semantics M2-0 did not gate:

- **Migrations**: versioned schema (`schema_version` table), forward-only migrations, fail-closed on future version or corrupt file (STORE-05).
- **Record codec**: `DurableRecord` is `Sendable, Equatable` only — NOT `Codable` (verified). A0 delivers a lossless codec for ALL NINE cases (`sessionOpened`, `epochOpened`, `eventAppended`, `operationIntent`, `operationResult`, `queueAdmitted`, `queueUpdated`, `checkpointCommitted`, `transcriptAppended`) plus the nested values (`OperationRef`, `EpochDescriptor`, `QueueEntry`, `TranscriptEntry`), with an every-case round-trip test. Undecodable rows are `.integrity`, never substituted (M2-0 probe precedent).
- **Ownership fencing (STORE-06 — the M2-0 deferral lands here)**: writer identity in the ownership row; two independent handles claiming ONE session → exactly one wins, the loser receives `StoreError.alreadyOwned` carrying the winner's identity. The certifying test is named `STORE_06_sqliteTwoWritersCompeteForOneSession` (the `sqlite` token is required by the ingestion tier map for `.nativeStorage` classification); the `deferredToM2A` entry is removed and `requiredEvidence` gains the case IN THE SAME SLICE.
- **Paging/resume (STORE-07)**: dense sequences, cursor paging, bounded memory at ≥10k rows; resume on a fresh handle returns identical records.
- **Artifact commit ordering (STORE-03/04)**: artifact bytes land (temp → fsync → rename) BEFORE the DB transaction that references them commits; the DB stores `(path, digest)`, never blobs; a completion referencing an absent/uncommitted artifact is a typed integrity failure.
- **Intents/results + reopen reconciliation**: `operationIntent` persists before dispatch; `operationResult` completes it; on reopen, an intent without a result becomes an explicit unknown-outcome marker (never auto re-executed — this is also the semantics POLICY-07 later asserts at its own tier). No transaction is held over an await; the store API stays synchronous-append; async work collects, then commits.
- **Quotas (STORE-09)**: session and global record caps enforced in-transaction → `.quotaExceeded`.
- **Named process-kill faults (STORE-02 matrix, PORT-04)**: kill before intent / after intent / after side effect / before completion against the REAL store in a separate process; reopen reconciles each point per the reducer's rules.
- **Export/diagnostics (STORE-08)**: bounded, redacted export of store state for support.
- **Composition-root wiring**: the production CLI's `EphemeralStore` (RunCommand.swift — a production `SessionStore` conformance, NOT test-local) migrates to the GRDB store behind the same seam; `SessionActor`/`Transcript.loadTranscript` call sites audited and updated in the wiring slice.

What this slice is NOT: file tools (M2-B), exec/permission gates (M2-C), queue/undo machinery (M2-D — which owns durable queue admission/hold/reconcile and therefore STATE-02), any provider traffic, any new package.

## 2. Baseline findings that constrain the plan

1. GRDB 7.11.1 is resolved and linked ONLY to `NeedletailPrimitiveTests` (Package.swift; decision D-2). `ImportGateTests` forbids `GRDB` (and `SQLite3`) imports in `NeedletailCore` sources — so the store does NOT live in Core. **Host target: `NeedletailRuntime`** (already the I/O-bearing target, depends on `SystemPackage`). GRDB links only there; the import gate must stay green as the proof.
2. `SessionStore` protocol (Core) has `append/records/claimWriterOwnership/releaseWriterOwnership`. Fencing needs a writer identity — a **protocol change** (decision §7.1). The production CLI conformance `EphemeralStore` (RunCommand.swift:103) breaks and is migrated (§1 wiring); only `InMemorySessionStore` (NeedletailTestSupport) and `SQLiteProbeStore` (NeedletailPrimitiveTests) are test-local.
3. M2-0 machinery is the certification path: `XUnitIngestionTests.requiredEvidence` maps exact function+module per case; `deferredToM2A` hard-blocks STORE-06. Each slice edits the maps it delivers evidence for, with the invariant **no case appears in both maps** (A2 adds this as a unit assertion). `deferredToM2A`'s named test is renamed per §1 (fencing) so the tier map classifies it `.nativeStorage`.
4. Durability settings are a POWER-LOSS decision, not a process-kill one: under WAL, SIGKILL cannot distinguish `synchronous=NORMAL` from `FULL` (both survive process death; only OS/power loss differs). The M2-0 crash probe used `journal_mode=DELETE` — a rollback-journal precedent, not a WAL one. Decision §7.2.
5. M2-due catalogue families and ownership (full enumeration, verified against `cases/catalog.json` due_milestone=M2): STORE-01..09 → **M2-A**; PORT-04 → **M2-A**; STATE-03 (provider ambiguity at crash) → **M2-A reconcile-level only** (§7.4); STATE-02 (queue admission/ack) → **M2-D**; STATE-05 (native undo precedes next request) → **M2-D** (undo); POLICY-07 (no auto-resume after unknown outcome) → asserted at M2-C/D tiers on semantics M2-A implements; UX-QUEUE/UX-UNDO/UX-MENTION → **M2-D** (+M2-B for preimages); TOOL-01..12 → **M2-B**; PROC-02..06, PORT-03, PKG-05 → **M2-B/C**; PROC-01 (child flood/dual-pipe) is ALREADY EXECUTED at M0 (native tier, `plans/m0-milestone-report.md`) and is carried, not re-owned; BDD-05 → review-process (any slice, not implementation). M2-A close claims ONLY STORE-01..09 + PORT-04 satisfied and STATE-03 as a labelled non-certifying reconcile probe.

## 3. Slices (each: implement → shared-contract + native evidence → coverage reconcile → DeepSeek review)

- **A0 — codec, target & test reach**: `NeedletailRuntime` gains the GRDB dependency (import gate green); `NeedletailPrimitiveTests` gains a dependency edge on `NeedletailRuntime` so the production store is reachable from the native-tier tests (required by the tier map); record codec for all nine cases + nested values; every-case round-trip test. No schema yet.
- **A1 — schema & reopen spine**: migrations, `records` table (seq/order/payload via codec), paged reads; fresh-handle resume identical; STORE-01 re-pointed at the production store (now reachable via the A0 edge); STORE-05 fail-closed; STORE-07 at 10k+ via `assertAppendOrderAndPagination` on both backends.
- **A2 — ownership fencing & quotas**: writer identity + atomic single-statement claim; `STORE_06_sqliteTwoWritersCompeteForOneSession` (two handles, one session, one winner); `deferredToM2A` entry removed AND `requiredEvidence` entry added in the same slice (maps-invariant assertion included); STORE-09 session+global caps in-transaction.
- **A3 — intents/results & reconciliation**: intent-before-dispatch persisted; reopen maps intent-without-result → unknown marker (R2/C3 semantics); no auto re-execution; STATE-03 labelled non-certifying reconcile probe (stays unsatisfied at close).
- **A4 — artifact ordering & kill matrix**: temp→fsync→rename→txn ordering; STORE-03 (rename OK, txn missing), STORE-04 (txn references absent artifact → typed integrity failure); STORE-02 named kill faults via separate-process staged writes (bounded, poll-synced, SIGKILL; M2-0 crash-test mechanics); PORT-04.
- **A5 — wiring, export & closeout**: `EphemeralStore` → GRDB store behind the same seam (CLI composition root; actor/transcript call sites); STORE-08 bounded export; coverage reconciliation (STORE-01..09 + PORT-04 satisfied; STATE-03 probe recorded unsatisfied); STATUS/receipt.

## 4. Gates per slice

`./dev test quick` + `native` green; `./dev coverage` INGEST line shows the slice's cases satisfied with correct tiers (nativeStorage evidence only from real file/process execution; tier map extended per slice); import gate green; no transaction-over-await; RED counterfactual for each new oracle (M2-0 pattern); CI green on the exact pushed SHA; DeepSeek slice review.

## 5. Explicit non-goals / forbidden

No M2-B/C/D behaviour; no re-execution of unknown side effects; no silent truncation or payload substitution (`.integrity`); no macOS-only APIs; no new packages; no weakening of M2-0 gates (tier map, ingestion fail-closed, maps invariant); no GRDB import in any SHIPPED target other than `NeedletailRuntime` (the existing `NeedletailPrimitiveTests` GRDB linkage is test-only and remains).

## 6. Risks

- Protocol change ripples to every `SessionStore` conformance (**4 known**: planned production GRDB store, `EphemeralStore` (RunCommand.swift:103), `InMemorySessionStore`, `SQLiteProbeStore`; no other fakes exist — verified by repo grep). Additionally, fencing the loser's error as `alreadyOwned` carrying the WINNER'S WRITER ID changes `StoreError.alreadyOwned(session: String)`'s payload — every pattern-match site updates in the same A2 commit (`InMemorySessionStore`, `StoreContractAssertions`, `SQLiteStoreContractTests`).
- Kill-fault tests are the slowest/flakiest surface; bounded sync (M2-0 mechanics) is mandatory, and the matrix runs under `./dev test native`, never `quick`.
- Codec breadth (nine cases) is the largest single A0 item; every-case round-trip is the gate, not spot checks.

## 7. Decisions requested from plan review

1. **Writer identity API**: extend to `claimWriterOwnership(session:writerID:)` with caller-supplied stable `writerID: String`; conflicting claim fails with the CURRENT owner's writerID. Rationale: minimal protocol change, fencing testable without handle-object lifecycle design.
2. **Durability**: WAL + `synchronous=FULL` justified explicitly as POWER-LOSS durability for the operator's local-machine profile (crash-consistent DB the operator can trust after hard power-off). Process-kill (application-crash) correctness is SQLite's own durability guarantee under WAL regardless of `synchronous` mode, and is proven by the kill matrix independently of the sync setting. If the reviewer/operator rejects the power-loss premise, `NORMAL` is acceptable — the kill matrix does not depend on it.
3. **Artifact home**: files beside the DB via temp+fsync+rename; DB stores `(path, digest)`; orphaned artifacts without a DB row are reportable, never referenced (STORE-03/04 semantics).
4. **STATE-02/03 boundary**: STATE-02 wholly M2-D; only STATE-03 reconcile-level in M2-A as a non-certifying probe — confirm.

## 8. Rev1 → REV2 changes (review folding)

- F-01 codec breadth made explicit A0 work (DurableRecord not Codable — verified).
- F-02 `EphemeralStore` recognized as production; wiring slice A5 added; "test-local" reserved for probes.
- F-03 host target named (`NeedletailRuntime`); import-gate conflict resolved by construction.
- F-04 durability rationale corrected (power-loss vs process-kill; DELETE-mode precedent noted).
- F-05 STATE-02 moved wholly to M2-D; only STATE-03 reconcile-level here.
- F-06 certifying test renamed `STORE_06_sqliteTwoWritersCompeteForOneSession` for tier classification.
- F-07 maps-invariant (no case in both maps) added as a unit assertion; same-slice coupling explicit.
- F-08 full M2-due enumeration with family ownership (§2.5); POLICY-07/STATE-05 named.
- F-09 STATE-03 stated as labelled non-certifying probe, unsatisfied at M2-A close.
- F-10 uncorroborated timing metric removed.

## 8. Known unrelated tooling issues (tracked separately, NOT A0 scope)

- **Sonar coverage-import defect**: the main-branch Sonar quality gate is broken (red on `f62ccdd`+ main runs and on PRs alike; operator-acknowledged). Not a code defect; to be fixed in CI tooling separately. M2-A slices do not gate on Sonar.
- **PTY-05 intermittent failure**: flaky on the Linux builder (operator-reported). M4-scope case; tracked so an M2-A run hitting it is triaged as the known flake, never absorbed silently into a green run.
- **A0 bundler note (M0-D audit trail)**: with GRDB in the Runtime graph, BOTH linkage modes now emit `lib/` (libsqlite3 collected; Swift libs in dynamic mode) and a pure-shell launcher at `bundle/needletail` (static mode previously placed the raw ELF there). `linkage-manifest.txt`/`size.txt` still read `bin/needletail.real`; `linkage-mode.txt` stays truthful. CI verified static mode (linux success on `71e1d5b`); local verified dynamic mode.

## 9. Rev2 → REV3 changes (delta review: F-fixes confirmed; G-findings folded)

- G-01 PROC-01 identified as already executed at M0 and carried (§2.5), not silently omitted.
- G-02 A0 adds the `NeedletailPrimitiveTests → NeedletailRuntime` dependency edge so production-store evidence is reachable at the native tier (A1 STORE-01 and A2 STORE-06 depend on it).
- G-03 conformance ripple corrected to 4 known conformances; phantom fakes removed (§6).
- G-04 internal contradiction fixed: codec is A0 work (§1 now matches §3/A0 and §8/F-01).
- G-05 `StoreError.alreadyOwned` payload change (winner's writer ID) added to A2 scope and the §6 ripple list.
- G-06 import rule scoped to shipped targets; test-only GRDB linkage explicitly preserved (§5).
- Non-blocking wording fix applied to §7.2 (application-crash durability is SQLite's guarantee under WAL, independent of sync mode).

## 10. A2 remediation (review-folded, authorized; NEXT SESSION'S FIRST WORK)

Verdict NEEDS_CHANGES (independent A2 review); findings to fold in order:

1. **Session-scoped reads (HIGH)**: add `records(session:since:limit:)` to the
   contract; keep the unscoped variant ONLY as documented diagnostic (or drop
   it). GRDB: `AND session = ?`. InMemory: store per-record session. Probe +
   Ephemeral likewise. `loadTranscript(from:session:limit:)` + all RunCommand
   call sites. Shared `assertAppendOrderAndPagination` reads session-scoped.
   REGRESSION: two sessions, one file, distinguishable private content
   ("AAA-only" vs "BBB-FORBIDDEN"); neither transcript contains the other's
   records; forbidden-content assertion explicit.
2. **Probe atomicity**: SQLiteProbeStore fence-SELECT + quota + INSERT in ONE
   `queue.write` (mirror GRDBSessionStore); fix the false "FENCED" comment.
3. **Index + busy timeout**: v2 migration adds
   `CREATE INDEX IF NOT EXISTS records_session ON records(session, seq)`
   (supports session-quota COUNT and ordered session pagination; global
   identity stays `seq` PK — per-session density is a read concern, not a
   second sequence). `configuration.busyMode = .timeout(...)` +
   `defaultTransactionKind = .immediate` (makes the BEGIN IMMEDIATE comments
   TRUE); map exhausted BUSY to a typed StoreError; tests: index presence via
   `PRAGMA index_list`, two-handle contention exercises the timeout.
4. **v1 fixture test**: hand-build a genuine v1 file (old records/writer DDL,
   one row, user_version=1, live claim); open → v2 shape, rows preserved with
   session='', legacy claim VOID (old-writer append/release → .notWriter),
   explicit re-claim required.
5. Low items: drop RunCommand's redundant pre-claim; record never-release as
   A5 concern (claim-row growth on reused files); .coderabbit.yaml TESTING §2
   wording → "case-bearing tests' display names begin with the case ID;
   support/oracle tests are UNLABELED support evidence and reconciled as
   such" (explicit exemption — do NOT assign unrelated case IDs).

Gates after fold: quick/native/coverage (STORE-06/09 stay satisfied), RED
probes for the session-isolation regression, DeepSeek delta verify → A2 CLOSED.

## 11. A3 recovery/ownership design obligation (operator directive)

Ordinary release/re-claim covers cooperating writers only. A crashed
process's claim persists and must NOT be recoverable by time, absence, or
PID assumptions. A3 qualifies an explicit, authorized recovery:
- Inspect + PRESERVE unresolved operation evidence first (intents without
  results stay unknown; never auto-replay an unknown side effect).
- `recoverOwnership(session:fromWriter:toWriter:authorization:)`-style
  operation: atomically supersedes the old identity with a fresh one in one
  transaction, subject to explicit preconditions (authorized invocation —
  operator intent carried as a value, not elapsed time/PID liveness/absent
  ack).
- Post-takeover, every fenced mutation of the OLD identity fails `.notWriter`
  (already guaranteed by the ownership row; recovery test proves it even if
  the old writer resumes).
- Old writer ID reuse is NOT recovery fencing; the takeover is deliberate,
  auditable (a durable record is appended for the recovery event).
- Small + integrated with the GRDB ownership contract; no lease service.

## 12. A2 delta review verdict (2d01e6c): NEEDS_CHANGES — fold BEFORE closing

Folds confirmed (1,2,4 core; index/busyTimeout present). Remaining:
1. HIGH: item 5 NOT folded despite commit subject — .coderabbit.yaml TESTING §2
   wording (plan §10 item 5), RunCommand:327 redundant pre-claim, A5
   claim-growth note. Commit/receipt claim must be corrected.
2. MED: typed SQLITE_BUSY mapping (append/appendBatch/reads) + PRAGMA
   index_list test + contention test; record: GRDB 7.11.1 has NO
   defaultTransactionKind (write closures already IMMEDIATE) — plan §10 API
   instruction stale, code correct.
3. MED: index not created for ALREADY-v2 files (inside `version < 2`) — move
   unconditional/idempotent post-branch.
4. MED: scoped reads lack limit>0 guard in InMemory/Ephemeral/probe (GRDB has
   it) — align all.
5. LOW: dense-sequence oracle wording (single-session log, not per-session
   density); 6. LOW: probe stale docs/dead recordCount/global-only quota —
   fix comments or mirror; 7. LOW: isolation regression GRDB-only — extract
   shared assertion, add InMemory leg + beta transcript; 8. LOW: RED probe
   WAS executed (scope dropped → 4 oracle trips → byte-exact restore) —
   record in receipt.
Adjudications accepted: v1 = unshipped dev history → documented limitation
+ focused regression (legacy row in diagnostic read, absent from scoped,
global-count-only); SessionIsolationTests stays UNLABELED with the
RecordCodecTests-style doc comment.

## 13. A2 closure ledger corrections (item 1)

- Commit f7187c5's subject claimed "TESTING §2 exemption" among folded items;
  that claim was OVERSTATED — the wording lands in THIS batch (item 1). The
  authoritative fold record is plan §12 + this section, not commit subjects.
- A5 obligation: claims are never released on the production path
  (RunCommand relies on unique per-process sessions today) — a reused store
  file accumulates claim rows. A5 must add claim retention/release policy
  (e.g. release at clean run end) or document bounded growth.

## 14. A2 CLOSED — independent delta review APPROVED (2026-10-19)

Reviewer: `deepseek-reviewer` (subagent ses_ead231231fffeAGFstoV7L9hzmf), read-only,
range `2d01e6c..ea252be`. Verdict: APPROVED — no outstanding A2 correctness
blockers. Verified first-hand: scoped reads (protocol split, GRDB WHERE
clause, InMemory/Ephemeral per-record attribution, all `loadTranscript` call
sites, shared assertions); probe single-transaction fence+quota+INSERT;
index created unconditionally for already-v2 files after fail-closed checks;
v1 fixture (genuine v1 DDL, preserved row, voided claim, re-claim); typed
BUSY on all DB accesses with primary-code matching sufficient per GRDB 7.11.1
(`resultCode` = extended's primaryResultCode); legacy-visibility regression;
STORE-06/09 certifiers intact; `deferredToM2A` empty + disjoint invariant;
isolation test unlabeled per TESTING §2 exemption.

Non-blocking nits ACCEPTED as follow-ups (not A2 gate): §12 scope comment,
probe/GRDB guard asymmetry on unscoped `limit>0`, shared isolation assertion
for InMemory, RED-evidence receipt file, index-presence assertion wording,
global-quota slot proof for legacy rows, stale `defaultTransactionKind`
instruction line (superseded by auto-managed IMMEDIATE, §12 retained),
assertion message wording, `SessionID("")` escape hatch (documented:
v1 unshipped, no production path constructs it).

## 15. A3-1 CLOSED — independent review APPROVED (2026-10-19)

Implementing commits `5add15a..a3ca247` (stable operation identities +
durable intent/result ordering), fold `ba53a27` + addendum `a5d2258`.
Reviewer: `deepseek-reviewer`, two rounds. Round 1 NEEDS_CHANGES (4
finite findings); all folded with RED/GREEN evidence; round 2
APPROVED — no remaining in-scope findings.

Delivered: derived operation IDs (`effectID/callID`) binding dispatch
intents to per-proposal completions; intent groups commit atomically
(`appendBatch`: GRDB single-txn pre-existing, InMemory + Ephemeral
overrides added) before any executor dispatch; failed result commits
halt without asserting success (reason classified from the unpersisted
record group); stale/cancel unknown markers reuse intent IDs.
Tests: 7 reducer + 4 actor (commit-gated double) + InMemory group-quota
atomicity; 8 RED counterfactuals verified (missing intent, minted
result ID, consumed-check vs torn state, early-return removal x2,
hardcoded mutating:false, minted cancel IDs, per-record actor
regression). Gates at HEAD: quick + native green, coverage
`executed=141 failed=0 satisfied=20`.

Scope guard: reopen reconciliation, ownership takeover, artifact
storage, A4/A5 NOT started — later A3 tasks.

## 16. A3-2 CLOSED — independent review APPROVED (2026-10-20)

Implementing commits `e5a4e45..13d61c0` (pure `reconcileOperations`
classifier + `GRDBSessionStore.reconcile` + `resumedAfterReopen` + 11
genuine-reopen tests + resume-hold test), fold `77dcb40`, doc addendum
`ca9ae74`. Reviewer: `deepseek-reviewer`, two rounds. Round 1
NEEDS_CHANGES (4 findings: swallowed ambiguous-delivery unknowns,
callID-nil validation/dedup gaps, unpinned mutating union); all folded
with fresh RED/GREEN evidence; round 2 APPROVED — no blocking findings
(one doc inconsistency, fixed in `ca9ae74`).

Delivered: stable-ID intent/result matching; completed vs explicit
unknown vs unmatched (mutating held as unknown, non-mutating reported
re-runnable); orphan results with conservative hold (unknown-state
always holds, done-state holds iff mutating); callID-less admission
markers and denial receipts never held; duplicates, contradictions,
malformed states and namespace collisions fail closed; batch receipts
never complete sibling calls (counterexample pinned). Resumed state
seeds held refs into `unresolvedOperations`, blocking admission and
continuation until explicit reconciliation. Gates at HEAD: quick +
native green (54 tests), coverage `executed=156 failed=0 satisfied=20`.
7 RED counterfactuals verified.

Scope guard: ownership takeover (A3-3), crash matrices (A4),
CLI production-store wiring (A5) NOT started.

## 17. A3-3 CLOSED — independent review APPROVED (2026-10-20)

Implementing commit `e1f87ab..5e32ae2` (preflight `.done`
callID/classification agreement + `RecoveryAuthorization` /
`WriterRecovery` / `writerRecovered` + GRDB single-transaction guarded
takeover + InMemory mirror + 7 two-handle recovery tests + codec tenth
case + preflight regression). Reviewer: `deepseek-reviewer`, single
round, APPROVED with no blocking findings — atomicity, fencing,
fail-closed precedence, hold preservation and codec safety all verified
first-hand against the cited lines.

Delivered: scope-bound operator authorization (never a boolean;
shape/scope validated before I/O); guarded atomic takeover (holder
match → in-transaction ledger reconcile → quotas → conditional update
→ audit with held evidence, full rollback otherwise); stale writers
fail closed on append/batch/release/claim including via still-open
handles; new writer gated pre-commit; invalid ledgers and exhausted
session/global quotas prevent recovery; holds preserved byte-identical,
never cleared. Gates at HEAD: quick + native green (62 tests),
coverage `executed=164 failed=0 satisfied=20`. 5 RED counterfactuals
verified (blind upsert, skipped audit, skipped reconcile, skipped auth
validation, neutered `.done` agreement).

Scope guard: crash matrices (A4), CLI production-store wiring (A5) NOT
started. M2-A remaining: A4/A5, then epic review.

## 18. A4-1 CLOSED — independent review APPROVED (2026-10-20)

Implementing commits `b30f50e..2f44f2e` (content-addressed artifacts
under a private managed root, tmp→fsync→rename→dirsync→verify→fenced
reference ordering, fd snapshot reads, orphan/interrupted reporting,
STORE-03/04 certified) plus fold `59e49ca`. Reviewer:
`deepseek-reviewer`, two rounds. Round 1 NEEDS_CHANGES (6 findings:
unverified dedup durability, non-snapshot reads, ignored session
param, untranslated pre-check, symlinked root, colliding roots); all
folded with new pins and RED/GREEN evidence each; round 2 APPROVED —
no blocking findings.

Delivered: SHA-256 (swift-crypto, Runtime-only) content addressing;
0700 root / 0600 files; same-filesystem atomic rename;
post-rename re-verification before any reference; reads verify size +
digest via O_NOFOLLOW/fstat/bounded-copy snapshots (no mmap, no
follows, no hangs, no unbounded reads); dedup re-establishes
durability (fchmod/fsync/dirsync) instead of trusting squatters;
symlinked roots refused; distinct stores never share a root;
stale writers create nothing; orphans reported, never deleted or
attached. Gates at HEAD: quick + native green (75 tests), coverage
`executed=177 failed=0 satisfied=22` (STORE-03/04 satisfied as
required). 11 RED counterfactuals total across both rounds.

Scope guard: separate-process SIGKILL matrix + PORT-04 (A4-2), CLI
production-store wiring (A5) NOT started. M2-A remaining: A4/A5, then epic review.

## 19. A4-2 CLOSED — independent review APPROVED (2026-10-20)

Implementing commit `3fcf3ea..73adaae` (self-hosted crash children:
same test binary re-invoked with `--filter` + env, staged production
operations, readiness acknowledgement, parked SIGKILL with waitpid
verification, fresh-handle reopen; 8 STORE-02 production variants +
PORT-04 native leg + maps pin), folds `905dec0` (bounded reaper, WAL
probe order, PORT-04 split, holder check, private fixtures) and
`eeb85aa` (source-level pin on the PORT-04 gating body). Reviewer:
`deepseek-reviewer`, three rounds. Rounds 1–2 NEEDS_CHANGES (6
findings: unbounded waits, vacuous WAL probe, PORT-04 body-removal
masking, writability masking ownership loss, tautological sentinel
claim, non-private fixtures; then 1 residual: unpinned gating body);
all folded with fresh evidence; round 3 APPROVED — no findings.

Delivered: 8-point kill matrix (pre/post intent, post-effect with
no-redispatch proof, uncommitted result txn via held raw txn, post
commit + WAL, artifact tmp/renamed/committed) with verified SIGKILL
termination per test; PORT-04 requires the native variant at the
native tier (rename/break/body-removal each fail loudly — the last via
the source pin); old DELETE-mode probe kept as supplementary
evidence only. Durability scope: process-kill (SQLite WAL guarantee),
never power-loss. Gates at HEAD: quick + native green (86 tests),
coverage `executed=190 failed=0 satisfied=23` (STORE-02 all 9
variants + PORT-04 + STORE-03/04). 8 RED counterfactuals total
(dropped intent, premature success, neutered admission hold, blind
orphan scan, 2 native-gate bypasses incl. end-to-end gate failure,
emptied PORT-04 body).

Scope guard: CLI production-store wiring (A5) NOT started.
M2-A remaining: A5, then epic review.

## 20. A5-1 CLOSED — independent review APPROVED (2026-10-20)

Implementing commits `5959817..063b666` (XDG-compatible private
state, GRDB wiring with no silent fallback, sealed volatile
exception, session/epoch persistence + reconcile before provider work,
release-on-clean with retention policy, CLIStore dispatch enum,
executable-target build edge) plus folds `54a82ac` (verified private
modes, umask-first, complete guard, binary resolution, evidence
gaps), `0126809`/`b40d5f2` (SIGILL-class shutdown discipline +
integration hardening), `1ebb3b7` (serialized process suites, longer
reap deadlines) and `a1bc89f` (Darwin umask import, trap-safe
lookup). Reviewer: `deepseek-reviewer`, three rounds. Rounds 1–2
NEEDS_CHANGES (6 + 2 findings: unverified chmod, umask placement,
incomplete guard, binary resolution, evidence gaps, unpinned union;
overclaimed read-back, untested override precedence); final round
APPROVED with two non-blocking nits, both fixed in-tree.

Delivered: ordinary `needletail run` persists sessions/epochs/
transcripts to the production GRDB store (0700 dir, 0600 files);
corrupt stores refuse without overwrite (exit 6); sealed runs stay
fully volatile; failed/ambiguous runs keep claims and holds; only
proven-clean runs release ownership; no recovery surface in the CLI
(import-gated); stdout JSONL stays parseable. A latent SIGILL-class
defect found during counterfactuals (un-shut-down HTTP client on
post-client store failure) was eliminated by construction: identity
work precedes client creation, actor init is guarded, every
post-client exit shuts down first. Gates at HEAD: quick + native
green (94 tests), coverage `executed=198 failed=0 satisfied=23`.
RED/GREEN: 5 implementation counterfactuals (sealed persistence,
missing release/identities, silent fallback, recovery mention) + 8
pin counterfactuals incl. SIGILL-scenario coverage proving clean
exit-6 with no crash.

Scope guard: STORE-08 support export (A5-2) and M2-A epic closeout
(A5-final) NOT started.

## 20. A5-2 CLOSED — independent review APPROVED (2026-10-20)

Implementing commits `e3ef777..ef36ca1` (allowlisted JSONL export,
read-only GRDB handle with schema-gate, bounded atomic private
writes, `needletail session export` narrow CLI, STORE-08 binary +
unit evidence, requiredEvidence + maps pin), folds `e0d4058` (verify
fail-closed modes, umask-first, complete guard, binary resolution,
evidence gaps) and `1324909`/`d0c6213` (CLI hardening tests, review
nits). Reviewer: `deepseek-reviewer`, two rounds. Round 1
NEEDS_CHANGES (8 findings: silent chmod, umask/trace privacy,
incomplete reconcile guard, binary resolution, writer tokens as
credentials, link errno mapping, tmp cleanup, test evidence); all
folded with per-finding verification. Round 2 APPROVED with two
non-blocking nits, both fixed in-tree (checkpoint fixture coverage,
explicit handle close on write failure).

Delivered: read-only, session-scoped `needletail session export`
with redacted-by-default / content-on-request modes; credentials,
raw payloads, epoch snapshots and recovery free text never enter
either mode (writer identities travel as truncated hashes); unknown
outcomes stay unknown with held/unstarted/orphan ID inventories;
fail-closed on missing/corrupt/future/legacy/unknown-session; no
overwrites, no symlinks followed, no partial output; 0600 artifacts.
Gates at HEAD: quick + native green (112 native tests), coverage
`executed=216 labeled=113 failed=0 satisfied=24` (STORE-08 satisfied
as required). 11 RED counterfactuals (redaction removal, undeclared
field, unscoped read, bounds removal, no-overwrite clobber, unknown-session
guard, version gate, raw writer IDs, bare-filename handling, usage
exit-code mapping, no read-back halting the run).
Process-spawning suites run serialized with bounded 30s reaps after
one load-induced SIGKILL-timeout flake in CI that never reproduced
locally (same SHA green on re-run).

Scope guard: M2-A epic closeout (A5-final) NOT started.
