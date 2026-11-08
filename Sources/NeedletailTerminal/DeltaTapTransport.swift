import Foundation
import NeedletailCore

/// M4-C raw display tap (adapter tier).
///
/// A STRUCT decorator wrapping any `ModelTransport` and conforming to
/// `DeltaStreamingTransport` itself, so it is the actor's concrete
/// `Transport`. The actor copies the transport back after setting the
/// sink (`SessionActor` copy/cast/invoke sequence), so the tap MUST be
/// set on the SAME inner value that is invoked (assigning to a copy
/// then invoking the original silently loses the tap) and all tap
/// state lives in the shared reference `TapBox` (per-invoke copies
/// die with the copy).
///
/// The tap is display-only: raw SSE content deltas feed the transient
/// progress line (bounded 1 MiB per request, then the tap goes quiet
/// with the progress line frozen — never state, never parsed). The
/// COMMIT source is authoritative: `TransportResult.response.outcome`
/// at `invoke` return — commit only on `.textDeltaComplete(text:)`
/// (raw, pre-`terminalSafe`); no commit for `.failed`/`.interrupted`.
/// A late return for an invalidated generation is dropped by the
/// output owner (generation-gated finalize).
public final class TapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: Int] = [:]
    private var truncated: Set<String> = []
    /// Adapter callbacks. `let`-bound at init (set-before-use — no
    /// post-start mutation race); nil headless.
    public let onProgress: (@Sendable (RequestID, Int) -> Void)?
    public let onComplete: (@Sendable (RequestID, Revision, String?) -> Void)?
    /// Fired ONCE when a request crosses the display bound (SPEC ¶805
    /// visible marker; the authoritative commit is unaffected).
    public let onTruncated: (@Sendable (RequestID, Int) -> Void)?

    public static let maxTapBytesPerRequest = 1 * 1024 * 1024

    public init(
        onProgress: (@Sendable (RequestID, Int) -> Void)? = nil,
        onComplete: (@Sendable (RequestID, Revision, String?) -> Void)? = nil,
        onTruncated: (@Sendable (RequestID, Int) -> Void)? = nil
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onTruncated = onTruncated
    }

    fileprivate func tap(_ requestID: RequestID, text: String) {
        let key = requestID.raw
        let (total, fireTruncated): (Int, Bool) = lock.withLock {
            let next = (bytes[key] ?? 0) + text.utf8.count
            bytes[key] = next
            if next > Self.maxTapBytesPerRequest, !truncated.contains(key) {
                truncated.insert(key)
                return (next, true)
            }
            return (next, false)
        }
        if fireTruncated {
            onTruncated?(requestID, total)
        } else if total <= Self.maxTapBytesPerRequest {
            // Past the bound the tap goes quiet (progress frozen at the
            // cap; the authoritative commit at invoke return is
            // unaffected).
            onProgress?(requestID, total)
        }
    }

    fileprivate func complete(requestID: RequestID, generation: Revision, text: String?) {
        lock.withLock {
            bytes[requestID.raw] = nil
            truncated.remove(requestID.raw)
        }
        onComplete?(requestID, generation, text)
    }

    /// Safety-net drop (loop calls at `run_finished`; per-request state
    /// already finalizes at invoke return).
    public func dropAll() {
        lock.withLock {
            bytes.removeAll()
            truncated.removeAll()
        }
    }
}

public struct DeltaTapTransport<Inner: ModelTransport>: DeltaStreamingTransport {
    public var deltaSink: (@Sendable (String) -> Void)?
    private var inner: Inner
    public let box: TapBox

    public init(wrapping inner: Inner, box: TapBox = TapBox()) {
        self.inner = inner
        self.box = box
    }

    public func invoke(
        _ invocation: ProviderInvocation,
        intake: BoundedChannelState<ProviderResponse>
    ) async throws -> TransportResult {
        // `deltaSink` here is the actor's closure (the actor set it on
        // its copy before invoking). Chain tap-then-forward onto the
        // SAME inner value that is invoked below.
        let actorSink = deltaSink
        let requestID = invocation.requestID
        let generation = invocation.generation
        let box = box
        var innerCopy = inner
        if var streaming = innerCopy as? any DeltaStreamingTransport {
            streaming.deltaSink = { text in
                box.tap(requestID, text: text)
                actorSink?(text)
            }
            if let back = streaming as? Inner {
                innerCopy = back
            }
        }
        do {
            let result = try await innerCopy.invoke(invocation, intake: intake)
            switch result.response.outcome {
            case .textDeltaComplete(let text, _, _):
                box.complete(requestID: requestID, generation: generation, text: text)
            case .failed, .interrupted:
                box.complete(requestID: requestID, generation: generation, text: nil)
            }
            return result
        } catch {
            box.complete(requestID: requestID, generation: generation, text: nil)
            throw error
        }
    }
}
