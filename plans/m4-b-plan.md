# M4-B Plan — Pure Presentation and Interaction Contract

Baseline: `m4-a` @ `29af6f0` (code tree `32d2226`, M4-A QUALIFIED).
Boundary: `plans/m4-a-boundary.md` (frozen; no M4-A re-investigation
without demonstrated defect).
Authorization: planning only until DeepSeek plan review passes (REV-01);
slices implement only after their slice review.

Normative sources: `COMPLETE-SPEC.md` UX-MENTION/QUEUE/UNDO/NAV/RENDER/DX
families (§Mission-4), `cases/catalog.json` (36 M4-due `pure` cases),
`plans/m4-plan.md` (ordering + priorities).

## 1. Case inventory and evidence tiers

M4-due `pure`-layer cases (36, from `cases/catalog.json`):

- DX-09, DX-10
- UX-MENTION-01…08 (09…12 are integration/native legs: M2-D contract
  reuse, connected not duplicated — §3)
- UX-NAV-01…07
- UX-QUEUE-01…05, 07, 11, 12 (pure legs here; `integration` legs
  executed in B6 §8; UX-QUEUE-06/08/10 are `integration` legs and
  UX-QUEUE-09 is a `pure` policy-limit leg — all executed, none
  assumed from prior milestones)
- UX-RENDER-01…08 (pure legs only here, labelled PARTIAL;
  `terminalAdapter` legs are M4-C/D)
- UX-UNDO-06, 08, 09 (pure halves here, labelled PARTIAL;
  `integration`+`nativeProcess` legs executed in B6 §8)
- UX-MENTION-09, 10, 12 (`pure`+`integration` M2-D legs connected
  in B1, executed in B6 §8); UX-MENTION-11 is `pure`-only and is
  covered by the existing exited M2-D test — B1's "cancellation with
  zero admission" means only the NEW preview-cancel path

Evidence tiers per case: `pure` (new Swift Testing, virtual clock/IDs,
semantic frames, golden fixtures) + `review` (slice review receipts).
Multi-layer cases are labelled PARTIAL at M4-B close until every
catalog evidence layer has executed evidence (BDD-05 discipline);
the receipt may never claim a full case pass on pure legs alone.
The 11 deferred M2-D rows below are executed in slice B6 (§8),
not merely "reused". No PTY/terminal evidence in M4-B.

## 2. Existing implementation vs genuinely missing behavior

Existing (reuse, do not rebuild):
- `UIAction` intents: input/submit/paste/cursor, session projection
  intake, completion intake, queueOp intents (followUp/steer/edit/
  withdraw/resume) → effects. `UIReducer.reduce` pure; `Render`
  semantic frames (roles, no ANSI); DX-01 replay determinism pinned;
  DX-02 stale-completion drop; DX-06 adversarial interleavings;
  DX-07 golden (`basic-chat.json` + manifest SHA); PORT-02 import gate.
- Core authority: `SessionEvent` families + `transition` + `SessionActor`;
  `SessionEventProjection` (Core-minted only, R21); M2-D
  snapshot/consent contract (`AttachmentSnapshot`, capture service,
  verdict order, consent epochs); queue admission/edit/withdraw/resume/
  retarget/reconcile; approvals/holds; undo preflight/inverses/journal;
  lineage fork (record-only); checkpoint/epoch descriptors; diff
  provenance (`ChangeGroup` vs operator `GitDiff`); read-only store
  queries (`records(session)`, transcript projections, `sessions()`).
- `FileCandidateSource` seam (String paths; no product impl).
- `UISink` headless JSONL sink (same projections, no interactivity).

Genuinely missing (this milestone builds):
- B1: `@` grammar/parser, query/revision derivation from composer text,
  candidate ranking/selection actions, structured file-token identity
  (path+range+rev), bounded previews (sanitized 8-line/4-KiB, binary/
  denied/missing/stale typing), paste-vs-mention literal rules,
  cancellation with zero admission, M2-D consent-connection actions
  (attach/replace/re-consent intents → existing Core validation).
