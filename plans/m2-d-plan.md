# M2-D Plan — durable queue, attachments, undo and rewind in virtual/headless form (REV1, planning only)

- Baseline: `main` @ `6104845` (M2-C merged, PR #7 squash). Local planning branch `m2-d-planning`.
- Authorization boundary: **planning, local documentation and independent plan review ONLY.** No implementation, no production/runtime behavior change, no live provider traffic, no dependency addition, no push/PR/merge in this session. Implementation slices D0–D3 each require separate authorization and per-slice DeepSeek review.
- Contract sources: COMPLETE-SPEC.md Part 8 MILESTONES M2-D (¶1330–1334), Part 6 quiescence/undo rule (¶924), UX-DX state rows STATE-02/STATE-05, Part 10 ACCEPTANCE UX-QUEUE-01..12 / UX-UNDO-01..11 / UX-MENTION-01..12, DEPENDENCIES.md, cases/catalog.json.

## 0. Review-round digest

- REV1: first full plan; baseline inventory verified at `6104845` (§2). Awaiting first deepseek-reviewer verdict.

## 1. Goal

Implement M2-D "queue, attachments and undo in virtual/headless form": authoritative durable follow-up/steer queue with crash-boundary receipts, structured attachment snapshots with stale-dispatch refusal, native change groups with quota-accounted preimages, undo eligibility with compensation (never atomic-claimed), and rewind lineage without filesystem mutation — all through pure state and core/temp-file integration, before any terminal controls.

**In scope**

- Queue hardening to close the M2 exit gap: dispatch-time route/consent re-validation under a new epoch (QUEUE-10 second half), head-of-queue attachment + grant validation with hold-instead-of-skip (QUEUE-08, first assignment of `HoldReason.staleAttachment`), crash-boundary receipts at queued/dispatched/delivered (QUEUE-06), cumulative-text budget tests (QUEUE-09 second half), busy-failure queue-visibility + explicit policy (QUEUE-12), structured headless approval stop that holds the queue (QUEUE-11 transition half), steer post-batch boundary + FIFO order tests (QUEUE-03/04), queue reorder via `orderKey` (QUEUE-05 reorder half; edit/withdraw already done), 500-chunk streaming scale test for draft survival (QUEUE-01).
- Attachment snapshots in structured form with injected candidates (no filesystem catalog in core): snapshot = resolved identity + content hash + byte range + bounded excerpt + capture epoch/route-grant; stale rule (hash changed or grant gone ⇒ hold + `staleAttachment`, never silent refresh/skip); sealed-vs-tool excerpt/manifest distinction; cancel/withdraw ⇒ zero dispatch; epoch/cloud switch ⇒ re-consent hold (MENTION-09/10/11/12).
- Native change groups (one group per dispatched mutating batch) with quota-accounted preimages (M2-B capture already exists); undo eligibility preflight (current-hash == afterHash, dev/ino identity + mode revalidation, in-root containment, no overwrite of later user work); compensation executor (restore preimage bytes / delete only-if-unmodified created file / refuse otherwise); partial-compensation logging (never claim atomic success); idempotent undo (duplicate/interrupted ⇒ reconcile, no second destructive inverse); fail-closed missing preimage with explicit non-undoable authorization path; exec-effects disclaimer notice; undo/partial notices appended to transcript before the next model request (STATE-05); quiescence + unresolved-outcome gates mandatory before any undo or next dispatch (UNDO-01..05/07/09/10/11, UNDO-08 lineage-only half, UNDO-06 disclaimer).
- Rewind lineage records only: fork marker with parent lineage, no file mutation, explicit divergence warning carried in state (UNDO-08 core half; interactive fork UX is M4).
- M3-gating integration: quiescence + unresolved-outcome checks enforced in the dispatch paths M3-B will exercise; M3-readiness checklist (§6).

**Out of scope (this milestone)**

- Any terminal wiring: `@` completion UI, preview rendering, queue edit/reorder/withdraw views, held-state recovery views, sessions/agents/models/context/epochs views, compact dry-run views, diff provenance views, undo/rewind flows, line-editor keybindings, ANSI/terminal adapter, PTY scenarios (all M4; M4-B re-lists them explicitly).
- `@`-mention grammar details due M4 (boundary parsing MENTION-02, token identity MENTION-03, 100K catalogues MENTION-05, ANSI/bidi preview MENTION-06, binary/symlink preview MENTION-07, `#L` ranges MENTION-08): core protects the loop via the snapshot/stale rules above; the composer UX follows.
- Exec-effect compensation (shell-produced changes are never ledger-undoable; disclaimer notice only).
- macOS qualification, cloud profiles, M3-C cache-shortening measurement, M3-D comparison (M3 work, after M3-B).
- New dependencies, live models, push/PR/merge.

**Certification targets** (catalog `due=M2` unless noted): UX-QUEUE-03/04/05(reorder)/06/08/09(bytes)/10(dispatch)/11(transition)/12 + QUEUE-01 scale + QUEUE-02 regression pin; UX-UNDO-01..05/07/09(core)/10/11 + UNDO-08 lineage + UNDO-06 disclaimer; UX-MENTION-09/10/11/12; STATE-02/STATE-05. Preservation: full M2-A/B/C lanes green throughout (e2e, native, C1/C2/C3).

## 2. Baseline findings that constrain the plan (verified at `6104845`)

Findings carry `file:line` evidence.

1. **Queue core exists; five holes remain.** Admission/hold/resume/pop/edit/withdraw/ack-idempotency/cancel-hold/epoch-stale-hold/20-item + 64 KiB-bound admission implemented (`SessionTransition.swift:322-373, 639-797, 806-876, 884-939, 1083-1184, 2347-2431`; `SessionState.swift:99-168, 347-387`). Holes: (a) `admitReservedRun` performs no `selectRoute`/`validateSealedInput` re-check under the new epoch before dispatch (`SessionTransition.swift:1140-1184` vs `admitFreshRun` `:639-673`); (b) no head-of-queue attachment/grant validation — `HoldReason.staleAttachment` defined once, never assigned (`SessionState.swift:175`, sole grep hit); (c) `holdForApproval` sets neither `queueHeld` nor any consent gate (`SessionTransition.swift:1768-1778`); (d) reorder absent — `orderKey` reserved for M2-D, no path assigns order (`SessionState.swift:139-140`); (e) byte-budget half untested (no test grep hit for `undispatchedBytes`/`maxQueueTextBytes`).
2. **Preimage capture exists; undo does not.** Edit/write publish verified preimages with `beforeHash`/`afterHash` in outcomes (`NativeToolExecutor.swift:2904-2936, 3042-3115`); grep for `undo|rewind|compensat|inverse|lineage|changeGroup` in `Sources/` returns only fd-repositioning and durability-note comments. No undo eligibility, no compensation ops, no rewind, no change groups, no `/undo` or `/rewind` commands.
3. **Mentions are UI scaffolding only.** `MentionSuggestionState` + 10-candidate cap + revision-guarded stale-drop exist in Presentation (`UIState.swift`, `UIReducer.swift:105-116`, tested); `UIAction.previewFile/requestCompletions` declared with no producer; "no mention grammar" (`LineEditorSession.swift:8`). No core attachment snapshot type, no sealed/tool excerpt path, no candidate-injection seam.
4. **Transcript/history structures are undo-ready but undo-unaware.** `DurableRecord` (`SessionStore.swift:7-38`), `TranscriptEntry` (`Transcript.swift:10-15`), export projection (`SessionExport.swift:95-248`) exist; no workspace-change notice record type, no undo receipt emitter (spec §6 ¶924 requires new `operationResult` receipts + notice, history append-only).
5. **The M3-B loop plumbing already exists.** `SessionActor` is transport-generic with internal multi-turn continuation; `ChatCompletionsTransport` dials only the authorized endpoint; `RunCommand.executeStatic` composes the production loop with poll-to-terminal (`RunCommand.swift:779-927`). M3-B is blocked on M2-B/C/D semantics, not on loop plumbing (verified by code reading, not assumed).

## 3. Slices

Each slice is independently implementable, testable, and reviewable (per-slice DeepSeek review). Order is dependency order: D0 → D1 → D2 → D3.

### D0: queue hardening + crash boundaries (Medium)

Goal: close every PARTIAL in UX-QUEUE so the queue is authoritative under faults, epoch changes, and headless operation.

- Dispatch-time re-validation in `admitReservedRun`: `selectRoute` + `validateSealedInput`/privacy re-check under the *current* epoch before dispatching a held entry (QUEUE-10 second half). Refusal holds with reason, never skips.
- Head-of-queue validation in `finishRunWithQueue`/`admitReservedRun`: attachment snapshot freshness + route-grant presence; stale/missing ⇒ hold + `HoldReason.staleAttachment` (first assignment), operator can fix or remove (QUEUE-08).
- `orderKey` assignment at admission (monotonic per session) + `moveQueueEntry` transition with revision guard (QUEUE-05 reorder half; edit/withdraw already done, regression-pinned).
- `holdForApproval` holds the queue: set `queueHeld` + structured approval-required reason, zero implicit dispatch on the headless path (QUEUE-11 transition half; exit-3 e2e legs already exist).
- Crash-boundary tests: kill after `queueAdmitted` vs after `queueUpdated(.dispatched)` vs after `admittedToHistory` ⇒ receipts + no duplicate provider input/side effect (QUEUE-06). Cumulative-text budget test: fill to 64 KiB, next enqueue refused typed, older entries intact (QUEUE-09 second half).
- Steer-boundary test (steer queued mid-stream/mid-exec waits for the post-batch boundary, never interleaves tool JSON — QUEUE-03); 2-steer + 3-follow-up FIFO order test, one-at-a-time, no dup/drop, within-kind order by `orderKey` (QUEUE-04); busy-failure test asserting visible queue state + explicit policy + no surprise continuation (QUEUE-12); 500-chunk synthetic stream + queued follow-up asserting single delivery + order (QUEUE-01 scale).
- Exit: all UX-QUEUE-01..12 green at pure/state tier plus temp-file crash legs; no M2-A/B/C lane regresses.

### D1: attachment snapshots + stale rules (Medium)

Goal: structured, injectable-candidate attachment snapshots that make queued dispatch evidence-exact, with refusal (never silent refresh/skip) on staleness.

- New core type `AttachmentSnapshot` (resolved identity dev/ino + content hash + byte range + bounded excerpt ≤4 KiB inline + artifact-store ref for the full bytes + capture epoch + route-grant snapshot). Candidates injected (Runtime resolves filesystem; core never catalogs).
- Admission binds snapshots to queue entries; dispatch revalidates hash + grant; mismatch ⇒ hold + `staleAttachment`, no silent refresh (MENTION-09).
- Sealed vs tool-mode: bounded excerpt/manifest in tool mode, explicit sealed-admission failure otherwise (MENTION-10). Preview-cancel/withdraw ⇒ zero provider requests, no epoch mutation, no orphan authoritative context (MENTION-11). Epoch/cloud switch before dispatch ⇒ re-consent hold (MENTION-12 + QUEUE-10 interplay).
- No `@` grammar, no preview rendering, no completion UI (M4). The snapshot type is shaped so M4 completion can attach to it without redesign (decision D-7 below records the seam).
- Exit: MENTION-09/10/11/12 green at pure/state + temp-file tiers; D0 queue tests still green.

### D2: change groups + undo eligibility + compensation + rewind lineage (Large)

Goal: the native ledger can actually restore what it captured — or truthfully refuse — with quiescence gates and history-append-only notices.

- `ChangeGroup` record per dispatched mutating batch (member op IDs + preimage digests + postimages + mode/identity), committed alongside completion receipts; group survives history compaction (UNDO-07: ledger available, eligibility governed by current file hashes).
- Undo eligibility preflight (pure + temp-file): current-hash == afterHash; dev/ino + mode revalidation; in-root containment; no overwrite of later user work (UNDO-02); created-file restore only if unmodified (UNDO-03); whole-group preflight — any conflict ⇒ no reversal starts, per-file conflicts visible (UNDO-04); symlink/inode/perm change ⇒ revalidate at commit, refuse/record conflict, no out-of-root write (UNDO-11).
- Compensation executor (temp-file integration + fault injection): restore preimage bytes / delete only-if-unmodified created file / refuse otherwise; I/O failure after first inverse ⇒ partial-compensation log, never atomic-success claim (UNDO-05); duplicate/interrupted undo ⇒ reconcile, no second destructive inverse, idempotent-safe error (UNDO-09 core); missing preimage (quota) ⇒ fail closed, or explicit non-undoable authorization path only (UNDO-10).
- Quiescence gate (spec §6 ¶924): undo runs only at a quiescent boundary — no in-flight tool, no unresolved outcome; gate checked in the undo entry transition and re-checked before commit.
- Notices: new `operationResult` receipts per inverse + concise workspace-change notice (paths/hashes/results) appended before the next model request; earlier history never rewritten (STATE-05); exec-effects disclaimer warning that shell effects are outside undo (UNDO-06).
- Rewind lineage records only: fork marker with parent lineage, no file mutation, divergence warning in state (UNDO-08 core half; fork UX is M4).
- Exit: UNDO-01..05/07/09(core)/10/11 + UNDO-08-lineage + UNDO-06-notice green; compensation fault-injection legs green; no lane regresses.

### D3: M3-gating integration + readiness (Small–Medium)

Goal: prove the assembled M2-D machine serves the loop M3-B will run, and record exactly what M3 may assume.

- Integration tests (headless `run` binary + temp dirs, no terminal): queued steer across tool batches with crash-reopen mid-queue; undo-eligible loop with a mid-loop user edit causing a truthful conflict (no overwrite); epoch-switch with stale mentions holding dispatch; quiescence gate refusing undo with in-flight tools and unresolved markers.
- Quiescence + unresolved-outcome checks enforced on every dispatch/undo entry path the M3-B loop exercises (mandatory per the M2-D exit paragraph).
- M3-readiness checklist (§6 of this plan, frozen as the slice exit): every must-have item mapped to passing tests; can-follow items explicitly deferred with the degradation noted.
- Exit: integration suite green; readiness checklist signed; CodeRabbit epic review of the M2-D diff; STOP for M2-D merge authorization (separate).

## 4. Critical invariants (cross-slice, non-negotiable)

- I-1 (fail-closed dispatch): no dispatch on stale attachments, missing grants, failed re-validation, missing preimages (absent explicit non-undoable authorization), or unresolved outcomes. Refusal holds with reason; skipping is forbidden.
- I-2 (no silent refresh): a snapshot is never refreshed under a queued entry; staleness holds the queue and is operator-visible.
- I-3 (no second inverse): duplicate or interrupted undo never runs a destructive inverse twice; reconciliation is idempotent-safe.
- I-4 (no overwrite of user work): eligibility is governed by current file hashes/identity; any divergence refuses with per-file conflicts.
- I-5 (history append-only): undo/rewind create new receipts and notices; earlier tool history is never rewritten (STATE-05).
- I-6 (quiescence): undo and dispatch-after-hold run only at quiescent boundaries (no in-flight tool, no unresolved outcome).
- I-7 (exec excluded): shell-produced effects are never ledger-undoable; the disclaimer is a notice, not a flow.
- I-8 (boundedness preserved): queue 20-item / 64 KiB-text bounds, snapshot excerpt caps, and preimage quotas apply on every path including undo and re-admission; refusals are typed, never silent drops.
- I-9 (no terminal in core): all D0–D2 behavior provable via pure state + temp-file integration; terminal controls are M4 and must not leak into core transitions.

## 5. Acceptance evidence mapping

| Slice | Spec cases (exit) | Test tiers |
|---|---|---|
| D0 | QUEUE-01(scale),02(pin),03,04,05(reorder),06,08,09(bytes),10(dispatch),11(transition),12; STATE-02 | pure state + actor + temp-file crash legs + headless binary legs where dispatch-shaped |
| D1 | MENTION-09,10,11,12 | pure state + temp-file (injected candidates) |
| D2 | UNDO-01..05,07,09(core),10,11; UNDO-06 notice; UNDO-08 lineage; STATE-05; §6 ¶924 quiescence | pure state + temp-file integration + fault injection (I/O failure, hash races, symlink swaps) |
| D3 | integration (queue+undo+epoch+crash), quiescence gates on M3-B paths, readiness checklist | headless binary + temp dirs; full M0–M2 lane preservation |

Out-of-plan (M4): MENTION-01..08 composer/preview UX, QUEUE-05 view-layer edit UI, UNDO-08 fork UX, UNDO-09 UX surfacing, `/undo` + `/rewind` terminal commands, all RENDER/NAV/PTY/DX-terminal rows.

## 6. M3 gating: must-have vs can-follow

**Strictly necessary before M3-B's real-model coding-loop experiment** (the loop cannot run truthfully without these): D0 in full (crash-safe, bounded, re-validated dispatch — otherwise a real loop can double-dispatch or run stale grants); D1 in full (stale mentions/grants must refuse in a headless loop no operator watches); D2 in full *minus terminal UX* (eligibility, compensation truthfulness, idempotency, notices — "undoable where the ledger permits" and "shell effects remain explicit" are M3-B's own words); D3 integration + checklist. Failure receipts + retained diffs/requests/outputs already exist (M2-A/B/C); D3 wires the quiescence gates M3-B exercises.

