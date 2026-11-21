import Foundation
import NeedletailPresentation

/// M4-C single terminal output owner (adapter tier).
///
/// ALL model deltas, tool events, approval prompts, status changes and
/// composer redraws pass through one instance with one writer thread —
/// there is no second output path. `emit` only enqueues under a lock
/// (never blocks on the writer), so calling from any thread — including
/// the actor's cooperative executor — cannot stall it; a dedicated
/// blocking thread owns every byte handed to `writer`. The actor never
/// touches the owner (the gateway's presenter posts to the adapter
/// runloop and suspends; actual writes happen on the owner thread).
///
/// Bounds (never an unbounded accumulator): pending droppable quota
/// 512 items / 1 MiB — over-quota keeps the TAIL (newest) with one
/// visible `…[output truncated]` marker head (never silent). Adjacent
/// progress updates coalesce to the latest write (throttle 10 Hz).
/// Committed content lines are never merged (scrollback fidelity).
/// Control lane (approval prompts, errors, `run_finished`): cap 64 is
/// a drain-priority threshold, NEVER a drop — over-cap sets the urgent
/// flag and the loop drains controls first, still ordered. Stale
/// generations (cancelled/superseded redraws) drop at enqueue, never
/// emit. `NO_COLOR`/dumb/non-TTY route through the same owner with
/// the ANSI stage disabled.
///
/// Shutdown: `close()` stops the writer thread (tests + loop exit).
/// The `writer` closure must not reenter `close()`/`flush()`.
public final class TerminalOutputOwner: @unchecked Sendable {
    public enum Lane: Sendable { case droppable, control }
    public struct EmitResult: Sendable, Equatable {
        public var written: Int
        public var truncated: Int
        public var droppedStale: Bool
        public var controlOverflow: Bool
    }

    public static let maxDroppableItems = 512
    public static let maxDroppableBytes = 1 * 1024 * 1024
    public static let maxControlItems = 64
    /// Transient progress redraw floor (max 10 Hz; adjacent updates
    /// coalesce to the latest).
    public static let minProgressInterval: TimeInterval = 0.1

    // Single lock domain: `work` (an NSCondition) guards ALL mutable
    // state (queues, progress, generation, caps). No second mutex —
    // no cross-domain data race (TSAN-clean by construction).
    private let work = NSCondition()
    private var pendingDroppable: [RenderedLine] = []
    private var pendingControl: [RenderedLine] = []
    private var pendingProgress: (text: String?, generation: UInt64)?
    private var lastProgressEnqueue: Date?
    private var progressShown = false
    private var generation: UInt64 = 0
    private var inFlight = 0
    private var stopped = false
    /// M4-MAC-02: set before a BAIL unwind so the composer's remaining
    /// renders never race replxx's terminal restore (Darwin tcsetattr
    /// TCSADRAIN blocks forever while writes keep refilling the tty
    /// output queue — the root cause of the C1/C2 exit hangs).
    private var quiesced = false
    /// M4-MAC-04B: set by silence() before the terminal-restore barrier.
    /// After it, the writer loop never captures a batch again — queued
    /// work is dropped and no future emission is accepted — so no write
    /// can start after the restore sequence begins.
    private var silenced = false
    /// M4-MAC-04B: serializes the writer's write section against the
    /// terminal-restore barrier. The writer holds it for the duration
    /// of its batch writes; beginRestoreBarrier() acquires it, which
    /// returns only when every accepted write has completed and no
    /// further write can start (silence() precedes it). This is the
    /// proof obligation for "the writer cannot emit after terminal
    /// restoration": writes either completed before the barrier or
    /// were dropped at the capture re-check.
    private let writeLock = NSLock()
    /// M4-MAC-04B: the always-consistent read of `silenced` for the
    /// per-line gate inside the write section (the write section runs
    /// off the work lock; this tiny lock makes the gate race-free).
    private let gateLock = NSLock()
    private var silencedGate = false

