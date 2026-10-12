# M0-C / M0-D plan review receipt

Review type: minor-milestone PLAN review (pre-implementation, REV-01 gate), revision 2.
Reviewer alias: `deepseek-reviewer` · Actual model route: `opencode-go/deepseek-v4.1-flash` (verified from `~/.config/opencode/opencode.jsonc`; independent of the implementer route `opencode-go/step-5-preview-free`). No credentials copied.

## Round 1 (revision 1, plan sha256 `9fb04d02f3d926dd860730976e5433d53276bc034e93cc91a944a65598615496`)

Disposition: **NEEDS_EVIDENCE** — 11 findings (FR-01…FR-11). Must-fix: FR-01, FR-02, FR-05.

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| FR-01 | Major | M0-D dropped two of three named clean-host executions (offline config inspection, synthetic/mock smoke) | FOLDED: added `doctor` (offline inspection, git/rg capability statements) + hermetic smoke trio; mock-session smoke deferred to M1-D with a maintainer-visible scope-reduction table (plan §3) |
| FR-02 | Major | Catalogue status wording ("partial") conflicts with the enforced due-milestone rule; risks fabricated CI evidence | FOLDED: explicit status-transition table; only `status_detail` annotations; DEV-03/REV-05..08 annotated pending remote authorization |
| FR-03 | Major | Bundle runtime linkage unspecified (Swift runtime would not exist on the clean host) | FOLDED: static-stdlib-preferred/dynamic-fallback layout stated; smoke asserts toolchain absence |
| FR-04 | Major | Completion callback registration without an invocation oracle | FOLDED: oracle asserts the callback fires and reports ≥1 candidate; full preview deferred to M4 |
| FR-05 | Minor | Stale baseline SHA; uncommitted prototype at review time | FOLDED: baseline `c2b3b13`; prototype-handling note (clone never committed) |
| FR-06 | Minor | `test case` guard could pass on bogus/prefix IDs | FOLDED: exact catalogue-ID validation + wrong-case guard |
| FR-07 | Minor | Floating docker tag; no network assertion | FOLDED: digest-pinned image + `--network none`, digest recorded |
| FR-08 | Minor | Prepared-but-inactive CI could hollow the gate | FOLDED: local command dry-run, least-privilege/fork rules, CodeRabbit validation recorded BLOCKED_REVIEW |
| FR-09 | Minor | `NeedletailLineEditor` target not in the SPEC §4 map | Accept-with-documentation: architecture note in plan §7 |
| FR-10 | Minor | Retained-evidence and vendored-integrity gaps | FOLDED: logs under `.needletail-dev/logs/`; `./dev vendor-check` + `SHA256SUMS-vendored` |
| FR-11 | Suggestion | Probe-vs-composition-root divergence; "submitted" wording | Accept-with-documentation: probe labeled the M0-C stand-in; assertions concern retained bytes |

## Round 2 (revision 2, plan sha256 `8b11409233ce16c85b4ed44477f67bffec94d09d4bebe364d800e6c79172beaf`)

Disposition: **READY** (no new blocker). Two optional fold-ins accepted during implementation: DX-08's existing `status_detail` was appended to (not overwritten), and `ThirdParty/` was added to `.gitignore`.

## Implementation-time corrections of note (recorded, not review findings)

- `replxx_input` returns NULL on Ctrl+C abort as well as EOF: the probe treats it as a cancel and re-enters input; the scenario's exact-draft oracle runs before any completion invocation because Tab inserts the common prefix.
- SIGUSR1 inherited the Swift Testing runner's blocked signal mask (fork inherits it): the probe unblocks it via `pthread_sigmask` in `nt_install_usr1_pipe`. This was found by scenario failure, fixed, and the scenario then passed 5/5 runs plus a wrong-expectation oracle probe.
- Static Swift stdlib linking fails on Swift 6.4.0 for this graph (`Synchronization._MutexHandle` undefined) — recorded as a toolchain finding; the dynamic bundle is the documented M0-D path.
