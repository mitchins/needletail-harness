# M0-A/M0-B plan review receipt

Review type: minor-milestone PLAN review (pre-implementation, REV-01 gate).
Reviewer alias: `deepseek-reviewer` · Actual model route: `opencode-go/deepseek-v4.1-flash` (resolved from the locally configured agent definition; independent of the implementer route `opencode-go/step-5-preview-free`).
Reviewer independence verified from `~/.config/opencode/opencode.jsonc` (subagent mode; edit deny; bash allowlist git/status/log/npm only). No credentials copied.

## Subject identity

- Plan digest (before disposition): `plans/m0-a-b-plan.md` sha256 = `974ad35d85262ce36e48f31a7ee21fa1613a6b9b509cdccfe5e664ffd430922f`
- Baseline commit: `86a717b0fda17d7690ce97b3161110cd169f5d33`
- Packet inputs: `COMPLETE-SPEC.md` sha256 `fc6627c63a5b03be76530deb4b5ba8386420b9c798dcfd4075ba5a4c28e25dbf`; `DEPENDENCIES.md` sha256 `5352016890573b84693a8bc115a7a241b82201b12991abb35d3bfd8e5702159f`; scratch evidence logs `/tmp/opencode/probe-build.log`, `/tmp/opencode/probe-build2.log`, probe graph `/tmp/opencode/needletail-probe`.
- Invocation timestamp: 2026-10-11T22:18:05Z (packet); review returned 2026-10-11T22:2x.

## Reviewer record

- Inspected source/raw evidence: YES (plan in full; COMPLETE-SPEC.md Parts 1–16 incl. DEPENDENCIES/TESTING/REVIEW/MILESTONES/SPEC §4/§15/ACCEPTANCE Part 10; DEPENDENCIES.md; probe build logs; probe Package.swift/Package.resolved).
- Re-executed builds/network: NO (shell beyond git/npm denied by policy; counting and evidence inspection done by file reads).

## Disposition: READY (no Blocker)

Reviewer verified: catalogue count is faithful (100 product + 68 UX/DX/PTY + 32 v0.3 = 200; product/UX 168 + delivery 32); dependency evidence is real (6-pin-graph `Build complete! 31.84s`; GRDB `sqlite3.h` failure reproduced); F-1/D-1/D-2 routing directionally correct.

### Findings and dispositions

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| DR-01 | Major | GRDB must be declared-but-not-linked while D-2 open, else finish condition is unsatisfiable | FOLDED before implementation (plan §2.4, §9, §12.1) |
| DR-02 | Major | `./dev test native` must really run the M0-B probes, not be a stub | FOLDED (plan §8) |
| DR-03 | Major | `NeedletailPresentation` must wait for M1-B; ledger types are test-support | FOLDED (plan §8, §9) |
| DR-04 | Major (marked uncertainty) | Catalog must freeze against an independently authored fixture, both directions, with ACCEPTANCE.md-unavailable provenance | FOLDED + accepted-with-documentation (plan §9, §10, §13) |
| DR-05 | Major | Draft `dependency-inventory.json` belongs in M0-B scope | FOLDED (plan §9, §12.4) |
| DR-06 | Minor | Use official status vocabulary | FOLDED (plan §3, §6.9, §10–12) |
| DR-07 | Minor | Record cold/warm and pure/native evidence separately | FOLDED (plan §12.2) |
| DR-08 | Minor | Full `./dev` entry-point set incl. disabled-with-reason stubs | FOLDED (plan §8) |
| DR-09 | Minor | Move ledger types out of Core into TestSupport | FOLDED (plan §8) |
| DR-10 | Minor | Record permitted scratch roots | FOLDED (plan §2) |
| DR-11 | Suggestion | Qualify the toolchain's machine-readable result route before adopting a reporter | FOLDED (plan §8) |
| DR-12 | Suggestion | Fix fault key; add no-sleep/readiness-handshake invariant | FOLDED (plan §10, §11) |
| DR-13 | Suggestion | State combined-slice rationale and file/line budget | Accepted-with-documentation (plan §13) |
| DR-14 | Suggestion | 25 vs 26 pin wording precision | FOLDED (plan §2.3) |

Smallest unblocking action per reviewer (declare GRDB unlinked; real `test native`; defer Presentation; add inventory draft) has been applied to `plans/m0-a-b-plan.md`. Post-disposition plan digest recorded in STATUS.md after the edit; implementation of M0-A/M0-B is authorized to start, with D-1/D-2 still routed to the human maintainer (neither blocks M0-A or the non-GRDB M0-B probes).

## Review authority notes

Per REVIEW.md §2: the reviewer saw contract + evidence, never an instruction that the implementer is correct; findings carry concrete locations or marked uncertainty; `NEEDS_EVIDENCE` was not required. Raw review output retained offline in this receipt's table (verbatim findings summarized by ID/severity with the reviewer's disposition list); the full verbatim response is stored with the implementer session log and is not a substitute for the code-side evidence at slice closeout.

---

# Completed-slice review receipt (REVIEW.md §1 cadence)

Review type: completed minor-milestone review (M0-A + M0-B).
Reviewer alias: `deepseek-reviewer` · Actual model route: `opencode-go/deepseek-v4.1-flash`.
Subject: full M0 slice tree (file list `.needletail-dev/m0-file-list.txt`), closeout report `plans/m0-milestone-report.md`, `STATUS.md`, raw logs `.needletail-dev/logs/*`. Baseline `86a717b0…`. Reviewer inspected source, tests, fixtures and raw logs; did NOT re-execute builds (shell allowlist).

