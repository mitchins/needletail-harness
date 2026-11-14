import Foundation
import NeedletailCore
import NeedletailPresentation
import NeedletailLineEditor

/// M4-C interactive runloop (adapter tier).
///
/// Owns the UI event loop over qualified M4-B contracts: reduces
/// `UIAction`s into `UIState`, renders `RenderFrame`s (overlay
/// suppressed — replxx owns the live line), drives the single
/// `TerminalOutputOwner`, and bridges replxx↔composer. It never touches
/// `SessionActor`: actor translation lives in the CLI edge via
/// `onEffects`; snapshots arrive via `snapshotProvider`. The loop is the
/// display owner, never agent state.
///
/// Threading: the main task owns `state`/render/dispatch. A dedicated
/// input thread blocks in `readLine`; cross-thread events (mirror,
/// keys, lines, projections, completions, tap callbacks) arrive over a
/// lock-free inbox (`AsyncStream` continuation yields are thread-safe).
/// The owner serializes every emitted byte on its own writer thread.
public final class ChatLoop: @unchecked Sendable {
    public enum Event: Sendable {
        case projection(SessionEventProjection)
        case tapProgress(RequestID, Int)
        case tapComplete(RequestID, Revision, String?)
        case tapTruncated(RequestID)
        case completions(query: String, revision: UInt64, candidates: [CandidateFile])
        case notice(String, StyleRole)
        /// Typed inspection payload (M4-D D2): the edge read store/actor
        /// state; the reducer maps it to the qualified InspectionView.
        case inspection(InspectionResult)
        case inputLine(String?)
        case mirror(text: String, cursor: Int)
        case key(ComposerBridge.KeyPress)
        /// Tab-accept carrying the exact previewed buffer (M4-D D2
        /// review + D7 review B3): the main task applies the accept
        /// ONLY when the recomputed live accept still equals the
        /// carried display (no interleaved input, no reselection). On
        /// mismatch the stale accept drops and its trailing echo is
        /// suppressed; the operator's newer keystrokes win, and a
        /// diverged submit reconciles (no main-thread buffer rewrite
        /// — the input thread owns the live line).
        case tabAccept(base: String, display: String, cursor: Int)
        /// Decided cancel (M4-D D2 review): the live Ctrl+C handler
        /// already determined cancelRun under lock — the main task must
        /// NOT recompute from possibly-flipped state (a finishing run
        /// would misread as idle-empty exit). Unconditional cancel.
        case cancelKey
        case approvalArmed(ApprovalRequest)
        case confirmDone(savedText: String, savedCursor: Int)
    }

    /// Submit-gate context (M4-D D2 review C1): the operator's line
    /// plus the current draft's mention tokens, offered pre-dispatch.
    public struct SubmitGateContext: Sendable {
        public let line: String
        public let tokens: [MentionToken]
        public init(line: String, tokens: [MentionToken]) {
            self.line = line
            self.tokens = tokens
        }
    }

    /// Submit-gate decision: proceed (with captured attachments) or
    /// refuse with an explicit message. Refusals happen BEFORE any
    /// dispatch — the draft, tokens and queue are untouched, so the
    /// operator can fix and resubmit (fail-closed, never silent loss).
    public enum SubmitGateDecision: Sendable {
        case proceed(attachments: [AttachmentSnapshot])
        case refuse(message: String, tone: StyleRole)
    }

    public struct Config: Sendable {
        public var caps: TerminalCaps
        public var sessionID: String
        /// One-shot notices rendered right after the initial frame
        /// (budget visibility, unbounded warning). Adapter-owned text,
        /// never model content.
        public var startupNotices: [String]
        public var snapshotProvider: @Sendable () async -> QueueSyncSnapshot
        public var onEffects: @Sendable ([UIEffect]) async -> Void
        public var mintCommandID: @Sendable () -> CommandID
        /// Turn-finished hook (M4-D D2.4 tool-result display): invoked
        /// after terminal outcomes (see `isTurnTerminal`). The loop stays
        /// store-free; composition owns the read + render.
        public var onTurnFinished: (@Sendable () async -> Void)?
        /// Submit gate (M4-D D2 review C1): budget/attach refusal BEFORE
        /// dispatch, preserving the draft. Nil ⇒ always proceed empty.
        public var submitGate: (@Sendable (SubmitGateContext) async -> SubmitGateDecision)?

        public init(
            caps: TerminalCaps,
            sessionID: String,
            startupNotices: [String] = [],
            snapshotProvider: @escaping @Sendable () async -> QueueSyncSnapshot,
            onEffects: @escaping @Sendable ([UIEffect]) async -> Void,
            mintCommandID: @escaping @Sendable () -> CommandID,
            onTurnFinished: (@Sendable () async -> Void)? = nil,
            submitGate: (@Sendable (SubmitGateContext) async -> SubmitGateDecision)? = nil
        ) {
            self.caps = caps
            self.sessionID = sessionID
            self.startupNotices = startupNotices
            self.snapshotProvider = snapshotProvider
            self.onEffects = onEffects
            self.mintCommandID = mintCommandID
            self.onTurnFinished = onTurnFinished
            self.submitGate = submitGate
        }
    }

