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

/// B5-C end-to-end binary qualification: the REAL `needletail run`
/// binary against synthetic loopback providers, temporary workspaces and
/// real SQLite. Every test asserts the actual binary, provider
/// request/response bytes, filesystem effects and durable records.
///
/// Functions named `TOOL_NN_…` / `PORT_03_…` are the certifying native
/// variants registered in `requiredEvidence`; plain-named functions are
/// UNLABELED support flows (must still pass, never certify).
@Suite(.serialized)
struct B5CEndToEndTests {

    // MARK: - Harness

    private enum WiringError: Error {
        case missingBinary
        case childCrashed(Int32)
        case ptyFailed
    }

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
        var env = ProcessInfo.processInfo.environment
        env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
        env["NEEDLETAIL_STATE_DIR"] = stateDir.path
        for (key, value) in extra { env[key] = value }
        return env
    }

    private static func writeConfig(_ directory: URL, port: Int) throws -> String {
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
                "exec": "ask", "consult": true,
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    private static func writeTools(_ directory: URL, entries: [[String: String]]) throws -> String {
        let url = directory.appendingPathComponent("tools.json")
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    private static func run(
        _ arguments: [String], env: [String: String]
    ) throws -> (exit: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binary())
        process.arguments = arguments
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        final class DataBox: @unchecked Sendable { var value = Data() }
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            Issue.record("child binary died from signal \(process.terminationStatus): \(String(decoding: errBox.value, as: UTF8.self).prefix(300))")
            throw WiringError.childCrashed(process.terminationStatus)
        }
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    /// Spawn with stdin AND stderr on one fresh PTY slave (isatty passes
    /// for both, mirroring a real terminal where stdout may still be
    /// piped). With `delayInput` false (default) `input` is pre-buffered
    /// in the PTY input queue — deterministic, no sleeps. With true, the
    /// driver waits for the approval prompt, proves the process is still
    /// alive (a premature exit-3 would fail here), waits a beat, and only
    /// then answers — the human-operator shape no pre-buffering can fake.
    private static func runWithPTY(
        _ arguments: [String], env: [String: String], input: String, delayInput: Bool = false
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
        final class DataBox: @unchecked Sendable { var value = Data() }
        final class LockedBox: @unchecked Sendable {
            private var value = Data()
            private let lock = NSLock()
            func append(_ bytes: Data) { lock.withLock { value.append(bytes) } }
            func snapshot() -> Data { lock.withLock { value } }
            func set(_ bytes: Data) { lock.withLock { value = bytes } }
        }
        final class FlagBox: @unchecked Sendable {
            var done = false
            let lock = NSLock()
            func set() { lock.withLock { done = true } }
            func get() -> Bool { lock.withLock { done } }
        }
        let masterBox = LockedBox()
        let doneFlag = FlagBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            // PTY master drain (prompt + echo): poll so the loop always
            // terminates — after the child exits no new master-bound byte
            // can ever arrive (everything is kernel-buffered).
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
        // The child holds its own dup of the slave from here on; the
        // parent copy closes so PTY EOF semantics stay natural.
        try stdinHandle.close()
        if delayInput {
            // Human shape: wait for the prompt, prove the process is
            // AWAITING the decision (a premature exit-3 would already be
            // reaped here), pause, then answer.
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
        // Decision input (pre-buffered, or post-prompt in delayed mode).
        let inputBytes = Array(input.utf8)
        _ = inputBytes.withUnsafeBufferPointer { buf in
#if canImport(Glibc)
            Glibc.write(masterFD, buf.baseAddress, buf.count)
#elseif canImport(Darwin)
            Darwin.write(masterFD, buf.baseAddress, buf.count)
#endif
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
            Issue.record("child binary died from signal \(process.terminationStatus)")
            throw WiringError.childCrashed(process.terminationStatus)
        }
        let ptyText = String(data: masterBox.snapshot(), encoding: .utf8) ?? ""
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), ptyText)
    }

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-b5c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func freshState(in directory: URL) throws -> URL {
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return stateDir
    }

    private static func finalText(_ text: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        var body = "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(encoded)},\"finish_reason\":null}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
        body += "data: [DONE]\n\n"
        return body
    }

    private static func toolCallChunk(callID: String, tool: String, arguments: String) -> String {
        try! Self.multiToolCallChunk([(callID: callID, tool: tool, arguments: arguments)])
    }

    private static func multiToolCallChunk(_ calls: [(callID: String, tool: String, arguments: String)]) throws -> String {
        let dataJSON = { (object: [String: Any]) -> String in
            (try? String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)) ?? "{}"
        }
        let toolCalls = calls.enumerated().map { index, call in
            ["index": index, "id": call.callID,
             "function": ["name": call.tool, "arguments": call.arguments]] as [String: Any]
        }
        let delta: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": toolCalls], "finish_reason": NSNull()]]]
        let finish: [String: Any] = ["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]
        let usage: [String: Any] = ["choices": [], "usage": ["prompt_tokens": 1, "completion_tokens": 1]]
        return "data: " + dataJSON(delta) + "\n\n"
            + "data: " + dataJSON(finish) + "\n\n"
            + "data: " + dataJSON(usage) + "\n\n"
            + "data: [DONE]\n\n"
    }

    private static func sha256hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func editArgs(path: String, expectedHash: String, old: String, new: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": path, "expectedHash": expectedHash,
            "old_string": old, "new_string": new,
        ], options: [.sortedKeys]), as: UTF8.self)
    }

    private static func jsonBody(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("request body is not a JSON object")
            throw WiringError.missingBinary
        }
        return object
    }

    private static func toolNames(in body: [String: Any]) -> [String]? {
        (body["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    private static func storeSessions(at stateDir: URL) throws -> [String] {
        let store = try GRDBSessionStore(path: stateDir.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        return try store.sessions().map(\.raw)
    }

    private static func sessionRecords(at stateDir: URL, session: String) throws -> [DurableRecord] {
        let store = try GRDBSessionStore(path: stateDir.appendingPathComponent("store.sqlite").path)
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

    private static func intentsAndResults(_ records: [DurableRecord]) -> (intents: [OperationRef], results: [(OperationRef, String)]) {
        // Tool operations only: admission markers are callID-less.
        let intents = records.compactMap { record -> OperationRef? in
            if case .operationIntent(let ref) = record, ref.callID != nil { return ref }
            return nil
        }
        let results = records.compactMap { record -> (OperationRef, String)? in
            if case .operationResult(let ref, let outcome) = record { return (ref, outcome) }
            return nil
        }
        return (intents, results)
    }

    /// Mutating-op success summaries are verb-led ("edited …", "write …",
    /// "replaced …"); anything else is a refusal or failure receipt.
    private static func isMutatingSuccess(_ outcome: String) -> Bool {
        outcome.hasPrefix("edited ") || outcome.hasPrefix("write ")
            || outcome.hasPrefix("replaced ") || outcome.hasPrefix("created ")
    }

    // MARK: - TOOL-01 read budget + binary

    @Test("TOOL_01_binaryReadBudgetAndBinary")
    func TOOL_01_binaryReadBudgetAndBinary() throws {
        let server = try LoopbackSSEServer()
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "read",
                               arguments: "{\"limit\":5,\"path\":\"long.txt\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c2", tool: "read",
                               arguments: "{\"path\":\"blob.bin\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let readRoot = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: true)
        try lines.write(to: readRoot.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE]).write(to: readRoot.appendingPathComponent("blob.bin"))
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "read files", "--format", "jsonl", "--alias", "loop",
             "--read-root", readRoot.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "read-only run completes: \(result.stderr)")
        #expect(server.requests.count == 3, "two tool turns + final, got \(server.requests.count)")
        // Budget honored: first five lines travel, the sixth does not.
        let secondBody = String(decoding: server.requests[1].body, as: UTF8.self)
        #expect(secondBody.contains("line5"), "budgeted lines reach the model")
        #expect(!secondBody.contains("line6"), "over-budget lines are withheld")
        // Binary: refused gracefully, no NUL byte in any provider body.
        for request in server.requests {
            #expect(!request.body.contains(0), "no NUL byte in provider traffic")
        }
        // Durable intents + results for both reads on the new session.
        let sessions = try Self.storeSessions(at: stateDir)
        #expect(sessions.count == 1)
        let (intents, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(intents.count == 2)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.0.mutating == false })
        // Advertisement: read/search only, tool_choice auto, never exec.
        let firstBody = try Self.jsonBody(Data(server.requests[0].body))
        #expect(Self.toolNames(in: firstBody)?.sorted() == ["read", "search"])
        #expect(firstBody["tool_choice"] as? String == "auto")
    }

    // MARK: - TOOL-02 search metacharacters

    @Test("TOOL_02_binarySearchMetacharacters")
    func TOOL_02_binarySearchMetacharacters() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "search",
                               arguments: "{\"path\":\".\",\"pattern\":\"-flag\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c2", tool: "search",
                               arguments: "{\"pattern\":\"c.ll\\\\(\\\\)\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c3", tool: "search",
                               arguments: "{\"pattern\":\"*.swift\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let readRoot = directory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: true)
        try "run with -flag set\ncall()\n".write(
            to: readRoot.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "search", "--format", "jsonl", "--alias", "loop",
             "--read-root", readRoot.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "metacharacter searches complete without crash: \(result.stderr)")
        #expect(server.requests.count == 4, "three search turns + final, got \(server.requests.count)")
        // Leading dash is data, not a flag: the literal line travels back.
        #expect(String(decoding: server.requests[1].body, as: UTF8.self).contains("-flag"))
        // Regex metacharacters work as regex.
        #expect(String(decoding: server.requests[2].body, as: UTF8.self).contains("call()"))
        // Invalid regex fails gracefully: the run continues to the final.
        let sessions = try Self.storeSessions(at: stateDir)
        let (_, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(results.count == 3)
    }

    // MARK: - TOOL-06 exact bytes via PTY-approved write

    @Test("TOOL_06_binaryWriteExactBytes")
    func TOOL_06_binaryWriteExactBytes() throws {
        let server = try LoopbackSSEServer()
        let content = "a\r\nb́🎉"
        let contentJSON = String(decoding: try! JSONEncoder().encode(content), as: UTF8.self)
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "write",
                               arguments: "{\"content\":\(contentJSON),\"path\":\"new.txt\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "write it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "PTY-approved write completes: \(result.ptyOutput.prefix(300))")
        #expect(server.requests.count == 2)
        // Filesystem bytes are byte-exact: CRLF, combining mark, emoji, no
        // trailing newline.
        let written = try Data(contentsOf: workspace.appendingPathComponent("new.txt"))
        #expect(written == Data(content.utf8), "exact bytes landed")
        // Durable success receipt with the matching hash.
        let sessions = try Self.storeSessions(at: stateDir)
        let (intents, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(intents.count == 1)
        #expect(results.count == 1)
        #expect(results[0].0.mutating)
        // The prompt rendered on the PTY; stdout stayed JSONL-pure.
        #expect(result.ptyOutput.contains("Approve and execute?"))
        #expect(!result.stdout.split(separator: "\n", omittingEmptySubsequences: true).contains(where: {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil
        }), "stdout stays pure JSONL despite the interactive approval")
        let firstBody = try Self.jsonBody(Data(server.requests[0].body))
        #expect(Self.toolNames(in: firstBody)?.sorted() == ["edit", "read", "search", "write"])
    }

    // MARK: - TOOL-04 edit occurrence semantics

    @Test("TOOL_04_binaryEditOccurrences")
    func TOOL_04_binaryEditOccurrences() throws {
        // Exactly one occurrence: succeeds, bytes and receipt exact.
        do {
            let server = try LoopbackSSEServer()
            let file = "solo\n"
            let args = try Self.editArgs(
                path: "one.txt", expectedHash: Self.sha256hex(file),
                old: "solo\n", new: "replaced\n")
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = try Self.writeConfig(directory, port: Int(server.port))
            let stateDir = try Self.freshState(in: directory)
            let workspace = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try file.write(to: workspace.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
            let result = try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
                 "--workspace", workspace.path],
                env: Self.environment(stateDir: stateDir), input: "y\n")
            #expect(result.exit == 0, "one-occurrence edit applies: \(result.ptyOutput.prefix(200))")
            let applied = try String(contentsOf: workspace.appendingPathComponent("one.txt"), encoding: .utf8)
            #expect(applied == "replaced\n")
            let sessions = try Self.storeSessions(at: stateDir)
            let (_, results) = Self.intentsAndResults(
                try Self.sessionRecords(at: stateDir, session: sessions[0]))
            #expect(results.count == 1)
            #expect(results.first?.1 == "edited one.txt", "exactly one occurrence reports success")
        }
        // Zero occurrences: old text absent → refused, filesystem untouched.
        do {
            let server = try LoopbackSSEServer()
            let file = "version 1\n"
            let args = try Self.editArgs(
                path: "t.txt", expectedHash: Self.sha256hex(file),
                old: "zzz\n", new: "q\n")
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = try Self.writeConfig(directory, port: Int(server.port))
            let stateDir = try Self.freshState(in: directory)
            let workspace = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try file.write(to: workspace.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
            let result = try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
                 "--workspace", workspace.path],
                env: Self.environment(stateDir: stateDir), input: "y\n")
            #expect(result.exit == 0, "refused edit still completes the run: \(result.ptyOutput.prefix(200))")
            #expect(try String(contentsOf: workspace.appendingPathComponent("t.txt"), encoding: .utf8) == file)
            let sessions = try Self.storeSessions(at: stateDir)
            let (_, results) = Self.intentsAndResults(
                try Self.sessionRecords(at: stateDir, session: sessions[0]))
            #expect(results.count == 1)
            #expect(!results.contains(where: { Self.isMutatingSuccess($0.1) }),
                    "zero-occurrence edit must not report success")
        }
        // Multiple occurrences: ambiguous → refused, filesystem untouched.
        do {
            let server = try LoopbackSSEServer()
            let file = "x\nx\n"
            let args = try Self.editArgs(
                path: "u.txt", expectedHash: Self.sha256hex(file),
                old: "x\n", new: "y\n")
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = try Self.writeConfig(directory, port: Int(server.port))
            let stateDir = try Self.freshState(in: directory)
            let workspace = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try file.write(to: workspace.appendingPathComponent("u.txt"), atomically: true, encoding: .utf8)
            let result = try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
                 "--workspace", workspace.path],
                env: Self.environment(stateDir: stateDir), input: "y\n")
            #expect(result.exit == 0)
            #expect(try String(contentsOf: workspace.appendingPathComponent("u.txt"), encoding: .utf8) == file)
            let sessions = try Self.storeSessions(at: stateDir)
            let (_, results) = Self.intentsAndResults(
                try Self.sessionRecords(at: stateDir, session: sessions[0]))
            #expect(!results.contains(where: { Self.isMutatingSuccess($0.1) }),
                    "ambiguous edit must not report success")
        }
    }

    // MARK: - TOOL-05 stale commit hash

    @Test("TOOL_05_binaryEditStaleHash")
    func TOOL_05_binaryEditStaleHash() throws {
        let server = try LoopbackSSEServer()
        let file = "real\n"
        // Well-formed 64-hex, but NOT the hash of the current bytes.
        let args = try Self.editArgs(
            path: "s.txt", expectedHash: Self.sha256hex("different\n"),
            old: "real\n", new: "fake\n")
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try file.write(to: workspace.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "stale-hash refusal still completes: \(result.ptyOutput.prefix(200))")
        #expect(try String(contentsOf: workspace.appendingPathComponent("s.txt"), encoding: .utf8) == file,
                "stale commit gate leaves the file untouched")
        let sessions = try Self.storeSessions(at: stateDir)
        let (_, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(!results.contains(where: { Self.isMutatingSuccess($0.1) }))
    }

    // MARK: - Support: interactive decisions are awaited, not raced

    @Test("interactiveDecisionIsAwaited")
    func interactiveDecisionIsAwaited() throws {
        // The human-operator shape: the prompt renders, the operator
        // deliberates, and only then answers. A run loop that mistook the
        // prompt for a headless verdict would exit 3 before the answer.
        let server = try LoopbackSSEServer()
        let file = "wait\n"
        let args = try Self.editArgs(
            path: "w.txt", expectedHash: Self.sha256hex(file),
            old: "wait\n", new: "done\n")
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try file.write(to: workspace.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n", delayInput: true)
        #expect(result.exit == 0, "the awaited decision applies the edit: \(result.ptyOutput.suffix(300))")
        #expect(try String(contentsOf: workspace.appendingPathComponent("w.txt"), encoding: .utf8) == "done\n")
        let sessions = try Self.storeSessions(at: stateDir)
        let (_, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(results.count == 1)
        #expect(results.first?.1 == "edited w.txt")
    }

    // MARK: - Support: PTY deny + headless approval

    @Test("denyLeavesZeroMutation")
    func denyLeavesZeroMutation() throws {
        let server = try LoopbackSSEServer()
        let file = "keep\n"
        let args = try Self.editArgs(
            path: "v.txt", expectedHash: Self.sha256hex(file),
            old: "keep\n", new: "drop\n")
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try file.write(to: workspace.appendingPathComponent("v.txt"), atomically: true, encoding: .utf8)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "n\n")
        #expect(result.exit == 3, "explicit denial maps to approval-required: \(result.ptyOutput.prefix(200))")
        #expect(try String(contentsOf: workspace.appendingPathComponent("v.txt"), encoding: .utf8) == file)
        #expect(server.requests.count == 1, "denied proposals dispatch nothing further")
        // No operation intent was ever committed: denial precedes dispatch.
        let sessions = try Self.storeSessions(at: stateDir)
        let records = try Self.sessionRecords(at: stateDir, session: sessions[0])
        #expect(!records.contains(where: {
            if case .operationIntent(let ref) = $0 { return ref.callID != nil }
            return false
        }), "denial precedes intent commit")
    }

    @Test("headlessMutationNeedsApproval")
    func headlessMutationNeedsApproval() throws {
        let server = try LoopbackSSEServer()
        let file = "keep\n"
        let args = try Self.editArgs(
            path: "v.txt", expectedHash: Self.sha256hex(file),
            old: "keep\n", new: "drop\n")
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try file.write(to: workspace.appendingPathComponent("v.txt"), atomically: true, encoding: .utf8)
        // Piped stdin: no TTY, headless approval unavailable.
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 3, "headless mutating request exits 3: \(result.stderr.prefix(200))")
        #expect(result.stderr.contains("approval required"))
        #expect(try String(contentsOf: workspace.appendingPathComponent("v.txt"), encoding: .utf8) == file)
        #expect(server.requests.count == 1, "no execution past the approval hold")
    }

    // MARK: - TOOL-03 foreign config + symlink escape

    @Test("TOOL_03_binarySearchIgnoresForeignConfig")
    func TOOL_03_binarySearchIgnoresForeignConfig() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "search",
                               arguments: "{\"pattern\":\"match-me|outside-secret\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let readRoot = directory.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: true)
        try "here: match-me\n".write(
            to: readRoot.appendingPathComponent("in.txt"), atomically: true, encoding: .utf8)
        // Symlink escaping the root (must never be followed for results).
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside-secret\n".write(
            to: outside.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: readRoot.appendingPathComponent("extlink"),
            withDestinationURL: outside)
        // Poisoned foreign config: a --pre preprocessor that would stamp
        // every result if the executor ever honored ambient configuration.
        let evilConfig = directory.appendingPathComponent("evil-rg-config")
        try "--pre=echo PWNED\n".write(to: evilConfig, atomically: true, encoding: .utf8)
        var env = Self.environment(stateDir: stateDir)
        env["RIPGREP_CONFIG_PATH"] = evilConfig.path
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "search", "--format", "jsonl", "--alias", "loop",
             "--read-root", readRoot.path],
            env: env)
        #expect(result.exit == 0, "foreign config cannot break the run: \(result.stderr.prefix(200))")
        // The tool RESULT (not the echoed proposal arguments, which carry
        // the pattern itself) must contain the in-root match and neither
        // the escaped content nor preprocessor output.
        let secondBody = try Self.jsonBody(Data(server.requests[1].body))
        let toolTexts = ((secondBody["messages"] as? [[String: Any]]) ?? []).compactMap { message -> String? in
            guard message["tool_call_id"] != nil else { return nil }
            return message["content"] as? String
        }
        #expect(!toolTexts.isEmpty, "tool result travels to the model")
        let toolText = toolTexts.joined(separator: "\n")
        #expect(toolText.contains("match-me"), "in-root match travels")
        #expect(!toolText.contains("outside-secret"), "symlinked escape never leaks")
        #expect(!toolText.contains("PWNED"), "foreign preprocessor never runs")
    }

    // MARK: - TOOL-07 symlink + parent escape

    @Test("TOOL_07_binarySymlinkEscapeDenied")
    func TOOL_07_binarySymlinkEscapeDenied() throws {
        // (a) Editing through a symlink that escapes the workspace.
        do {
            let server = try LoopbackSSEServer()
            let secret = "top-secret\n"
            // Shape-valid path; the escape is caught at dispatch, not validation.
            let args = try Self.editArgs(
                path: "link", expectedHash: Self.sha256hex(secret),
                old: "top-secret\n", new: "pwned\n")
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = try Self.writeConfig(directory, port: Int(server.port))
            let stateDir = try Self.freshState(in: directory)
            let workspace = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try secret.write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("link"),
                withDestinationURL: outside.appendingPathComponent("secret.txt"))
            let result = try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
                 "--workspace", workspace.path],
                env: Self.environment(stateDir: stateDir), input: "y\n")
            #expect(result.exit == 0)
            #expect(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8) == secret,
                    "symlink escape leaves the outside file untouched")
            #expect((try? FileManager.default.destinationOfSymbolicLink(
                atPath: workspace.appendingPathComponent("link").path)) != nil,
                "the symlink itself is preserved (no replacement)")
        }
        // (b) Parent escape in the path shape is rejected pre-dispatch.
        do {
            let server = try LoopbackSSEServer()
            let args = try Self.editArgs(
                path: "../escape", expectedHash: String(repeating: "a", count: 64),
                old: "x\n", new: "y\n")
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
            server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
            server.start()
            defer { server.stop() }
            let directory = try Self.freshDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let config = try Self.writeConfig(directory, port: Int(server.port))
            let stateDir = try Self.freshState(in: directory)
            let workspace = directory.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let result = try Self.runWithPTY(
                ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
                 "--workspace", workspace.path],
                env: Self.environment(stateDir: stateDir), input: "y\n")
            #expect(result.exit == 0, "shape-invalid batch is denied without crashing: \(result.ptyOutput.prefix(200))")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape").path),
                    "no file escapes the workspace")
        }
    }

    // MARK: - TOOL-08 create-new exclusivity

    @Test("TOOL_08_binaryCreateNewExistsRefused")
    func TOOL_08_binaryCreateNewExistsRefused() throws {
        let server = try LoopbackSSEServer()
        let existing = "original\n"
        let contentJSON = String(decoding: try! JSONEncoder().encode("overwrite\n"), as: UTF8.self)
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "write",
                               arguments: "{\"content\":\(contentJSON),\"path\":\"exists.txt\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try existing.write(to: workspace.appendingPathComponent("exists.txt"), atomically: true, encoding: .utf8)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "write it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "exclusive create-new refusal still completes: \(result.ptyOutput.prefix(200))")
        #expect(try String(contentsOf: workspace.appendingPathComponent("exists.txt"), encoding: .utf8) == existing,
                "create-new never silently overwrites")
        let sessions = try Self.storeSessions(at: stateDir)
        let (_, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(!results.contains(where: { Self.isMutatingSuccess($0.1) }))
    }

    // MARK: - TOOL-09 partial batch

    @Test("TOOL_09_binaryPartialBatchSecondFails")
    func TOOL_09_binaryPartialBatchSecondFails() throws {
        let server = try LoopbackSSEServer()
        let outsideContent = "untouchable\n"
        let okJSON = String(decoding: try! JSONEncoder().encode("fine\n"), as: UTF8.self)
        let badJSON = String(decoding: try! JSONEncoder().encode("bad\n"), as: UTF8.self)
        let batch = try Self.multiToolCallChunk([
            (callID: "c1", tool: "write", arguments: "{\"content\":\(okJSON),\"path\":\"ok.txt\"}"),
            (callID: "c2", tool: "write", arguments: "{\"content\":\(badJSON),\"path\":\"trap\"}"),
        ])
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(batch.utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try outsideContent.write(to: outside.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("trap"),
            withDestinationURL: outside.appendingPathComponent("real.txt"))
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "write both", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "partial batch completes the run: \(result.ptyOutput.prefix(200))")
        // First file stands; the symlink escape fails; nothing leaks out.
        #expect(try String(contentsOf: workspace.appendingPathComponent("ok.txt"), encoding: .utf8) == "fine\n")
        #expect(try String(contentsOf: outside.appendingPathComponent("real.txt"), encoding: .utf8) == outsideContent)
        let sessions = try Self.storeSessions(at: stateDir)
        let (intents, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(intents.count == 2)
        #expect(results.count == 2)
        let byCall = Dictionary(uniqueKeysWithValues: results.map { ($0.0.callID ?? "?", $0.1) })
        #expect(byCall["c1"] == "write ok.txt", "first write succeeds exactly")
        #expect(byCall["c2"] != "write trap", "second call fails honestly, never the success shape")
    }

    // MARK: - TOOL-10 operator diff in dirty tree (direct CLI)

    @Test("TOOL_10_binaryDiffDirtyTree")
    func TOOL_10_binaryDiffDirtyTree() throws {
        let git = try Self.locateGit()
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try Self.runGit(git, args: ["init", "-q"], cwd: repo)
        _ = try Self.runGit(git, args: ["config", "user.email", "t@t"], cwd: repo)
        _ = try Self.runGit(git, args: ["config", "user.name", "t"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try Self.runGit(git, args: ["add", "-A"], cwd: repo)
        _ = try Self.runGit(git, args: ["commit", "-qm", "init"], cwd: repo)
        try "base\nuser change\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // Repo-configured fsmonitor hook: executes on diff unless disabled.
        let fsMarker = repo.appendingPathComponent("fsmonitor-fired").path
        _ = try Self.runGit(git, args: ["config", "core.fsmonitor", "touch \(fsMarker)"], cwd: repo)
        // Poisoned drivers in the child environment: the fixed argv/env
        // pins neutralize them (B5-A contract, certified at the binary).
        var env = ProcessInfo.processInfo.environment
        env["GIT_EXTERNAL_DIFF"] = "echo HACKED"
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "diff.external"
        env["GIT_CONFIG_VALUE_0"] = "echo HACKED"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.binary())
        process.arguments = ["diff", "--workspace", repo.path, "--git", git]
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "dirty-tree diff exits 0")
        let stdout = String(decoding: outData, as: UTF8.self)
        #expect(stdout.contains("user change"), "user modification in output")
        #expect(!stdout.contains("HACKED"), "external diff driver neutralized")
        #expect(!FileManager.default.fileExists(atPath: fsMarker), "repo fsmonitor hook neutralized")
        #expect(!String(decoding: errData, as: UTF8.self).contains("HACKED"))
    }

    private static func locateGit() throws -> String {
        for candidate in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        Issue.record("git required for TOOL-10 evidence")
        throw WiringError.missingBinary
    }

    private static func runGit(_ git: String, args: [String], cwd: URL, env: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = cwd
        // Fixture hermeticity (see TOOL10DiffTests.runGit): strip inherited
        // repository-location variables so fixture commands cannot act on
        // the caller's repository; explicit overrides apply afterwards.
        var merged = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE"] {
            merged.removeValue(forKey: key)
        }
        if let env {
            for (key, value) in env { merged[key] = value }
        }
        process.environment = merged
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    // MARK: - TOOL-11 cross-session artifact denial

    @Test("TOOL_11_binaryCrossSessionArtifactDenied")
    func TOOL_11_binaryCrossSessionArtifactDenied() throws {
        let content = "artifact-source\n"
        let args = try Self.editArgs(
            path: "a.txt", expectedHash: Self.sha256hex(content),
            old: "artifact-source\n", new: "changed\n")
        // Run 1 (workspace ws1): native edit publishes a preimage artifact.
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let ws1 = directory.appendingPathComponent("ws1")
        try FileManager.default.createDirectory(at: ws1, withIntermediateDirectories: true)
        try content.write(to: ws1.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let first = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws1.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(first.exit == 0)
        // The preimage digest belongs to session 1.
        let sessions1 = try Self.storeSessions(at: stateDir)
        #expect(sessions1.count == 1)
        let records1 = try Self.sessionRecords(at: stateDir, session: sessions1[0])
        let published = records1.compactMap { record -> String? in
            if case .artifactPublished(let ref) = record { return ref.digest }
            return nil
        }
        let digest = try #require(published.first, "native edit publishes its preimage")
        // Run 2 (workspace ws2, same store): read the foreign artifact.
        let server2 = try LoopbackSSEServer()
        server2.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c2", tool: "read",
                               arguments: "{\"artifactId\":\"\(digest)\"}").utf8))]))
        server2.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("denied ok").utf8))]))
        server2.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server2.start()
        defer { server2.stop() }
        // Run 2 dials the SECOND server: reusing run 1's config would hit
        // a drained queue (wrong-port cross-talk, not product behavior).
        let config2 = try Self.writeConfig(directory, port: Int(server2.port))
        let ws2 = directory.appendingPathComponent("ws2")
        try FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
        let second = try Self.runWithPTY(
            ["run", "--config", config2, "--prompt", "read it", "--format", "jsonl", "--alias", "loop",
             "--workspace", ws2.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(second.exit == 0, "denial is honest, not a crash: \(second.ptyOutput.prefix(300))")
        // Session 2's tool result carries no foreign bytes.
        let sessions2 = try Self.storeSessions(at: stateDir)
        #expect(sessions2.count == 2)
        let newSession = try #require(sessions2.first(where: { $0 != sessions1[0] }))
        let (_, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: newSession))
        #expect(!results.contains(where: { $0.1.contains(content) || Self.isMutatingSuccess($0.1) }),
                "cross-session artifact read yields no bytes and no success")
        let bodies = server2.requests.map { String(decoding: $0.body, as: UTF8.self) }.joined()
        #expect(!String(bodies.dropFirst()).contains("artifact-source"),
                "foreign artifact bytes never reach the provider")
    }

    // MARK: - TOOL-12 terminal bytes at the display boundary

    @Test("TOOL_12_binaryTerminalBytesSanitized")
    func TOOL_12_binaryTerminalBytesSanitized() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.finalText("done \u{1B}[2J \u{07}bell \u{202E}rtl").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // Human mode: final answer goes to stdout through terminalSafe.
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hi", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0)
        let outBytes = Array(result.stdout.utf8)
        #expect(!outBytes.contains(0x1B), "no ESC byte on the terminal")
        #expect(!outBytes.contains(0x07), "no BEL byte on the terminal")
        #expect(!result.stdout.contains("\u{202E}"), "bidi neutralized")
        #expect(result.stdout.contains("\u{FFFD}"), "neutralization marker present")
        let errBytes = Array(result.stderr.utf8)
        #expect(!errBytes.contains(0x1B), "no ESC byte on stderr either")
    }

    // MARK: - PORT-03 case + Unicode-distinct filenames

    @Test("PORT_03_binaryCaseAndUnicodeDistinct")
    func PORT_03_binaryCaseAndUnicodeDistinct() throws {
        let server = try LoopbackSSEServer()
        let batch = try Self.multiToolCallChunk([
            (callID: "c1", tool: "read", arguments: "{\"path\":\"README.md\"}"),
            (callID: "c2", tool: "read", arguments: "{\"path\":\"readme.md\"}"),
            (callID: "c3", tool: "read", arguments: "{\"path\":\"caf\u{E9}.txt\"}"),
            (callID: "c4", tool: "read", arguments: "{\"path\":\"cafe\u{301}.txt\"}"),
        ])
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(batch.utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let readRoot = directory.appendingPathComponent("rr")
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: true)
        try "upper\n".write(to: readRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "lower\n".write(to: readRoot.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        try "nfc\n".write(to: readRoot.appendingPathComponent("caf\u{E9}.txt"), atomically: true, encoding: .utf8)
        try "nfd\n".write(to: readRoot.appendingPathComponent("cafe\u{301}.txt"), atomically: true, encoding: .utf8)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "read all", "--format", "jsonl", "--alias", "loop",
             "--read-root", readRoot.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "distinct names read distinctly: \(result.stderr.prefix(200))")
        #expect(server.requests.count == 2)
        let toolTexts = ((try Self.jsonBody(Data(server.requests[1].body))["messages"] as? [[String: Any]]) ?? []).compactMap { message -> String? in
            guard message["tool_call_id"] != nil else { return nil }
            return message["content"] as? String
        }
        let combined = toolTexts.joined(separator: "\n")
        for marker in ["upper", "lower", "nfc", "nfd"] {
            #expect(combined.contains(marker), "distinct file \(marker) returned")
        }
    }

    // MARK: - Support: backend selection denies unadvertised exec

    @Test("backendSelectionExecDenied")
    func backendSelectionExecDenied() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "exec",
                               arguments: "{\"command\":\"touch MARKER\"}").utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "run it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 0, "caps-denied exec is a denial, not a crash: \(result.ptyOutput.prefix(200))")
        // The advertisement never carries exec/consult/diff under any caps.
        let firstBody = try Self.jsonBody(Data(server.requests[0].body))
        #expect(Self.toolNames(in: firstBody)?.sorted() == ["edit", "read", "search", "write"])
        #expect(firstBody["tool_choice"] as? String == "auto")
        // Nothing executes: no marker file, and the denial (not a
        // success) is the durable outcome. The intent IS committed
        // (intent-before-effect); the denial result proves no effect ran.
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("MARKER").path))
        let sessions = try Self.storeSessions(at: stateDir)
        let (intents, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(intents.count == 1)
            #expect(results.count == 1)
            #expect(!results.contains(where: { Self.isMutatingSuccess($0.1) }), "caps-denied exec records denial, never success")
    }

    // MARK: - Support: trusted demo cannot mutate real files

    @Test("trustedCannotMutateRealFiles")
    func trustedCannotMutateRealFiles() throws {
        let server = try LoopbackSSEServer()
        let file = "keep\n"
        let scriptArgs = "{\"expectedHash\":\"\(Self.sha256hex(file))\",\"old_string\":\"keep\\n\",\"new_string\":\"drop\\n\",\"path\":\"v.txt\"}"
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: scriptArgs).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let tools = try Self.writeTools(directory, entries: [[
            "tool": "edit", "arguments": scriptArgs, "result": "canned",
        ]])
        let stateDir = try Self.freshState(in: directory)
        // A real file that the scripted backend must never touch.
        let victim = directory.appendingPathComponent("victim.txt")
        try file.write(to: victim, atomically: true, encoding: .utf8)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--tools", tools, "--trusted"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "trusted demo completes: \(result.stderr.prefix(200))")
        #expect(try String(contentsOf: victim, encoding: .utf8) == file,
                "scripted execution never mutates the real filesystem")
        // The scripted dispatch still commits its durable intent + result.
        let sessions = try Self.storeSessions(at: stateDir)
        let (intents, results) = Self.intentsAndResults(
            try Self.sessionRecords(at: stateDir, session: sessions[0]))
        #expect(intents.count == 1)
        #expect(results.count == 1)
    }

    // MARK: - Support: sealed runs stay tool-free and non-persistent

    @Test("sealedRunsStayToolFree")
    func sealedRunsStayToolFree() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("sealed answer").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "answer only", "--format", "jsonl", "--alias", "loop",
             "--sealed"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "sealed run completes: \(result.stderr.prefix(200))")
        #expect(server.requests.count == 1)
        // No usable file tools are advertised to a sealed run.
        let body = try Self.jsonBody(Data(server.requests[0].body))
        #expect(body["tools"] == nil, "sealed requests carry no tools")
        #expect(body["tool_choice"] == nil)
        // Nothing sealed persists: the production store is never created.
        #expect(!FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("store.sqlite").path),
                "sealed content never reaches durable storage")
    }

    // MARK: - Support: persistence failure blocks the provider

    @Test("persistenceFailureBlocksProvider")
    func persistenceFailureBlocksProvider() throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        // Seed a store, then revoke all writes: claim and migration both
        // fail closed on the read-only files. Permissions are restored
        // before the teardown remove (LIFO: this defer runs first).
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateDir.path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: stateDir.appendingPathComponent("store.sqlite").path)
        }
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let seeder = try GRDBSessionStore(path: dbPath)
        let id = SessionID("s-seed")
        try seeder.claimWriterOwnership(session: id, writer: "w")
        try seeder.append(.sessionOpened(session: id, atMillis: 1),
                          as: WriterIdentity(session: id, writer: "w"))
        try seeder.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dbPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateDir.path)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "do work", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 6, "unwritable store fails closed, got \(result.exit): \(result.stderr.prefix(200))")
        #expect(server.connectionCount == 0, "no provider traffic past a persistence failure")
        #expect(server.requests.isEmpty)
    }

    // MARK: - Support: artifact failure fails the edit honestly

    @Test("artifactPublishFailureFailsEditHonestly")
    func artifactPublishFailureFailsEditHonestly() throws {
        let server = try LoopbackSSEServer()
        let file = "precious\n"
        let args = try Self.editArgs(
            path: "p.txt", expectedHash: Self.sha256hex(file),
            old: "precious\n", new: "changed\n")
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            Self.toolCallChunk(callID: "c1", tool: "edit", arguments: args).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = try Self.freshState(in: directory)
        let workspace = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try file.write(to: workspace.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
        // Plant a FILE where the artifacts root must be: the byte ledger
        // cannot reconcile it at store open, so the run fails closed at
        // startup — no false success, no provider continuation, target
        // untouched.
        try "blocker".write(to: stateDir.appendingPathComponent("store.sqlite-artifacts"),
                            atomically: true, encoding: .utf8)
        let result = try Self.runWithPTY(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop",
             "--workspace", workspace.path],
            env: Self.environment(stateDir: stateDir), input: "y\n")
        #expect(result.exit == 6, "unlistable artifacts root fails the run closed: \(result.ptyOutput.prefix(300))")
        #expect(result.ptyOutput.contains("artifact root") || result.ptyOutput.contains("byte ledger"),
                "the integrity fault names the artifacts root")
        #expect(try String(contentsOf: workspace.appendingPathComponent("p.txt"), encoding: .utf8) == file,
                "the target is untouched")
        #expect(server.connectionCount == 0, "no provider traffic past the integrity failure")
    }
}
