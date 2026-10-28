import Testing
import Foundation
import Dispatch
import GRDB
import Crypto
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-C C3 (plan REV12 §6-§7): certifying binary scenarios through the real
/// `needletail run` product against a synthetic loopback provider —
/// temporary workspaces, owned child processes, real GRDB, PTY-mediated
/// operator approval. No live models, no network beyond loopback.
///
/// Every positive leg asserts durable agreement (intent + result +
/// artifacts match what the provider saw); every negative leg asserts a
/// typed, non-executing refusal with its durable trace.
@Suite(.serialized)
struct C3ExecQualificationTests {

    enum WiringError: Error {
        case missingBinary
        case childCrashed(Int32)
        case ptyFailed
        case unparseableStdout
    }

    // MARK: - Harness (mirrors the A5-1/B5-C binary seams)

    private static func binary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["NEEDLETAIL_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        var runner = URL(fileURLWithPath: CommandLine.arguments[0])
        if !runner.path.hasPrefix("/") {
            runner = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(CommandLine.arguments[0])
        }
        let sibling = runner.deletingLastPathComponent().appendingPathComponent("needletail").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        let fallback = root() + "/.build/debug/needletail"
        guard FileManager.default.isExecutableFile(atPath: fallback) else {
            Issue.record("needletail binary missing; build the product first")
            throw WiringError.missingBinary
        }
        return fallback
    }

    private static func root() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }

    private static func environment(stateDir: URL, extra: [String: String] = [:]) -> [String: String] {
        var env = hermeticChildEnvironment(ProcessInfo.processInfo.environment)
        env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
        env["NEEDLETAIL_STATE_DIR"] = stateDir.path
        for (k, v) in extra { env[k] = v }
        return env
    }

    private static func writeConfig(_ directory: URL, port: UInt16, exec: Any = "ask") throws -> String {
        let url = directory.appendingPathComponent("config.json")
        let config: [String: Any] = [
            "version": 1,
            "default_model": "loop",
            "allow_http_origins": ["http://127.0.0.1:\(port)"],
            "models": [[
                "alias": "loop",
                "protocol": "openai-chat-completions",
                "base_url": "http://127.0.0.1:\(port)",
                "model": "test-model",
                "context_window": 4096,
                "max_output": 128,
                "locality": "local",
                "credential": ["env": "NEEDLETAIL_LOOPBACK_TEST_KEY"],
                "connect_timeout_s": 5,
                "read_idle_timeout_s": 10,
                "request_timeout_s": 30,
                "max_in_flight": 1,
            ]],
            "tools": [
                "read": true, "search": true, "edit": true, "write": true,
                "exec": exec, "consult": true,
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    /// Final-only assistant text chunk.
    private static func finalText(_ text: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        var body = "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(encoded)},\"finish_reason\":null}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
        body += "data: [DONE]\n\n"
        return body
    }

    private static func toolCallChunk(callID: String, tool: String, arguments: String) -> String {
        let delta: [String: Any] = [
            "choices": [[
                "index": 0,
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": callID,
                    "function": ["name": tool, "arguments": arguments],
                ]]],
                "finish_reason": NSNull(),
            ]],
        ]
        let finish: [String: Any] = [
            "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]],
        ]
        let usage: [String: Any] = [
            "choices": [],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1],
        ]
        let dataJSON = { (object: [String: Any]) -> String in
            (try? String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)) ?? "{}"
        }
        return "data: " + dataJSON(delta) + "\n\n"
            + "data: " + dataJSON(finish) + "\n\n"
            + "data: " + dataJSON(usage) + "\n\n"
            + "data: [DONE]\n\n"
    }

    private static func jsonLines(_ stdout: String) throws -> [[String: Any]] {
        var envelopes: [[String: Any]] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                Issue.record("stdout must be pure JSONL; unparseable line: \(line.prefix(160))")
                throw WiringError.unparseableStdout
            }
            envelopes.append(object)
        }
        return envelopes
    }

    private static func freshDirectory(prefix: String = "needletail-c3") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Spawn with stdin+stderr on a fresh PTY slave (isatty passes); stdout
    /// stays a pipe (JSONL purity). Pre-buffered input by default; with
    /// delayInput the driver waits for the approval prompt first.
    private static func runWithPTY(
        _ arguments: [String], env: [String: String], input: String, delayInput: Bool = false,
        childPID: LockedBox<Int32>? = nil, expectSignal: Int32? = nil
    ) throws -> (exit: Int32, stdout: String, ptyOutput: String) {
        var master: Int32 = -1
        var slave: Int32 = -1
#if canImport(Glibc)
        guard Glibc.openpty(&master, &slave, nil, nil, nil) == 0 else { throw WiringError.ptyFailed }
#elseif canImport(Darwin)
        guard Darwin.openpty(&master, &slave, nil, nil, nil) == 0 else { throw WiringError.ptyFailed }
#endif
        let masterFD = master
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binary())
        process.arguments = arguments
        process.environment = env
        let stdinHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = stdinHandle
        process.standardError = stderrHandle
        let outPipe = Pipe()
        process.standardOutput = outPipe
        final class DataBox: @unchecked Sendable {
            private var value = Data()
            private let lock = NSLock()
            func append(_ bytes: Data) { lock.withLock { value.append(bytes) } }
            func snapshot() -> Data { lock.withLock { value } }
        }
        final class FlagBox: @unchecked Sendable {
            var done = false
            let lock = NSLock()
            func set() { lock.withLock { done = true } }
            func get() -> Bool { lock.withLock { done } }
        }
        let masterBox = DataBox()
        let doneFlag = FlagBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
