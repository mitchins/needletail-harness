import Testing
import Foundation
@testable import NeedletailTerminal

/// C5.2/C5.4/C5.5: single-writer ordering, stale suppression, quotas,
/// control-lane priority, progress coalescing + plain suppression.
/// The writer thread drains asynchronously: every assertion flushes.
struct TerminalOutputOwnerTests {
    private func owner(
        caps: TerminalCaps = TerminalCaps(),
        now: @escaping @Sendable () -> Date = Date.init,
        written: LockedBox
    ) -> TerminalOutputOwner {
        TerminalOutputOwner(caps: caps, writer: { written.append($0) }, now: now)
    }

    @Test("ordered writes under one lock, stale generations drop")
    func orderingAndStale() {
        let box = LockedBox()
        let o = owner(written: box)
        defer { o.close() }
        let g = o.currentGeneration
        let r1 = o.emit([RenderedLine(spans: [TextSpan(text: "a", role: .normal)])], generation: g)
        #expect(r1 == TerminalOutputOwner.EmitResult(written: 1, truncated: 0, droppedStale: false, controlOverflow: false))
        o.invalidate()
        let r2 = o.emit([RenderedLine(spans: [TextSpan(text: "b", role: .normal)])], generation: g)
        #expect(r2.droppedStale == true)
        o.flush()
        #expect(box.joined() == "a\n")
    }

    @Test("droppable quota keeps tail with marker")
    func droppableQuota() {
        let box = LockedBox()
        let o = owner(written: box)
        defer { o.close() }
        let lines = (0 ..< 600).map { i in RenderedLine(spans: [TextSpan(text: "l\(i)", role: .normal)]) }
        let r = o.emit(lines, generation: o.currentGeneration)
        #expect(r.truncated == 600 - TerminalOutputOwner.maxDroppableItems)
        o.flush()
        let out = box.joined()
        #expect(out.contains("…[output truncated]"))
        #expect(out.range(of: "…[output truncated]")!.lowerBound < out.range(of: "l88")!.lowerBound)
        #expect(out.contains("l599"))
        #expect(!out.contains("l0\n") && !out.contains("\nl0"))
    }

    @Test("control lane never truncates and drains first")
    func controlNeverTruncates() {
        let box = LockedBox()
        let o = owner(written: box)
        defer { o.close() }
        let g = o.currentGeneration
        let controls = (0 ..< 100).map { i in RenderedLine(spans: [TextSpan(text: "c\(i)", role: .errorNotice)]) }
        let r = o.emit(controls, generation: g, lane: .control)
        #expect(r.truncated == 0)
        #expect(r.written == 100)
        #expect(r.controlOverflow == true)
        o.emit([RenderedLine(spans: [TextSpan(text: "d0", role: .normal)])], generation: g)
        o.flush()
        // Color caps wrap each record in SGR: count records, not raw text.
        let records = box.joined().split(separator: "\n").filter { !$0.isEmpty }
        #expect(records.count == 101)
        #expect(records.first?.contains("c0") == true)
        #expect(records[99].contains("c99"))
        #expect(records.last?.contains("d0") == true)
    }

    @Test("progress coalesces to 10 Hz, clears pass, plain suppresses")
    func progressRules() {
        let box = LockedBox()
        let clock = ManualClock(start: Date(timeIntervalSince1970: 1_000_000))
        let o = owner(now: { clock.now() }, written: box)
        defer { o.close() }
        let g = o.currentGeneration
        o.setProgress("streaming… 10 bytes", generation: g)
        o.flush()
        clock.advance(by: 0.01)
        o.setProgress("streaming… 20 bytes", generation: g) // throttled out
        o.flush()
        clock.advance(by: 0.2)
        o.setProgress("streaming… 30 bytes", generation: g)
        o.flush()
        o.setProgress("stale", generation: g + 99) // stale: dropped
        o.setProgress(nil, generation: g) // clear passes (progress shown)
        o.flush()
        let writes = box.values()
        #expect(writes.count == 3)
        #expect(writes[0].contains("10 bytes"))
        #expect(!writes.joined().contains("20 bytes"))
        #expect(writes[1].contains("30 bytes"))
        #expect(writes[2] == "\r\u{1B}[K")
        // Adjacent updates without a drain collapse to the latest.
        let box2 = LockedBox()
        let o2 = owner(now: { clock.now() }, written: box2)
        defer { o2.close() }
        clock.advance(by: 1.0)
        o2.setProgress("streaming… 40 bytes", generation: o2.currentGeneration)
        clock.advance(by: 1.0)
        o2.setProgress("streaming… 50 bytes", generation: o2.currentGeneration)
        o2.flush()
        let writes2 = box2.values()
        // The writer thread may drain the 40-byte update before the
        // 50-byte call lands: assert the guaranteed property (the
        // latest update wins, nothing follows it), never one drain.
        #expect((1...2).contains(writes2.count))
        #expect(writes2.last?.contains("50 bytes") == true, "latest update wins")

        let plainBox = LockedBox()
        let plain = owner(caps: .plain, written: plainBox)
        defer { plain.close() }
        plain.setProgress("streaming… 1 byte", generation: plain.currentGeneration)
        plain.flush()
        #expect(plainBox.values().isEmpty)

        // NO_COLOR (no color, addressing on): progress suppressed too —
        // the clear-to-EOL is ANSI, and NO_COLOR means zero ANSI bytes.
        let noColorBox = LockedBox()
        let noColorCaps = TerminalCaps(color: false, cursorAddressing: true, width: 80)
        let noColor = owner(caps: noColorCaps, written: noColorBox)
        defer { noColor.close() }
        noColor.setProgress("streaming… 1 byte", generation: noColor.currentGeneration)
        noColor.flush()
        #expect(noColorBox.values().isEmpty)
    }

