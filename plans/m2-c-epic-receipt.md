# M2-C Epic Receipt — READY TO MERGE (required gates passed; A2 flake documented; merge awaits authorization)

Authoritative candidate: branch `m2-c-planning`, qualified code
head `fe8d631` (CodeRabbit whole-system review fixes, all §2 evidence
re-measured at this head — see §8; prior qualified heads `be2620a`
(full-lane evidence) and `26496db` (DeepSeek final APPROVED) are
ancestors with docs-only deltas between them except the noted fixes).
Closeout commits after the qualified head are docs-only
(this receipt, STATUS.md). Final HEAD contains everything; see §8.
No push, PR, merge, or tag performed. No live-model qualification,
no M2-D/M3 work. Branch unpushed by direction.

## 1. What M2-C claims (and does not)

M2-C connects the C0 validated execution contract, the C1 qualified
native process runner, and the M2-A/B durable operation ledger, and
composes the result into the production `needletail run` binary behind
`--workspace --allow-exec` (default off; `--trusted` stays
scripted-demo-only; `--sealed` stays tool-free).

Certified by native evidence (all green; see §2):
- Approved command executes once under the approved identity; its
  stdout/stderr are durably recorded as content-addressed artifacts;
  completion receipts, truncation/discard counts, and timeout/cancel
  outcomes are durable and truthful.
- Substitution, wrong-cwd, unapproved, ungranted, malformed,
  credential-polluted, and capability-denied invocations never execute.
- Intent persistence failure prevents spawn; completion persistence
  failure leaves an unresolved hold; crash/reopen never replays;
  no automatic retry, anywhere.
- Bounded capture (32 MiB/stream), bounded spill-lease accounting
  (schema v4), per-call and global quotas enforced before spawn and
  before publish; no SQLite transaction spans an exec or an await.
- Native `run:tool-exec` receipt on every exec path, in JSONL and in
  the provider-facing transcript; execution remains Linux-only
  (`/proc/self/fd`); `--sealed` runs stay tool-free.
- Explicitly NOT claimed: production model-directed exec (gated off by
  default; separate authorization required), Darwin exec support,
  non-exec behavioral changes, M2-D/M3 scope.

## 2. Green evidence at the candidate head

- `C2ExecDurableTests`: 41/41 (incl. no-retry first-attempt run).
- `C3ExecQualificationTests`: 18/18 (real binary + loopback SSE + PTY).
- `C1QualificationTests`: 23/23. `C1ProcRunnerTests`: 3/3.
- `e2e` lane (13 suites incl. C2+C3): 231/231.
- `native` lane: 192/192. `timing`: 8/8. `quick`: green except one
  pre-existing A2 contention flake (fails ~50% on the base commit too;
  unrelated to this slice — verified by clean-tree comparison and by
  stash-comparison of the fix delta).
- M1-D HEAD cases, C0 actor suites, StateTests: green.
- Known environmental flakes (not evidence against): A2 contention
  (pre-existing), actor bare-yield tests under 300+ load (verified
  identical on clean tree).

## 3. Counterfactual probes (each fails when its protection is removed)

- Digest substitution before spawn → pre-dispatch conflict, never
  executed (C2).
- Cwd replacement / absolute cwd → conflict/invalid-arguments,
  never executed (C2).
- Missing approval / missing grant → conflict/denied, never spawned (C2).
- Malformed argv / credential overlay → invalid-arguments, never
  dispatched (C2 + C3 binary).
- exec-error pipe: ENOENT/EACCES/ENOEXEC classified pre-dispatch;
  marker-without-EOF and EOF-without-marker classify uncertain,
  never success; post-marker SIGSTOP/SIGKILL classify started/failed
  or timeout/unknown, never success (C2).
- Intent-store failure → no spawn; completion-store failure →
  unresolved hold, no retry, gate blocks rerun (C2 actor tests).
- Two-stream and identical-digest publish; zero-byte release;
  boot-ID mismatch reclaim; TTL reclaim; unreadable boot-id skips
  (C2 store tests).
- Cancellation during grant/spawn/deadline → CancellationError or
  timeout/unknown, never success and never a converted preDispatch
  (C2 + C3).
