# M4-C plan — Terminal Presentation Adapter (rev 3)

Branch `m4-a` at `fce17a3` (M4-B QUALIFIED, final macOS B6 evidence
complete). Baseline production: `3e9806f`. No M4-D work, no push/PR.

Addresses DeepSeek round-1 review (10 blockers B1…B10 + caveats);
dispositions at the end.

## C0 findings (unchanged)

- `NeedletailPresentation/Render.swift`: pure semantic frames, never
  ANSI; `terminalSafe` boundary (`NeedletailCore/TerminalSafety.swift`).
- `NeedletailPresentation/UIReducer.swift` + `UIState.swift` + `UIAction.swift`:
  pure reducer; adapter emits `UIAction`, renders `UIState`/`RenderFrame`.
- `NeedletailLineEditor/LineEditorSession.swift`: thin seam (`readLine` /
  `emit` / one completion callback). The C API additionally offers
  `replxx_set_modify_callback`, `replxx_bind_key` (+`_internal`),
  `replxx_enable_bracketed_paste`, `replxx_get/set_state`,
  `replxx_set_preload_buffer` (`Sources/CReplxx/replxx/replxx.h:248-255,
  362,394,451,464,591-592`) — C3 extends the Swift seam to expose them.
- `NeedletailRuntime/FileHandleUISink.swift`: locked write-through JSONL;
  `needletail run` headless contract untouched.
- G13/G14 per M4-B receipt: new debug tests avoid deep value-type
  recursion; any Darwin-debug gating is test-only and reported
  separately (never concealed by `-O` passes).

## Dependency decision: swift-markdown 0.9.0 CONDITIONAL

Scratch qualification `/tmp/mdqual` (main graph untouched): resolves
to `swift-markdown @ 0.9.0` (`25cb61d34820`) + only transitive
`swift-cmark @ 0.9.0` (`08ddb528923c`, cmark-gfm C); Linux x86_64
build green, incremental ~2.3 s wall; linked debug binary 4.6M;
parses headings/strong/code/fences/task lists.

Adoption is CONDITIONAL on a hard C0-exit gate (B10): the edge lands
only after `swift build --target NeedletailTerminal` (averse,
`--configuration release` link check) passes on Linux AND on the
qualified macOS host (Builds-Mac-Pro.local), with binary-size delta
recorded in the receipt. Edge spelling is `.exact("0.9.0")` (not a
`from:` range) + committed `Package.resolved`. If macOS fails, the
edge is reverted and C1 ships the documented bounded fallback
(literal + prefix-classified ANSI spans, no parsing). `Needletail-
Presentation` stays dependency-free and pure; the ANSI span writer
remains ours; no other framework imported.

## C1 rendering (revised per B1/B2/B8/B9)

- Raw source (B1): `SessionEventProjection.delta` is `terminalSafe`'d
  at mint (`SessionEvent.swift:249-251`; newlines → `\u{a}`), so the
  adapter does NOT parse projections. Raw display bytes come from a
  `DeltaTapTransport` decorator (new, `NeedletailTerminal`): a STRUCT
  wrapping any `ModelTransport` and conforming to
  `DeltaStreamingTransport` itself, so it is the actor's concrete
  `Transport`. The actor copies the transport back after setting the
  sink (`SessionActor.swift:624-636`), so the decorator's `didSet`
  capture of the actor's closure survives — but ONLY if the decorator
  sets the sink on the SAME inner value it invokes: at `invoke` it
  assigns the inner-as-`DeltaStreamingTransport` sink to
  tap-then-forward-to-captured-actor-closure and invokes that same
  inner value (assigning to a copy then invoking the original
  silently loses the tap). The tap is display-only, keyed by
  requestID, bounded (1 MiB per request with a visible
  `…[stream truncated: display bound 1 MiB]` marker per SPEC ¶805 —
  a display bound independent of `SSEBounds`/actor-queue limits),
  dropped at `run_finished` — never state, never a second
  conversation. Tap state lives in a REFERENCE box shared with the
  adapter (the decorator is a struct the actor copies per invoke —
  per-invoke tap buffer + finalize notification must not die with
  the copy).   COMMIT source (authoritative): `TransportResult.response.outcome`
  (`ProviderOutcome`) at `invoke` return — commit only on
  `.textDeltaComplete(text:)` (raw, pre-`terminalSafe`); no commit
  for `.failed`/`.interrupted` — never the tap, never a projection
  (deltas are explicitly hints-only; this also covers non-streamed
  turns and delta/assembly mismatch). The 1 MiB tap feeds ONLY the transient
  progress line. Block cap 256 KiB + exact marker
  `…[block truncated at 256 KiB: full text in transcript
  session=<id> request=<id>]` apply to the authoritative text; the
  transcript is the retained artifact. Finalize is
  generation-gated: the output owner takes the request generation
  and drops commits for invalidated generations (C5.5).
