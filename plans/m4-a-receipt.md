# M4-A Receipt — native Darwin x86_64 qualification

Date: 5–7 November 2026. Branch `m4-a` (local only — no push/PR/merge),
based at `2d11209` (M3 squash-merge of PR #9; tree-identical to qualified
HEAD `bc29050`). Supersedes the 2026-11-04 environment-only edition:
the Intel macOS host is now provisioned and the slice is executed.
Close-out edition: includes the DeepSeek review resolutions (§11), the
G13 terminal-revive product fix (§4, §6), and the G14 Darwin-debug
stack limitation with the final gate set (§5, §6, §11).

Acceptance per the maintainer amendment: native Intel macOS qualification
satisfies the M4 portability gate; Apple Silicon execution is NOT a
prerequisite for M4-B/C/D. Architecture-specific exclusions are recorded;
no arm64 runtime or macOS 14 compatibility claim is made.

## 1. M3 merge record (unchanged from the 2026-11-04 edition)

- PR #9 verified (6/6 checks, CodeRabbit approval, 30/30 threads, CLEAN),
  squash-merged **without** `--admin`, nothing dismissed.
- Merge SHA `2d1120925b07da19ae8658d9ec680027319dc92c`; tree-identical to
  qualified HEAD `bc29050` (both trees `cddf7eebe935f5b65e1bc7fcdea765493f497b61`).

## 2. Build host inventory (actual, verified over SSH)

- SSH: key-auth `build@192.168.2.106` (alias `macbuild` initially unresolved
  via DNS; direct address used). Verified noninteractive before any work.
- macOS 26.7.1 (Build 25G241), Darwin 25.6.0, **Intel** x86_64
  (Core i7-8700), git 2.50.1.
- Xcode 26.6 (17F113), Apple Swift **6.3.3** (swiftlang-6.3.3.1.3),
  target x86_64-apple-macosx26.0, SDK MacOSX26.5.sdk (15.x SDKs also
  installed).
- Toolchain note: host Swift is 6.3.3, NEWER than the 6.4 Linux CI
  toolchain in some diagnostics but OLDER in `await`-in-`defer` rules —
  Xcode 16.3-era (Swift 6.1) rejected `await` in `defer`; this host
  accepts it. The shim set below keeps both toolchains building.
- Deployment floor: package declares `.macOS(.v14)`. macOS 14 compatibility
  is NOT claimed (no 14.x host available); the floor stays
  declared-but-unproven.
- Dependency resolution: `Package.resolved` resolved and all targets built
  from source on Darwin x86_64 (GRDB, AHC/NIO, swift-subprocess,
  swift-system, swift-crypto, argument-parser, openapi-runtime). OS-floor
  evidence per dependency is NOT recorded (needs per-vendor minimum
  checks) — follow-up F3.

## 3. Native build + test results (unchanged tree @ 2d11209, then minimal shims)

Unchanged-tree build on macOS: Core, Presentation, Providers built clean;
**Runtime failed**: `fork()` is unavailable in the Darwin Swift overlay
(5 duplicated compile errors, `NativeToolExecutor.swift`). Full `swift
build` then surfaced: PTYShim `<pty.h>` missing (Linux-only include) and
`NeedletailTypingProbe` unconditional `import Glibc`. The scheduled
suites then exposed two more compile classes: `await`-in-`defer`
(reported by the Xcode 16.3-era checker semantics used below as "defer"
shims) and Darwin-vs-Glibc POSIX spelling differences.

Final state — everything builds. Native macOS results below are the
CLOSE-OUT state (final gate set, §5): debug lanes green where they run;
G14 suites/tests excluded on Darwin-debug only (Linux-debug green,
Darwin `-O` green — evidence §11).

