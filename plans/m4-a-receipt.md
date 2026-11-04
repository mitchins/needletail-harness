# M4-A Receipt — native Apple Silicon portability (environment + audit)

Date: 2026-11-04. Branch `m4-a` (local only — no push/PR/merge per authorization),
based at `2d11209` (M3 squash-merge of PR #9; tree-identical to qualified HEAD
`bc29050`). No tracked modifications; this receipt was the only untracked file
(committed locally at close so the tree is clean — still no push).

Scope honored: M4-A only (M4 plan §3). No terminal/PTY, no `@`/queue/undo UX,
no swift-markdown, no frameworks, no live model traffic, no benchmark runs.
M3's CONDITIONAL acceptance and all documented benchmark limitations stand
(`plans/m3-acceptance.md`, unchanged).

## 1. M3 merge record

- PR #9 pre-merge verification (2026-11-04): head `bc29050` == qualified HEAD;
  6/6 exact-head checks green (offline build+tests, packaging smoke,
  CodeRabbit, SonarCloud, SonarQube, GitGuardian); CodeRabbit approvals
  (latest 04:07:51Z, post-final-push); 30/30 review threads resolved;
  `MERGEABLE`, `mergeStateStatus` CLEAN. No `--admin`; no reviews dismissed.
- Squash-merge SHA: `2d1120925b07da19ae8658d9ec680027319dc92c`
  (single parent `1ab0aa4`, the M2-D merge base).
- Tree-equivalence: `git rev-parse bc29050^{tree}` ==
  `git rev-parse 2d11209^{tree}` == `cddf7eebe935f5b65e1bc7fcdea765493f497b61`;
  `git diff bc29050 2d11209` empty. The merged main tree is byte-identical
  to the qualified PR HEAD.

## 2. macOS environment availability: NONE

- Build host: Linux x86_64 (Ubuntu 24.04), Swift 6.4 Linux toolchain.
  No `xcodebuild`/`xcrun`, no `/Applications`, no Apple hardware.
- No remote macOS host reachable (no ssh entries, no documented Mac).
- GitHub-hosted Apple Silicon runners (`macos-14/15`) exist as a platform
  but are unreachable in this slice: consuming them requires pushing a
  branch or workflow file, and push is prohibited for M4-A.
- A Linux cross-build does NOT qualify macOS (no macOS SDK on Linux; the
  Swift Linux toolchain cannot typecheck `canImport(Darwin)` branches).
- Consequence: M4-A's exit criterion (native Apple Silicon build + scheduled
  portable suites) CANNOT execute here. This is blocker B1 below — a
  provisioning decision for the maintainer, not a technical finding.

## 3. Static portability audit (unchanged tree @ `2d11209`)

Package graph: `swift-tools-version:6.1`, `platforms: [.macOS(.v14)]`
(floor DECLARED, evidence pending per M4 plan §3 — no macOS 14 claim is
made here). Dependencies are all cross-platform vendors (swift-argument-parser,
async-http-client + swift-nio, swift-openapi-runtime, swift-subprocess,
swift-system, swift-crypto, GRDB.swift), resolved and tested Linux x86_64
only (`Package.resolved` committed). macOS resolution/execution untested.