- B2: reorder action (see risk §5 — Core transition required),
  retarget/reconcile/acknowledgeUnknown UI intents, held/unknown/stale
  delivery projections in `QueueSummary`, optimistic-pending markers +
  rollback on denial, recovery/re-consent actions, explicit
  approve/deny intent routing to existing approval events.
- B3: read-only projections for sessions/epochs/models/context (typed,
  not `InspectionView` strings), `/compact --dry-run` inspection,
  checkpoint lineage/failure views, budget-boundary vs clean completion
  distinction, verified-receipt vs model-claim labeling.
- B4: undo preview/eligibility/conflict views, partial-undo and
  unknown-outcome notices, rewind lineage/divergence views, approval
  request/deny views (human + sandbox-policy), exact executable identity
  display. Presentation only: no filesystem undo, no rollback of exec
  effects, no new approval engine.
- B5: full semantic-frame coverage of the above, revision-supersede
  rule (N+1 replaces N), bounded frame/update queues, headless
  consumer proof (§9 six capabilities + oracles), independently
  reviewed golden fixtures (`Tests/Fixtures/ux/*.json` + manifest).
- B6: deferred integration/native leg completion (§8).

Dead code to wire or remove (decide per slice, no dead effects at
close): `UIEffect.previewFile`, `requestCompletions`, `cancelCurrent`,
`inspect` (+ `InspectionCommand`/`InspectionView` either typed or
deleted), `FileCandidateSource` product-or-test-only decision,
write-only `pasting` flag, unrendered `statusLine`.

## 3. Authoritative owner of each state transition

| Transition | Owner | Presentation role |
|---|---|---|
| Composer text/cursor/revision/draft | `UIReducer` (Presentation) | Owns (only mutable UI truth) |
| Mention query/candidates/selection | `UIReducer` + `FileCandidateSource` seam | Owns display; Runtime supplies candidates |
| Attachment capture/validation/consent | Core `AttachmentSnapshot` + Runtime capture/validator + `transition` | Intent + display only; never capture/re-consent/relax rules |
| Queue admission/edit/withdraw/resume/retarget/reconcile | `transition` + `SessionActor` | Emit intents as `UIEffect`; project `QueueSummary`; never mutate |
| Queue ordering/reorder | Core (`orderKey`, new transition — §5 risk) | Reorder intent only |
| Approvals/grants/denials (human + sandbox) | Core approval events + existing grant mechanism | Display Core-minted `ApprovalRequestView` (requestID+generation+ scope+policy-kind, read-only, delivered via a new Core-only `SessionEventProjection` factory — `internal init` preserved); route grant/deny intents carrying those IDs; sandbox-policy rows display-only (decisions come from `SandboxPolicyGateway`, never the UI); no auto-approval engine (Mission §B4) |
| Undo preview/run/eligibility/conflicts | Core `UndoLedger` + `SessionActor` | Request + render outcomes; never run inverses |
| Rewind/lineage fork | Core (record-only fork) | Display lineage/divergence; no file mutation |
| Epochs/checkpoints/sessions/models/context | Core descriptors + store queries | Typed read-only projections; no provider calls |
| Diff provenance display | `ChangeGroup` (agent) + `GitDiff` (operator) | Render with labels; never attribute dirty tree to agent |
| Semantic frame emission | `Render` (Presentation) | Pure function of state; never mutates actor |

Flow (Mission §2): `UIAction → pure reducer → UIEffect → SessionActor
→ authoritative projection → UIState`. Optimistic rows render
`pending` until Core acknowledges; denial rolls back. `delta`
projections are display hints, never state.

## 4. Presentation types requiring extension