- Streaming contract (B2, rewritten): partial input is NEVER parsed
  and NEVER echoed raw into scrollback (SPEC ¶717 forbids repainting
  committed history; echo-then-restyled would duplicate or repaint).
  Live scrollback receives tool events, approval prompts and status
  changes only.   Model-text progress shows as a BOUNDED transient
  progress line (`streaming… N bytes`, redrawn in place via the
  composer-redraw path through replxx's cross-thread `replxx_write`
  — never manual cursor movement racing replxx's repaint, max 10 Hz
  redraw — never committed). Committed-line incrementality (SPEC
  ¶801) is explicitly deferred to per-request finalize: no partial
  model line ever commits. On per-request completion —
  finalize trigger is the decorator's `invoke` RETURN for that
  requestID (adapter-side; `run_finished` only drops tap state, so
  multi-turn tool runs finalize per request, never mis-ordered) —
  the adapter commits the full styled block via swift-markdown
  `Document(parsing:)` walk. Observable contract: the COMMITTED
  block rendering is identical regardless of chunk split; no partial
  model text ever commits. The C5.2 oracle compares committed-block
  renders across chunkings AND asserts the transient path emitted no
  control/ANSI bytes from content.
- `DisplaySanitizer` (new, B8 — does NOT touch `terminalSafe`, whose
  Cf→U+FFFD pins stay): preserves ZWJ (U+200D) + combining marks so
  emoji sequences survive to cluster-safe wrap; DENY-BY-DEFAULT on
  Unicode `Cf`: the ONLY preserved `Cf` scalar is ZWJ (U+200D);
  every other `Cf` (U+00AD, U+0600–0605, U+2060–2064, U+206A–206F,
  U+FFF9–FFFB, U+E0020–E007F, etc.) → U+FFFD. Combining marks
  (Mn/Mc/Me) are not `Cf` and pass through. Additionally
  neutralizes: ESC, CSI/OSC/DCS/SOS/PM/APC introducers, C0/C1 (incl.
  NUL → `\u{0}` escape — also fixes `LineEditorSession.emit`'s
  `strlen` truncation); TAB expands to next 8-stop; CR is rejected
  visibly (`\u{d}`); links render text-first (`text (url)`), never
  OSC-8 (SPEC ¶805 rules enumerated here).
  Sanitization runs BEFORE renderer ANSI emission, and C5.3 asserts
  on the final byte stream (SGR only around sanitized spans).
- Roles (B9): `StyleRole` is extended ADDITIVELY in Presentation
  (pure, tested — flagged production change, reviewed before
  landing): `heading`, `strong`, `emphasis`, `code`, `codeBlock`,
  `listMarker`, `taskCheckbox`, `filePath`, `quote`, `diffAdd`,
  `diffDel`, `diffHunk`, `toolReceipt`, `warning` (SPEC ¶799 roles
  covered; unmapped spans fall back to `normal`). Diff lines
  classify by prefix from `UIDiffFile.hunks` (`+`/`-`/`@@`/context)
  in the adapter; no re-parse as Markdown. Canonical bytes untouched
  (UX-RENDER-08).