    private var silencedNow: Bool {
        gateLock.withLock { silencedGate }
    }

    /// Stops ALL further emissions (queued and future). The writer
    /// thread keeps running until stop() so teardown semantics are
    /// unchanged; nothing is written after this returns.
    ///
    /// BOUNDED by design: it returns once the in-flight straggler window
    /// has expired (500 ms). A writer still writing at that point is
    /// handled by the M4-MAC-04B teardown sequence — silence() then
    /// beginRestoreBarrier() — which guarantees the terminal restore
    /// never overlaps a write; quiesce itself never blocks unboundedly.
    public func quiesce() {
        work.lock()
        quiesced = true
        pendingDroppable.removeAll()
        pendingControl.removeAll()
        pendingProgress = nil
        work.broadcast()
        // Wait — BOUNDED — for the batch the writer may have already
        // captured: a batch in flight would otherwise still hit the tty
        // during the unwind. The wait CANNOT be unbounded: the writer's
        // writes go through replxx's notification pipe, which the
        // CALLING thread (input) drains — a full pipe plus an
        // unbounded wait is exactly the circular wait this method must
        // not create (observed: the terminal left raw at a forced
        // exit, because the unwind never ran). 500 ms bounds the
        // straggler batch; anything still writing is abandoned and the
        // BAIL unwind (instant TCSANOW restore) proceeds.
        var waitedMs = 0
        while inFlight > 0 && waitedMs < 500 {
            work.unlock()
            usleep(10_000)
            waitedMs += 10
            work.lock()
        }
        work.unlock()
    }

    /// M4-MAC-04B: permanently stops the writer from capturing or
    /// writing. Pending work is dropped. Unlike quiesce() this is not
    /// reversible by design — it precedes the terminal-restore barrier.
    /// Idempotent; safe from any thread.
    public func silence() {
        gateLock.withLock { silencedGate = true }
        work.lock()
        silenced = true
        pendingDroppable.removeAll()
        pendingControl.removeAll()
        pendingProgress = nil
        work.broadcast()
        work.unlock()
    }

    /// M4-MAC-04B: blocks BOUNDEDLY until the writer is between writes
    /// (or done), then holds that guarantee. Call silence() first —
    /// otherwise new captures could still start. Returns true when the
    /// gate was acquired (every accepted write completed; the restore
    /// cannot overlap a write), false on timeout: a writer still stuck
    /// mid-write (Darwin: blocked on replxx's notification pipe, which
    /// nobody drains after the unwind) cannot emit while blocked, and
    /// the ChatLoop teardown watchdog bounds the process either way.
    /// Pair with endRestoreBarrier() only on true.
    public func beginRestoreBarrier(timeoutMs: Int = 500) -> Bool {
        let polls = timeoutMs / 10
        for _ in 0 ..< polls {
            if writeLock.try() { return true }
            usleep(10_000)
        }
        return false
    }

    /// Releases the restore barrier acquired by beginRestoreBarrier().
    /// No-op when the barrier timed out (nothing to release).
    public func endRestoreBarrier() {
        writeLock.unlock()
    }

    private var finished = false
    private var writerThread: Thread?

    private let writer: @Sendable (String) -> Void
    private var caps: TerminalCaps
    private let now: @Sendable () -> Date

    public init(
        caps: TerminalCaps = TerminalCaps(),
        writer: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.caps = caps
        self.writer = writer
        self.now = now
        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.name = "needletail-output-owner"
        thread.qualityOfService = .userInteractive
        self.writerThread = thread
        thread.start()
    }

    // deinit never joins: stop + broadcast only (a join could hang
    // if the writer thread never started; explicit close() drains).
    deinit {
        work.lock()
        stopped = true
        work.broadcast()
        work.unlock()
    }

    /// Stops the writer thread after draining. Idempotent.
    public func close() {
        work.lock()
        stopped = true
        work.broadcast()
        while !finished { work.wait() }
        work.unlock()
    }

