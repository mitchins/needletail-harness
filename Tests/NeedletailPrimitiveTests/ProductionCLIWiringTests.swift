import Testing
import Foundation
import GRDB
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A5-1 production CLI wiring evidence: the REAL `needletail run`
/// binary against a synthetic loopback provider, asserting durable
/// state in the REAL GRDB store. No mocks of the store, no
/// test-target doubles — every record below was committed by the
/// shipped product through the production seam.
struct ProductionCLIWiringTests {

    private static func binary() throws -> String {
        // NEEDLETAIL_BIN (dev/CI explicit) wins; otherwise resolve the
        // product beside THIS test runner — the executable-target edge
        // guarantees it was built fresh from the same revision, whatever
        // the build configuration or scratch path is. The legacy
        // .build/debug fallback remains for hand-invoked runs.
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

    private static func environmentWithout(keys: Set<String>) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in keys { env.removeValue(forKey: key) }
        env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
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
        // Signal deaths must never masquerade as exit codes: a crashed
        // child (e.g. an un-shut-down HTTP client fatalErroring in deinit)
        // fails loudly here instead of matching an expected code.
        if process.terminationReason == .uncaughtSignal {
            Issue.record("child binary died from signal \(process.terminationStatus): \(String(decoding: errBox.value, as: UTF8.self).prefix(300))")
            throw WiringError.childCrashed(process.terminationStatus)
        }
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    /// Minimal final text chunk (mirrors the CannedTurn shape the
    /// provider tests use): assistant text + stop + usage + [DONE].
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

    private static func sessions(in dbPath: String) throws -> [String] {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session FROM records")
        }
    }