- Sanitizer boundary (B8): TWO sanitizers coexist by path, documented
  here. `terminalSafe` (Core) stays the store/projection boundary
  (Cc→`\u{hex}`, all Cf→U+FFFD; TOOL-12/UX-RENDER-04 pins hold).
  `DisplaySanitizer` (adapter) is the pre-emit boundary for RAW tap
  bytes only: it preserves ZWJ/combining and neutralizes the rest.
  ZWJ-bearing content MUST never pass through `render()`/
  `terminalSafe`; C5.3/C5.6 oracles assert on the final byte stream
  with ZWJ-aware expectations, never a blanket "no Cf".
- Layout stays grapheme-cluster-count based (M4-B rule); East-Asian
  wide/emoji display-width misalignment is a KNOWN LIMITATION
  (wcwidth out of scope), recorded in the receipt.

## C2 output owner (revised per B6)

Single `TerminalOutputOwner` (one lock, one writer): all model
deltas, tool events, approval prompts, status changes and composer
redraws pass through it. Concrete bounds: 512 pending items / 1 MiB
pending bytes; adjacent delta chunks coalesce; over-cap drops OLDEST
  droppable first with one visible `…[output truncated]` marker (never
  silent, never unbounded). Priority lanes: approval prompts, errors
  and `run_finished` terminal outcomes travel a reserved control lane
  (cap 64, NEVER dropped; over-cap drains the queued control items
  first, then falls back to synchronous direct write under the same
  lock — still ordered, still single-writer, never blocks the actor's
  cooperative executor: the owner runs its writes on a dedicated
  blocking thread).
Tool events render actual lifecycle states from projections, never
inferred success; generation counters suppress stale/cancelled
callbacks (a redraw for an older generation is dropped, never
emitted); newline/paste bytes enter the draft literally, never
submit. `NO_COLOR`/dumb/non-TTY routes through the same owner with
the ANSI stage disabled.

## C3 composer (revised per B3/B4/B5/B7)

- Seam extension: `LineEditorSession` gains `setModifyHandler`
  (mirror text+cursor), `bindKey` (custom codes incl. Ctrl+C/Ctrl+J/
  Esc), `enableBracketedPaste`, state save/restore
  (`replxx_get/set_state` `replxx.h:386/394`,
  `replxx_set_preload_buffer` `replxx.h:466`) — thin
  wrappers only, no policy.
- Draft authority (B4, rewritten): the replxx live buffer is
  authoritative DURING editing; the modify callback mirrors with
  fine-grained `insertText`/`deleteBackward`/`moveCursor` proposals
  ONLY (never `replaceDraft`, so the mention popup survives typing).
  Submit NEVER trusts the mirror: the adapter first emits the small
  additive `InputAction.replaceDraft(text:)` (new Presentation case,
  flagged for review — full spec: rejects text over
  `maxComposerBytes` (same 64 KiB rule as `insertText`, never silent
  truncation); sets text, cursor=end scalar count, revision+1,
  `pasting=false`; clears suggestion AND tokens (submit boundary
  semantics, mirroring `submitDraft`'s reset — mention flow restarts
  after a boundary); pure, tested), with the exact replxx line, THEN
  maps: idle → `.input.submitDraft` (edge-minted UUID commandID;
  retry reuses the same ID — dedup is Core admission idempotency,
  adapter stores last `(text → commandID)`); busy →
  `.queueOp.submitFollowUp` (SPEC ¶744) FOLLOWED by
  `replaceDraft("")` + replxx buffer clear, so queued text cannot be
  re-submitted.   Cap pre-check: the adapter verifies
  `text.utf8.count <= maxComposerBytes` BEFORE `replaceDraft` on
  BOTH branches (`.submitDraft` has no byte guard — a rejected
  over-cap `replaceDraft` must short-circuit before `submitDraft`
  could submit the stale mirror; `.submitFollowUp` silently emits
  nothing over cap) — over-cap keeps the replxx buffer and shows
  "draft exceeds 64 KiB". The mirror is thus exact at every submit
  boundary by construction. Bracketed paste mirrors via
  `.input.pasteLiteral` (SPEC ¶751: `pasting=true` keeps pasted `@`
  from opening a mention); ordinary typing mirrors via
  insert/delete/move.