- Forged spill handles rejected; arbitrary unlink refused (C2).

## 4. Durable record traces (representative)

- Approved exec: intent + done result + artifactPublished + transcript
  agree; `readArtifact` returns exact child bytes; no lease rows or
  `.tmp-lease-` files remain (C2 actor test asserts all three).
- Crash: intent-only record reconciles to unmatched-mutating + hold;
  reopened run is blocked by the cross-run gate (C2 + C3).
- Timeout/deadline and cancellation map to started/unknown + hold;
  publish/grant failures map to pre-dispatch typed failures
  (no spawn) or timeout/unknown (post-spawn).
- All spill leases are per-stream and boot-qualified; grant, publish,
  and release are fenced; schema migrates v3→v4 with pre-existing
  records, artifacts, byte usage, and indexes intact (C2).

## 5. Recovery outcomes

- Startup sweep reclaims crashed/other-boot leases and row-less
  staging files (TTL + boot-id), never touching live leases.
- Reopen never auto-executes; unresolved markers gate fresh work.
- In-memory spill mirror + default store refusal keep
  non-production stores fail-closed.

## 6. Reviewer findings and disposition

- DeepSeek C2 review (116ec6b): NEEDS-CHANGES (4 High + Mediums).
- DeepSeek delta disposition (3a42908): punchlist partially closed.
- DeepSeek C3 review (first round, at 7504896): NEEDS-CHANGES with
  1 Blocker (B1) + 8 Majors (M1–M8), ALL addressed in-tree with
  regression coverage — bounded artifact lock with cancellation,
  NC-9 complete on all exec paths (incl. validation/failed/cancelled
  variants), secondary artifact IDs, receipt truthfulness (reducer
  verdict, not raw outcome), terminal-guard narrowing,
  writeSpillFile fstat + name binding, errno-capture ordering,
  no test-only code in the child path post-fork, STATUS/docs updates.
- DeepSeek C3 re-review (fix delta 7504896..be2620a): NEEDS_CHANGES
  with exactly one open Major — the M2 held-branch receipt in
  `completeCancelledPending` (SessionTransition.swift:2270) reported
  the raw executor outcome for late completions after cancel;
  fixed at 26496db (status forced to the reducer verdict "unknown",
  reducer-level regression test `lateExecSuccessAfterCancelReadsUnknown`
  added and green). B1/M1/M3–M8 confirmed CLOSED, no Blocker open.
- DeepSeek C3 final verification (fix delta be2620a..26496db):
  **APPROVED** — M2 confirmed closed (held-branch receipt reports
  the reducer verdict; contradictory-outcome sub-cases covered;
  regression test verified to fail pre-fix). Nothing else open.
  C3 slice review is COMPLETE.
- GLM targeted audit (process identity/signalling/reaping):
  C1 guarantees stand; no new false-negative or leak paths
  introduced; remaining notes documented as accepted deviations.