    private let config: Config
    private let lineEditor: LineEditorSession
    private let owner: TerminalOutputOwner

    private var state = UIState()
    private var commandIDs = ComposerBridge.CommandIDStore()
    private var emitted: [(id: String, text: String)] = []
    private var shutdown = false
    private var confirmArmed = false

    private let lock = NSLock()
    private var inboxContinuation: AsyncStream<Event>.Continuation?
    // Locked cross-thread snapshots (key handlers + sync completion).
    private var statusBusy = false
    private var draftNonEmpty = false
    private var queuePending = false
    /// One-shot captured attachments for the pending submit (M4-D D2
    /// review C1): the submit gate resolves these pre-dispatch; the
    /// effect closure consumes exactly once. Serial inbox processing
    /// pairs each stash with its submit.
    private var pendingSubmitAttachments: [AttachmentSnapshot] = []
    /// Two-press exit latch (M4-D D2.5): set by an idle-empty Ctrl+C
    /// that warned about pending work; cleared by any other input.
    /// The main task owns arm/disarm; key handlers read under lock.
    private var ctrlCExitArmed = false
    /// Suggestion-live snapshot (M4-D D2 Tab/arrows): the Up/Down/Tab
    /// bound handlers consult this under lock to decide between
    /// selection/accept and the default line behavior.
    private var suggestionLive = false
    /// Published accept snapshot (M4-D D2 review): the input thread
    /// NEVER reads live state (main-owned, written unlocked) — it
    /// reads this lock-published immutable value, computed in dispatch.
    /// Carried in `.tabAccept` so the main task applies the identical
    /// accept it previewed (no cross-thread state race, no A/B swap).
    private var publishedAccept: (base: String, display: String, cursor: Int)? = nil
    /// Dropped-accept echo guard (M4-D D7 review B3): when the main
    /// task drops a stale `.tabAccept`, the input thread has ALREADY
    /// painted the previewed display into the live buffer, and its
    /// trailing mirror echo is still queued behind the accept. The
    /// dropped display is parked here so the next mirror can be
    /// recognised as that stale echo (suppressed, never re-applied as
    /// text without its token). While set, the live buffer is known
    /// diverged from state text; subsequent mirrors and submits
    /// reconcile through it (strip the known stale prefix, keep the
    /// operator's newer input). Cleared on consume, submit, or buffer
    /// clear. Main task owns it; the input thread never reads it.
    private var staleTabEcho: String? = nil
    /// Undo groups previewed this session (M4-D D2 review): `/undo run`
    /// requires a prior preview of the SAME group (read before mutate).
    /// Set by the composition edge after a successful preview resolve;
    /// checked (and only checked) on the run path.
    private var previewedUndoGroups = Set<String>()
    private var confirmSlot: (box: ContinuationBox, saved: (text: String, cursor: Int)?)?
    /// Request-scoped liveness: tap callbacks register here; cancel
    /// and terminal outcomes clear the set (submissions deliberately
    /// do NOT — retiring on submit would drop the commit of a still
    /// streaming turn when a follow-up or inspect line is entered
    /// mid-stream; D7 review B4). Completions/progress for unknown
    /// requests drop — the generation-gated finalize (C5.5).
    private var liveRequests = Set<String>()
    /// Highest committed transport revision per request: a late
    /// completion for an older revision than the committed one drops
    /// (out-of-order invoke returns, e.g. post-cancel stragglers).
    private var committedRevisions: [String: UInt64] = [:]

    public init(config: Config, lineEditor: LineEditorSession, owner: TerminalOutputOwner) {
        self.config = config
        self.lineEditor = lineEditor
        self.owner = owner
    }

    // MARK: - Cross-thread entry points (any thread)

    /// Posts an event to the main loop (thread-safe).
    public func post(_ event: Event) {
        lock.withLock { inboxContinuation?.yield(event) }
    }

    /// Published accept snapshot for the bound Tab handler and tests
    /// (input thread, M4-D D2 review): the dispatch-time value — the
    /// input thread never reads live state. Nil ⇒ nothing to accept.
    public func acceptSnapshot() -> (base: String, display: String, cursor: Int)? {
        lock.withLock { publishedAccept }
    }

    /// Suggestion-live probe for the bound Up/Down handlers.
    public func isSuggestionLive() -> Bool {
        lock.withLock { suggestionLive }
    }

    /// Records a successfully resolved undo preview (edge-called).
    public func noteUndoPreviewed(_ groupID: String) {
        lock.withLock { previewedUndoGroups.insert(groupID) }
    }

    /// Whether this group was previewed (edge-checked before run).
    public func didPreviewUndo(_ groupID: String) -> Bool {
        lock.withLock { previewedUndoGroups.contains(groupID) }
    }

    /// Consumes the one-shot captured attachments stashed for the
    /// pending submit (M4-D D2 review C1). Called on the main task from
    /// the composition's effect closure.
    public func takePendingSubmitAttachments() -> [AttachmentSnapshot] {
        lock.withLock {
            let taken = pendingSubmitAttachments
            pendingSubmitAttachments = []
            return taken
        }
    }

