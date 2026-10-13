import Testing
import Subprocess
import Foundation

/// PROC-01 primitive tier — dual-pipe drain over the production subprocess
/// API. Given a child that floods stdout and stderr simultaneously, when
/// both streams are collected, then both complete without deadlock and the
/// line counts are exact. The full process-group/cancellation matrix with
/// grandchildren and readiness barriers is M2-C work; this proves only the
/// bounded dual-stream drain.

struct SubprocessDualPipeTests {

    private static let floodScript = """
    i=0
    while [ $i -lt 400 ]; do
      echo "out-$i"
      echo "err-$i" 1>&2
      i=$((i+1))
    done
    """

    @Test("PROC-01 child flooding stdout and stderr drains both pipes without deadlock")
    func PROC_01_dualPipeFloodDrainsBothStreams() async throws {
        // 1 MiB limits per stream: the flood is ~14 KiB per stream, well
        // inside the bound; exceeding the limit throws rather than hangs.
        let result = try await run(
            Executable.path("/bin/sh"),
            arguments: ["-c", Self.floodScript],
            output: .string(limit: 1 << 20),
            error: .string(limit: 1 << 20)
        )
        let stdout = result.standardOutput
        let stderr = result.standardError
        #expect(result.terminationStatus.isSuccess, "child should exit 0, got \(result.terminationStatus)")
        let stdoutLines = stdout.split(separator: "\n", omittingEmptySubsequences: false).count
        let stderrLines = stderr.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(stdoutLines == 401, "400 payload lines plus trailing newline, got \(stdoutLines)")
        #expect(stderrLines == 401, "400 payload lines plus trailing newline, got \(stderrLines)")
        #expect(stdout.contains("out-0") && stdout.contains("out-399"), "stdout content incomplete")
        #expect(stderr.contains("err-0") && stderr.contains("err-399"), "stderr content incomplete")
        #expect(!stdout.contains("err-"), "streams must not cross-contaminate")
    }
}
