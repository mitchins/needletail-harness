# M2-D M3-B Preflight Checklist (frozen)

Baseline: `main` @ `6104845` + M2-D D0 (`75c0187` series incl. D0
review fixes) + D1 (`c9cd23c`, `04a2a1d`) + D2 (`e0f3491`, `b04fc91`,
`c152865`) + D3 (`08f0b95`, `cd75adc`, CodeRabbit fixes; qualified
code HEAD `a47e216`).

Status vocabulary (this document only):

- **implemented** — production code exists on the branch.
- **tested** — executed evidence exists at the stated tier
  (pure / nativeProcess / integration, per `cases/catalog.json`).
- **not yet live-qualified** — proven with synthetic providers, temp
  filesystems and temp stores only; no live model, no operator
  workspace, no production loop has exercised it.
- **intentionally deferred** — M4 (terminal/UX) or out-of-scope; not
  required for the M3-B viability decision.

No row is marked passed beyond its evidence. In particular, nothing
below claims a live-model run.

## Must-have before the M3-B real-model coding-loop experiment

| # | Area | Status | Evidence |
|---|---|---|---|
| 1 | Actual five-tool composition and authorization (read/search/edit/write/exec gating, per-call attestation) | implemented, tested, **not yet live-qualified** | M2-B B4/TOOL lanes; `TOOL09OrderedBatchTests`, `B4PerCallAgreementTests`; D3 D (real `NativeToolExecutor` end-to-end), E2 (live commit-failure integrity stop) |
| 2 | Exact command approval and execution receipts (ask-gated exec, NC-9 operator receipts, no fabricated success) | implemented, tested, **not yet live-qualified** | M2-C C2 (`C2ExecDurableTests` 41) + C3 (`C3ExecQualificationTests` 18) |
| 3 | Durable file mutations and preimage availability (verified preimages, quota, create/empty shapes, boundary identity) | implemented, tested, **not yet live-qualified** | `B3EditWriteTests`, `B3ByteQuotaTests`, D2 `UndoFilesTests` (real FS + real GRDB preimages), D3 D (real executor end-to-end) |
| 4 | Queue replay and unknown-delivery holds (durable replay, dispatch linkage, head barrier, no auto-resend, explicit reconcile) | implemented, tested, **not yet live-qualified** | D0 lanes; D3 A (order/IDs/acks/no-duplicates, real GRDB), B (linkage crash → held → resume-no-resend → reconcile durability → release-only-intended), C (stale head, no overtake), F (combined) |
| 5 | Attachment validation and privacy transitions (atomic capture, stale refusal, re-consent, excerpt accounting, redacted export, cross-alias grant hold) | implemented, tested, **not yet live-qualified** | D1 lanes + `QueueAttachmentActorTests` (new excerpt in, stale excerpt out); D2 export redaction (`SessionExportTests` allowlist); D3 C (real capture + real validator across reopen; fix redispatches with reconsent) + C2 (epoch switch preserves unknown head; retarget refreshes consent without release; drain carries current bytes) + C3 (cross-alias grant holds; retarget preserves grant; fresh capture re-consents and drains; RED-proven) |
| 6 | Undo journal reconciliation (change groups, write-ahead intents, idempotent duplicates, unknown holds, crash boundaries 1-7) | implemented, tested, **not yet live-qualified** | D2 `UndoTests` (33 pure), `UndoJournalTests` (real GRDB resume/export), D3 D (partial across reopen, no replay), E (boundary-5 recovery exactly once), F (combined) |
| 7 | Workspace-change notice ordering (dedicated entry, atomic with disposition, precedes next provider request, exec disclaimer) | implemented, tested, **not yet live-qualified** | D2 notice/STATE-05 legs; D3 E (seeded crash → sweep recovers → next request carries it), CF-sweep (bypass proves load-bearing) |
| 8 | Quiescence before checkpoints, rewind and undo (checkpoints: clean ledger, no unresolved outcomes; rewind/undo: full quiescence — no in-flight tool/stream, no unresolved outcome, no deliveryUnknown, exclusive undo phase) | implemented, tested, **not yet live-qualified** | D2 quiescence legs; D3 F (resume/retarget/admission/undo refused while held; checkpoint refused on dirty ledger; explicit reconciliation releases); D3 C2 (checkpoint proceeds orthogonally to queue holds) |
| 9 | Session ownership/fencing (claim, competing-writer refusal, no silent takeover, store untouched on refusal) | implemented, tested, **not yet live-qualified** | A2 lanes; D3 CF-fencing (competing writer throws `alreadyOwned`, zero new records) |
| 10 | Real provider continuation availability (transport dials only the authorized endpoint, bounded intake, classified failures) | implemented, tested, **not yet live-qualified** | M1-C loopback suites; D3 A–F drive multi-turn continuations against synthetic providers on every path above. **Live-model traffic is explicitly out of scope for M2-D.** |

## Safely follows the viability decision (degrades UX, never loop-correctness)

- Queue reorder mechanism + all queue views (QUEUE-05).
- Draft-survival streaming UX (QUEUE-01); steer-timing UX (QUEUE-03/04);
  busy-failure/interrupt UX (QUEUE-07/12); headless-permission UX row
  (QUEUE-11 row; the hold mechanism shipped in D0).
- `@` completion/preview/range/binary-preview UX (MENTION-01..08);
  rewind fork UX + duplicate-undo surfacing (UNDO-08/09 views);
  `/queue`, `/undo`, `/rewind` terminal commands.
- M3-C cache-shortening measurement and M3-D comparison (sequenced
  after M3-B, not prerequisites).

## M2-D scope that M3 does not need at all

Terminal/line-editor/ANSI/PTY wiring; macOS qualification; cloud
profiles; M4+ dependencies; live models; push/PR/merge.

## Known limitations carried into M3-B

- Unknown-operation reconciliation is operator-explicit
  (`acknowledgeUnknown` + `queueReconcile` + `undoFinalize`); there is no
  automatic unknown resolution and none is planned — an ambiguous
  inverse holds the queue until a human accepts the risk (D3 F proves
  the loop closes).
- Same-path multi-touch change groups refuse whole-group (exact-identity
  rule); partial chains are reported as partial, never atomic (D2).
- Fresh-run admissions have no durable delivery tracking (in-memory ack
  only, by D0 design); only queued dispatches carry linkage. M3-B must
  not treat a fresh admission as exactly-once.
- Timing-sensitive actor suites show load flakes under full-parallel
  runs (pre-existing; see epic receipt). D3 scenarios assert on durable
  state, not wall timing.