    /// Arms confirm mode (called synchronously by the approval
    /// presenter on the actor thread, before the prompt renders). From
    /// here, the next `readLine` result is the decision, never a
    /// submission. The draft snapshot is filled by the main task (state
    /// owner) when it handles `.approvalArmed`; the input thread
    /// bounded-spins for it. The shared box converges every settle
    /// path (operator, cancel, loop exit): a settled box means the arm
    /// is stale and the next line submits normally instead of wedging.
    /// If the draft is non-empty at arm time, the prompt guides the
    /// operator to clear the line (idle Ctrl+C) and then answer y/N —
    /// the saved draft is restored after the decision either way.
    public func prepareConfirm(box: ContinuationBox) {
        lock.withLock {
            confirmSlot = (box, nil)
            confirmArmed = true
        }
    }

    // MARK: - Main loop (call once, awaits shutdown)

    /// Runs the loop. Production passes `scriptedInput: nil` (live
    /// replxx input thread). Tests pass scripted lines (no input
    /// thread, no TTY): each element feeds one `.inputLine`, `nil`
    /// feeds EOF. Deterministic: no timing dependence.
    public func run(scriptedInput: [String?]? = nil) async {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        lock.withLock { inboxContinuation = continuation }
        wireLineEditor()
        if let scriptedInput {
            Task { [weak self] in
                for line in scriptedInput {
                    self?.post(.inputLine(line))
                    if line == nil { break }
                }
            }
        } else {
            spawnInputThread()
        }
        // Initial snapshot + welcome render.
        await refreshSnapshot()
        renderFrame()
        for notice in config.startupNotices {
            owner.emit([DiffRenderer.receipt(notice, tone: .normal)], generation: owner.currentGeneration)
        }
        for await event in stream {
            await handle(event)
            if shutdown { break }
        }
        finish()
    }

    private func finish() {
        // Loop exit with an armed confirm denies it through the shared
        // box (never stranded, never double-resumed).
        lock.withLock {
            if let slot = confirmSlot {
                confirmSlot = nil
                confirmArmed = false
                slot.box.resumeDeny()
            }
            inboxContinuation?.finish()
            inboxContinuation = nil
        }
        owner.close()
    }

    // MARK: - Wiring

    private func wireLineEditor() {
        lineEditor.setModifyHandler { [weak self] text, cursor in
            guard let self else { return }
            // Confirm typing must not pollute the draft mirror: the
            // restorable draft is exact at arm time.
            let armed = self.lock.withLock { self.confirmArmed }
            if !armed { self.post(.mirror(text: text, cursor: cursor)) }
        }
        // (No replxx completion callback: Tab is loop-driven now —
        // the probe binary keeps the seam covered.)
        lineEditor.bindKey(code: LineEditorSession.tabKeyCode) { [weak self] in // Tab
            // M4-D D2 Tab-accept (spec §2.2): the input thread reads the
            // published snapshot ONLY (never live state — review), syncs
            // the live buffer (instant repaint), and posts `.tabAccept`
            // carrying the exact previewed values. The main task applies
            // the identical accept. Nil snapshot ⇒ post plain `.key(.tab)`
            // (a no-op without a live suggestion).
            guard let self else { return .continue }
            // Staleness check, still on-thread (D7 review B3): the
            // live buffer must still equal the snapshot base.
            // Keystrokes the main task has not processed yet mean the
            // snapshot (and its preview) is stale. A stale Tab is
            // IGNORED outright — never a partial accept, never a
            // clobber, never a main-thread buffer rewrite. The
            // operator re-tabs; Tab is idempotent.
            if let accepted = self.acceptSnapshot(),
               self.lineEditor.currentBufferText() == accepted.base {
                self.lineEditor.replaceBuffer(text: accepted.display, cursor: accepted.cursor)
                self.post(.tabAccept(base: accepted.base, display: accepted.display, cursor: accepted.cursor))
            } else if self.acceptSnapshot() == nil {
                self.post(.key(.tab))
            }
            return .continue
        }
        lineEditor.bindKey(code: LineEditorSession.upKeyCode) { [weak self] in // Up
            // M4-D D2 arrow selection: select while a suggestion is
            // live, history-navigate otherwise (bound keys replace the
            // default, so the fallback is invoked explicitly).
            guard let self else { return .continue }
            if self.isSuggestionLive() {
                self.post(.key(.up))
            } else {
                self.lineEditor.invokeHistoryPrevious()
            }
            return .continue
        }
        lineEditor.bindKey(code: LineEditorSession.downKeyCode) { [weak self] in // Down
            guard let self else { return .continue }
            if self.isSuggestionLive() {
                self.post(.key(.down))
            } else {
                self.lineEditor.invokeHistoryNext()
            }
            return .continue
        }
        lineEditor.bindKey(code: LineEditorSession.ctrlCKeyCode) { [weak self] in // Ctrl+C
            guard let self else { return .continue }
            // Bound keys skip replxx's default processing, so buffer
            // edits go through `set_state` (trampoline syncs the mirror).
            // Armed confirm ALWAYS clears (approvals arrive mid-run while
            // busy — cancelling would deny the pending request); busy
            // cancels via the actor; idle clears the LIVE buffer (mirror
            // converges, SPEC ¶746); idle-empty EXITS with nothing
            // pending (M4-D D2.5) or warns-then-exits on the second press
            // with queued work (`.abort` bails `readLine`, which returns
            // nil — the input thread posts EOF and the run shuts down).
            let action = self.lock.withLock {
                ComposerBridge.ctrlCAction(
                    busy: self.statusBusy, armed: self.confirmArmed,
                    draftNonEmpty: self.draftNonEmpty, queuePending: self.queuePending,
                    exitArmed: self.ctrlCExitArmed)
            }
            switch action {
            case .cancelRun:
                self.post(.cancelKey)
                return .continue
            case .clearBuffer:
                self.lineEditor.clearBuffer()
                return .continue
            case .warnPending:
                self.lock.withLock { self.ctrlCExitArmed = true }
                self.owner.emitText(ComposerBridge.pendingExitWarning, generation: self.owner.currentGeneration)
                return .continue
            case .exit:
                // `.abort` bails `readLine`, which returns nil; the
                // input thread then posts `.inputLine(nil)` and exits,
                // and the main task sets `shutdown` in
                // `handleSubmitLine` (main-owned — never written here,
                // so the input thread cannot race the main-task read).
                self.lock.withLock { self.ctrlCExitArmed = false }
                return .abort
            }
        }
        lineEditor.bindKey(code: LineEditorSession.ctrlJKeyCode) { [weak self] in // Ctrl+J
            // Newline goes into the LIVE buffer (set_state); the mirror
            // sync converges state. Never commits by itself.
            self?.lineEditor.insertNewline()
            return .continue
        }
        lineEditor.bindKey(code: LineEditorSession.escKeyCode) { [weak self] in // Esc
            self?.post(.key(.esc))
            return .continue
        }
        // Control-mapped ESC twin (whichever form the terminal layer
        // yields, dismiss is idempotent — the reducer noops with no
        // popup live).
        lineEditor.bindKey(code: LineEditorSession.escControlKeyCode) { [weak self] in // Esc (control form)
            self?.post(.key(.esc))
            return .continue
        }
        lineEditor.enableBracketedPaste()
    }

