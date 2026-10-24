import Testing
import Foundation
import Dispatch
import GRDB
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport

/// B5-B startup gate CLI evidence: the REAL `needletail run` binary
/// against seeded GRDB stores. Blocked runs exit 3 before any provider
/// traffic (loopback connection count stays zero); authorized runs
/// commit a durable acknowledgment and complete; corrupt ledgers exit 6
/// even WITH the flag; the gate is store-wide (cross-workspace).
///
/// Serialized: spawns real binaries against real store files.
@Suite(.serialized)
struct CrossRunGateCLITests {

    // MARK: - Binary + config harness (mirrors ProductionCLIWiringTests)

    private enum WiringError: Error {
        case missingBinary
        case childCrashed(Int32)
        case unparseableStdout
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
            Issue.record("needletail binary missing; build the product before CLI wiring cases")
            throw WiringError.missingBinary
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

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-gate-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Minimal final-text chunk (same shape as ProductionCLIWiringTests).
    private static func finalText(_ text: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        var body = "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(encoded)},\"finish_reason\":null}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        body += "data: {\"id\":\"t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
        body += "data: [DONE]\n\n"
        return body
    }

    // MARK: - Store seeding (in-process GRDB, then fresh binary handle)

    private static func seedDirtyStore(at stateDir: URL, session: String = "s-prior") throws {
        let store = try GRDBSessionStore(
            path: stateDir.appendingPathComponent("store.sqlite").path)
        let id = SessionID(session)
        try store.claimWriterOwnership(session: id, writer: "w-prior")
        try store.appendBatch([
            .sessionOpened(session: id, atMillis: 1000),
            .operationIntent(OperationRef(
                operationID: OperationID("ep/c1"), callID: "c1", state: .intent, mutating: true)),
        ], as: WriterIdentity(session: id, writer: "w-prior"))
        try store.close()
    }

    private static func storeSessions(at stateDir: URL) throws -> [String] {
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        return try store.sessions().map(\.raw)
    }

    private static func acknowledgments(
        at stateDir: URL, session: String
    ) throws -> [Acknowledgment] {
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (page, _) = try store.records(session: SessionID(session), since: 0, limit: 10_000)
        return page.compactMap {
            if case .acknowledgedUnresolved(let ack) = $0.record { return ack }
            return nil
        }
    }

    // MARK: - CLI gate legs

    @Test("B5-B CLI blocked without flag: exit 3, names session, zero provider traffic")
    func cliBlockedWithoutFlag() throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "do work", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 3, "gate trip without authorization exits 3, got \(result.exit): \(result.stderr)")
        #expect(result.stderr.contains("s-prior"), "block message names the dirty session")
        #expect(result.stderr.contains("acknowledge-unresolved-outcomes"), "block message points at the flag")
        #expect(result.stderr.contains("session export"), "block message points at export for audit")
        #expect(server.connectionCount == 0, "no provider traffic before the gate decision")
        #expect(server.requests.isEmpty)
    }

