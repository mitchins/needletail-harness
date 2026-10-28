import Testing
import Foundation
@testable import NeedletailCore
@testable import NeedletailRuntime

@Suite(.serialized)
struct C1ProcRunnerTests {

    // Helper to count open FDs (for leak detection)
    private static func openFDCount() -> Int {
        var count = 0
        for fd in 0..<1024 {
            if fcntl(Int32(fd), F_GETFD) != -1 { count += 1 }
        }
        return count
    }

    @Test("PROC-01 simultaneous stdout/stderr flood — no deadlock, bounded, both drained")
    func proc01DualFlood() throws {
        // Child floods both pipes with 4 MiB each; the runner must drain both
        // concurrently without deadlock and with bounded memory.
        let script = """
        import sys
        for i in range(4000):
            sys.stdout.write("x" * 1024 + "\\n")
            sys.stderr.write("y" * 1024 + "\\n")
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proc01-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ExecArguments(executable: "/usr/bin/python3", argv: ["/usr/bin/python3", tmp.path], cwd: nil, timeoutSecs: 10, env: [:])
        let runner = ExecRunner(resolver: try WorkspaceResolver(workspace: nil, readRoots: []))
        let result = try runner.run(args: args, timeout: 10)
        #expect(result.exitStatus == 0, "flood script exits 0")
        #expect(!result.timedOut, "not timed out")
        #expect(result.stdout.count > 1024 * 1024, "stdout drained")
        #expect(result.stderr.count > 1024 * 1024, "stderr drained")
        #expect(!result.truncated, "not truncated within 32 MiB caps")
    }

    @Test("PROC-06 existing absolute-path interpreter — no activation, uses existing binary")
    func proc06AbsoluteInterpreter() throws {
        let args = ExecArguments(executable: "/usr/bin/python3", argv: ["/usr/bin/python3", "-c", "print('hello-m2c')"], cwd: nil, timeoutSecs: 5, env: [:])
        let runner = ExecRunner(resolver: try WorkspaceResolver(workspace: nil, readRoots: []))
        let result = try runner.run(args: args, timeout: 5)
        #expect(result.exitStatus == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("hello-m2c"))
        #expect(result.timedOut == false)
    }

    @Test("PROC-01 via NativeToolExecutor runBounded dual flood (rg-style caps)")
    func proc01ViaRunBounded() throws {
        // Use the existing rg-style runner to prove the dual-drain primitive
        // still works after the C1 group/escalation changes. Each stream
        // carries ~80 KB — past the 64 KiB pipe buffer — so a runner that
        // drains only one pipe at a time would deadlock here.
        let result = try NativeToolExecutor.runBounded(
            executablePath: "/bin/sh", args: ["-c", "for i in $(seq 1 40000); do echo x; echo y >&2; done"],
            stdoutCap: 4 * 1024 * 1024, stderrCap: 4 * 1024 * 1024, timeout: 15,
            useSession: true)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.stdout.count > 65536, "stdout past the pipe buffer, fully drained")
        #expect(result.stderr.count > 65536, "stderr past the pipe buffer, fully drained")
    }
}