| Suite (macOS, native x86_64, debug) | Result |
|---|---|
| ImportGate + PresentationGate + M3CProjectionLimitTests | 5 + 3 pass |
| C2ExecDurableTests | 21/21 pass (20 per-test gates: 14 exec-spawn + 3 actor-spawn + 3 digest-actor-spawn found by native re-run, G-exec) |
| TOOL10DiffTests | 8/8 pass (13 per-test gates: 10 spawn + 3 binary-diff legs, G-cwd) |
| C3ExecQualificationTests | 0 run (18/18 gated: 5 G1 + 13 G14 child-run) |
| B5CEndToEndTests | 3/24 run, pass (19 G14 binary-run legs + TOOL_10 G-cwd + PORT_03 PORT-03 section gates) |
| ProductionCLIWiringTests | 2/9 run, pass (7 run-driving tests gated G14) |
| B0ActorIntegrationTests / B1ContainmentTests / TOOL09OrderedBatchTests / TimerLoopbackTests / ActorLoopbackTests / BoundaryVerificationTests / D3IntegrationTests / B0SpineTests | 0 run each (G14 suite gates) |
| B2ClosureTests / B2ReadSearchTests | 12/12 + 15/15 pass |
| B3EditWriteTests | 30/30 pass |
| C1QualificationTests | 8/23 run, pass (15 pre-existing Linux-only lifecycle gates: /proc offsets, group probe, crash staging) |
| DX / Wire / NetLoopbackTests | 3 + 11 + 8 pass |
| CrossRunGateTests | 20/20 pass |
| M3AReplayLiveTests2 | 1/1 pass (rest live-gated, skipped) |

Darwin `-O` (optimized) evidence — same PRODUCT code as the committed
tree (test-only `#if canImport(Glibc)` G14 gates lifted for these runs,
since the gates exclude all configs on Darwin): B0 12/12, B1 39/39,
TOOL09 13/13, TimerLoopback 2/2, ActorLoopback 2/2, BoundaryVerification
6/6, B5C 22/22, ProductionCLI 9/9 — every G14 exclusion with -O evidence
exclusion passes optimized (behavior qualified; debug frames are the
limitation, §11).

Linux regression gate after every change: full `./dev test offline` green
(all scheduled offline layers), `./dev vendor-check` (offline + clone) OK,
packaging CLEAN-HOST SMOKE OK, qualification OK; affected suites re-run
locally after each shim and after the G13 product fix (C2 41/41, B1 45/45,
B2 27/27 combined, B3 31/31, CrashMatrix 11/11, TOOL09 13/13, B0Actor 12/12,
TOOL10 21/21, C3 unit legs, B0Spine/D3 suites, provider suites).
PORT-06 satisfied: no Linux regression. The G13 loop revive (§4) is
behavior-identical on Linux (full gate green, no test change needed).

Runner finding (recorded, not a product defect): running the ENTIRE
`NeedletailPrimitiveTests` target as ONE `swift test` invocation on macOS
(incl. the CLI-spawning integration suites) intermittently wedges the
`swiftpm-testing-helper` (SN state, ~14s CPU then idle; two occurrences,
0 completions). Every affected suite passes individually and the
non-spawning subset completes deterministically (150s). Linux CI runs the
same suites as separate scheduled invocations via `./dev test offline`
layering, so no Linux exposure. Follow-up F5 (runner invocation split) —
not an M4-A blocker.

## 4. Platform shims applied (minimal, demonstrated-failure-first)

All Linux behavior is preserved: every shim is inside
`#if !canImport(Glibc)` / `#elseif canImport(Darwin)` / `#if !os(macOS)`
branches or test-harness files. Glibc paths byte-identical except where
noted (ProbeRoute is platform-neutral; see P2).

- **P1 (G1 partial) `NativeToolExecutor.runBounded` Darwin spawn**: the
  fork+execve path is Glibc-only (Darwin `fork()` unavailable). New
  `posixSpawnDarwin` — posix_spawn with CLOEXEC_DEFAULT, SIGINT/TERM/PIPE
  reset-to-default via SETSIGDEF, SETPGROUP(0) for session children,
  dup2 file actions for stdio. Same downstream drain/escalate/reap. The
  fork path's 0x01-marker protocol has no Darwin counterpart: a
  successful `posix_spawn` IS the started signal (exec failure is
  synchronous). Fail-closed refusals (recorded exclusions, not silent
  fallbacks): fd-bound exec (`execPath`) refused on Darwin; cwd-pinned
  spawn (`cwdFD`) refused — no fchdir-in-spawn primitive on the macOS 14
  floor.