    private func spawnInputThread() {
        let editor = lineEditor
        let loop = self
        let thread = Thread {
            while true {
                let line = editor.readLine(prompt: "needletail> ")
                // Commit every accepted non-empty line to history
                // on the input thread (M4-D D7 review B2): replxx
                // itself only stages a scratch entry per read — the
                // application owns the commit. Without this call the
                // history stays empty forever (Up/Down/Ctrl+R find
                // nothing, and the D2.7 hygiene drop has no tail to
                // check). Decision lines are removed right after by
                // settleConfirm's hygiene drop.
                if let line, !line.isEmpty { editor.addHistoryEntry(line) }
                let armed = loop.lock.withLock { loop.confirmArmed }
                if armed {
                    loop.settleConfirm(line: line, fromMain: false)
                } else {
                    loop.post(.inputLine(line))
                    if line == nil { break }
                }
            }
        }
        thread.name = "needletail-input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Settles an armed confirm: resumes the shared box, restores the
    /// saved draft for the next `readLine` (preload — consumed after
    /// replxx clears, so the draft returns verbatim), and notifies the
    /// main loop for state reset. A box settled by cancellation makes
    /// the arm stale: the line is re-dispatched as a normal submission
    /// instead of wedging. The saved draft is filled by the main task
    /// on `.approvalArmed`; the live input thread bounded-spins (≤1 s)
    /// for it, the main task (scripted/test path) fills it directly.
    private func settleConfirm(line: String?, fromMain: Bool) {
        if fromMain {
            lock.withLock {
                if confirmSlot?.saved == nil {
                    confirmSlot?.saved = (state.composer.text, state.composer.cursor)
                }
            }
        } else {
            var spins = 0
            var filled = lock.withLock { confirmSlot?.saved != nil }
            while !filled, spins < 200 {
                Thread.sleep(forTimeInterval: 0.005)
                spins += 1
                filled = lock.withLock { confirmSlot?.saved != nil }
            }
        }
        let slot = lock.withLock { () -> (box: ContinuationBox, saved: (text: String, cursor: Int)?)? in
            let taken = confirmSlot
            confirmSlot = nil
            confirmArmed = false
            return taken
        }
        guard let (box, saved) = slot else { return }
        if box.isSettled {
            // Stale arm (cancelled/superseded): normal submission path —
            // but the decision line was already auto-committed to history
            // on accept, so drop it first (D2.7: no persisted decision
            // lines on ANY path through the confirm gate).
            if let line, !line.isEmpty, !fromMain {
                if !lineEditor.dropLastHistoryEntry(matching: line) {
                    post(.notice("confirm hygiene: decision line not found in history; it may persist — press Up-arrow to check", .warning))
                }
            }
            post(.inputLine(line))
            return
        }
        // M4-D D2.7 hygiene: the decision line was auto-committed by
        // replxx on accept — drop it so `y`/`N` never persists in
        // history. A non-matching tail is left untouched (fail-safe),
        // but its absence IS the hygiene check failing (D7 review B2):
        // surface it loudly — a persisted decision line is a
        // privacy-class defect, never a silent no-op.
        // (Scripted/fromMain confirms have no live history by
        // construction — the input loop commits it — so the warning
        // fires only on the live path where the tail must be present.)
        if let line, !line.isEmpty, !fromMain {
            if !lineEditor.dropLastHistoryEntry(matching: line) {
                post(.notice("confirm hygiene: decision line not found in history; it may persist — press Up-arrow to check", .warning))
            }
        } else if let line, !line.isEmpty {
            _ = lineEditor.dropLastHistoryEntry(matching: line)
        }
        box.resume(ComposerBridge.interpretConfirmLine(line) ? .approve : .deny("operator did not explicitly approve"))
        if let saved {
            lineEditor.preload(saved.text)
            post(.confirmDone(savedText: saved.text, savedCursor: saved.cursor))
        } else {
            post(.notice("approval draft restore timed out; retype if needed", .warning))
        }
    }

    // MARK: - Event handling (main task)

    private func handle(_ event: Event) async {
        switch event {
        case .projection(let projection):
            dispatch([.session(projection)])
            // Terminal outcomes retire every live request (display
            // finalizes per invoke return; terminal projections drop).
            // M4-D D1 composition finding: the actor never emits the
            // `run_finished` envelope to the UI sink (headless mints it
            // via `emitTerminal` for JSONL); interactive terminality
            // arrives as `run:<phase>` updates. Both retire.
            if ChatLoop.isTurnTerminal(projection) {
                liveRequests.removeAll()
                committedRevisions.removeAll()
                owner.setProgress(nil, generation: owner.currentGeneration)
            }
            // Deltas never change queue/approval truth: skip the actor
            // round-trip per chunk (snapshot on structural projections).
            if projection.kind != "delta" {
                await refreshSnapshot()
            }
            renderFrame()
            // M4-D D2.4: turn-finished tool-result display (composition
            // hook; the loop stays store-free).
            if ChatLoop.isTurnTerminal(projection) {
                await config.onTurnFinished?()
            }
        case .tapProgress(let requestID, let bytes):
            // The tap only fires while the transport invoke is
            // in-flight, so progress registers liveness. Completion
            // requires registration (finalize gate); explicit cancel
            // and terminal outcomes clear the set — submissions do
            // NOT (D7 review B4). C5.5.
            liveRequests.insert(requestID.raw)
            owner.setProgress("streaming… \(bytes) bytes", generation: owner.currentGeneration)
        case .tapComplete(let requestID, let revision, let text):
            owner.setProgress(nil, generation: owner.currentGeneration)
            guard liveRequests.remove(requestID.raw) != nil else { return }
            // Numeric generation gate on top of liveness: a completion
            // older than the committed revision for the same request
            // (out-of-order invoke return) drops, never commits twice.
            if let committed = committedRevisions[requestID.raw], revision.value < committed { return }
            committedRevisions[requestID.raw] = revision.value
            if let text {
                let context = RenderContext(sessionID: config.sessionID, requestID: requestID.raw)
                let rendered = renderMarkdownBlock(text, context: context)
                owner.emit(rendered, generation: owner.currentGeneration)
            }
        case .tapTruncated(let requestID):
            guard liveRequests.contains(requestID.raw) else { return }
            owner.emitText("…[stream truncated: display bound 1 MiB]", generation: owner.currentGeneration, lane: .control, role: .warning)
        case .completions(let query, let revision, let candidates):
            _ = query
            // M4-D D2: candidates land in reducer state (the suggestion
            // popup + Tab-accept read them from there). Stale revisions
            // drop in the reducer (DX-02); the sync-serve cache is gone.
            let effects = dispatch([.completion(CompletionResult(queryRevision: revision, candidates: candidates))])
            await config.onEffects(effects)
            renderFrame()
        case .notice(let text, let tone):
            owner.emit([DiffRenderer.receipt(text, tone: tone)], generation: owner.currentGeneration)
        case .inspection(let result):
            let effects = dispatch([.inspectResult(result)])
            if !effects.isEmpty { await config.onEffects(effects) }
            renderFrame()
        case .inputLine(let line):
            lock.withLock { ctrlCExitArmed = false }
            await handleSubmitLine(line)
        case .mirror(let text, let cursor):
            lock.withLock { ctrlCExitArmed = false }
            // Dropped-accept echo suppression (D7 review B3): the
            // mirror queued immediately behind a dropped `.tabAccept`
            // carries the stale display the input thread painted — it
            // is that echo, not new input. Drop it, but KEEP the park:
            // the live buffer still shows the stale display, so the
            // divergence persists until a later mirror or the submit
            // reconciles it below.
            if let stale = lock.withLock({ staleTabEcho }), stale == text {
                return
            }
            if let stale = lock.withLock({ staleTabEcho }) {
                // Diverged live buffer (see `.tabAccept` drop): the
                // line still shows `stale`. Strip that known prefix and
                // apply only the operator's newer input to the state
                // text (typing is overwhelmingly at end-of-line; the
                // cursor lands at end — documented approximation for a
                // race that must never clobber).
                if text.hasPrefix(stale) {
                    let merged = state.composer.text + text.dropFirst(stale.count)
                    lock.withLock { staleTabEcho = nil }
                    let actions = ComposerBridge.actionsForMirror(text: merged, cursor: merged.unicodeScalars.count, state: state)
                    if !actions.isEmpty {
                        let effects = dispatch(actions)
                        await config.onEffects(effects)
                        renderFrame()
                    }
                    return
                }
                lock.withLock { staleTabEcho = nil }
            }
            let actions = ComposerBridge.actionsForMirror(text: text, cursor: cursor, state: state)
            if !actions.isEmpty {
                let effects = dispatch(actions)
                await config.onEffects(effects)
                renderFrame()
            }
        case .cancelKey:
            // Decided-cancel (see Event.cancelKey): no recompute.
            let effects = dispatch([.queueOp(.cancelRun)])
            await config.onEffects(effects)
            liveRequests.removeAll()
            committedRevisions.removeAll()
            owner.invalidate()
            renderFrame()
        case .tabAccept(let base, let display, _):
            // Recompute-equality gate (D7 review B3): apply ONLY the
            // exact accept the input thread previewed. The live
            // acceptPreview is recomputed from CURRENT state and must
            // equal the carried display, and state text must still
            // equal the base. A selection change (Up/Down raced Tab)
            // or a candidates refresh (completions raced Tab) alters
            // the recomputed accept, and the stale preview DROPS —
            // never a partial accept, never a wrong-file token.
            if state.composer.text == base,
               let now = ComposerBridge.acceptPreview(state: state),
               now.text == display {
                let effects = dispatch([.mention(.acceptSelected)])
                if !effects.isEmpty { await config.onEffects(effects) }
                renderFrame()
            } else {
                // Stale accept dropped: the input thread already
                // painted `display` into the live buffer and its
                // trailing mirror echo is queued right behind this
                // event. Park the display so that echo is suppressed
                // below — never re-applied as tokenless text (the
                // buffer/state reconverge through the mirror and
                // submit reconcile). No replxx calls from the main
                // task: the input thread owns the live buffer.
                lock.withLock { staleTabEcho = display }
            }
            return
        case .key(let key):
            if key == .ctrlC {
                await handleCtrlCKey()
                return
            }
            // Any other key disarms the two-press exit latch.
            lock.withLock { ctrlCExitArmed = false }
            switch key {
            case .tab:
                // Back-compat/test path: gate on live state (the input
                // thread posts `.tabAccept` with the snapshot instead).
                if ComposerBridge.acceptPreview(state: state) != nil {
                    let effects = dispatch([.mention(.acceptSelected)])
                    if !effects.isEmpty { await config.onEffects(effects) }
                    renderFrame()
                }
                return
            case .up:
                let effects = dispatch([.mention(.selectPrevious)])
                if !effects.isEmpty { await config.onEffects(effects) }
                renderFrame()
                return
            case .down:
                let effects = dispatch([.mention(.selectNext)])
                if !effects.isEmpty { await config.onEffects(effects) }
                renderFrame()
                return
            default:
                break
            }
            let actions = ComposerBridge.actionsForKey(key, state: state)
            if !actions.isEmpty {
                // Cancellation retires live display requests too.
                if actions.contains(.queueOp(.cancelRun)) {
                    liveRequests.removeAll()
                    committedRevisions.removeAll()
                    owner.invalidate()
                }
                let effects = dispatch(actions)
                await config.onEffects(effects)
                renderFrame()
            }
        case .approvalArmed(let request):
            // Main task owns state: snapshot the restorable draft into
            // the armed slot, then render the actionable prompt on the
            // control lane (validated ops + bound exec identities +
            // protected paths — display only, never granted here).
            // Modify events stay skipped while armed, so the mirror is
            // exact at this boundary. Non-empty drafts: clear the line
            // (idle Ctrl+C) and answer y/N; the draft is restored after.
            lock.withLock {
                if confirmSlot != nil {
                    confirmSlot?.saved = (state.composer.text, state.composer.cursor)
                    confirmArmed = true
                }
            }
            var prompt: [RenderedLine] = [
                RenderedLine(spans: [TextSpan(text: "approval required: \(displaySafe(request.operation)) [\(displaySafe(request.requiredGrant))]", role: .candidateSelected)]),
                RenderedLine(spans: [TextSpan(text: "clear the line (Ctrl+C), then answer y/N (draft preserved)", role: .normal)]),
            ]
            for path in request.protectedPaths {
                prompt.append(RenderedLine(spans: [TextSpan(text: "  path: \(displaySafe(path))", role: .normal)]))
            }
            for identity in request.execIdentities {
                prompt.append(RenderedLine(spans: [TextSpan(text: "  exec: \(displaySafe(identity.resolvedPath))#\(displaySafe(identity.contentDigest))", role: .filePath)]))
            }
            // M4-D D1: exact approval requests — every validated proposal
            // renders its tool + truncated sanitized arguments (the
            // executable identity for non-exec tools). Display only.
            for proposal in request.batch.proposals {
                var detail = "  tool: \(displaySafe(proposal.tool))"
                if let args = proposal.arguments, !args.isEmpty {
                    let clipped = String(args.prefix(200))
                    detail += " \(displaySafe(clipped))" + (args.count > 200 ? "…" : "")
                }
                prompt.append(RenderedLine(spans: [TextSpan(text: detail, role: .filePath)]))
            }
            owner.emit(prompt, generation: owner.currentGeneration, lane: .control)
        case .confirmDone(let savedText, _):
            // Exact-sync the mirror back to the saved draft (the typed
            // decision line never entered state — mirroring was skipped
            // while armed). Skip the replace when state already matches:
            // the normal path leaves composer, suggestion AND tokens
            // untouched (an approval round-trip must not silently drop
            // accepted file identities — M4-D review C2). Drift
            // (shouldn't happen) still converges via replaceDraft.
            if state.composer.text != savedText {
                _ = dispatch([.input(.replaceDraft(savedText))])
            }
            renderFrame()
        }
    }

    /// Scripted/test Ctrl+C: the same latch-aware decision as the live
    /// bindKey path, acting on state (no replxx buffer here). Idle-empty
    /// with nothing pending shuts the run down (M4-D D2.5); with queued
    /// work the first press warns and arms the latch, the second exits.
    /// Exit is confirmed against a fresh actor snapshot (never from a
    /// stale status — a finishing run must cancel, not exit).
    private func handleCtrlCKey() async {
        var action = currentCtrlCAction()
        if action == .exit {
            await refreshSnapshot()
            action = currentCtrlCAction()
        }
        switch action {
        case .cancelRun:
            let effects = dispatch([.queueOp(.cancelRun)])
            await config.onEffects(effects)
            liveRequests.removeAll()
            committedRevisions.removeAll()
            owner.invalidate()
            renderFrame()
        case .clearBuffer:
            let effects = dispatch([.input(.replaceDraft(""))])
            await config.onEffects(effects)
            renderFrame()
        case .warnPending:
            lock.withLock { ctrlCExitArmed = true }
            owner.emit([DiffRenderer.receipt(ComposerBridge.pendingExitWarning, tone: .warning)], generation: owner.currentGeneration)
            renderFrame()
        case .exit:
            lock.withLock { ctrlCExitArmed = false }
            shutdown = true
        }
    }

    /// Main-task Ctrl+C decision on live state (freshest — the input
    /// thread uses lock snapshots). Used by the scripted path and the
    /// exit-confirmation recompute.
    private func currentCtrlCAction() -> ComposerBridge.CtrlCAction {
        let busy: Bool = {
            if case .busy = state.status { return true }
            return false
        }()
        let armed = lock.withLock { confirmArmed }
        let exitArmed = lock.withLock { ctrlCExitArmed }
        return ComposerBridge.ctrlCAction(
            busy: busy, armed: armed,
            draftNonEmpty: !state.composer.text.isEmpty,
            queuePending: ComposerBridge.hasPendingQueueEntries(state: state), exitArmed: exitArmed)
    }

    /// Turn-terminal projection kinds (M4-D D1 + review C3 + D7
    /// review B4): `run_finished` plus the terminal `run:<phase>`
    /// updates the actor actually emits to the UI sink
    /// (completed/failed/interrupted/budget-boundary). `denied` is
    /// NOT terminal: Core emits denials for non-terminal mid-run
    /// refusals (queue ops while busy, stale revisions, unquiescent
    /// undo, reconcile blocks) — retiring liveness or firing the
    /// turn hook on them would drop in-flight commits and end turns
    /// that never ended. Non-terminal phases (queue/model/epoch/
    /// tool-exec/undo/authorising/cancelling) and hint kinds
    /// (delta/admitted/agent) never retire live requests or fire
    /// the turn hook.
    static func isTurnTerminal(_ projection: SessionEventProjection) -> Bool {
        if projection.kind == "run_finished" { return true }
        guard projection.kind.hasPrefix("run:") else { return false }
        let phase = String(projection.kind.dropFirst("run:".count))
        return phase == "completed" || phase == "failed"
            || phase == "interrupted" || phase == "budget-boundary"
    }

    private func handleSubmitLine(_ line: String?) async {
        // Scripted/test path honors arming (the live input thread
        // settles before posting, so this branch is test-only).
        if lock.withLock({ confirmArmed }) {
            settleConfirm(line: line, fromMain: true)
            return
        }
        // Diverged-buffer reconcile (D7 review B3): the committed
        // line comes from the live buffer, which may still show a
        // dropped Tab preview. Strip that known stale prefix and
        // submit the state text plus only the operator's newer input.
        // The park is cleared ONLY when the strip applies: an
        // unrelated line (e.g. an inspect slash while diverged) must
        // not consume it — the buffer is still diverged afterwards.
        var line = line
        if let stale = lock.withLock({ staleTabEcho }),
           let committed = line, committed.hasPrefix(stale) {
            line = state.composer.text + committed.dropFirst(stale.count)
            lock.withLock { staleTabEcho = nil }
        }
        guard let line else {
            // EOF on an unarmed line: graceful shutdown (replxx restores
            // the terminal on readLine return; M4-D owns full lifecycle).
            shutdown = true
            return
        }
        if line.isEmpty {
            // Empty Enter: ignored (never submits, never queues).
            return
        }
        let commandID = commandIDs.id(for: line, mint: config.mintCommandID)
        switch ComposerBridge.actionsForSubmitLine(line, state: state, commandID: commandID) {
        case .actions(let actions):
            // Submit gate BEFORE dispatch (M4-D D2 review C1): budget
            // and attach refusals must preserve the draft, tokens and
            // queue — dispatch would clear them. Only submit-like
            // actions consult the gate.
            let dispatchesProviderTraffic = actions.contains { action in
                switch action {
                case .input(.submitDraft(commandID: _)): return true
                case .queueOp(.submitFollowUp(text: _, commandID: _)),
                     .queueOp(.submitSteer(text: _, commandID: _)): return true
                default: return false
                }
            }
            if dispatchesProviderTraffic, let gate = config.submitGate {
                switch await gate(SubmitGateContext(line: line, tokens: state.tokens)) {
                case .refuse(let message, let tone):
                    owner.emit([DiffRenderer.receipt(message, tone: tone)], generation: owner.currentGeneration)
                    renderFrame()
                    return
                case .proceed(let attachments):
                    lock.withLock { pendingSubmitAttachments = attachments }
                }
            }
            if dispatchesProviderTraffic {
                // A new turn takes over the transient display
                // generation (in-flight progress rows belong to the
                // previous turn). Liveness sets are NOT retired here:
                // terminal projections and explicit cancel own them —
                // retiring on submit would drop the commit of a still
                // streaming turn whenever a follow-up or inspect line
                // is entered mid-stream (D7 review B4).
                owner.invalidate()
                // A committed line ends any Tab-drop divergence: the
                // next readLine starts fresh (D7 review B3).
                lock.withLock { staleTabEcho = nil }
            }
            // @-mention tokens ride the submit for fd-pinned capture in
            // the composition edge (M4-D D2.1); refusal/failure there is
            // explicit, never silent.
            let effects = dispatch(actions)
            await config.onEffects(effects)
            await refreshSnapshot()
            renderFrame()
        case .rejected(let reason):
            owner.emitText(reason, generation: owner.currentGeneration, lane: .control, role: .warning)
        case .notice(let text, let actions):
            owner.emit([DiffRenderer.receipt(text, tone: .normal)], generation: owner.currentGeneration)
            let effects = dispatch(actions)
            await config.onEffects(effects)
            renderFrame()
        }
    }

    /// Applies actions (pure reduce), refreshes cross-thread snapshots,
    /// and returns the effects for the edge. Never awaits while
    /// dispatching — the reducer stays synchronous and ordered.
    @discardableResult
    private func dispatch(_ actions: [UIAction]) -> [UIEffect] {
        var effects: [UIEffect] = []
        for action in actions {
            let (next, fx) = reduce(state, action)
            state = next
            effects.append(contentsOf: fx)
        }
        lock.withLock {
            statusBusy = {
                if case .busy = state.status { return true }
                return false
            }()
            draftNonEmpty = !state.composer.text.isEmpty
            queuePending = ComposerBridge.hasPendingQueueEntries(state: state)
            suggestionLive = state.suggestion != nil
            // Publish the accept snapshot for the input thread (M4-D D2
            // review: the ONLY cross-thread Tab state — immutable).
            if let accepted = ComposerBridge.acceptPreview(state: state) {
                publishedAccept = (base: state.composer.text, display: accepted.text, cursor: accepted.cursor)
            } else {
                publishedAccept = nil
            }
        }
        return effects
    }

    private func refreshSnapshot() async {
        let snapshot = await config.snapshotProvider()
        dispatch([.queueSync(snapshot)])
    }

    private func renderFrame() {
        let width = TerminalCaps.resolveColumns(env: ProcessInfo.processInfo.environment, explicit: nil, ioctlWidth: TerminalCaps.ioctlColumns())
        var caps = config.caps
        caps.width = width
        let pcap = TerminalCapabilities(
            color: caps.color ? .sixteen : .none,
            cursorAddressing: caps.cursorAddressing)
        let frame = ComposerBridge.frameForInteractive(render(state, width: width, capabilities: pcap))
        var fresh: [RenderedLine] = []
        for line in frame.lines {
            let text = line.runs.map { $0.text }.joined()
            if let known = emitted.first(where: { $0.id == line.id }) {
                if known.text != text {
                    if let index = emitted.firstIndex(where: { $0.id == line.id }) {
                        emitted[index] = (line.id, text)
                    }
                    fresh.append(semanticToTerminal(line))
                }
            } else {
                emitted.append((line.id, text))
                if emitted.count > 1024 { emitted.removeFirst(emitted.count - 1024) }
                fresh.append(semanticToTerminal(line))
            }
        }
        if !fresh.isEmpty {
            owner.emit(fresh, generation: owner.currentGeneration)
        }
    }

    private func semanticToTerminal(_ line: SemanticLine) -> RenderedLine {
        RenderedLine(spans: line.runs.map { TextSpan(text: $0.text, role: $0.role) })
    }
}