## Disposition: NEEDS_EVIDENCE → findings fixed, final re-review at frozen head pending

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| F-1 | Major | Cancellation probe credited to NET-05, whose scenario (pre-stream retry vs mid-stream disconnect) it does not exercise | FIXED: relabeled NET-04 (`NET_04_cancellationCompletesBounded`); report credits NET-04; NET-05 + CORE-02 DEFERRED_BY_PLAN |
| F-2 | Major | Intentional-failure probe reachable from bare `swift test` (green-path hazard) | FIXED: `.enabled(if: NEEDLETAIL_QUALIFICATION=1)` gate; bare `swift test` exit 0 (log retained); `./dev test qualification` still detects the failure |
| F-3 | Major | 13 M0-due IDs unsatisfied and unscheduled | FIXED: BDD-01..04, REV-01..04, DEV-01/02/04, PORT-01, DX-08 executed with evidence; BDD-05→M2, BDD-06→M1, BDD-07→M4, BDD-08→M1, REV-05..08→M0-D, DEV-03→M0-D reassigned by this reviewed disposition (fixture+catalog provenance updated) |
| F-4 | Minor | No head/tree identity on the subject | FIXED: tree hash recorded (`.needletail-dev/m0-tree-hash.txt`); head SHA filled at commit |
| F-5 | Minor | Asserted commands lacked raw evidence | FIXED: all command outputs retained under `.needletail-dev/logs/` |
| F-6 | Minor | DX-08 claimed, not exercised | FIXED: executed under proxy blackhole + Node/Python-free PATH + fake HOME; exit 0 (`test-quick-offline.log`) |
| F-7 | Minor | `coverage` not TESTING §4 reconciliation; reconciler milestone-blind | FIXED (documented): M0-scope reconciliation documented in `dev` and STATUS; tier/due-aware coverage deferred with results ingestion |
| F-8 | Minor | STORE-01 labeled DEFERRED_BY_PLAN (catalog) vs UNQUALIFIED_ENVIRONMENT (status/report) | FIXED: catalog `status_detail` first carried both `test_status: DEFERRED_BY_PLAN` and `environment_status: UNQUALIFIED_ENVIRONMENT`; after decision D-2 resolved (operator installed libsqlite3-dev), STORE-01 executed PASS on Swift 6.4.0 and `cases/catalog.json` records the executed evidence |
| F-9 | Minor | swift-crypto declared-but-unlinked, not recorded | FIXED: inventory note; Package.swift comment |
| F-10 | Suggestion | Server readiness wait unbounded; polling teardown | FIXED: bounded readiness watchdog; timed semaphore wait |

## Subject freshness

The pre-fix working tree was not staged when the slice review ran, so its tree hash was not captured — a recording gap recorded here rather than reconstructed. What is immutable:
- Slice review (NEEDS_EVIDENCE) inspected the pre-fix tree by file list `.needletail-dev/m0-file-list.txt` and logs; findings F-1…F-10 are quoted verbatim above.
- Post-fix tree `788a6acd93508abc84d8f6f6df300e1bab9afaf1` = commit `4d2805d`; final head `1770956` tree `6de5ddf0332da6d86d5df9479da801d9f1af4cc0` recorded in `.needletail-dev/m0-tree-hash.txt`.
- Final verification at `1770956`/`6de5ddf…` returned NEEDS_EVIDENCE on F-3 (catalog status of reassigned IDs contradicted the report) plus stale-text gaps N2–N4; all corrected in the follow-up commit.
- Closure verification at `a91f689`/`0315650…` found one surviving stale sentence (this file's F-8 row and the report's F-8 bullet); corrected in the next commit. Both tree hashes are immutable in git history (`4d2805d`→`788a6ac…`, `1770956`→`6de5ddf…`, `a91f689`→`0315650…`); `.needletail-dev/m0-tree-hash.txt` points at the latest reviewed head.

---

## Closure determination

| Review | Subject | Disposition |
|---|---|---|
| Plan review (pre-implementation) | plan `974ad35d…`, baseline `86a717b0…` | READY (DR-01…DR-14 folded) |
| Completed-slice review | pre-fix slice tree | NEEDS_EVIDENCE (F-1…F-10; all fixed) |
| Toolchain re-qualification review | `1770956` / `6de5ddf…` | NEEDS_EVIDENCE (F-3 PARTIAL + N2–N4; fixed at `a91f689`) |
| Closure verification | `a91f689` / `0315650…` | NEEDS_EVIDENCE (surviving F-8 sentence; fixed at `5ad7d28`) |
| Final check | `5ad7d28` / `a8d7177…` | NEEDS_EVIDENCE (stale 20-test count in STATUS; fixed at `07e0269`) |
| Incremental doc-only review | `07e0269` / `d7a1107…` | **READY TO CLOSE** |

Final closure: `deepseek-reviewer` route `opencode-go/deepseek-v4.1-flash`, documentation-only diff verified at `07e0269`, no new blocker. M0-A/M0-B slice is closed at head `07e0269b5254194a73f65928f8f32f03aa3c06bf` (base `86a717b0…`). No tests were re-executed by the reviewer at any round (shell allowlist); all runtime evidence is the retained logs referenced in `plans/m0-milestone-report.md`.
