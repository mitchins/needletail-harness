import Testing
import Foundation
import NeedletailTestSupport

private enum M1DCases {
    static let modelAlias = "loop"

    static func root() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }

    static func binary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["NEEDLETAIL_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let fallback = root() + "/.build/debug/needletail"
        guard FileManager.default.isExecutableFile(atPath: fallback) else {
            Issue.record("needletail binary missing; build the product before Swift Testing cases")
            throw M1DCaseError.missingBinary
        }
        return fallback
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
        return env
    }

    static func writeConfig(_ directory: URL, port: Int, execPolicy: Any = true) throws -> String {
        let url = directory.appendingPathComponent("config.json")
        let config: [String: Any] = [
            "version": 1,
            "default_model": modelAlias,
            "allow_http_origins": ["http://127.0.0.1:\(port)"],
            "models": [[
                "alias": modelAlias,
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
                "exec": execPolicy, "consult": true,
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    static func writeTools(_ directory: URL) throws -> String {
        let entries = [
            ["tool": "read", "arguments": "{\"path\":\"src/main.py\"}", "result": "read result"],
            ["tool": "edit", "arguments": "{\"path\":\"src/main.py\",\"old\":\"a\",\"new\":\"b\"}", "result": "edit applied"],
            ["tool": "exec", "arguments": "{\"command\":\"pytest\"}", "result": "pytest failure"],
            ["tool": "edit", "arguments": "{\"path\":\"src/main.py\",\"old\":\"bad\",\"new\":\"fixed\"}", "result": "repair applied"],
        ]
        let url = directory.appendingPathComponent("tools.json")
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]).write(to: url)
        return url.path
    }

    static func dataJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    static func toolCall(_ callID: String, tool: String, arguments: String) throws -> String {
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
        return try dataJSON(delta) + dataJSON(finish) + dataJSON(usage)
    }

    static func finalText(_ text: String) throws -> String {
        let start: [String: Any] = [
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant", "content": text],
                "finish_reason": NSNull(),
            ]],
        ]
        let finish: [String: Any] = [
            "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
        ]
        let usage: [String: Any] = [
            "choices": [],
            "usage": ["prompt_tokens": 5, "completion_tokens": 5],
        ]
        return try dataJSON(start) + dataJSON(finish) + dataJSON(usage) + "data: [DONE]\n\n"
    }

    static func happyScripts() throws -> [SSEScript] {
        [
            SSEScript(chunks: [ScriptChunk(bytes: Array(try toolCall(
                "call-read-1", tool: "read", arguments: "{\"path\":\"src/main.py\"}").utf8))]),
            SSEScript(chunks: [ScriptChunk(bytes: Array(try toolCall(
                "call-edit-1", tool: "edit", arguments: "{\"path\":\"src/main.py\",\"old\":\"a\",\"new\":\"b\"}").utf8))]),
            SSEScript(chunks: [ScriptChunk(bytes: Array(try toolCall(
                "call-exec-1", tool: "exec", arguments: "{\"command\":\"pytest\"}").utf8))]),
            SSEScript(chunks: [ScriptChunk(bytes: Array(try toolCall(
                "call-edit-2", tool: "edit", arguments: "{\"path\":\"src/main.py\",\"old\":\"bad\",\"new\":\"fixed\"}").utf8))]),
            SSEScript(chunks: [ScriptChunk(bytes: Array(try finalText("fixed and tests pass").utf8))]),
        ]
    }

    static func run(_ arguments: [String]) throws -> (exit: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binary())
        process.arguments = arguments
        process.environment = environment()
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
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    static func runArguments(
        config: String, trace: String? = nil, tools: String? = nil,
        trusted: Bool = false, sealed: Bool = false, maxTurns: Int? = nil
    ) -> [String] {
        var args = ["run", "--config", config, "--prompt", "fix and verify",
                    "--format", "jsonl", "--alias", modelAlias]
        if let trace { args += ["--trace", trace] }
        if let tools { args += ["--tools", tools] }
        if trusted { args += ["--trusted"] }
        if sealed { args += ["--sealed"] }
        if let maxTurns { args += ["--max-turns", String(maxTurns)] }
        return args
    }
}

