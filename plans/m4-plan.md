# M4 Implementation Plan (planning only — no implementation authorized)

Baseline: `main` @ `1ab0aa4` + M3 epic PR #9 (`m3-planning` @ `2a952d9`, do-not-merge).
Authorization boundary: **planning only.** No code, no macOS procurement/config,
no terminal/PTY implementation, no live model traffic, no merge.

Contract sources: COMPLETE-SPEC.md ¶1356–1374 (M4-A…D, exit criteria), ¶918
(pure-before-terminal sequencing), ¶955–957 (portability boundaries),
DEPENDENCIES.md (M4 swift-markdown candidacy), `cases/catalog.json`
(M4-due case families), M3 acceptance (`plans/m3-acceptance.md`, carried
limitations stand — no parity/speedup claims feed into M4 scope).

## 1. Ordering (spec order, no shortcuts)

M4-A → M4-B → M4-C → M4-D. Pure-state correctness (M4-B) precedes adapter
wiring (M4-C), which precedes physical-terminal integration (M4-D). macOS
qualification (M4-A) comes first and re-runs Linux after every portability
change — never the reverse. No slice starts until the previous slice's exit
criteria are independently reviewed.

## 2. Maintainer UX priorities → slice mapping

| Priority | Slice | Notes |
|---|---|---|
| Streaming terminal interface with visible tool activity + outcomes | M4-C, then M4-D | Bounded completed-block parsing, streamed fallback, escaped controls; real PTY proof in M4-D |
| Diff inspection + actionable approval UX | M4-B (pure: diff provenance, approval views) → M4-C/D (render + keys) | Approval semantics unchanged; presentation only |
| Sandboxed autonomous execution as first-class mode | M4-B (mode + queue/hold views) | Grant path and sandbox architecture untouched |
| Explicit reusable grants for ordinary host operation | M4-B (grant views/lifecycle) | No weakening of the host authorization guarantees; views over the existing grant mechanism |
| Session resume, checkpoint visibility, recovery | M4-B (sessions/epochs/checkpoint views) | M3-C checkpoint mechanism as-is; visibility only |
| Completion vs budget-exhaustion vs unresolved differentiation | M4-B (run-outcome views; R4 boundary kind surfaced) | Builds directly on the R4 `completed-budget-boundary` telemetry already shipped |

## 3. Proposed M4-A scope (first slice)

**Goal:** build and run the *unchanged* portable core on Apple Silicon macOS;
qualify package OS floors and native differences; add only required platform
shims. Retain the Linux gate on every change.

**In:**
- Native macOS build of the existing package graph on Apple Silicon; record
  which dependency pins resolve/execute there (DEPENDENCIES.md OS floors).
- Minimal platform shims behind the existing PORT-02 boundary (no `Darwin` /
  `Security` / AppKit / SwiftUI / Combine in Core or Presentation; Foundation
  value types only). Linux-only convenience code stays behind the same boundary.
- Filesystem/process/clock capability recording (case sensitivity, UTF-8 names,
  executable modes, symlinks, process groups, CA roots); an APFS default is not
  assumed equivalent to ext4.
- Re-run the full Linux offline gate after every portability change; a Linux
  regression blocks (PORT-06), no macOS-pass override.
- macOS 14 deployment floor: claimed only with actual compatible
  dependency/runtime evidence; otherwise propose a reviewed minimum.

**Out (explicitly not M4-A):** any terminal/line-editor/ANSI/PTY work (M4-C/D),
`@`/queue/undo/rewind UX (M4-B), swift-markdown qualification (M4-C), cloud
routes (M5), Jev-style classification (candidate for later evaluation, not an
M4 prerequisite), new frameworks, benchmark platforms.

**Exit:** portable core builds + scheduled offline suites pass natively on
Apple Silicon macOS AND Linux stays green; shim inventory + capability deltas
recorded; gaps are named follow-ups, never silent passes.

## 4. Later slices (bounded sketches, planned at their own gates)

- **M4-B — complete use cases in pure state.** Mention completion/preview, queue
  edit/reorder/withdraw, held-state recovery, sessions/agents/models/context/
  epochs views, compact dry-run, diff provenance, undo/rewind flows. Virtual
  clock/IDs + semantic frame fixtures; no terminal required to assert
  correctness. M4-due QUEUE/UNDO/MENTION/NAV/RENDER case rows.
- **M4-C — Markdown/ANSI/replxx adapter.** Qualify the deferred swift-markdown
  0.9.0 pin first (linkage, build-time, binary size, Linux+macOS); on failure,
  scope down to plain styled lines and record it. One output owner + line
  editor, draft retention during stream/resize, stale-callback ignore, escaped
  controls, plain mode. No language lexer framework, no full-screen UI.
- **M4-D — eight PTY scenarios + release-binary wiring smoke.** PTY-01…08 with
  actual key/paste/resize/cancel signals on Linux and macOS after pure+adapter
  gates; catchable-exit vs SIGKILL distinction; TERM simulation vs real
  SSH/tmux spot-check; actual release binary against a synthetic loopback
  provider to catch composition-root/test-only divergence.

**M4 exit (spec ¶1374):** all due UX-MENTION/QUEUE/UNDO/NAV/RENDER, DX, TERM,
PTY obligations pass on the scheduled native matrix; Linux core/cache
contracts stay green; CodeRabbit epic review.

## 5. Guardrails carried into M4

- Host authorization guarantees retained verbatim (grant path, sandbox
  architecture, approval precedence, zero-human-approval discipline from M3-D).
- Incremental slices; independent review per slice (DeepSeek delta + CodeRabbit
  epic at close). Settled M3 decisions (frozen benchmark, scored outcomes, STOP
  verdicts, INVALID_INFRA exclusions) are not reopened.
- Jev-style classification stays a later-evaluation candidate; not designed,
  not prototyped, not a dependency of any M4 slice.
- No new agent framework, scheduler, memory system, MCP/plugin catalogue, or
  benchmark platform. Reuse the M2/M3 machine; M4 is UX + portability.

## 6. Review plan

One focused plan review of this document (blockers: scope creep into frameworks,
weakened authorization boundaries, macOS-first sequencing, terminal-before-pure
inversions). Slice implementation plans (M4-A first) get their own authorizations.
