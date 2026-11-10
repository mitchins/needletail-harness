# M4-C receipt — Terminal Presentation Adapter

Branch `m4-a`. M4-A QUALIFIED, M4-B QUALIFIED (final macOS B6 evidence
complete). Mission: M4-C Markdown/ANSI/replxx integration over the
qualified M4-B pure contracts. No M4-D work; no push/PR/merge (STOP).

## Baseline and code SHA

- Qualified production baseline: `3e9806f` (M4-B QUALIFIED).
- M4-C work base: `fce17a3`.
- M4-C code HEAD: `6e73568cb5b1e30466af8f98c7b9889a4e69540c`;
  receipt HEAD: resolve via `git rev-parse HEAD` (this commit adds
  only `plans/m4-c-receipt.md` on top of the code commit).
- `git diff 3e9806f..6e73568 -- Sources/NeedletailCore/ Sources/NeedletailRuntime/` is EMPTY — no Core/Runtime production change (verified 2026-11-10: empty output, zero stat lines).
- Change set (vs `fce17a3`):
  - `Package.swift` / `Package.resolved`: new `NeedletailTerminal`
    target + `.exact("0.9.0")` swift-markdown edge; CLI gains
    `NeedletailTerminal`+`NeedletailLineEditor`; `Needletail-
    TerminalTests` gains `NeedletailTerminal`+`NeedletailPresentation`.
  - `Sources/NeedletailTerminal/` (NEW, 11 files): DisplaySanitizer,
    TerminalCaps, MarkdownRenderer, MarkdownVisitor, ANSISpans,
    DiffRenderer, TerminalOutputOwner, ComposerBridge, ChatLoop,
    DeltaTapTransport, ReplxxApprovalGateway.
  - `Sources/NeedletailCLI/ChatCommand.swift` (NEW) + `NeedletailCLI.swift`
    (registers `chat`).
  - `Sources/NeedletailPresentation/Render.swift` (additive StyleRole
    cases), `UIAction.swift` (additive `InputAction.replaceDraft`),
    `UIReducer.swift` (additive replaceDraft case) — pure, tested.
  - `Sources/NeedletailLineEditor/LineEditorSession.swift` (seam
    extension: modify/key/preload/clear/insertNewline — thin, no policy).
  - `Tests/NeedletailTerminalTests/` (10 files: 9 suites +
    ScalarAsserts helper),
    `Tests/NeedletailPresentationTests/ReplaceDraftTests.swift`,
    `Tests/NeedletailConfigTests/ImportGateTests.swift` (skip extended
    to ChatCommand.swift — same rationale as RunCommand),
    scalar-level hardening of 3 M4-B suites' lone-Cf oracles
    (MentionGrammar/UndoDiffViews/SemanticFrame — test-only, strictly
    stronger; macOS `String.contains` is vacuous on lone invisibles).
  - `plans/m4-c-plan.md` (rev 3 + clarifications, DeepSeek READY).

## Dependency and native-linkage findings (C0 hard gate: PASS)

- Adopted `swiftlang/swift-markdown @ 0.9.0` (`25cb61d34820`) +
  transitive `swiftlang/swift-cmark @ 0.9.0` (`08ddb528923c`, cmark-gfm
  C source). Graph: nothing else (no plugins). Spelling `.exact`,
  lockfile committed. Satisfies DEPENDENCIES.md conditional-adoption
  rule (actual graph, native linkage, build-time/binary cost,
  Linux+macOS behavior before selection).
- Scratch qualification (`/tmp/mdqual`, main graph untouched):
  resolves to the two pins; Linux x86_64 build green; incremental
  rebuild ~2.3 s wall; linked debug binary 4.6M (Markdown + cmark
  statically linked — the floor of the binary contribution).
- Linux gates: `swift build --target NeedletailTerminal` green;
  `swift build -c release --target NeedletailTerminal` green (43 s
  incr); full `swift build` green; release `needletail` product
  links: `.build/release/needletail` 93M.
- macOS gates (Builds-Mac-Pro.local): debug `swift build --target
  NeedletailTerminal` green (77 s); release link green (106 s);
  Markdown behavior smoke green (parse + ZWJ + Cf battery via the
  `pipework` replica + the `finalStreamCfBattery` suite test).
