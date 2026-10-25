#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// FINAL-03: SIG_IGN for SIGPIPE, installed once per test-runner process.
///
/// `signal()` disposition is process-wide, so the previous write-scoped
/// toggle dance (SIG_IGN around a write, SIG_DFL after) raced across
/// concurrently running suites in the same runner: one suite's restore
/// re-exposed every other suite's write window, and a single unguarded
/// write to a dead socket/pipe/PTY killed the whole runner (observed on
/// CI as `exited with unexpected signal code 13`, which also collapses
/// instrumented coverage for every suite that runner carried). With
/// SIG_IGN installed, writes to dead descriptors fail with EPIPE —
/// which every guarded site already treats as "the peer went away".
public enum SIGPIPEGuard {
    private static let installed: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    public static func install() {
        _ = installed
    }
}