- **P2 `ProbeRoute`**: `defer { try? await client.shutdown().get() }`
  breaks Swift 6.1-era toolchains; restructured to explicit shutdown on
  success + failure paths (elapsed measured before shutdown). Platform-
  neutral code, Linux-verified.
- **P3 `LoopbackSSEServer`**: `#if os(Linux)` → `#if os(Linux) || os(macOS)`
  (BSD sockets identical; SOCK_STREAM spelling differs). Test-support
  only.
- **P4 `RunCommand` SIGINT/SIGPIPE ignore (G8 closed)**: the
  `#if canImport(Glibc)` SIG_IGN installation gains a Darwin branch.
  Without it the default disposition can kill the process before the
  DispatchSource handler runs — demonstrated natively (SIGINT-while-
  awaiting-approval returned wrong exit / child died SIGINT) and fixed:
  the test now passes natively (exit 130).
- **P5 `nt_pty.c`**: `<pty.h>` → `<util.h>` under `__APPLE__` (same
  openpty family). Linux behavior untouched.
- **P6 `NeedletailTypingProbe`**: dual `canImport(Glibc/Darwin)` import
  (POSIX calls only).
- **Test-harness shims** (no product behavior): `await`-in-`defer`
  restructures (NetLoopback ×3, ActorLoopback ×2, BoundaryVerification ×3,
  TimerLoopback ×2, WireLoopback helper, M3A live tests ×7 → unstructured
  drain task), `SpawnHelpers` imports SDK `System` where available (matches
  swift-subprocess's own binding), Glibc-qualified calls unqualified
  (open/rename/mkfifo/lstat in B3; `getpid()` in C1 ×4), SOCK_STREAM
  Int32 spelling (B1, TransportCancellation, LoopbackServerShutdownTests
  widened to `os(Linux) || os(macOS)`), toolchain-inference decompositions
  (B0Spine loops, B0Actor/TOOL09 `first(where:)` forms — one TOOL09
  expression exceeded the macOS type-checker budget), `Package.resolved`-
  identical dependency import fix in SpawnHelpers.

## 5. Demonstrated capability deltas → recorded exclusions (gated tests)

Every gate is `#if canImport(Glibc)` / `#if !os(macOS)` with the reason in
a comment; counts below are native macOS suite runs on the final tree
(post-rebuild). G1/G-cwd/PORT-03/STORE-02/staging-child/flock(1) unchanged
(except C2/TOOL10 narrowing from review, §11); G13 needed NO gate (fixed
by P7); G14 is new (this section, end).

- **G1 exec fd-binding (load-bearing)**: digest-approved exec refuses
  closed on Darwin ("exec requires Linux"). Narrowed per review (§11)
  from whole-suite to per-test gates: C2ExecDurableTests runs 21/21
  natively (20 per-test gates: 17 G1 [14 exec-spawning incl. digest/cwd-pinned paths + 3 actor-spawning] + 3 G-exec digest-actor-spawn found by the native re-run); the DIGEST-VERIFIED
  exec guarantee remains Linux-qualified. C3 keeps its 5 G1 binary-test
  gates (fd-bound exec legs).
- **G-cwd**: GitDiff pins the repo via an open dir FD (`fchdir` in child);
  no posix_spawn equivalent. Narrowed per review (§11): the Darwin denial
  moved AFTER `qualifiedGitFD` (pure-POSIX git-binary qualification, so
  provisioning errors surface identically on both platforms) and
  TOOL10DiffTests runs 8/8 natively (13 per-test gates: 10 spawn legs +
  3 CLI-diff binary legs); the `binary()` helper now searches
  `<cwd>/.build` (swiftpm-testing-helper layout, §11). Diff tool is
  Darwin-denied fail-closed.
- **PORT-03 filesystem deltas** (APFS vs ext4): case-insensitivity +
  Unicode normalization make distinct-name fixtures collide. Excluded:
  B1 `port03CaseSensitive`, `port03UnicodeDistinct`,
  `r1LossySkeletonReadFailsLoud` + `b1CounterfactualUnicodeNormalization`
  (NFD open resolves on APFS), B3 `approvalTwin` (NFC/NFD twin),
  B2Closure `nonUTF8Paths` (APFS rejects raw non-UTF-8 names), `CLOSURE_01_explicitRootRace` + `CLOSURE_02_workspaceRootRace` (fd-bound search identity is Linux-only, G1), B5C
  `PORT_03_binaryCaseAndUnicodeDistinct`. Byte-exact path semantics are
  environment-conditional; documented, not claimed on macOS defaults.
- **STORE-02 crash primitives**: macOS system sqlite (3.51.0) does not
  spill dirty pages into the DB mid-transaction under the test's
  40 KiB-page-cache script (demonstrated: file stays 8192 B vs Linux
  73 728 B mid-transaction) — the crash points the tests rely on cannot
  be staged. Excluded: SQLiteCrashTests STORE-02, CrashMatrix
  `STORE_02_sqliteKillBeforeIntentCommit...`.
- **Staging-child harness**: CrashMatrix re-invokes the test bundle with
  `--filter StagingChild`; that re-invocation protocol has no working
  swift-testing path on this Xcode (child exits immediately, empty logs —
  demonstrated). Excluded: the remaining 7 withKilledChild tests
  (kill-after-intent/side-effect/result, artifact-tmp, renamed-orphan,
  committed-reference, PORT-04 reopen leg).
- **flock(1) tool**: macOS ships flock(2) but not the flock(1) utility;
  B1 lock-holder helper scripts depend on it. Excluded:
  `b1LockContention`, `b1MixedBatchLock`.
- **G14 Darwin-debug pool-stack limitation (new)**: Swift cooperative-pool
  threads are **512 KiB** on Darwin (measured in-test via
  `pthread_get_stacksize_np`; Linux pools are 8 MiB). Debug (`-Onone`)
  frames of the actor call chains (`transition` + admit/cancel/complete
  rows, and the debug `needletail run` child, which runs the same code)
  overflow them — deterministic SIGBUS/SIGILL, layout-sensitive (the
  crashing set flips across rebuilds of identical sources; an 8 MiB
  thread executes the identical crashing sequences cleanly; `-O`/`-c
  release` passes everything). This is a toolchain/platform harness
  limit, not a behavior defect: Linux-debug is green everywhere and
  Darwin-`-O` is green for every exclusion below.
  - Test-process crashers (process dies, suite aborts → suite gates;
    crashing suites identified on the post-rebuild binary, gate set
    frozen for this tree state — see host note on rebuild sensitivity):
    B0ActorIntegrationTests, B1ContainmentTests, TOOL09OrderedBatchTests,
    TimerLoopbackTests, ActorLoopbackTests, BoundaryVerificationTests,
    D3IntegrationTests, B0SpineTests — 0 tests run on Darwin-debug;
    Linux-debug green for all; Darwin-`-O` green for B0/B1/TOOL09/Timer/
    Actor/Boundary (D3/B0Spine `-O` pending host return — counted as
    qualified-by-Linux).
  - Child-process crashers (test process survives → per-test gates,
    keepers keep running): B5CEndToEndTests 19 run-driving binary legs
    (3 early-denial keepers pass), C3ExecQualificationTests 18 binary
    legs (5 G1 + 13 G14 run-driving; 0 run on Darwin-debug),
    ProductionCLIWiringTests 7 run-driving tests (2 early-denial keepers
    pass).
- **Test-fix shims (not exclusions)**: B1 `b1SearchProtected`, B5C rg
  evidence and B2 `locateRg` now locate rg (`/usr/bin/rg` or
  `/usr/local/bin/rg`) instead of hardcoding the Linux path — rg 15.1.0
  was provisioned at `/usr/local/bin/rg` (official release tarball,
  SHA-256 verified against the published sidecar) since no brew exists
  on the host. NOTE (host incident 2026-11-06): the macbuild host
  rebooted mid-slice and lost the workspace AND `/usr/local/bin/rg`;
  the workspace was rebuilt from scratch (fresh clone at `2d11209` +
  change-set tarball) and   rg re-provisioned from the same verified
  tarball (same SHA). No evidence was taken from the pre-reboot
  workspace after the rebuild; all §3 counts are post-rebuild.
  SECOND incident 2026-11-07: host unreachable again (no route) during
  final verification; keepers battery (C2/B2/B3/C1/DX/Wire/Net) and the
  D3/B0Spine/C3 `-O` runs were in flight. All committed Linux gates are
  green; Mac debug keepers were last verified on the post-tarball binary
  (product-identical to final; only test-file gates differ). Re-verify
  on next host availability before citing keeper counts as final.
- **P7 (G13 product fix, not a shim): `SessionTransition.transition`
  terminal-revive de-recursed.** Operator input on a terminal phase
  (`failed`/`completed`/`interrupted`) implicitly acknowledges the
  receipt and re-enters as a fresh admission; the code did this with a
  DIRECT generic self-recursion. On Darwin that recursion stacked two
  of this very large function's `-Onone` frames and overflowed the
  512 KiB cooperative-pool thread stacks — deterministic SIGBUS before
  re-entry (bisected to the call-formation boundary with fsync'd file
  markers; a backtrace sample showed the return into address `0x0`;
  an 8 MiB-stack thread executes the identical call sequence cleanly).
  Replaced with an in-function revive loop (parameter shadowing, zero
  downstream renames): revive terminal→idle, then fall through to the
  normal checkStale + switch. Equivalent by construction — checkStale
  has no operatorInput* row (pre-revive evaluation was always nil),
  idle is non-terminal (at most one revive), all other event/phase
  pairs break out with the original values. Linux behavior identical
  (full offline gate green, no test change); Darwin now admits second
  submits on terminal phases instead of crashing (e.g. B0-F2A 5,
  Boundary ring test pass natively in `-O`; debug lanes still G14,
  §5/§6).
- **P8 (test harness, not product): `SIGPIPEGuard.install()` at the
  head of `boundedSinksFailLoudly`.** The broken-pipe leg writes to a
  closed pipe; the production CLI ignores SIGPIPE at startup (G8) but
  the test runner does not guarantee it — Linux runners happen to
  ignore SIGPIPE while Darwin `swiftpm-testing-helper` does not, so the
  test died of SIGPIPE (signal 13) on macOS instead of surfacing EPIPE.
  Installing the guard in the test makes the EPIPE→`.brokenPipe`
  mapping deterministic on both platforms; Linux unchanged (no-op).

## 6. macOS gap inventory update (from the 2026-11-04 audit)

- G1 (fd-bound exec): CLOSED as refused-fail-closed + bounded runner
  shimmed via posix_spawn (P1); digest verification of executables
  remains Linux-only (exclusion above). The `strdup`-post-fork concern
  (G9) is MOOT for Darwin (no fork path) and unchanged on Linux.
- G2 (/proc liveness): unchanged — Darwin group probe returns nil →
  no group escalation (degraded, documented in-code).
- G3 (monotonic clock): unchanged on Darwin (`Date()` wall fallback in
  `currentBootID`-adjacent `currentMonotonic` is in GRDBSessionStore;
  `NativeToolExecutor.monotonicNanos` already dual-pathed correctly).
  Follow-up F4 stands (boot-elapsed Darwin clock).
- G5 (loopback): CLOSED (P3) — loopback suites green natively.
- G6 (default-graph terminal targets): CLOSED in practice — PTYShim +
  TypingProbe now compile on macOS (P5/P6); the full `swift build` and
  the full test-target build both succeed natively.
- G7 flock(2): exists on Darwin; the store's flock usage untested
  natively (STORE-06 sqlite fencing ran within the 344 — passing).
- G8 (CLI signals): CLOSED (P4).
- G10 (F_FULLFSYNC durability): NOT ADDRESSED — macOS fsync does not
  guarantee physical-media flush. STORE/STOP-durability claims remain
  Linux-qualified; follow-up F2.
- G11 (XDG defaults): functional as-is on macOS (state dir under HOME
  works); no change proposed.
- G12 (Doctor utsname): works (`Darwin … x86_64`).
- G13 (terminal-revive self-recursion): CLOSED by product fix P7 —
  revive is now a loop; no recursion, no gate needed. Linux identical
  (full gate green); Darwin admits second submits instead of crashing.
- G14 (Darwin-debug pool stacks): NEW, documented, qualified-around —
  512 KiB cooperative-pool stacks + `-Onone` frame bloat overflow in
  deep actor paths and debug CLI children. Behavior is qualified by
  Linux-debug (all green) and Darwin-`-O` (all gated suites/tests
  verified green except C3/D3/B0Spine `-O`, pending). Not a product defect;
  no M4-B blocker (lanes run Linux-debug; Darwin native lanes record
  G14 exclusions explicitly).

## 7. arm64 cross-build (COMPILE-ONLY)

`swift build --arch arm64` on the Intel host: **Build complete (321s)**,
product `needletail` verified `Mach-O 64-bit executable arm64`
(.build/arm64-apple-macosx/debug). This is compile evidence ONLY:
nothing arm64 was executed and no arm64 runtime claim is made.

## 8. Remaining arm64 qualification requirements (for any future claim)

1. Apple Silicon hardware (any M-series Mac) or an arm64 GH runner lane;
   Rosetta on Intel cannot execute arm64 binaries.
2. Native run of the scheduled suites on arm64 macOS (same suite list as
   §3) — offsets/probe paths (`siginfo_t` ABI legs are x86_64/arm64-Linux
   gated anyway) and Rosetta-free Process/PTY behavior must be re-proven.
3. Release (`-c release`) build + clean-host smoke on arm64 (packaging
   PORT-05: declared runtime/glibc-equivalent requirements).
4. Universal-binary decision (lipo) + notarization/codesigning evidence
   if distribution is intended.
5. Dependency OS-floor matrix per vendor (F3) if macOS 14 floor is to be
   claimed on arm64.

## 9. Follow-ups (named, none blocking M4-B)

- F1: macOS equivalents for fd-bound exec + cwd-pinned spawn (public API
  does not exist on the macOS 14 floor; needs a design decision —
  e.g. helper approach — reviewed separately).
- F2: `F_FULLFSYNC` on Darwin durability paths or explicit macOS
  durability downgrade in the spec.
- F3: per-dependency minimum-OS evidence table.
- F4: Darwin boot-elapsed monotonic clock with defined sleep semantics
  (`mach_continuous_time`) to replace the wall-clock fallback.
- F5: split the PrimitiveTests mega-run into scheduled per-suite
  invocations (Linux CI already layers; macOS runner wedge recorded in §3).
- F6: `posix_spawn` started-signal semantics documented in the spec
  (marker protocol is Linux-only now).

## 10. Bounds honored

No M4-B/C/D work, no live model traffic, no new benchmark runs, no push/
PR/merge for `m4-a`. M3 acceptance and limitations untouched. Linux
gates green at close (§3). The branch remains local-only; deep-review
and any future authorization are the maintainer's.

## 11. Deep-review close-out + Darwin stack-limitation evidence

DeepSeek review #2 (NEEDS-CHANGES, static-only) findings F1–F9, all
addressed on Linux + Mac (Linux `./dev test offline` green after every
change; affected Mac suites re-run natively):

- F1 (over-broad C2/TOOL10 gates) → narrowed to per-test gates drawn
  from the macOS failure inventory, then re-verified: 3 C2 tests the
  inventory missed (digest-approved actor spawns) were caught by the
  NATIVE re-run and gated with the accurate reason
  (ExecRunner digest refusal); TOOL10's denial now runs git-binary
  qualification first (identical error precedence both platforms) and
  the binary helper resolves the swiftpm-testing-helper layout.
- F2 (GitDiff `Failure` typed) → `Failure.denied` with the neutral-cwd
  message; ordering fixed per F1.
- F3/F4 (Atlas/ProbeRoute lifecycle + ProbeRoute ordering) → existing
  do/catch shutdown kept; transport+invocation construction hoisted
  before the clock (elapsed measures the wire, as pre-6.1).
- F5 (suite `:{x}` counts) → CrashMatrix gate corrected (9 exclusions
  with stated reasons: STORE-02 sqlite + 7 staging-child + flock... —
  exact inventory in code comments).
- F6 (B1 `b1SearchProtected` paragraph) → comment now states the B2
  story: B2's `locateRg` needed no change (already searches both
  paths); the macOS failures were the missing rg binary after the host
  reboot (§4 P-note), not the locator.