- Binary delta (release, stripped): base `fce17a3` 85M → M4-C
  93M (+8M: swift-markdown + cmark-gfm + NeedletailTerminal + chat
  command, statically linked). Debug CLI 56M → 137M (debug info
  for cmark C++ + Markdown Swift dominates). Scratch floor
  (Markdown+cmark alone, debug): 4.6M.
- `NeedletailPresentation` stays dependency-free and pure (no
  Markdown edge there); the ANSI span writer remains ours; no general
  Markdown parser built; no unrelated terminal framework.

## Implemented capabilities

C1 rendering: completed-block `Document(parsing:)` walk to role
spans (headings, strong/emphasis, code, fences with language,
quotes, ordered/unordered/task lists, tables, thematic breaks; raw
HTML/directives/custom nodes as sanitized literal); unified-diff
prefix roles (`+++`/`---`/`@@` hunk, `+` add, `-` del); tool
receipts/warnings/errors via tone roles; text-first links (never
OSC-8); truncation with the exact SPEC ¶805 marker (256 KiB blocks,
transcript locator). Canonical bytes untouched (store/transcript
authoritative). Partial input never parsed: transient progress only,
committed-block oracle identical across chunk splits.

C2 output owner: single lock-domain instance, dedicated writer
thread, pending droppable quota (512 items / 1 MiB, tail + marker),
control lane (cap 64 drain-priority, NEVER dropped), stale
generation drop, 10 Hz progress coalescing with clear-noop rule,
NO_COLOR/dumb/non-TTY zero-ANSI routing. Request-scoped liveness
(`liveRequests`): progress registers, completion requires, cancel/
submit/terminal-outcome clears — the generation-gated finalize.

C3 composer: replxx seam (modify/mirror, key bindings, bracketed
paste, preload, clear/newline buffer edits with trampoline mirror
sync); reducer-exact mirror (prefix/suffix edit script, paste
heuristic for multi-line/large inserts per SPEC ¶751);
revision-keyed completion cache (sync serve gated on live revision
+ query); CommandIDStore (retry reuses ID); slash map
(/steer//queue//undo <group> (PARTIAL: latest-eligible deferred)/
/rewind//compact(dry-run only)//cancel//keys; /preview//diff/etc.
explicitly deferred; unknown → usage error); key map (Ctrl+C busy
cancel / idle clear / idle-empty hint; Ctrl+J newline into live
buffer; Esc dismiss); single-owner approval (gateway + loop share
one resume-once box; confirm serialized through readLine with
save/restore; sandbox rows display-only; explicit isSandbox, never a
type-test).

C4 portability: `TerminalCaps.fromEnvironment` (NO_COLOR
present-and-non-empty; TERM=dumb; non-TTY plain; width via
explicit/COLUMNS/ioctl, clamp ≥20); plain mode identical semantics,
zero ANSI; `needletail run` JSONL contract byte-unchanged (new
`chat` command only; TTY-gated with headless refusal).

`needletail chat` (composition root): run-mirrored config/store/
gates/transport composition; DeltaTapTransport wrap; sandbox vs
interactive gateway; trace tee; SIGINT→cancel; effect translation
(submit/followUp/steer/edit/withdraw/resume/cancel/reorder/fork/
previewFile-read/completions-walk/queue-inspect/undoPreview with
real preimages via artifactRecord; deferred inspect/attach/runUndo/
grant intents are explicit notices, never silent).

## Test and acceptance-case mapping (C5)

1. Draft/cursor preservation: mirror convergence + replaceDraft
   boundary unit tests; confirm consume + follow-up-submit loop
   tests (decision line never submitted; mirror reset proven by
   clean follow-up); live restore covered at the PTY layer (M4-D).
2. Chunk splits: determinism + trailing/leading-newline
   normalization + partial-prefix no-crash (no partial-parse API
   exists — committed render is a pure function of completed
   text).
3. Injection: Cf battery (all Cf classes → U+FFFD, only ZWJ
   survives) + C0/C1/ESC/OSC/TAB/CR/NUL + final-byte-stream SGR
   framing asserts, all at scalar level (ScalarAsserts — see
   stdlib divergence note).
4. Bounds: droppable quota tail+marker, control never truncates
   (100 records ordered), tap 1 MiB quiet + once-marker, progress
   coalescing, inbox bound inherits actor delivery-queue caps.
5. Stale suppression: revision-gated completion serve, generation
   drop, request-scoped finalize (unknown completions drop), cancel
   deny, resume-once.