    /// Blocks until all enqueued records are written (tests, loop
    /// barriers). Never call from `writer`.
    public func flush() {
        work.lock()
        while !pendingDroppable.isEmpty || !pendingControl.isEmpty || pendingProgress != nil || inFlight > 0 {
            work.wait()
        }
        work.unlock()
    }

    public func setCaps(_ caps: TerminalCaps) {
        work.lock()
        self.caps = caps
        work.unlock()
    }

    public var currentGeneration: UInt64 {
        work.lock()
        defer { work.unlock() }
        return generation
    }

    /// Bumps the generation: pending/stale callbacks for older
    /// generations drop (cancellation + supersede suppression).
    public func invalidate() {
        work.lock()
        generation += 1
        work.unlock()
    }

    /// Enqueues rendered lines (stale generation ⇒ dropped whole).
    /// Synchronous enqueue only; the writer thread drains.
    @discardableResult
    public func emit(_ lines: [RenderedLine], generation: UInt64, lane: Lane = .droppable) -> EmitResult {
        work.lock()
        defer { work.unlock() }
        if quiesced {
            return EmitResult(written: 0, truncated: 0, droppedStale: true, controlOverflow: false)
        }
        guard generation == self.generation else {
            return EmitResult(written: 0, truncated: 0, droppedStale: true, controlOverflow: false)
        }
        switch lane {
        case .droppable:
            pendingDroppable.append(contentsOf: lines)
            let truncated = Self.applyDroppableQuota(&pendingDroppable)
            work.broadcast()
            return EmitResult(written: lines.count, truncated: truncated, droppedStale: false, controlOverflow: false)
        case .control:
            // Control lane: cap 64 is a drain-priority threshold, NEVER
            // a drop (over-cap still writes everything, ordered, and
            // reports overflow). Approvals/errors/terminal outcomes are
            // low-volume by construction; the flag sizes the normal
            // queue, not the write.
            pendingControl.append(contentsOf: lines)
            let overflow = pendingControl.count > Self.maxControlItems
            work.broadcast()
            return EmitResult(written: lines.count, truncated: 0, droppedStale: false, controlOverflow: overflow)
        }
    }

    /// Enqueues pre-rendered text (status/progress scaffolding, never
    /// model content): sanitized here, so every emit path is safe.
    @discardableResult
    public func emitText(_ text: String, generation: UInt64, lane: Lane = .droppable, role: StyleRole = .normal) -> EmitResult {
        emit([RenderedLine(spans: [TextSpan(text: displaySafe(text), role: role)])], generation: generation, lane: lane)
    }

    /// Bounded transient progress (`streaming… N bytes`). Requires
    /// cursor addressing AND color (the clear-to-EOL uses ANSI, so
    /// NO_COLOR/plain suppress it — zero ANSI bytes). Adjacent updates
    /// coalesce: at most one progress write per 100 ms; clears (nil)
    /// always enqueue. Content bytes are counts, never model text.
    public func setProgress(_ text: String?, generation: UInt64) {
        work.lock()
        defer { work.unlock() }
        if quiesced { return }
        guard generation == self.generation, caps.cursorAddressing, caps.color else { return }
        if text != nil {
            let current = now()
            if let last = lastProgressEnqueue, current.timeIntervalSince(last) < Self.minProgressInterval { return }
            lastProgressEnqueue = current
            pendingProgress = (text, generation)
            // A clear for never-shown progress is a noop (no stray
            // control bytes); clears only enqueue after a show.
            work.broadcast()
        } else if progressShown || pendingProgress?.text != nil {
            pendingProgress = (nil, generation)
            work.broadcast()
        }
    }

    // MARK: - Writer thread (sole writer)

