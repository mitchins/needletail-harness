import Foundation
import NeedletailCore

/// B4 per-tool deadlines (REV25 §4/B4), executor-enforced and injectable
/// for deterministic tests. Production: local I/O 30 s, search/diff
/// subprocess 120 s, exec honors the validated operator-approved bound up
/// to ExecArguments.maxTimeoutSecs (the schema advertises "max 1800": a
/// silent lower cap would kill approved runs and hold the queue).
/// A fired deadline never retries: the in-flight call reports `timeout`
/// (unknown+hold for mutating via the reducer) and the batch halts with
/// later calls unstarted-cancelled.
public struct ToolDeadlines: Sendable, Equatable {
    public var localIO: TimeInterval
    public var search: TimeInterval
    public var exec: TimeInterval

    public init(localIO: TimeInterval = 30, search: TimeInterval = 120, exec: TimeInterval = Double(ExecArguments.maxTimeoutSecs)) {
        self.localIO = localIO
        self.search = search
        self.exec = exec
    }

    public func seconds(for tool: String) -> TimeInterval {
        switch tool {
        case "search": return search
        case "exec": return exec
        default: return localIO
        }
    }
}
