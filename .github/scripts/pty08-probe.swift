import Foundation

// PTY-08 fresh tmux-server bootstrap probe — mirrors
// Tests/NeedletailTerminalTests/ChatPTYTests tmux() exactly:
// /usr/bin/env resolution, stdout captured to a FILE (never a pipe),
// caller-side bounded poll, TERM/SIGKILL escalation on a verified-own
// child, FileHandle cleanup. The environment is INHERITED (the test
// helper sets no TERM) — the runner's real TERM reaches the client.
// Usage: probe <socket> <tmpdir>

let socket = CommandLine.arguments[1]
let tmpDir = CommandLine.arguments[2]
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
proc.arguments = ["tmux", "-L", socket, "-vv", "-f", "/dev/null",
                  "new-session", "-d", "-s", "probeB", "-x", "80", "-y", "24"]
let outURL = URL(fileURLWithPath: tmpDir + "/client-stdout.log")
let errURL = URL(fileURLWithPath: tmpDir + "/client-stderr.log")
FileManager.default.createFile(atPath: outURL.path, contents: nil)
FileManager.default.createFile(atPath: errURL.path, contents: nil)
guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
      let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
    print("PROBE-B: cannot open capture files"); exit(2)
}
defer {
    try? outHandle.close()
    try? errHandle.close()
}
proc.standardOutput = outHandle
proc.standardError = errHandle
print("PROBE-B: spawning \(proc.arguments!.joined(separator: " "))")
print("PROBE-B: child sees TERM=\(ProcessInfo.processInfo.environment["TERM"] ?? "<unset>")")
try proc.run()
let deadline = Date().addingTimeInterval(30)
while proc.isRunning, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.1)
}
if proc.isRunning {
    print("PROBE-B: HUNG past 30s (matches the PTY-08 CI signature)")
    print("PROBE-B: child pid \(proc.processIdentifier) — TERM then SIGKILL (own child)")
    proc.interrupt(); proc.terminate()
    Thread.sleep(forTimeInterval: 1)
    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    exit(1)
}
proc.waitUntilExit()
print("PROBE-B: returned status \(proc.terminationStatus)")
