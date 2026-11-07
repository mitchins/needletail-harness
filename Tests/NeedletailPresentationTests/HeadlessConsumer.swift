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
    public mutating func receive(_ action: UIAction, label: String) {
        let (next, fx) = reduce(state, action)
        state = next
        assert(fx.isEmpty, "authoritative inputs must not request work")
        applied.append("receive:\(label)")
    }

    /// Replay check: a fresh consumer applying the recorded script
    /// (sends only; receives re-applied in order) reaches the same state.
    public func replayed(with script: [(UIAction, String, Bool)]) -> UIState {
        var fresh = HeadlessConsumer()
        for (action, label, isSend) in script {
            if isSend { fresh.send(action, label: label) }
            else { fresh.receive(action, label: label) }
        }
        return fresh.state
    }
}