    @Test("content clears a visible progress line before writing")
    func contentClearsVisibleProgress() {
        let box = LockedBox()
        let o = owner(written: box)
        defer { o.close() }
        let g = o.currentGeneration
        o.setProgress("streaming… 10 bytes", generation: g)
        o.flush()
        o.emit([RenderedLine(spans: [TextSpan(text: "hello", role: .normal)])], generation: g)
        o.flush()
        let writes = box.values()
        #expect(writes.count == 3)
        #expect(writes[0].contains("10 bytes"))
        // The progress line is cleared before the content batch lands,
        // so stale progress text is never committed to scrollback.
        #expect(writes[1] == "\r\u{1B}[K")
        #expect(writes[2].contains("hello"))
    }

    @Test("a dropped stale pending write keeps the visible line clearable")
    func staleDropKeepsLineClearable() {
        let box = LockedBox()
        let clock = ManualClock(start: Date(timeIntervalSince1970: 2_000_000))
        let o = owner(now: { clock.now() }, written: box)
        defer { o.close() }
        let g = o.currentGeneration
        o.setProgress("streaming… 10 bytes", generation: g)
        o.flush() // line visible on screen
        clock.advance(by: 0.2)
        o.setProgress("streaming… 20 bytes", generation: g) // pending
        o.invalidate() // the pending write is now stale…
        o.flush() // …so the drain drops it: NOTHING written, line remains
        #expect(box.values().count == 1, "a stale pending write must not emit")
        // The shown-state tracker must still consider the line visible:
        // the next clear passes and content is preceded by the clear.
        o.setProgress(nil, generation: o.currentGeneration)
        o.flush()
        o.emit([RenderedLine(spans: [TextSpan(text: "hello", role: .normal)])], generation: o.currentGeneration)
        o.flush()
        let writes = box.values()
        #expect(writes.count == 3, "expected clear + content after the visible line, got \(writes.count)")
        #expect(writes[1] == "\r\u{1B}[K", "visible progress line must be cleared before content, got \(writes[1])")
        #expect(writes[2].contains("hello"))
    }

    @Test("progress path never carries live control bytes (C5.2 partial oracle)")
    func progressNoLiveControls() {
        let box = LockedBox()
        let o = owner(written: box)
        defer { o.close() }
        let g = o.currentGeneration
        // Hostile progress content is sanitized to visible escapes; the
        // ONLY raw ESC on the wire is the clear-to-EOL framing.
        o.setProgress("streaming… \u{1B}[31m9999999 bytes", generation: g)
        o.flush()
        let writes = box.values()
        #expect(writes.count == 1)
        #expect(writes[0].contains("9999999")) // the count itself shows
        #expect(writes[0].contains("\\u{1b}")) // the attack shows escaped
        #expect(writes[0].filter { $0 == "\u{1B}" }.count == 1) // framing only
    }

    @Test("emitText sanitizes; plain route has zero ANSI")
    func emitTextSafe() {
        let box = LockedBox()
        let o = owner(caps: .plain, written: box)
        defer { o.close() }
        o.emitText("a\u{1B}[31mb", generation: o.currentGeneration)
        o.flush()
        let out = box.joined()
        #expect(!hasScalar(out, 0x1B))
        #expect(out.contains("\\u{1b}"))
    }
}

/// Manual clock for throttle tests (Sendable test double).
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) { lock.withLock { current = current.addingTimeInterval(interval) } }
}

/// Lock-boxed writer capture (Sendable test double).
final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ s: String) { lock.withLock { items.append(s) } }
    func values() -> [String] { lock.withLock { items } }
    func joined() -> String { lock.withLock { items.joined() } }
}