    @Test("B5-B CLI proceeds with flag: durable ack committed, run completes")
    func cliProceedsWithFlag() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "do work", "--format", "jsonl", "--alias", "loop",
             "--acknowledge-unresolved-outcomes", "operator-accepted-risk"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "authorized run completes, got \(result.exit): \(result.stderr)")
        // Exactly one new session; it carries the committed decision with
        // exact identity; the prior hold is preserved.
        let sessions = try Self.storeSessions(at: stateDir)
        #expect(sessions.count == 2)
        #expect(sessions.contains("s-prior"))
        let newSession = try #require(sessions.first(where: { $0 != "s-prior" }))
        let acks = try Self.acknowledgments(at: stateDir, session: newSession)
        #expect(acks.count == 1)
        #expect(acks[0].subjectSessions.map(\.raw) == ["s-prior"])
        #expect(acks[0].operationIDs.map(\.raw) == ["ep/c1"])
        #expect(acks[0].determination == "operator-accepted-risk")
    }

    @Test("B5-B CLI garbage flag value exits 2 (usage, before any store write)")
    func cliGarbageFlagValue() throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "do work", "--alias", "loop",
             "--acknowledge-unresolved-outcomes", "yes-please"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 2, "malformed determination is a usage error, got \(result.exit)")
        #expect(server.connectionCount == 0)
        // No new session was opened: only the seeded session exists.
        #expect(try Self.storeSessions(at: stateDir) == ["s-prior"])
    }

    @Test("B5-B CLI corrupt ledger fails closed (exit 6) even WITH the flag")
    func cliCorruptLedgerFailsClosed() throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        // Corrupt a row with raw SQL (foreign/garbled payload).
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO records (session, payload) VALUES (?, ?)",
                arguments: ["s-corrupt", "not-json{{{"])
        }
        try queue.close()
        let base = ["run", "--config", config, "--prompt", "do work", "--alias", "loop"]
        let withoutFlag = try Self.run(base, env: Self.environment(stateDir: stateDir))
        #expect(withoutFlag.exit == 6, "unreadable ledger fails closed, got \(withoutFlag.exit)")
        let withFlag = try Self.run(
            base + ["--acknowledge-unresolved-outcomes", "operator-accepted-risk"],
            env: Self.environment(stateDir: stateDir))
        #expect(withFlag.exit == 6, "acknowledgment cannot cure corruption, got \(withFlag.exit)")
        #expect(server.connectionCount == 0, "no provider traffic on corrupt ledgers")
        #expect(server.requests.isEmpty)
    }

    @Test("B5-B CLI clean store is unaffected: no ack, run completes")
    func cliCleanStoreUnaffected() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("clean").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "fresh work", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "clean store runs complete, got \(result.exit): \(result.stderr)")
        let sessions = try Self.storeSessions(at: stateDir)
        #expect(sessions.count == 1, "empty store bootstrap opens exactly one session")
        #expect(try Self.acknowledgments(at: stateDir, session: sessions[0]).isEmpty,
                "no acknowledgment is recorded when the gate is clean")
    }

    @Test("B5-B CLI cross-workspace block: dirt from one workspace blocks another")
    func cliCrossWorkspaceBlock() throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        let otherWorkspace = directory.appendingPathComponent("other-ws")
        try FileManager.default.createDirectory(at: otherWorkspace, withIntermediateDirectories: true)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "other work", "--alias", "loop",
             "--workspace", otherWorkspace.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 3, "store-wide gate blocks regardless of workspace, got \(result.exit)")
        #expect(result.stderr.contains("s-prior"))
        #expect(server.connectionCount == 0)
    }

    @Test("B5-B CLI manually-reconciled determination records the note")
    func cliManuallyReconciledNote() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("ok").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "do work", "--alias", "loop",
             "--acknowledge-unresolved-outcomes", "manually-reconciled:ops-verified-by-hand"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "noted acknowledgment proceeds, got \(result.exit): \(result.stderr)")
        let sessions = try Self.storeSessions(at: stateDir)
        let newSession = try #require(sessions.first(where: { $0 != "s-prior" }))
        let acks = try Self.acknowledgments(at: stateDir, session: newSession)
        #expect(acks.count == 1)
        #expect(acks[0].determination == "manually-reconciled:ops-verified-by-hand")
    }

    @Test("B5-B CLI second run without flag is blocked again (no-consumption)")
    func cliNoConsumptionAcrossRuns() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("first").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Self.seedDirtyStore(at: stateDir)
        // Run 1: authorized, completes.
        let first = try Self.run(
            ["run", "--config", config, "--prompt", "first", "--alias", "loop",
             "--acknowledge-unresolved-outcomes", "operator-accepted-risk"],
            env: Self.environment(stateDir: stateDir))
        #expect(first.exit == 0, "first authorized run completes: \(first.stderr)")
        // Run 2: no flag → blocked AGAIN on the same historical hold.
        let second = try Self.run(
            ["run", "--config", config, "--prompt", "second", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(second.exit == 3, "the prior acknowledgment exempts nothing, got \(second.exit)")
        #expect(second.stderr.contains("s-prior"))
    }
}
