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
        case inputLine(String?)
        case mirror(text: String, cursor: Int)
        case key(ComposerBridge.KeyPress)
        case approvalArmed(ApprovalRequest)
        case confirmDone(savedText: String, savedCursor: Int)
    }

    public struct Config: Sendable {
        public var caps: TerminalCaps
        public var sessionID: String
        public var snapshotProvider: @Sendable () async -> QueueSyncSnapshot
        public var onEffects: @Sendable ([UIEffect]) async -> Void
        public var mintCommandID: @Sendable () -> CommandID

        public init(
            caps: TerminalCaps,
            sessionID: String,
            snapshotProvider: @escaping @Sendable () async -> QueueSyncSnapshot,
            onEffects: @escaping @Sendable ([UIEffect]) async -> Void,
            mintCommandID: @escaping @Sendable () -> CommandID
        ) {
            self.caps = caps
            self.sessionID = sessionID
            self.snapshotProvider = snapshotProvider
            self.onEffects = onEffects
            self.mintCommandID = mintCommandID
        }
    }

    private let config: Config
    private let lineEditor: LineEditorSession
    private let owner: TerminalOutputOwner

    private var state = UIState()
    private var cache = ComposerBridge.CompletionCache()
    private var commandIDs = ComposerBridge.CommandIDStore()
    private var emitted: [(id: String, text: String)] = []
    private var shutdown = false
    private var confirmArmed = false

    private let lock = NSLock()
    private var inboxContinuation: AsyncStream<Event>.Continuation?
    // Locked cross-thread snapshots (key handlers + sync completion).
    private var statusBusy = false
    private var draftNonEmpty = false
    private var serveRevision: UInt64?
    private var serveQuery: String?
    private var servePaths: [String] = []
    private var confirmSlot: (box: ContinuationBox, saved: (text: String, cursor: Int)?)?
    /// Request-scoped liveness: tap callbacks register here; cancel,
    /// submit and terminal outcomes clear it. Completions/progress for
    /// unknown requests drop — the generation-gated finalize (C5.5).
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

    /// Sync completion serve for replxx (input thread). Serves ONLY the
    /// live revision+query (DX-02); Tab mid-line serves nothing.
    public func serveCompletion(input: String) -> [String] {
        lock.withLock {
            // serveRevision/serveQuery are refreshed on every dispatch;
            // a query match against the input gates staleness (the main
            // loop clears them on revision change, so a concurrent Tab
            // sees a self-consistent snapshot either way).
            guard serveRevision != nil, let query = serveQuery else { return [] }
            guard let live = mentionQuery(text: input, cursor: input.unicodeScalars.count),
                  live.query == query else { return [] }
            return servePaths
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
        lineEditor.setCompletionHandler { [weak self] input in
            self?.serveCompletion(input: input) ?? []
        }
        lineEditor.bindKey(code: 3) { [weak self] in // Ctrl+C
            guard let self else { return .continue }
            // Bound keys skip replxx's default processing, so buffer
            // edits go through `set_state` (trampoline syncs the mirror).
            // Armed confirm ALWAYS clears (approvals arrive mid-run while
            // busy — cancelling would deny the pending request); busy
            // cancels via the actor; idle clears the LIVE buffer (mirror
            // converges, SPEC ¶746); idle-empty hints.
            let action = self.lock.withLock {
                ComposerBridge.ctrlCAction(busy: self.statusBusy, armed: self.confirmArmed, draftNonEmpty: self.draftNonEmpty)
            }
            switch action {
            case .cancelRun:
                self.post(.key(.ctrlC))
            case .clearBuffer:
                self.lineEditor.clearBuffer()
            case .hint:
                self.owner.emitText(ComposerBridge.idleEmptyHint, generation: self.owner.currentGeneration)
            }
            return .continue
        }
        lineEditor.bindKey(code: 10) { [weak self] in // Ctrl+J
            // Newline goes into the LIVE buffer (set_state); the mirror
            // sync converges state. Never commits by itself.
            self?.lineEditor.insertNewline()
            return .continue
        }
        lineEditor.bindKey(code: 27) { [weak self] in // Esc
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
            // Stale arm (cancelled/superseded): normal submission path.
            post(.inputLine(line))
            return
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
            // finalizes per invoke return; run_finished only drops).
            if projection.kind == "run_finished" {
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
        case .tapProgress(let requestID, let bytes):
            // The tap only fires while the transport invoke is
            // in-flight, so progress registers liveness. Completion
            // requires registration (finalize gate); cancel, submit
            // and terminal outcomes clear the set — C5.5.
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
                owner.emit(renderMarkdownBlock(text, context: context), generation: owner.currentGeneration)
            }
        case .tapTruncated(let requestID):
            guard liveRequests.contains(requestID.raw) else { return }
            owner.emitText("…[stream truncated: display bound 1 MiB]", generation: owner.currentGeneration, lane: .control, role: .warning)
        case .completions(let query, let revision, let candidates):
            _ = query
            cache.store(candidates, revision: revision)
            refreshServeState()
        case .notice(let text, let tone):
            owner.emit([DiffRenderer.receipt(text, tone: tone)], generation: owner.currentGeneration)
        case .inputLine(let line):
            await handleSubmitLine(line)
        case .mirror(let text, let cursor):
            let actions = ComposerBridge.actionsForMirror(text: text, cursor: cursor, state: state)
            if !actions.isEmpty {
                let effects = dispatch(actions)
                await config.onEffects(effects)
                renderFrame()
            }
        case .key(let key):
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
            owner.emit(prompt, generation: owner.currentGeneration, lane: .control)
        case .confirmDone(let savedText, _):
            // Exact-sync the mirror back to the saved draft (the typed
            // decision line never entered state — mirroring was skipped
            // while armed). replaceDraft also clears any suggestion the
            // decision keystrokes may have opened.
            _ = dispatch([.input(.replaceDraft(savedText))])
            renderFrame()
        }
    }

    private func handleSubmitLine(_ line: String?) async {
        // Scripted/test path honors arming (the live input thread
        // settles before posting, so this branch is test-only).
        if lock.withLock({ confirmArmed }) {
            settleConfirm(line: line, fromMain: true)
            return
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
        // A new submission retires every live request (display
        // finalizes per invoke return; the new turn owns the stream).
        liveRequests.removeAll()
        committedRevisions.removeAll()
        owner.invalidate()
        switch ComposerBridge.actionsForSubmitLine(line, state: state, commandID: commandID) {
        case .actions(let actions):
            // @-mention tokens are display-respected but not yet
            // attached in chat (fd-pinned capture edge deferred, M4-D):
            // honest notice instead of silent loss.
            if !state.tokens.isEmpty {
                owner.emit([DiffRenderer.receipt("@-mentions noted (attach not yet wired in chat; text submits without files)", tone: .warning)], generation: owner.currentGeneration)
            }
            let effects = dispatch(actions)
            await config.onEffects(effects)
            cache.dropAll()
            refreshServeState()
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
        }
        refreshServeState()
        return effects
    }

    private func refreshServeState() {
        lock.withLock {
            if let suggestion = state.suggestion,
               suggestion.revision == state.composer.revision,
               let cached = cache.candidates(forRevision: suggestion.revision) {
                serveRevision = suggestion.revision
                serveQuery = suggestion.query
                // SAME rule as the bridge (single predicate): only
                // display-safe paths reach replxx's direct render.
                servePaths = cached.map(\.path).filter(ComposerBridge.isDisplaySafePath)
            } else {
                serveRevision = nil
                serveQuery = nil
                servePaths = []
            }
        }
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
