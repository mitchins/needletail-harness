import Foundation

/// B4 per-tool deadlines (REV25 §4/B4), executor-enforced and injectable
/// for deterministic tests. Production: local I/O 30 s, search/diff
/// subprocess 120 s. A fired deadline never retries: the in-flight call
/// reports `timeout` (unknown+hold for mutating via the reducer) and the
/// batch halts with later calls unstarted-cancelled.
public struct ToolDeadlines: Sendable, Equatable {
    public var localIO: TimeInterval
    public var search: TimeInterval

    public init(localIO: TimeInterval = 30, search: TimeInterval = 120) {
        self.localIO = localIO
        self.search = search
    }

    public func seconds(for tool: String) -> TimeInterval {
        tool == "search" ? search : localIO
    }
}
