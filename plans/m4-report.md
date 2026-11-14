# M4 Milestone Report — Interactive Terminal Integration

Date: 2026-11-09 (residual closure same day). Branch `m4-a`, local only. No push/PR/merge (STOP).

## 1. What M4 set out to prove

M4 hypothesis: the qualified M4-B pure engine can drive a real
interactive terminal (`needletail chat`) with composed authority
calls, physical PTY acceptance, and lifecycle closeout — without
reopening Core/Runtime, without live model traffic, without new
agent architecture.

## 2. M4-A / M4-B / M4-C (carried in, retained)

- M4-A QUALIFIED: contract slice ordering + exit rule
  (`plans/m4-a-receipt.md`, `plans/m4-a-boundary.md`).
- M4-B QUALIFIED (`3e9806f`, final battery `80cab63`): 36 pure
  closeout + B6 FULL (Q01/Q03 partial → M4-D); Linux offline green;
  mac keepers valid. Receipt `plans/m4-b-receipt.md`.
- M4-C QUALIFIED (code `6e73568`, receipt `c18fa54`): terminal
  adapter (DisplaySanitizer, Markdown/ANSI/replxx, TerminalOutputOwner,
  ComposerBridge, ChatLoop, DeltaTapTransport), `chat` command,
  scalar-level macOS findings, depth-guarded Markdown, dependency
  findings (swift-markdown 0.9.0 + swift-cmark), Linux offline green,
  macOS debug green. Carried limitation: terminal was an adapter
  with incomplete wiring (the M4-D work list).

## 3. M4-D method

Plan `plans/m4-d-plan.md` (DeepSeek-reviewed, READY after 3 rounds).
Real CLI composition root shared by product and tests (loopback
provider only); physical release-binary PTY-01…08; deterministic
gates/barriers (no sleeps-as-oracles); nonzero-count runners;
transcript preservation on failure; Core/Runtime frozen
(byte-identical to `3e9806f`, verified per commit and at closeout);
two adversarial DeepSeek code-review rounds, all blockers closed
with targeted regression tests.

## 4. Results (Linux x86_64, exact-HEAD evidence) (M4-D CLOSEOUT STATE — SUPERSEDED by residual §§7–9: PTY 13, terminal 146, presentation 100 at §12 remediation; retained for history)

- `run-m4d-pty.sh`: **11/11 green** (PTY-01…08 + EOF + D2.7
  hygiene oracle + TERM-04 refusal), release product, all cases
  started (nonzero gate).
- `NeedletailTerminalTests`: **126/17 green** (21 composition incl.
  attach/undo/inspect/diff/queue/budget/mention/Cf/in-gated-stream
  + stale-accept locks, PTY, loop/bridge/history/VT/sanitizer suites).
- `NeedletailPresentationTests`: **100/14 green**.
- Manual D6 smoke (release + synthetic 127.0.0.1 SSE): all legs
  PASS; zero non-loopback traffic (server logs); 2 minor
  non-blocking notes.
- Full `./dev test offline`: **OFFLINE OK** (all layers + case
  filters, zero failures; see receipt §6).
- Reviews: 6-blocker D7 round closed (Tab race, inspect/denied
  retire, hygiene model, bearer gaps, tautological bound, timeout
  transcripts) + delta re-review closed (1 remainder fixed) +
  residual delta review closed (focused: fresh-mint soundness PASS,
  SIGKILL arming holds PASS, 1 test flake + receipt mismatch fixed).
- Review-found product defects fixed: stale Tab-accept clobber
  path, mid-stream inspect commit-drop, `denied`-as-terminal,
  submit-time liveness retire, empty-history (replxx never
  auto-commits; input loop now commits), missing bearer oracles.

## 5. Gaps at M4-D closeout (SUPERSEDED by residual §§7–9 below; retained for history)

- macOS acceptance: none (host unreachable; single check, no
  re-poll). Real-SSH path outstanding; Linux real-tmux stands as
  the labelled fallback.
