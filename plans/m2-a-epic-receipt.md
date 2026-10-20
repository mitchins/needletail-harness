# M2-A Epic Receipt — EPIC-REVIEW READY

Candidate head: `m2-a-store` @ `04f554a` + preflight (content-freeze SHA
recorded at push; CI-qualification entry appended post-push as §8).
PR #5 open, unmerged. No merge performed. Next session owns the
aggregate CodeRabbit review + merge-readiness disposition.

## 1. What M2-A claims (and does not)

- Satisfied with tier-correct native evidence: STORE-01 … STORE-09,
  PORT-04 (+ STATE-01, M1 scope, carried in the same gate).
- STATE-03 (provider ambiguity at crash) is explicitly NON-CERTIFYING:
  zero required variants, zero tests emit STATE-03 results, catalogue
  status DEFERRED_BY_PLAN. Unknown-outcome semantics are certified
  instead via STORE-02/A3 (held/unstarted/orphan inventories).
- M2-A closeout scope per plan REV3 §5: only STORE-01..09 + PORT-04
  satisfied; all other M2-due cases (TOOL-*, UX-*, PROC-02..06,
  STATE-02/05, POLICY-01/06/07, PORT-03, BDD-05, PKG-05) belong to
  M2-B/C/D and are `missing` by design (171 missing, expected).

## 2. Local gates at the candidate head (all green)

- `./dev test quick`: 28 tests, 4 suites, pass.
- `./dev test native`: 113 tests, 17 suites, pass.
- `./dev coverage`: COVERAGE OK —
  `executed=217 labeled=113 unlabeled=104 skipped=1 failed=0
  satisfied=24 unsatisfied=5 missing=171`.
  - All 11 required cases satisfied (gate asserts every required
    variant executed in its pinned module): STATE-01 (5 pass),
    STORE-01 (3), STORE-02 (9), STORE-03 (1), STORE-04 (1),
    STORE-05 (7), STORE-06 (3), STORE-07 (3), STORE-08 (2),
    STORE-09 (3), PORT-04 (1). Zero failures anywhere.
  - satisfied=24 preserved (23 pre-STORE-08 + STORE-08).
  - The 5 unsatisfied are non-required cases with partial evidence
    outside M2-A scope; none is M2-A-closeout.
  - skipped=1 is the ingestion self-test (`BDD_01_…` skips outside
    `./dev coverage` by `.enabled(if:)`); BDD-04 records skips as
    unsatisfied — no silent skip (gate pins this).
- `./dev test offline`: OFFLINE OK (all scheduled offline layers).
- `./dev release-bundle` + `./dev test packaging`: CLEAN-HOST SMOKE OK
  (digest-pinned container, no network, no toolchain).
- Focused suites: SessionExportTests 9/9, RecordCodecTests (incl.
  strengthened `decodeRefusesInvalidProfileRow`) pass.

## 3. RED/GREEN counterfactual evidence (this preflight)

- Adversarial source-bytes (`exportBoundsSourceBytes`, deterministic:
  20 × ~10 KB secrets, 5 KB budget, ~2 KB redacted output): guard
  removed → export succeeds while retaining ~200 KB (Issue recorded,
  RED); guard present → `.byteLimitExceeded` (GREEN); generous-budget
  control exports fine with redaction intact.
- Validating-init pin (`decodeRefusesInvalidProfileRow` + new
  `message.contains("context_window")` assertion): `checkRange`
  neutered → decode succeeds silently (RED); intact → `.integrity`
  naming `$.store.model-profile.context_window` (GREEN).
- Large-trailer regression (`exportVerifiesLargeTrailer`,
  deterministic: 4500 completed ops, ~250 B IDs, 9001 rows under the
  10 k session quota): asserts the TRAILER line itself exceeds 1 MiB
  and `writeLines` verifies it — a fixed tail window would fail this.

## 4. Native/process qualifications

- STORE-02 crash matrix: 8 self-hosted child-process kills
  (SIGKILL at intent/commit/result/side-effect points, artifact tmp +
  rename + verified-read legs) + the original DELETE-mode probe as
  supplementary evidence; serialized suites + bounded 30 s reaps.
- PORT-04: native kill/reopen leg executes in NeedletailPrimitiveTests
  (module-pinned; an emptied body would still satisfy the gate, so a
  source pin asserts the body performs a real kill).
- Process-kill vs power-loss: the matrix qualifies PROCESS-KILL
  (SIGKILL + waitpid-verified reaping) with WAL + `synchronous=FULL`
  + fsync/dir incumbent durability. POWER-LOSS (torn OS/hardware
  writes, used-space exhaustion mid-commit) is NOT qualified — no
  fault-injection harness exists; the completeness guard
  (`stream.count >= total`, trailer count match) fails closed on
  whatever a power event leaves behind, but that path is untested.

## 5. Privacy boundaries (STORE-08 export)

- Default redacted mode emits structural metadata only; free text
  travels ONLY with `--include-content`, and even then NEVER:
  credentials, raw provider payloads, epoch/config snapshots, routes,
  capability maps, recovery rationale. Writer identities travel as
  truncated SHA-256 hashes. Trailer carries operation-ID inventories
  only. Tested with per-field sentinels incl. at-scale redaction.
- Export reads through a READ-ONLY handle (no claim/release/
  migration/writes); version + full schema-shape gate before any row.
