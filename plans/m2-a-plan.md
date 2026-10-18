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

## 9. Rev2 → REV3 changes (delta review: F-fixes confirmed; G-findings folded)

- G-01 PROC-01 identified as already executed at M0 and carried (§2.5), not silently omitted.
- G-02 A0 adds the `NeedletailPrimitiveTests → NeedletailRuntime` dependency edge so production-store evidence is reachable at the native tier (A1 STORE-01 and A2 STORE-06 depend on it).
- G-03 conformance ripple corrected to 4 known conformances; phantom fakes removed (§6).
- G-04 internal contradiction fixed: codec is A0 work (§1 now matches §3/A0 and §8/F-01).
- G-05 `StoreError.alreadyOwned` payload change (winner's writer ID) added to A2 scope and the §6 ripple list.
- G-06 import rule scoped to shipped targets; test-only GRDB linkage explicitly preserved (§5).
- Non-blocking wording fix applied to §7.2 (application-crash durability is SQLite's guarantee under WAL, independent of sync mode).