- F7 (M3A fire-and-forget shutdown) → explicit awaited `shutdown().get()`
  on live-test happy paths (deferred task kept as the throw-path
  backstop); M3A tests are live-gated (skip without `M3A_LIVE=1`).
- F8/F9 (assertion exactness, CrashMatrix reason, EOF blanks) → applied
  (`filter`+`allSatisfy`/`contains` preserving negative/positive
  polarity; s1 comment; trailing newlines).

G13/G14 stack-limitation evidence (all Darwin-native, x86_64):
- Pool stacks measured 512 KiB in-test (`pthread_get_stacksize_np`).
- Deterministic SIGBUS before `transition()` re-entry on
  (failed-state, operatorInput); fsync'd file markers prove the call
  never enters; a `sample` backtrace showed the return into `0x0`
  (clobbered frame); the IDENTICAL sequence passes on an 8 MiB-stack
  thread and under `-O`/`-c release`.
- The loop revive (P7) removes the only self-recursion; remaining
  debug crashes are deep single-entry chains (cancel/failEffect paths,
  full CLI runs) overflowing the same 512 KiB — layout-sensitive
  (identical sources flip pass/fail across rebuilds), release-clean.
- `-O` evidence — same product code (test-only G14 gates lifted for
  these runs): B0 12/12, B1 39/39, TOOL09 13/13, Timer 2/2,
  Actor 2/2, Boundary 6/6, B5C 22/22, ProductionCLI 9/9 (C3 binary legs,
  D3, B0Spine `-O` runs pending — Linux-debug green stands in;
  macbuild host went unreachable 2026-11-07 before these three could
  run — see §12 host note).

