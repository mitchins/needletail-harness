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

/// Decodes a raw waitpid status as returned by `nt_pty_wait`: true only
/// for a normal exit with code 0. A signal death (e.g. raw status 11 for
/// SIGSEGV) has a zero high byte but must never pass as a clean exit.
private func isCleanExitStatus(_ raw: Int32) -> Bool {
    (raw & 0x7F) == 0 && ((raw >> 8) & 0xFF) == 0
}

/// Session-wide transcript with a read cursor for `ProbeProcess.expect`.
/// Bytes arriving after a marker stay available to later searches: a
/// per-call buffer would drop them whenever one read chunk holds two
/// markers (e.g. `PROBE:ready` and the prompt), producing timing-dependent
/// timeouts. Offsets are UTF-8 integer offsets, not `String.Index`, so no
/// index-validity subtlety across appends.
private struct TranscriptCursor {
    private var transcript = ""
    private var offset = 0

    mutating func append(_ text: String) { transcript += text }

    /// Searches at/after the cursor; on a hit, advances past the marker
    /// and returns everything from the previous cursor to the marker end.
    /// On a miss the cursor does not move.
    mutating func take(through marker: String) -> String? {
        let utf8 = transcript.utf8
        let fromUTF8 = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex) ?? utf8.endIndex
        guard let from = String.Index(fromUTF8, within: transcript) else { return nil }
        guard let found = transcript.range(of: marker, range: from..<transcript.endIndex) else { return nil }
        let result = String(transcript[from..<found.upperBound])
        offset = utf8.distance(from: utf8.startIndex, to: found.upperBound)
        return result
    }

    var tail: String { String(transcript.suffix(400)) }

    /// The whole session transcript, for post-hoc analysis anchored on
    /// deterministic markers (e.g. the abort refresh preceding `^C`).
    var fullText: String { transcript }
}

private final class ProbeProcess {
    var pty = nt_pty_t()
    private var started = false
    private var cursor = TranscriptCursor()

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
    /// Searches the session transcript from the previous match, so bytes
    /// that arrived after an earlier marker are never lost.
    @discardableResult
    func expect(_ marker: String, timeoutMS: Int = readyTimeoutMS) -> String {
        if let hit = cursor.take(through: marker) { return hit }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = nt_pty_read(&pty, &chunk, 4096, 250)
            if count > 0 {
                cursor.append(String(decoding: chunk.prefix(Int(count)), as: UTF8.self))
                if let hit = cursor.take(through: marker) { return hit }
            } else if count == 0 {
                break // child closed the PTY
            }
        }
        Issue.record("probe.readiness-timeout: marker \(marker) not seen; transcript tail: \(cursor.tail)")
        return ""
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            nt_pty_write(&pty, buffer.baseAddress!, buffer.count)
        }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    /// The whole session transcript so far, for post-hoc analysis.
    func fullTranscript() -> String { cursor.fullText }

    func signal(_ sig: Int32) { nt_pty_signal(&pty, sig) }

    func resize(rows: Int, cols: Int) { nt_pty_resize(&pty, Int32(rows), Int32(cols)) }

    func waitExit(timeoutMS: Int = 15_000) -> Int32? {        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
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

    /// PTY-05 resize determinism, contracted without timing games. The
    /// abort refresh is the observation point: Ctrl+C is queued behind the
    /// typed bytes by PTY FIFO order, so when the abort runs the FULL
    /// 60-char line is in the buffer; abort resets the refresh clock, so
    /// its render is unthrottled; and it renders at the CURRENT columns,
    /// which the RESIZE event updated (never throttled). A full 60-char
    /// render ending at column 23 proves a two-row wrap at 40 cols; ending
    /// at column 63 proves a single row (100 cols or untouched). The slice
    /// is render-exact: abort writes the refresh and `^C` synchronously,
    /// so the last `"> "` before `^C` starts exactly the abort refresh —
    /// partial typing echoes cannot pollute it.
    @Test("PTY-05 resize to a narrower width rewraps the live composer")
    func PTY_05_narrowerResizeRewrapsComposer() {
        let probe = ProbeProcess()
        defer { probe.stop() }
        probe.start()
        probe.expect("PROBE:ready")
        probe.expect("> ")
        probe.resize(rows: 24, cols: 100)
        // Long draft, typed fire-and-forget: the test asserts on renders,
        // never on per-keystroke echoes.
        probe.send(String(repeating: "x", count: 60))
        probe.resize(rows: 24, cols: 40)
        probe.send([3]) // Ctrl+C aborts and re-arms a clean line
        probe.expect("PROBE:cancel-returned")
        probe.expect("> ")
        let transcript = probe.fullTranscript()
        guard let caret = transcript.range(of: "^C", options: .backwards) else {
            Issue.record("abort marker ^C missing from transcript")
            return
        }
        let before = transcript[..<caret.lowerBound]
        guard let promptStart = before.range(of: "> ", options: .backwards) else {
            Issue.record("abort refresh has no prompt start")
            return
        }
        let abortRefresh = String(before[promptStart.lowerBound...])
        #expect(abortRefresh.contains("[23G"), "abort refresh did not end wrapped at 40 cols: \(abortRefresh.suffix(200))")
        #expect(!abortRefresh.contains("[63G"), "abort refresh rendered single-row, resize had no effect: \(abortRefresh.suffix(200))")
        probe.send([21]) // Ctrl+U clears the retained draft
        probe.send("quit\r")
        _ = probe.expect("PROBE:exit:0", timeoutMS: 20_000)
        _ = probe.waitExit()
    }

    /// The single M0-C scenario (PTY-05 development evidence: TIOCSWINSZ
    /// 40→120→80 with a live multi-line composer, plus streaming, cancel,
    /// completion and clean exit in one bounded run). Ordering matters: the
    /// exact-draft oracle is asserted BEFORE any completion invocation,
    /// because replxx's Tab inserts the common candidate prefix.
    @Test("PTY-05 feasibility M0-C: draft preserved across streaming, resize and cancel; completion fires; clean exit")
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
        //    Wait for the re-armed prompt before typing: bytes sent while
        //    the terminal is still in canonical mode skip the readiness
        //    check the re-entry provides.
        probe.send([3]) // Ctrl+C
        probe.expect("PROBE:cancel-returned")
        probe.expect("> ")

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
        //    concurrent-redraw property under test. Streamed chunks are
        //    queued inside replxx and drained in FIFO order by the input
        //    thread, while `PROBE:stream-done` is a raw write that bypasses
        //    the queue: waiting for the LAST queued chunk (stream-23) is
        //    the deterministic proof that every chunk rendered.
        probe.signal(SIGUSR1)
        let afterStream = probe.expect("PROBE:stream-23 synthetic", timeoutMS: 20_000)
        #expect(afterStream.contains("PROBE:stream-0 synthetic"), "stream never started: \(afterStream.suffix(200))")

        // 5. Resize 40 -> 120 -> 80 while the editor is live.
        probe.resize(rows: 24, cols: 40)
        probe.resize(rows: 24, cols: 120)
        probe.resize(rows: 24, cols: 80)

        // 6. Submit the draft with Enter and require the EXACT retained
        //    bytes to round-trip. The full expected line is the marker:
        //    finding it proves the exact bytes arrived.
        probe.send("\r")
        let expected = "PROBE:line:" + Data(draft.utf8).base64EncodedString()
        let submitted = probe.expect(expected)
        #expect(submitted.contains(expected),
                "retained draft bytes changed across the scenario; expected \(expected), transcript: \(submitted.suffix(400))")

        // 7. Completion-callback oracle on a FRESH line: the callback must
        //    fire and report its candidates (it may then modify the buffer,
        //    which is why the exactness oracle already ran).
        probe.send("pro\t")
        let completion = probe.expect("PROBE:completion-invoked count=2")
        #expect(completion.contains("PROBE:completion-invoked count=2"),
                "completion callback did not fire with both candidates: \(completion.suffix(300))")

        // 8. Clear the completion insertion, quit cleanly, require exit 0.
        probe.send([21]) // Ctrl+U kills the line
        probe.send("quit\r")
        let transcript = probe.expect("PROBE:exit:0", timeoutMS: 20_000)
        #expect(transcript.contains("PROBE:exit:0"), "probe did not exit cleanly: \(transcript.suffix(300))")
        let status = probe.waitExit()
        #expect(status != nil, "probe did not exit within the deadline")
        #expect(status.map(isCleanExitStatus) ?? false, "probe did not exit with code 0: raw status \(String(describing: status))")

        // 9. Functional terminal-state check after exit.
        #expect(probe.canonicalEchoRestored(), "terminal did not return to canonical echo after exit")
    }
}

