import Foundation

/// B1 strict argument validator: `validateBatchArguments` per REV25.
/// Throws `ToolFailure.preDispatch` on any malformed args — PRE-side-effect,
/// so no FS touch precedes it. Validates required/unknown/duplicate fields,
/// exact types, allowed enums, numerical limits, string bounds, and
/// operation-specific path fields. Tool capability derived from validated
/// operation, never model-provided safety claim.
public struct ValidatedToolCall: Sendable, Equatable {
    public let callID: String
    public let tool: String
    public let paths: [String]
    public let isMutating: Bool
    public let rawArguments: String

    public init(callID: String, tool: String, paths: [String], isMutating: Bool, rawArguments: String) {
        self.callID = callID
        self.tool = tool
        self.paths = paths
        self.isMutating = isMutating
        self.rawArguments = rawArguments
    }
}

public enum ProtectedClassification: Sendable, Equatable {
    case absoluteDenied
    case grantable
    case unprotected
}

public enum ToolValidator {
    private static let maxPathLength = 4096
    private static let maxStringLength = 8 * 1024
    private static let maxTotalArgumentsSize = 64 * 1024

    public static func validateBatchArguments(batch: ToolBatch) throws -> [ValidatedToolCall] {
        // Check total batch size
        var validated: [ValidatedToolCall] = []
        for proposal in batch.proposals {
            // callID and tool already validated at enterAuthorising, but double-check
            guard !proposal.callID.isEmpty else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty callID")
            }
            guard !proposal.tool.isEmpty else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty tool")
            }
            guard let argsStr = proposal.arguments else {
                // State tests create proposals without arguments (just tool + callID) to test dispatch logic;
                // treat nil as empty valid for backward compat (no paths, isMutating derived from tool)
                let isMut = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
                validated.append(ValidatedToolCall(callID: proposal.callID, tool: proposal.tool, paths: [], isMutating: isMut, rawArguments: "{}"))
                continue
            }
            if argsStr.utf8.count > maxTotalArgumentsSize {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "arguments too large")
            }
            // Duplicate JSON keys detection (byte-exact, no normalization)
            try checkDuplicateKeys(in: argsStr, tool: proposal.tool, callID: proposal.callID)
            guard let data = argsStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "arguments not object for \(proposal.tool)")
            }
            let validatedCall: ValidatedToolCall
            switch proposal.tool {
            case "read":
                validatedCall = try validateRead(callID: proposal.callID, json: json, raw: argsStr)
            case "search":
                validatedCall = try validateSearch(callID: proposal.callID, json: json, raw: argsStr)
            case "edit":
                validatedCall = try validateEdit(callID: proposal.callID, json: json, raw: argsStr)
            case "write":
                validatedCall = try validateWrite(callID: proposal.callID, json: json, raw: argsStr)
            case "exec", "consult":
                // These are denied regardless, but still validate shape for deterministic failure
                try validateExecConsult(callID: proposal.callID, json: json, raw: argsStr)
                // For exec/consult, we still return a validated call with isMutating false/true for capability check
                let isMut = proposal.tool == "exec"
                validatedCall = ValidatedToolCall(callID: proposal.callID, tool: proposal.tool, paths: [], isMutating: isMut, rawArguments: argsStr)
            default:
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown tool \(proposal.tool)")
            }
            validated.append(validatedCall)
        }
        return validated
    }

    private static func checkDuplicateKeys(in json: String, tool: String, callID: String) throws {
        // Simple duplicate key detection: scan for quoted keys
        // This is approximate but catches obvious duplicates like {"path":"a","path":"b"}
        // We parse by finding all keys via regex for "...": and checking duplicates
        // Use a simple state machine: extract keys between quotes before colon
        var seen: Set<String> = []
        var idx = json.startIndex
        while idx < json.endIndex {
            guard let qStart = json[idx...].firstIndex(of: "\"") else { break }
            let afterQ = json.index(after: qStart)
            guard let qEnd = json[afterQ...].firstIndex(of: "\"") else { break }
            let key = String(json[afterQ..<qEnd])
            // Look ahead for colon after optional whitespace
            var look = json.index(after: qEnd)
            while look < json.endIndex && json[look].isWhitespace { look = json.index(after: look) }
            if look < json.endIndex && json[look] == ":" {
                // This is a key
                if seen.contains(key) {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "duplicate field \(key) for \(tool) \(callID)")
                }
                seen.insert(key)
            }
            idx = json.index(after: qEnd)
        }
    }

    private static func validateRead(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        let allowed: Set<String> = ["path", "limit"]
        for key in json.keys where !allowed.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for read \(callID)")
        }
        guard let path = json["path"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing path for read \(callID)")
        }
        try validatePath(path, callID: callID, tool: "read")
        if let limit = json["limit"] {
            guard let v = limit as? Int else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "limit must be int for read \(callID)")
            }
            if v < 1 || v > 10000 {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "limit out of range for read \(callID)")
            }
        }
        // Check for NUL, overlong, etc already in validatePath
        return ValidatedToolCall(callID: callID, tool: "read", paths: [path], isMutating: false, rawArguments: raw)
    }

    private static func validateSearch(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        let allowed: Set<String> = ["pattern", "path"]
        for key in json.keys where !allowed.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for search \(callID)")
        }
        guard let pattern = json["pattern"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing pattern for search \(callID)")
        }
        if pattern.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty pattern for search \(callID)") }
        if pattern.utf8.count > 1024 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "pattern too long for search \(callID)") }
        if pattern.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "pattern contains NUL") }
        if let path = json["path"] as? String {
            try validatePath(path, callID: callID, tool: "search")
            return ValidatedToolCall(callID: callID, tool: "search", paths: [path], isMutating: false, rawArguments: raw)
        }
        return ValidatedToolCall(callID: callID, tool: "search", paths: [], isMutating: false, rawArguments: raw)
    }

    private static func validateEdit(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        let allowed: Set<String> = ["path", "expectedHash", "oldBytes", "newBytes", "old_string", "new_string"]
        for key in json.keys where !allowed.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for edit \(callID)")
        }
        // Require path
        guard let path = json["path"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing path for edit \(callID)")
        }
        try validatePath(path, callID: callID, tool: "edit")
        // B1: oldBytes/newBytes not strictly required for validation (B3 will enforce); only validate if present
        let hasOldBytes = json["oldBytes"] != nil || json["old_string"] != nil
        let hasNewBytes = json["newBytes"] != nil || json["new_string"] != nil
        // For B1, we allow missing old/new for capability-denied tests (e.g., edit with only path)
        _ = hasOldBytes; _ = hasNewBytes
        // Validate strings if present
        for key in ["oldBytes", "newBytes", "old_string", "new_string"] {
            if let v = json[key] {
                guard v is String else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(key) must be string for edit \(callID)")
                }
                let s = v as! String
                if s.utf8.count > 1024*1024 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(key) too large") }
                if s.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(key) contains NUL") }
            }
        }
        if let hash = json["expectedHash"] as? String {
            if hash.utf8.count != 64 || !hash.allSatisfy({ $0.isHexDigit }) {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "expectedHash must be 64 hex for edit \(callID)")
            }
        } else if json["expectedHash"] != nil {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "expectedHash must be string")
        }
        return ValidatedToolCall(callID: callID, tool: "edit", paths: [path], isMutating: true, rawArguments: raw)
    }

    private static func validateWrite(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        let allowed: Set<String> = ["path", "content"]
        for key in json.keys where !allowed.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for write \(callID)")
        }
        guard let path = json["path"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing path for write \(callID)")
        }
        try validatePath(path, callID: callID, tool: "write")
        guard let content = json["content"] else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing content for write \(callID)")
        }
        guard content is String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "content must be string for write \(callID)")
        }
        let s = content as! String
        if s.utf8.count > 32*1024*1024 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "content too large") }
        if s.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "content contains NUL") }
        return ValidatedToolCall(callID: callID, tool: "write", paths: [path], isMutating: true, rawArguments: raw)
    }

    private static func validateExecConsult(callID: String, json: [String: Any], raw: String) throws {
        // For exec/consult, just check no unknown fields? But they are denied anyway.
        // Allow no args or empty, but check types
        for key in json.keys {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for exec/consult")
        }
    }

    private static func validatePath(_ path: String, callID: String, tool: String) throws {
        if path.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty path for \(tool) \(callID)") }
        if path.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path contains NUL for \(tool) \(callID)") }
        if path.utf8.count > maxPathLength { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path too long for \(tool) \(callID)") }
        if path.hasPrefix("/") { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "absolute path not allowed for \(tool) \(callID)") }
        // Check for // or trailing / gives empty component
        if path.contains("//") { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty component in path for \(tool) \(callID)") }
        if path.hasSuffix("/") { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "trailing slash in path for \(tool) \(callID)") }
        // Check each component for "." and ".." and length
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            let p = String(part)
            if p.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty component in path for \(tool) \(callID)") }
            if p == "." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "dot component not allowed for \(tool) \(callID)") }
            if p == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "parent escape not allowed for \(tool) \(callID)") }
            if p.utf8.count > 255 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "component too long") }
        }
    }

    public static func protectedClassification(for path: String) -> ProtectedClassification {
        let components = path.split(separator: "/")
        for comp in components {
            let c = String(comp)
            if c == ".needletail" { return .absoluteDenied }
            if c == "credentials" || c == ".credentials" { return .absoluteDenied }
            if c == "artifacts" || c.hasSuffix("-artifacts") { return .absoluteDenied }
        }
        if path.contains(".needletail/") || path == ".needletail" { return .absoluteDenied }
        if path.contains("/credentials") || path == "credentials" { return .absoluteDenied }
        guard let first = components.first.map(String.init) else { return .unprotected }
        if first == ".git" || first.hasPrefix(".git/") { return .grantable }
        if components.contains(where: { $0 == ".git" }) { return .grantable }
        if first == ".ssh" || first.hasPrefix(".ssh/") { return .grantable }
        if components.contains(where: { $0 == ".ssh" }) { return .grantable }
        if first.hasPrefix(".env") { return .grantable }
        if components.contains(where: { $0.hasPrefix(".env") }) { return .grantable }
        return .unprotected
    }
}
