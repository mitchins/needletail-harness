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
        guard let realRg = Self.locateRg() else { return }
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
        guard let realRg = Self.locateRg() else { return }
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

    @Test("CLOSURE_03_poisonedEnvReal")
    func poisonedEnvReal() async throws {
        guard let realRg = Self.locateRg() else { return }
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
        guard let realRg = Self.locateRg() else { return }
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
    }

    // MARK: - 6. Protected pruning by parsed path, legit content preserved

    @Test("CLOSURE_06_protectedPrune")
    func protectedPrune() async throws {
        guard let realRg = Self.locateRg() else { return }
        let parent = try Self.tempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let ws = parent.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let gitDir = ws.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "GIT_SENTINEL_111\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "ENV_SECRET_222=1\n".write(to: ws.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "my .env file mentions git config\n".write(to: ws.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "hello normal\n".write(to: ws.appendingPathComponent("normal.txt"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        // Protected content pruned without approval.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"SENTINEL_111|SECRET_222\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success")
        #expect(!result.calls[0].data.contains("GIT_SENTINEL_111"), ".git content must be pruned")
        #expect(!result.calls[0].data.contains("ENV_SECRET_222"), ".env content must be pruned")
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
        // Approval relaxes pruning for the approved grantable category only:
        // .env becomes visible, .git stays pruned.
        let batch4 = ToolBatch([ToolProposal(callID: "c4", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"SECRET_222|SENTINEL_111\"}")])
        let result4 = try await exec.execute(batch: batch4, reservation: Self.makeReservation(batch: batch4, approved: [".env"]))
        #expect(result4.calls[0].status == "success")
        #expect(result4.calls[0].data.contains("ENV_SECRET_222"), "approved grantable path must be visible")
        #expect(!result4.calls[0].data.contains("GIT_SENTINEL_111"), "unapproved grantable category must stay pruned")
    }

    // MARK: - 7. Ripgrep qualification matrix

    @Test("CLOSURE_07_rgQualification")
    func rgQualification() async throws {
        guard let realRg = Self.locateRg() else { return }
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
        guard let realRg = Self.locateRg() else { return }
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