- `UIAction`: mention actions (query update from composer, select/
  dismiss completion, preview request, cancel), attachment actions
  (attach/replace/withdraw/re-consent intents), queue actions
  (reorder, retarget, reconcile, acknowledgeUnknown), approval
  actions (grant/deny intents carrying Core-minted request IDs —
  human + sandbox, display/route-only), undo actions
  (preview/run intents), pure cancel intent (key binding is M4-C/D;
  the intent maps to existing `cancelRequested`), inspection
  actions (typed context/queue/epochs/compact/diff views) or
  deletion of `InspectionCommand`.
- `UIState`: attachment-token rows, approval-request rows,
  undo-preview/eligibility rows, typed epoch/session/model/context
  rows, optimistic `pending` + ack-correlation fields, hold/stale/
  unknown reason fields. Replace untyped `InspectionView` or type it.
- `UIEffect`: producers for every currently-dead effect or removal;
  new intents map 1:1 to existing `SessionActor` entry points
  (enumerated in audit; no new actor endpoints except reorder —
  §5).
- `Render`: branches for every new row kind; revision-supersede
  display rule; bounded-frame accounting; `terminalSafe` at all new
  untrusted boundaries.
- `FileCandidateSource`: DECIDED — pure seam with injected
  observations. Candidate/preview provider protocols are value-type
  contracts in Core (query/revision in, bounded candidate/excerpt
  observations out; no I/O, no filesystem). Runtime owns the
  product implementation (bounded catalogue, ranking caps,
  capture-backed previews); scripted fakes serve pure tests.
  Presentation never performs I/O (PORT-02 import gate holds).
  UX-MENTION-05/06/07 native-read hardening (100K catalogue, 20 MiB,
  binary/symlink/denied) executes at integration tier in B6 as
  supplementary evidence — the catalog tiers for these cases are
  `pure`-only, so this is extra hardening, not a required layer;
  pure tests use injected bounded observations and assert caps,
  truncation, and typed refusals.

PORT-02 holds throughout: Presentation imports Foundation+Core only
(enforced by `PresentationGateTests`).

## 5. Risks to existing actor/replay semantics

R1 — Reorder is new Core behavior with ack-identity coupling.
`orderKey` is NOT a spare sort hint: it is assigned as the admission
sequence (`transition` admission path), the durable ack sequence is
reconstructed AS `orderKey` on reopen, and it feeds
`durableIDHighWater`/allocator reseeding. Reassigning `orderKey` to
reorder would corrupt durable ack identity and risk post-reopen ID
collision. Design constraint (non-negotiable): `orderKey` stays
immutable; reorder is a separate rank/position field plus a new
reorder event with explicit replay rules (rank travels with the
entry, ack identity untouched, FIFO/admission invariants re-proved).
The B2 slice designs this transition first with replay tests; if
the design threatens D0/D1 or ack/watermark invariants, reorder
defers and UX-QUEUE-05 is recorded PARTIAL (edit/withdraw legs
done, reorder leg deferred) — never claimed implemented.
R2 — Optimistic queue rows must not leak into durable history.
`QueueSummary.pending` rows are display-only; admission acks carry
the only history path (STATE-02 idempotency). Tests assert
forbidden effects (no ` submitting` from render, no duplicate
history on replay).
R3 — `delta`/`run_finished` must stay display-only; reducer already
ignores them — new branches must not synthesize state from them.
R4 — Stale async completions (DX-02 pattern) for every new async
seam (candidates, previews, approvals): revision-guard each.
R5 — Golden fixtures must be hand-authored + independently reviewed
(BDD-07/DX-07); auto-regeneration from the renderer is a blocking
defect, enforced by manifest SHA review.
R6 — No terminal/ANSI/parser leakage into Core/Pure Presentation
(M4-C owns adapters; `terminalSafe` boundary tests per new string
path).
R7 — macbuild flakiness (two outages in M4-A): Linux gate is the
blocking gate (PORT-06). macOS runs best-effort per slice — EXCEPT
any slice touching Core/replay (R1 reorder): that slice requires at
least a macOS build + targeted state tests, or an explicit recorded
deferral rationale, per the M4-A boundary (must not regress native
macOS behavior).

