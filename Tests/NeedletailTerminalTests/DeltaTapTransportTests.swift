import Testing
import Foundation
import NeedletailCore
@testable import NeedletailTerminal

/// C1/C5: tap chains actor sink on the SAME invoked value; commit comes
/// from the authoritative outcome (never the tap); failures commit nil.
struct DeltaTapTransportTests {
    /// Records the sink the INVOKED value carries: the decorator must
    /// set the chained sink on the same value it invokes (assigning to
    /// a throwaway copy and invoking the original leaves this nil).
    /// The test then drives the recorded sink, proving tap-then-forward
    /// end to end through the invoked value.
    final class SinkBox: @unchecked Sendable {
        var recordedSink: (@Sendable (String) -> Void)?
    }

    struct StreamingInner: DeltaStreamingTransport {
        var outcomeText: String?
        let sinkBox: SinkBox

        // Plain stored sink (per-copy, like the real transport): a
        // decorator that sets a throwaway copy's sink leaves THIS nil.
        var deltaSink: (@Sendable (String) -> Void)?

        func invoke(
            _ invocation: ProviderInvocation,
            intake: BoundedChannelState<ProviderResponse>
        ) async throws -> TransportResult {
            // Record the sink THIS invoked value carries.
            sinkBox.recordedSink = deltaSink
            return TransportResult(response: ProviderResponse(
                requestID: invocation.requestID,
                generation: invocation.generation,
                outcome: outcomeText.map { .textDeltaComplete(text: $0, toolProposals: [], isFinal: true) } ?? .failed("nope")))
        }
    }

    struct NonStreamingInner: ModelTransport {
        func invoke(
            _ invocation: ProviderInvocation,
            intake: BoundedChannelState<ProviderResponse>
        ) async throws -> TransportResult {
            TransportResult(response: ProviderResponse(
                requestID: invocation.requestID, generation: invocation.generation,
                outcome: .textDeltaComplete(text: "full", toolProposals: [], isFinal: true)))
        }
    }

    private func invocation() -> ProviderInvocation {
        ProviderInvocation(
            effectID: EffectID("e"), requestID: RequestID("req-1"), runID: RunID("r"),
            generation: Revision(3), alias: "local", epochID: EpochID("epoch-1"),
            sealed: false, turnsLeft: 5, deadlineMillis: nil, historyDigest: "d")
    }

    @Test("streaming inner: tap fires, actor sink chained, commit authoritative")
    func streamingTap() async throws {
        let progressed = LockedValue([(RequestID, Int)]())
        let completed = LockedValue([(RequestID, Revision, String?)]())
        let box = TapBox(
            onProgress: { req, n in progressed.mutate { $0.append((req, n)) } },
            onComplete: { req, rev, text in completed.mutate { $0.append((req, rev, text)) } })
        let actorGot = LockedValue([String]())
        let sinkBox = SinkBox()
        var transport = DeltaTapTransport(
            wrapping: StreamingInner(outcomeText: "AUTHORITATIVE", sinkBox: sinkBox), box: box)
        // The actor overwrites the sink before invoke (copy semantics).
        transport.deltaSink = { text in actorGot.mutate { $0.append(text) } }
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        let result = try await transport.invoke(invocation(), intake: intake)
        // The chained sink reached the INVOKED value (not a throwaway
        // copy): driving it fires tap-then-actor-forward end to end.
        #expect(sinkBox.recordedSink != nil)
        sinkBox.recordedSink?("chunk")
        #expect(progressed.get().count == 1)
        #expect(actorGot.get() == ["chunk"])
        if case .textDeltaComplete(let text, _, _) = result.response.outcome {
            #expect(text == "AUTHORITATIVE")
        } else { Issue.record("expected text outcome") }
        #expect(completed.get().count == 1)
        #expect(completed.get()[0].0 == RequestID("req-1"))
        #expect(completed.get()[0].1 == Revision(3))
        #expect(completed.get()[0].2 == "AUTHORITATIVE")
    }

    @Test("failed outcome commits nil (no partial commit)")
    func failedCommitsNil() async throws {
        let completed = LockedValue([(RequestID, Revision, String?)]())
        let box = TapBox(
            onComplete: { req, rev, text in completed.mutate { $0.append((req, rev, text)) } })
        var transport = DeltaTapTransport(
            wrapping: StreamingInner(outcomeText: nil, sinkBox: SinkBox()), box: box)
        transport.deltaSink = { _ in }
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        _ = try await transport.invoke(invocation(), intake: intake)
        #expect(completed.get().count == 1)
        #expect(completed.get()[0].2 == nil)
    }

    @Test("non-streaming inner still commits authoritative text")
    func nonStreaming() async throws {
        let completed = LockedValue([(RequestID, Revision, String?)]())
        let box = TapBox(
            onComplete: { req, rev, text in completed.mutate { $0.append((req, rev, text)) } })
        let transport = DeltaTapTransport(wrapping: NonStreamingInner(), box: box)
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        let result = try await transport.invoke(invocation(), intake: intake)
        if case .textDeltaComplete(let text, _, _) = result.response.outcome {
            #expect(text == "full")
        }
        #expect(completed.get().first?.2 == "full")
    }

    @Test("tap quiets past 1 MiB per request; marker fires once; commit unaffected")
    func tapBound() async throws {
        let progressCalls = LockedValue(0)
        let completed = LockedValue([(RequestID, Revision, String?)]())
        let truncated = LockedValue([(RequestID, Int)]())
        let box = TapBox(
            onProgress: { _, _ in progressCalls.mutate { $0 += 1 } },
            onComplete: { req, rev, text in completed.mutate { $0.append((req, rev, text)) } },
            onTruncated: { req, n in truncated.mutate { $0.append((req, n)) } })
        let sinkBox = SinkBox()
        var transport = DeltaTapTransport(
            wrapping: StreamingInner(outcomeText: "done", sinkBox: sinkBox), box: box)
        transport.deltaSink = { _ in }
        let intake = BoundedChannelState<ProviderResponse>(itemCap: 512, byteCap: 4 << 20)
        _ = try await transport.invoke(invocation(), intake: intake)
        // Drive the installed chained sink past the bound directly.
        for _ in 0 ..< 8 {
            sinkBox.recordedSink?(String(repeating: "x", count: 256 * 1024))
        }
        #expect(progressCalls.get() < 8)
        #expect(progressCalls.get() > 0)
        #expect(truncated.get().count == 1)
        #expect(truncated.get().first?.0 == RequestID("req-1"))
        #expect(completed.get().first?.2 == "done")
    }
}

final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { value = initial }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.withLock { value = v } }
    func get() -> Bool { lock.withLock { value } }
}
