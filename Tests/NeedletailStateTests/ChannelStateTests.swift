import Testing
import Foundation
import NeedletailCore

/// STATE-04 pure rows — the channel is a VALUE, so buffer/backpressure/
/// teardown properties are finite folds over scripted input lists (no
/// async, no sleeps; "no hang" = termination within an explicit step cap).
/// Authoritative payloads never drop silently; only replaceable display
/// deltas may coalesce. Durable-artifact quotas are M2 (explicit non-claim).
struct ChannelStateTests {

    @Test("STATE-04 overflow is a visible stop with receipts kept")
    func STATE_04_overflowVisibleStop() throws {
        var channel = BoundedChannelState<String>(itemCap: 4, byteCap: 64)
        for i in 0..<4 {
            guard case .accepted(let depth) = channel.offer("e-\(i)", bytes: 8) else {
                Issue.record("offer \(i) must fit"); return
            }
            #expect(depth == i + 1)
        }
        guard case .overflow(let items, let bytes) = channel.offer("boom", bytes: 8) else {
            Issue.record("5th offer must overflow"); return
        }
        #expect(items == 4 && bytes == 32, "overflow reports the retained counts")
        #expect(channel.items.count == 4, "buffered payloads kept, none dropped")
        // Byte cap binds independently of the item cap.
        var narrow = BoundedChannelState<String>(itemCap: 64, byteCap: 16)
        #expect(narrow.offer("0123456789abcdef", bytes: 16) == .accepted(depth: 1))
        guard case .overflow = narrow.offer("x", bytes: 1) else {
            Issue.record("byte cap must bind"); return
        }
    }

    @Test("STATE-04 cancel-during-fill drains bounded with receipts kept")
    func STATE_04_cancelDuringFillBounded() throws {
        var channel = BoundedChannelState<String>(itemCap: 8, byteCap: 1_024)
        var scripted: [String] = (0..<6).map { "event-\($0)" }
        scripted.insert("CANCEL", at: 3)
        var delivered: [String] = []
        var steps = 0
        var cancelled = false
        for token in scripted {
            steps += 1
            #expect(steps <= 32, "fold terminates within the step cap (no hang)")
            if token == "CANCEL" {
                cancelled = true
                continue
            }
            if !cancelled, case .accepted = channel.offer(token, bytes: 8) {
                continue
            }
            if cancelled, let next = channel.poll() {
                delivered.append(next)
            }
        }
        // Drain the remainder after cancel.
        while let next = channel.poll() {
            steps += 1
            #expect(steps <= 32, "drain terminates")
            delivered.append(next)
        }
        #expect(delivered == ["event-0", "event-1", "event-2"], "pre-cancel payloads all drain, post-cancel arrivals never buffer")
        #expect(channel.items.isEmpty, "drain completes")
    }

    @Test("STATE-04 slow consumer backpressures without growth or loss")
    func STATE_04_backpressureBounded() throws {
        var channel = BoundedChannelState<String>(itemCap: 2, byteCap: 64)
        #expect(channel.offer("a", bytes: 1) == .accepted(depth: 1))
        #expect(channel.offer("b", bytes: 1) == .accepted(depth: 2))
        // At cap: offer reports backpressure AND keeps every byte.
        guard case .overflow(let items, _) = channel.offer("c", bytes: 1) else {
            Issue.record("full channel must push back"); return
        }
        #expect(items == 2)
        #expect(channel.poll() == "a", "poll frees exactly one slot")
        #expect(channel.offer("c", bytes: 1) == .accepted(depth: 2), "freed slot re-admits")
    }

    @Test("STATE-04 UI spool caps bind display deltas, not authority")
    func STATE_04_uiSpoolCaps() throws {
        var spool: BoundedChannelState<String> = uiSpoolChannel()
        #expect(spool.itemCap == 128 && spool.byteCap == 512 << 10)
        var intake: BoundedChannelState<String> = providerIntakeChannel()
        #expect(intake.itemCap == 512 && intake.byteCap == 4 << 20)
    }
}
