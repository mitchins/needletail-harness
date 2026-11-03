import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime

/// M3-D Docker amendment: container-scoped automatic approval. The
/// gateway approves ONLY against an immutable launcher grant bound to
/// the live container + disposable workspace, evaluating the VALIDATED
/// batch (never display text). Everything else fails closed.
struct SandboxPolicyTests {

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func writeGrant(in dir: URL, container: String, workspace: String, tools: [String] = ["read", "search", "edit", "write", "exec"], exec: [String] = ["python3", "node"]) throws -> String {
        let grant: [String: Any] = [
            "version": 1, "runID": "run-test-1", "containerID": container,
            "workspace": workspace, "allowedTools": tools, "allowedExec": exec,
        ]
        let url = dir.appendingPathComponent("grant.json")
        try JSONSerialization.data(withJSONObject: grant).write(to: url)
        return url.path
    }

    private static func request(batch: ToolBatch, identities: [ExecCommandIdentity] = []) -> ApprovalRequest {
        ApprovalRequest(
            requestID: RequestID("r"), runID: RunID("run"), generation: Revision(1),
            operation: "tool batch (untrusted display text; the gateway must not read this)",
            requiredGrant: "explicit approval", protectedPaths: [],
            execIdentities: identities, batch: batch)
    }

    private static func readBatch(_ args: String) -> ToolBatch {
        ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: args)])
    }

    @Test("missing grant file fails closed")
    func missingGrant() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = SandboxPolicyGateway(grantPath: dir.appendingPathComponent("nope.json").path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox grant missing or invalid; fail closed"))
    }

    @Test("corrupt grant fails closed")
    func corruptGrant() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("grant.json")
        try Data("not-json".utf8).write(to: url)
        let gateway = SandboxPolicyGateway(grantPath: url.path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox grant missing or invalid; fail closed"))
    }

    @Test("container mismatch fails closed")
    func containerMismatch() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "some-other-container", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "this-container")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox grant container mismatch; fail closed"))
    }

    @Test("live hostname without override never matches a foreign grant")
    func liveHostnameMismatch() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        // No override: the gateway reads the REAL hostname, which cannot
        // equal this freshly minted grant identity.
        let path = try Self.writeGrant(in: dir, container: "grant-\(UUID().uuidString)", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path)
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox grant container mismatch; fail closed"))
    }

    @Test("missing workspace fails closed")
    func missingWorkspace() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: dir.appendingPathComponent("nope").path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox workspace missing; fail closed"))
    }

    @Test("disallowed tool fails closed even with a valid grant")
    func disallowedTool() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path, tools: ["read"])
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let batch = ToolBatch([ToolProposal(callID: "c9", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"]}")])
        let decision = await gateway.decide(Self.request(batch: batch))
        #expect(decision == .unavailable("sandbox denies tool exec; fail closed"))
    }

    @Test("absolute escape fails closed (validator rejects first)")
    func absoluteEscape() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"/etc/passwd\"}")))
        // The validator rejects absolute paths before the grant-scope check
        // runs; either layer refuses with fail-closed unavailability.
        #expect(decision == .unavailable("sandbox batch failed validation; fail closed"))
    }

    @Test("dot-dot escape fails closed (validator rejects first)")
    func dotDotEscape() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"sub/../../evil\"}")))
        #expect(decision == .unavailable("sandbox batch failed validation; fail closed"))
    }

    @Test("grant-scope confinement: lexical check admits only the workspace")
    func grantScopeConfinement() throws {
        let ws = "/workspace"
        #expect(SandboxPolicyGateway.isWithinWorkspace("a.txt", workspace: ws))
        #expect(SandboxPolicyGateway.isWithinWorkspace("sub/dir/f.txt", workspace: ws))
        #expect(SandboxPolicyGateway.isWithinWorkspace("/workspace/a.txt", workspace: ws))
        #expect(SandboxPolicyGateway.isWithinWorkspace("/workspace", workspace: ws))
        #expect(!SandboxPolicyGateway.isWithinWorkspace("/etc/passwd", workspace: ws))
        #expect(!SandboxPolicyGateway.isWithinWorkspace("sub/../../evil", workspace: ws))
        #expect(!SandboxPolicyGateway.isWithinWorkspace("/workspace-evil/a.txt", workspace: ws), "prefix confusion must not admit siblings")
        #expect(SandboxPolicyGateway.isWithinWorkspace("../workspace/a.txt", workspace: ws), "../workspace resolves back inside the workspace")
    }

    @Test("unsupported grant version fails closed")
    func unsupportedVersion() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        var raw: [String: Any] = ["version": 99, "runID": "r", "containerID": "c", "workspace": ws.path, "allowedTools": ["read"], "allowedExec": []]
        let url = dir.appendingPathComponent("grant.json")
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        let gateway = SandboxPolicyGateway(grantPath: url.path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: Self.readBatch("{\"path\":\"a.txt\"}")))
        #expect(decision == .unavailable("sandbox grant version unsupported; fail closed"))
    }

    @Test("empty batch fails closed")
    func emptyBatch() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let decision = await gateway.decide(Self.request(batch: ToolBatch([])))
        #expect(decision == .unavailable("sandbox cannot approve an empty batch"))
    }

    @Test("unknown tool fails closed at validation")
    func unknownTool() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path, tools: ["frobnicate"])
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let batch = ToolBatch([ToolProposal(callID: "c9", tool: "frobnicate", argumentsDigest: "d", arguments: "{}")])
        let decision = await gateway.decide(Self.request(batch: batch))
        #expect(decision == .unavailable("sandbox batch failed validation; fail closed"))
    }

    @Test("exec without a bound identity fails closed")
    func execWithoutIdentity() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let batch = ToolBatch([ToolProposal(callID: "cx", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\",\"-m\",\"unittest\"]}")])
        let decision = await gateway.decide(Self.request(batch: batch))
        #expect(decision == .unavailable("sandbox denies unbound exec identity; fail closed"))
    }

    @Test("exec outside the allowlist fails closed even when bound")
    func execOutsideAllowlist() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let batch = ToolBatch([ToolProposal(callID: "cx", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"/bin/sh\",\"argv\":[\"/bin/sh\",\"-c\",\"id\"]}")])
        let identities = [ExecCommandIdentity(callID: "cx", requestedPath: "/bin/sh", resolvedPath: "/bin/sh", contentDigest: String(repeating: "a", count: 64))]
        let decision = await gateway.decide(Self.request(batch: batch, identities: identities))
        #expect(decision == .unavailable("sandbox denies exec outside the allowlist; fail closed"))
    }

    @Test("valid confined batch approves as sandbox policy, never as human")
    func validBatchApprovesAsSandboxPolicy() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path)
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\"}"),
            ToolProposal(callID: "c2", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\",\"-m\",\"unittest\"]}"),
        ])
        let identities = [ExecCommandIdentity(callID: "c2", requestedPath: "/usr/bin/python3", resolvedPath: "/usr/bin/python3", contentDigest: String(repeating: "b", count: 64))]
        let decision = await gateway.decide(Self.request(batch: batch, identities: identities))
        #expect(decision == .sandboxGrant(note: "sandbox:run-test-1:c"))
        #expect(decision != .approve, "sandbox approvals are never recorded as human")
    }

    @Test("display text cannot widen the grant")
    func displayTextIgnored() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        let path = try Self.writeGrant(in: dir, container: "c", workspace: ws.path, tools: ["read"])
        let gateway = SandboxPolicyGateway(grantPath: path, containerID: "c")
        // The operation text claims edit/exec approval; the batch is a
        // plain confined read — the grant follows the batch, but the
        // reverse (text claiming more than the batch) can never widen it:
        // an edit batch against a read-only grant still fails.
        let editBatch = ToolBatch([ToolProposal(callID: "c9", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a.txt\",\"expectedHash\":\"\(String(repeating: "0", count: 64))\",\"old_string\":\"a\",\"new_string\":\"b\"}")])
        let decision = await gateway.decide(Self.request(batch: editBatch))
        #expect(decision == .unavailable("sandbox denies tool edit; fail closed"))
    }
}
