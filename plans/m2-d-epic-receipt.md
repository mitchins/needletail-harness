# M2-D Epic Receipt — durable queue, attachments, undo and rewind in virtual/headless form

- Branch: `m2-d-planning`
- Baseline: `main` @ `6104845` (M2-C merged, PR #7)
- Plan: `plans/m2-d-plan.md` REV3 (planning only; implementation slices
  D0–D3 each separately authorized with per-slice DeepSeek review)
- Qualified code HEAD: `a47e216` (this receipt is void if the code
  tree moves — re-qualify and re-issue. Prior qualification
  checkpoints: D2 `c152865` (DeepSeek APPROVED), D3 `394c07c`
  (DeepSeek APPROVED); subsequent deltas are covered by the
  whole-system review below.)
- Status vocabulary: `cases/catalog.json` is untouched by D0–D3 by
  precedent; the due-milestone flip to IMPLEMENTED with executed
  evidence belongs to the M2-D epic PR (CodeRabbit whole-system review).

## D0–D3 completion history

- **D0 — durable queue/replay/head barrier** (`75c0187` series; DeepSeek
  NEEDS_CHANGES → all fixed in-tree: switchModel hold, production
  `resumeSession` entry point, failed-run join, ack `queueEntryIDs`,
  replay allocator watermark continuity). Delivered: durable queue
  replay, dispatch linkage, held-head barrier, validate-before-marking,
  epoch retarget path, byte/text budget legs.
- **D1 — attachment snapshots** (`c9cd23c`, `04a2a1d`; DeepSeek final
  APPROVED, with the cancellation/snapshot-loss defect fixed and
  regression-covered). Delivered: structured injectable snapshots,
  atomic capture, stale-dispatch refusal, sealed/tool branches,
  cancel/withdraw ⇒ zero dispatch, epoch re-consent.
- **D2 — change groups, native undo, durable inverse journal, rewind
  lineage** (`e0f3491`; DeepSeek NEEDS_CHANGES: 1 Blocker + 5 Majors,
  all fixed in `b04fc91`; Major 5 rebutted with evidence and accepted.
  Re-review NEEDS_CHANGES (legacy-row compat, pre-fix rows, recovery
  report), all fixed in `c152865`; final **APPROVED**). Delivered:
  per-batch change groups with boundary-captured identity, exclusive
  `SessionPhase.undoing`, whole-group preflight, one-inverse-at-a-time
  compensation with commit-time revalidation, O-2 journal, O-3
  transcript notices, `LineageFork` records, resume reseeding,
  `recoverUndoJournal` sweep.
- **D3 — integration, recovery qualification, epic readiness**
  (`08f0b95` + review fixes in `cd75adc` + `394c07c`; DeepSeek
  NEEDS_CHANGES: 2 Blockers + 2 Majors, all addressed; re-review
  NEEDS_CHANGES (2 doc-precision Majors), all addressed; final
  **APPROVED**). Delivered: single authoritative reopen sequence,
  scenarios A–F with real GRDB + production actor,
  failure-injection legs, bypass counterfactuals, explicit
  unknown-acknowledgment path, M3-B preflight checklist (frozen).

## Evidence (all executed, none self-awarded)

### Native + real-store tiers (no mocks for the system under test)

- `B3EditWriteTests` 31 pass (executor boundary identity, preimages).
- `C2ExecDurableTests` 41 pass, `C3ExecQualificationTests` 18 pass
  (M2-C lanes preserved after the D2 executor changes).
- `NeedletailStateTests` 180 pass (includes 33 D2 `UndoTests`).
- D2 `UndoFilesTests` 10 pass (real FS + real GRDB: restore, user-edit
  refusal, create/delete/repurpose, symlink/mode/root refusal, missing
  preimage (incl. distinct restoreMissing kind + commit-gate revalidation),
  empty-original restore, double-apply counterfactual).
- D2 `UndoJournalTests` 5 pass (real GRDB resume: unknown hold,
  settled reseed, export redaction, ambiguous reopen, pre-fix rows).
- D2 `UndoActorTests` 5 pass (full loop, preview conflict, fault
  injection, boundary-5 recovery sweep).
- D3 `D3IntegrationTests` 14 pass (A: order/IDs/acks/no-duplicates;
  B: unknown head, no-resend, reconcile durability, release-only-
  intended; C: stale snapshot across reopen, no overtake, fix +
  reconsent, provider-context proof; C2: epoch switch preserves
  unknown head, retarget refreshes consent without release, drain
  carries current bytes; D: partial undo across reopen, no replay,
  user edits retained; E: notice-before-next-request exactly once +
  second sweep; E2: live commit-failure integrity stop with honest
  unknown hold and explicit re-acceptance; F: combined holds, every
  bypass refused, explicit reconciliation in order; 4 bypass
  counterfactuals: resume/sweep/fencing/corrupt-journal).
- `RecordCodecTests` (incl. legacy-row decode tolerance),
  `SessionExportTests` (allowlist incl. all D2 keys, redaction both
  modes), `ReopenReconciliationTests`, `QueueDurabilityTests`,
  `B0F2BDurabilityTests` 11 (F2B-5 ack-never-converts pins intact).

### Acceptance-case tier mapping (REV3 §5; M4 rows excluded)

| Slice | Scheduled cases | Evidence |
|---|---|---|
| D0 | UX-QUEUE-06/09(both)/10(route); STATE-02(durable)/STATE-03 | D0 lanes; D3 A (order/IDs/acks/no-dup), B (linkage/no-resend/durability/release), F (combined) |
| D1 | UX-QUEUE-08/10(dispatch); UX-MENTION-09/10/11/12 | D1 lanes; D3 C (stale head/no-overtake/fix+reconsent), C2 (epoch switch/retarget/reconsent) |
| D2 | UX-UNDO-01..05/07/10/11; UNDO-06 notice; UNDO-09 core; UNDO-08 lineage; STATE-05 | D2 53 tests (33 + 10 + 5 + 5); D3 D (partial across reopen), E (boundary-5 exactly once), F (combined), CF-sweep |
| D3 | integration (queue+undo+epoch+crash), quiescence gates on M3-B paths, readiness checklist, STATE-05 end-to-end | D3 15 tests (A, B, C, C2, C3, D, E, E2, F, pure ack, 5 counterfactuals); `plans/m2-d-m3-readiness.md` (frozen) |

Deferred test rows (M4 dues, not exited): QUEUE-01/02/03/04/05/07/11/12
rows, UNDO-06/08/09 rows, MENTION-01..08 UX rows, `/undo` + `/rewind`
commands, all RENDER/NAV/PTY/DX-terminal rows.

## Independent review dispositions

- D0: NEEDS_CHANGES → fixed (see history). D1: APPROVED (final).
- D2: NEEDS_CHANGES (Blocker 1: ambiguous results recorded done;
  Major 1: reversed preflight pairing; Major 3: heldUnknown gate;
  Major 4: notice hashes; Major 2: boundary-5 production recovery;
  Major 5 rebutted/accepted) → fixed; re-review NEEDS_CHANGES
  (legacy-row decode, pre-fix row classification, recovery report
  shape) → fixed; final **APPROVED**.
- D3: NEEDS_CHANGES (Blocker 1: reconcile ack-honoring regressed the
  approved D0 F2B-5 never-converts contract → reverted; ack is
  live-session-only, reopen re-derives holds; Blocker 2: same for the
  journal/resume path → same resolution + pure test updated to pin
  still-held semantics; Major 3: missing store file now fails closed;
  Major 4: second sweep executed, C2 epoch-switch/retarget leg,
  provider-context assertions, citation fixes) → all addressed in
  `cd75adc`; re-review NEEDS_CHANGES (2 doc-precision Majors: stale
  ack doc, readiness row 8 scope) → all addressed in `394c07c`;
  final **APPROVED**.
- Epic (whole-system, PR #8): CodeRabbit CHANGES_REQUESTED with 15
  findings (verified 2026-10-30) → all reconciled in `ba1fccb` +
  `a47e216`: 13 fixed in-tree (allocator watermark vs post-reopen ID
  collision; commit-gate re-open + content re-hash with unit tests;
  CRLF sliceLines trap + fixture test; missing-preimage distinct kind;
  O_NONBLOCK post-commit verify; fsync-dir outcome reporting;
  no-op yield-loop removal; case-ID test naming incl. `dev test case`
  resolution; doc corrections for counts/plan-title/STATUS), 1
  explicitly rejected with evidence (fresh-run durable ack records:
  contradicts the settled D0 REV3 design — no queue records for
  fresh admissions by design; no defect demonstrated), 1
  superseded-by-revert (ack honoring already removed per F2B-5).
  Round 2 (3 findings on the fixed tree): empty-digest sentinel,
  commit-gate re-read + WorkspaceLock question, display-name fix →
  all fixed; WorkspaceLock declined with evidence (exclusive
  `undoing` phase admits no cooperating contender). Final
  CodeRabbit check: PASS, all threads resolved (2 findings withdrawn
  by the reviewer).
- Epic round 3 (4 out-of-diff findings on the fixed tree): duplicate
  queueDispatched links → discriminating integrity error (reject only
  without an intervening recorded reconcile; legitimate
  reconcile→redispatch preserved; positive + negative replay tests);
  attachment alias verdict (grant alias must equal the live route
  alias; C3 cross-alias test, RED-proven); export notice rows carry
  inverseID + content-gated detail; receipt count reconciliation
  (D2 = 53). All fixed with evidence; final CodeRabbit verdict:
  **APPROVED** (no Blockers/Majors open).
- Remote gates on qualified HEAD `a47e216` (2026-10-30/31): offline
  build + tests PASS (40m lane); clean-host release smoke PASS;
  SonarQube + SonarCloud PASS; GitGuardian PASS. (One CLOSURE_01 race
  failure occurred on an earlier push's run in a timing-sensitive
  search test untouched by this epic; 3/3 local reruns green and the
  final HEAD's full lane passed clean — recorded as a flake, not
  concealed.)

## Known flakes and remaining limitations

- Timing-sensitive suites flake under load: `OperationIntentActorTests` /
  `ToolAdvertisementRoundTripTests` (20k-yield barriers) fail
  identically on pristine `04a2a1d` — pre-existing and unrelated to
  D2/D3 (D3 suites await durable state, not timing, and pass
  consistently); `CLOSURE_01_explicitRootRace` (search root-swap
  timing) failed once on CI and passed 3/3 locally plus clean on the
  final HEAD's full lane — pre-existing race shape in code untouched
  by this epic, recorded, not concealed.
- Subprocess/network lanes (C1 reap 18 s timeouts, WIRE-02 loopback,
  CLI end-to-end) are sandbox-load sensitive; C1/C2/C3 re-verified
  green in isolation during D2.
- No terminal/PTY, macOS, cloud, live-model or push/PR/merge work was
  done or claimed.
- Deliberate semantic limits (unchanged from plan): same-path
  multi-touch groups refuse whole-group (exact identity); fresh-run
  admissions carry no durable delivery tracking; unknown
  reconciliations are explicit and per-boot (acks never convert).
