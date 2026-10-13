# M0-C / M0-D plan — replxx feasibility and release foundations

Slice type: minor milestones M0-C (line-editor feasibility only) + M0-D (clean Linux runtime and CI foothold, local scope).
Status: revision 2 after `deepseek-reviewer` plan review (findings FR-01…FR-11). Baseline commit: `c2b3b139ba9fc82764af03a5a96ddcda4f04ab33` (M0-A/M0-B closed; `07e0269` was the code closure, `c2b3b13` the evidence-only receipts commit).
Prepared: 12 October 2026 by implementer route `opencode-go/step-5-preview-free` (unchanged).

Prototype handling (FR-05): the pre-plan `Sources/CReplxx/**` vendored target and the `ThirdParty/replxx` reference clone already exist in the working tree from evidence gathering. They are unmodified by this plan's approval; they become slice artifacts only if this plan is approved, and the clone itself is never committed (gitignored; the vendored copy carries a provenance file).

## 1. Goal

- **M0-C:** prove the risky library assumption before any TUI work — vendor the pinned replxx under a SwiftPM C/C++ bridge and run ONE bounded Linux PTY feasibility scenario: line editor live; synthetic streaming output while the composer is live; an unsent multiline/Unicode draft; a completion callback that FIRES and returns an observable synthetic candidate (full preview rendering is M4); a resize; a cancel; verifying the retained draft bytes and terminal-state cleanup. If concurrent redraw or draft preservation fails, record the exact failing trace and produce a narrow ADR comparing the smallest maintained line-editor alternative — no accumulating workarounds, no custom terminal framework.
- **M0-D (local only):** release foundations — a release build with declared native linkage, a clean-host smoke on a digest-pinned container without Swift/Node/Python and with network disabled, an offline environment/capability inspection command (`doctor`), the Linux CI workflow file (prepared locally, NOT pushed: remote operations are not authorized), and `./dev` hardening so a missing case match, a wrong-case match, or a test-runner failure can never produce a false pass.

Authorization unchanged: local implementation approved; GitHub push/PR/CodeRabbit activation NOT authorized; no new product dependency decisions (the replxx pin is the existing DEPENDENCIES.md selection; docker is a local qualification aid; the PTY driver is the authorized test-only C shim, not a new package).

## 2. Baseline evidence already established (this session, pre-plan)

| Fact | Evidence |
|---|---|
| replxx at pinned commit `1f149bfe…` compiled standalone with g++ 13.3 C++11: 11 objects, no errors; `src/windows.cxx` is `#ifdef _WIN32`-guarded (no-op on Linux); C API in `include/replxx.h` is `extern "C"` | `/tmp/opencode/replxx-build`, log retained to `.needletail-dev/logs/replxx-standalone-build.log` |
| Vendored SwiftPM target `CReplxx` (upstream sources + `LICENSE.md` + module map + shim header) **builds** on Swift 6.4.0 Linux: 12 objects, `Build complete! (3.68s)` | log retained to `.needletail-dev/logs/creplxx-swiftpm-build.log` |
| C API surface needed exists: `replxx_init/replxx_end`, `replxx_input(replxx, prompt)`, `replxx_print/replxx_write`, `replxx_set_prompt`, completion callback type `replxx_completion_callback_t` + `replxx_add_completion` | `include/replxx.h:227–410` |
| Docker usable; g++ 13.3.0 / cmake 3.28.3 present (build-time only) | `docker info`; image pinned by digest at smoke time and recorded |
| Vendored integrity check available: per-file hash comparison of `Sources/CReplxx/replxx/**` against the pinned upstream commit (FR-10) | recorded as a finish condition |

Open risk carried into the slice (the reason M0-C exists): replxx's public names do not prove safe concurrent output/draft preservation while an input line is live; only a real PTY run does (UX-DX §4, S09/S25).

## 3. Case IDs in scope — explicit status-transition table (FR-02)