- Key map (B5, corrected): Ctrl+C → `.queueOp.cancelRun` when busy;
  when idle and draft non-empty → `replaceDraft("")` + replxx clear
  (SPEC ¶746 idle clear); when idle and empty → noop with hint
  (never silent exit). Ctrl+J → `.input.newline`; Esc →
  `.mention.dismissSuggestion`; `/steer …` → `submitSteer`,
  `/queue` → inspect queue, `/undo <group>` → `undoIntent.preview`
  (bare `/undo` → visible "usage: /undo <group>" error — PARTIAL:
  latest-eligible-group resolution edge-side via `UndoLedger`
  reconcile is deferred, not in M4-C), `/rewind …` →
  `rewindRequest`,   `/compact` → inspect compactDryRun ONLY
  (triggering `/compact` non-dry-run has no intent in the UIAction
  vocabulary — out of scope), `/cancel` → `.queueOp.cancelRun`
  (SPEC ¶768), `/keys` → adapter-local help text;
  `/preview`, `/diff`, `/agents`, `/context`, `/epochs`, `/sessions`,
  `/models`, `/help`, `/queue resume|edit|withdraw` are DEFERRED
  (explicit "not yet in interactive mode" message, never dispatch,
  never silent). `/preview` is NOT diff (SPEC ¶755 file-preview
  fallback; no preview action exists in the vocabulary). Unknown
  `/…` → visible error listing supported commands. C5 covers each
  mapped command plus the deferred/error paths.
- Completion race (B3): replxx demands candidates synchronously, so
  the adapter keeps a revision-keyed candidate cache; the modify
  callback fires `.requestCompletions` (async edge fetch), and the
  sync callback serves only the cache entry whose key equals the
  revision derived from its `input` argument matching live
  `UIState.composer.revision` (the same revision `reduceCompletion`
  checks — otherwise async results drop as stale, DX-02 preserved).
  Tab before the async fetch returns serves nothing; stated here.
  Cache bound: entries pruned on submit/clear and on revision
  supersession (at most one live + one in-flight revision kept);
  mirror-lag (Tab served nothing while a valid fetch is in flight)
  is accepted and covered by C5.5.
- Interactive overlay: the adapter SUPPRESSES `RenderFrame.
  composerOverlay` in interactive mode (adapter-local render step —
  replxx owns the live line; rendering the overlay would double-draw
  the composer AND corrupt ZWJ drafts through `terminalSafe`). The
  overlay stays the contract for headless/dumb-inline paths.
- Approval (B7, rewritten — single owner): `TerminalApprovalGateway`
  reads stdin directly and would steal replxx input — it is NOT used
  in interactive mode. New `ReplxxApprovalGateway` (in
  `NeedletailTerminal`, conforming to the Core `ApprovalGateway`
  protocol) is the SOLE decision path in interactive mode: the
  actor calls `decide`; `decide` suspends on a `CheckedContinuation`
  (actor-executor-safe — the actor already awaits gateways today)
  and invokes the loop-injected async presenter, which renders the
  `ApprovalRequestView` (validated ops + resolved exec identities
  only) through the output owner. The `y/N` read is serialized
  THROUGH replxx, never a second stdin reader: the presenter arms a
  one-shot confirm mode, the blocked `readLine` returns, the adapter
  interprets that line as the decision (explicit `y`/`yes` approves;
  EOF/empty/anything else denies — `TerminalApprovalGateway`
  fail-closed semantics preserved), resumes the continuation, then
  restores the saved draft via preload and loops `readLine`.
  Action-level rule (reducer untouched, M4-B flow contract holds):
  the interactive adapter NEVER emits `.queueOp.grantApproval`/
  `.denyApproval`, so `.decideApproval` can never arise from it; the
  effect stays fully translated on every path where it can arise
  (headless exact-effect-list gate stays green). Approval rows render
  non-actionable display-only with an adapter-local "answer in the
  approval prompt" hint (no `Render` change). C5 asserts the
  interactive action map produces no `.decideApproval`. Cancellation:
  the gateway's `CheckedContinuation` carries a cancellation handler
  — task cancel/supersede resumes it (deny) so no suspended task
  leaks and confirm-arming never wedges. Confirm mode disables
  history (no `y` retained) and bracketed paste for the decision
  line; documented. Sandbox: the composition root derives an explicit
  `isSandbox = (sandboxGrant != nil)` bool at the branch (NEVER
  `gateway is SandboxPolicyGateway` — `AnyApprovalGateway` erases
  the type) and threads it to BOTH the gateway selection AND the new
  `QueueSyncSnapshot.from` edge wiring; sandbox rows stay
  display-only. `SandboxPolicyGateway` path unchanged.