6. Unicode: combining/ZWJ/emoji preserved, cluster-safe wrap
   (grapheme-count rule; wcwidth out of scope — limitation).
7. Plain mode: NO_COLOR/TERM=dumb/non-TTY → identical semantics,
   zero ANSI (incl. progress suppression under NO_COLOR).
8. No duplicate submission: retry reuses command ID (loop test);
   Core admission idempotency unchanged.
9. Core/Runtime unchanged: full Linux offline aggregate green;
   `run` headless regressions green; import gates green.
10. Linux + qualified macOS: suites below, debug and `-O`
    reported separately (no G14 concealment).

## Linux/macOS results

- Linux: `NeedletailTerminalTests` 74/74 (13 suites);
  `ReplaceDraftTests` 4/4; `NeedletailPresentationTests` 100/100
  (UX-RENDER-01…08 pure green); `quick` 267+100+77+28 green;
  `./dev test offline` aggregate green (OFFLINE OK).
- macOS (Builds-Mac-Pro.local, final tree): debug
  `NeedletailTerminalTests` 74 tests / 13 suites — 73 pass; the
  sole failure is pre-existing PTY-05 (`canonicalEchoRestored`,
  ssh-session PTY environment; fails identically on the untouched
  B6 tree `~/m4b`, unrelated to M4-C). All M4-C suites green
  incl. the Cf battery at scalar level, confirm flow, stale/revision
  gates, hostile-candidate filter. Release link check PASS
  (106 s). Behavior smoke PASS (pipework replica: ZWJ + full Cf
  battery at scalar level). No `-O` mac run (debug evidence +
  Linux release link + G14-clean shallow tests; M4-D owns
  release-binary smoke).
- Pre-existing mac failures (NOT M4-C — reproduce on the
  untouched B6 tree `~/m4b`): PTY-05 feasibility
  (`canonicalEchoRestored`, ssh-session PTY environment).
- macOS stdlib divergence (found during C5.3): `String.contains`
  with a lone invisible scalar (Cf) returns FALSE on macOS
  Foundation even when present (Linux finds it). Security oracles
  MUST assert at `unicodeScalars` level — done via
  `ScalarAsserts.hasScalar` (also hardened three B5-C gateway
  assertions that were vacuous on mac). Multi-scalar patterns
  unaffected.
- G14: debug-stack guard (64) on block AND inline recursion;
  adversarial test depths trimmed for Darwin-debug (120);
  no new debug-only gates. The pre-guard tree SIGBUS'd the mac
  debug runner (signal 10) — resolved by the guard + trims.

## Security and display-control counterfactuals

- Model/tool/file bytes reach the terminal ONLY via: tap buffer
  → DisplaySanitizer → renderer spans → SGR framing; or
  projections → terminalSafe → semantic spans → SGR; or owner
  emitText/progress (sanitized inside). No raw path to the writer
  (audited: owner writer ← encoded spans/sanitized text only;
  `LineEditorSession.emit` requires sanitized input — sole
  production caller is the owner).
- Cf deny-by-default (only U+200D), C0/C1→`\u{hex}` (NUL→`\u{0}`
  fixes `strlen` truncation), ESC-introducer neutralization,
  TAB→8-stop, CR→`\u{d}`, Zl/Zp neutralized, links text-first
  (no OSC-8 emitted anywhere — renderer has no hyperlink path).
- Stale/cancelled output drops (generations + liveRequests);
  approval cannot auto-fire (explicit y/yes; EOF/empty/anything
  else denies; cancel denies; loop-exit denies).
- No second conversation state (tap display-only, bounded,
  dropped at run_finished); no queue/grant mutation from terminal
  code (bridge emits intents; reducer pure; actor owns grants;
  sandbox display-only; isSandbox explicit).
- No duplicate operator submission (commandID reuse + Core
  admission idempotency); newline/paste never auto-submits
  (pasteLiteral literal; Enter on empty ignored).

## Known limitations (carried, not hidden)

- wcwidth: East-Asian wide/emoji display width may misalign
  (grapheme-count layout per M4-B; M4-D or follow-up).