    private func writerLoop() {
        while true {
            work.lock()
            while pendingDroppable.isEmpty && pendingControl.isEmpty && pendingProgress == nil && !stopped {
                work.wait()
            }
            if stopped, pendingDroppable.isEmpty, pendingControl.isEmpty, pendingProgress == nil {
                finished = true
                work.broadcast()
                work.unlock()
                return
            }
            let controls = pendingControl
            let droppable = pendingDroppable
            var progress = pendingProgress
            let caps = caps
            let generation = generation
            // A progress write for an invalidated generation is stale:
            // drop, never emit (cancellation/supersede suppression).
            if let p = progress, p.generation != generation { progress = nil }
            // A visible progress line must be cleared before content:
            // otherwise the content batch appends below it and commits
            // the stale progress text to scrollback. A batch that only
            // carries a progress clear (or a fresh progress value) needs
            // no extra clear — the clear/newline write below handles it.
            let clearBeforeContent = progressShown && (!controls.isEmpty || !droppable.isEmpty)
            pendingControl.removeAll()
            pendingDroppable.removeAll()
            pendingProgress = nil
            inFlight += 1
            work.broadcast() // wake flush()
            // M4-MAC-03 finding B: a captured batch must NEVER be
            // written once quiesced. Writing during the BAIL unwind
            // deadlocks — the writer can block on replxx's notification
            // pipe, which only the input thread drains, while the input
            // thread is inside quiesce() waiting for this batch — a
            // circular wait (the intermittent PTY-01 hang). Drop
            // instead of writing; quiesce's inFlight wait then always
            // terminates.
            // M4-MAC-04B: the check runs at the WRITE GATE too — a batch
            // captured before quiesce()/silence() is re-evaluated after
            // acquiring writeLock, so a batch can never slip in between
            // the capture and the write.
            writeLock.lock()
            if quiesced || silenced {
                // Drop the captured batch: never write it.
                inFlight -= 1
                work.broadcast()
                work.unlock()
                writeLock.unlock()
                continue
            }
            work.unlock()
            // Encode + write off-lock; this thread is the only writer.
            // M4-MAC-04B: the per-line gate. On the barrier-timeout
            // path the restore proceeds while this thread may still be
            // inside ONE writer() call (a blocked write cannot be
            // cancelled). Once silenced, no further line is emitted:
            // the late emission is bounded to the single in-flight
            // line, and every subsequent line is dropped here.
            if clearBeforeContent, !silencedNow {
                writer("\r\u{1B}[K")
            }
            for line in controls {
                if silencedNow { break }
                writer(ANSISpans.encode(line, caps: caps) + "\n")
            }
            for line in droppable {
                if silencedNow { break }
                writer(ANSISpans.encode(line, caps: caps) + "\n")
            }
            if let progress, !silencedNow {
                writer(progress.text.map { "\r" + displaySafe($0) + "\u{1B}[K" } ?? "\r\u{1B}[K")
            }
            writeLock.unlock()
            work.lock()
            // Track shown state for the clear-noop rule (written path
            // only — a gate-dropped batch wrote nothing and must not
            // change the visible progress state).
            if let progress {
                progressShown = progress.text != nil
            } else if clearBeforeContent {
                progressShown = false
            }
            inFlight -= 1
            work.broadcast()
            work.unlock()
        }
    }

    private static func applyDroppableQuota(_ lines: inout [RenderedLine]) -> Int {
        var truncated = 0
        if lines.count > maxDroppableItems {
            truncated = lines.count - maxDroppableItems
            lines = Array(lines.suffix(maxDroppableItems))
        }
        var bytes = lines.reduce(0) { $0 + $1.plainText.utf8.count }
        while bytes > maxDroppableBytes, !lines.isEmpty {
            bytes -= lines.removeFirst().plainText.utf8.count
            truncated += 1
        }
        if truncated > 0 {
            lines.insert(RenderedLine(spans: [TextSpan(text: "…[output truncated]", role: .warning)]), at: 0)
        }
        return truncated
    }
}
