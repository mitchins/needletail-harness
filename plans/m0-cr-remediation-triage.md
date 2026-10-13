# M0 CodeRabbit remediation — triage (13 Oct 2026)

Scope: PR #1's 25 review threads only, plus directly necessary regression tests.
Review verdict under triage: CHANGES_REQUESTED (reviewed SHA `6f35e49`).
CodeRabbit severity is advisory; each finding verified against source and
executed evidence before disposition. Verdicts: FIX / REJECT_WITH_EVIDENCE /
DEFER_WITH_RATIONALE. Catalogue (`cases/catalog.json`, 200 IDs) and frozen
spec are preserved: no entry added, removed, renumbered or re-stated.

## Method per finding

Source read + (where the claim is behavioral) executed probe. Regression
tests reproduce confirmed defects BEFORE the fix (red logs retained); the
fix turns them green. Where a live repro is infeasible or unsafe, the
triage names the exact code fact verified instead.

## Triage table

| # | Thread (file:line, id) | Claim | Verification | Verdict |
|---|---|---|---|---|
| 1 | `.coderabbit.yaml:53` `4253911290` | `finish_review` / `generate_code_suggestions` unknown top-level keys, silently ignored | File read: keys present at lines 52–53; service now ACTIVE and authoritative on its own schema (it reviewed the PR). Prior F-08 deferral is superseded. | FIX (remove; add supported equivalents per reviewer schema paths; refresh stale NOT-ACTIVATED comments) |
| 2 | `linux-ci.yml:41` `4253911297` | Unverified tarball piped to tar; unquoted `$(uname -m)`; swallowed init errors | File read: confirmed as described. | FIX (temp file + pinned SHA-256 + cleanup + fatal init; keep env-source tolerant) |
| 3 | `linux-ci.yml:112` `4253911307` | Packaging job has no Swift, so release-bundle fails | **Premise false:** CI run `38332572896` packaging job PASSED (`swift build` ran, 3,650,256-byte binary, smoke OK) — the Oct-2026 `ubuntu-24.04` image ships an unpinned Swift. Recommendation valid: pin 6.4 + sqlite + resolve + version assert in the packaging job. | FIX (setup steps) + record premise correction |
| 4 | `README.provenance:16` `4253911378` | Bridge list omits `SHA256SUMS-vendored`, wrong `shim.h` path, wrong `include/replxx.h` | File reads: `Sources/CReplxx/{include/shim.h,include/module.modulemap,SHA256SUMS-vendored,README.provenance}` exist; `include/shim.h` includes `../replxx/replxx.h`. All three claims true. | FIX (apply suggested wording) |
| 5 | `NeedletailVersion.swift:26` `4253911383` | `"0.03.0"` parses to `0.3.0`, violating no-normalization | Source read: `Int("03") == 3`, `description` emits `3`. True. | FIX + regression test (`"0.03.0"` → nil; round-trip `"0.3.0"`) |
| 6 | `LineEditorSession.swift:29` `4253911389` | `replxx_install_window_change_handler` never installed; resizes don't reach replxx | Vendored source: handler exists (`replxx.cxx:714`, declared `replxx.h:590`); NO internal call sites (only forwarding definitions). True. Exposed via existing shim (no bridge change). | FIX (one-line call) + deterministic regression test (post-resize redraw bytes; red pre-fix) |
| 7 | `CaseLedger.swift:31` `4253911396` | `UX-UNDO-2` passes; suffix must be exactly two digits | Source read: suffix check is digits-only, no length. True. Blast radius checked: spec tables + catalogue + expected-index contain ZERO one-digit IDs (200/200 verified), so tightening is safe. | FIX (`suffix.count == 2`) + regression test + update line-76 test to `UX-UNDO-98` (verified uncatalogued) |
| 8 | `CaseLedger.swift:251` `4253911401` | BDD-03 `testStatus: pass` without `reviewStatus` satisfies, though layers require `reviewProcess` | Source read: `satisfied` ignores layers; classification test line 48 encodes the defect (`satisfied == ["BDD-03"]`). True. `satisfied` used only at `reconcile:318`. | FIX (`satisfied(for:)` requires review iff `.reviewProcess` ∈ layers; present fields must pass) + regression tests (missing-review → unsatisfied RED; with-review → satisfied) + update line-48 expectation |
| 9 | `CaseLedger.swift:290` `4253911410` | `kind == "placeholder"` + pass certifies; needs allow-list | Source read: only `"example"` rejected. True. Only kinds in tree: `"evidence"` (default), `"example"` (one test). | FIX (allow-list `{"evidence"}`; message names the offending kind) + regression test (placeholder → invalid RED) |
| 10 | `CaseLedger.swift:318` `4253911416` | One passing variant of ten satisfies; required IDs never registered | Source read: `allSatisfy` over REPORTED only. True. Catalogue schema has no variant registry (frozen; not adding fields to 200 entries). | FIX (`reconcile(..., requiredVariants: [String: Set<String>] = [:])`; required ⊆ passing required for satisfied; default preserves behavior) + regression tests (1-of-10 → unsatisfied RED; 10-of-10 → satisfied) |
| 11 | `SSEFramingTests.swift:63` `4253911421` | `#expect(count == 2)` then index traps on short decode | Source read: non-fatal expect + unconditional `events[0]`/`[1]`. True by Swift semantics. Reachability: truncated payload decodes to 1 event (regression test proves). | FIX (`try #require`) + reachability regression test; scratch crash demo as RED evidence (not committed) |
| 12 | `TransportCancellationTests.swift:112` `4253911424` | Catch conflates any error with cancellation; server-close can masquerade | Source read: catch returns same string for all errors. True. AHC 1.36 + Swift runtime: task-cancel surfaces as bare `CancellationError()` at the suspension point (EXECUTED: `failed: CancellationError()` observed 13 Oct); `HTTPClientError.cancelled` accepted too via public `Equatable` (`Code` is private). Classifier accepts both. | FIX (`classify`: `.cancelled` → `"cancelled"`, else `"failed: …"`) + differ-test (refused vs cancelled must differ; RED pre-fix) + classify unit tests |
| 13 | `TransportCancellationTests.swift:145` `4253911428` | `cancelAll` can't unblock group; test can exceed deadline | Swift semantics: groups await cancelled children; child awaits `requestTask.value` (uncancellable wait). True. Current bound is accidental (server's 10 s semaphore ≈ 20 s worst case). | FIX (result-latch + deadline poll; returns at deadline, `server.stop()` bounds cleanup) + mechanism regression test (cancellation-ignoring stall returns at ~deadline, RED-by-design pre-fix N/A — mechanism is new; integration differ-test is the pre-fix repro; see row note) |
| 14 | `QualificationProbes.swift:27` `4253911434` | Display names lack catalogue case IDs (×5) | File read: all five begin "qualification". Applicability split: skips → BDD-04 (cited in code comments); parameterized → BDD-02 (variant discipline); intentional-failure + passing control → NO applicable catalogue ID (runner-demonstration meta-fixtures; forcing IDs fabricates traceability). | FIX 3 (BDD-04 ×2, BDD-02 ×1; grepped substring preserved) + REJECT 2 with rationale |
| 15 | `TerminalFeasibilityTests.swift:60` `4253911436` | `expect` drops post-marker bytes; no prompt wait after cancel | Source read: per-call local buffer (bytes after marker lost — incontrovertible); no `expect("> ")` after cancel (lines 127–132). True. Live timing repro infeasible deterministically; 5/5 passes were luck-prone. | FIX (session transcript + cursor; post-cancel `expect("> ")`) + `TranscriptCursor` unit tests (chunk splits, trailing bytes, ordering) + 10× stability runs + oracle still red |
| 16 | `TerminalFeasibilityTests.swift:99` `4253911440` | Post-exit echo check can't validate; hung-up master | **Premise false (executed):** `/tmp/opencode/eio-probe` (child exits, slave closed everywhere): write rc=0, 12 echo bytes back — master NOT hung up; last termios persists. Negative control `/tmp/opencode/rawleak` (raw leaked): read −1 timeout. The check discriminates restoration functionally. | REJECT_WITH_EVIDENCE (two experiment logs); no code change |
| 17 | `TerminalFeasibilityTests.swift:111` `4253911446` | Display name lacks catalogue case ID | PTY-05 scenario text is EXACTLY this scenario (`TIOCSWINSZ` 40→120→80 in multi-line composer). Catalogue status untouched (stays M4 DEFERRED; development tier explicit in name). | FIX (prefix `PTY-05`; keep `feasibility M0-C` remainder + header caveat) |
| 18 | `TerminalFeasibilityTests.swift:145` `4253911450` | `stream-done` can precede drained chunks; wait for `stream-23` | Vendored source: `ReplxxImpl::print` QUEUES from non-input threads (`_messages` FIFO, drained by input loop); probe's `stream-done` is a raw write bypassing the queue. True. Live inversion timing-dependent; FIFO drain order makes `stream-23` the deterministic proof. | FIX (one-line marker change) + 10× stability runs |
| 19 | `TerminalFeasibilityTests.swift:175` `4253911459` | `(status ?? 1) >> 8 == 0` passes signal death (e.g. 11) | `nt_pty_wait` returns RAW waitpid status (`nt_pty.c:146`); `11 >> 8 == 0` is arithmetic fact. True. | FIX (`isCleanExitStatus` helper: normal-exit + code 0) + helper unit tests (exit 0 / SIGSEGV / SIGKILL / exit 1) + arithmetic RED demo |
| 20 | `dev:9` `4253911317` | Relative `root_dir` breaks log paths after `cd` (`sh repo/dev` from parent) | Source read: line 8 relative + line 9 `cd`; reassignments at 174/242/288. True. | FIX (absolutize once; drop 3 reassignments) + CI guard step (relative-path `test case BDD-01` must pass) + local pre/post evidence |
| 21 | `dev:275` `4253911349` | `VENDOR OK (clone)` prints unconditionally (shared `status`) | Source read: line 275 unconditional; `status` shared with offline check. True. | FIX (separate `clone_ok` flag, both failure branches) + sandbox repro (corrupted byte → contradictory log pre-fix; clean post-fix) as evidence log |
| 22 | `dev:331` `4253911356` | Duplicate `chmod +x` | Trivially true (lines 330–331). Nitpick. | FIX (delete one line) |
| 23 | `m0-milestone-report.md:33` `4253911363` | Row reports 20, STATUS says 21 | Both true for their time: cited log `test-quick-swift64-grdb.log` shows 5+15=20; the 16th behaviour test (BDD-04 rule) landed later (`a91f689`). Naive 20→21 would contradict the cited log. | FIX (annotate temporal count: 20 then, 21 after; cite both logs) |
| 24 | `m0-milestone-report.md:54` `4253911369` | 16 counted as cases, violating BDD-02 | True: 4 semantic cases (BDD-01..04), 16 executions (8+5+3). | FIX (`4` + executions reported separately) |
| 25 | `m0-milestone-report.md:85` `4253911371` | D-2 named as next action though resolved | True: line 85 names D-2 ruling; lines 81–82 record resolution. | FIX (state only the pending action; keep scope limits) |

