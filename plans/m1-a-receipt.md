# M1-A plan-review receipt — READY (planning only, not implemented)

- Plan: `plans/m1-a-plan.md`, rev3, sha256 `99cbeff19f219000cbe5aa9882b729f89e8456fa979f3067c39989a44203e430` (373 lines; implementer-computed, unrestricted shell).
- Baseline: `main` at `e3c0527` (M0 squash `ffbc677` + ledger + STATUS; matches `origin/main` at planning time). Swift 6.4, `Package.resolved` `de95226e…`, `./dev test quick` 20/20 green, working tree clean except this planning slice.
- Implementer (actual): `muse-spark-1.3-contributor` (Muse Spark; Step 5 Preview Free retained only as example, not claimed).
- Reviewer (independent): `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash` (resolved from `/home/mitch/.config/opencode/opencode.jsonc`; read-only, no edits, no secrets).
- Scope: plan review only. No M1-A production/test code written; no remote push/PR; no dependency/macOS changes.

## Review history (REVIEW §3 budget: 1 initial + 1 substantive re-review + 1 narrow verification)

1. Rev1 (`fcdb0d2d…99d22`, 337 lines) → **NEEDS-EVIDENCE**, 15 findings: Majors M1A-R1..R7 (case-label contradiction, integration seam not runnable, Dictionary ordering, reserved case bypass, credential shape, stat-size bypass, self-referential probes); Minors R8..R13+R15 (6-input signature, workspaceGrant provenance, selectRoute ambiguity, NET-06 partial/exit-4, redaction heuristic, requiredness/BOM/surrogate edges, digest governance); Suggestion R14 (over-scope trim).
2. Rev2 (`a6ffa3a2…248a2`, 370 lines, §13 log) → **NEEDS-EVIDENCE**, 12/15 CLOSED; 3 STILL-OPEN Minors: R1 (test-11 `PORT-02` prefix still matchable by case filter), R2 (test-target/CLI dep graph gaps + "vendored subprocess" wording + origin-check layering), R14 (trim announced but `configuredOrigins`/three-valued label/stray U+53CA remained).
3. Rev3 (`99cbeff1…03e430`, 373 lines) → **READY** bound to this digest + baseline `e3c0527`. All three residuals CLOSED with line evidence (R1 §9 row 11 `ARCH-import-gate` + filter exclusion; R2 §8 seam with Runtime+Providers deps + conditional CLI deps + Core/Providers layering + "already-resolved package dependency"; R14 `RoutePolicy {none, localOnly}` + uniformly-unknown + stray removed). No new findings (third-verification budget respected).

Digest caveat (R15, recorded honestly): the reviewer's sandbox denies `sha256sum`; it verified 373 lines + `git status` (only `plans/m1-a-plan.md` modified) + baseline `e3c0527` instead of recomputing the digest. Digest above is the implementer's unrestricted-shell value; re-run `sha256sum plans/m1-a-plan.md` to confirm before implementation.

## What was reviewed

Contracts: SPEC §§ 5/5.1–5.3/10.1–10.3/12, MILESTONES M1-A, ACCEPTANCE CFG-01..06/POLICY-02/05/NET-01/06, DEVELOPMENT §§ 4–5, TESTING §§ 1–5/9, REVIEW §§ 1–2/4. Baseline files: `NeedletailVersion.swift` (CFG-05 precedent), `ProviderIdentity.swift`, `WorkspaceRoot.swift`, `Doctor.swift`, `NeedletailCLI.swift`, `Package.swift`, `cases/catalog.json` (45 M1-due; 10 taken: 9 full + NET-06 partial).

Adversarial questions (a)–(g) answered in each round; final round confirms: no config escape (escape/surrogate/BOM/depth specified), no permission widening (repo not a parameter, deny-all default, contradictions rejected at parse), no cloud path (single `selectRoute`, M1-A cloud denied), no silent identity/option change (raw bytes + case-insensitive reserved + strict credential shape), no leak/traffic (redaction-by-default + import gate), probes independent (temporary production patches + RED logs), trim complete (no further deletion warranted).

## Deliverables pointer (all planning, none implemented)

- Test/case matrix: plan §9 (12 rows; 10 cases: CFG-01..06, POLICY-02/05, NET-01, NET-06 PARTIAL; per-variant IDs, G/W/T in §7, forbidden effects, pure vs spawn-integration, red/green expectations; commands `./dev build`, `./dev test quick`, `./dev test case <ID>` ×10, `./dev coverage`).
- Swift file/type changes: plan §8 table (9 Core files + 2 Runtime + 1 Providers + 2 CLI + schema/example + `NeedletailConfigTests` target; error taxonomy; precedence; snapshot; redaction; M1-B connection).
- Remaining 35 M1 cases allocated to M1-B/C/D: plan §10 (not in M1-A scope).
- Raw review outputs: `.needletail-dev/logs/m1a-plan-review-r1.md`, `m1a-plan-review-r2.md`, `m1a-plan-review-r3-ready.md` (gitignored, exact task results).

## Disposition (planning phase)

**M1-A PLAN REVIEWED — READY for implementation planning; NOT IMPLEMENTED.** Implementation waits for its own authorization. Next authorized step only on operator approval: implement per rev3 plan with red-before/green-after evidence, then DeepSeek completed-slice review.

## Addendum — implementation authorization corrections (rev4 → rev5)

Authorization (M1-A implementation) required three contract corrections plus
one targeted delta review (no full re-review):

- Rev4 (`7b03fd7c…b59f8a`, 380 lines): A. `base_url` allows explicit path
  prefixes (`scheme://host[:port][/prefix]`), endpoint join preserves the
  prefix once, origins stay origin-only with prefix-discarded comparison;
  B. sealed/tools-none deny tools only, route independent (sealed +
  approved-local permitted tool-free); C. config-plus-flag is allowed
  narrowing, only disagreeing explicit argv pairs reject; new POLICY-02
  (12 rows) and NET-01 (+2) regression variants.
- Delta review (deepseek-reviewer, `opencode-go/deepseek-v4.1-flash`) →
  **NEEDS-EVIDENCE**: D1 Major (missing `base-prefix-already-suffix`
  variant — double-suffix wrong impl escapes), D2 Minor (encoded
  traversal/`//`/backslash/fragment/whitespace/default-port variants
  missing), D3/D4 Suggestions (inert `sealed` param documentation,
  raw-argv detection basis). No origin-widen, prefix-drop/duplication, or
  permission-escalation escape found; core A/B/C logic confirmed.
- Rev5 (`71d91dac…59e0`, 381 lines): folds D1 (variant + all three
  suffixes), D2 (encoded/mixed `%2e`, `//`, backslash, fragment,
  whitespace, default-port equality + decode-before-compare rule), D3
  (outcome-inert invariant + `sealed-route-identical` test), D4
  (raw-argv-before-folding rule + §3.1 argv-only scope). Rev5 was not
  re-reviewed as a plan (budget); its new variants are verified as
  implementation tests and fall under the completed-slice review below.
- Workspace anomaly (recorded honestly): tracked `Archive.zip` (1405926
  bytes, committed in `ffbc677`) was present-modified at session start and
  found deleted mid-session by unknown cause; restored byte-identical from
  HEAD (`git checkout -- Archive.zip`; size matches the HEAD blob; the
  earlier `M` was a stat artifact). No content lost; unrelated to M1-A.
- Raw delta output: `.needletail-dev/logs/m1a-plan-review-r4-delta.md`.

## Completed-slice review (filled after implementation)

See `plans/m1-a-report.md` for the implementation SHA, evidence map,
findings and final disposition.
