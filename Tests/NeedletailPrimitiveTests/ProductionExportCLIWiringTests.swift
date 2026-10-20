import Testing
import Foundation
import GRDB
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport

/// A5-2 STORE-08 binary evidence: the REAL `needletail` product against a
/// synthetic loopback provider, then `needletail session export` against
/// the produced store. The loopback proposes tools (trusted mode), so the
/// ledger carries intents, done results, transcripts and queue rows with
/// synthetic sentinels end to end.
struct ProductionExportCLIWiringTests {

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
            Issue.record("needletail binary missing; build the product before CLI export tests")
            throw ExportWiringError.missingBinary
        }
        return fallback
    }

    private static func root() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }

    private static func environment(stateDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
        env["NEEDLETAIL_STATE_DIR"] = stateDir.path
        return env
    }

    private static func writeConfig(_ directory: URL, port: Int, urlSuffix: String) throws -> String {
        let url = directory.appendingPathComponent("config.json")
        let config: [String: Any] = [
            "version": 1,
            "default_model": "loop",
            "allow_http_origins": ["http://127.0.0.1:\(port)"],
            "models": [[
                "alias": "loop",
                "protocol": "openai-chat-completions",
                "base_url": "http://127.0.0.1:\(port)\(urlSuffix)",
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
                "read": true, "search": true, "edit": false, "write": false,
                "exec": "ask", "consult": false,
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    private static func writeTools(_ directory: URL) throws -> String {
        let entries = [
            ["tool": "read", "arguments": "{\"path\":\"/x/GAMMA-333\"}", "result": "file EXP-DELTA-444"],
        ]
        let url = directory.appendingPathComponent("tools.json")
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            .write(to: url)
        return url.path
    }

    private static func dataJSON(_ object: [String: Any]) -> String {
        "data: " + (String(data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}") + "\n\n"
    }

    /// One tool call, as its own scripted response...
    private static func toolCallOnly(callID: String) -> String {
        var out = dataJSON([
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": callID,
                "function": ["name": "read", "arguments": "{\"path\":\"/x/GAMMA-333\"}"],
            ]]], "finish_reason": NSNull()]],
        ])
        out += dataJSON(["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]])
        out += "data: [DONE]\n\n"
        return out
    }

    /// ...followed by a final text answer as the next response.
    private static func finalText(_ text: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        var body = "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(encoded)},\"finish_reason\":null}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
        body += "data: [DONE]\n\n"
        return body
    }

    private static func run(_ arguments: [String], env: [String: String]) throws -> (exit: Int32, stdout: String, stderr: String) {
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
            Issue.record("child binary died from signal \(process.terminationStatus)")
            throw ExportWiringError.childCrashed
        }
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-export-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func posixMode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    private static func jsonLines(_ stdout: String) throws -> [[String: Any]] {
        var envelopes: [[String: Any]] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                Issue.record("unparseable export line: \(line.prefix(120))")
                throw ExportWiringError.unparseable
            }
            envelopes.append(object)
        }
        return envelopes
    }

    /// A real trusted run against the loopback: tool call + final answer,
    /// returning the state dir (whose store.sqlite holds the ledger).
    @discardableResult
    private static func trustedRun(
        in directory: URL, prompt: String, answer: String, callID: String = "call-9"
    ) throws -> URL {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallOnly(callID: callID).utf8))]))
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText(answer).utf8))]))
        server.start()
        defer { server.stop() }
        let config = try Self.writeConfig(directory, port: Int(server.port), urlSuffix: "/sentinel-SECRET-BASE-88")
        let tools = try Self.writeTools(directory)
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", prompt, "--format", "jsonl", "--alias", "loop",
             "--tools", tools, "--trusted"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "trusted tool run completes: \(result.stderr.prefix(300))")
        return stateDir
    }

    @Test("STORE-08 sqlite redacted export omits confidential content")
    func STORE_08_sqliteRedactedExportOmitsConfidentialContent() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDir = try Self.trustedRun(
            in: directory, prompt: "read it EXP-ALPHA-111", answer: "all done EXP-BETA-222")
        // Second run: the cross-session isolation probe.
        _ = try Self.trustedRun(
            in: directory, prompt: "second CONTENT-000", answer: "second done")
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        #expect(FileManager.default.fileExists(atPath: dbPath))
        #expect(try Self.posixMode(stateDir.path) == 0o700, "state directory is private")
        #expect(try Self.posixMode(dbPath) == 0o600, "database file is private")
        // Export the FIRST session (discover IDs without touching the DB).
        let sessions = try Self.sessionIDs(dbPath: dbPath)
        #expect(sessions.count == 2, "two binary runs, two sessions, got \(sessions)")
        let first = try Self.sessionWithPrompt(dbPath: dbPath, prompt: "read it EXP-ALPHA-111")
        let outURL = directory.appendingPathComponent("redacted.jsonl")
        let export = try Self.run(
            ["session", "export", first, "--output", outURL.path],
            env: Self.environment(stateDir: stateDir))
        #expect(export.exit == 0, "redacted export succeeds: \(export.stderr.prefix(300))")
        #expect(try Self.posixMode(outURL.path) == 0o600, "export file is private")
        let text = try String(contentsOfFile: outURL.path, encoding: .utf8)
        for sentinel in ["EXP-ALPHA-111", "EXP-BETA-222", "GAMMA-333", "EXP-DELTA-444",
                         "SECRET-BASE-88", "CONTENT-000", "second done"] {
            #expect(!text.contains(sentinel), "default export leaks \(sentinel)")
        }
        let objects = try Self.jsonLines(text)
        #expect(objects.first?["format"] as? String == "needletail-session-export")
        #expect(objects.first?["version"] as? Int == 1)
        #expect(objects.first?["content"] as? Bool == false)
        #expect(objects.first?["sensitive"] as? Bool == true)
        #expect(objects.first?["session"] as? String == first)
        guard let trailer = objects.last, trailer["complete"] as? Bool == true else {
            Issue.record("export must end with a complete trailer")
            return
        }
        #expect((trailer["recordCount"] as? Int) == objects.count - 2,
                "trailer count matches record lines")
        let kinds = Set(objects.compactMap { $0["kind"] as? String })
        #expect(kinds.contains("intent") && kinds.contains("result"), "operation identities travel")
        // Completed tool operation identified without its contents.
        let operations = trailer["operations"] as? [String: Any]
        #expect((operations?["completed"] as? [String])?.count == 1)
        #expect(try Self.posixMode(outURL.path) == 0o600, "export file is private")
    }

    @Test("STORE-08 sqlite content export permits only documented content")
    func STORE_08_sqliteContentExportPermitsOnlyDocumentedContent() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDir = try Self.trustedRun(
            in: directory, prompt: "read it EXP-ALPHA-111", answer: "all done EXP-BETA-222")
        let first = try Self.sessionWithPrompt(
            dbPath: stateDir.appendingPathComponent("store.sqlite").path, prompt: "read it EXP-ALPHA-111")
        let outURL = directory.appendingPathComponent("content.jsonl")
        let export = try Self.run(
            ["session", "export", first, "--output", outURL.path, "--include-content"],
            env: Self.environment(stateDir: stateDir))
        #expect(export.exit == 0, "content export succeeds: \(export.stderr.prefix(300))")
        let text = try String(contentsOfFile: outURL.path, encoding: .utf8)
        // Documented permitted content travels verbatim.
        for permitted in ["EXP-ALPHA-111", "EXP-BETA-222", "GAMMA-333", "EXP-DELTA-444"] {
            #expect(text.contains(permitted), "documented content must travel: \(permitted)")
        }
        // Never permitted: epoch/config identity, raw payloads, credentials.
        for excluded in ["SECRET-BASE-88", "127.0.0.1"] {
            #expect(!text.contains(excluded), "content export must still exclude \(excluded)")
        }
        let objects = try Self.jsonLines(text)
        #expect(objects.first?["content"] as? Bool == true)
        #expect(objects.first?["sensitive"] as? Bool == true)
        // No credential-shaped or raw-payload keys anywhere in the file.
        let forbidden = ["credential", "credentials", "secret", "token", "password",
                         "rawBody", "rawPayload", "raw", "route", "endpoint",
                         "baseURL", "base_url", "model", "configSnapshot", "snapshot",
                         "capabilities", "caps"]
        var seenKeys = Set<String>()
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                dict.forEach { seenKeys.insert($0.key); walk($0.value) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        objects.forEach(walk)
        #expect(seenKeys.isDisjoint(with: Set(forbidden)),
                "forbidden keys present: \(seenKeys.intersection(forbidden))")
    }

    @Test("A5-2 cli export missing future and corrupt stores fail explicitly")
    func exportMissingFutureAndCorruptStoresFail() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingDir = directory.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: missingDir, withIntermediateDirectories: true)
        // Missing store: no file is created, exit is honest.
        var result = try Self.run(
            ["session", "export", "s-x", "--output", missingDir.appendingPathComponent("o.jsonl").path],
            env: Self.environment(stateDir: missingDir))
        #expect(result.exit == 4, "missing store is a usage-shaped failure, got \(result.exit)")
        #expect(!FileManager.default.fileExists(atPath: missingDir.appendingPathComponent("store.sqlite").path),
                "missing store is never created")
        #expect(!FileManager.default.fileExists(atPath: missingDir.appendingPathComponent("o.jsonl").path),
                "no output on missing store")
        // Corrupt bytes: identified, untouched, exit 6.
        let corruptDB = directory.appendingPathComponent("corrupt.sqlite").path
        let garbage = Data("not a database".utf8)
        try garbage.write(to: URL(fileURLWithPath: corruptDB))
        let corruptDir = directory.appendingPathComponent("corruptstate")
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: corruptDB, toPath: corruptDir.appendingPathComponent("store.sqlite").path)
        let corruptStateDB = corruptDir.appendingPathComponent("store.sqlite").path
        result = try Self.run(
            ["session", "export", "s-x", "--output", directory.appendingPathComponent("o2.jsonl").path],
            env: Self.environment(stateDir: corruptDir))
        #expect(result.exit == 6, "corrupt store fails closed, got \(result.exit): \(result.stderr.prefix(200))")
        #expect(try Data(contentsOf: URL(fileURLWithPath: corruptStateDB)) == garbage,
                "corrupt source byte-identical afterwards (no repair attempt)")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("o2.jsonl").path),
                "no output on corrupt store")
        // Future schema: refused without downgrading or migrating.
        let futureDir = directory.appendingPathComponent("futurestate")
        try FileManager.default.createDirectory(at: futureDir, withIntermediateDirectories: true)
        let futureDB = futureDir.appendingPathComponent("store.sqlite").path
        let raw = try DatabaseQueue(path: futureDB)
        try raw.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
        try raw.close()
        result = try Self.run(
            ["session", "export", "s-x", "--output", directory.appendingPathComponent("o3.jsonl").path],
            env: Self.environment(stateDir: futureDir))
        #expect(result.exit == 6, "future store fails closed, got \(result.exit)")
        let probe = try DatabaseQueue(path: futureDB)
        let version = try probe.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        try probe.close()
        #expect(version == 99, "future store untouched")
        // Unknown session in a valid store.
        let emptyDir = directory.appendingPathComponent("emptystate")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyStore = try GRDBSessionStore(path: emptyDir.appendingPathComponent("store.sqlite").path)
        try emptyStore.close()
        result = try Self.run(
            ["session", "export", "s-ghost", "--output", directory.appendingPathComponent("o4.jsonl").path],
            env: Self.environment(stateDir: emptyDir))
        #expect(result.exit == 4, "unknown session is a usage-shaped failure, got \(result.exit)")
    }

    @Test("A5-2 cli export refuses overwrite and leaves no partial output")
    func exportRefusesOverwrite() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDir = try Self.trustedRun(
            in: directory, prompt: "read it", answer: "done")
        let first = try Self.sessionWithPrompt(
            dbPath: stateDir.appendingPathComponent("store.sqlite").path, prompt: "read it")
        let outURL = directory.appendingPathComponent("exists.jsonl")
        try "marker".write(to: outURL, atomically: true, encoding: .utf8)
        let result = try Self.run(
            ["session", "export", first, "--output", outURL.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit != 0, "existing target must refuse, got exit \(result.exit)")
        #expect(try String(contentsOfFile: outURL.path, encoding: .utf8) == "marker",
                "refused overwrite leaves the target byte-identical")
        let linkURL = directory.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: outURL.path)
        let linked = try Self.run(
            ["session", "export", first, "--output", linkURL.path],
            env: Self.environment(stateDir: stateDir))
        #expect(linked.exit != 0, "symlink target must refuse")
    }

    // MARK: - Session discovery helpers (test-only raw reads)

    private static func sessionIDs(dbPath: String) throws -> [String] {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session FROM records ORDER BY session")
        }
    }

    private static func sessionWithPrompt(dbPath: String, prompt: String) throws -> String {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        let sessions = try db.read { db -> [String] in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT session FROM records
                WHERE payload LIKE ?
                """, arguments: ["%\(prompt)%"])
        }
        guard let first = sessions.first else {
            Issue.record("no session contains prompt \(prompt)")
            throw ExportWiringError.unparseable
        }
        return first
    }
}

private enum ExportWiringError: Error {
    case missingBinary
    case unparseable
    case childCrashed
}
