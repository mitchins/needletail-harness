import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage

struct B2ReadSearchTests {
    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    @Test("TOOL_01_binary")
    func tool01Binary() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("bin")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"bin\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "failed", "binary should be failed, got \(result.calls[0])")
        #expect(result.calls[0].started == true)
    }

    @Test("TOOL_01_truncated")
    func tool01Truncated() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("big")
        let lines = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"big\",\"limit\":10}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "success")
        #expect(result.calls[0].truncated == true, "should be truncated")
        #expect(result.calls[0].data.split(separator: "\n").count == 10)
    }

    @Test("TOOL_03_poisonedEnv")
    func tool03PoisonedEnv() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("a")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        // Genuine injection into the PROCESS environment (not a local dict):
        // poisoned PATH with a fake rg first, plus a RIPGREP_CONFIG_PATH
        // preprocessor that would stamp PRE_POISON into every file.
        // Cross-suite note: setenv is process-global, but interference is
        // benign by construction — the executor never reads the parent
        // environment (sanitized env + --no-config), and every direct-rg
        // counterfactual passes an explicit env. Restores run in defer.
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeDir) }
        let fakeRg = fakeDir.appendingPathComponent("rg")
        try "#!/bin/sh\necho 'fake'\nexit 0".write(to: fakeRg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRg.path)
        let evilPre = fakeDir.appendingPathComponent("evil-pre.sh")
        try "#!/bin/sh\necho PRE_POISON\ncat \"$1\"\n".write(to: evilPre, atomically: true, encoding: .utf8)
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
        let realRg = "/usr/bin/rg"
        try #require(FileManager.default.fileExists(atPath: realRg), "rg required for B2 search evidence; silent skip is not evidence")
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "success", "poisoned env must not break pinned search, got \(result.calls[0])")
        #expect(result.calls[0].data.contains("hello world"), "real match must be present")
        #expect(!result.calls[0].data.contains("fake"), "PATH-shadowing fake rg must not be used")
        #expect(!result.calls[0].data.contains("PRE_POISON"), "poisoned preprocessor config must not be applied")
    }

    @Test("TOOL_11_crossSession")
    func tool11CrossSession() async throws {
        let (dir, path) = try Self.tempRootForStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: path)
        let sessionA = SessionID("s-a")
        let sessionB = SessionID("s-b")
        try store.claimWriterOwnership(session: sessionA, writer: "w-a")
        try store.claimWriterOwnership(session: sessionB, writer: "w-b")
        let data = Data("artifact-data".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ref = ArtifactRef(digest: digest, size: data.count, kind: "test", operationID: OperationID("op-1"))
        let artifactsRoot = (path as NSString).deletingLastPathComponent + "/" + (path as NSString).lastPathComponent + "-artifacts"
        try FileManager.default.createDirectory(atPath: artifactsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: URL(fileURLWithPath: artifactsRoot + "/" + digest))
        try store.appendBatch([.artifactPublished(ref)], as: WriterIdentity(session: sessionA, writer: "w-a"))
        // Same-session read via executor should succeed
        let resolverA = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
        let execA = NativeToolExecutor(resolver: resolverA, store: store, sessionID: sessionA, writer: WriterIdentity(session: sessionA, writer: "w-a"))
        let batchA = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"artifactId\":\"\(digest)\"}")])
        let resA = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batchA, kind: .executor, approvedPaths: [])
        let resultA = try await execA.execute(batch: batchA, reservation: resA)
        #expect(resultA.calls[0].status == "success", "same-session artifact read should succeed, got \(resultA.calls[0])")
        // Foreign session should be denied
        let execB = NativeToolExecutor(resolver: resolverA, store: store, sessionID: sessionB, writer: WriterIdentity(session: sessionB, writer: "w-b"))
        let resultB = try await execB.execute(batch: batchA, reservation: resA)
        #expect(resultB.calls[0].status == "denied", "foreign session artifact read should be denied, got \(resultB.calls[0])")
        // Digest alone is never a grant (no artifactPublished for random digest)
        let badDigest = String(repeating: "b", count: 64)
        let batchBad = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"artifactId\":\"\(badDigest)\"}")])
        let resultBad = try await execA.execute(batch: batchBad, reservation: resA)
        #expect(resultBad.calls[0].status == "denied", "unknown digest should be denied")
        try store.close()
    }

    @Test("TOOL_01_malformedUTF8")
    func tool01MalformedUTF8() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("bad")
        try Data([0xFF, 0xFE, 0xFD]).write(to: file)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"bad\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "failed", "malformed UTF-8 should be failed without replacement, got \(result.calls[0])")
        #expect(!result.calls[0].data.contains("\u{FFFD}"), "must not contain replacement char")
    }

    @Test("TOOL_01_oversized")
    func tool01Oversized() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("big")
        let bigData = Data(repeating: 0x41, count: 33*1024*1024)
        try bigData.write(to: file)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"big\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "failed", "oversized should be failed, got \(result.calls[0])")
    }

    @Test("TOOL_02_missingRg")
    func tool02MissingRg() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: "/nonexistent/rg")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"x\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "denied", "missing rg should be denied, got \(result.calls[0])")
    }

    @Test("TOOL_11_sameSession")
    func tool11SameSession() async throws {
        let (dir, path) = try Self.tempRootForStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBSessionStore(path: path)
        let sessionA = SessionID("s-a")
        try store.claimWriterOwnership(session: sessionA, writer: "w-a")
        let data = Data("hello artifact".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ref = ArtifactRef(digest: digest, size: data.count, kind: "test", operationID: OperationID("op-2"))
        let artifactsRoot = (path as NSString).deletingLastPathComponent + "/" + (path as NSString).lastPathComponent + "-artifacts"
        try FileManager.default.createDirectory(atPath: artifactsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: URL(fileURLWithPath: artifactsRoot + "/" + digest))
        try store.appendBatch([.artifactPublished(ref)], as: WriterIdentity(session: sessionA, writer: "w-a"))
        let resolver = try WorkspaceResolver(workspace: FilePath(dir.path), readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: sessionA, writer: WriterIdentity(session: sessionA, writer: "w-a"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"artifactId\":\"\(digest)\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "success", "same-session artifact read should succeed, got \(result.calls[0])")
        #expect(result.calls[0].data == "hello artifact")
        try store.close()
    }

    @Test("TOOL_03_largeOutput")
    func tool03LargeOutput() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        // Create many files to generate large rg output > pipe buffer (64KB)
        for i in 0..<500 {
            let f = url.appendingPathComponent("f\(i).txt")
            try String(repeating: "hello world pattern\n", count: 100).write(to: f, atomically: true, encoding: .utf8)
        }
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let realRg = "/usr/bin/rg"
        try #require(FileManager.default.fileExists(atPath: realRg), "rg required for B2 search evidence; silent skip is not evidence")
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(result.calls[0].status == "success", "large output search should not deadlock, got \(result.calls[0])")
        #expect(result.calls[0].data.contains("hello"), "large output should contain matches")
    }

    @Test("TOOL_01_binaryIsolation")
    func tool01BinaryIsolation() async throws {
        // RED/GREEN: replacement char must not appear
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("bin2")
        try Data([0xFF, 0xFE]).write(to: file)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let store = InMemorySessionStore()
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"))
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"bin2\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        #expect(!result.calls[0].data.contains("\u{FFFD}"), "binary must not produce replacement char")
    }

    private static func tempRootForStore() throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b2-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("store.sqlite").path)
    }
}
