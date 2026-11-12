import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M4-D D3 physical PTY acceptance: the ACTUAL release `needletail
/// chat` binary under a real terminal process (PTYShim forkpty),
/// driven by real key bytes/paste/resize/signals against the
/// deterministic loopback provider. No pure-snapshot substitution:
/// every case runs the shipped composition root.
///
/// Serialized: tests mutate process environment (driver child env)
/// and bind ephemeral loopback ports. A zero-test pass is FAIL — the
/// `run-m4d-pty.sh` runner asserts every required case executed its
/// expected nonzero count (B6 precedent). Failure preserves the FULL
/// transcript under `.needletail-dev/m4d-pty/<case>.log`.
@Suite(.serialized)
struct ChatPTYTests {
    static func repoRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/NeedletailTerminalTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .path
    }

    static func releaseBinary() -> String {
        repoRoot() + "/.build/release/needletail"
    }

    struct PTYEnv {
        let base: URL
        let stateDir: URL
        let configPath: String
        let server: LoopbackSSEServer?
    }

    /// Temp state dir + config. With a server, the profile points at
    /// loopback with the dummy bearer (the binary proves credential
    /// composition through the real path); without, a dummy URL that
    /// is never contacted (no provider traffic in that case).
    /// Child-process environment for the export probes (same state dir).
    static func driverSnapshot(_ env: PTYEnv) -> [String: String] {
        var child = ProcessInfo.processInfo.environment
        child["NEEDLETAIL_STATE_DIR"] = env.stateDir.path
        child[ChatLoopback.credentialEnv] = ChatLoopback.credentialValue
        return child
    }

    /// Child-only environment for spawned release-binary children:
    /// state dir + loopback bearer (+ optional extras), applied in the
    /// forked child by ChatPTYDriver — the parent process environment
    /// is NEVER mutated, so concurrently running suites cannot observe
    /// or clobber PTY credentials (M4-D isolation fix).
    static func childEnv(_ env: PTYEnv, extra: [String: String] = [:]) -> [String: String] {
        var child = ["NEEDLETAIL_STATE_DIR": env.stateDir.path,
                     ChatLoopback.credentialEnv: ChatLoopback.credentialValue]
        for (k, v) in extra { child[k] = v }
        return child
    }

    static func makeEnv(withServer: Bool, tools: String) throws -> PTYEnv {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-pty-\(UUID().uuidString)")
        let stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let server: LoopbackSSEServer?
        let baseURL: String
        if withServer {
            let s = try LoopbackSSEServer()
            s.start()
            server = s
            baseURL = s.baseURL
        } else {
            server = nil
            baseURL = "http://127.0.0.1:9"
        }
        let configPath = base.appendingPathComponent("config.json").path
        let origin = (try? parseBaseURL(baseURL, path: "$").origin) ?? "http://127.0.0.1:9"
        let text = """
            {"version":1,"default_model":"loop","allow_http_origins":["ORIGIN"],"models":[{"alias":"loop","protocol":"openai-chat-completions","base_url":"BASE","model":"test-model","context_window":4096,"max_output":128,"locality":"local","credential":{"env":"KEY"},"connect_timeout_s":5,"read_idle_timeout_s":120,"request_timeout_s":300,"max_in_flight":1}],"tools":TOOLS}
            """
            .replacingOccurrences(of: "ORIGIN", with: origin)
            .replacingOccurrences(of: "BASE", with: baseURL)
            .replacingOccurrences(of: "KEY", with: ChatLoopback.credentialEnv)
            .replacingOccurrences(of: "TOOLS", with: tools)
        try Data(text.utf8).write(to: URL(fileURLWithPath: configPath))
        return PTYEnv(base: base, stateDir: stateDir, configPath: configPath, server: server)
    }

    static func tearDown(_ env: PTYEnv, oldKey: String?) {
        env.server?.stop()
        if let oldKey { setenv(ChatLoopback.credentialEnv, oldKey, 1) } else { unsetenv(ChatLoopback.credentialEnv) }
        try? FileManager.default.removeItem(at: env.base)
    }

    /// Structure-only wrapper (kept so every PTY leg reads the same):
    /// the credential reaches the child via childEnv(), never via
    /// parent setenv — this body runs with the ambient environment.
    static func withCredentialKey(_ body: () async throws -> Void) async rethrows {
        try await body()
    }

    static func preserve(_ name: String, transcript: String) {
        let dir = repoRoot() + "/.needletail-dev/m4d-pty"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? transcript.write(toFile: dir + "/\(name).log", atomically: true, encoding: .utf8)
    }

    /// Settle-then-exit without a blind sleep. The first Ctrl+C exits an
    /// idle-empty loop at once (the common case — the short probe
    /// returns promptly, faster than the old fixed 2 s sleep).
    /// Otherwise it warned (queue pending), cleared a draft, or
    /// cancelled a still-finalizing turn; all three converge by sending
    /// one more Ctrl+C once any cancel grace has settled. The poll
    /// watches post-Ctrl+C output for the settled markers (fresh
    /// "idle" status, or the exit warning which is already settled),
    /// advancing the transcript with reads (a frozen transcript would
    /// never satisfy the wait) and returning the moment the child dies.
    /// Freshness is positional (transcript mark + slice), so earlier
    /// output can never satisfy the wait. A wedged loop still fails
    /// the caller's waitExit deadline below, never hangs the suite.
    static func settleThenExit(_ driver: ChatPTYDriver) async -> Int32? {
        driver.send([3])
        if let status = driver.waitExit(timeoutMS: 3_000) { return status }
        let mark = driver.transcriptMark()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let status = driver.waitExit(timeoutMS: 100) { return status }
            driver.drain(timeoutMS: 200)
            let fresh = driver.transcriptSince(mark)
            if fresh.contains("queued work pending") { break }
            if fresh.contains("idle") { break }
        }
        driver.send([3])
        return driver.waitExit(timeoutMS: 15_000)
    }

    @Test("PTY-01 release chat opens, idle-empty Ctrl+C exits 0, terminal restored")
    func pty01OpenCancelExitRestores() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: false, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-01-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            // Arming signal: the replxx prompt renders only once the
            // terminal is in raw mode and the input thread is inside
            // replxx_input — Ctrl+C cannot race canonical mode after it.
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send([3]) // Ctrl+C at idle-empty: clean exit, code 0.
            guard let status = driver.waitExit(timeoutMS: 15_000) else {
                Self.preserve("pty-01", transcript: driver.fullTranscript())
                Issue.record("PTY-01 release chat did not exit after idle-empty Ctrl+C")
                return
            }
            if !chatPTYCleanExit(status) {
                Self.preserve("pty-01", transcript: driver.fullTranscript())
            }
            #expect(chatPTYCleanExit(status), "PTY-01 exit must be code 0, raw status \(status)")
            #expect(driver.canonicalEchoRestored(), "PTY-01 terminal must return to canonical echo after exit")
        }
    }
}