struct TranscriptCursorTests {

    /// PTY-05 driver mechanics: bytes after a marker survive for later
    /// searches, even when one chunk holds two markers.
    @Test("PTY-05 transcript keeps post-marker bytes for later searches")
    func PTY_05_transcriptKeepsPostMarkerBytes() {
        var cursor = TranscriptCursor()
        cursor.append("AAA PROBE:ready BBB ")
        let first = cursor.take(through: "PROBE:ready")
        #expect(first == "AAA PROBE:ready", "search returns up to the marker end, got \(first ?? "nil")")
        let second = cursor.take(through: "BBB")
        #expect(second == " BBB", "post-marker bytes must survive, got \(second ?? "nil")")
    }

    @Test("PTY-05 transcript finds markers split across appends")
    func PTY_05_transcriptFindsSplitMarkers() {
        var cursor = TranscriptCursor()
        cursor.append("PROBE:strea")
        #expect(cursor.take(through: "PROBE:stream-0") == nil, "partial marker must miss without advancing")
        cursor.append("m-0 synthetic tail")
        #expect(cursor.take(through: "PROBE:stream-0") == "PROBE:stream-0", "completed marker must hit")
    }

    @Test("PTY-05 transcript searches in order without skipping")
    func PTY_05_transcriptSearchesInOrder() {
        var cursor = TranscriptCursor()
        cursor.append("one two one two")
        #expect(cursor.take(through: "two") == "one two")
        #expect(cursor.take(through: "two") == " one two", "second search continues after the first match")
        #expect(cursor.take(through: "three") == nil)
    }
}

struct ExitStatusDecodingTests {

    /// PTY-07 exit semantics: only a normal exit with code 0 is clean.
    /// Signal deaths (SIGSEGV status 11, SIGKILL status 9) and nonzero
    /// codes must never pass.
    @Test("PTY-07 signal death never passes as a clean exit")
    func PTY_07_signalDeathIsNotCleanExit() {
        #expect(isCleanExitStatus(0), "normal exit 0 is clean")
        #expect(!isCleanExitStatus(11), "SIGSEGV death must not pass")
        #expect(!isCleanExitStatus(9), "SIGKILL death must not pass")
        #expect(!isCleanExitStatus(256), "exit code 1 (0x100) must not pass")
        #expect(!isCleanExitStatus(0x7F00), "stopped state must not pass")
    }
}