private enum M1DCaseError: Error {
    case missingBinary
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("needletail-m1d-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized)
struct M1DCasesTests {

    @Test("CORE-01 scripted multi-turn read/edit/test/repair loop")
    func CORE_01_scriptedMultiTurnLoop() throws {
        let server = try LoopbackSSEServer()
        for script in try M1DCases.happyScripts() { server.enqueue(script) }
        server.start()
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try M1DCases.writeConfig(directory, port: Int(server.port))
        let tools = try M1DCases.writeTools(directory)
        let result = try M1DCases.run(M1DCases.runArguments(
            config: config, trace: directory.appendingPathComponent("trace.jsonl").path,
            tools: tools, trusted: true))
        #expect(result.exit == 0, "headless loop completed: \(result.stderr)")
        #expect(result.stdout.contains("\"kind\":\"delta\""), "streamed output visible in JSONL")
        #expect(result.stdout.contains("\"kind\":\"run_finished\""))
        #expect(server.requests.count == 5, "one request per turn, got \(server.requests.count)")
        let requests = try server.requests.map { request -> [String: Any] in
            try JSONSerialization.jsonObject(with: Data(request.body), options: []) as! [String: Any]
        }
        let messages = requests[4]["messages"] as! [[String: Any]]
        let calls = messages.compactMap { message -> String? in
            let toolCalls = message["tool_calls"] as? [[String: Any]]
            return toolCalls?.first?["id"] as? String
        }
        #expect(calls == ["call-read-1", "call-edit-1", "call-exec-1", "call-edit-2"], "transcript pairing order: \(calls)")
        let toolResponses = messages.filter { $0["role"] as? String == "tool" }
        #expect(toolResponses.count == 4)
    }

    @Test("HEAD-01 JSONL mode with streamed tool output and errors")
    func HEAD_01_jsonlStreamedOutputAndErrors() throws {
        let server = try LoopbackSSEServer()
        for script in try M1DCases.happyScripts() { server.enqueue(script) }
        server.start()
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try M1DCases.writeConfig(directory, port: Int(server.port))
        let tools = try M1DCases.writeTools(directory)
        let result = try M1DCases.run(M1DCases.runArguments(
            config: config, tools: tools, trusted: true))
        #expect(result.exit == 0)
        let envelopes = try M1DCasesJSON.envelopes(result.stdout)
        #expect(envelopes.map(\.seq) == envelopes.map(\.seq).sorted())
        #expect(envelopes.contains { $0.kind == "delta" })
        #expect(envelopes.last?.kind == "run_finished")
        #expect(result.stderr.contains("fixed and tests pass"))
        #expect(!result.stdout.contains("\u{1B}"))

        let errorServer = try LoopbackSSEServer()
        let malformed = try M1DCases.toolCall(
            "call-bad", tool: "read", arguments: "not-json")
        errorServer.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(malformed.utf8))]))
        errorServer.start()
        defer { errorServer.stop() }
        let errorDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: errorDir) }
        let errorConfig = try M1DCases.writeConfig(errorDir, port: Int(errorServer.port))
        let errorResult = try M1DCases.run(M1DCases.runArguments(
            config: errorConfig, tools: tools, trusted: true))
        #expect(errorResult.exit == 4, "protocol failure maps to exit 4: \(errorResult.stderr)")
        #expect(errorResult.stdout.contains("provider_error"))
    }

    @Test("HEAD-02 consumer closes output pipe")
    func HEAD_02_consumerClosesOutputPipe() throws {
        let server = try LoopbackSSEServer()
        let first = try M1DCases.dataJSON([
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant", "content": "first "],
                "finish_reason": NSNull(),
            ]],
        ])
        let second = try M1DCases.dataJSON([
            "choices": [[
                "index": 0,
                "delta": ["content": "second "],
                "finish_reason": NSNull(),
            ]],
        ])
        server.enqueue(SSEScript(chunks: [
            ScriptChunk(bytes: Array(first.utf8), delayMillis: 0),
            ScriptChunk(bytes: Array(second.utf8), delayMillis: 400),
        ]))
        server.start()
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try M1DCases.writeConfig(directory, port: Int(server.port))
        let trace = directory.appendingPathComponent("trace.jsonl").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try M1DCases.binary())
        process.arguments = M1DCases.runArguments(config: config, trace: trace, trusted: true)
        process.environment = M1DCases.environment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let output = stdoutPipe.fileHandleForReading
        var sawDelta = false
        var observed = Data()
        while !sawDelta {
            let chunk = output.availableData
            if chunk.isEmpty { break }
            observed.append(chunk)
            if String(decoding: observed, as: UTF8.self).contains("\"kind\":\"delta\"") {
                sawDelta = true
            }
        }
        #expect(sawDelta, "delta observable before the consumer closed")
        try output.close()
        process.waitUntilExit()
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let status = process.terminationStatus
        #expect(status == 130, "closed stdout maps to exit 130, got \(status): \(stderr)")
        let traceText = try String(contentsOf: URL(fileURLWithPath: trace), encoding: .utf8)
        #expect(traceText.contains("\"kind\":\"delta\""), "authoritative trace retains the streamed delta")
        #expect(!traceText.contains("\u{1B}"))
    }

    @Test("HEAD-03 each terminal run outcome")
    func HEAD_03_terminalRunOutcomes() throws {
        let happyDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: happyDirectory) }
        let happyServer = try LoopbackSSEServer()
        for script in try M1DCases.happyScripts() { happyServer.enqueue(script) }
        happyServer.start()
        defer { happyServer.stop() }
        let happyConfig = try M1DCases.writeConfig(happyDirectory, port: Int(happyServer.port))
        let tools = try M1DCases.writeTools(happyDirectory)
        let happy = try M1DCases.run(M1DCases.runArguments(config: happyConfig, tools: tools, trusted: true))
        #expect(happy.exit == 0)

        let approvalDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: approvalDirectory) }
        let approvalServer = try LoopbackSSEServer()
        approvalServer.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            try M1DCases.toolCall("call-exec", tool: "exec", arguments: "{\"command\":\"pytest\"}").utf8))]))
        approvalServer.start()
        defer { approvalServer.stop() }
        let approvalConfig = try M1DCases.writeConfig(
            approvalDirectory, port: Int(approvalServer.port), execPolicy: "ask")
        let approval = try M1DCases.run(M1DCases.runArguments(config: approvalConfig, trusted: true))
        #expect(approval.exit == 3, "headless approval-required maps to exit 3: \(approval.stderr)")
        #expect(approval.stdout.contains("approval_required"))

        let providerDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: providerDirectory) }
        let providerServer = try LoopbackSSEServer()
        providerServer.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
            "data: {\"choices\":[{\"delta\":{\"content\":\"incomplete\"}}]}\n\n".utf8))]))
        providerServer.start()
        defer { providerServer.stop() }
        let providerConfig = try M1DCases.writeConfig(providerDirectory, port: Int(providerServer.port))
        let provider = try M1DCases.run(M1DCases.runArguments(config: providerConfig, trusted: true))
        #expect(provider.exit == 4, "provider failure maps to exit 4: \(provider.stderr)")

        let budgetDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: budgetDirectory) }
        let budgetServer = try LoopbackSSEServer()
        for _ in 0..<5 {
            budgetServer.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(
                try M1DCases.toolCall("call-read", tool: "read", arguments: "{\"path\":\"src/main.py\"}").utf8))]))
        }
        budgetServer.start()
        defer { budgetServer.stop() }
        let budgetConfig = try M1DCases.writeConfig(budgetDirectory, port: Int(budgetServer.port))
        let budget = try M1DCases.run(M1DCases.runArguments(
            config: budgetConfig, tools: tools, trusted: true, maxTurns: 2))
        #expect(budget.exit == 5, "budget exhaustion maps to exit 5: \(budget.stderr)")

        let invalid = try M1DCases.writeConfig(try temporaryDirectory(), port: 0)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: invalid))
        let invalidResult = try M1DCases.run(M1DCases.runArguments(config: invalid))
        #expect(invalidResult.exit == 2, "invalid config maps to exit 2: \(invalidResult.stderr)")
    }
}

private enum M1DCasesJSON {
    struct Envelope {
        let seq: Int
        let kind: String
    }

    static func envelopes(_ text: String) throws -> [Envelope] {
        var envelopes: [Envelope] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seq = object["seq"] as? Int,
                  let kind = object["kind"] as? String else { continue }
            envelopes.append(Envelope(seq: seq, kind: kind))
        }
        return envelopes
    }
}
