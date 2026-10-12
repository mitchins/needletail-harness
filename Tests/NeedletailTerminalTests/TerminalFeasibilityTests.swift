import Testing
import Foundation
import PTYShim

/// M0-C feasibility scenario — ONE bounded Linux PTY exercise (TESTING §7).
/// It proves the vendored line editor can: stay live while synthetic
/// streamed output is written; preserve an unsent multiline Unicode draft
/// across streaming and resizes; invoke its completion callback; survive a
/// cancel; and exit cleanly. The terminal is verified to return to usable
/// canonical-echo state by the driver's post-exit reads.
///
/// This is development evidence for the M4-due PTY family, NOT interactive
/// release acceptance: PTY-01…08 and TERM-01…04 remain DEFERRED_BY_PLAN.

private let readyTimeoutMS = 15_000

private final class ProbeProcess {
    var pty = nt_pty_t()
    private var started = false

    func start() {
        let executable = ProcessInfo.processInfo.environment["NEEDLETAIL_TYPING_PROBE"]
            ?? ".build/debug/NeedletailTypingProbe"
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/NeedletailTerminalTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(executable).path
        let executableC = strdup(path)
        defer { free(executableC) }
        var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = UnsafeMutablePointer.allocate(capacity: 2)
        defer { argv?.deallocate() }
        argv!.initialize(to: executableC)
        argv!.advanced(by: 1).initialize(to: nil)
        let result = nt_pty_spawn(&pty, argv)
        guard result == 0 else {
            Issue.record("pty.spawn-failure: could not spawn \(path)")
            return
        }
        started = true
    }

    /// Reads until `marker` appears, the deadline passes, or the child exits.
    @discardableResult
    func expect(_ marker: String, timeoutMS: Int = readyTimeoutMS) -> String {
        var buffer = ""
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = nt_pty_read(&pty, &chunk, 4096, 250)
            if count > 0 {
                buffer += String(decoding: chunk.prefix(Int(count)), as: UTF8.self)
                if buffer.contains(marker) { return buffer }
            } else if count == 0 {
                return buffer // child closed the PTY
            }
        }
        Issue.record("probe.readiness-timeout: marker \(marker) not seen; transcript tail: \(buffer.suffix(400))")
        return buffer
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            nt_pty_write(&pty, buffer.baseAddress!, buffer.count)
        }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func signal(_ sig: Int32) { nt_pty_signal(&pty, sig) }

    func resize(rows: Int, cols: Int) { nt_pty_resize(&pty, Int32(rows), Int32(cols)) }

    func waitExit(timeoutMS: Int = 15_000) -> Int32? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            let status = nt_pty_wait(&pty, 250)
            if status >= 0 { return status }
        }
        return nil
    }

    /// Functional mode-restoration check: after the child has exited and the
    /// slave termios is back to canonical echo, a byte written to the master
    /// is echoed back. In a leaked raw mode it would not be.
    func canonicalEchoRestored() -> Bool {
        send("echo-probe\r")
        var collected = ""
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 256)
            let count = nt_pty_read(&pty, &chunk, 256, 200)
            if count > 0 {
                collected += String(decoding: chunk.prefix(Int(count)), as: UTF8.self)
                if collected.contains("echo-probe") { return true }
            }
        }
        return false
    }

    func stop() {
        if started { nt_pty_close(&pty) }
    }
}

struct TerminalFeasibilityTests {

    /// The single M0-C scenario. Ordering matters: the exact-draft oracle is
    /// asserted BEFORE any completion invocation, because replxx's Tab
    /// inserts the common candidate prefix into the buffer.
    @Test("feasibility M0-C: draft preserved across streaming, resize and cancel; completion fires; clean exit")
    func draftPreservedAcrossConcurrentInteraction() {
        let probe = ProbeProcess()
        defer { probe.stop() }
        probe.start()

        // 1. Editor live. The prompt ("`> `") is drawn by replxx only once
        //    it has the terminal in raw mode and the input thread is inside
        //    replxx_input — it is the deterministic arming signal, so the
        //    Ctrl+C below cannot race with canonical-mode signal delivery.
        probe.expect("PROBE:ready")
        probe.expect("> ")

        // 2. Cancel path: Ctrl+C must return the editor to a clean input
        //    state (replxx_input returns on abort; the probe re-enters).
        probe.send([3]) // Ctrl+C
        probe.expect("PROBE:cancel-returned")

        // 3. Type an unsent multiline Unicode draft. Ctrl+J inserts a
        //    newline; 4-byte emoji and combining marks exercise UTF-8
        //    fidelity; nothing is submitted yet.
        let draft = "he\u{301}llo \u{1F30D} line-one\n line-two done"
        for scalar in draft.unicodeScalars {
            if scalar == "\n" {
                probe.send([10]) // Ctrl+J
            } else {
                probe.send(Array(String(scalar).utf8))
            }
        }

        // 4. Synthetic streamed output while the composer is live — the
        //    concurrent-redraw property under test.
        probe.signal(SIGUSR1)
        let afterStream = probe.expect("PROBE:stream-done", timeoutMS: 20_000)
        #expect(afterStream.contains("PROBE:stream-0"), "stream never started: \(afterStream.suffix(200))")

        // 5. Resize 40 -> 120 -> 80 while the editor is live.
        probe.resize(rows: 24, cols: 40)
        probe.resize(rows: 24, cols: 120)
        probe.resize(rows: 24, cols: 80)

        // 6. Submit the draft with Enter and require the EXACT retained
        //    bytes to round-trip.
        probe.send("\r")
        let submitted = probe.expect("PROBE:line:")
        let expected = "PROBE:line:" + Data(draft.utf8).base64EncodedString()
        #expect(submitted.contains(expected),
                "retained draft bytes changed across the scenario; expected \(expected), transcript: \(submitted.suffix(400))")

        // 7. Completion-callback oracle on a FRESH line: the callback must
        //    fire and report its candidates (it may then modify the buffer,
        //    which is why the exactness oracle already ran).
        probe.send("pro\t")
        let completion = probe.expect("PROBE:completion-invoked")
        #expect(completion.contains("PROBE:completion-invoked count=2"),
                "completion callback did not fire with both candidates: \(completion.suffix(300))")

        // 8. Clear the completion insertion, quit cleanly, require exit 0.
        probe.send([21]) // Ctrl+U kills the line
        probe.send("quit\r")
        let transcript = probe.expect("PROBE:exit:0", timeoutMS: 20_000)
        #expect(transcript.contains("PROBE:exit:0"), "probe did not exit cleanly: \(transcript.suffix(300))")
        let status = probe.waitExit()
        #expect(status != nil, "probe did not exit within the deadline")
        #expect((status ?? 1) >> 8 == 0, "probe exit code: \(String(describing: status))")

        // 9. Functional terminal-state check after exit.
        #expect(probe.canonicalEchoRestored(), "terminal did not return to canonical echo after exit")
    }
}