No case status changes from `DEFERRED_BY_PLAN`. `status` fields are untouched; only `status_detail` annotations are added, naming local preparation or pending authorization:

| Case(s) | Status (unchanged) | `status_detail` after this slice |
|---|---|---|
| PTY-01…08, TERM-01…04 | DEFERRED_BY_PLAN (M4) | PTY-driver seed + ONE Linux feasibility scenario exist as development evidence; not interactive acceptance |
| PKG-01 | DEFERRED_BY_PLAN (M6) | thin clean-host smoke executed locally (version/help/doctor on digest-pinned image, network none); mock-session run still due |
| PKG-02 | DEFERRED_BY_PLAN (M6) | no network-blocked host matrix run yet |
| PKG-03 | DEFERRED_BY_PLAN (M6) | workflow file prepared locally; locked-graph rebuild not executed (unpushed) |
| PKG-04 | DEFERRED_BY_PLAN (M6) | linkage manifest + notices produced for the local bundle; SBOM still due |
| PKG-05 | DEFERRED_BY_PLAN (M2 due) | `doctor` capability machinery exists early (git/rg presence → capability statement) |
| PKG-06 | DEFERRED_BY_PLAN (M6) | unimplemented-arch handling not built |
| DX-08 | IMPLEMENTED (M0) | CI workflow runs the same offline suites when activated |
| DEV-03 | DEFERRED_BY_PLAN (M0-D) | workflow prepared locally with least-privilege/fork boundaries; activation pending remote authorization (`BLOCKED_REVIEW` on the authorization itself) |
| REV-05…08 | DEFERRED_BY_PLAN (M0-D) | all require the remote CodeRabbit/review path; not authorized |

Bounded scope reduction routed to the maintainer (FR-01): MILESTONES M0-D names three clean-host executions — help, offline config inspection, synthetic smoke. This slice implements help + offline inspection (`doctor`, no config schema at M0) + a hermetic offline smoke trio. The **mock/session-provider smoke** cannot exist until M1-D (headless end-to-end) and is recorded as deferred with this table rather than silently omitted; the maintainer may accept this reduction or direct otherwise.

## 4. Invariants the slice must not violate

I01 (`doctor`, help, version stay network-free by construction), I02 (bundle performs no downloads; smoke runs with `--network none`), I13/I14 (draft semantics are M4 concerns; the probe must not alter draft bytes), I18 (no terminal controls from untrusted bytes — the probe writes only its own synthetic output), plus bounded queues/deadlines in the harness. No sudo, no host reconfiguration, no serving-workload disturbance, no push.

## 5. Given/When/Then outcomes (behaviour contracts)

1. **Vendored integration:** Given the pinned replxx sources, when the package builds on Linux/Swift 6.4, then `CReplxx` compiles as a target, per-file hashes match the pinned upstream commit, and licence + commit provenance are committed with it.
2. **Feasibility scenario (the M0-C gate):** Given the probe executable running under a real PTY with the line editor live, when the operator types an unsent multiline Unicode draft, synthetic stream output is written, the completion callback is invoked and reports at least one observable candidate, the window is resized 40→120→80, and Ctrl+C cancels, then the retained draft bytes are reported exactly as typed, streamed output stayed ordered (no interleaved escape corruption), and after exit the terminal returns to canonical echo (functional mode-restoration check).
3. **Feasibility failure branch:** Given concurrent redraw garbles output or the draft is lost, when the scenario runs, then the exact failing trace is retained and a narrow ADR compares the smallest maintained alternative under fixed criteria (bracketed paste, Unicode, concurrent output, signal cleanup, vendoring simplicity) — no workaround accumulation, no bespoke full-screen framework.
4. **Release bundle + clean host:** Given a digest-pinned ubuntu:24.04 container without Swift/Node/Python and with networking disabled, when the bundled binary runs `--version`, `--help` and `doctor`, then each exits 0 with no download attempt, `swift`/`node`/`python3` are asserted absent, and the linkage manifest matches the bundle's notices.
5. **`./dev test case` guard:** Given a case ID absent from `cases/catalog.json` or matching no test (or a prefix like `REV_0` that is not a catalogue ID), when `./dev test case CASE-ID` runs, then it exits non-zero naming the exact problem — never a green run, and never a run whose matched tests belong to a different case.
6. **Runner-failure guard:** Given the test runner crashes or emits no result line, when any `./dev test` command runs, then the command exits non-zero — a runner failure is never a pass.

