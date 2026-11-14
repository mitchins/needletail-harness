import Testing
import Foundation
import PTYShim

/// M4-D D3 PTY driver: spawns an ACTUAL binary (release `needletail
/// chat` for acceptance; debug for diagnostics) under a PTYShim-driven
/// PTY, with marker-based waits, bounded deadlines, and full-transcript
/// preservation. Extends the M0-C `ProbeProcess` pattern (kept
/// untouched in TerminalFeasibilityTests.swift) with configurable
/// argv/env and the chat-completion prompt as the arming signal.
///
/// Determinism rules: assert on markers/prompts/echo reports, never on
/// chunk arrival counts; every wait has a loud bound; failure dumps the
/// FULL transcript to `.needletail-dev/m4d-pty/<case>.log`.
final class ChatPTYDriver {
    private var pty = nt_pty_t()
    private var started = false
    private var cursor = ChatPTYTranscript()
    private let executable: String
    private let args: [String]
    private let extraEnv: [String: String]
    /// Failure hook (D7 review B6): the FULL transcript is delivered
    /// here on every `expect` timeout, so a readiness/prompt timeout
    /// fails WITH the promised transcript — never with just a tail.
    /// Set by the test leg (case-labelled preserve) right after init.
    var preserveTranscript: ((String) -> Void)? = nil

    init(executable: String, args: [String] = [], extraEnv: [String: String] = [:]) {
        self.executable = executable
        self.args = args
        self.extraEnv = extraEnv
    }

    @discardableResult
    func start() -> Bool {
        // Child-only environment: overrides are applied in the forked
        // child (never via parent setenv), so concurrently running
        // suites that mutate process env cannot leak into PTY children.
        // PTY legs always run unbudgeted: an inherited
        // NEEDLETAIL_REQUEST_BUDGET from another suite must not cap the
        // release binary under test.
        var envStrings = extraEnv.map { "\($0.key)=\($0.value)" }
        envStrings.append("NEEDLETAIL_REQUEST_BUDGET")
        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        var eStrings: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in cStrings { free(pointer) }
            for pointer in eStrings { free(pointer) }
            cStrings.removeAll()
            eStrings.removeAll()
        }
        cStrings.append(strdup(executable))
        for arg in args { cStrings.append(strdup(arg)) }
        cStrings.append(nil)
        for entry in envStrings { eStrings.append(strdup(entry)) }
        eStrings.append(nil)
        let result = cStrings.withUnsafeMutableBufferPointer { argvBuffer in
            eStrings.withUnsafeMutableBufferPointer { envBuffer in
                nt_pty_spawn_env(&pty, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        guard result == 0 else {
            Issue.record("pty.spawn-failure: could not spawn \(executable) \(args.joined(separator: " "))")
            return false
        }
        started = true
        return true
    }

    /// Reads until `marker` appears, the deadline passes, or the child
    /// exits. Searches the session transcript from the previous match.
    /// UTF-8 decodes INCREMENTALLY: a multi-byte scalar split across two
    /// reads must not become U+FFFD (lossy per-chunk decoding corrupts
    /// ZWJ/emoji/CJK and would fake a sanitizer leak).
    @discardableResult
    func expect(_ marker: String, timeoutMS: Int = 15_000) -> String {
        if let hit = cursor.take(through: marker) { return hit }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = nt_pty_read(&pty, &chunk, 4096, 250)
            if count > 0 {
                pendingBytes.append(contentsOf: chunk.prefix(Int(count)))
                cursor.append(decodePending())
                if let hit = cursor.take(through: marker) { return hit }
            } else if count == 0 {
                cursor.append(decodePending())
                if !pendingBytes.isEmpty {
                    // Truncated UTF-8 at EOF: one replacement marker.
                    cursor.append("\u{FFFD}")
                    pendingBytes.removeAll()
                }
                // A marker landing in the final bytes before the child
                // closes the PTY is a hit, not a timeout.
                // NOTE: count < 0 is the routine select-timeout retry
                // signal (nt_pty.c returns -1 when no data arrives
                // within the poll window), not a hard error — it must
                // keep polling until the deadline. All paths here are
                // deadline-bounded; there is no unbounded spin.
                if let hit = cursor.take(through: marker) { return hit }
                break // child closed the PTY
            }
        }
        Issue.record("probe.readiness-timeout: marker \(marker) not seen; transcript tail: \(cursor.tail)")
        preserveTranscript?(cursor.fullText)
        return ""
    }

    /// Incomplete UTF-8 sequences stay buffered until complete (or the
    /// 4-byte maximum is exceeded, in which case the lead byte is
    /// replaced once — a split multi-byte scalar never becomes FFFD).
    private var pendingBytes: [UInt8] = []

    /// Read available output until `timeoutMS` elapses without new
    /// data. Advances the transcript (so `transcriptSince` sees fresh
    /// bytes) without matching any marker and without recording any
    /// issue — the read side of freshness polling. EOF (count 0)
    /// ends the drain; select-timeouts (count < 0) keep polling
    /// until the deadline.
    func drain(timeoutMS: Int = 200) {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = nt_pty_read(&pty, &chunk, 4096, 100)
            if count > 0 {
                pendingBytes.append(contentsOf: chunk.prefix(Int(count)))
                cursor.append(decodePending())
            } else if count == 0 {
                cursor.append(decodePending())
                if !pendingBytes.isEmpty {
                    cursor.append("\u{FFFD}")
                    pendingBytes.removeAll()
                }
                return // child closed the PTY
            }
        }
    }