#if canImport(Glibc)
                let ready = Glibc.poll(&pfd, 1, 100)
#elseif canImport(Darwin)
                let ready = Darwin.poll(&pfd, 1, 100)
#endif
                if ready > 0 {
                    let count = buf.withUnsafeMutableBytes { raw -> Int in
#if canImport(Glibc)
                        Glibc.read(masterFD, raw.baseAddress, 4096)
#elseif canImport(Darwin)
                        Darwin.read(masterFD, raw.baseAddress, 4096)
#endif
                    }
                    if count > 0 {
                        masterBox.append(Data(buf.prefix(count)))
                        continue
                    }
                    break
                }
                if doneFlag.get() { break }
            }
            group.leave()
        }
        try process.run()
        // Publish the child PID for tests that must signal the binary
        // (cancellation/crash legs). No /proc discovery races.
        childPID?.set(process.processIdentifier)
        try stdinHandle.close()
        if delayInput {
            let promptStop = Date().addingTimeInterval(30)
            var sawPrompt = false
            while Date() < promptStop {
                if String(data: masterBox.snapshot(), encoding: .utf8)?.contains("Approve and execute?") == true {
                    sawPrompt = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            #expect(sawPrompt, "approval prompt must render on the terminal")
            #expect(process.isRunning, "the run waits for the operator decision (no premature exit)")
            Thread.sleep(forTimeInterval: 1.0)
            #expect(process.isRunning, "still awaiting the decision after a beat")
        }
        let inputBytes = Array(input.utf8)
        _ = inputBytes.withUnsafeBufferPointer { buf in
            SIGPIPEGuard.install()
            return write(masterFD, buf.baseAddress, buf.count)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        doneFlag.set()
        group.wait()
#if canImport(Glibc)
        Glibc.close(masterFD)
#elseif canImport(Darwin)
        Darwin.close(masterFD)
#endif
        if process.terminationReason == .uncaughtSignal {
            // An expected test-injected signal (SIGKILL crash leg) is the
            // scenario, not a product crash.
            if let expected = expectSignal, process.terminationStatus == expected {
                let ptyText = String(data: masterBox.snapshot(), encoding: .utf8) ?? ""
                return (process.terminationStatus, String(decoding: outData, as: UTF8.self), ptyText)
            }
            Issue.record("child binary died from signal \(process.terminationStatus)")
            throw WiringError.childCrashed(process.terminationStatus)
        }
        let ptyText = String(data: masterBox.snapshot(), encoding: .utf8) ?? ""
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), ptyText)
    }

    /// Piped run (headless): stdin+stderr are pipes, never a TTY.
    private static func runPiped(_ arguments: [String], env: [String: String]) throws -> (exit: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binary())
        process.arguments = arguments
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = Pipe()
        try process.run()
        let group = DispatchGroup()
        final class DataBox: @unchecked Sendable { var value = Data() }
        let errBox = DataBox()
        group.enter()
        DispatchQueue.global().async {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            Issue.record("child binary died from signal \(process.terminationStatus)")
            throw WiringError.childCrashed(process.terminationStatus)
        }
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    private static func dbPath(in stateDir: URL) -> String {
        stateDir.appendingPathComponent("store.sqlite").path
    }

    private static func allRecords(dbPath: String, session: String) throws -> [DurableRecord] {
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        var out: [DurableRecord] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: SessionID(session), since: cursor, limit: 1000)
            out += page.map(\.record)
            guard let advanced = next else { break }
            cursor = advanced
        }
        return out
    }

    private static func sessions(dbPath: String) throws -> [String] {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session FROM records")
        }
    }
    // MARK: - Positive: read → edit → exec → continuation

    @Test("C3 binary: read → edit → exec → continuation runs once with durable agreement")
    func binaryReadEditExecContinuation() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            server.stop()
        }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "v1\n".write(to: ws.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let script = ws.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho PROOF-OUTPUT\ntouch \(ws.path)/SENTINEL\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let editArgs = "{\"path\":\"data.txt\",\"expectedHash\":\"\(Self.shaHex("v1\n"))\",\"old_string\":\"v1\\n\",\"new_string\":\"v2\\n\"}"
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "read", arguments: "{\"path\":\"data.txt\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c2", tool: "edit", arguments: editArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c3", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("all done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        // Two operator grants (edit, exec); read needs none.
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "do it", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\ny\n")
        #expect(result.exit == 0, "certifying run completes: \(result.stdout.prefix(500)) pty=\(result.ptyOutput.prefix(300))")
        // JSONL purity on stdout; approval prompts on the terminal.
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(envelopes.contains { ($0["kind"] as? String) == "run_finished" }, "terminal run_finished envelope")
        #expect(result.ptyOutput.contains("Approve and execute?"), "operator approval rendered on the terminal")
        #expect(result.ptyOutput.contains("run.sh"), "approval binds the resolved executable")
        // §10.4 banner on stderr (stdout stays JSONL-pure).
        // (Banner asserted via dedicated test below; PTY carries prompts here.)
        // Filesystem effects: exactly once each.
        #expect(try String(contentsOf: ws.appendingPathComponent("data.txt"), encoding: .utf8) == "v2\n")
        #expect(FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL").path), "exec ran once")
        // Provider continuation carries the preview after exec.
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.contains(where: { $0.contains("PROOF-OUTPUT") }), "provider saw the exec preview")
        // NC-9: the provider continuation also carries the exec receipt
        // (status, op ID, artifact, truncation) — not just the preview.
        #expect(bodies.contains(where: { $0.contains("stdout-artifact=") }), "provider saw the artifact reference")
        #expect(bodies.contains(where: { $0.contains("exec c3 success op=") }), "provider saw the exec receipt")
        // NC-9: the terminal/JSONL stream carries a per-exec receipt line.
        let toolExecEnvelopes = envelopes.filter { ($0["kind"] as? String) == "run:tool-exec" }
        #expect(toolExecEnvelopes.count == 1, "exactly one tool-exec receipt, got \(toolExecEnvelopes.count)")
        if let payload = toolExecEnvelopes.first?["payload"] as? String {
            #expect(payload.contains("c3") && payload.contains("success"), "receipt names the call and status: \(payload.prefix(200))")
            #expect(payload.contains("stdout-artifact="), "receipt references the artifact")
            #expect(!payload.contains("\u{1B}"), "receipt is terminal-sanitized")
        } else {
            Issue.record("tool-exec receipt has no string payload: \(toolExecEnvelopes)")
        }
        // Durable agreement in the production store.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        #expect(sessions.count == 1, "one run session, got \(sessions)")
        let session = try #require(sessions.first)
        let records = try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session)
        let intents = records.compactMap { r -> OperationRef? in
            if case .operationIntent(let ref) = r, ref.callID != nil { return ref }
            return nil
        }
        let results = records.compactMap { r -> (OperationRef, String)? in
            if case .operationResult(let ref, let outcome) = r { return (ref, outcome) }
            return nil
        }
        #expect(intents.map(\.callID) == ["c1", "c2", "c3"], "one durable intent per call, in order")
        let doneByCall = Dictionary(uniqueKeysWithValues: results.filter { $0.0.state == .done }.map { ($0.0.callID ?? "?", $0.1) })
        #expect(doneByCall["c3"]?.contains("exec succeeded") == true, "exec done receipt, got \(doneByCall)")
        let artifacts = records.compactMap { r -> ArtifactRef? in
            if case .artifactPublished(let ref) = r, ref.kind == "exec-output" { return ref }
            return nil
        }
        #expect(artifacts.count == 1, "exactly one exec-output artifact (stdout), got \(artifacts.count)")
        let store = try GRDBSessionStore(path: Self.dbPath(in: stateDir))
        defer { try? store.close() }
        let bytes = try store.readArtifact(artifacts[0])
        #expect(bytes == Data("PROOF-OUTPUT\n".utf8), "artifact bytes are the exact child output")
        // No unresolved holds on the clean path.
        let report = try store.reconcile(session: SessionID(session))
        #expect(report.heldOperations.isEmpty, "clean run holds nothing: \(report)")
    }

    private static func shaHex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("C3 binary: exec advertised only when granted and native-composed")
    func execAdvertisedOnlyWhenComposed() throws {
        // With --allow-exec: the first provider request carries an exec tool definition.
        do {
            let server = try LoopbackSSEServer()
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory); server.stop() }
            let ws = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            let config = try Self.writeConfig(directory, port: server.port)
            let result = try Self.runPiped(
                ["run", "--config", config, "--prompt", "hi", "--format", "jsonl", "--alias", "loop",
                 "--workspace", ws.path, "--allow-exec"],
                env: Self.environment(stateDir: directory.appendingPathComponent("state")))
            #expect(result.exit == 0, "run completes: \(result.stderr.prefix(300))")
            let firstBody = String(decoding: server.requests.first?.body ?? [], as: UTF8.self)
            #expect(firstBody.contains("\"exec\"") || firstBody.contains("exec"), "exec advertised when granted+composed, body=\(firstBody.prefix(400))")
        }
        // Without --allow-exec (denied caps): no exec definition offered.
        do {
            let server = try LoopbackSSEServer()
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory); server.stop() }
            let ws = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            let config = try Self.writeConfig(directory, port: server.port, exec: false)
            let result = try Self.runPiped(
                ["run", "--config", config, "--prompt", "hi", "--format", "jsonl", "--alias", "loop",
                 "--workspace", ws.path],
                env: Self.environment(stateDir: directory.appendingPathComponent("state")))
            #expect(result.exit == 0, "run completes: \(result.stderr.prefix(300))")
            let firstBody = String(decoding: server.requests.first?.body ?? [], as: UTF8.self)
            #expect(!firstBody.contains("\"name\":\"exec\""), "exec not advertised when denied, body=\(firstBody.prefix(400))")
        }
    }

    @Test("C3 binary: §10.4 banner present when native exec composes, absent otherwise")
    func execBannerPresentAndAbsent() throws {
        // Composed run: banner on stderr (stdout stays JSONL-pure).
        do {
            let server = try LoopbackSSEServer()
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory); server.stop() }
            let ws = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            let config = try Self.writeConfig(directory, port: server.port)
            let result = try Self.runPiped(
                ["run", "--config", config, "--prompt", "hi", "--format", "jsonl", "--alias", "loop",
                 "--workspace", ws.path, "--allow-exec"],
                env: Self.environment(stateDir: directory.appendingPathComponent("state")))
            _ = try Self.jsonLines(result.stdout)
            #expect(result.stderr.contains("not OS-isolated"), "banner warns on host execution, stderr=\(result.stderr.prefix(300))")
        }
        // Sealed run: no native exec, no banner.
        do {
            let server = try LoopbackSSEServer()
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory); server.stop() }
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            let config = try Self.writeConfig(directory, port: server.port)
            let result = try Self.runPiped(
                ["run", "--config", config, "--prompt", "hi", "--format", "jsonl", "--alias", "loop", "--sealed"],
                env: Self.environment(stateDir: directory.appendingPathComponent("state")))
            #expect(!result.stderr.contains("not OS-isolated"), "no banner without native exec")
        }
    }
    // MARK: - Negatives: refusals never execute

    @Test("C3 binary: unadvertised exec denied (call fails, run continues, nothing spawned)")
    func execDeniedWithoutAllowExec() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("nope.sh")
        try "#!/bin/sh\ntouch \(ws.path)/SENTINEL-DENIED\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
        // The model proposes exec even though it was never advertised; the
        // run refuses at the authorizer and exhausts the script (exit 4).
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port, exec: false)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runPiped(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "denial fails the call, the run continues: \(result.stderr.prefix(300))")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL-DENIED").path), "denied exec never spawns")
        // The denial is a durable deterministic transcript receipt (no
        // operation records: nothing was ever dispatched).
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        var sawDenial = false
        for session in sessions {
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .transcriptAppended(.toolResponse(let callID, let text)) = record, callID == "c1" {
                    #expect(text.contains("denied"), "denial receipt, got \(text)")
                    sawDenial = true
                }
                if case .operationIntent(let ref) = record, ref.callID != nil {
                    Issue.record("denied call must not commit an intent")
                }
                if case .artifactPublished = record {
                    Issue.record("no artifact may exist for a denied call")
                }
            }
        }
        #expect(sawDenial, "denial receipt committed")
        // NC-9: the denial is operator-visible in JSONL too.
        let deniedEnvelopes = try Self.jsonLines(result.stdout)
        #expect(deniedEnvelopes.contains(where: { ($0["kind"] as? String) == "run:tool-exec" }), "denial emits a tool-exec receipt")
    }

    @Test("C3 binary: headless approval-required exits 3 with nothing spawned")
    func execHeadlessExit3() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("gated.sh")
        try "#!/bin/sh\ntouch \(ws.path)/SENTINEL-HEADLESS\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        // Piped stdio: no TTY, no decision possible.
        let result = try Self.runPiped(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 3, "headless approval-required exits 3, got \(result.exit)")
        #expect(result.stderr.contains("approval required") || result.stdout.contains("approval_required"), "structured request: \(result.stderr.prefix(300))")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL-HEADLESS").path), "unapproved exec never spawns")
        // No exec intent was ever committed.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        for session in sessions {
            let records = try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session)
            #expect(!records.contains(where: {
                if case .operationIntent(let ref) = $0 { return ref.callID != nil }
                return false
            }), "no tool intent without approval")
        }
    }

    @Test("C3 binary: malformed argv is invalid-arguments, never spawned")
    func execMalformedArgvRejected() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("spoof.sh")
        try "#!/bin/sh\ntouch \(ws.path)/SENTINEL-SPOOF\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // argv[0] must equal executable: this proposal spoofs argv[0].
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"/bin/echo\",\"spoofed\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runPiped(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "malformed proposal fails the call, not the run: \(result.stderr.prefix(300))")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL-SPOOF").path), "spoofed argv never spawns")
        // NC-9: the pre-dispatch refusal is visible to the operator (JSONL)
        // and to the provider (transcript receipt), with the call identity.
        let envelopes = try Self.jsonLines(result.stdout)
        let toolExecDetails = envelopes.compactMap { $0["payload"] as? String }
            .filter { $0.contains("exec c1") }
        #expect(!toolExecDetails.isEmpty, "refusal receipt emitted, kinds=\(envelopes.compactMap { $0["kind"] as? String })")
        #expect(toolExecDetails.allSatisfy { !$0.contains("\u{1B}") }, "receipt sanitized")
        let bodies2 = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies2.contains(where: { $0.contains("preDispatch invalid-arguments") }), "provider saw the deterministic refusal")
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        var sawInvalid = false
        for session in sessions {
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .operationResult(_, let outcome) = record, outcome.contains("invalid-arguments") { sawInvalid = true }
            }
        }
        #expect(sawInvalid, "deterministic invalid-arguments receipt is durable")
    }

    @Test("C3 binary: substitution changes the approved digest between runs")
    func execSubstitutionChangesDigest() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("swap.sh")
        func runOnce(scriptBody: String, input: String) throws -> (exit: Int32, stdout: String, ptyOutput: String) {
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let server = try LoopbackSSEServer()
            let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let config = try Self.writeConfig(directory, port: server.port)
            return try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
                 "--workspace", ws.path, "--allow-exec"],
                env: Self.environment(stateDir: directory.appendingPathComponent("state")), input: input)
        }
        let first = try runOnce(scriptBody: "#!/bin/sh\necho A\n", input: "y\n")
        #expect(first.exit == 0, "first run executes: \(first.stdout.prefix(300))")
        let digestA = Self.approvalDigest(from: first.ptyOutput)
        let second = try runOnce(scriptBody: "#!/bin/sh\necho B-CHANGED\n", input: "y\n")
        #expect(second.exit == 0, "second run executes the new bytes: \(second.stdout.prefix(300))")
        let digestB = Self.approvalDigest(from: second.ptyOutput)
        #expect(!digestA.isEmpty && !digestB.isEmpty, "both approvals bind digests")
        #expect(digestA != digestB, "substitution changes the approved digest (no stale approval): \(digestA) vs \(digestB)")
    }

    /// Extracts the bound content digest from a rendered approval prompt.
    private static func approvalDigest(from pty: String) -> String {
        for line in pty.split(separator: "\n") {
            if line.contains("digest=") {
                let part = line.split(separator: " ").first(where: { $0.hasPrefix("digest=") }) ?? ""
                var d = String(part.dropFirst("digest=".count))
                if d.hasSuffix("…") { d = String(d.dropLast()) }
                return d
            }
        }
        return ""
    }

    @Test("C3 binary: operator deny stops the run with exit 3, nothing spawned")
    func execDeniedByOperator() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("denied.sh")
        try "#!/bin/sh\ntouch \(ws.path)/SENTINEL-DENY\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: directory.appendingPathComponent("state")), input: "n\n")
        #expect(result.exit == 3, "operator deny exits 3, got \(result.exit): \(result.stdout.prefix(300))")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL-DENY").path), "denied exec never spawns")
    }

    @Test("C3 binary: cwd escape is invalid-arguments, never spawned")
    func execCwdEscapeRejected() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("probe.sh")
        try "#!/bin/sh\ntouch \(outside.path)/SENTINEL-ESCAPE\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: ws.appendingPathComponent("escape"), withDestinationURL: outside)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"cwd\":\"escape\",\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runPiped(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "cwd escape fails the call, not the run: \(result.stderr.prefix(300))")
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("SENTINEL-ESCAPE").path), "escaped cwd never launches")
    }

    // MARK: - Negatives: child environment, launch, interruption, crash
    // MARK: - Negatives: child environment, launch, interruption, crash

    @Test("C3 binary: child inherits no parent secrets and no harness credentials")
    func execCredentialContaminationAbsent() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let execArgs = "{\"executable\":\"/usr/bin/env\",\"argv\":[\"/usr/bin/env\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        // The binary's own environment carries two secrets the child must
        // never observe: a test-injected parent secret and the loopback
        // credential the transport uses.
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir, extra: ["NT_CHILD_SECRET": "child-must-never-see-this"]),
            input: "y\n")
        #expect(result.exit == 0, "env dump completes: \(result.stdout.prefix(300))")
        #expect(!result.stdout.contains("child-must-never-see-this"), "parent secret absent from child env capture")
        #expect(!result.stdout.contains("loopback-test-secret"), "harness credential absent from child env capture")
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(!bodies.joined().contains("child-must-never-see-this"), "parent secret absent from provider traffic")
        #expect(!bodies.joined().contains("loopback-test-secret"), "harness credential absent from provider traffic")
        // And absent from the durable artifacts.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        let store = try GRDBSessionStore(path: Self.dbPath(in: stateDir))
        defer { try? store.close() }
        for session in sessions {
            var cursor: UInt64 = 0
            while true {
                let (page, next) = try store.records(session: SessionID(session), since: cursor, limit: 1000)
                for row in page {
                    if case .artifactPublished(let ref) = row.record {
                        let bytes = String(decoding: try store.readArtifact(ref), as: UTF8.self)
                        #expect(!bytes.contains("child-must-never-see-this"), "parent secret absent from artifacts")
                        #expect(!bytes.contains("loopback-test-secret"), "harness credential absent from artifacts")
                    }
                }
                guard let advanced = next else { break }
                cursor = advanced
            }
        }
    }

    @Test("C3 binary: credential overlay is refused with a receipt, never spawned")
    func execCredentialOverlayRefused() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        // The loopback credential name is a registered harness secret: a
        // model-authored overlay carrying it must be refused pre-dispatch.
        let execArgs = "{\"executable\":\"/bin/true\",\"argv\":[\"/bin/true\"],\"env\":{\"NEEDLETAIL_LOOPBACK_TEST_KEY\":\"x\"},\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "credential refusal fails the call, not the run: \(result.stdout.prefix(300))")
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(envelopes.contains(where: { ($0["kind"] as? String) == "run:tool-exec" }), "refusal emits a tool-exec receipt")
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.contains(where: { $0.contains("credential overlay") }), "provider saw the credential refusal")
    }

    @Test("C3 binary: launch failure is a deterministic receipt, never spawned")
    func execLaunchFailureDeterministic() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let execArgs = "{\"executable\":\"/nonexistent-c3-xyz\",\"argv\":[\"/nonexistent-c3-xyz\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "launch failure fails the call, not the run: \(result.stdout.prefix(300))")
        // The exec-error classification is durable and pre-dispatch.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        var sawFailed = false
        var sawArtifact = false
        for session in sessions {
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .operationResult(let ref, let outcome) = record, ref.callID == "c1" {
                    #expect(ref.state == .done, "impossible launch is deterministic, not unknown")
                    #expect(outcome.contains("failed"), "failed receipt, got \(outcome)")
                    sawFailed = true
                }
                if case .artifactPublished = record { sawArtifact = true }
            }
        }
        #expect(sawFailed, "launch-failure receipt committed")
        #expect(!sawArtifact, "no artifact without execution")
    }

    @Test("C3 binary: output-cap exhaustion truncates with exact discarded counts")
    func execOutputCapExhaustion() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let execArgs = "{\"executable\":\"/bin/sh\",\"argv\":[\"/bin/sh\",\"-c\",\"dd if=/dev/zero bs=1048576 count=40 2>/dev/null\"],\"timeoutSecs\":120}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "capped drain runs to completion: \(result.stdout.prefix(300))")
        let envelopes = try Self.jsonLines(result.stdout)
        // The tool-exec receipt envelope is present and parseable JSON.
        let toolExecKinds = envelopes.compactMap { $0["kind"] as? String }.filter { $0 == "run:tool-exec" }
        #expect(!toolExecKinds.isEmpty, "run:tool-exec receipt emitted")
        // Durable receipt carries truncation + discarded counts.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        var sawTruncation = false
        var sawArtifact = false
        let store = try GRDBSessionStore(path: Self.dbPath(in: stateDir))
        defer { try? store.close() }
        for session in sessions {
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .operationResult(let ref, let outcome) = record, ref.callID == "c1" {
                    if outcome.contains("stdout-discarded=8388608") { sawTruncation = true }
                }
                if case .artifactPublished(let ref) = record {
                    let bytes = try store.readArtifact(ref)
                    if bytes.count == 32 * 1024 * 1024 { sawArtifact = true }
                }
            }
        }
        #expect(sawTruncation, "exact discarded counts in the durable receipt")
        #expect(sawArtifact, "capped artifact committed")
    }

    @Test("C3 binary: terminal output cannot smuggle control bytes; JSONL stays parseable")
    func execTerminalControlSanitized() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("noisy.sh")
        try "#!/bin/sh\nprintf '\\033[2J\\033[HINJECTED\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":30}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "noisy output completes: \(result.stdout.prefix(300))")
        // Every stdout line parses as JSON (control bytes cannot break the
        // envelope framing), and no envelope carries a raw ESC byte.
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(!envelopes.isEmpty)
        #expect(!result.stdout.contains("\u{1B}"), "no raw escape bytes on stdout")
        // The exec receipt line in the JSONL stream is sanitized too.
        for envelope in envelopes {
            if let detail = envelope["payload"] as? String, envelope["kind"] as? String == "run:tool-exec" {
                #expect(!detail.contains("\u{1B}"), "receipt detail sanitized")
            }
        }
    }

    @Test("C3 binary: SIGINT mid-exec yields ambiguous hold (exit 4), never success")
    func execInterruptHolds() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let execArgs = "{\"executable\":\"/bin/sleep\",\"argv\":[\"/bin/sleep\",\"60\"],\"timeoutSecs\":120}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let outcomeBox = LockedBox<Int32>(-1)
        let ptyBox = LockedBox<String>("")
        let stdoutBox = LockedBox<String>("")
        let pidBox = LockedBox<Int32>(-1)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do {
                let result = try Self.runWithPTY(
                    ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
                     "--workspace", ws.path, "--allow-exec"],
                    env: Self.environment(stateDir: stateDir), input: "y\n", childPID: pidBox)
                ptyBox.set(result.stdout.suffix(2000).description + "\n---PTY---\n" + result.ptyOutput.suffix(2000).description)
                stdoutBox.set(result.stdout)
                outcomeBox.set(result.exit)
            } catch {
                outcomeBox.set(999)
            }
            group.leave()
        }
        // Synchronize on the durable dispatch intent (committed immediately
        // before spawn), not on /proc sightings: robust under load and
        // precise — the child may or may not have spawned yet, and either
        // way the verdict must be hold, never success.
        let sawIntent = Self.waitForIntent(dbPath: Self.dbPath(in: stateDir), timeout: 90)
        #expect(sawIntent, "intent committed before interruption")
        let binaryPID = pidBox.get()
        #expect(binaryPID > 0, "binary running for interruption")
        if binaryPID > 0 { kill(binaryPID, SIGINT) }
        group.wait()
        if outcomeBox.get() != 4 {
            print("C3DIAG exit=\(outcomeBox.get()) out=\(ptyBox.get().prefix(1500))")
        }
        #expect(outcomeBox.get() == 4, "interrupted exec holds ambiguous, got \(outcomeBox.get())")
        // NC-9: the hold is operator-visible in JSONL.
        let interruptEnvelopes = try Self.jsonLines(stdoutBox.get())
        #expect(interruptEnvelopes.contains(where: { ($0["kind"] as? String) == "run:tool-exec" }), "interrupted exec emits a tool-exec receipt")
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        let store = try GRDBSessionStore(path: Self.dbPath(in: stateDir))
        defer { try? store.close() }
        var held = false
        for session in sessions {
            let report = try store.reconcile(session: SessionID(session))
            if !report.heldOperations.isEmpty { held = true }
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .operationResult(let ref, _) = record, ref.callID == "c1" {
                    #expect(ref.state == .unknown, "interrupted exec is unknown, never done")
                }
            }
        }
        #expect(held, "interruption leaves an unresolved hold")
    }

    /// Waits for a callID-bearing operation intent in any session of the
    /// given store (the commit that immediately precedes spawn).
    private static func waitForIntent(dbPath: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sessions = try? Self.sessions(dbPath: dbPath) {
                for session in sessions {
                    if let records = try? Self.allRecords(dbPath: dbPath, session: session),
                       records.contains(where: {
                           if case .operationIntent(let ref) = $0 { return ref.callID != nil }
                           return false
                       }) {
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @Test("C3 binary: SIGINT while awaiting approval exits 130, nothing dispatched")
    func execInterruptWhileAuthorisingGives130() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let script = ws.appendingPathComponent("never.sh")
        try "#!/bin/sh\ntouch \(ws.path)/SENTINEL-INT\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let execArgs = "{\"executable\":\"\(script.path)\",\"argv\":[\"\(script.path)\"],\"timeoutSecs\":120}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let outcomeBox = LockedBox<Int32>(-1)
        let pidBox = LockedBox<Int32>(-1)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do {
                // No input: the run waits at the approval prompt.
                let result = try Self.runWithPTY(
                    ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
                     "--workspace", ws.path, "--allow-exec"],
                    env: Self.environment(stateDir: stateDir), input: "", delayInput: true, childPID: pidBox)
                outcomeBox.set(result.exit)
            } catch {
                outcomeBox.set(999)
            }
            group.leave()
        }
        // Wait until the binary is parked at the approval prompt, then SIGINT.
        let deadline = Date().addingTimeInterval(60)
        var binaryPID: Int32 = -1
        while Date() < deadline {
            let candidate = pidBox.get()
            if candidate > 0 { binaryPID = candidate; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        #expect(binaryPID > 0, "binary parked at approval")
        guard binaryPID > 0 else {
            group.wait()
            return
        }
        Thread.sleep(forTimeInterval: 2.0)
        kill(binaryPID, SIGINT)
        group.wait()
        #expect(outcomeBox.get() == 130, "interrupt with nothing dispatched exits 130, got \(outcomeBox.get())")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("SENTINEL-INT").path), "nothing dispatched before interrupt")
    }

    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()
        init(_ value: T) { self.value = value }
        func set(_ v: T) { lock.withLock { value = v } }
        func get() -> T { lock.withLock { value } }
    }

    @Test("C3 binary: divergent access — exec reads what native read denies (not OS-isolated)")
    func execDivergentAccess() throws {
        let server = try LoopbackSSEServer()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory); server.stop() }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        // A file outside the workspace: native `read` denies absolute paths.
        let outside = directory.appendingPathComponent("outside.txt")
        try "DIVERGENT-SECRET\n".write(to: outside, atomically: true, encoding: .utf8)
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "read", arguments: "{\"path\":\"\(outside.path)\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c2", tool: "exec", arguments: "{\"executable\":\"/bin/cat\",\"argv\":[\"/bin/cat\",\"\(outside.path)\"],\"timeoutSecs\":30}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        let config = try Self.writeConfig(directory, port: server.port)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "run completes: \(result.stdout.prefix(300))")
        // The native read refuses the absolute path; the approved exec
        // reads the same bytes. This asymmetry is exactly what the §10.4
        // banner warns about (host execution is not OS-isolated).
        #expect(result.ptyOutput.contains("not OS-isolated"), "banner present on composed run")
        let bodies = server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.contains(where: { $0.contains("DIVERGENT-SECRET") }), "exec read the outside file")
        // The native read refused the same path: denial recorded, nothing read.
        let sessions = try Self.sessions(dbPath: Self.dbPath(in: stateDir))
        var sawReadDenial = false
        for session in sessions {
            for record in try Self.allRecords(dbPath: Self.dbPath(in: stateDir), session: session) {
                if case .operationResult(let ref, let outcome) = record, ref.callID == "c1" {
                    #expect(outcome.contains("denied") || outcome.contains("invalid-arguments"), "read denial recorded, got \(outcome)")
                    sawReadDenial = true
                }
            }
        }
        #expect(sawReadDenial, "native read denial is durable")
    }

    @Test("C3 binary: crash mid-exec leaves a hold that blocks the next run")
    func execCrashReopenHolds() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ws = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let stateDir = directory.appendingPathComponent("state")
        let server = try LoopbackSSEServer()
        let execArgs = "{\"executable\":\"/bin/sleep\",\"argv\":[\"/bin/sleep\",\"60\"],\"timeoutSecs\":120}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "exec", arguments: execArgs).utf8))]))
        server.start()
        defer { server.stop() }
        let config = try Self.writeConfig(directory, port: server.port)
        // Drive the binary in a thread: approve, wait for the dispatch
        // intent, then SIGKILL the binary mid-exec (intent committed, no
        // result). PID comes from our own spawn handle — no /proc races.
        let pidBox = LockedBox<Int32>(-1)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = try? Self.runWithPTY(
                ["run", "--config", config, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
                 "--workspace", ws.path, "--allow-exec"],
                env: Self.environment(stateDir: stateDir), input: "y\n", childPID: pidBox,
                expectSignal: SIGKILL)
            group.leave()
        }
        let sawIntent = Self.waitForIntent(dbPath: Self.dbPath(in: stateDir), timeout: 90)
        #expect(sawIntent, "intent committed before the kill")
        let binaryPID = pidBox.get()
        #expect(binaryPID > 0, "binary running for the kill")
        if binaryPID > 0 { kill(binaryPID, SIGKILL) }
        group.wait()
        // A fresh run against the same state dir must trip the cross-run
        // gate (exit 3, blocked) rather than silently continue past the
        // unresolved mutating intent.
        let server2 = try LoopbackSSEServer()
        server2.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server2.start()
        defer { server2.stop() }
        let config2 = try Self.writeConfig(directory, port: server2.port)
        let result = try Self.runPiped(
            ["run", "--config", config2, "--prompt", "go", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws.path, "--allow-exec"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 3, "reopen trips the cross-run gate, got \(result.exit): \(result.stderr.prefix(300))")
        #expect(result.stderr.contains("blocked"), "gate explains the block: \(result.stderr.prefix(300))")
    }
}