## Row 13 note (pre-fix repro boundary)
The deadline mechanism is new code; no pre-fix unit target exists. The
pre-fix defect is verified by (a) Swift task-group semantics (groups await
cancelled children; `await task.value` is uncancellable — stdlib-documented,
reviewer-cited), and (b) the current worst case being accidental (server
10 s semaphore). The committed mechanism test (cancellation-ignoring stall
returns at ~deadline) pins the fixed behavior; the integration differ-test
(row 12) is the executed pre-fix RED.

## Blast-radius checks (done pre-implementation)

- `CaseID` tightening: 200/200 spec-table IDs and 200/200 catalogue IDs have
  two-digit suffixes; `UX-UNDO-98` absent from catalogue (used for the
  uncatalogued test).
- `CaseResult.satisfied` property: sole production use is `reconcile:318`.
- `kind` values in tree: only `"evidence"` (default) and `"example"`.
- `replxx_install_window_change_handler`: public C API (`replxx.h:590`),
  no shim change needed.
- AHC 1.36: task-cancel surfaces as `HTTPClientError.cancelled`; `Code` is
  private → compare whole values via public `Equatable`.
- Qualification gate (`dev:122`) greps display substring
  `qualification intentional failure must be reported as a failure` — renames
  preserve it (the two REJECTed names are unchanged anyway).