    private func decodePending() -> String {
        var out = ""
        var i = pendingBytes.startIndex
        while i < pendingBytes.endIndex {
            let byte = pendingBytes[i]
            let width: Int
            if byte & 0x80 == 0 { width = 1 }
            else if byte & 0xE0 == 0xC0 { width = 2 }
            else if byte & 0xF0 == 0xE0 { width = 3 }
            else if byte & 0xF8 == 0xF0 { width = 4 }
            else {
                // Invalid lead: consume one byte as FFFD and continue.
                out += "\u{FFFD}"
                i = pendingBytes.index(after: i)
                continue
            }
            let end = pendingBytes.index(i, offsetBy: width, limitedBy: pendingBytes.endIndex)
            guard let end, pendingBytes.distance(from: i, to: end) == width,
                  // Strict UTF-8 decode via the long-available
                  // bytes:encoding: form — String(validating:as:) is
                  // macOS 15+ and broke the macOS 14-floor test build.
                  let text = String(bytes: Array(pendingBytes[i..<end]), encoding: .utf8) else {
                // Incomplete (wait for more) or invalid (consume one).
                if let end, pendingBytes.distance(from: i, to: end) == width {
                    out += "\u{FFFD}"
                    i = pendingBytes.index(after: i)
                } else {
                    break
                }
                continue
            }
            out += text
            i = end
        }
        pendingBytes.removeFirst(i)
        return out
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            nt_pty_write(&pty, buffer.baseAddress!, buffer.count)
        }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func fullTranscript() -> String { cursor.fullText }

    /// Monotonic transcript cursor for freshness polling:
    /// `transcriptSince` returns only bytes appended after
    /// `transcriptMark()`. Non-consuming (the expect cursor is
    /// undisturbed), so polling for a marker never masks it.
    /// Scalar-based (not Character count): appending can merge a new
    /// scalar into the previous grapheme cluster ("\r" + "\n" → one
    /// Character), which would shift a Character-counted mark and skip
    /// the start of fresh output.
    func transcriptMark() -> Int { cursor.fullText.unicodeScalars.count }
    func transcriptSince(_ mark: Int) -> String {
        let scalars = cursor.fullText.unicodeScalars
        guard mark < scalars.count else { return "" }
        return String(String.UnicodeScalarView(scalars.dropFirst(mark)))
    }

    func signal(_ sig: Int32) { nt_pty_signal(&pty, sig) }

    func resize(rows: Int32, cols: Int32) { nt_pty_resize(&pty, rows, cols) }

    func waitExit(timeoutMS: Int = 15_000) -> Int32? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        while Date() < deadline {
            let status = nt_pty_wait(&pty, 250)
            if status >= 0 { return status }
        }
        return nil
    }

    /// Functional mode-restoration check after child exit.
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

/// Session-wide transcript with a read cursor (same mechanics as the
/// M0-C feasibility TranscriptCursor, duplicated for the configurable
/// driver to keep the M0-C evidence file untouched).
private struct ChatPTYTranscript {
    private var transcript = ""
    private var offset = 0

    mutating func append(_ text: String) { transcript += text }

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

    var fullText: String { transcript }
}

/// Decodes a raw waitpid status as returned by `nt_pty_wait`: true only
/// for a normal exit with code 0.
func chatPTYCleanExit(_ raw: Int32) -> Bool {
    (raw & 0x7F) == 0 && ((raw >> 8) & 0xFF) == 0
}
