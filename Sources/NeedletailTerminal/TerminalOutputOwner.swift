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
            work.unlock()
            // Encode + write off-lock; this thread is the only writer.
            if clearBeforeContent {
                writer("\r\u{1B}[K")
            }
            for line in controls {
                writer(ANSISpans.encode(line, caps: caps) + "\n")
            }
            for line in droppable {
                writer(ANSISpans.encode(line, caps: caps) + "\n")
            }
            if let progress {
                writer(progress.text.map { "\r" + displaySafe($0) + "\u{1B}[K" } ?? "\r\u{1B}[K")
            }
            work.lock()
            // Track shown state for the clear-noop rule.
            progressShown = progress?.text != nil
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
