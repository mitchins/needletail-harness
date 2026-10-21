import Foundation
import SystemPackage
import NeedletailCore
import Crypto

/// Minimal NativeToolExecutor for M2-B (simplified for initial build; containment via WorkspaceResolver)
public struct NativeToolExecutor: ToolExecutor, Sendable {
    public let resolver: WorkspaceResolver
    public let store: any SessionStore
    public let sessionID: SessionID
    public let writer: WriterIdentity
    public let rgPath: String?
    public let gitPath: String?

    public init(resolver: WorkspaceResolver, store: any SessionStore, sessionID: SessionID, writer: WriterIdentity, rgPath: String? = nil, gitPath: String? = nil) {
        self.resolver = resolver
        self.store = store
        self.sessionID = sessionID
        self.writer = writer
        self.rgPath = rgPath
        self.gitPath = gitPath
    }

    public func describe(batch: ToolBatch) -> String {
        batch.proposals.map { "\($0.tool):\($0.callID)" }.joined(separator: ", ")
    }

    public func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
        var outcomes: [ToolCallOutcome] = []
        var halted = false
        var haltAfter: String? = nil
        for proposal in batch.proposals {
            if halted {
                let summary = "unstarted: halted after \(haltAfter ?? "unknown")"
                outcomes.append(ToolCallOutcome(callID: proposal.callID, status: "cancelled", summary: summary, data: "", started: false))
                continue
            }
            let outcome = try await executeOne(proposal: proposal)
            outcomes.append(outcome)
            if outcome.status != "success" && outcome.status != "no-match" {
                halted = true
                haltAfter = proposal.callID
            }
        }
        let receipt = ExecutorReceipt(callID: batch.proposals.first?.callID ?? "batch", status: outcomes.first?.status ?? "failed", summary: outcomes.map { "\($0.callID):\($0.status)" }.joined(separator: ", "))
        return ExecutorResult(receipt: receipt, calls: outcomes)
    }

    private func executeOne(proposal: ToolProposal) async throws -> ToolCallOutcome {
        guard let argsStr = proposal.arguments, let data = argsStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolCallOutcome(callID: proposal.callID, status: "invalid-arguments", summary: "invalid json", data: "", error: "invalid json", started: false)
        }
        switch proposal.tool {
        case "read":
            return try read(callID: proposal.callID, json: json)
        case "search":
            return try search(callID: proposal.callID, json: json)
        case "edit":
            return try edit(callID: proposal.callID, json: json)
        case "write":
            return try write(callID: proposal.callID, json: json)
        default:
            return ToolCallOutcome(callID: proposal.callID, status: "invalid-arguments", summary: "unknown tool", data: "", error: "unknown tool", started: false)
        }
    }

    private func read(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        if path.isEmpty {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "missing path", data: "", error: "missing path", started: false)
        }
        let (abs, grantable) = WorkspaceResolver.isProtected(path: path)
        if abs {
            return ToolCallOutcome(callID: callID, status: "denied", summary: "absolute protected path", data: "", error: "protected", started: false)
        }
        // For grantable, we would check approval, but for now deny unless workspace
        // Minimal: try to read via Foundation using workspace root
        guard let ws = resolver.workspaceRoot else {
            return ToolCallOutcome(callID: callID, status: "denied", summary: "workspace not configured", data: "", error: "no workspace", started: false)
        }
        let fullPath = ws.path.string + "/" + path
        guard FileManager.default.fileExists(atPath: fullPath) else {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "not found", data: "", started: true)
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
        if isDir.boolValue {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "is directory", data: "", error: "is directory", started: true)
        }
        guard let data = FileManager.default.contents(atPath: fullPath) else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "cannot read", data: "", error: "cannot read", started: true)
        }
        if data.count > 32*1024*1024 {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "over size limit", data: "", error: "too large", started: true)
        }
        // Check for binary
        if data.contains(0) {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "binary", data: "", error: "binary", started: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        let limit = json["limit"] as? Int ?? 200
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limited = lines.prefix(limit).joined(separator: "\n")
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolCallOutcome(callID: callID, status: "success", summary: "read \(path)", data: limited, path: path, beforeHash: hash, started: true)
    }

    private func search(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        guard let rg = rgPath, FileManager.default.fileExists(atPath: rg) else {
            return ToolCallOutcome(callID: callID, status: "denied", summary: "rg not provisioned", data: "", error: "rg missing", started: false)
        }
        let pattern = json["pattern"] as? String ?? ""
        if pattern.isEmpty {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "missing pattern", data: "", error: "missing pattern", started: false)
        }
        // Minimal: run rg with fixed argv and deny globs
        var args = [rg, "--json", "--hidden", "--glob", "!.git/", "--glob", "!**/.git/**", "--glob", "!.env*", "--glob", "!**/.env*", "--glob", "!.ssh/", "--glob", "!**/.ssh/**", "--", pattern]
        if let ws = resolver.workspaceRoot {
            args.append(ws.path.string)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "RIPGREP_CONFIG_PATH")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rg failed", data: "", error: "\(error)", started: true)
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: out, as: UTF8.self)
        return ToolCallOutcome(callID: callID, status: "success", summary: "search \(pattern)", data: text, started: true)
    }

    private func edit(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let expectedHash = json["expectedHash"] as? String ?? ""
        let oldBytes = (json["oldBytes"] as? String ?? "").data(using: .utf8) ?? Data()
        let newBytes = (json["newBytes"] as? String ?? "").data(using: .utf8) ?? Data()
        if oldBytes.isEmpty {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "empty oldBytes", data: "", error: "empty", started: true)
        }
        guard let ws = resolver.workspaceRoot else {
            return ToolCallOutcome(callID: callID, status: "denied", summary: "no workspace", data: "", error: "no workspace", started: false)
        }
        let fullPath = ws.path.string + "/" + path
        guard let current = FileManager.default.contents(atPath: fullPath) else {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "not found", data: "", started: true)
        }
        let currentHash = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
        if !expectedHash.isEmpty && currentHash != expectedHash {
            return ToolCallOutcome(callID: callID, status: "conflict", summary: "hash mismatch", data: "", error: "conflict", path: path, beforeHash: currentHash, started: true)
        }
        guard let range = current.range(of: oldBytes) else {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "oldBytes not found", data: "", path: path, beforeHash: currentHash, started: true)
        }
        let rest = current[range.upperBound...]
        if rest.range(of: oldBytes) != nil {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "multiple matches", data: "", error: "multiple", started: true)
        }
        var newData = Data(current[..<range.lowerBound])
        newData.append(newBytes)
        newData.append(Data(current[range.upperBound...]))
        let afterHash = SHA256.hash(data: newData).map { String(format: "%02x", $0) }.joined()
        // Write atomically via tmp + rename
        let dir = (fullPath as NSString).deletingLastPathComponent
        let tmp = dir + "/." + UUID().uuidString + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: newData, attributes: [.posixPermissions: 0o600])
        // Preserve mode
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath), let mode = attrs[.posixPermissions] as? NSNumber {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp)
        }
        do {
            try FileManager.default.moveItem(atPath: tmp, toPath: fullPath)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rename failed", data: "", error: "\(error)", started: true)
        }
        return ToolCallOutcome(callID: callID, status: "success", summary: "edit \(path)", data: "edited", path: path, beforeHash: currentHash, afterHash: afterHash, started: true)
    }

    private func write(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let content = (json["content"] as? String ?? "").data(using: .utf8) ?? Data()
        guard let ws = resolver.workspaceRoot else {
            return ToolCallOutcome(callID: callID, status: "denied", summary: "no workspace", data: "", error: "no workspace", started: false)
        }
        let fullPath = ws.path.string + "/" + path
        if FileManager.default.fileExists(atPath: fullPath) {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "exists", data: "", error: "exists", started: true)
        }
        let dir = (fullPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        FileManager.default.createFile(atPath: fullPath, contents: content, attributes: [.posixPermissions: 0o600])
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return ToolCallOutcome(callID: callID, status: "success", summary: "write \(path)", data: "written", path: path, afterHash: hash, started: true)
    }
}