    private static func writerHolders(dbPath: String) throws -> [String] {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT writer FROM writer")
        }
    }

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func posixMode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    @Test("A5-1 cli run persists session epoch transcript to production store")
    func runPersistsSessionEpochTranscript() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("all done").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "headless run completes: \(result.stderr)")
        // stdout is pure JSONL: every line parses, no diagnostic pollution.
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(!envelopes.isEmpty, "run emits JSONL envelopes")
        #expect(envelopes.contains { ($0["kind"] as? String) == "run_finished" && (($0["payload"] as? [String: Any])?["outcome"] as? String) == "completed" },
                "terminal envelope reports completion")
        // Private state location with private modes.
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        #expect(FileManager.default.fileExists(atPath: dbPath), "durable store file exists")
        #expect(try Self.posixMode(stateDir.path) == 0o700, "state directory is private")
        #expect(try Self.posixMode(dbPath) == 0o600, "database file is private")
        let walURL = URL(fileURLWithPath: dbPath + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            #expect(try Self.posixMode(walURL.path) == 0o600, "WAL file is private")
        }
        // No artifacts root: nothing published, nothing created.
        let entries = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        #expect(!entries.contains { $0.hasSuffix("-artifacts") }, "no artifacts root without publications")
        // Fresh-handle read-back: exactly one session, identities first,
        // then the transcript of this run.
        let sessions = try Self.sessions(in: dbPath)
        let sessionID = try #require(sessions.first, "exactly this run's session must exist, got \(sessions)")
        #expect(sessions.count == 1)
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (page, _) = try store.records(session: SessionID(sessionID), since: 0, limit: 1000)
        let kinds = page.map(\.record)
        // Identity rows come FIRST: nothing provider- or tool-driven may
        // precede them, so the run is identifiable even if it dies next.
        if case .sessionOpened(let openedSession, _) = kinds.first {
            #expect(openedSession.raw == sessionID, "sessionOpened names this run's session")
        } else {
            Issue.record("first durable record must be sessionOpened, got \(String(describing: kinds.first))")
        }
        if kinds.count > 1, case .epochOpened(let openedEpoch) = kinds[1] {
            #expect(openedEpoch.epochID.raw.hasPrefix("epoch-run-"), "epochOpened follows")
        } else {
            Issue.record("second durable record must be epochOpened")
        }
        #expect(kinds.contains { if case .sessionOpened = $0 { return true }; return false },
                "session identity persisted before provider work")
        #expect(kinds.contains { if case .epochOpened = $0 { return true }; return false },
                "epoch identity persisted before provider work")
        let texts = kinds.compactMap { record -> String? in
            if case .transcriptAppended(.user(let text)) = record { return text }
            return nil
        }
        #expect(texts.contains("hello"), "operator prompt durable")
        let answers = kinds.compactMap { record -> String? in
            if case .transcriptAppended(.assistantText(let text)) = record { return text }
            return nil
        }
        #expect(answers.contains("all done"), "final answer durable")
        // Clean completion released the claim: no writer row remains.
        #expect(try Self.writerHolders(dbPath: dbPath).isEmpty,
                "proven-clean run releases its ownership claim")
        // Post-hoc fencing: the released session refuses foreign writers —
        // identity rows were committed through the fenced path.
        #expect(throws: StoreError.notWriter(session: sessionID, writer: "intruder")) {
            try store.append(.transcriptAppended(.user("intrusion")),
                             as: WriterIdentity(session: SessionID(sessionID), writer: "intruder"))
        }
        // And the session reconciles clean.
        let report = try store.reconcile(session: SessionID(sessionID))
        #expect(report.heldOperations.isEmpty && report.completed.isEmpty,
                "text-only run holds nothing and completes nothing operational")
    }

    @Test("A5-1 cli refuses corrupt store without overwrite")
    func refusesCorruptStoreWithoutOverwrite() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDir = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let garbage = Data("not a database".utf8)
        try garbage.write(to: URL(fileURLWithPath: dbPath))
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("unused").utf8))]))
        server.start()
        defer { server.stop() }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 6, "corrupt store fails closed with integrity exit, got \(result.exit): \(result.stderr.prefix(300))")
        #expect(result.stderr.lowercased().contains("store"), "honest store diagnostic, got: \(result.stderr.prefix(300))")
        #expect(try Data(contentsOf: URL(fileURLWithPath: dbPath)) == garbage,
                "incompatible store is never overwritten")
        #expect(!FileManager.default.fileExists(atPath: dbPath + "-wal"),
                "no WAL sidecar for a store that never opened")
        // No completion is reported on the failed start.
        if let envelopes = try? Self.jsonLines(result.stdout), !envelopes.isEmpty {
            #expect(!envelopes.contains { ($0["outcome"] as? String) == "completed" },
                    "no completion claimed when durable start failed")
        }
    }

    @Test("A5-1 cli provider failure reports without completion")
    func providerFailureReportsWithoutCompletion() throws {
        // Mid-stream abort classifies as postContent (provider failure),
        // never as unknown: NET-05 pins that postContent arms no retry
        // and records no unknown marker. The CLI must surface the failure
        // honestly — exit 4, no completion envelope, no success claim —
        // while the failed run's claim row is retained, not auto-released.
        // (Genuine unknown-outcome holds are qualified natively: the A4-2
        // kill matrix proves them through real SIGKILL reopen; no
        // loopback stimulus can produce an unclassifiable transport
        // error, by taxonomy design.)
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(
            chunks: [ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n".utf8))],
            abortAfterChunks: 1))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 4, "classified provider failure, got \(result.exit): \(result.stderr.prefix(300))")
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(envelopes.contains { ($0["kind"] as? String) == "run_finished" && (($0["payload"] as? [String: Any])?["outcome"] as? String) == "provider_error" },
                "terminal envelope reports provider failure")
        #expect(!envelopes.contains { (($0["payload"] as? [String: Any])?["outcome"] as? String) == "completed" },
                "no completion claimed when the durable result failed")
        // Failed before any dispatch: clean reconcile, but the claim row
        // is retained (only proven-clean runs release).
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let sessions = try Self.sessions(in: dbPath)
        let oneSession = try #require(sessions.first, "fresh run must have exactly one session")
        #expect(sessions.count == 1)
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let report = try store.reconcile(session: SessionID(oneSession))
        #expect(report.heldOperations.isEmpty && report.completed.isEmpty,
                "classified failure records no unknown and completes nothing")
        #expect(try Self.writerHolders(dbPath: dbPath).count == 1,
                "failed run keeps its ownership claim")
    }

    @Test("A5-1 cli sealed run leaves no persistent store")
    func sealedRunLeavesNoPersistentStore() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("sealed answer").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop", "--sealed"],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "sealed text run completes: \(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: stateDir.path),
                "sealed runs create no state directory at all")
    }

    @Test("A5-1 cli denied tool fails the run without completion")
    func deniedToolFailsRunWithoutCompletion() throws {
        // Workspace headless policy denies ungranted mutating tools at
        // validation (I05), before any dispatch or approval: the denial
        // joins the transcript as a typed receipt, and the run then fails
        // on script exhaustion with exit 4 and provider_error — never a
        // completion, never a silent drop. (The exit-3 approval path
        // exists for non-headless gateways; headless never approves, so
        // the shutdown paired with its throw is defense-in-depth.)
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.toolCallChunk(callID: "c1", tool: "edit", arguments: "{\"path\":\"f\"}").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "edit it", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        let envelopes = try Self.jsonLines(result.stdout)
        #expect(result.exit == 4, "denied tooling exhausts the script into provider failure, got \(result.exit)")
        #expect(envelopes.contains { (($0["payload"] as? [String: Any])?["outcome"] as? String) == "provider_error" },
                "terminal envelope reports provider_error")
        #expect(!envelopes.contains { (($0["payload"] as? [String: Any])?["outcome"] as? String) == "completed" },
                "no completion on a denied run")
        // The denied run holds no operation (validation refused dispatch)
        // but keeps its claim: the pending approval decision is explicit
        // operator business for a non-headless gateway.
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let sessions = try Self.sessions(in: dbPath)
        let oneSession = try #require(sessions.first, "fresh run must have exactly one session")
        #expect(sessions.count == 1)
        let (allRows, _) = try store.records(session: SessionID(oneSession), since: 0, limit: 1000)
        #expect(allRows.contains {
            if case .transcriptAppended(.toolResponse(_, let text)) = $0.record {
                return text.hasPrefix("denied:")
            }
            return false
        }, "typed denial receipt is durable in the transcript")
        let report = try store.reconcile(session: SessionID(oneSession))
        #expect(report.heldOperations.isEmpty && report.completed.isEmpty)
        #expect(try Self.writerHolders(dbPath: dbPath).count == 1,
                "denied run retains its claim")
    }

    @Test("A5-1 cli killed run retains claim and ledger for new run")
    func killedRunRetainsClaimAndLedger() throws {
        // The loopback server writes paced chunks on its own thread; when
        // the child dies mid-stream the next write would raise SIGPIPE and
        // kill THIS test process by default disposition — exactly why the
        // CLI itself ignores SIGPIPE (RunCommand). Ignore it for the kill
        // window only, then restore.
        signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, SIG_DFL) }
        let server = try LoopbackSSEServer()
        // Slow drip keeps the run alive for the kill window.
        var paced: [ScriptChunk] = []
        for i in 0..<8 {
            paced.append(ScriptChunk(
                bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"tok\(i) \"}}]}\n\n".utf8),
                delayMillis: 400))
        }
        paced.append(ScriptChunk(bytes: Array(Self.finalText("finished").utf8)))
        server.enqueue(SSEScript(chunks: paced))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let dbPath = stateDir.appendingPathComponent("store.sqlite").path
        // Spawn the real binary (no waiting): poll for the first
        // committed row, then SIGKILL mid-run.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.binary())
        process.arguments = ["run", "--config", config, "--prompt", "hello",
                             "--format", "jsonl", "--alias", "loop"]
        process.environment = Self.environment(stateDir: stateDir)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            var status: Int32 = 0
            let stop = Date().addingTimeInterval(10)
            while process.isRunning, Date() < stop {
                if waitpid(process.processIdentifier, &status, WNOHANG) != 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // Bounded poll: proceed only once durable rows exist.
        let stop = Date().addingTimeInterval(60)
        var committed = 0
        while Date() < stop {
            if let db = try? DatabaseQueue(path: dbPath),
               let count = try? db.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records") ?? 0 }),
               count > 0 {
                try? db.close()
                committed = count
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(committed > 0, "kill lands only after durable rows exist")
        #expect(process.isRunning, "child still mid-run when killed")
        kill(process.processIdentifier, SIGKILL)
        let reapStop = Date().addingTimeInterval(10)
        var status: Int32 = 0
        while process.isRunning, Date() < reapStop {
            if waitpid(process.processIdentifier, &status, WNOHANG) != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!process.isRunning, "killed child reaped")
        // Ledger prefix intact; claim row retained (never discarded).
        let survivors = try GRDBSessionStore(path: dbPath)
        defer { try? survivors.close() }
        let (kept, _) = try survivors.records(session: SessionID(try Self.sessions(in: dbPath)[0]), since: 0, limit: 100_000)
        #expect(kept.count >= committed, "no committed row lost to the kill")
        #expect(try Self.writerHolders(dbPath: dbPath).count == 1,
                "interrupted run keeps its ownership claim")
        let retained = try Self.writerHolders(dbPath: dbPath)
        // A new run on the same file works and leaves the old rows alone.
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("second").utf8))]))
        let again = try Self.run(
            ["run", "--config", config, "--prompt", "second hello", "--format", "jsonl", "--alias", "loop"],
            env: Self.environment(stateDir: stateDir))
        #expect(again.exit == 0, "store stays writable after a kill: \(again.stderr.prefix(300))")
        #expect(try Self.sessions(in: dbPath).count == 2, "old session retained alongside the new one")
        // The killed run's claim is still there (never silently
        // discarded, never taken over); the clean second run released its
        // own claim at its proven-clean boundary.
        #expect(try Self.writerHolders(dbPath: dbPath) == retained,
                "retention + clean-release, not takeover")
    }

    @Test("A5-1 cli state directory resolution and repair")
    func stateDirectoryResolutionAndRepair() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("x").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let args = ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop"]

        // A path pointing at a regular FILE is not a usable directory —
        // deterministic for every user (unlike permission bits under root):
        // establishment fails closed with exit 4.
        let fileAsDir = directory.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: fileAsDir)
        let blocked = try Self.run(args, env: Self.environment(stateDir: fileAsDir))
        #expect(blocked.exit == 4, "file-as-state-dir fails closed, got \(blocked.exit)")

        // XDG_DATA_HOME is honored when no override is set.
        var xdgEnv = Self.environmentWithout(keys: ["NEEDLETAIL_STATE_DIR"])
        let xdgHome = directory.appendingPathComponent("xdg")
        xdgEnv["XDG_DATA_HOME"] = xdgHome.path
        xdgEnv.removeValue(forKey: "HOME")
        let xdgRun = try Self.run(args, env: xdgEnv)
        #expect(xdgRun.exit == 0, "XDG state home works: \(xdgRun.stderr.prefix(200))")
        #expect(FileManager.default.fileExists(
            atPath: xdgHome.appendingPathComponent("needletail/store.sqlite").path),
                "store lands under $XDG_DATA_HOME/needletail")

        // No HOME, no XDG, no override: fail closed, never scatter state.
        let noHomeEnv = Self.environmentWithout(
            keys: ["NEEDLETAIL_STATE_DIR", "XDG_DATA_HOME", "HOME"])
        let noHome = try Self.run(args, env: noHomeEnv)
        #expect(noHome.exit == 2, "missing state home fails closed, got \(noHome.exit)")

        // Pre-existing lax modes are repaired, then the run succeeds.
        let laxDir = directory.appendingPathComponent("lax")
        try FileManager.default.createDirectory(at: laxDir, withIntermediateDirectories: true)
        let laxDB = laxDir.appendingPathComponent("store.sqlite").path
        do {
            let seed = try GRDBSessionStore(path: laxDB)
            try seed.close()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: laxDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: laxDB)
        var laxEnv = Self.environment(stateDir: laxDir)
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("ok").utf8))]))
        let repaired = try Self.run(args, env: laxEnv)
        #expect(repaired.exit == 0, "repaired state dir runs: \(repaired.stderr.prefix(200))")
        #expect(try Self.posixMode(laxDir.path) == 0o700, "directory repaired private")
        #expect(try Self.posixMode(laxDB) == 0o600, "database repaired private")

        // Override wins over XDG when both are set: the store lands under
        // the override and nothing is created under XDG (distinct paths
        // per sub-case so earlier runs cannot pollute this assertion).
        let overrideDir = directory.appendingPathComponent("override-state")
        let xdgBase = directory.appendingPathComponent("xdg-other")
        var bothEnv = Self.environment(stateDir: overrideDir)
        bothEnv["XDG_DATA_HOME"] = xdgBase.path
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("ok").utf8))]))
        let overridden = try Self.run(args, env: bothEnv)
        #expect(overridden.exit == 0, "override run works: \(overridden.stderr.prefix(200))")
        #expect(FileManager.default.fileExists(
            atPath: overrideDir.appendingPathComponent("store.sqlite").path),
                "store lands under $NEEDLETAIL_STATE_DIR")
        #expect(!FileManager.default.fileExists(atPath: xdgBase.appendingPathComponent("needletail").path),
                "XDG location untouched when the override is set")
    }

    @Test("A5-1 cli sealed trace stays private and storeless")
    func sealedTraceStaysPrivateAndStoreless() throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(Self.finalText("sealed answer").utf8))]))
        server.start()
        defer { server.stop() }
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Self.writeConfig(directory, port: Int(server.port))
        let stateDir = directory.appendingPathComponent("state")
        let traceURL = directory.appendingPathComponent("trace.jsonl")
        let result = try Self.run(
            ["run", "--config", config, "--prompt", "hello", "--format", "jsonl", "--alias", "loop",
             "--sealed", "--trace", traceURL.path],
            env: Self.environment(stateDir: stateDir))
        #expect(result.exit == 0, "sealed run completes: \(result.stderr.prefix(200))")
        #expect(FileManager.default.fileExists(atPath: traceURL.path), "explicit trace file is written")
        #expect(try Self.posixMode(traceURL.path) == 0o600, "operator-requested trace is private")
        #expect(!FileManager.default.fileExists(atPath: stateDir.path),
                "sealed runs create no state directory at all")
    }
}

private enum WiringError: Error {
    case missingBinary
    case unparseableStdout
    case childCrashed(Int32)
}