- CodeRabbit whole-system review (PR #7): CHANGES_REQUESTED with 21
  inline findings (2 Majors, 15 Minors, 4 Trivial). Reconciled at
  `fe8d631`: 18 fixed — both approval-display Majors fixed fail-closed
  (argv elision removed; batch truncation replaced by typed
  invalid-arguments refusal); pre-dispatch refusal receipt built with
  the canonical helper; probe entry cap removed (deadline-only
  bound); cwd identity maps required to agree; outer exec deadline
  +15s slack so the runner keeps its timeout classification; cwd fds
  keep CLOEXEC; spill rootFD cleanup fenced; InMemory mirror enforces
  recordCap, bound names, and lease existence; exec deadline default
  honors the advertised max (1800); nested argv/env schemas +
  envelope test; 7 test-fidelity fixes (consult fixture, deleted
  tautological probe, real pipe-buffer flood, retry-attempts
  comparison, advertisement assertion, prompt-readiness signal,
  file-list regeneration).
  Skipped with documented rationale (fail-closed or unreachable on
  qualified platforms; 3 skips total, 2 of them explicitly withdrawn
  by the reviewer on re-review): anchored-walk unification
  (digest-binding fail-closes any divergence — withdrawn),
  non-Glibc lock clock (Linux-only execution contract — standing
  skip), gateway char-vs-byte truncation (both construction paths
  now fail closed, truncation unreachable — withdrawn),
  Sonar MAJOR (vacuous ternary) fixed. SonarQube quality gate PASS
  on the fix head (re-run green).
- Verdict sought: READY FOR M2-C EPIC REVIEW. "C2 independently
  APPROVED" is NOT claimed (per mission rule).

## 7. Accepted deviations and residual risks (documented, not hidden)

- Pre-dispatch failures (conflict/invalid-arguments/denied) throw
  typed errors without recording an exec identity: the refusal is
  deterministic and no side effect exists; the durable record carries
  the refusal. No silent execution is possible on these paths.
- The `/proc/self/fd` execution path is Linux-only; Darwin builds
  fail exec composition closed (documented; Darwin CI is a follow-up).
- The artifact lock uses bounded acquisition (10s grant / 60s
  publish default); a wedged holder fails closed with typed
  contention (never hangs, never fabricates). TTL sweep bounds
  orphaned leases. Pre-existing store semantics otherwise unchanged.
- C2 test retries apply ONLY to the safe-direction probe-flake
  signature (timeout + exit-0); a `NEEDLETAIL_C2_NO_RETRY` knob
  supports first-attempt measurement (41/41 green first-attempt).
- Known pre-existing flakes (A2 contention, actor bare-yield tests
  under extreme load) are environmental and unchanged by this slice;
  verified identical on the clean base tree.
- `plans/m2-c-plan.md` remains REV12 (planning artifact); this
  receipt + STATUS.md record the implementation closeout.

## 8. Exact SHAs, files, and next step

- Baseline: `main` @ `db3c239`.
- C0: `fa69525`. C1 head: `5a1763b`.
- C2 base: `116ec6b`; C2 hardening: `3a42908`.
- C3 implementation + review follow-ups: `7938925`, `3ed1326`,
  `d676b20`, `14255e2`, `be2620a` (qualified; full-lane §2 evidence
  measured here), `26496db` (DeepSeek final APPROVED: M2 held-branch
  receipt fix + regression test), `fe8d631` (qualified code head:
  CodeRabbit whole-system review reconciliation — 2 approval-display
  fail-closed Majors, probe/lock/fd hardening, InMemory contract,
  exec deadline ceiling, nested argv/env schemas, 7 test-fidelity
  fixes; all lanes re-measured green at this head: C2 41/41 no-retry,
  C3 18/18, C1 23+3, e2e 231/231, native 192/192, timing 8/8,
  StateTests 105/105, quick green except pre-existing A2 flake).
  Closeout commits after the qualified head touch only this receipt
  and STATUS.md.
- Changed files (vs `db3c239`, regenerated from
  `git diff --name-only`): `Sources/NeedletailCore/ExecContract.swift`,
  `Sources/NeedletailCore/SessionActor.swift`,
  `Sources/NeedletailCore/SessionEvent.swift`,
  `Sources/NeedletailCore/SessionState.swift`,
  `Sources/NeedletailCore/SessionStore.swift`,
  `Sources/NeedletailCore/SessionTransition.swift`,
  `Sources/NeedletailCore/ToolAdvertisement.swift`,
  `Sources/NeedletailCore/ToolValidator.swift`,
  `Sources/NeedletailRuntime/ExecRunner.swift`,
  `Sources/NeedletailRuntime/GRDBSessionStore.swift`,
  `Sources/NeedletailRuntime/NativeToolExecutor.swift`,
  `Sources/NeedletailRuntime/TerminalApprovalGateway.swift`,
  `Sources/NeedletailRuntime/ToolDeadlines.swift`,
  `Sources/NeedletailTestSupport/InMemorySessionStore.swift`,
  `Sources/NeedletailCLI/RunCommand.swift`,
  `Sources/NeedletailProviders/ChatTransport.swift`,
  `Tests/NeedletailPrimitiveTests/C2ExecDurableTests.swift`,
  `Tests/NeedletailPrimitiveTests/C3ExecQualificationTests.swift`,
  `Tests/NeedletailPrimitiveTests/C1ProcRunnerTests.swift`,
  `Tests/NeedletailPrimitiveTests/C1QualificationTests.swift`,
  `Tests/NeedletailPrimitiveTests/C0ExecContractTests.swift`,
  `Tests/NeedletailPrimitiveTests/B2ClosureTests.swift`,
  `Tests/NeedletailPrimitiveTests/B5CEndToEndTests.swift`,
  `Tests/NeedletailPrimitiveTests/CrashMatrixTests.swift`,
  `Tests/NeedletailPrimitiveTests/RecordCodecTests.swift`,
  `Tests/NeedletailActorTests/ActorApprovalTests.swift`,
  `Tests/NeedletailActorTests/C0TwoPhaseActorTests.swift`,
  `Tests/NeedletailStateTests/CancellationTests.swift`,
  `Tests/NeedletailStateTests/ApprovalPolicyTests.swift`,
  `Tests/NeedletailProviderTests/ToolAdvertisementTests.swift`,
  `Tests/NeedletailProviderIntegrationTests/M1DCasesTests.swift`,
  `STATUS.md`, `dev`, `.github/scripts/merge-xunit.py`,
  `plans/m2-c-epic-receipt.md` (this file), `plans/m2-c-plan.md`.
- Test totals at candidate: C2 41/41, C3 18/18, C1 23+3,
  e2e 231/231 (13 suites), native 192/192, timing 8/8,
  StateTests 105/105, quick green (1 pre-existing flake),
  M1-D HEAD cases green.
- Stop. No push, PR, merge, live-model run, M2-D, or M3 work.
- Next (separately authorized): CodeRabbit whole-system review of
  this branch; production exec enablement decision; M2-D scoping.

## 9. Phase 4 — exact-head gates and merge recommendation (PR #7)

Exact head: `m2-c-planning` @ `9963b13` (qualified code `fe8d631`
+ docs-only receipt/STATUS). All gates measured on this exact head:

- GitHub CI `offline build and tests (Linux x86_64)`: PASS (39m34s,
  run 40650994573).
- `release bundle smoke (clean host)`: PASS (6m2s, same run).
- SonarCloud Code Analysis: PASS. SonarQube Cloud quality gate:
  PASS (prior C-Reliability failure cleared by the vacuous-ternary
  fix in `fe8d631`).
- CodeRabbit whole-system review: PASS (check green); all 21 inline
  threads reconciled — 18 fixed in `fe8d631`, 3 skipped with
  documented rationale (the 2 safety-relevant skips explicitly
  withdrawn by the reviewer on re-review; 1 standing skip:
  non-Glibc lock clock, unreachable on the Linux-only execution
  path); per-thread replies posted, summary comment on the PR.
- GitGuardian Security Checks: PASS.
- DeepSeek C3 slice review: FINAL APPROVED covering `be2620a..26496db`
  (the M2 held-branch receipt fix) — nothing open within that scope.
  The later `fe8d631` CodeRabbit-reconciliation delta is NOT covered
  by DeepSeek; it is covered by CodeRabbit whole-system review
  (PASS), full local lane re-measurement, and exact-head CI.
- Local re-measurement at `fe8d631`: C2 41/41 no-retry, C3 18/18,
  C1 23+3, e2e 231/231, native 192/192, timing 8/8, StateTests
  105/105, quick green except the pre-existing A2 contention flake
  (verified identical on clean base and by stash-comparison).

Residual limitations (unchanged, documented in §7): Linux-only exec
path; no production model-directed exec until separately authorized;
no live models; pre-existing A2/A5-1 environmental flakes reported
separately, never counted as passes.

**Merge recommendation: READY TO MERGE.** No Blocker or Major open
in any review; all required exact-head gates passed (quick retains
one documented pre-existing A2 contention flake, verified identical
on the clean base — reported separately, never counted as a pass);
evidence complete with exact SHAs. Merge itself explicitly NOT
performed — awaiting operator authorization per mission stop rule.
No M2-D/M3 work begun.
