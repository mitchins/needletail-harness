import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    let pid = proc.processIdentifier
    print("PROBE-B: HUNG past 30s (matches the PTY-08 CI signature)")
    // Zombie analysis: isRunning can stay true for an exited-but-
    // unreaped child. Read the REAL exit status via waitpid(WNOHANG)
    // — Foundation's reaper has not taken it (state Z persisted).
    var status: Int32 = 0
    let wr = waitpid(pid, &status, WNOHANG)
    if wr == pid {
        if (status & 0x7F) == 0 {
            print("PROBE-B: zombie already EXITED with code \((status >> 8) & 0xFF)")
        } else {
            print("PROBE-B: zombie died by signal \(status & 0x7F)")
        }
    } else if wr == -1, errno == ECHILD {
        print("PROBE-B: waitpid ECHILD — child reaped elsewhere; exit status unknown")
    } else {
        print("PROBE-B: waitpid WNOHANG -> child still alive (wr=\(wr))")
    }
    // tmux -vv logs are written to the CURRENT DIRECTORY of the client
    // (not TMUX_TMPDIR) — copy them next to the artifact evidence.
    let cwd = FileManager.default.currentDirectoryPath
    if let logs = try? FileManager.default.contentsOfDirectory(atPath: cwd) {
        for log in logs where log.hasPrefix("tmux-") {
            let dst = tmpDir + "/" + log
            try? FileManager.default.copyItem(atPath: cwd + "/" + log, toPath: dst)
            print("PROBE-B: copied \(log) into evidence dir")
        }
    }
    // Bounded wchan/fd diagnostic (pre-authorized): read-only /proc
    // inspection of our own hung child + any child it forked (the
    // would-be server), BEFORE termination.
    for target in [pid] + childPids(of: pid) {
        print("---- pid \(target) ----")
        dumpOne(path: "/proc/\(target)/cmdline", label: "cmdline", asArgs: true)
        dumpOne(path: "/proc/\(target)/wchan", label: "wchan")
        dumpOne(path: "/proc/\(target)/stat", label: "stat(state+ppid fields)")
        dumpOne(path: "/proc/\(target)/syscall", label: "syscall")
        if let fds = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(target)/fd") {
            for fd in fds.sorted(by: { Int($0)! < Int($1)! }) {
                let target_path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(target)/fd/\(fd)")) ?? "?"
                print("  fd \(fd) -> \(target_path)")
            }
        } else {
            print("  fds: unreadable")
        }
    }
    print("PROBE-B: child pid \(pid) — TERM then SIGKILL (own child)")
    proc.interrupt(); proc.terminate()
    Thread.sleep(forTimeInterval: 1)
    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    exit(1)
}

/// One-level child scan of /proc (read-only): pids whose PPID is `pid`.
func childPids(of pid: pid_t) -> [pid_t] {
    var out: [pid_t] = []
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") {
        for e in entries where e.allSatisfy(\.isNumber) {
            if let stat = try? String(contentsOfFile: "/proc/\(e)/stat", encoding: .utf8) {
                // comm may contain spaces/parens: parse after the LAST ')'
                if let close = stat.lastIndex(of: ")") {
                    let fields = stat[stat.index(close, offsetBy: 2)...].split(separator: " ")
                    if fields.count >= 2, let ppid = Int(fields[1]), ppid == pid {
                        out.append(pid_t(e) ?? 0)
                    }
                }
            }
        }
    }
    return out
}

func dumpOne(path: String, label: String, asArgs: Bool = false) {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
        if asArgs {
            let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            print("  \(label): \(parts.joined(separator: " "))")
        } else {
            print("  \(label): \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("  \(label): <unreadable/empty>")
    }
}
proc.waitUntilExit()
print("PROBE-B: returned status \(proc.terminationStatus)")