- Output files are 0600, tmp→fsync→verify→atomic-link (never
  overwrite, never follow symlinks), dirsync with target removal on
  failure. Failed exports leave no target and no tmp debris.

## 6. Durability limitations

- SessionExport bounds: shared `maxBytes` budget over retained output
  + source pages (fail-closed); EXCLUDED from the guarantee: the
  single in-flight page (≤200 rows) + one row's decode expansion.
  Trailer verification scans back from EOF with no fixed cap
  (O(trailer)); mid-file corruption is out of scope for that check.
- Preflight delta review (deepseek-reviewer) of the bounds fold:
  first round NEEDS_CHANGES (1 Major: fixed 1 MiB window could reject
  valid large-trailer exports; 1 Medium: page transient + doc claim;
  3 Lows) — all folded (backward scan, shared counter, 500→200 pages,
  propagated seek errors, scoped comments) incl. the large-trailer
  regression test; second round APPROVED with 2 non-blocking notes
  (folded: trailer-size assertion, doc wording) + 1 accepted
  (O(trailer²/chunk) rescan, harmless at tested scale).

## 7. DeepSeek reviews on this head's lineage

- A0–A5-2: each slice independently APPROVED (plan §§10–21 record
  round counts; A3-2/A4-2/A5-1/A5-2 each needed a fold round).
- Preflight production delta (04f554a bounds fix): NEEDS_CHANGES →
  folded → APPROVED (this receipt §6).
- Preflight test-only change (RecordCodecTests message assertion):
  no production impact; covered by local gates (no delta review
  required per mission §6).

## 8. CI qualification (verified post-push on the exact head)

- Candidate head `6e848f4` pushed to `origin:m2-a-store`; `gh pr checks 5`
  verified green on that SHA:
  - `offline build and tests (Linux x86_64)`: PASS 12m59s
    (run 39496187719, job 118881719026).
  - `release bundle smoke (clean host)`: PASS 6m26s
    (run 39496187719, job 118881718603).
  - GitGuardian Security Checks: pass. CodeRabbit: pass (paused —
    final aggregate round explicitly not invoked; next session owns it).
- SonarQube Cloud quality gate: FAIL (run 39496187640,
  job 118881718311; SonarCloud analysis fail) — reported separately,
  never counted toward green. Known pre-existing coverage-import
  gate defect on `main` + PRs (tracked separately, not an M2-A
  blocker). The PR as a whole is therefore NOT called green while
  this gate fails; the code gates above are green on the exact SHA.

## 9. Unresolved risks / non-blockers

- Sonar red (pre-existing, tracked separately).
- One CI-only flake observed historically (single A3-2 test,
  `SQLITE_NOTADB` on a fresh UUID-isolated DB, unreproducible
  locally; same SHA green on re-run). Process-spawning suites run
  serialized with bounded reaps as hardening.
- Power-loss path unqualified by design (§4).
- Four historical CodeRabbit threads dispositioned against current
  source (see §10); 10 others already resolved. The final aggregate
  CodeRabbit round is explicitly NOT invoked here (next session).

## 10. Historical CodeRabbit thread disposition (4 remaining)

1. RecordCodecTests display names lack catalogue IDs (Minor,
   maintainability) — REJECTED. `.coderabbit.yaml` TESTING §2
   explicitly exempts support/oracle tests ("UNLABELED support
   evidence ... do NOT assign unrelated case IDs"); file header
   declares UNLABELED; ingestion reconciles unlabeled as
   non-evidence. Assigning STORE IDs would manufacture
   certification (tier fraud). Mission directive concurs.
2. Tampered payload must fail at the validating init (Major,
   functional correctness) — FIXED. Test now derives from real
   `RecordCodec.encode` output and mutates only `contextWindow`
   (-5) in both profile copies; strengthened this preflight with
   `message.contains("context_window")` (verified passing); RED
   probe (neutered `checkRange` → silent decode, test fails)
   re-verified at this head. BaseURL/origin-derivation leg covered
   by the line-224 oracle (origin never encoded, re-derived on
   decode).
3. Register the pragma oracle as required evidence (Minor) — FIXED.
   `storePragmasHold` renamed to
   `STORE_01_sqliteDurabilityPragmasHoldOnOwnConnection`,
   display name begins STORE-01, function carries `sqlite`,
   executes in NeedletailPrimitiveTests, registered in
   `requiredEvidence` (XUnitIngestionTests.swift:135-136) and pinned
   by the module-attribution assertion.
4. Limit the unlabeled exemption wording (Minor, plan) — FIXED
   (already in tree): plan §A2 item 5 + `.coderabbit.yaml` TESTING
   §2 (lines 48–50) scope the exemption to non-certifying
   support/oracle tests with reconciliation treatment specified.

## 11. Files changed in the preflight (vs 67a02d0)

- `Sources/NeedletailRuntime/SessionExport.swift`: shared
  materialized-bytes budget, per-page pre-decode charge, 500→200
  pages, backward-scan trailer verification (DeepSeek-APPROVED).
- `Tests/NeedletailPrimitiveTests/SessionExportTests.swift`:
  large-trailer regression test (+1 MiB trailer assertion).
- `Tests/NeedletailPrimitiveTests/RecordCodecTests.swift`:
  `context_window` message assertion (test-only).
- `plans/m2-a-plan.md`: duplicate `## 20` → `## 21` (A5-2).
- `STATUS.md`: M1/M2-0 merged history + M2-A readiness (history
  preserved, nothing rewritten).
- This receipt.