PORT-02 boundary: CLEAN. `NeedletailCore` and `NeedletailPresentation`
contain zero `Glibc`/`Darwin`/`os()` references. The `canImport(Glibc)` /
`canImport(Darwin)` dual-import pattern is already established in
Runtime/CLI/TestSupport (`RunCommand`, `DiffCommand`, `AttachmentCapture`,
`GRDBSessionStore`, `ExecRunner`, `NativeToolExecutor`, `WorkspaceResolver`,
`SIGPIPEGuard`, etc. — POSIX `read`/`write`/`_exit`/`signal`/
`setsid`/`raise`/`clock_gettime(CLOCK_MONOTONIC)` dual-pathed throughout;
known exceptions are inventoried as G2 (Darwin reaping uses `waitpid`,
group-liveness unqualified) and G8 (CLI SIGINT/SIGPIPE ignore is
Glibc-only).
`Tests/NeedletailConfigTests/ImportGateTests.swift` + `PresentationGateTests`
pass on the `m4-a` checkout (5/5).

Load-bearing macOS gaps (G1 fails closed; G2 is unqualified/degraded — see
G2 note; G3 degrades to wall-clock — see G3 note; none altered):
- G1. `ExecRunner.run` refuses closed on non-Glibc for digest-approved exec
  ("exec requires Linux (/proc/self/fd unavailable)"). The TOCTOU-safe
  spawn binds executables via `/proc/self/fd`; macOS needs the `/dev/fd`
  (or equivalent) path the code comment already anticipates. THIS is the
  M4-A implementation work — gated on a Mac.
- G2. `NativeToolExecutor` liveness probes read `/proc/<pid>/stat` and scan
  `/proc` (lines 1241, 1316); on non-Glibc the group probe returns nil and
  the caller treats it as no-escalation (degraded, not fail-closed).
  macOS needs `sysctl(kern.proc)` equivalents.
  (Group-liveness itself is dual-pathed: `setsid` + `kill(-pid)` at 1483+,
  1944; Darwin reaping already uses `waitpid` — what needs verifying on
  Darwin is the group-liveness semantics, not API availability.)
- G3. `currentMonotonic()` uses `CLOCK_BOOTTIME` on Glibc but falls back to
  wall-clock `Date()` elsewhere — an NTP step would corrupt durations, so
  this is a silent degradation, not a fail-closed gap. The Darwin shim needs
  a boot-elapsed clock with DEFINED sleep semantics (`mach_continuous_time`
  or equivalent — note `CLOCK_UPTIME_RAW` excludes suspend time whereas
  `CLOCK_BOOTTIME` includes it; the choice must be explicit).
- G4. `currentBootID()` already has a Darwin fallback (`kern.boottime`
  sysctl). No work expected; verify on Mac.
- G5. `LoopbackSSEServer.init` throws `unsupportedPlatform` on non-Linux
  (not just its shutdown test) — dozens of suites construct it directly
  (e.g. `B5CEndToEndTests:374`, `NetLoopbackTests:43`, `M1DCasesTests:201`)
  and will fail on macOS until Darwin socket branches exist. Additionally
  `C2ExecDurableTests:838,964` assert on `/proc/self/fd` paths and count
  `/proc/self/fd` entries with no Glibc guard (contrast `B2ClosureTests:759`,
  guarded). A test-portability inventory with per-suite disposition
  (port / guard / skip-with-reason) is required before anyone claims the
  "scheduled portable suites" run on macOS.
- G6. `NeedletailTypingProbe` (executableTarget) and `PTYShim`
  (`Tests/PTYShim/nt_pty.c` — Linux-only, includes `<pty.h>`) plus
  `NeedletailTerminalTests` sit in the DEFAULT package graph
  (`Package.swift:93-96,139-151`): a plain `swift build` / `swift test`
  touches them. This is M4-C/D *functionality* but M4-A *build scope* —
  the M4-A lane must be product-scoped (`swift build --product needletail`
  plus the library products; `swift test` with terminal targets excluded
  or platform-guarded) and that scoping is recorded here as an M4-A item.
- G7. `flock()` (store fencing) exists on Darwin (BSD) — semantics to
  confirm on Mac. Child `PATH` defaults (`/usr/bin:/bin`) exist on macOS.
  TLS via AsyncHTTPClient/NIOSSL is platform-neutral; credentials are
  env-file based (no Keychain dependency).
- G8. CLI signal setup is Glibc-only: `RunCommand:984-987` ignores
  SIGINT/SIGPIPE under `#if canImport(Glibc)` with no Darwin branch, while
  the SIGINT `DispatchSource` (line 988+) installs unconditionally.
  Dispatch signal delivery races the default disposition without the
  ignore — cancellation may terminate the process before the actor handles
  it. Needs an `#elseif canImport(Darwin)` branch (or unqualified Darwin
  import, matching the file's existing dual-import pattern).
- G9. Child-side `strdup(execPath)` post-fork (`NativeToolExecutor:1610-1622`)
  is not async-signal-safe (argv/env themselves are prepared pre-fork per
  the comment at 1439-1445 — this one allocation escaped that discipline).
  Tolerated on Linux; materially riskier on macOS, where fork() from a
  multithreaded process is restricted to async-signal-safe operations.
  Fix direction: precompute the exec-path C string pre-fork, or adopt a
  `posix_spawn`-based runner on Darwin (no such runner exists today —
  `posix_spawn` appears only in comments).
- G10. Durability paths use plain `fsync` (`GRDBSessionStore:878,953,1263,
  1323`; `ArtifactFiles:59-73`; `LiveRequestBudget:104-130`;
  `UndoFiles:322,348`; `NativeToolExecutor:478-484,2894,2993`). On macOS
  `fsync` does not guarantee physical-media flush — `F_FULLFSYNC` is
  required for the flush claim. This is a load-bearing capability delta
  for STORE/crash-durability evidence: implement `F_FULLFSYNC` on Darwin
  or explicitly downgrade the macOS durability claim.
- G11. Default state/config paths follow XDG (`~/.local/share/needletail`,
  `~/.config/needletail/config.json`, overridable via `NEEDLETAIL_STATE_DIR`
  / `XDG_*_HOME`). Functional on macOS, non-native convention — recorded
  as an intentional-vs-pending delta for the maintainer (no change proposed
  in M4-A).
- G12. `Doctor.hostPlatform()` reports via `utsname`/`uname`
  (`Sources/NeedletailCLI/Doctor.swift`) — portable API, output differs
  (`Darwin … arm64`); no change needed, noted so capability deltas are
  read correctly.

Remaining verification points for the Mac (not findings — behavior to confirm
natively): group-liveness semantics of the dual-pathed `setsid`/`kill(-pid)`
and `waitpid` reaping; APFS case-insensitive default vs ext4 (PORT-03);
quarantine xattr + executable bits on spawned binaries; codesigning
requirements for spawned helpers; CA roots for provider TLS; product-scoped
and per-target builds resolving the full `Package.resolved` graph on macOS.

## 4. Baselines and regressions

- Linux baseline for the unchanged tree: the exact-head CI on `bc29050`
  (6/6 green) covers the merged tree byte-for-byte (§1). Local `m4-a`
  checkout: PORT-02 gate suites pass; `git status` clean.
- Platform shims applied: NONE — correct per the M4-A goal (build and run
  the unchanged portable core on Apple Silicon first; add only required
  shims after). Altering code without the macOS gate would be
  unverifiable.
- Linux regressions: NONE POSSIBLE — zero implementation changes; tree
  untouched. PORT-06 gate (Linux stays green after every portability change)
  stands ready for the first shim.

## 5. Blockers

- B1 (load-bearing): no accessible native Apple Silicon macOS environment.
  M4-A cannot proceed past audit without one. Maintainer options: provision
  an Apple Silicon Mac with Swift 6.1+ toolchain (Xcode 16.3+, per
  `swift-tools-version:6.1`), or authorize a macOS CI lane — which requires
  lifting the no-push constraint for a workflow branch. Lane shape when
  unblocked: arm64 `macos-14`/`macos-15`, product-scoped build
  (`--product needletail` + libraries; terminal targets excluded/guarded
  per G6), scheduled portable suites per the G5 test inventory, with the
  PORT-06 Linux re-run after every shim.
- B2 (consequent): all M4-A exit criteria pending — native build, scheduled
  portable suites on macOS, dependency floor evidence, capability deltas,
  shim inventory (G1–G12 recorded above; actionable shims G1/G5/G6/G8/G9/G10
  queued smallest-first when unblocked).

No M4-B/C/D work started. No live traffic, no benchmarks, no PR/push/merge
for `m4-a` (branch remains local-only).
