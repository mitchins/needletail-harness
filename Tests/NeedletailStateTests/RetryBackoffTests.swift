import Testing
import Foundation
import NeedletailCore

/// M1-C backoff arming (NET-05 policy half): preSend failures arm a
/// deadline instead of resending inline; ONLY the tick row dispatches;
/// clearing on cancel/epoch/dispatch; counter increments at ARM time.
/// Forbidden: inline resends, tick dispatch without deadline, double-count.
struct RetryBackoffTests {

    private static func requesting(ids: inout DeterministicIDSource) throws -> (SessionState, RunDescriptor) {
        let (admitting, run) = try StateFixtures.admitted("run", ids: &ids)
        let requesting = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1000), &ids).state
        guard case .requesting = requesting.phase else {
            Issue.record("expected requesting"); throw FixtureFailure.admission
        }
        return (requesting, run)
    }

    @Test("NET-05 preSend arms a deadline instead of resending inline")
    func NET_05_preSendArmsDeadline() throws {
        var ids = StateFixtures.ids()
        let (requesting, run) = try Self.requesting(ids: &ids)
        let armed = transition(requesting, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .preSend, error: "refused", atMillis: 2000), &ids)
        #expect(armed.state.retryDeadlineMillis == 2000 + 1_000, "first backoff is 1s")
        #expect(armed.state.preSendRetries == 1, "counter increments at ARM time")
        #expect(!armed.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "no inline resend — the tick dispatches")
        #expect(armed.effects.contains(where: {
            if case .startTimer = $0 { return true }
            return false
        }), "timer effect arms the wait")
    }

    @Test("NET-05 tick dispatches once, then clears")
    func NET_05_tickDispatchesOnce() throws {
        var ids = StateFixtures.ids()
        let (requesting, run) = try Self.requesting(ids: &ids)
        var state = transition(requesting, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .preSend, error: "refused", atMillis: 2000), &ids).state
        // Early tick: explicit no-op, deadline stands.
        let early = transition(state, .tick(nowMillis: 2000 + 999), &ids)
        #expect(early.state.retryDeadlineMillis != nil)
        #expect(early.effects.isEmpty, "stale ticks dispatch nothing")
        // Due tick: exactly one re-request, counter and deadline consumed.
        let due = transition(state, .tick(nowMillis: 2000 + 1_000), &ids)
        #expect(due.state.retryDeadlineMillis == nil, "deadline consumed")
        #expect(due.state.turnsUsed == 2, "dispatch consumes a turn (initial + retry)")
        #expect(due.effects.filter({
            if case .requestProvider = $0 { return true }
            return false
        }).count == 1, "exactly one re-request")
    }

    @Test("NET-05 cancel clears the armed deadline")
    func NET_05_cancelClearsDeadline() throws {
        var ids = StateFixtures.ids()
        let (requesting, run) = try Self.requesting(ids: &ids)
        var state = transition(requesting, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .preSend, error: "refused", atMillis: 2000), &ids).state
        #expect(state.retryDeadlineMillis != nil)
        state = transition(state, .cancelRequested(atMillis: 2001), &ids).state
        #expect(state.retryDeadlineMillis == nil, "cancel disarms")
        // Inside the 5 s cancel grace: the disarmed retry stays silent.
        let quiet = transition(state, .tick(nowMillis: 6000), &ids)
        #expect(quiet.effects.isEmpty, "disarmed ticks stay silent inside grace")
        // Past the grace the M1-B cancel path still interrupts the run —
        // but the retry stays disarmed: no re-request, ever, after cancel.
        let past = transition(state, .tick(nowMillis: 9000), &ids)
        #expect(!past.effects.contains(where: {
            if case .requestProvider = $0 { return true }
            return false
        }), "cancelled retries never re-request, even as grace fires")
    }

    @Test("NET-05 exhaustion still fails closed after arming")
    func NET_05_exhaustionFailsClosed() throws {
        var ids = StateFixtures.ids()
        let (requesting, run) = try Self.requesting(ids: &ids)
        var state = requesting.replacing(preSendRetries: 2)
        let done = transition(state, .transportFailed(
            requestID: run.requestID, generation: run.revision,
            phase: .preSend, error: "refused", atMillis: 2000), &ids)
        guard case .failed(let failure) = done.state.phase else {
            Issue.record("exhausted retries must fail, got \(done.state.phase)"); return
        }
        guard case .providerError = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
        #expect(done.state.retryDeadlineMillis == nil, "no deadline armed past exhaustion")
    }
}