## C4 portability

`TerminalCaps.fromEnvironment`: `NO_COLOR` present-and-non-empty →
color none (no-color.org rule); `TERM=dumb` → dumb caps; non-TTY
stdout → plain; width from `COLUMNS`/ioctl clamped ≥ 20; missing caps
→ safe fallback. Plain mode keeps all semantic text, zero ANSI bytes.
Width/caps live in the ADAPTER (outside the reducer — `UIAction.
terminal` is currently a no-op and stays so; no reducer change).
`needletail run` JSONL byte contract unchanged; interactive features
never engage without a TTY.

## C5 evidence (revised per B2/B5/B8)

1. Draft/cursor preserved across streaming output (synthetic).
2. Completed-block renders identical across arbitrary splits;
   partials carry zero ANSI/control bytes.
3. Control/bidi injection battery asserted on the FINAL byte stream
   (Cf classes U+00AD, U+0600–0605, U+2060–2064, U+206A–206F,
   U+FFF9–FFFB, tags U+E0020–E007F, bidi U+202A–202E/U+2066–2069,
   direction marks → U+FFFD; ONLY U+200D ZWJ survives).
4. Bounded buffer/queue: over-cap drops oldest + marker; control
   lane never drops (fault injection).
5. Stale completion/redraw suppression by revision/generation.
6. Unicode-safe layout incl. explicit ZWJ-emoji oracle (combining/
   ZWJ preserved, never split).
7. Plain mode: NO_COLOR/`TERM=dumb`/non-TTY → identical semantics,
   zero ANSI bytes.
8. No duplicate operator submission (same commandID retry → one row).
9. Existing Core/Runtime authorization + persistence unchanged
   (regressions: `BehaviourTests`, `quick`, presentation suites).
10. Linux + qualified macOS, debug and `-O` reported separately
    (macOS includes a Markdown parse smoke test — behavior, not just
    link — per DEPENDENCIES.md).
- Regressions: `NeedletailPresentationTests` (UX-RENDER-01…08 pure
  legs stay green), `BehaviourTests`, `./dev test quick`.
- Test target: `NeedletailTerminalTests` gains deps
  `NeedletailTerminal` + `NeedletailPresentation` (renderer tests
  stay G14-clean: no deep recursion). ALL emit paths (incl.
  `LineEditorSession.emit`) pass through `DisplaySanitizer`, so NUL
  safety holds end to end.
- Reviews: this plan (round 3) + substantive adapter changes before
  closeout; receipt records dispositions.

## Production wiring changes (no Core state change; reviewed pre-land)

