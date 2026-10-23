import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B2 closure corrections: deterministic native regressions for the six
/// required fixes (FD-preserved search launch, bounded drain, genuine
/// poisoned env, read fidelity, JSON path classification, rg qualification).
@Suite(.serialized)
struct B2ClosureTests {
    private static func tempParent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b2closure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func locateRg() -> String? {
        for p in ["/usr/bin/rg", "/usr/local/bin/rg"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func makeReservation(batch: ToolBatch, approved: [String] = []) -> EffectReservation {
        EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: approved)
    }

    /// Direct ripgrep invocation (pathname-based, caller-chosen env) for
    /// counterfactuals: shows what the UNSAFE path would do.
    private static func runDirectRg(_ rg: String, args: [String], env: [String: String]? = nil) throws -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rg)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return (String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }

    /// Wrapper executable used as rgPath: serves --version directly, otherwise
    /// signals launch (validation + FD acquisition already done by then),
    /// sleeps to open a deterministic replacement window, then execs real rg.
    private static func makeRaceWrapper(realRg: String, signalPath: String, in dir: URL, name: String) throws -> URL {
        let w = dir.appendingPathComponent(name)
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  exec \(realRg) --version\nfi\ntouch \(signalPath)\nsleep 2\nexec \(realRg) \"$@\"\n"
        try script.write(to: w, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.path)
        return w
    }