**Safely follows the viability decision** (degrades UX, never loop-correctness): `@` completion/preview/range/binary-preview UX (MENTION-01..08); queue edit-view/reorder-view/held-recovery views (QUEUE-05-view, QUEUE-07/12 views); rewind fork UX + duplicate-undo UX surfacing (UNDO-08/09 views); `/undo` + `/rewind` terminal commands; M3-C cache-shortening measurement and M3-D Pi comparison (these *are* M3, sequenced after M3-B).

**M2-D scope M3 does not need at all**: any terminal/line-editor/ANSI/PTY wiring; macOS qualification; cloud profiles; M4+ dependency (swift-markdown).

## 7. Genuinely unresolved design decisions (require operator/reviewer input)

- D-1 Reorder mechanism: `orderKey` assignment at admission + explicit `moveQueueEntry` (revision-guarded) vs array-position only. Proposed: orderKey (the state comment reserves it for M2-D); needs confirmation before D0.
- D-2 Snapshot byte storage: bounded excerpt inline (≤4 KiB) + full bytes as artifact-store ref vs fully inline. Proposed: hybrid (inline excerpt for the notice/preview-seam, ref for fidelity); interacts with the 64 KiB queue budget.
- D-3 Undo scope: file-restore only, exec effects excluded with disclaimer (spec-directed). Confirm no exec-compensation is ever wanted, even operator-approved.
- D-4 Non-undoable authorization shape: explicit per-approval `undoable:false` marker requiring typed grant when a preimage is unrecordable (quota) — vs blanket refusal. UNDO-10 allows either; the plan proposes the explicit-grant path so bounded M3 tasks are not bricked by quota, but needs authorization-policy confirmation.
- D-5 Rewind lineage representation: epoch-fork record reusing `parentEpochID` lineage vs turn-marker list. Proposed: epoch-fork (M3-C checkpoint interplay); needs M3-C author confirmation that fork records compose with epoch shortening.
- D-6 Change-group granularity: one group per dispatched mutating batch (matches ordered-batch composition + NC-17 per-proposal reduction) vs explicit cross-batch groups. Proposed: per-batch.
- D-7 M4 seam: snapshot/notice/record shapes frozen in D1/D2 must be consumable by M4 completion/preview/views without redesign. Proposed: reviewer checks the seam at each slice review (cheap now, expensive later).

## 8. Complexity estimate + review plan

- D0: Medium — ~6 transition additions (revalidation, stale-hold, move API, approval-hold, notice shapes) + ~10 tests (pure/state/temp-file/binary). Comparable to half an M2-B slice.
- D1: Medium — one new core type + validation paths + sealed/tool branches + injection seam + ~8 tests. No store migration expected (snapshots reference artifacts; confirm in review).
- D2: Large — new ChangeGroup/UndoRecord types + store support (possible migration — confirm in review) + executor inverse ops + eligibility preflight + partial-compensation log + idempotency + notices + quiescence gates + ~14 tests with fault injection. Largest M2-D slice, comparable to M2-C C2.
- D3: Small–Medium — integration suite (~6 headless binary scenarios) + gate enforcement + checklist doc. Mostly evidence, little new logic.
- Review plan: per-slice DeepSeek review (D0→D1→D2→D3 order, each needs authorization); CodeRabbit whole-system review of the M2-D diff at epic close; STOP for M2-D merge authorization. Total scope deliberately smaller than M2-C (no process supervision, no Linux FD-level machinery); risk concentrates in D2 compensation correctness, which fault-injection tests pin down.