## 8. Slice B6 — deferred integration/native completion (new)

The 11 M2-D-deferred rows (`plans/m2-d-epic-receipt.md:91-93`:
QUEUE-01/02/03/04/05/07/11/12 and UNDO-06/08/09 non-pure legs) are
M4-due and owned by no other slice (M4-C is adapter/ANSI, M4-D is
PTY). B6 executes each deferred `integration`/`nativeProcess` leg
against the final M4-B tree with the new presentation-backed flows
where applicable, or formally defers it with a named milestone.
No new product code is expected (verification of existing
mechanisms); any failure is a defect, not a re-scope. MENTION-09,
10, 12 legs ride in B6 as well. B6 runs after B5; its results and
PARTIAL/full labels go in the receipt per case.

## 6. Explicit B/C/D ownership boundaries

- M4-B (this plan): pure state, intents, effects, projections,
  semantic frames, golden fixtures, headless consumer, BDD-06
  probes for new boundaries, BDD-08 frozen replays. Zero ANSI,
  zero line editing, zero PTY, zero release-binary wiring.
- M4-C: Markdown/ANSI rendering of semantic frames, replxx line
  editor, terminal adapter consuming `RenderFrame`; swift-markdown
  pin qualification; draft retention during stream/resize;
  stale-callback ignore. M4-C may not change reducer semantics —
  frame in, bytes out.
- M4-D: physical PTY scenarios PTY-01…08, release-binary wiring
  smoke, keyboard/resize/signal handling, TERM/SSH/tmux paths.
  M4-D may not add presentation state — failures route to B/C
  slices explicitly.
- Future desktop frontend: consumes the same projections +
  `UIAction`s proven by the B5 headless consumer; no agent-loop
  changes permitted (gated by the headless-consumer test).

## 7. Slice exit criteria and review gates

Each slice (B1…B6) exits with: case IDs implemented/deferred/PARTIAL,
pure tests green (`quick` + `test case` per ID), golden fixtures
+ manifest review, BDD-06 probe→guard→oracle entry (disposable
patch, RED log per probe, byte-identical restore, no production
fault switches; target guards include revision-supersede,
`terminalSafe`, pending/ack correlation, no-mint), BDD-08 replay
where interleavings exist, Linux `offline` green, macOS keepers
best-effort (mandatory build+targeted tests for Core/replay
changes), focused DeepSeek slice review (findings resolved,
no broad re-review), receipt section in `plans/m4-b-receipt.md`.
`coverage` reconciliation extends to newly due pure IDs.
M4-B closes with the headless-consumer gate (§9) + B6 + full receipt.

Slices run sequentially (B1→B6); B5 integrates pure, B6 completes
native legs. RED-before-green per slice (failing test first, then
implementation).

## 9. B5 headless-consumer gate — six capabilities and oracles

The closure gate is a test-only headless consumer (no terminal
import) that must demonstrate, against scripted Core responses:

1. Obtain a complete semantic session projection — oracle: the
   consumer holds queue + permissions + undo + epoch rows covering
   every row kind the receipt claims; missing row kind fails.
2. Apply a sequence of UI actions — oracle: fixed action script
   executes without executor, producing the exact expected
   `UIEffect` list (no more, no fewer).
3. Receive requested effects without executing them — oracle: effect
   sink records requests; any direct Core mutation from the
   consumer layer fails the test.
4. Apply authoritative Core responses — oracle: scripted
   admitted/denied/run/agent projections applied; optimistic
   pending rolls back on denial byte-exactly.
5. Reconstruct the same resulting UI state from replay — oracle:
   replay of the action+response script from initial state equals
   the live state (`==`), twice.
6. Inspect queue, permissions, undo and epoch state without a
   terminal module — oracle: PORT-02-style import gate on the
   consumer test target (Foundation+Core only) plus field-level
   assertions on all four domains.

All six fail-closed: any oracle violation fails M4-B closure.
