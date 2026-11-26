import Foundation
import NeedletailPresentation
import NeedletailCore

/// B5 headless consumer: the architectural proof that a non-terminal
/// frontend can drive Needletail. It holds UI state, records requested
/// effects WITHOUT executing them (no actor, no runtime, no terminal),
/// and applies authoritative Core responses. Imports are intentionally
/// Foundation + Presentation + Core only (gated by
/// HeadlessConsumerTests.importGate).
public struct HeadlessConsumer: Sendable {
    public var state = UIState()
    /// Requested effects, recorded in order, never executed here.
    public private(set) var requested: [UIEffect] = []
    /// Applied authoritative inputs, in order (replay log).
    public private(set) var applied: [String] = []

    public init() {}

    /// Operator-side action: reduce locally, record effects.
    public mutating func send(_ action: UIAction, label: String) {
        let (next, fx) = reduce(state, action)
        state = next
        requested.append(contentsOf: fx)
        applied.append("send:\(label)")
    }

    /// Core-side response: apply an authoritative projection or sync.
    /// Returns any effects the reducer emits (authoritative inputs must
    /// request nothing — the caller asserts emptiness; no assert() here
    /// so the check holds under -O too).
    public mutating func receive(_ action: UIAction, label: String) -> [UIEffect] {
        let (next, fx) = reduce(state, action)
        state = next
        applied.append("receive:\(label)")
        return fx
    }

    /// Replay check: two fresh consumers applying the recorded script
    /// reach states and effect lists identical to each other and live.
    public func replayed(with script: [(UIAction, String, Bool)]) -> (state: UIState, requested: [UIEffect]) {
        var fresh = HeadlessConsumer()
        for (action, label, isSend) in script {
            if isSend { fresh.send(action, label: label) }
            else { _ = fresh.receive(action, label: label) }
        }
        return (fresh.state, fresh.requested)
    }
}