- D4 named suites unbuilt (`ChatStressTests`, `ChatWidthTests`,
  `ChatRenderParityTests`, `GoldenRegenerationProbe`;
  attach/undo/inspect behaviors covered in composition, not as
  named files). D4.2/D4.4 rows open.
- Provider-integration suite intermittently red under parallel
  load at HEAD (35/36; NET-03 `ECONNREFUSED`) — reproduced on the
  pristine baseline: pre-existing flake, reported failed, not
  waived.
- Explicit deferrals: `/compact` trigger (non-case); TERM-04
  loopback-run superseded by the qualified non-TTY refusal (pinned
  instead); resubmit-identical-text silent no-op (qualified Core
  idempotency).

## 6. Recommendation at M4-D closeout (SUPERSEDED by §9 below; retained for history)

Merge/close M4-D Linux evidence as the qualified interactive
baseline; carry macOS acceptance, D4 stress rows, and the BDD-07
probe as the explicit M5 prerequisites (no M5 work started).
Full detail: `plans/m4-d-receipt.md`.

## 7. Residual closure (same branch, local commits, no push)

Implementation commits: `bd87724` (M4-D adapter — the M4-D
implementation SHA; `c18fa54` is the M4-C receipt and must never be
cited for M4-D code), `ba723b0` (identical-resubmit fix),
`63c637d` (D4 suites + PTY legs), `06a9bae` (review fixes),
plus the receipt/report commit (see receipt §11.1). Core/Runtime
still byte-identical to `3e9806f`.

- Identical-prompt resubmission FIXED (adapter `CommandIDStore`
  now mints per submission event; Core contract preserved):
  composition repro RED → green (2 admissions, same-ID retry
  replays), unit + loop tests rewritten, PTY
  `identicalResubmitAdmitsTwice` green.
- D4 built: `ChatStressTests` (4: control-storm exact, quota
  accounting, 64-submit storm, seeded fuzz),
  `ChatWidthTests` (6: grapheme rule, CJK/combining/flags/mixed/TAB;
  wcwidth-2 out of scope recorded),
  `ChatLifecycleTests` (stale completions),
  `ChatRenderParityTests` (3) + PTY `parityFixedScenario`;
  runner 13/13. Counterfactuals CF-A/B/C RED→restore-verified;
  BDD-07 P1/P2 executed (frame self-certifies, manifest catches).
  Full detail + digests + verbatim RED cores: receipt §11.
- macOS: single check — host now reachable-but-inaccessible
  (host-key verification fails; auth denied). No changes, no
  retries. ENVIRONMENT-BLOCKED; Linux primary per revised policy.

## 8. Gaps (residual-corrected)

- macOS release-acceptance matrix: outstanding
  (environment-blocked; the single remaining M4 gate — run once
  against the frozen candidate when accessible).
- Attach/undo/inspect as named files: behaviors covered in
  composition (split not required).
- Standing limitations (unchanged): NET-03-class parallel flake
  (visible, pristine-reproducible); vendor-check secondary
  (single documented patch); `/compact` non-case; stale-Tab
  re-tab; wcwidth-2 out of scope.

## 9. Recommendation: M4 PARTIAL — STOP

Linux acceptance is complete (resubmit fixed + proven; D4 suites
green: 143 terminal / 100 presentation / 13 PTY / offline OFFLINE
OK; CF-A/B/C + BDD-07 P1/P2 with verified restores; delta review
closed; Core/Runtime byte-identical to `3e9806f`). PARTIAL solely
because the macOS release-acceptance matrix never executed
(reachable-but-inaccessible host; single remaining gate — run once
against the frozen candidate when accessible). The branch is ready
for push/PR (authorization required, not performed) and aggregate
CodeRabbit review; merge/close waits on the macOS gate. No M5, no
live traffic, no push/PR/merge.

Full detail: `plans/m4-d-receipt.md` (§11 residual closure).
