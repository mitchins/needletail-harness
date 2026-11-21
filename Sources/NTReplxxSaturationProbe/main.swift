import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import NeedletailLineEditor

/// NTReplxxSaturationProbe — a DEBUG-ONLY fixture executable (the
/// NeedletailTypingProbe pattern, M4-MAC-04B). Not part of the released
/// product. Modes:
///   sat <count>  — notification saturation: an ACTIVE raw-path reader
///     (readLine on fd 0) while the main thread torrents <count>
///     messages through replxx_write, then waits for the parent's
///     "done\r" to complete the reader, restores the captured termios
///     and exits 0 with `SATURATION-DONE drops=<n>` on stderr.
///   stalek       — the stale-token regression: queue a synthetic
///     keypress and a message in quick succession so the keypress can
///     be serviced by the coalesced message-drain (leaving its 'k'
///     token stale in the pipe), then complete via the parent's
///     "done\r". Exit 0 with `STALEK-DONE key=<n> line=<len>`.
/// Reader completion and terminal restoration are asserted by the
/// driving test (the completion flag here, the exact-restore oracle in
/// the parent via the shim).
setenv("TERM", "xterm-256color", 1)
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sat"
let count = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 200_000) : 200_000
guard let session = LineEditorSession() else {
    FileHandle.standardError.write(Data("PROBE-FAIL no-session\n".utf8))
    exit(3)
}
final class ReaderState: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var lineLen = 0
}
let state = ReaderState()
let reader = Thread {
    let line = session.readLine(prompt: "sat> ") ?? ""
    state.lineLen = line.utf8.count
    state.done.signal()
}
reader.name = "sat-reader"
reader.start()
Thread.sleep(forTimeInterval: 0.5) // the reader engages raw mode

switch mode {
case "sat":
    for i in 0 ..< count {
        session.emit("m\(i)\n")
    }
    Thread.sleep(forTimeInterval: 1.0) // the message drain settles
default:
    // The stale-token sequence: the keypress and the message race for
    // the same wake cycle. Whichever wins, the assertions hold.
    session.emit("BEFORE\n")
    Thread.sleep(forTimeInterval: 0.3)
    session.emulateKeyPress(UInt32(UInt8(UInt8(ascii: "a"))))
    session.emit("AFTER-KEY\n")
    Thread.sleep(forTimeInterval: 0.3)
    session.emulateKeyPress(UInt32(UInt8(ascii: "b")))
    session.emit("MSG-2\n")
}

// The parent completes the reader with "done\r" (a real keystroke —
// the reader's designed function after any stale token).
let waited = (state.done.wait(timeout: .now() + 20) == .success)
guard waited else {
    FileHandle.standardError.write(Data("PROBE-FAIL reader-never-completed\n".utf8))
    exit(4)
}
session.restoreSaneTermios()
if mode == "sat" {
    FileHandle.standardError.write(Data("SATURATION-DONE drops=\(LineEditorSession.notifyDrops)\n".utf8))
} else {
    FileHandle.standardError.write(Data("STALEK-DONE key=a+line=\(state.lineLen)\n".utf8))
}
exit(0)
