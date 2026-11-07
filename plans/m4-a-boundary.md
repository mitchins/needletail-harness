# M4-A Qualification Boundary (frozen reference for M4-B)

Date: 2026-11-07 UTC. Branch `m4-a` @ `29af6f0`
(receipt-only over code tree `32d2226`).
Full evidence: `plans/m4-a-receipt.md` §§1–13.

## 1. Qualification verdict: PASSED (native macOS Intel x86_64)

M4-A is PASSED for Intel x86_64 macOS (macbuild `Builds-Mac-Pro.local`,
Darwin 25.6.0, macOS 26.7.1, Xcode 26.6, Swift 6.3.3).
Final-tree evidence (§13): full keeper battery green in debug;
155 optimized test executions green (`swift test -c release`) across
all 11 G14-gated suites/legs, including D3 15/15, B0Spine 22/22,
C3 13/13; G13 terminal-revive re-verified (B0-F2A 7/7 in `-O`).

## 2. Preserved evidence (do not re-litigate)

- G13 (terminal-revive self-recursion → revive loop, product fix P7):
  receipt §§4–5, 11; re-verified §13.
- G14 (Darwin-debug 512 KiB pool-stack limitation, two mechanisms:
  8 test-process suite gates + 39 child-process per-test gates):
  receipt §§5–6, 11–12; complete `-O` triangulation §13.
- G1–G12 gap inventory: receipt §6. Follow-ups F1–F6: receipt §9
  (none blocking M4-B).
- Linux cross-platform gate: `./dev test offline` green + vendor-check
  green at the qualified code tree (code-identical to receipt HEAD).

## 3. Explicitly NOT qualified

Apple Silicon: compile-only (`swift build --arch arm64`); zero arm64
execution was performed in M4-A's native matrix (receipt §7–8).
arm64 native execution remains an explicit future platform
qualification obligation, not a silent pass. macOS 14 floor remains
declared-but-unproven.

## 4. Maintainer-approved progression

Intel x86_64 qualification satisfies the M4 portability gate;
M4-B (pure presentation/interaction contract) proceeds on the
qualified `32d2226` code tree. M4-B must preserve the Linux gate and
must not regress native macOS behavior.

## 5. M4-A investigation rule

No further M4-A investigation without a demonstrated defect
(failing native test, crash evidence, or toolchain breakage tied to
the qualified tree). Questions about G13/G14/gates resolve to the
receipt sections above, not to re-execution.