extension ChatPTYTests {
    static func bearerViolation(_ server: LoopbackSSEServer?) -> String? {
        guard let server else { return "no server" }
        return ChatLoopback.bearerViolation(server: server, expected: ChatLoopback.credentialValue)
    }

    static func allowlistViolation(_ transcript: String, _ context: String) -> String? {
        if let v = VTAllowlist.violation(in: transcript) {
            return "\(context): allowlist violation: \(v)"
        }
        return nil
    }

    @Test("PTY-02 bracketed paste while streaming submits exactly once, literally")
    func pty02PasteDuringStream() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            // Hold after the first content chunk: the paste lands
            // provably mid-stream (non-vacuous concurrency proof).
            server.enqueue(ChatLoopback.textTurn("streaming base", splits: 3, gateAfter: 1, gateName: "p2"))
            server.enqueue(ChatLoopback.textTurn("paste answer", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-02-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("first\r")
            #expect(await server.waitUntilGateArmed("p2", timeout: 20), "gate never armed")
            // Multiline shell-looking paste INCLUDING a slash line:
            // literal, never executed, never submitted early.
            let paste = "line one\nrm -rf /\n/cancel\nline four"
            driver.send("\u{1B}[200~" + paste + "\u{1B}[201~")
            try? await Task.sleep(nanoseconds: 300_000_000)
            if server.requests.count != 1 {
                Self.preserve("pty-02", transcript: driver.fullTranscript())
            }
            #expect(server.requests.count == 1, "paste must not submit or execute (requests: \(server.requests.count))")
            server.releaseGate("p2")
            driver.expect("streaming base", timeoutMS: 20_000)
            // Submit the pasted buffer with Enter.
            driver.send("\r")
            driver.expect("paste answer", timeoutMS: 20_000)
            if server.requests.count != 2 {
                Self.preserve("pty-02", transcript: driver.fullTranscript())
                Issue.record("expected exactly two provider requests, got \(server.requests.count)")
                return
            }
            let body = String(decoding: server.requests[1].body, as: UTF8.self)
            for line in paste.split(separator: "\n") {
                // JSON escapes `/` as `\/`; normalize before comparing.
                let wire = String(line).replacingOccurrences(of: "/", with: "\\/")
                if !body.contains(wire) {
                    let raw = server.requests[1].body
                    let hex = raw.prefix(1200).map { String(format: "%02x", $0) }.joined()
                    Self.preserve("pty-02", transcript: driver.fullTranscript() + "\n---BODY---\n" + body + "\n---HEX---\n" + hex)
                }
                #expect(body.contains(wire), "request must carry pasted line verbatim: \(line)")
            }
            #expect(body.contains("/cancel"), "slash-looking paste line submits literally (never executed)")
            // Clean exit: turn done, composer idle-empty (helper polls
            // for settle, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-02", transcript: driver.fullTranscript())
                Issue.record("PTY-02 release chat did not exit"); return
            }
            if !chatPTYCleanExit(status) || driver.canonicalEchoRestored() == false {
                Self.preserve("pty-02", transcript: driver.fullTranscript())
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            if let v = Self.allowlistViolation(driver.fullTranscript(), "PTY-02") {
                Self.preserve("pty-02", transcript: driver.fullTranscript())
                Issue.record(Comment(rawValue: v))
            }
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("PTY-03 @ completion and bounded preview during output; Tab accepts exactly")
    func pty03CompletionDuringOutput() async throws {
        try await Self.withCredentialKey {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat-pty03-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            try "completion file bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("streaming output here", splits: 3, gateAfter: 1, gateName: "p3"))
            server.enqueue(ChatLoopback.textTurn("second turn done", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath, "--workspace", base.path],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-03-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("describe it\r")
            #expect(await server.waitUntilGateArmed("p3", timeout: 20), "gate never armed")
            // Type a mention mid-stream: the popup must list the
            // candidate with its bounded preview while output flows.
            driver.send("@he")
            driver.expect("hello.txt", timeoutMS: 15_000)
            // Tab accepts exactly (token, not string parsing), Enter
            // submits the accepted line. Readiness, not a fixed sleep:
            // the accept must land before Enter (else the draft carries
            // the raw query and the body oracle fails). Positional
            // freshness: the popup's "hello.txt" is pre-mark, so only
            // the ACCEPT repaint satisfies the wait.
            driver.send("\t")
            let tmark = driver.transcriptMark()
            var accepted = false
            let acceptDeadline = Date().addingTimeInterval(10)
            while !accepted, Date() < acceptDeadline {
                driver.drain(timeoutMS: 200)
                if driver.transcriptSince(tmark).contains("hello.txt") { accepted = true }
            }
            if !accepted {
                Self.preserve("pty-03", transcript: driver.fullTranscript())
                Issue.record("Tab accept never repainted the live line"); return
            }
            server.releaseGate("p3")
            driver.expect("streaming output here", timeoutMS: 20_000)
            driver.send("\r")
            driver.expect("second turn done", timeoutMS: 20_000)
            if server.requests.count != 2 {
                Self.preserve("pty-03", transcript: driver.fullTranscript())
                Issue.record("expected two provider requests, got \(server.requests.count)")
                return
            }
            #expect(server.requests.count == 2)
            let body = String(decoding: server.requests[1].body, as: UTF8.self)
            #expect(body.contains("completion file bytes"), "accepted mention must attach (request carries excerpt)")
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-03", transcript: driver.fullTranscript())
                Issue.record("PTY-03 release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            let transcript = driver.fullTranscript()
            if let v = Self.allowlistViolation(transcript, "PTY-03") {
                Self.preserve("pty-03", transcript: transcript)
                Issue.record(Comment(rawValue: v))
            }
            // No ghost popup: the candidate row renders once, inline.
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("PTY-04 queue during 100 streamed chunks, interrupt, no lost draft")
    func pty04QueueInterruptNoLostDraft() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            // 100 deterministic chunks, gate at #50: input lands
            // provably mid-stream.
            var bodies: [String] = []
            for i in 0..<100 { bodies.append("chunk-\(i) ") }
            server.enqueue(ChatLoopback.textTurn(bodies.joined(), splits: 100, gateAfter: 50, gateName: "p4"))
            server.enqueue(ChatLoopback.textTurn("go answer", splits: 1))
            server.enqueue(ChatLoopback.textTurn("head answer", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-04-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("first\r")
            #expect(await server.waitUntilGateArmed("p4", timeout: 20), "gate never armed")
            // Queue a follow-up mid-stream (Enter while busy queues,
            // never sends): exactly one provider request in flight.
            driver.send("queued-while-busy\r")
            try? await Task.sleep(nanoseconds: 300_000_000)
            if server.requests.count != 1 {
                Self.preserve("pty-04", transcript: driver.fullTranscript())
                Issue.record("expected exactly one provider request, got \(server.requests.count)"); return
            }
            // Leave an unsent draft in the live buffer, then cancel:
            // the draft must survive the cancel untouched (byte-exact
            // in the live transcript — the system never wipes it).
            driver.send("partial-draft-kept")
            driver.send([3])
            driver.expect("held", timeoutMS: 20_000)
            if !driver.fullTranscript().contains("partial-draft-kept") {
                Self.preserve("pty-04", transcript: driver.fullTranscript())
                Issue.record("cancel wiped the unsent draft"); return
            }
            // The cancel grace is a deterministic 5 s timer: resume needs
            // the settled interrupted+held state. Retry resume until
            // accepted (bounded): a fixed 7 s sleep is too short on a
            // slow host and wasteful on a fast one. Refused resumes are
            // loud no-ops (a denial notice, no state change — the draft
            // was already cleared), so retrying is safe; acceptance
            // renders "resumed". Freshness is positional (transcript
            // mark), so earlier output can never satisfy the wait.
            // Ctrl+U clears the proven draft (explicit operator action),
            // then resume unholds and the gate release frees the server
            // from the dead gated stream. A fresh submit dispatches
            // immediately (qualified Core admission is not gated on a
            // non-empty queue); the queued head follows on completion.
            driver.send([21])
            let rmark = driver.transcriptMark()
            var resumed = false
            var childDead = false
            let resumeDeadline = Date().addingTimeInterval(30)
            while !resumed, !childDead, Date() < resumeDeadline {
                driver.send("/queue resume\r")
                let attemptEnd = Date().addingTimeInterval(2)
                while !resumed, !childDead, Date() < attemptEnd {
                    if driver.waitExit(timeoutMS: 100) != nil { childDead = true; break }
                    driver.drain(timeoutMS: 200)
                    if driver.transcriptSince(rmark).contains("resumed") { resumed = true }
                }
            }
            if !resumed {
                Self.preserve("pty-04-noresume", transcript: driver.fullTranscript())
                Issue.record("resume never accepted after cancel grace"); return
            }
            server.releaseGate("p4")
            driver.send("go\r")
            driver.expect("go answer", timeoutMS: 20_000)
            driver.expect("head answer", timeoutMS: 20_000)
            if server.requests.count != 3 {
                Self.preserve("pty-04", transcript: driver.fullTranscript())
                Issue.record("expected first + go + head requests, got \(server.requests.count)"); return
            }
            let goBody = String(decoding: server.requests[1].body, as: UTF8.self)
            #expect(goBody.contains("\"content\":\"go\""), "fresh submit dispatches as its own turn")
            let headBody = String(decoding: server.requests[2].body, as: UTF8.self)
            #expect(headBody.contains("queued-while-busy"), "queued head follows on completion")
            // Liveness probe before exit: typed text must echo (proves the
            // input thread is alive in readLine, independent of loop
            // state). No submit, no new requests.
            driver.send("xyz")
            driver.expect("xyz", timeoutMS: 10_000)
            driver.send([21])
            // Inspect the queue before exit (diagnostic for the exit path).
            driver.send("/queue\r")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-04", transcript: driver.fullTranscript())
                Issue.record("PTY-04 release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            if let v = Self.allowlistViolation(driver.fullTranscript(), "PTY-04") {
                Self.preserve("pty-04", transcript: driver.fullTranscript())
                Issue.record(Comment(rawValue: v))
            }
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }



}

extension ChatPTYTests {
    @Test("PTY-05 real TIOCSWINSZ 40→120→80 redraws the live composer without hang")
    func pty05RealResizeRedraw() async throws {
        try await ChatPTYTests.withCredentialKey {
            let env = try ChatPTYTests.makeEnv(withServer: false, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { ChatPTYTests.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            let driver = ChatPTYDriver(
                executable: ChatPTYTests.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-05-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            // Spec sequence 40→120→80 with the cursor in a multi-line
            // composer: must redraw, never hang, never emit
            // out-of-bounds cursor addressing.
            driver.resize(rows: 24, cols: 40)
            driver.send(String(repeating: "x", count: 60))
            driver.resize(rows: 24, cols: 120)
            driver.resize(rows: 24, cols: 80)
            // Clear the retained draft, then idle-empty Ctrl+C exits.
            driver.send([21]) // Ctrl+U kills the line
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                ChatPTYTests.preserve("pty-05", transcript: driver.fullTranscript())
                Issue.record("PTY-05 release chat did not exit after resizes")
                return
            }
            let transcript = driver.fullTranscript()
            if !chatPTYCleanExit(status) {
                ChatPTYTests.preserve("pty-05", transcript: transcript)
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            // Cursor discipline: project the abort-to-exit region; the
            // projection must never see an unknown sequence, and no
            // absolute cursor address may target outside the 80-column
            // viewport (stale-width cursor math after the 40→120→80
            // storm would park the cursor off-screen — D7 review B6:
            // the old `cursorCol <= 81` bound was tautological because
            // the projection clamps).
            var projection = VTProjection(rows: 24, cols: 80)
            projection.feed(transcript)
            if projection.sawUnsupported || projection.sawOutOfRange {
                ChatPTYTests.preserve("pty-05", transcript: transcript)
            }
            #expect(!projection.sawUnsupported, "no unknown sequences during resize storm")
            #expect(!projection.sawOutOfRange, "no off-viewport cursor address after resizes")
            if let v = ChatPTYTests.allowlistViolation(transcript, "PTY-05") {
                ChatPTYTests.preserve("pty-05", transcript: transcript)
                Issue.record(Comment(rawValue: v))
            }
        }
    }
}

extension ChatPTYTests {
    @Test("PTY-06 hostile OSC/cursor/Cf stream cannot control the terminal")
    func pty06HostileStream() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            // One text turn carrying the hostile battery: OSC title set,
            // cursor motion, C0/C1, lone Cf (ZWJ joins legitimately and
            // must survive), bidi controls. Chunked to prove no
            // split-boundary bypass.
            let hostile = "Hello \u{1B}]0;pwned\u{07} world \u{1B}[10;20H moved \u{01}c0\u{7F}del end\u{200D}cf\u{200B}\u{202E}bidi \u{1F600}emoji DONE"
            server.enqueue(ChatLoopback.textTurn(hostile, splits: 9))
            server.enqueue(ChatLoopback.textTurn("after", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-06-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("go\r")
            driver.expect("DONE", timeoutMS: 20_000)
            driver.send("next\r")
            driver.expect("after", timeoutMS: 20_000)
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-06", transcript: driver.fullTranscript())
                Issue.record("PTY-06 release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            let transcript = driver.fullTranscript()
            // (a) Untrusted bytes never appear unsanitized: no raw ESC
            // outside the harness allowlist.
            if let v = Self.allowlistViolation(transcript, "PTY-06") {
                Self.preserve("pty-06", transcript: transcript)
                Issue.record(Comment(rawValue: v))
            }
            // (b) The OSC title model still equals baseline: the terminal
            // title was not changed by untrusted content.
            var projection = VTProjection(rows: 24, cols: 80)
            projection.feed(transcript)
            #expect(projection.title.isEmpty, "terminal title changed by hostile stream: \(projection.title)")
            if projection.sawUnsupported {
                Self.preserve("pty-06", transcript: transcript)
            }
            #expect(!projection.sawUnsupported, "unknown sequences during hostile stream")
            // (c) Scalar-level Cf battery: only ZWJ survives (macOS
            // `contains` is vacuous on lone invisibles — assert on
            // unicodeScalars per the M4-C finding).
            let hexDump = transcript.utf8.prefix(3000).map { String(format: "%02x", $0) }.joined()
            Self.preserve("pty-06-hex", transcript: hexDump)
            let badCf = transcript.unicodeScalars.filter { s in
                guard s.value >= 0x200B && s.value <= 0x206F else { return false }
                return s.value != 0x200D
            }
            if !badCf.isEmpty {
                Self.preserve("pty-06", transcript: transcript)
            }
            #expect(badCf.isEmpty, "lone Cf scalars leaked to the terminal: \(badCf.prefix(8).map { String($0.value, radix: 16) })")
            // Scalar-level ZWJ survival (D0.2: `String.contains` on a
            // lone invisible returns FALSE on macOS even when present —
            // a `.contains("\u{200D}")` oracle here would be vacuous on
            // the macOS leg, so assert at unicodeScalars level).
            #expect(hasScalar(transcript, 0x200D), "ZWJ must survive (joiner, not control)")
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("PTY-07 catchable SIGTERM/EOF restores; SIGKILL has no in-process cleanup; session recovers")
    func pty07SignalsAndRecovery() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("persist me", splits: 1))
            server.enqueue(ChatLoopback.textTurn("second", splits: 1))
            let traceURL = env.stateDir.appendingPathComponent("trace.jsonl")
            let sessionID: String = try await {
                let driver = ChatPTYDriver(
                    executable: Self.releaseBinary(),
                    args: ["chat", "--config", env.configPath, "--trace", traceURL.path],
                    extraEnv: Self.childEnv(env))
                defer { driver.stop() }
                driver.preserveTranscript = { Self.preserve("pty-07-timeout", transcript: $0) }
                guard driver.start() else { return "NO-START" }
                driver.expect("needletail> ", timeoutMS: 30_000)
                driver.send("remember this\r")
                driver.expect("persist me", timeoutMS: 20_000)
                // Wait for the DURABLE commit before SIGTERM: the render
                // (tap complete) precedes the transcript apply by design,
                // so "bytes seen" is not "durable". Poll the export tool
                // (the real recovery path) until the turn is committed —
                // bounded, deterministic, no sleeps-as-oracles. Killing
                // before the commit would be a crash-boundary run (data
                // shows unfinished) — not what this leg proves.
                var committed = false
                let commitDeadline = Date().addingTimeInterval(20)
                let preURL = env.base.appendingPathComponent("pre.json")
                // The session ID comes from the trace (first envelope).
                var tracedSession: String? = nil
                if let trace = try? String(contentsOf: traceURL, encoding: .utf8),
                   let line = trace.split(separator: "\n").first,
                   let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    tracedSession = json["session_id"] as? String
                }
                while Date() < commitDeadline && !committed, let sid = tracedSession {
                    let probe = Process()
                    probe.executableURL = URL(fileURLWithPath: Self.releaseBinary())
                    probe.arguments = ["session", "export", sid, "--output", preURL.path, "--include-content"]
                    probe.environment = Self.driverSnapshot(env)
                    try? FileManager.default.removeItem(at: preURL)
                    try probe.run()
                    probe.waitUntilExit()
                    if let text = try? String(contentsOf: preURL, encoding: .utf8),
                       text.contains("\"text\":\"remember this\"") { committed = true }
                    if !committed { try? await Task.sleep(nanoseconds: 200_000_000) }
                }
                #expect(committed, "turn must commit durably before SIGTERM")
                // Catchable SIGTERM: restores termios, exits 143.
                driver.signal(15)
                guard let status = driver.waitExit(timeoutMS: 15_000) else {
                    Self.preserve("pty-07-term", transcript: driver.fullTranscript())
                    Issue.record("PTY-07 child survived SIGTERM (catchable exit broken)")
                    return "NO-EXIT"
                }
                let code = (status >> 8) & 0xFF
                if code != 143 {
                    Self.preserve("pty-07-term", transcript: driver.fullTranscript())
                }
                #expect(code == 143, "SIGTERM must restore + exit 143, raw \(status)")
                #expect(driver.canonicalEchoRestored(), "termios restored after SIGTERM")
                // Recover the session ID from the trace for the export leg.
                guard let trace = try? String(contentsOf: traceURL, encoding: .utf8),
                      let line = trace.split(separator: "\n").first,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = json["session_id"] as? String else {
                    Self.preserve("pty-07-term", transcript: driver.fullTranscript())
                    Issue.record("PTY-07 trace missing session_id; cannot prove recovery")
                    return "NO-SID"
                }
                return sid
            }()
            #expect(!sessionID.hasPrefix("NO-"), "SIGTERM leg failed: \(sessionID)")
            // SIGKILL: no in-process cleanup is claimed. The store must
            // still reconcile and the session must export.
            do {
                let killer = ChatPTYDriver(
                    executable: Self.releaseBinary(),
                    args: ["chat", "--config", env.configPath],
                    extraEnv: Self.childEnv(env))
                defer { killer.stop() }
                killer.preserveTranscript = { Self.preserve("pty-07-kill-timeout", transcript: $0) }
                guard killer.start() else { return }
                killer.expect("needletail> ", timeoutMS: 30_000)
                killer.signal(9)
                let status = killer.waitExit(timeoutMS: 15_000)
                #expect(status != nil, "SIGKILLed child must die")
                if let raw = status, chatPTYCleanExit(raw) {
                    Issue.record("SIGKILL must not look like a clean exit")
                }
            }
            // Recovery: the durable session exports and contains the
            // turn. The SIGTERM may land mid-commit (render precedes
            // the durable apply by design), so the export is the
            // CRASH-BOUNDARY oracle: it must always succeed, and the
            // user text must be there once the commit lands (bounded
            // poll — the catchable exit flushed it within the grace).
            let exportURL = env.base.appendingPathComponent("export.json")
            var storeEnv = ProcessInfo.processInfo.environment
            storeEnv["NEEDLETAIL_STATE_DIR"] = env.stateDir.path
            var exported = ""
            var exportedOnce = false
            let exportDeadline = Date().addingTimeInterval(20)
            while Date() < exportDeadline {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: Self.releaseBinary())
                proc.arguments = ["session", "export", sessionID, "--output", exportURL.path, "--include-content"]
                proc.environment = storeEnv
                try? FileManager.default.removeItem(at: exportURL)
                try proc.run()
                proc.waitUntilExit()
                #expect(proc.terminationStatus == 0, "session export must succeed (exit \(proc.terminationStatus))")
                exported = (try? String(contentsOf: exportURL, encoding: .utf8)) ?? ""
                exportedOnce = true
                if exported.contains("persist me") { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            _ = exportedOnce
            if !exported.contains("persist me") {
                Self.preserve("pty-07-export", transcript: "sid=\(sessionID) content=\(exported.prefix(1500))")
            }
            #expect(exportedOnce, "export must have run")
            #expect(exported.contains("persist me"), "pre-kill turn must survive in the durable session")
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("PTY-08 TERM matrix degrades honestly; real tmux path is stable")
    func pty08TermModesAndRealTmux() async throws {
        try await Self.withCredentialKey {
            // Simulated matrix legs (TERM=dumb, NO_COLOR, narrow) against
            // the release binary: prompt + turn + clean exit each.
            for (name, extra): (String, [String: String]) in [
                ("dumb", ["TERM": "dumb"]),
                ("nocolor", ["NO_COLOR": "1"]),
                ("narrow", ["COLUMNS": "20"]),
            ] {
                let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
                defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
                guard let server = env.server else { Issue.record("no loopback"); return }
                server.enqueue(ChatLoopback.textTurn("\(name) ok", splits: 1))
                let driver = ChatPTYDriver(
                    executable: Self.releaseBinary(),
                    args: ["chat", "--config", env.configPath],
                    extraEnv: Self.childEnv(env, extra: extra))
                defer { driver.stop() }
                driver.preserveTranscript = { Self.preserve("pty-08-\(name)-timeout", transcript: $0) }
                guard driver.start() else { Issue.record("pty spawn failed"); return }
                driver.expect("needletail> ", timeoutMS: 30_000)
                driver.send("go\r")
                driver.expect("\(name) ok", timeoutMS: 20_000)
                // TERM=dumb takes replxx's line-based fallback path (no
                // raw mode, no key bindings), so Ctrl+C-as-key does not
                // exist there — exit via the catchable SIGTERM handler
                // (which works in both modes) and assert exit 143.
                driver.signal(15)
                guard let status = driver.waitExit(timeoutMS: 15_000) else {
                    Self.preserve("pty-08-\(name)", transcript: driver.fullTranscript())
                    Issue.record("PTY-08 [\(name)] did not exit"); return
                }
                let code = (status >> 8) & 0xFF
                #expect(code == 143 || chatPTYCleanExit(status), "PTY-08 [\(name)] clean or SIGTERM exit, raw \(status)")
                #expect(driver.canonicalEchoRestored(), "PTY-08 [\(name)] terminal restored")
                // D1.1/D7-review-B5: every real-traffic leg proves the
                // dummy-bearer composition (a wrong-but-present bearer
                // would be served and pass without this).
                if let b = Self.bearerViolation(server) { Issue.record("PTY-08 [\(name)] credential: \(b)") }
            }
            // REAL tmux path (labelled REAL-TMUX, not simulated TERM):
            // the release binary under a live tmux server + pty.
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("tmux turn ok", splits: 1))
            let tmuxName = "m4d-pty08-\(UUID().uuidString.prefix(8))"
            func tmux(_ args: String...) throws -> String {
                let proc = Process()
                // Resolve via PATH (/usr/bin/env): a hard-coded
                // /usr/bin/tmux misses Homebrew (/opt/homebrew, /usr/local).
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["tmux"] + args
                // Capture to a FILE, never a pipe: a daemonized tmux
                // server can inherit the client's stdout and hold a pipe
                // open forever, so no pipe read (blocking or polling) is
                // a safe join primitive here. Files never block.
                let outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("m4d-pty08-out-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: outURL.path, contents: nil)
                guard let outHandle = FileHandle(forWritingAtPath: outURL.path) else {
                    throw TestSkip.tmuxFailed("cannot open capture file")
                }
                defer {
                    try? outHandle.close()
                    try? FileManager.default.removeItem(at: outURL)
                }
                proc.standardOutput = outHandle
                // PTY-08 CI finding (diagnostic 43134786983): the CI
                // test-runner process has fd 0 CLOSED — tmux inherited it
                // and hung silently before server bootstrap; a /dev/null
                // stdin handle opened INTO slot 0 made Foundation's spawn
                // fail EBADF. Heal fd 0 first (valid stdin for this
                // process and every spawned child), then set stdin
                // explicitly. Verified by the CI feasibility lane.
                #if canImport(Glibc)
                if fcntl(0, F_GETFD) == -1, errno == EBADF {
                    _ = open("/dev/null", O_RDONLY)
                }
                #elseif canImport(Darwin)
                if fcntl(0, F_GETFD) == -1, errno == EBADF {
                    _ = Darwin.open("/dev/null", O_RDONLY)
                }
                #endif
                if let nullStdin = FileHandle(forReadingAtPath: "/dev/null") {
                    proc.standardInput = nullStdin
                    defer { try? nullStdin.close() }
                }
                var childEnv = ProcessInfo.processInfo.environment
                childEnv["TERM"] = "xterm"
                proc.environment = childEnv
                try proc.run()
                // Bounded join, polled by the CALLER (never a spawned
                // watchdog thread — thread creation must not be on the
                // critical path of a hang bound). A wedged tmux server
                // must fail this leg loudly, never hang the suite.
                let tmuxDeadline = Date().addingTimeInterval(30)
                while proc.isRunning, Date() < tmuxDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if proc.isRunning {
                    // SIGTERM first (clean exit path); escalate to SIGKILL:
                    // a client wedged in an uninterruptible server wait
                    // must not survive as an orphan, and waitUntilExit
                    // must have a dead child to reap.
                    proc.interrupt()
                    proc.terminate()
                    Thread.sleep(forTimeInterval: 1)
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                    throw TestSkip.tmuxFailed("tmux hung: \(args.joined(separator: " "))")
                }
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { throw TestSkip.tmuxFailed(args.joined(separator: " ")) }
                return (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            }
            // Cleanup on EVERY exit path, registered BEFORE the first
            // tmux call: a new-session failure must still attempt the
            // kill (no-op if the session was never created).
            defer { _ = try? tmux("kill-session", "-t", tmuxName) }
            do {
                _ = try tmux("new-session", "-d", "-s", tmuxName, "-x", "80", "-y", "24",
                               "-e", "NEEDLETAIL_STATE_DIR=\(env.stateDir.path)",
                               "-e", "\(ChatLoopback.credentialEnv)=\(ChatLoopback.credentialValue)")
                // Leg deadline: with a sick tmux server every call can
                // burn its 30 s watchdog (150+200 iterations would exceed
                // any step budget silently). A deadline breach throws to
                // the catch below — loud, never silent.
                let legDeadline = Date().addingTimeInterval(600)
                // Pass loopback env at session creation: tmux only applies
                // set-environment to subsequently spawned processes, so the
                // session's initial shell would otherwise miss the state
                // dir and loopback bearer.
                _ = try tmux("send-keys", "-t", tmuxName,
                    "\(Self.releaseBinary()) chat --config \(env.configPath)", "Enter")
                // Wait for the prompt via capture-pane polling.
                var ready = false
                var lastPane = ""
                var probeCount = 0
                while !ready, probeCount < 150, Date() < legDeadline {
                    probeCount += 1
                    let pane = try tmux("capture-pane", "-t", tmuxName, "-p")
                    lastPane = pane
                    // capture-pane trims the prompt's trailing space.
                    if pane.contains("needletail>") { ready = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Date() >= legDeadline { throw TestSkip.tmuxFailed("leg deadline exceeded waiting for prompt") }
                if !ready {
                    Self.preserve("pty-08-tmux-noprompt", transcript: lastPane)
                }
                #expect(ready, "REAL-TMUX prompt never appeared")
                _ = try tmux("send-keys", "-t", tmuxName, "go", "Enter")
                var done = false
                var turnProbes = 0
                while !done, turnProbes < 200, Date() < legDeadline {
                    turnProbes += 1
                    let pane = try tmux("capture-pane", "-t", tmuxName, "-p")
                    lastPane = pane
                    if pane.contains("tmux turn ok") { done = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Date() >= legDeadline { throw TestSkip.tmuxFailed("leg deadline exceeded waiting for turn") }
                if !done {
                    Self.preserve("pty-08-tmux-noturn", transcript: lastPane)
                }
                #expect(done, "REAL-TMUX turn never completed")
                // Exit the chat (Ctrl+C at idle-empty, PTY-01 path),
                // then clean the session. Exit-code fidelity through
                // tmux is covered by the direct-PTY legs; here the
                // composition proof is prompt + turn + cleanup.
                _ = try tmux("send-keys", "-t", tmuxName, "C-c")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
            } catch {
                Self.preserve("pty-08-tmux", transcript: "tmux setup failed: \(error)")
                Issue.record("REAL-TMUX path failed: \(error)")
            }
        }
    }

    enum TestSkip: Error {
        case tmuxFailed(String)
    }

    @Test("PTY-07 EOF (Ctrl+D) on an empty line exits cleanly")
    func pty07EofExitsCleanly() async throws {
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: false, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-07-eof-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send([4]) // Ctrl+D on the empty line: EOF.
            guard let status = driver.waitExit(timeoutMS: 15_000) else {
                Self.preserve("pty-07-eof", transcript: driver.fullTranscript())
                Issue.record("PTY-07 EOF did not exit"); return
            }
            if !chatPTYCleanExit(status) {
                Self.preserve("pty-07-eof", transcript: driver.fullTranscript())
            }
            #expect(chatPTYCleanExit(status), "EOF exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored after EOF")
        }
    }

    @Test("D2.7 confirm hygiene: Up-arrow after approval recalls the draft, never the decision line")
    func testConfirmHygieneNoDecisionInHistory() async throws {
        // Live proof for `LineEditorHistoryTests` (D7 review B2): only
        // a real replxx accept commits history, so only the release
        // binary can prove the `y` decision line never persists. After
        // a real approval, Up-arrow must recall the pre-confirm draft;
        // resubmitting it proves (via the provider request body) the
        // recalled line is the draft — a persisted `y` would submit
        // "y" instead and fail the body oracle below.
        try await Self.withCredentialKey {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat-hyg-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            try "hygiene file bytes".write(to: base.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":true,"search":true,"edit":false,"write":true,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("first answer", splits: 1))
            server.enqueue(ChatLoopback.toolTurn(name: "write", arguments: #"{"path":"note.txt","content":"hygiene bytes"}"#, prefixText: "writing:"))
            server.enqueue(ChatLoopback.textTurn("after write", splits: 1))
            server.enqueue(ChatLoopback.textTurn("recall done", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath, "--workspace", base.path],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-hygiene-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("first\r")
            driver.expect("first answer", timeoutMS: 20_000)
            driver.send("write the note\r")
            driver.expect("approval required:", timeoutMS: 20_000)
            driver.send("y\r")
            driver.expect("after write", timeoutMS: 20_000)
            // Up-arrow recalls history; append one character (the
            // recall proof below needs a body oracle distinct from the
            // earlier "write the note" request) and Enter resubmits.
            // Resubmission mints a FRESH command ID per Enter event, so
            // even a byte-identical recall dispatches a genuine second
            // turn (M4-D residual fix — the old same-text ID reuse made
            // Core replay the prior admission as a silent no-op).
            // The fourth provider request proves WHAT was recalled.
            driver.send([0x1B, 0x5B, 0x41]) // Up
            // Readiness, not sleep: the recall must render before "?"
            // is typed, or "?" submits on an empty line. The recalled
            // "write the note" echo was consumed by the earlier
            // approval-flow expects, so expect() waits for the fresh
            // recall render.
            driver.expect("write the note", timeoutMS: 20_000)
            driver.send("?")
            driver.send("\r")
            driver.expect("recall done", timeoutMS: 20_000)
            if server.requests.count != 4 {
                Self.preserve("pty-hygiene", transcript: driver.fullTranscript())
                Issue.record("expected four provider requests, got \(server.requests.count)")
                return
            }
            let recall = String(decoding: server.requests[3].body, as: UTF8.self)
            #expect(recall.contains("write the note?"), "Up-arrow must recall the draft, got: \(recall.suffix(300))")
            #expect(!recall.contains("\"content\":\"y"), "decision line must not persist in history")
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-hygiene", transcript: driver.fullTranscript())
                Issue.record("PTY hygiene release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            let transcript = driver.fullTranscript()
            if let v = Self.allowlistViolation(transcript, "PTY-hygiene") {
                Self.preserve("pty-hygiene", transcript: transcript)
                Issue.record(Comment(rawValue: v))
            }
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("TERM-04 non-TTY refusal is fail-closed + --help documents chat")
    func term04NonTTYRefusalAndHelp() async throws {
        // D0.4 TERM-04 as-built: `chat` deliberately refuses when
        // stdin/stdout are not TTYs (fail-closed; automation keeps
        // using headless `run` — the refusal text says so). A
        // "loopback run asserting plain output" cannot exist against
        // that refusal, so this leg pins the refusal contract
        // instead: exit 2, exact guidance, zero ANSI, zero provider
        // traffic. Plain-output-on-a-terminal is covered by the
        // PTY-08 TERM=dumb leg (line-based fallback) and by
        // `TerminalCapsTests` (unit).
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            // --help discoverability surface (cheap, same binary).
            do {
                let help = Process()
                help.executableURL = URL(fileURLWithPath: Self.releaseBinary())
                help.arguments = ["--help"]
                let pipe = Pipe()
                let errPipe = Pipe()
                help.standardOutput = pipe
                help.standardError = errPipe
                try help.run()
                help.waitUntilExit()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(help.terminationStatus == 0, "--help must exit 0")
                #expect(text.contains("chat"), "--help must document chat")
            }
            // Non-TTY pipes: the refusal must be exact, plain, and
            // must never dial the provider.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Self.releaseBinary())
            proc.arguments = ["chat", "--config", env.configPath]
            proc.environment = Self.driverSnapshot(env)
            proc.standardInput = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            try proc.run()
            proc.waitUntilExit()
            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(proc.terminationStatus == 2, "non-TTY chat must refuse with exit 2, got \(proc.terminationStatus)")
            #expect(err.contains("requires an interactive terminal"), "refusal guidance must name the terminal requirement, got: \(err.suffix(200))")
            #expect(err.contains("needletail run"), "refusal must redirect to headless run, got: \(err.suffix(200))")
            #expect(!out.contains("\u{1B}") && !err.contains("\u{1B}"), "refusal output must carry zero ANSI escapes")
            #expect(server.requests.isEmpty, "refused chat must send zero provider traffic")
        }
    }

    @Test("RESUBMIT byte-identical second Enter dispatches a genuine second turn")
    func identicalResubmitAdmitsTwice() async throws {
        // Release-PTY proof for the M4-D residual fix: two EXPLICIT
        // Enter events carrying byte-identical text must produce two
        // provider dispatches (two genuine Core admissions with distinct
        // command IDs). The old same-text ID reuse replayed the first
        // admission without dispatching — requests stayed at 1.
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("first same answer", splits: 1))
            server.enqueue(ChatLoopback.textTurn("second same answer", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-resubmit-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("same question twice\r")
            driver.expect("first same answer", timeoutMS: 20_000)
            // Byte-identical second Enter AFTER the first turn finished
            // (a queued follow-up would also dispatch twice, so the
            // answer wait above is the non-vacuous resubmission proof).
            driver.send("same question twice\r")
            driver.expect("second same answer", timeoutMS: 20_000)
            if server.requests.count != 2 {
                Self.preserve("pty-resubmit", transcript: driver.fullTranscript())
                Issue.record("identical resubmit must dispatch twice, got \(server.requests.count) requests")
                return
            }
            let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
            #expect(bodies.allSatisfy { $0.contains("same question twice") }, "both turns must carry the submitted text")
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-resubmit", transcript: driver.fullTranscript())
                Issue.record("PTY resubmit release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            let transcript = driver.fullTranscript()
            if let v = Self.allowlistViolation(transcript, "PTY-resubmit") {
                Self.preserve("pty-resubmit", transcript: transcript)
                Issue.record(Comment(rawValue: v))
            }
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }

    @Test("PARITY fixed scenario renders in the release binary exactly what the semantic frames say")
    func parityFixedScenario() async throws {
        // D4.3 release-binary vs semantic-frame parity (PTY side). The
        // semantic side is pinned deterministically in
        // `ChatRenderParityTests` (submitted state + tap block +
        // candidate rows); this leg drives the RELEASE binary through
        // the same fixed scenario and asserts the transcript carries
        // the same hand-written strings in order. Agreement by
        // construction, never by generation.
        try await Self.withCredentialKey {
            let env = try Self.makeEnv(withServer: true, tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { Self.tearDown(env, oldKey: getenv(ChatLoopback.credentialEnv).map { String(cString: $0) }) }
            guard let server = env.server else { Issue.record("no loopback"); return }
            server.enqueue(ChatLoopback.textTurn("parity line one\n\nparity line two", splits: 1))
            let driver = ChatPTYDriver(
                executable: Self.releaseBinary(),
                args: ["chat", "--config", env.configPath],
                extraEnv: Self.childEnv(env))
            defer { driver.stop() }
            driver.preserveTranscript = { Self.preserve("pty-parity-timeout", transcript: $0) }
            guard driver.start() else { Issue.record("pty spawn failed"); return }
            driver.expect("needletail> ", timeoutMS: 30_000)
            driver.send("parity probe\r")
            driver.expect("parity line one", timeoutMS: 20_000)
            driver.expect("parity line two", timeoutMS: 20_000)
            await Task.yield()
            let transcript = driver.fullTranscript()
            // Ordered containment of the hand-written semantic strings:
            // echoed probe, then the two answer lines.
            let marks = ["parity probe", "parity line one", "parity line two"]
            var cursor = transcript.startIndex
            for mark in marks {
                guard let range = transcript.range(of: mark, range: cursor..<transcript.endIndex) else {
                    Self.preserve("pty-parity", transcript: transcript)
                    Issue.record("parity mark missing in order: \(mark)")
                    return
                }
                cursor = range.upperBound
            }
            if server.requests.count != 1 {
                Self.preserve("pty-parity", transcript: transcript)
                Issue.record("parity scenario must dispatch exactly once, got \(server.requests.count)")
            }
            // Settle-then-exit via helper (readiness poll, no blind sleep).
            guard let status = await Self.settleThenExit(driver) else {
                Self.preserve("pty-parity", transcript: driver.fullTranscript())
                Issue.record("PTY parity release chat did not exit"); return
            }
            #expect(chatPTYCleanExit(status), "exit code 0, raw \(status)")
            #expect(driver.canonicalEchoRestored(), "terminal restored")
            let final = driver.fullTranscript()
            if let v = Self.allowlistViolation(final, "PTY-parity") {
                Self.preserve("pty-parity", transcript: final)
                Issue.record(Comment(rawValue: v))
            }
            if let b = Self.bearerViolation(server) { Issue.record("credential: \(b)") }
        }
    }
}


extension ChatPTYTests {
}
