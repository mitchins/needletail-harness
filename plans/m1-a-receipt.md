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

## Completed-slice review

- Subject: base `e3c0527` → head `0ec46ed` (implementation `f7f2628` +
  report amend). Working tree clean at review time; `cases/` and
  `Package.resolved` untouched; no PROBE markers remain.
- Reviewer: `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash`
  (static review — no builds/tests run by the reviewer; evidence from
  retained logs). Raw: `.needletail-dev/logs/m1a-slice-review.md`.
- Confirmed clean: no permission widening, no secret leakage, opaque
  identities (P4 genuine), sealed inference + value snapshots (D3 test
  real), 7 wrong-impl probes genuine production patches, scope held
  (9 full + NET-06 partial; BDD-04 intact).
- Disposition: **NEEDS-EVIDENCE** — M1A-S1 Major (FIFO `--config` hangs:
  `readBoundedConfigFile` checks only `isDirectory`; plan R6 requires
  `S_ISREG`) + S2–S7 Minor + S8–S11 Suggestions. Deviations D-a..D-i
  all ACCEPTED (D-c with required plan correction).
- Minimal fixes demanded: S1 non-regular rejection (+O_NONBLOCK,
  FIFO red/green log); S4 correct 16-test evidence citation; S2 tool-set
  epoch gap or D-deviation; S3 real `\uD83D\uDE00` oracle; S5 normalized
  identity; S6 size-guard off-by-one; S7 real CLI caller or downgrade;
  S8–S11 hardening/notes; D-c plan amendment.

## Final review (filled after S-fixes)

- Plan rev6 (`eb322bee…73041d`, 397 lines): §15 documents S1–S11 fixes
  and supersedes the §5 empty-models sentence (D-c).
- Implementation fixes: Runtime `readBoundedFile` (O_NONBLOCK +
  S_ISREG) wired into `config validate`/`doctor --probe` + O_NONBLOCK
  credential open; snapshot-level `requiresNewEpoch` overload;
  `\uD83D\uDE00` + lone-surrogate oracles; normalized endpoint identity;
  `<= maxFileBytes`; `config validate --sealed/--tools` production
  caller with `invocation:` echo; decoded-backslash rejection;
  snippet-free refusal; locality cross-check.
- Evidence deltas: pure 60→63, integration 16→18; `m1a-fix-*.log`
  series; FIFO/conflict probes run live (exit 2, no hang).
- Slice review (head `0ec46ed`): NEEDS-EVIDENCE — S1 Major (FIFO hang)
  + S2–S7 Minor + S8–S11 Suggestions; D-a..D-i ACCEPTED (D-c with plan
  correction). Raw: `.needletail-dev/logs/m1a-slice-review.md`.
- S-fix commit `130176e`: all S1–S11 fixes; final narrow verification
  found S8 test-only gap (production rejection present, no `%5C` input).
- S8 commit `a76022c` (1 file, +2 lines): `%5Cx` variants added;
  `m1a-final-case-CFG-02.log` (18+1 green) + `m1a-final-quick.log`
  (14+63+20 green) retained.
- Final review: **READY TO CLOSE**, bound to head `a76022c` on baseline
  `e3c0527` (reviewer `deepseek-reviewer` /
  `opencode-go/deepseek-v4.1-flash`; tree clean; 10-case coverage and S1
  closure confirmed). No push/PR/merge — M1-epic CodeRabbit is the later
  aggregate gate.

## Final hardening H1/H2 (external-inspection defects, slice still local)

- H1 (stale-origin bypass, reproduced): post-load mutation of `baseURL`
  against a retained allowed `origin` returned `allowed`. RED:
  `m1a-h1-red.log` (`NET-01 mutated profile state…` fails, route
  allowed for `https://evil.example:443/admin`). GREEN: immutable
  `let` state throughout; single validating `ModelProfile` initializer
  (origin/prefix derived, inconsistency unconstructible);
  `selectRoute` re-derives from the effective `baseURL` (+ new
  `malformedDestination` denial; stored `origin` diagnostics-only);
  `authorizeRequestDestination` re-verifies endpoint bytes for M1-C
  call-before-dispatch. Evidence: `m1a-h-green-pure.log` (67),
  `m1a-h-green-int-2.log` (20), full `m1a-h-ev-*.log` series + offline
  aggregate green; bundle 6175248 bytes dynamic, packaging smoke OK.
- H2 (ESC in diagnostics, reproduced): unknown `default_model` with
  `\u001b[2J` rendered raw ESC. RED: `m1a-h2-red-pure.log` (raw
  controls in `description`/redacted strings). GREEN: pure
  `terminalSafe` at every display boundary; stored bytes untouched;
  exact paths/kinds preserved; CLI byte assertions (0 ESC/BEL/secret
  bytes: `m1a-h-noleak.log` shows the brief's exact input rendering
  `ghost-\u{1b}[2J`). New tests: `TerminalSafetyTests`
  (CFG-02 ×2, CFG-05 ×1) + 2 spawn tests; no catalogue renumbering.
- Plan rev7 (`44995364…5bf9b33`, 422 lines): §16 documents H1/H2.
- Workspace note (recurring, environmental): tracked `Archive.zip`
  again found deleted mid-session by unknown cause; restored
  byte-identical from HEAD (1405926 bytes, matches blob). Unrelated.
- Targeted H1/H2 review (head `88e4acd`): NEEDS-EVIDENCE —
  H2-1 (probe unknown-alias raw echo), H2-2 (C1 host accepted),
  H1-1 (dispatch-gate default-port disagreement), H1-2 (unreachable
  denial claim), S-2 (raw credential-error fields); +3 speculations
  (S-1 bidi follow-up for M4, S-3 ambiguity note). Raw:
  `.needletail-dev/logs/m1a-h-review.md` (retained below as final).
- Residual fixes (commit `778ca89`, 7 files): escaped probe
  diagnostic + hostile-alias spawn test; control-or-whitespace
  rejection at all three URL sites (S8 retained; whitespace regress
  caught by the traversal oracle); dispatch gate via parsed origin +
  fresh-join equality + parity test; defense-in-depth doc;
  sanitized credential errors. Evidence: quick 14+69+20, integration
  21, 10/10 cases, offline aggregate — all green.
- S-1 bidi/zero-width visual spoofing: recorded follow-up for M4
  terminal-safety work (outside the M1-A C0/C1 table); S-3 `\u{hex}`
  literal ambiguity: noted, no change.
- Final review: **READY TO CLOSE**, bound to head `778ca89` on
  baseline `e3c0527` (reviewer `deepseek-reviewer` /
  `opencode-go/deepseek-v4.1-flash`; 7-file diff confirmed; tree
  clean; `origin/main` unmoved — 7 local-only commits, no push).
  M1-A closes locally; M1-B planning authorized.
- Restored-file check: `git status` clean except intended files; no
  push performed at any point.