## 12. Final qualification attempt 2026-11-06 UTC (SHA `96eaeda`, BLOCKED)

Tree: `96eaeda2433ef9c0b6f0601f28e502473bbbe7e6` (branch `m4-a`,
local-only), working tree clean. No code changes in this slice
(receipt-only); DeepSeek READY stands, no re-review launched.

Host note (the "below" §11 points at): macbuild `build@192.168.2.106`
is unreachable at L2 — `ping` 100% loss, `ssh` "No route to host",
`tracepath` ends `!H` at gateway 192.168.1.1, no ARP entry for .106.
The local segment is healthy (peer 192.168.2.216 answers in <1 ms on
`enp9s0`; gateway answers). No VPN/tunnel interfaces exist on this
machine. A port-22 sweep of 192.168.1.0/24 found only unrelated Linux
lab hosts (no macOS SSH banner). The host is powered off, crashed, or
disconnected — same outage §4/§5 record, not returned. NO other macOS
host exists in this environment (`uname -a`: Linux betalab 7.0.0-38).
Conclusion: §1 (D3/B0Spine/C3 `-O`, final-tree keepers, G13 re-verify)
is NOT executable here. Nothing from earlier trees is carried forward
as final-tree qualification: the pending items remain pending.

§1 status (all unexecuted, none waived):
- D3 optimized: not run (Linux-debug green stands in, unexecuted).
- B0Spine optimized: not run (Linux-debug green stands in).
- C3 optimized (13 G14 legs): not run (Linux-debug green stands in).
- Final-tree keeper re-verification (C2/B2/B3/C1/DX/Wire/Net keepers
  on the committed tree incl. c59401c/96eaeda assertion+gate fixes):
  not run on Darwin (Linux green, §12 gate below).