- Chat attach (`@` tokens display-respected, not attached —
  fd-pinned capture edge deferred); undo RUN stays headless
  (preview wired with real preimages); inspect legs beyond
  queue deferred with explicit notices; `/preview` deferred
  (SPEC ¶755 — not diff); bare `/undo` PARTIAL (no
  latest-eligible resolution); triggering `/compact` has no
  intent (dry-run only); Tool receipts/diff-hunk renderers
  await tool-display wiring (status/queue lifecycle visible).
- Confirm modal: clear-line-then-y/N (prompt-guided; armed
  Ctrl+C clears even mid-run, never cancels); line typed while
  armed that isn't y/yes denies fail-closed (post-arm keystrokes
  discarded on restore — documented); confirm disables neither
  history nor bracketed paste (M4-D PTY acceptance); cursor
  restores at end (mirror converges); SIGINT-while-armed denies
  and the next line submits normally.
- Undo preview scans the first 10,000 session records for group
  reconciliation (older groups report "no reconciled group" —
  limit documented); candidate walk skips symlinked files and
  caps previews at 64 KiB files / 500 walks / 10 candidates.
- History pollution: decision lines may enter replxx history
  (M4-D hygiene).
- `liveRequests`/emitted-map bounded by construction (actor
  queue caps 512/4MiB inherited; emitted-ID map capped 1024).
- Chat runs unbounded by live-request budget (operator watches;
  headless budget path untouched).
- Pre-existing mac PTY-05 environment failure (B6 tree too).

## Independent review dispositions

- Plan rounds 1–3 (DeepSeek): 10 → 5 → 5 blockers, all closed in
  rev 2/rev 3/clarifications; round 4 verdict READY.
- Code review A (implementation): 8 blockers + caveats. All
  addressed: shared resume-once box (gateway+loop); preload (not
  set_state) restore + y/Enter protocol (no y/n binding);
  Ctrl+J/Ctrl+C-live-buffer edits via set_state + trampoline
  mirror sync; undo preimages via artifactRecord; request-scoped
  liveness gate; armed-under-lock; owner single lock domain +
  deinit no-join; inbox bound documented (actor caps);
  duplicate previewFile removed; inspect(queue) threads
  isSandbox; chat omits live budget (documented); approval
  prompt shows identities/paths; DiffRenderer.receipt used for
  notices; collectInline depth-guarded; oracle honesty fixes
  (chunk determinism, confirm effects-empty, stale gate test,
  encode boundary doc, final-stream Cf battery).
- Code review B: NEEDS-CHANGES (5 blockers) — all closed in the
  fix batch (see dispositions above).
- Review C (fix-batch verification): NEEDS-CHANGES (3 blockers:
  live-path completion filter, tautological chunk oracle,
  shared-box same-value test) — all closed: single
  `isDisplaySafePath` predicate on the live serve path (+LF
  rejection, loop-level hostile-cache test); oracle reframed as
  determinism + newline normalization + partial no-crash;
  recorded-on-invoked-value sink proof. Caveats folded (revision
  gate + clears, dumb-inline drop, finish→box deny, CLI dropAll,
  symlink skip, notice tones, scalar oracles suite-wide).
- As-built deltas vs plan rev 3 (behavior-preserving): armed
  Ctrl+C always clears (even mid-run); cancel-before-store
  resumes late continuations immediately; confirm restore via
  preload (cursor end, mirror converges); SIGINT-while-armed
  denies the approval and the next line submits normally
  (fail-closed, no wedge).
- Reviewer-noted pre-existing items preserved: `.needletail-dev/
  m4a-final/run-b6final.sh` working-tree modification predates
  M4-C (B6 staging, uncommitted — untouched by this change set).

## M4-D prerequisites (M4-C does NOT own)

- PTY-01…08 end-to-end; physical keyboard/paste/resize/
  cancellation; ssh/tmux spot checks; full release-binary
  composition smoke; terminal lifecycle and cleanup acceptance
  (incl. raw-mode restore paths, history hygiene, signal
  behavior, budget policy for interactive runs).
- Tool-display wiring (receipts/hunks into scrollback), attach
  edge (AttachmentCaptureService), deferred inspect legs, undo
  RUN surfacing, `/preview` file-preview intent, latest-eligible
  `/undo`, key-binding behavioral tests, completion Tab-insert
  exactness (Enter-accept path).

**STOP** after M4-C qualification per mission: no M4-D/D
implementation, no live model benchmarking, no additional agent
framework, no desktop application, no push/PR/merge without
separate authorization.