    private static func waitForFile(_ path: String, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    // MARK: - 1. Explicit search-root replacement between validation and launch

    @Test("CLOSURE_01_explicitRootRace")
    func explicitRootRace() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let scope = ws.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try "hello scope\n".write(to: scope.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try "SENTINEL_OUTSIDE_1\n".write(to: outside.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
        let signal = parent.appendingPathComponent("sig1").path
        let wrapper = try Self.makeRaceWrapper(realRg: realRg, signalPath: signal, in: parent, name: "wrap1.sh")
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: wrapper.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello scope|SENTINEL_OUTSIDE_1\",\"path\":\"scope\"}")])
        let res = Self.makeReservation(batch: batch)
        async let pending = exec.execute(batch: batch, reservation: res)
        let launched = await Self.waitForFile(signal)
        #expect(launched, "wrapper must signal rg launch (validation already complete)")
        // Deterministic replacement AFTER validation+FD acquisition, BEFORE rg traversal.
        try FileManager.default.moveItem(at: scope, to: parent.appendingPathComponent("scope.orig"))
        try FileManager.default.createSymbolicLink(at: scope, withDestinationURL: outside)
        let outcome = try await pending
        #expect(outcome.calls[0].status == "success", "FD-pinned search must succeed, got \(outcome.calls[0])")
        #expect(outcome.calls[0].truncated == false)
        #expect(outcome.calls[0].data.contains("hello scope"), "original content must be found via held FD")
        #expect(!outcome.calls[0].data.contains("SENTINEL_OUTSIDE_1"), "outside sentinel must never be read")
        // Counterfactual: the same replacement IS visible through a pathname launch.
        let (direct, _) = try Self.runDirectRg(realRg, args: ["SENTINEL_OUTSIDE_1", scope.path])
        #expect(direct.contains("SENTINEL_OUTSIDE_1"), "counterfactual: pathname launch reads the sentinel")
        try? FileManager.default.removeItem(at: scope)
        try? FileManager.default.moveItem(at: parent.appendingPathComponent("scope.orig"), to: scope)
    }

    // MARK: - 2. Workspace-root replacement when searching without explicit path

    @Test("CLOSURE_02_workspaceRootRace")
    func workspaceRootRace() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer {
            let ws = parent.appendingPathComponent("ws")
            let orig = parent.appendingPathComponent("ws.orig")
            if FileManager.default.fileExists(atPath: orig.path) {
                try? FileManager.default.removeItem(at: ws)
                try? FileManager.default.moveItem(at: orig, to: ws)
            }
            try? FileManager.default.removeItem(at: parent)
        }
        let ws = parent.appendingPathComponent("ws")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "hello root\n".write(to: ws.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try "SENTINEL_OUTSIDE_2\n".write(to: outside.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
        let signal = parent.appendingPathComponent("sig2").path
        let wrapper = try Self.makeRaceWrapper(realRg: realRg, signalPath: signal, in: parent, name: "wrap2.sh")
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: wrapper.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello root|SENTINEL_OUTSIDE_2\"}")])
        let res = Self.makeReservation(batch: batch)
        async let pending = exec.execute(batch: batch, reservation: res)
        let launched = await Self.waitForFile(signal)
        #expect(launched, "wrapper must signal rg launch")
        try FileManager.default.moveItem(at: ws, to: parent.appendingPathComponent("ws.orig"))
        try FileManager.default.createSymbolicLink(at: ws, withDestinationURL: outside)
        let outcome = try await pending
        #expect(outcome.calls[0].status == "success", "FD-pinned search must succeed, got \(outcome.calls[0])")
        #expect(outcome.calls[0].data.contains("hello root"), "original workspace must be searched via held FD")
        #expect(!outcome.calls[0].data.contains("SENTINEL_OUTSIDE_2"), "outside sentinel must never be read")
        let (direct, _) = try Self.runDirectRg(realRg, args: ["SENTINEL_OUTSIDE_2", ws.path])
        #expect(direct.contains("SENTINEL_OUTSIDE_2"), "counterfactual: pathname launch reads the sentinel")
    }

    // MARK: - 3. Genuine poisoned environment + PATH shadowing
    // (Process-global setenv; benign per the note in TOOL_03_poisonedEnv —
    // the executor ignores the parent environment entirely.)

    @Test("CLOSURE_03_poisonedEnvReal")
    func poisonedEnvReal() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello world\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // Poison kit: fake rg shadowing PATH + preprocessor config stamping PRE_POISON.
        let fakeDir = parent.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let fakeRg = fakeDir.appendingPathComponent("rg")
        try "#!/bin/sh\necho 'FAKE_RG_USED'\nexit 0\n".write(to: fakeRg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRg.path)
        let evilPre = fakeDir.appendingPathComponent("evil-pre.sh")
        try "#!/bin/sh\necho PRE_POISON_XYZ\ncat \"$1\"\n".write(to: evilPre, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evilPre.path)
        let poisonRC = fakeDir.appendingPathComponent("poison.rc")
        try "--pre=\(evilPre.path)\n".write(to: poisonRC, atomically: true, encoding: .utf8)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        let oldRC = getenv("RIPGREP_CONFIG_PATH").map { String(cString: $0) }
        let oldRC2 = getenv("RIPGREP_CONFIG").map { String(cString: $0) }
        setenv("PATH", "\(fakeDir.path):\(oldPath ?? "/usr/bin:/bin")", 1)
        setenv("RIPGREP_CONFIG_PATH", poisonRC.path, 1)
        setenv("RIPGREP_CONFIG", poisonRC.path, 1)
        defer {
            if let v = oldPath { setenv("PATH", v, 1) } else { unsetenv("PATH") }
            if let v = oldRC { setenv("RIPGREP_CONFIG_PATH", v, 1) } else { unsetenv("RIPGREP_CONFIG_PATH") }
            if let v = oldRC2 { setenv("RIPGREP_CONFIG", v, 1) } else { unsetenv("RIPGREP_CONFIG") }
        }
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        // Real pattern still found; neither poison mechanism leaks in.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "sanitized search must succeed, got \(result.calls[0])")
        #expect(result.calls[0].data.contains("hello world"))
        #expect(!result.calls[0].data.contains("FAKE_RG_USED"), "PATH-shadowing fake must not run")
        #expect(!result.calls[0].data.contains("PRE_POISON_XYZ"), "poisoned preprocessor must not apply")
        // Preprocessor-stamped output must not be searchable through the executor.
        let batchPre = ToolBatch([ToolProposal(callID: "c2", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"PRE_POISON_XYZ\"}")])
        let resultPre = try await exec.execute(batch: batchPre, reservation: Self.makeReservation(batch: batchPre))
        #expect(resultPre.calls[0].status == "success")
        #expect(!resultPre.calls[0].data.contains("PRE_POISON_XYZ"), "preprocessor output must not be searchable")
        // Counterfactuals: the SAME poison is effective when the environment is inherited.
        var poisonEnv = ProcessInfo.processInfo.environment
        poisonEnv["RIPGREP_CONFIG_PATH"] = poisonRC.path
        let (directPre, _) = try Self.runDirectRg(realRg, args: ["--json", "PRE_POISON_XYZ", ws.path], env: poisonEnv)
        #expect(directPre.contains("PRE_POISON_XYZ"), "counterfactual: inherited config poison stamps output")
        let (shadowed, _) = try Self.runDirectRg("/bin/sh", args: ["-c", "rg --version"], env: ["PATH": "\(fakeDir.path):/usr/bin:/bin"])
        #expect(shadowed.contains("FAKE_RG_USED"), "counterfactual: poisoned PATH shadows naive lookup")
    }

    // MARK: - 4. Multi-megabyte output stays bounded

    @Test("CLOSURE_04_searchBounded")
    func searchBounded() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let line = "hello world padding padding padding padding\n"
        for i in 0..<200 {
            var big = ""
            big.reserveCapacity(400 * line.utf8.count)
            for _ in 0..<400 { big += line }
            try big.write(to: ws.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "bounded search must succeed, got \(result.calls[0])")
        #expect(result.calls[0].truncated == true, "multi-MB output must report truncation")
        #expect(result.calls[0].data.utf8.count <= 1 * 1024 * 1024, "output must respect the 1 MiB bound, got \(result.calls[0].data.utf8.count)")
        #expect(result.calls[0].data.contains("hello"), "capped output must still contain matches")
    }

    // MARK: - 5. Read fidelity: exact bytes, byte budget, truthful hash

    @Test("CLOSURE_05_readFidelity")
    func readFidelity() async throws {
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello\n".write(to: ws.appendingPathComponent("exact.txt"), atomically: true, encoding: .utf8)
        try "a\nb\n".write(to: ws.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try "a\nb\nc\n".write(to: ws.appendingPathComponent("three.txt"), atomically: true, encoding: .utf8)
        try "".write(to: ws.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
        let longLine = String(repeating: "x", count: 2 * 1024 * 1024)
        try longLine.write(to: ws.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        func read(_ args: String) async throws -> ToolCallOutcome {
            let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: args)])
            let r = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
            return r.calls[0]
        }
        let exact = try await read("{\"path\":\"exact.txt\"}")
        #expect(exact.status == "success")
        #expect(exact.data == "hello\n", "terminal newline must be preserved exactly, got \(exact.data.debugDescription)")
        #expect(exact.truncated == false)
        #expect(exact.beforeHash == SHA256.hash(data: Data("hello\n".utf8)).map { String(format: "%02x", $0) }.joined(), "SHA must cover exact file bytes")
        let two = try await read("{\"path\":\"two.txt\",\"limit\":10}")
        #expect(two.data == "a\nb\n")
        #expect(two.truncated == false)
        let slice = try await read("{\"path\":\"three.txt\",\"offset\":1,\"limit\":1}")
        #expect(slice.data == "b\n", "offset slice must be exact bytes, got \(slice.data.debugDescription)")
        #expect(slice.truncated == true, "omitted trailing content must set truncation")
        let empty = try await read("{\"path\":\"empty.txt\"}")
        #expect(empty.status == "success" && empty.data == "" && empty.truncated == false)
        let beyond = try await read("{\"path\":\"three.txt\",\"offset\":10}")
        #expect(beyond.status == "success" && beyond.data == "" && beyond.truncated == false)
        let long = try await read("{\"path\":\"long.txt\"}")
        #expect(long.status == "success")
        #expect(long.truncated == true, "single 2 MiB line must trigger the result-byte budget")
        #expect(long.data.utf8.count <= 1 * 1024 * 1024, "returned bytes must respect the budget")
        #expect(long.beforeHash == SHA256.hash(data: Data(longLine.utf8)).map { String(format: "%02x", $0) }.joined(), "hash must cover the full file even when output is budgeted")
        // Exact budget boundaries (1 MiB cap): a final unterminated line is
        // charged its bytes only (no phantom newline).
        let cap = 1 * 1024 * 1024
        let fitLine = String(repeating: "y", count: cap - 1)
        try fitLine.write(to: ws.appendingPathComponent("fit.txt"), atomically: true, encoding: .utf8)
        let fit = try await read("{\"path\":\"fit.txt\"}")
        #expect(fit.status == "success" && fit.truncated == false, "cap-1 unterminated line fits exactly")
        #expect(fit.data == fitLine, "exactly-fitting line returned whole")
        let exactLine = String(repeating: "z", count: cap)
        try exactLine.write(to: ws.appendingPathComponent("exactcap.txt"), atomically: true, encoding: .utf8)
        let exactCap = try await read("{\"path\":\"exactcap.txt\"}")
        #expect(exactCap.status == "success" && exactCap.truncated == false, "cap-sized unterminated line fits (no phantom newline charge)")
        #expect(exactCap.data == exactLine)
        let overLine = String(repeating: "w", count: cap + 1)
        try overLine.write(to: ws.appendingPathComponent("over.txt"), atomically: true, encoding: .utf8)
        let over = try await read("{\"path\":\"over.txt\"}")
        #expect(over.status == "success" && over.truncated == true, "cap+1 line must truncate")
        #expect(over.data == "", "over-budget single line truncates to empty at the line boundary")
        let fitNL = String(repeating: "v", count: cap - 1) + "\n"
        try fitNL.write(to: ws.appendingPathComponent("fitnl.txt"), atomically: true, encoding: .utf8)
        let fitNLRead = try await read("{\"path\":\"fitnl.txt\"}")
        #expect(fitNLRead.status == "success" && fitNLRead.truncated == false && fitNLRead.data == fitNL, "cap-1 plus newline fits exactly")
    }

    // MARK: - 6. Protected pruning by parsed path, legit content preserved

    @Test("CLOSURE_06_protectedPrune")
    func protectedPrune() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        let ws = parent.appendingPathComponent("ws")
        let lockedDir = ws.appendingPathComponent(".git/locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let gitDir = ws.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "GIT_SENTINEL_111\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "GIT_HEAD_MARKER\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try "LOCKED_MARKER\n".write(to: lockedDir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        // Unreadable even to the owner: any traversal into locked/ fails the
        // whole rg run (exit 2). Precise approved targets never descend here.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
        try "ENV_SECRET_222=1\n".write(to: ws.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "my .env file mentions git config\n".write(to: ws.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "hello normal\n".write(to: ws.appendingPathComponent("normal.txt"), atomically: true, encoding: .utf8)
        let subDir = ws.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "SUB_SECRET=1\n".write(to: subDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "hello sub\n".write(to: subDir.appendingPathComponent("notes2.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        // Protected content pruned without approval — and summaries are
        // dropped by design (stats would aggregate over traversed files),
        // so a protected-only search returns exactly empty output.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"SENTINEL_111|SECRET_222\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success")
        #expect(!result.calls[0].data.contains("GIT_SENTINEL_111"), ".git content must be pruned")
        #expect(!result.calls[0].data.contains("ENV_SECRET_222"), ".env content must be pruned")
        #expect(result.calls[0].data.isEmpty, "protected-only search must return empty output (no summary oracle), got \(result.calls[0].data.prefix(200))")

        // Bare protected FILES (not directories): regular files named exactly
        // "credentials"/"artifacts" or ending "-artifacts" must be pruned
        // before traversal. If rg ever opened one, the 000 mode would fail
        // the run (exit 2); success with empty output proves pruning.
        let bareCred = ws.appendingPathComponent("credentials")
        try "BAREMARK=1\n".write(to: bareCred, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bareCred.path)
        let bareArt = ws.appendingPathComponent("artifacts")
        try "BAREMARK2=1\n".write(to: bareArt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bareArt.path)
        let bareSfx = ws.appendingPathComponent("x-artifacts")
        try "SFXMARK=1\n".write(to: bareSfx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bareSfx.path)
        let batchB = ToolBatch([ToolProposal(callID: "cb", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"BAREMARK|BAREMARK2|SFXMARK\"}")])
        let resultB = try await exec.execute(batch: batchB, reservation: Self.makeReservation(batch: batchB))
        #expect(resultB.calls[0].status == "success", "bare protected files must be pruned, got \(resultB.calls[0])")
        #expect(resultB.calls[0].data.isEmpty, "no output for pruned-only matches")
        for f in [bareCred, bareArt, bareSfx] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
        if getuid() != 0 {
            // Isolated trap workspace (no .git/locked confound): unpruned
            // rg must attempt the 000 files and fail the run.
            let trap = parent.appendingPathComponent("trap-ws")
            try FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
            let trapGit = trap.appendingPathComponent(".git")
            try "TRAPGIT=1\n".write(to: trapGit, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trapGit.path)
            let trapArt = trap.appendingPathComponent("artifacts")
            try "TRAPMARK=1\n".write(to: trapArt, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trapArt.path)
            let trapSfx = trap.appendingPathComponent("x-artifacts")
            try "TRAP2MARK=1\n".write(to: trapSfx, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trapSfx.path)
            let (_, trapStatus) = try Self.runDirectRg(realRg, args: ["--hidden", "--json", "TRAPMARK|TRAP2MARK", trap.path])
            #expect(trapStatus == 2, "counterfactual: unpruned open of 000 files fails, got \(trapStatus)")
            let (directGit, _) = try Self.runDirectRg(realRg, args: ["--hidden", "--json", "TRAPGIT", trap.path])
            #expect(directGit.contains("TRAPGIT"), "counterfactual: unpruned rg sees the bare .git file")
            // Executor search over the trap workspace: the bare .git file is
            // pruned before traversal (success, empty), even though it is
            // readable — no EACCES, no match.
            let trapResolver = try WorkspaceResolver(workspace: FilePath(trap.path), readRoots: [])
            let trapExec = NativeToolExecutor(resolver: trapResolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
            let trapBatch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"TRAPGIT\"}")])
            let trapResult = try await trapExec.execute(batch: trapBatch, reservation: Self.makeReservation(batch: trapBatch))
            #expect(trapResult.calls[0].status == "success", "bare .git file must be pruned, not read, got \(trapResult.calls[0])")
            #expect(trapResult.calls[0].data.isEmpty, "no output for pruned bare .git file")
            // Executor search over the 000 suffix files: bare-name globs
            // prune them before traversal (success, empty) rather than
            // failing on EACCES like unpruned rg does.
            let trapBatchSfx = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"TRAPMARK|TRAP2MARK\"}")])
            let trapResultSfx = try await trapExec.execute(batch: trapBatchSfx, reservation: Self.makeReservation(batch: trapBatchSfx))
            #expect(trapResultSfx.calls[0].status == "success", "bare artifact/suffix files must be pruned, got \(trapResultSfx.calls[0])")
            #expect(trapResultSfx.calls[0].data.isEmpty, "no output for pruned bare artifact files")
        }
        // Legitimate content merely MENTIONING .env/.git is preserved.
        let batch2 = ToolBatch([ToolProposal(callID: "c2", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"mentions\"}")])
        let result2 = try await exec.execute(batch: batch2, reservation: Self.makeReservation(batch: batch2))
        #expect(result2.calls[0].status == "success")
        #expect(result2.calls[0].data.contains("notes.txt"), "ordinary file must be searchable")
        #expect(result2.calls[0].data.contains(".env"), "legitimate .env mention in content must be preserved")
        // Sensitivity: the old whole-line substring filter would have dropped that line.
        if let notesLine = result2.calls[0].data.split(separator: "\n").map(String.init).first(where: { $0.contains("notes.txt") && $0.contains("\"type\":\"match\"") }) {
            let s = notesLine
            let oldKeeps: Bool = {
                if s.contains(".git/") || s.contains(".env") || s.contains(".ssh/") || s.contains(".needletail/") || s.contains("credentials") || s.contains("artifacts") {
                    if s.contains(".git") || s.contains(".env") || s.contains(".ssh") { return false }
                }
                return true
            }()
            #expect(!oldKeeps, "counterfactual: old substring filter would have dropped this legitimate line")
        } else {
            Issue.record("expected a notes.txt match line in output: \(result2.calls[0].data.prefix(300))")
        }
        // Counterfactual: without --hidden+--glob pruning, rg DOES see the protected files.
        let (direct, _) = try Self.runDirectRg(realRg, args: ["--hidden", "SENTINEL_111|SECRET_222", ws.path])
        #expect(direct.contains("GIT_SENTINEL_111") && direct.contains("ENV_SECRET_222"), "counterfactual: unpruned rg sees protected files")
        // Approval delivers the approved file itself via an exact FD target
        // (category globs stay fully armed): .env becomes visible, .git content
        // is never traversed.
        let batch4 = ToolBatch([ToolProposal(callID: "c4", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"SECRET_222|SENTINEL_111\"}")])
        let result4 = try await exec.execute(batch: batch4, reservation: Self.makeReservation(batch: batch4, approved: [".env"]))
        #expect(result4.calls[0].status == "success")
        #expect(result4.calls[0].data.contains("ENV_SECRET_222"), "approved grantable path must be visible")
        #expect(!result4.calls[0].data.contains("GIT_SENTINEL_111"), "unapproved grantable category must stay pruned")
        // Approving .git/config must not cause any other .git file to be
        // opened: traversal stays out (classifier as backstop, not the gate).
        // The locked/ subtree makes traversal observable: any descent into it
        // fails the whole rg run (exit 2 → failed), so success proves precise
        // access. The approved config itself is delivered via its own FD.
        let batch5 = ToolBatch([ToolProposal(callID: "c5", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"GIT_SENTINEL_111|GIT_HEAD_MARKER|LOCKED_MARKER\"}")])
        let result5 = try await exec.execute(batch: batch5, reservation: Self.makeReservation(batch: batch5, approved: [".git/config"]))
        #expect(result5.calls[0].status == "success", "precise approved access must not touch locked/, got \(result5.calls[0])")
        #expect(result5.calls[0].data.contains("GIT_SENTINEL_111"), "approved .git/config must be visible")
        #expect(!result5.calls[0].data.contains("GIT_HEAD_MARKER"), "unapproved .git/HEAD must not be visible")
        #expect(!result5.calls[0].data.contains("LOCKED_MARKER"), "locked subtree must never be read")
        // Covered-root grantable descendant (regression): explicit sub/ search
        // prunes .env via globs, so the approved sub/.env must arrive via its
        // own target — skipping it would be a fail-closed false negative.
        let batch6 = ToolBatch([ToolProposal(callID: "c6", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"SUB_SECRET|hello sub\",\"path\":\"sub\"}")])
        let result6 = try await exec.execute(batch: batch6, reservation: Self.makeReservation(batch: batch6, approved: ["sub/.env"]))
        #expect(result6.calls[0].status == "success", "approved grantable under explicit root must be visible, got \(result6.calls[0])")
        #expect(result6.calls[0].data.contains("SUB_SECRET"), "approved sub/.env visible despite glob pruning")
        #expect(result6.calls[0].data.contains("hello sub"), "unprotected subtree content still visible")
        // Read-root fallback: an approval absent from the workspace resolves
        // from the read root instead of vanishing.
        let ws2 = parent.appendingPathComponent("ws2")
        let rr = parent.appendingPathComponent("rr")
        try FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rr.appendingPathComponent("g"), withIntermediateDirectories: true)
        try "hello base\n".write(to: ws2.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try "RR_SECRET=1\n".write(to: rr.appendingPathComponent("g/.env"), atomically: true, encoding: .utf8)
        let resolver2 = try WorkspaceResolver(workspace: FilePath(ws2.path), readRoots: [FilePath(rr.path)])
        let exec2 = NativeToolExecutor(resolver: resolver2, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        let batch7 = ToolBatch([ToolProposal(callID: "c7", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"RR_SECRET|hello base\"}")])
        let result7 = try await exec2.execute(batch: batch7, reservation: Self.makeReservation(batch: batch7, approved: ["g/.env"]))
        #expect(result7.calls[0].status == "success", "read-root approval must resolve, got \(result7.calls[0])")
        #expect(result7.calls[0].data.contains("RR_SECRET"), "approved read-root grantable visible")
        #expect(result7.calls[0].data.contains("hello base"), "workspace content still visible")
        // Counterfactuals: without hidden-traversal rg never reaches the trap
        // (exit 1, skips dotfiles); with --hidden but no .git pruning it
        // descends into locked/ and the whole run fails (exit 2). The trap is
        // therefore sensitive exactly to traversal, which the executor never
        // performs for unapproved content.
        let (_, plainStatus) = try Self.runDirectRg(realRg, args: ["--json", "LOCKED_MARKER", ws.path])
        #expect(plainStatus == 1, "sanity: default rg skips hidden dirs, got \(plainStatus)")
        // Root bypasses permission bits, making the trap vacuous there; the
        // precise-access assertions above hold regardless (globs + classifier).
        if getuid() != 0 {
            let (_, hiddenStatus) = try Self.runDirectRg(realRg, args: ["--hidden", "--json", "LOCKED_MARKER", ws.path])
            #expect(hiddenStatus == 2, "counterfactual: unpruned traversal bites the trap, got \(hiddenStatus)")
        }
    }

    // MARK: - 10. Non-UTF-8 paths classified, never bypassed

    @Test("CLOSURE_10_nonUTF8Paths")
    func nonUTF8Paths() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let wsFD = ws.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        try #require(wsFD >= 0, "workspace must open")
        defer { close(wsFD) }
        func createRaw(_ name: [UInt8], under dirFD: Int32, content: String) throws {
            var cname = name + [0]
            let fd = cname.withUnsafeMutableBytes { ptr in
                openat(dirFD, ptr.baseAddress!.assumingMemoryBound(to: CChar.self), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o644))
            }
            try #require(fd >= 0, "raw file must create: \(name)")
            defer { close(fd) }
            let bytes = Array(content.utf8)
            var written = 0
            while written < bytes.count {
                let n = bytes.withUnsafeBufferPointer { ptr in
                    write(fd, ptr.baseAddress! + written, bytes.count - written)
                }
                try #require(n > 0, "raw file must write")
                written += n
            }
        }
        // .git/config (approved later) + .git/<0xFF> (must never leak).
        let gitDir = ws.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "cfg CONFIGMARK\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let gitFD = ".git".withCString { openat(wsFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        try #require(gitFD >= 0, ".git must open")
        defer { close(gitFD) }
        try createRaw([0x62, 0x61, 0x64, 0xFF, 0x6E, 0x61, 0x6D, 0x65], under: gitFD, content: "marker GHOSTMARK2\n")
        // Unprotected dir with a non-UTF-8 name stays searchable.
        try createRaw([0x74, 0x6F, 0x70, 0xFF, 0x2E, 0x74, 0x78, 0x74], under: wsFD, content: "top TOPMARK\n")
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        // Approving .git/config delivers it via its own FD (traversal never
        // relaxes): CONFIGMARK visible, GHOSTMARK2 (non-UTF-8 name inside
        // grantable, unapproved) dropped by the classifier.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"CONFIGMARK|GHOSTMARK2|TOPMARK\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch, approved: [".git/config"]))
        #expect(result.calls[0].status == "success", "bytes-path search must succeed, got \(result.calls[0])")
        #expect(result.calls[0].data.contains("CONFIGMARK"), "approved config visible")
        #expect(!result.calls[0].data.contains("GHOSTMARK2"), "non-UTF-8 path inside grantable must not bypass classification")
        #expect(result.calls[0].data.contains("TOPMARK"), "non-UTF-8 name in unprotected dir stays searchable")
        // Counterfactual: unpruned rg DOES see the ghost file via path.bytes.
        let (direct, _) = try Self.runDirectRg(realRg, args: ["--hidden", "--json", "GHOSTMARK2", ws.path])
        #expect(direct.contains("\"bytes\"") && direct.contains("GHOSTMARK2"), "counterfactual: raw rg reports the ghost via path.bytes")
        // U+FFFD approval collision: a literal-U+FFFD name and an invalid-byte
        // name share the same lossy skeleton; only the exact one approves.
        try "real REAL3MARK\n".write(to: gitDir.appendingPathComponent("README�"), atomically: true, encoding: .utf8)
        try createRaw([0x52, 0x45, 0x41, 0x44, 0x4D, 0x45, 0xFF], under: gitFD, content: "ghost GHOST3MARK\n")
        let approvedLiteral = ".git/README�"
        let batch2 = ToolBatch([ToolProposal(callID: "c2", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"REAL3MARK|GHOST3MARK\"}")])
        let result2 = try await exec.execute(batch: batch2, reservation: Self.makeReservation(batch: batch2, approved: [approvedLiteral]))
        #expect(result2.calls[0].status == "success", "collision search must succeed, got \(result2.calls[0])")
        #expect(result2.calls[0].data.contains("REAL3MARK"), "exact literal-U+FFFD approval must show its own file")
        #expect(!result2.calls[0].data.contains("GHOST3MARK"), "lossy skeleton must never satisfy an approval")
    }

    // MARK: - 7. Ripgrep qualification matrix

    @Test("CLOSURE_07_rgQualification")
    func rgQualification() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let bin = parent.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        func deniedBy(_ rg: String?) async throws -> ToolCallOutcome {
            let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: rg)
            let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
            let r = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
            return r.calls[0]
        }
        // Symlink executable.
        let link = bin.appendingPathComponent("rg-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: realRg))
        let rLink = try await deniedBy(link.path)
        #expect(rLink.status == "denied" && (rLink.summary.contains("symlink")), "symlinked rg must be denied, got \(rLink)")
        // Group-writable copy.
        let grpCopy = bin.appendingPathComponent("rg-grp")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: realRg), to: grpCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: grpCopy.path)
        let rGrp = try await deniedBy(grpCopy.path)
        #expect(rGrp.status == "denied" && rGrp.summary.contains("group-writable"), "group-writable rg must be denied, got \(rGrp)")
        // World-writable copy.
        let worldCopy = bin.appendingPathComponent("rg-world")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: realRg), to: worldCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: worldCopy.path)
        let rWorld = try await deniedBy(worldCopy.path)
        #expect(rWorld.status == "denied" && rWorld.summary.contains("world-writable"), "world-writable rg must be denied, got \(rWorld)")
        // Garbage version output (proves the probe executes and parses).
        let garbage = bin.appendingPathComponent("rg-garbage.sh")
        try "#!/bin/sh\necho 'not ripgrep at all'\nexit 0\n".write(to: garbage, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: garbage.path)
        let rGarbage = try await deniedBy(garbage.path)
        #expect(rGarbage.status == "denied" && rGarbage.summary.contains("unexpected output"), "garbage version must be denied, got \(rGarbage)")
        // Old version.
        let old = bin.appendingPathComponent("rg-old.sh")
        try "#!/bin/sh\necho 'ripgrep 12.1.0'\necho 'features:+pcre2'\nexit 0\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let rOld = try await deniedBy(old.path)
        #expect(rOld.status == "denied" && rOld.summary.contains("too old"), "old rg must be denied, got \(rOld)")
        // Non-executable.
        let noexec = bin.appendingPathComponent("rg-noexec.sh")
        try "#!/bin/sh\nexit 0\n".write(to: noexec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noexec.path)
        #expect(access(noexec.path, X_OK) != 0, "setup: file must lack exec permission")
        let rNoexec = try await deniedBy(noexec.path)
        #expect(rNoexec.status == "denied" && rNoexec.summary.contains("not executable"), "non-executable rg must be denied, got \(rNoexec)")
        // Non-absolute and nonexistent.
        let rRel = try await deniedBy("relative/rg")
        #expect(rRel.status == "denied" && rRel.summary.contains("absolute"), "relative rg path must be denied, got \(rRel)")
        let rMissing = try await deniedBy("/nonexistent/rg-xyz-123")
        #expect(rMissing.status == "denied" && rMissing.summary.contains("not found"), "missing rg must be denied, got \(rMissing)")
    }

    // MARK: - 8. Executable identity survives replacement during launch

    @Test("CLOSURE_08_rgExecIdentityRace")
    func rgExecIdentityRace() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello ident\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let signal = parent.appendingPathComponent("sig8").path
        let wrapper = try Self.makeRaceWrapper(realRg: realRg, signalPath: signal, in: parent, name: "wrap8.sh")
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: wrapper.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello ident|RG_EVIL_XYZ\"}")])
        let res = Self.makeReservation(batch: batch)
        async let pending = exec.execute(batch: batch, reservation: res)
        let launched = await Self.waitForFile(signal)
        #expect(launched, "wrapper must signal rg launch")
        // Replace the EXECUTABLE between qualification and traversal.
        try FileManager.default.moveItem(at: wrapper, to: parent.appendingPathComponent("wrap8.sh.orig"))
        try "#!/bin/sh\necho RG_EVIL_XYZ\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let outcome = try await pending
        #expect(outcome.calls[0].status == "success", "FD-held executable must survive replacement, got \(outcome.calls[0])")
        #expect(outcome.calls[0].data.contains("hello ident"), "real search must proceed via qualified inode")
        #expect(!outcome.calls[0].data.contains("RG_EVIL_XYZ"), "replaced executable must never run")
        // Counterfactual: the replaced file IS evil when launched by pathname.
        let (direct, _) = try Self.runDirectRg(wrapper.path, args: ["anything"])
        #expect(direct.contains("RG_EVIL_XYZ"), "counterfactual: replaced file runs evil by pathname")
        try? FileManager.default.removeItem(at: wrapper)
        try? FileManager.default.moveItem(at: parent.appendingPathComponent("wrap8.sh.orig"), to: wrapper)
    }

    // MARK: - 11. Sanitized environment proven by in-child probe

    @Test("CLOSURE_11_envSanitizationProbe")
    func envSanitizationProbe() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // Probe executable: passes the version gate, then reports the exact
        // environment it observes inside a fixed-shape match record whose
        // path is the argv root it was given (so classification passes).
        let probe = parent.appendingPathComponent("envprobe.sh")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\necho 'ripgrep 99.0.0'\necho 'features:none'\nexit 0\nfi\nlast=\"\"\nfor a in \"$@\"; do last=\"$a\"; done\nprintf '{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"%s/probe.txt\"},\"lines\":{\"text\":\"PATH=%s RC=%s HOME=%s\\\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[]}}\\n' \"$last\" \"$PATH\" \"${RIPGREP_CONFIG_PATH-unset}\" \"${HOME-unset}\"\n"
        try script.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        let poisonDir = parent.appendingPathComponent("poisonbin")
        try FileManager.default.createDirectory(at: poisonDir, withIntermediateDirectories: true)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        let oldRC = getenv("RIPGREP_CONFIG_PATH").map { String(cString: $0) }
        let oldHome = getenv("HOME").map { String(cString: $0) }
        setenv("PATH", "\(poisonDir.path):\(oldPath ?? "/usr/bin:/bin")", 1)
        setenv("RIPGREP_CONFIG_PATH", "/tmp/definitely-poisoned.rc", 1)
        setenv("HOME", "/tmp/poison-home", 1)
        defer {
            if let v = oldPath { setenv("PATH", v, 1) } else { unsetenv("PATH") }
            if let v = oldRC { setenv("RIPGREP_CONFIG_PATH", v, 1) } else { unsetenv("RIPGREP_CONFIG_PATH") }
            if let v = oldHome { setenv("HOME", v, 1) } else { unsetenv("HOME") }
        }
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: probe.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"anything\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "probe search must succeed, got \(result.calls[0])")
        #expect(result.calls[0].data.contains("PATH=/usr/bin:/bin"), "child must observe exactly the sanitized PATH, got \(result.calls[0].data.prefix(300))")
        #expect(result.calls[0].data.contains("RC=unset"), "RIPGREP_CONFIG_PATH must be absent in child")
        #expect(result.calls[0].data.contains("HOME=unset"), "HOME must be absent in child")
        #expect(!result.calls[0].data.contains(poisonDir.path), "poisoned PATH prefix must not leak into child")
        // Counterfactual: the same probe with inherited env observes poison.
        var poisonEnv = ProcessInfo.processInfo.environment
        poisonEnv["RIPGREP_CONFIG_PATH"] = "/tmp/definitely-poisoned.rc"
        let (direct, _) = try Self.runDirectRg(probe.path, args: ["anything", ws.path], env: poisonEnv)
        #expect(direct.contains("RC=/tmp/definitely-poisoned.rc"), "counterfactual: inherited env reaches an unsanitized child")
        _ = realRg
    }

    // MARK: - 12. Timeout is failure, never partial success

    @Test("CLOSURE_12_searchTimeout", .timeLimit(.minutes(2)))
    func searchTimeout() async throws {
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // Hanging probe: fast --version, then execs a 60 s sleep so SIGTERM
        // at the 30 s budget kills the direct child itself (no orphan).
        let hanging = parent.appendingPathComponent("hang.sh")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\necho 'ripgrep 99.0.0'\nexit 0\nfi\nexec sleep 60\n"
        try script.write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: hanging.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let start = Date()
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.calls[0].status == "failed", "timeout must be failure, got \(result.calls[0])")
        #expect(result.calls[0].summary.contains("timed out"), "timeout must be explicit, got \(result.calls[0])")
        #expect(elapsed < 60, "SIGTERM escalation must bound the wait, took \(elapsed)s")
        #expect(elapsed >= 25, "sanity: the 30 s budget must actually elapse, took \(elapsed)s")
    }

    // MARK: - 13. Concurrent bounded runners stay independent

    @Test("CLOSURE_13_concurrentRunners")
    func concurrentRunners() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let line = "hello concurrent padding padding\n"
        func makeWS(_ name: String) throws -> FilePath {
            let ws = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            for i in 0..<50 {
                var big = ""
                for _ in 0..<200 { big += line }
                try big.write(to: ws.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
            }
            return FilePath(ws.path)
        }
        let fpA = try makeWS("wsA")
        let fpB = try makeWS("wsB")
        let store = InMemorySessionStore()
        func runSearch(_ fp: FilePath) async throws -> ToolCallOutcome {
            let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
            let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
            let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
            return try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch)).calls[0]
        }
        async let a = runSearch(fpA)
        async let b = runSearch(fpB)
        let (ra, rb) = try await (a, b)
        for (i, r) in [ra, rb].enumerated() {
            #expect(r.status == "success", "concurrent runner \(i) must succeed, got \(r)")
            #expect(r.truncated == true, "concurrent runner \(i) output must be bounded")
            #expect(r.data.utf8.count <= 1 * 1024 * 1024, "concurrent runner \(i) respects the cap")
        }
        // FD ownership: repeated runs must not leak descriptors (each spawn
        // closes pipe ends, roots and rg FD exactly once). Sample /proc/self/fd
        // around sequential runs; transient cross-suite FDs are tolerated via
        // min-of-3, a leak would grow every window.
        #if canImport(Glibc)
        func fdCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? -1000
        }
        var deltas: [Int] = []
        for _ in 0..<3 {
            let before = fdCount()
            for _ in 0..<10 { _ = try await runSearch(fpA) }
            deltas.append(fdCount() - before)
        }
        #expect((deltas.min() ?? 999) <= 2, "FD count must be stable across runs, got deltas \(deltas)")
        #endif
    }

    // MARK: - 14. Hard stop never masks as success; siblings unaffected

    @Test("CLOSURE_14_hardStopNoMask", .timeLimit(.minutes(2)))
    func hardStopNoMask() async throws {
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello quick\n".write(to: ws.appendingPathComponent("q.txt"), atomically: true, encoding: .utf8)
        // Probe A: exits 0 immediately but leaves a background sleep holding
        // stdout open. Reaped exit-0 + unobservable EOF must be a timeout,
        // never success-with-partial.
        let leaver = parent.appendingPathComponent("leaver.sh")
        let leaverScript = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
            echo 'ripgrep 99.0.0'
            exit 0
            fi
            ( exec sleep 60 >&1 & )
            echo '{"type":"summary","data":{"stats":{}}}'
            exit 0
            """
        try leaverScript.write(to: leaver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leaver.path)
        // Probe B: hangs past the 30 s budget (SIGTERM must reap the execd sleep).
        let hanging = parent.appendingPathComponent("hang14.sh")
        let hangScript = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
            echo 'ripgrep 99.0.0'
            exit 0
            fi
            exec sleep 60
            """
        try hangScript.write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        func runSearch(rg: String, pattern: String) async throws -> ToolCallOutcome {
            let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: rg)
            let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"" + pattern + "\"}")])
            return try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch)).calls[0]
        }
        async let a = runSearch(rg: leaver.path, pattern: "hello")
        async let b = runSearch(rg: hanging.path, pattern: "hello")
        async let q = runSearch(rg: realRg, pattern: "hello quick")
        let (ra, rb, rq) = try await (a, b, q)
        #expect(ra.status == "failed" && ra.summary.contains("timed out"), "reaped exit-0 with held pipe must be timeout, got \(ra)")
        #expect(rb.status == "failed" && rb.summary.contains("timed out"), "hanging child must be timeout, got \(rb)")
        #expect(rq.status == "success" && rq.data.contains("hello quick"), "quick sibling must be unaffected, got \(rq)")
    }

    // MARK: - 15. Deadline expiry is sticky past clean exit

    @Test("CLOSURE_15_deadlineSticky", .timeLimit(.minutes(2)))
    func deadlineSticky() async throws {
        let realRg = try #require(Self.locateRg(), "rg required for B2 search evidence; silent skip is not evidence")
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try "hello late\n".write(to: ws.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        // Slow probe: ignores TERM, sleeps past the 30 s budget, then execs
        // real rg which exits 0 with genuine matches. The deadline expiry is
        // sticky: post-deadline output is never reported as success.
        let slow = parent.appendingPathComponent("slow.sh")
        let slowScript = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
            echo 'ripgrep 99.0.0'
            exit 0
            fi
            trap '' TERM
            sleep 32
            exec \(realRg) "$@"
            """
        try slowScript.write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: slow.path)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello late\"}")])
        let start = Date()
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.calls[0].status == "failed", "post-deadline exit-0 must be timeout, got \(result.calls[0])")
        #expect(result.calls[0].summary.contains("timed out"), "timeout must be explicit, got \(result.calls[0])")
        #expect(result.calls[0].data.isEmpty, "post-deadline output must be suppressed, got \(result.calls[0].data.prefix(200))")
        #expect(elapsed >= 28 && elapsed < 60, "30 s budget must elapse (plus SIGKILL grace at most), took \(elapsed)s")
    }

    // MARK: - 9. artifactId alias pair rejected

    @Test("CLOSURE_09_artifactAliasBoth")
    func artifactAliasBoth() async throws {
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let hex = String(repeating: "c", count: 64)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"artifactId\":\"\(hex)\",\"artifact_id\":\"\(hex)\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "invalid-arguments", "both alias forms must be rejected, got \(result.calls[0])")
        #expect(result.calls[0].started == false)
    }
}