- G13 loop-revive re-verify on final tree: not run on Darwin.
  Static check only: `transition` has exactly one definition
  (`SessionTransition.swift:402`), zero self-call sites — the
  recursion is structurally absent; Linux behavior identical
  (full gate green, no test change needed).

G14 adjudication (static, exact — no Darwin reruns possible, none
substituted):
- Inventory verified against code: 8 suite-level G14 gates (B0, B1,
  TOOL09, Timer, Actor, Boundary, D3, B0Spine — test-process crashers,
  0 run each on Darwin-debug) + 39 per-test G14 gates (B5C 19, C3 13,
  ProductionCLI 7 — debug-child crashers, test process survives) +
  C3 5 G1 + B5C TOOL_10 G-cwd + B5C PORT_03 + keepers (B5C 3,
  ProductionCLI 2, C2 21, TOOL10 8, B2 27, B3 30, C1 8, DX/Wire/Net).
  Every gate comment states its mechanism; counts match §§3/5.
- Mechanism split is precise, not blanket: suite gates exist ONLY
  where the runner process itself dies (a per-test gate cannot survive
  process death); per-test gates everywhere else. All gates are
  Darwin-only (`#if canImport(Glibc)`); Linux runs everything.
- Classification truthful: failing sequences are proven correct code
  (Linux-debug green everywhere + Darwin `-O` green for 6/8 suites,
  B5C, ProductionCLI — same product code, test-only gates lifted).
  Failure requires Darwin-debug specifically (512 KiB pool stacks ×
  `-Onone` frame bloat). No shipped configuration (`-c release`)
  has ever demonstrated the failure; the one implicated production
  path (G13 self-recursion) was fixed as product change P7, which
  REMOVED an exclusion rather than adding one. G14 adds zero product
  code (diff `0614491..HEAD -- Sources/`: one 5-line comment).
