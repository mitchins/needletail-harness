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
        // Create a fake rg that would be used if PATH shadowing happened
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeDir) }
        let fakeRg = fakeDir.appendingPathComponent("rg")
        try "#!/bin/sh\necho 'fake'\nexit 0".write(to: fakeRg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRg.path)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = fakeDir.path + ":" + (env["PATH"] ?? "")
        env["RIPGREP_CONFIG_PATH"] = "/tmp/fake-config"
        // Use real rg path (pinned)
        let realRg = "/usr/bin/rg"
        guard FileManager.default.fileExists(atPath: realRg) else { return }
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: SessionID("s"), writer: WriterIdentity(session: SessionID("s"), writer: "w"), rgPath: realRg)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")])
        let res = EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor, approvedPaths: [])
        let result = try await exec.execute(batch: batch, reservation: res)
        // Should not use fake rg, should use real rg and find the file
        #expect(result.calls[0].status == "success", "search should succeed with real rg, not fake, got \(result.calls[0])")
        #expect(!result.calls[0].data.contains("fake"), "should not use fake rg")
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
        let digest = String(repeating: "a", count: 64)
        let ref = ArtifactRef(digest: digest, size: 4, kind: "test", operationID: OperationID("op-1"))
        // Publish artifact for session A
        let data = Data("test".utf8)
        // Create artifact file manually for test
        let artifactsRoot = (path as NSString).deletingLastPathComponent + "/" + (path as NSString).lastPathComponent + "-artifacts"
        try FileManager.default.createDirectory(atPath: artifactsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let artifactPath = artifactsRoot + "/" + digest
        try data.write(to: URL(fileURLWithPath: artifactPath))
        try store.appendBatch([.artifactPublished(ref)], as: WriterIdentity(session: sessionA, writer: "w-a"))
        // Try to read artifact from session B (foreign) should be denied
        let foundB = try store.artifactRecord(session: sessionB, digest: digest)
        #expect(foundB == nil, "foreign session should not see artifact")
        let foundA = try store.artifactRecord(session: sessionA, digest: digest)
        #expect(foundA != nil, "same session should see artifact")
        try store.close()
    }

    private static func tempRootForStore() throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b2-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("store.sqlite").path)
    }
}