## 6. Forbidden effects

Pushing to the remote, creating a PR, activating CodeRabbit, adding any product dependency beyond the already-selected replxx pin, shipping the probe or PTY shim in the release bundle, sleeps instead of readiness, unbounded PTY reads, modifying the vendored replxx sources (only the bridge files are ours), claiming PTY-01…08/TERM-*/macOS satisfied, claiming config-schema or session behaviour (not built), or treating the container smoke as more than its Linux scope.

## 7. Proposed seams

- `Sources/CReplxx` — vendored C/C++ target: upstream sources under `replxx/`, `LICENSE.md`, `shim.h`, `include/module.modulemap`, `README.provenance` (pinned commit, upstream URL, per-file hash integrity check).
- `Sources/NeedletailLineEditor` — new production target holding the replxx bridge (C API only). Architecture note (FR-09, accept-with-doc): SPEC §4's map predates the line editor; this seam exists so M4 can fold CLI ownership around it without a rewrite, and it is recorded in `plans/` as an architecture note; no other target imports it.
- `Sources/NeedletailCLI` — gains the offline `doctor` command (version/platform identity, git/rg presence with the exact capability each enables/disables, no network) and stays the composition root.
- `Sources/NeedletailTypingProbe` — debug-only fixture executable (excluded from the release bundle, documented as the M0-C stand-in for the M4 production composition root, FR-11); speaks the marker protocol the driver asserts.
- `Tests/PTYShim` — test-only C target: `forkpty`/`openpty`, termios save/restore, `ioctl(TIOCSWINSZ)`, signal helpers, bounded read.
- `Tests/NeedletailTerminalTests` — Swift Testing driver: one bounded scenario with readiness markers and hard deadlines.
- `./dev` — new `release-bundle` and `test packaging` commands; exact-ID validation and result-line hardening.

## 8. Changed files (planned)

`Package.swift` (CReplxx, NeedletailLineEditor, NeedletailTypingProbe, PTYShim targets; probe/PTYShim excluded from the executable product); `Sources/CReplxx/**`; `Sources/NeedletailLineEditor/*.swift`; `Sources/NeedletailCLI/*` (doctor command); `Sources/NeedletailTypingProbe/main.swift`; `Tests/PTYShim/*.c` + module map; `Tests/NeedletailTerminalTests/*.swift`; `dev`; `release/README.md` + generated bundle + `release/linkage-manifest.txt` (build artifacts); `.github/workflows/linux-ci.yml` (local, unpushed); `.coderabbit.yaml` (prepared; schema validation `BLOCKED_REVIEW` until the remote exists); `NOTICE.md` (replxx notice); `dependency-inventory.json` (vendored component, C++ runtime linkage, docker-as-local-aid note); `STATUS.md`; `plans/m0-c-d-plan.md`; `plans/m0-c-d-receipt.md`; `plans/m0-milestone-report.md` (M0-C/D section); `.gitignore` (`ThirdParty/`, bundle outputs).

## 9. Tests to be written (RED first)

