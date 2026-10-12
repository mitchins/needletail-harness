import Foundation
import Glibc
import NeedletailLineEditor
import PTYShim

/// NeedletailTypingProbe — a DEBUG-ONLY fixture executable for the M0-C PTY
/// feasibility scenario (plans/m0-c-d-plan.md). It is NOT part of the
/// released product: it never ships in the release bundle, takes no real
/// model/session parameters, and exists so the native test driver can
/// drive the vendored line editor through a real PTY with deterministic
/// markers. M4 drives the production composition root instead.
///
/// Marker protocol (all markers go to stdout for the driver):
///   PROBE:ready                    editor live, completion handler armed
///   PROBE:cancel-returned          replxx_input returned nil (Ctrl+C abort)
///   PROBE:stream-<n>               the n-th synthetic chunk was emitted
///   PROBE:stream-done              all synthetic chunks emitted
///   PROBE:completion-invoked       the completion callback fired (with count)
///   PROBE:line:<base64>            a submitted line, exactly as returned
///   PROBE:exit:0                   clean exit (after the "quit" line)
///
/// Driving:
///   The driver types bytes into the PTY. SIGUSR1 to the probe starts the
///   deterministic synthetic-output burst. replxx_input returns NULL on
///   Ctrl+C (an abort, NOT EOF) and on EOF alike — this probe treats that
///   as a cancel and re-enters input; the only clean exit is a submitted
///   "quit" line. readLine blocks a dedicated thread (SPEC §4.1).

private let chunkCount = 24

/// Async-signal-safe stream trigger: a self-pipe. Signal handlers may not
/// touch semaphores or locks; they may write() to a pipe. Immutable after
/// startup (file-scope `let`), so Swift 6 strict concurrency is satisfied
/// without silencing.
private final class StreamTrigger: Sendable {
    let readFD: Int32
    let writeFD: Int32
    init?() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let flags = fcntl(fds[1], F_GETFL, 0)
        _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        readFD = fds[0]
        writeFD = fds[1]
    }
}

private let streamTrigger: StreamTrigger? = StreamTrigger()

private let markerLock = NSLock()

private func emitMarker(_ marker: String) {
    let payload = Data((marker + "\n").utf8)
    markerLock.lock()
    defer { markerLock.unlock() }
    payload.withUnsafeBytes { raw in
        _ = write(STDOUT_FILENO, raw.baseAddress, raw.count)
    }
}

private func installSIGUSR1Handler() {
    // The handler lives in C (PTYShim): a Swift @convention(c) handler
    // cannot capture context, and a signal handler must not touch locks.
    guard let trigger = streamTrigger else { return }
    nt_install_usr1_pipe(trigger.writeFD)
}

private func base64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

@main
struct NeedletailTypingProbe {
    static func main() {
        installSIGUSR1Handler()

        // Synthetic completion candidates: fixed, deterministic, and the
        // callback reports how many it registered so the driver can prove
        // invocation (feasibility.callback-not-invoked fault point).
        let candidates = ["probe-alpha", "probe-beta"]

        guard let session = LineEditorSession() else {
            emitMarker("PROBE:exit:70")
            exit(70)
        }
        session.setCompletionHandler { input in
            emitMarker("PROBE:completion-invoked count=\(candidates.count) input=\(base64(input))")
            return candidates
        }

        // Deterministic synthetic-output burst: started by SIGUSR1 via the
        // self-pipe, emitted on a dedicated thread while the editor is
        // live — the concurrent-output property under test.
        Thread.detachNewThread {
            guard let trigger = streamTrigger else { return }
            var token: UInt8 = 0
            // The SIGUSR1 handler is installed without SA_RESTART, so the
            // blocking read can return EINTR: retry until the byte the
            // handler wrote actually arrives (never assume one syscall).
            while true {
                let count = read(trigger.readFD, &token, 1)
                if count == 1 { break }
                if count < 0 && errno == EINTR { continue }
                return
            }
            for index in 0..<chunkCount {
                session.emit("PROBE:stream-\(index) synthetic output while the composer is live\n")
            }
            emitMarker("PROBE:stream-done")
        }

        emitMarker("PROBE:ready")

        // Blocking input on a dedicated thread (SPEC §4.1).
        let inputQueue = DispatchQueue(label: "needletail.probe.input")
        let inputGroup = DispatchGroup()

        inputGroup.enter()
        inputQueue.async {
            defer { inputGroup.leave() }
            while true {
                guard let line = session.readLine(prompt: "> ") else {
                    // replxx_input returns NULL on Ctrl+C abort and on EOF
                    // alike; this probe treats it as a cancel and re-enters
                    // input. Clean exit happens only via the "quit" line.
                    emitMarker("PROBE:cancel-returned")
                    continue
                }
                emitMarker("PROBE:line:\(base64(line))")
                if line == "quit" {
                    return
                }
            }
        }

        inputGroup.wait()
        emitMarker("PROBE:exit:0")
        exit(0)
    }
}