- No gated test is recorded PASS: §§3/5 record "0 run"; `-O`
  results are labeled evidence ("behavior qualified"), never pass
  claims. The §3 line "every G14 exclusion with -O evidence ...
  passes optimized" refers to the excluded BEHAVIOR under `-O`,
  not to the debug tests.
- Targeted-reproduction caveat: fresh crash evidence (samples,
  stack measurements) is NOT obtainable without the host; the §11
  evidence stands as recorded run evidence (11-06 sessions), not
  re-derived here. Adjudication here is inventory + mechanism +
  labeling verification, which is complete.
- Pre-existing honesty gap retained: D3/B0Spine/C3 `-O` runs are the
  only unexecuted leg of the triangulation for those three suites.

Linux gate at final SHA (this slice, no model traffic):
- `./dev test offline` → **OFFLINE OK: all scheduled offline layers
  passed** (0 FAIL lines), plus `./dev vendor-check` → VENDOR OK
  (offline + clone). Tree clean before and after.
- Incident: the first full-gate attempt FAILed ONLY in the
  coverage-evidence bulk lane: `TOOL_05_concurrentEdits` (B3, 5
  issues — a double-failure interleaving: artifact-verify fail +
  lock contention, zero clean winners). Same test passed 2× earlier
  in that same run (quick + native lanes), 3× standalone, and 1× in
  an isolated bulk-lane retry (266/266 pass) — 6 passes vs 1 failure
  under bulk+coverage scheduling perturbation. Product stayed
  fail-closed in every branch (no silent corruption/lost update);
  zero product-code changes exist in this tree to implicate. The
  second FULL `./dev test offline` run is green end-to-end (the
  flake did not recur — 7th consecutive pass). Recorded as
  environmental timing flake, consistent with the ./dev FINAL-02/03
  notes on bulk-lane scheduler contention; test strictness
  (exactly-one-winner) intentionally unchanged.

Verdict: **M4-A BLOCKED** — scope precisely:
- QUALIFIED-requirements met: Linux offline gate green at final SHA,
  vendor-check green, G14 classified truthfully with exact inventory,
  no demonstrated production portability blocker (G13 fixed; G14
  confined to Darwin-debug with dual-platform behavioral evidence
  except the three pending `-O` legs).
- QUALIFIED-requirements unmet (all host-dependent): D3/B0Spine/C3
  `-O` runs, final-tree Darwin keeper evidence, final-tree Darwin
  G13 re-verify.
- Unblock condition: macbuild (or any Intel macOS host with Xcode
  26.x/Swift 6.3.x) returns → sync tree at `96eaeda` (or its
  successor if the keeper re-verify forces changes), run the §1
  battery with command lines + exit codes + host identity recorded,
  then QUALIFIED can be declared without further review iff all
  green and no code changes result.
- STOP honored: no M4-B/C/D, no push/PR/merge (branch local-only),
  no model traffic (M3A live-gated, none invoked).