- **Terminal feasibility (native, PTY):** the one scenario in §5.2 with a readiness marker protocol, including the completion-callback invocation oracle (callback fires; ≥1 observable candidate reported) and the retained-draft assertion.
- **Probe protocol checks (native):** draft bytes round-trip exactly (multiline + Unicode + combining marks), cancel retains the draft, exit restores canonical echo, no interleaved corruption of the synthetic stream.
- **`doctor` (native):** offline output has no network dependency; git/rg presence maps to the correct capability statement either way (test via PATH restriction in a subprocess, not by touching the host).
- **Release/packaging commands (native):** `./dev release-bundle` produces binary + manifest; clean-container smoke (network none, digest-pinned image) asserts version/help/doctor exit 0 and asserted absence of swift/node/python; release binary runs from a directory with no toolchain on PATH.
- **`./dev` hardening (native):** bogus `test case` ID exits non-zero; `REV_0`-style prefix exits non-zero as a non-catalogue ID; a forced runner-no-result exits non-zero; qualification still distinguishes expected failure from crash.
- **Guard probes:** the classical 0-test-green and wrong-case-green cases fail RED first in the shell (recorded), then the hardening makes them red-by-design.

## 10. Fault points (named, deterministic)

`replxx.vendored-build`, `vendor.licence-missing`, `vendor.hash-mismatch`, `pty.spawn-failure`, `feasibility.redraw-garbled`, `feasibility.draft-lost`, `feasibility.modes-not-restored`, `feasibility.callback-not-invoked`, `probe.readiness-timeout`, `dev.case-no-match`, `dev.case-not-in-catalogue`, `dev.case-wrong-case-match`, `dev.runner-no-result`, `dev.qualification-crash-confused-with-fail`, `bundle.missing-native-lib`, `cleanhost.download-attempt`, `cleanhost.toolchain-present`, `ci.unpinned-action`.

## 11. Finish conditions

1. `CReplxx` builds and is committed with licence/provenance; vendored per-file hashes match the pinned upstream commit (integrity check recorded).
2. M0-C scenario executed with retained logs; outcome recorded as PASS evidence or a failing trace + ADR (no half-state).
3. Release bundle builds (`./dev release-bundle`) with the linkage manifest matching the notices; clean-container smoke passes with logs retained, including the static-stdlib-or-dynamic decision and the digest-pinned image identity.
4. CI workflow + CodeRabbit config prepared locally, documented as inactive, with least-privilege/fork-boundary rules stated, the workflow's command sequence dry-run locally, pinned action revisions verified against the GitHub API, and CodeRabbit schema validation recorded `BLOCKED_REVIEW`.
5. `./dev` hardening verified against every named fault point in §10 (`dev.*`); no command reports green on a missing/unknown/wrong case, a runner failure, or a confused qualification run.
6. All existing gates still green: `./dev test quick/native/qualification`, bare `swift test`.
7. Slice reviews by `deepseek-reviewer` (this plan before implementation — re-requested at revision 2; completed slice after), findings dispositioned; closeout report attests executed work only.
8. STATUS.md, dependency-inventory, NOTICE updated; no push/PR/CodeRabbit action taken.

## 12. Risks / open questions for the reviewer

- Is `Sources/NeedletailTypingProbe` acceptable as the M0-C stand-in for the production composition root (excluded from release, documented; M4 drives the real root)? Chosen: yes — M0-C must not pretend to be product UX.
- Is the functional mode-restoration check (canonical echo after exit) acceptable in place of a screen-state emulator? Chosen: yes — output-byte correctness plus a functional check per TESTING §7, with no terminal emulator built for an 8-line preview.
- Mock/session-provider smoke deferred to M1-D with the §3 table as the maintainer-visible scope reduction (FR-01); confirm this reading of MILESTONES M0-D's "thin smoke" exit note ("a thin M0 smoke is not complete product acceptance").
- Static Swift stdlib vs dynamic runtime bundle: prefer `--static-swift-stdlib`; if it fails for the NIO graph, fall back to a dynamic bundle (copied Swift runtime + `LD_LIBRARY_PATH` launcher) — both documented with the measured binary size and `ldd` manifest; Static Linux SDK remains a later bounded experiment (S17), not a prerequisite.
