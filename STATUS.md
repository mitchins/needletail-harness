# STATUS — Needletail v0.3

Updated: 12 October 2026 (session 1). Normative sources: COMPLETE-SPEC.md (all parts), DEPENDENCIES.md. This file is the project's single status tracker; the harness does not create a competing one.

## Current position

- **Milestone:** M0 — M0-A and non-GRDB M0-B implemented and evidenced; slice-closeout review pending; M0-C/M0-D remain (replxx PTY feasibility, clean-runtime bundle, CI, CodeRabbit epic review).
- **Plan:** `plans/m0-a-b-plan.md` — reviewed by `deepseek-reviewer` (route `opencode-go/deepseek-v4.1-flash`), disposition READY, receipts in `plans/m0-a-b-receipt.md`. REV-01 satisfied before implementation.
- **Closeout:** `plans/m0-milestone-report.md`.
- **Scope guard:** M0–M3 only, Linux x86_64/Ubuntu 24.04. No remote writes (push/PR not authorized; GitHub remote configured). No macOS work.

## Environment record (M0-A)

| Item | Value |
|---|---|
| Host | Ubuntu 24.04.4 LTS x86_64, kernel 7.0.0-31-generic, 24 cores, 80 GiB RAM (`/` 93% full; build under `/data`) |
| Git | repo `needletail-harness`, baseline commit `86a717b`; untracked packet: COMPLETE-SPEC.md, DEPENDENCIES.md (AppleDouble `._*` files gitignored) |
| Remote | `git@github.com:mitchins/needletail-harness.git` configured; **push/PR NOT authorized this session** |
| Swift | **6.3.3** (swiftly, `/home/mitch/.local/share/swiftly`) — see F-2 deviation |
| Implementer route | `opencode-go/step-5-preview-free` (verified from `opencode models`, opencode 1.18.35) |
| Reviewer route | `deepseek-reviewer` → `opencode-go/deepseek-v4.1-flash` (subagent, edit deny; independent; no secrets copied) |
| Tools | rg 14.1.0, git 2.43.0, sqlite3 CLI 3.45.1; **no `sqlite3.h`** (libsqlite3-dev absent) |
| Permitted scratch roots | `.needletail-dev/` (repo-local evidence), `/tmp/opencode/` (session probe scratch) |

## Findings and decisions

- **F-1 (M0-B, resolved by operator ruling D-2):** GRDB 7.11.1's `GRDBSQLite` system-library target requires `<sqlite3.h>`; builder lacks it. Operator ruled: install `libsqlite3-dev`. **Blocked for this agent:** `sudo` requires a password (PASSWORDLESS_SUDO=no). Operator must run `sudo apt install -y libsqlite3-dev`; until then GRDB is declared-but-not-product-linked (DR-01) and the SQLite-reopen probe is `UNQUALIFIED_ENVIRONMENT` (never skipped-as-pass).
- **F-2 (deviation, D-1):** Operator ruled install Swift 6.4.0. **Not executable:** `swiftly install 6.4` fails — `download.swift.org` returns 404 for Swift 6.4.0 on every Ubuntu release path (2404/2410/2504/2510 checked). Swift 6.4.0 is unavailable for Linux at this time. Deviation: continue on 6.3.3 (all seven candidate pins resolve on it); re-qualify toolchain pin before any release claim. DEV-01 discipline applied (record blocker; no rotation/hack).
- **F-3 (dependency shape):** replxx revision `1f149bfe…` has no `Package.swift` at that ref → not a SwiftPM dependency; must be vendored C/C++ bridge (M0-C, matches DEPENDENCIES.md).
- **D-1, D-2:** see F-1/F-2. Rulings recorded; implementation proceeds on unaffected work.

## Dependency evidence (M0-B, recorded)

- Full 7-pin resolution on Linux: **26-pin transitive graph** (argument-parser 1.8.2, async-http-client 1.36.2, openapi-runtime 1.13.0, subprocess 1.0.1, system 1.8.1, crypto 5.0.0, GRDB 7.11.1; transitives incl. nio 2.104.0, nio-ssl 2.37.5, swift-certificates 1.21.0, http-types 1.8.0).
- Six-of-seven build+link on 6.3.3: PASS (32.3 s warm; probe ran `ok`; links libswift*/libdispatch/libstdc++/libz/glibc). Scratch: `/tmp/opencode/needletail-probe`, logs `/tmp/opencode/probe-build*.log`.
- GRDB build: FAIL with `sqlite3.h` not found (F-1). No fabricated graph, no downgrade.

## Case catalogue

- `cases/expected-index.json`: frozen hand-audited 200-ID expectation (100 product PKG…REAL + 68 UX/DX/PTY + 32 v0.3 delivery; 168 product/UX + 32 delivery), provenance + digest recorded.
- `cases/catalog.json`: normalized catalogue; reconciliation runs both directions vs the fixture and vs Part 10 of COMPLETE-SPEC.md. All not-yet-due entries: `NOT_IMPLEMENTED` / `DEFERRED_BY_PLAN`. No entry may be reported PASS without executed evidence.

## M0-A / M0-B closeout (this session)

- All `./dev` entry points implemented and exercised: `build`, `test quick` (19 tests green), `test native` (4 primitive tests green: SSE framing WIRE-01/02, cancellation NET-05, subprocess dual-pipe PROC-01), `test qualification` (intentional failure detected; 2 skips; 3 parameterized; 1 pass — never a gate), `test case CASE-ID`, `coverage`, deferred-with-reason stubs (integration M2, terminal/pty M4, live M3/M5, offline M0-D).
- Status vocabulary is the official DEVELOPMENT §6 set (DR-06): the SQLite-reopen probe (STORE-01) is `UNQUALIFIED_ENVIRONMENT` while D-2 is open; D-2 itself is `BLOCKED_REVIEW` for the operator.
- Qualification of the runner route (DR-11): Swift Testing `--filter` matches test ID paths, not display names; case IDs are embedded in function names with underscores and `./dev test case` translates hyphens; no invented flags.
- Timings (DR-07): cold test-graph build 70.0 s; warm cycle 4.07 s; slowest test 0.016 s; pure vs native split by command. Raw logs under `.needletail-dev/logs/`.
- Closeout report: `plans/m0-milestone-report.md` (all fields attested; no pending promises).
- Slice review by `deepseek-reviewer`: due at slice closeout per REVIEW.md cadence; packet = closeout report + this file. Recorded receipt after the review returns.
- Review findings DR-01…DR-14 from the plan review: all folded (see plan §13 and receipt).

## Findings and decisions