M4-C requires, and explicitly schedules for independent review
before landing (blocker 5): (a) `Package.swift`: NEW
`NeedletailTerminal` target + `.exact("0.9.0")` swift-markdown edge +
`NeedletailTerminalTests` deps on `NeedletailTerminal`/
`NeedletailPresentation`; (b) `RunCommand` composition root: compose
`SessionActor<DeltaTapTransport,…>` wrapping
`ChatCompletionsTransport`, select `ReplxxApprovalGateway` for the
interactive (non-`--sandbox-grant`) TTY path, derive explicit
`isSandbox` at the `sandboxGrant != nil` branch for gateway choice
AND new `QueueSyncSnapshot.from` edge wiring; (c) Presentation
additive-only: `InputAction.replaceDraft` + reducer case + tests,
`StyleRole` new cases + tests. No change to Core authorization,
persistence, queue, grant or transport semantics; no Core state
mutation from the terminal. If the macOS build/link/behavior gate
fails, the package edge is reverted and C1 ships the documented
bounded literal fallback.

## Out of scope (M4-D owns; unchanged)

PTY-01…08 end-to-end, physical keyboard/paste/resize/cancellation,
ssh/tmux spot checks, full release-binary smoke, lifecycle/cleanup
acceptance. M4-C uses synthetic streams, deterministic actions,
native adapter tests, fault injection — no PTY, no live model.

## Round-2 dispositions (→ rev 3)

- R2B1 (sandbox erasure) → explicit `isSandbox` at composition,
  threaded to gateway + snapshot wiring; single-owner gateway with
  confirm-armed `readLine` protocol. Plan §C3 + §Wiring.
- R2B2 (idle submit reads mirror) → new additive
  `InputAction.replaceDraft`; exact-mirror-at-submit + clear-after-
  followUp. Plan §C3 + §Wiring.
- R2B3 (key/slash errors) → `.cancelRun`, SPEC ¶746 idle clear,
  `/undo <group>` required, corrected map. Plan §C3.
- R2B4 (duplication/finalize/marker) → transient-progress-only
  partials, `invoke`-return finalize, 1 MiB/256 KiB caps + SPEC ¶805
  markers. Plan §C1.
- R2B5 (unflagged wiring) → explicit §Wiring section, reviewed
  pre-land. Plan §Wiring.
- Per-disposition notes folded: struct-decorator same-value rule;
  cache-revision equality rule + Tab-serves-nothing; control-lane
  drain-first + dedicated thread; two-sanitizer boundary doc;
  SPEC ¶799 roles (`taskCheckbox`, `filePath`, strong/emphasis split);
  macOS behavior smoke; invoke-return finalize; clear-after-followUp;
  gateway fail-closed preserved; NUL-all-paths; cite fixes.

## Round-1 dispositions

- B1 (no completed-block source) → `DeltaTapTransport` decorator;
  projections unparsed; tap bounded/display-only. Plan §C1.
- B2 (C5.2 contradiction) → completed-block oracle + literal
  partials; contract restated. Plan §C1.
- B3 (no replxx seam) → explicit seam extension + revision-keyed
  sync candidate cache. Plan §C3.
- B4 (draft authority) → replxx authoritative live, reducer mirror;
  submit mapping. Plan §C3.
- B5 (missing input semantics) → busy-submit→followUp, key map,
  slash commands, C5 cases. Plan §C3/C5.
- B6 (unbounded/unsafe drops) → concrete caps + control lane. §C2.
- B7 (approval bypass) → `ReplxxApprovalGateway`, draft save/
  restore, sandbox flag wiring. Plan §C3.
- B8 (ZWJ false claim) → new `DisplaySanitizer` preserving ZWJ;
  `terminalSafe` untouched; ZWJ oracle. Plan §C1/C5.
- B9 (roles don't exist) → additive `StyleRole` extension stated.
  Plan §C1.
- B10 (early adoption + `from:`) → CONDITIONAL + `.exact("0.9.0")`
  + macOS link hard gate + fallback. Plan §Dep.
- Caveats folded: width/caps adapter-owned; wcwidth limitation;
  NO_COLOR non-empty rule; SPEC ¶805 enumeration; final-stream C5.3;
  test-target deps; commandID-reuse rule; NUL-before-emit.