- `--filter` matching uses function/type/target names — display renames are
  filter-safe. Test counts unchanged (no test added/removed in the
  qualification target).

## PTY-05 redraw resolution (13 Oct, contract-based rework)

The provisional redraw test (immediate post-prompt repaint bytes) failed
for an upstream reason, found by mechanism analysis, not guessing: replxx
throttles `refresh_line` within 1 ms of the previous render
(`RAPID_REFRESH_US`, `replxx_impl.cxx`), and the probe installs no hint
callback (`_hintDelay == 0`), so a throttled repaint never re-fires.
Driver-paced actions always land inside the window; only wall-clock idles
escape it. Probing deeper showed the stdin backlog can also starve the
event pipe, and per-keystroke echoes are throttle-unreliable.

Final design (deterministic, no sleeps, no throttle exposure):
- 60-char draft typed fire-and-forget; resize 100→40; Ctrl+C, which PTY
  FIFO order places after every typed byte.
- The abort refresh is the observation point: abort resets the refresh
  clock (unthrottled by construction), renders the FULL retained line at
  the current columns, and writes `^C` synchronously right after.
- Slice = last `"> "` before `^C` .. `^C` = exactly the abort refresh
  (partial typing echoes cannot pollute it). Full-62-col render ending
  `[23G` ⟺ two-row wrap at 40; ending `[63G` ⟺ single row.
- Pre-fix RED (0.017 s, structural — no timeout): `[23G` absent,
  `[63G` present. Post-fix GREEN 5/5 (~0.02 s each).

Supporting evidence preserved in `.needletail-dev/logs/`: strace
`SI_KERNEL` delivery, SigCgt handler bit, foreground-pgrp match,
settled/kill repaint bytes, raw-leak negative control, EIO
non-hangup probes. The `unblockSIGWINCH` probe addition proved
unnecessary (SigBlk is clear on this runner) and is retained as harmless
defense with its comment saying so — correction: see probe source.

Note on ANSI coupling: `[23G`/`[63G` are asserted as cursor-geometry
facts (end column of a full-line render ⟺ wrapped-or-not, uniqueness
shown above), not as incidental repaint bytes; the test never requires a
particular repaint shape or prompt string.
