import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import NeedletailLineEditor

/// NTReplxxSaturationProbe — a DEBUG-ONLY fixture executable (the
/// NeedletailTypingProbe pattern, M4-MAC-04B). Not part of the released
/// product. Runs the vendored line editor on fd 0 (a real pty provided
/// by the test shim) with an ACTIVE readLine reader while the main
/// thread emits a message torrent through replxx_write — the exact
/// notification-pipe saturation scenario: the reader drains wakeup
/// tokens while the notifier floods them. Exits 0 with
/// `SATURATION-DONE drops=<n>` on stderr, where n is the actual
/// EAGAIN drop count from the registered 0002/0003 telemetry. The
/// torrent's final message reaching the pty output IS the delivery
/// proof (the reader's message drain flushed it through the tty).
// A real TERM: a dumb/unsupported TERM routes replxx to its plain
// line reader (no raw mode, no notification path) — the exact trap
// the PTY driver pins for the product child.
setenv("TERM", "xterm-256color", 1)
let count = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "200000") ?? 200_000
guard let session = LineEditorSession() else {
    FileHandle.standardError.write(Data("SATURATION-FAIL no-session\n".utf8))
    exit(3)
}
let reader = Thread {
    _ = session.readLine(prompt: "sat> ")
}
reader.name = "sat-reader"
reader.start()
Thread.sleep(forTimeInterval: 0.5) // the reader engages raw mode
for i in 0 ..< count {
    session.emit("m\(i)\n")
}
Thread.sleep(forTimeInterval: 1.0) // the message drain settles
// Hold the composer alive while the parent resize-spams the pty: the
// SIGWINCH handler is a free-running notify caller (it holds no
// mutex), so a resize storm is the channel saturator — tokens arrive
// far faster than the reader consumes them and the nonblocking
// notifier must take EAGAIN. The reader stays inside readLine the
// whole time (the writer/input concurrency is live).
sleep(6)
session.restoreSaneTermios()
FileHandle.standardError.write(Data("SATURATION-DONE drops=\(LineEditorSession.notifyDrops)\n".utf8))
exit(0)
