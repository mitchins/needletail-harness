# M2-0 closeout receipt (test assurance)

Head at closeout: `2650aac` + the STORE-06 evidence correction. PR #4 (squash-merge
after operator manual approval). All CodeRabbit findings across 13 review rounds
(2026-10-17 08:12Z → 2026-10-18 12:03Z) remediated and re-reviewed; the final
correction after the last substantive review was accepted on operator manual review.

## What M2-0 delivers (executable evidence in `./dev coverage`)

- **Runner ingestion**: `Tests/BehaviourTests/XUnitIngestionTests.swift` joins actual
  Swift Testing xunit output to `cases/catalog.json` via the single
  `ResultsReconciler` (110 executed, 88 labeled in the reported run; skips recorded
  as `.deferredByPlan` → unsatisfied; failures → FAIL; parameterized cases collapse
  to one `<testcase>` — documented gap, argument-level variants are NOT certified).
- **Evidence tiers**: explicit, asymmetric native/terminal/live/packaging matching;
  exhaustive switch (no `default`); mock pins pass test gates but never veto
  native certification; certifying variants pinned by exact function + module.
- **Replay**: `STATE_01_cancelledLateCompletionReplays` — real reducer-minted
  effect reservation, independent state/effects/receipts oracles, forbidden-effect
  checks, whole-state expectation built with the public initializer (independent
  of `replacing`).
- **Store contracts**: shared `StoreContractAssertions` executed on in-memory AND
  SQLite backends (order/pagination, exact ownership error, real 10k quota fill,
  reopen leg with lossless payload codec).
- **Crash primitive**: STORE-02 separate-process SIGKILL mid-transaction with
  proven page spill (DB file growth + journal presence) and rollback-on-reopen.
- **RED counterfactuals**: three deliberate probes (stale-drop, ownership error,
  quota guard) each verified RED, restored byte-identical, GREEN re-run — plus the
  STORE-06 misclassification probe below.

## STORE-06 disposition (operator decision, this correction)

The prior `STORE_06_sqliteWriterOwnershipExclusive` / in-memory tests prove only
GLOBAL-SLOT exclusion: a competing DIFFERENT session fails with the exact owner.
They do not prove two writers cannot hold the SAME session — with the current
`SessionStore` interface, same-session claims are idempotent and there is no
writer identity. Listing them as certifying STORE-06 evidence was a semantic
coverage false positive.

Correction applied:
- Ownership tests reclassified as unlabeled global-slot evidence (no catalogue ID).
- `XUnitIngestionTests.deferredToM2A` registers
  `STORE-06 → STORE_06_twoWritersCompeteForOneSession` as required certifying
  evidence with a hard gate: STORE-06 must NEVER appear in `satisfied` in M2-0.
- RED probe executed: with the false certification still live, the new gate failed
  with `satisfied=[… STORE-06 …]` (proof the present evidence cannot satisfy
  STORE-06 honestly). GREEN after reclassification.

## Outstanding M2-A obligation

**STORE-06 — two writers open same session.** Implement writer identity/ownership
fencing in the production store (M2-A schema), add the test named
`STORE_06_twoWritersCompeteForOneSession` (two independent handles claiming the
same session; exactly one wins, the loser receives
`StoreError.alreadyOwned(session:)` with the winner's identity), and remove the
entry from `deferredToM2A` so ingestion begins certifying STORE-06. Until then
STORE-06 stays formally unsatisfied; M2-A also owes production-schema and
real-operation crash qualification (STORE-03/04/05 and the STORE-02 points on the
production store).
