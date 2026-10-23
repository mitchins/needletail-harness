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
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing arguments for \(proposal.tool) \(proposal.callID)")
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
        // JSON-aware duplicate key detection: handles escaped quotes and unicode escapes
        // Scan for string literals that are followed by optional whitespace and colon (keys)
        var seen: Set<String> = []
        var i = json.startIndex
        var inString = false
        var escape = false
        var stringStart: String.Index? = nil
        while i < json.endIndex {
            let c = json[i]
            if !inString {
                if c == "\"" {
                    inString = true
                    escape = false
                    stringStart = json.index(after: i)
                }
                i = json.index(after: i)
                continue
            } else {
                // Inside string
                if escape {
                    escape = false
                    // Handle \u escape: skip next 4 hex digits if present
                    if c == "u" {
                        // Skip 4 hex digits
                        var j = json.index(after: i)
                        var count = 0
                        while j < json.endIndex && count < 4 {
                            j = json.index(after: j)
                            count += 1
                        }
                        i = j
                        continue
                    }
                    i = json.index(after: i)
                    continue
                }
                if c == "\\" {
                    escape = true
                    i = json.index(after: i)
                    continue
                }
                if c == "\"" {
                    // End of string
                    if let start = stringStart {
                        let rawKey = String(json[start..<i])
                        // Unescape the key for comparison (handle \" and \\ and \u)
                        let key = unescapeJSONString(rawKey)
                        // Look ahead for colon after optional whitespace
                        var look = json.index(after: i)
                        while look < json.endIndex && json[look].isWhitespace { look = json.index(after: look) }
                        if look < json.endIndex && json[look] == ":" {
                            if seen.contains(key) {
                                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "duplicate field \(key) for \(tool) \(callID)")
                            }
                            seen.insert(key)
                        }
                    }
                    inString = false
                    stringStart = nil
                }
                i = json.index(after: i)
            }
        }
    }

    private static func unescapeJSONString(_ s: String) -> String {
        // Minimal unescaping for duplicate key comparison: handle \" \\ \/ \b \f \n \r \t and \u
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { result.append(c); break }
                let esc = s[next]
                switch esc {
                case "\"", "\\", "/": result.append(esc)
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    // 4 hex digits
                    let hexStart = s.index(after: next)
                    var hexEnd = hexStart
                    var count = 0
                    while hexEnd < s.endIndex && count < 4 {
                        hexEnd = s.index(after: hexEnd)
                        count += 1
                    }
                    if count == 4, let code = UInt32(String(s[hexStart..<hexEnd]), radix: 16), let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                        i = hexEnd
                        continue
                    } else {
                        result.append("\\u")
                    }
                default: result.append(esc)
                }
                i = s.index(after: next)
            } else {
                result.append(c)
                i = s.index(after: i)
            }
        }
        return result
    }

    private static func validateRead(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        let allowed: Set<String> = ["path", "artifactId", "artifact_id", "limit", "offset"]
        for key in json.keys where !allowed.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for read \(callID)")
        }
        let hasPath = json["path"] != nil
        let hasArtifact = json["artifactId"] != nil || json["artifact_id"] != nil
        if hasPath == hasArtifact {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "read requires exactly one of path or artifactId for \(callID)")
        }
        if let rawPath = json["path"] {
            guard let path = rawPath as? String else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path must be string for read \(callID)")
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
            if let offset = json["offset"] {
                guard let v = offset as? Int, v >= 0 else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "offset must be non-negative int for read \(callID)")
                }
            }
            return ValidatedToolCall(callID: callID, tool: "read", paths: [path], isMutating: false, rawArguments: raw)
        } else {
            // Artifact ID path: exactly one alias form allowed
            if json["artifactId"] != nil && json["artifact_id"] != nil {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "both artifactId and artifact_id for read \(callID)")
            }
            let artifactId = (json["artifactId"] as? String) ?? (json["artifact_id"] as? String) ?? ""
            if artifactId.isEmpty {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "artifactId must be non-empty string for read \(callID)")
            }
            if artifactId.utf8.count > 128 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "artifactId too long") }
            if artifactId.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "artifactId contains NUL") }
            if artifactId.count != 64 || !artifactId.allSatisfy({ $0.isHexDigit }) {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "artifactId must be 64 hex")
            }
            if let limit = json["limit"] {
                guard let v = limit as? Int else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "limit must be int for read \(callID)")
                }
                if v < 1 || v > 10000 {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "limit out of range for read \(callID)")
                }
            }
            if let offset = json["offset"] {
                guard let v = offset as? Int, v >= 0 else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "offset must be non-negative int for read \(callID)")
                }
            }
            return ValidatedToolCall(callID: callID, tool: "read", paths: [], isMutating: false, rawArguments: raw)
        }
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
        if let rawPath = json["path"] {
            guard let path = rawPath as? String else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path must be string for search \(callID)")
            }
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
        // B1 Phase1: edit now requires its mandatory payload and SHA before auth/lock
        guard let expectedHash = json["expectedHash"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing expectedHash for edit \(callID)")
        }
        if expectedHash.utf8.count != 64 || !expectedHash.allSatisfy({ $0.isHexDigit }) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "expectedHash must be 64 hex for edit \(callID)")
        }
        let hasOld = (json["oldBytes"] as? String) ?? (json["old_string"] as? String)
        guard hasOld != nil else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing oldBytes/old_string for edit \(callID)")
        }
        if let o = hasOld, o.isEmpty {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty oldBytes/old_string for edit \(callID)")
        }
        let hasNew = (json["newBytes"] as? String) ?? (json["new_string"] as? String)
        guard hasNew != nil else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing newBytes/new_string for edit \(callID)")
        }
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
        return ValidatedToolCall(callID: callID, tool: "edit", paths: [path], isMutating: true, rawArguments: raw)
    }

    private static func validateWrite(callID: String, json: [String: Any], raw: String) throws -> ValidatedToolCall {
        // B3: create_new is exclusive; replacement is authorized ONLY by an
        // expectedHash over the exact current bytes (same contract as edit).
        let allowed: Set<String> = ["path", "content", "expectedHash"]
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
        if let expectedHash = json["expectedHash"] {
            guard let h = expectedHash as? String,
                  h.utf8.count == 64, h.allSatisfy({ $0.isHexDigit }) else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "expectedHash must be 64 hex for write \(callID)")
            }
        }
        return ValidatedToolCall(callID: callID, tool: "write", paths: [path], isMutating: true, rawArguments: raw)
    }

    private static func validateExecConsult(callID: String, json: [String: Any], raw: String) throws {
        // For exec/consult, just check no unknown fields? But they are denied anyway.
        // Allow no args or empty, but check types
        for key in json.keys {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for exec/consult")
        }
    }

    /// Byte-exact path components: split UTF-8 bytes at 0x2F. Character
    /// splitting is WRONG here ("/" + combining mark is one grapheme, so it
    /// would hide an embedded separator from every per-component check).
    /// ASCII boundaries align with scalar boundaries, so decoding each
    /// piece is lossless.
    public static func byteComponents(of path: String) -> [String] {
        var parts: [String] = []
        var piece: [UInt8] = []
        piece.reserveCapacity(64)
        for b in path.utf8 {
            if b == 0x2F {
                parts.append(String(decoding: piece, as: UTF8.self))
                piece.removeAll(keepingCapacity: true)
            } else {
                piece.append(b)
            }
        }
        parts.append(String(decoding: piece, as: UTF8.self))
        return parts
    }

    private static func validatePath(_ path: String, callID: String, tool: String) throws {
        if path.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty path for \(tool) \(callID)") }
        if path.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path contains NUL for \(tool) \(callID)") }
        if path.utf8.count > maxPathLength { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "path too long for \(tool) \(callID)") }
        // Byte-level edge checks (grapheme hasPrefix/hasSuffix can misread a
        // leading/trailing "/" glued to a combining mark).
        if path.utf8.first == 0x2F { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "absolute path not allowed for \(tool) \(callID)") }
        if path.utf8.last == 0x2F { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "trailing slash in path for \(tool) \(callID)") }
        var sawEmpty = false
        var prevWasSlash = false
        for b in path.utf8 {
            if b == 0x2F {
                if prevWasSlash { sawEmpty = true }
                prevWasSlash = true
            } else {
                prevWasSlash = false
            }
        }
        if sawEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty component in path for \(tool) \(callID)") }
        // Check each component for "." and ".." and length.
        let parts = Self.byteComponents(of: path)
        for p in parts {
            if p.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty component in path for \(tool) \(callID)") }
            if p == "." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "dot component not allowed for \(tool) \(callID)") }
            if p == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "parent escape not allowed for \(tool) \(callID)") }
            if p.utf8.count > 255 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "component too long") }
        }
    }

    /// Byte-exact string equality (raw UTF-8 bytes). Swift `String ==` is
    /// Unicode canonical equivalence, so NFC and NFD spellings of the same
    /// name compare equal — approvals must never rely on that, or one
    /// approved spelling authorizes an unlisted twin (B1 grant enumeration).
    public static func byteEqual(_ a: String, _ b: String) -> Bool {
        Array(a.utf8) == Array(b.utf8)
    }

    /// Byte-exact approval membership (see byteEqual).
    public static func isApprovedPath(_ path: String, approvedPaths: [String]) -> Bool {
        approvedPaths.contains(where: { byteEqual($0, path) })
    }

    /// Byte-exact subtree grant: exact match or `base + "/"` prefix match on
    /// raw bytes. A U+FFFD literal approval never matches a different raw
    /// name (see the lossy-bytes handling at the search classifier).
    public static func isApprovedPrefix(_ logical: String, approvedPaths: [String]) -> Bool {
        let lb = Array(logical.utf8)
        for a in approvedPaths {
            let ab = Array(a.utf8)
            if lb == ab { return true }
            if lb.count > ab.count + 1, lb.starts(with: ab), lb[ab.count] == 0x2F {
                return true
            }
        }
        return false
    }

    /// Byte-distinct dedup preserving first-occurrence order (for grantable
    /// approval enumeration: NFC/NFD twins must both be listed).
    public static func dedupeByteDistinct(_ paths: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        var unique: [String] = []
        for p in paths {
            if seen.insert(Array(p.utf8)).inserted {
                unique.append(p)
            }
        }
        return unique
    }

    public static func protectedClassification(for path: String) -> ProtectedClassification {
        // Byte-split components (same grapheme-hiding hazard as validatePath:
        // "artifacts/<U+0301>pwn" must still see the "artifacts" component).
        // hasPrefix/hasSuffix/contains below all use pure-ASCII needles, so
        // combining marks elsewhere can neither hide nor forge a match.
        let components = Self.byteComponents(of: path)
        for c in components {
            if c == ".needletail" { return .absoluteDenied }
            if c == "credentials" || c == ".credentials" { return .absoluteDenied }
            if c == "artifacts" || c.hasSuffix("-artifacts") { return .absoluteDenied }
        }
        if path.contains(".needletail/") || path == ".needletail" { return .absoluteDenied }
        if path.contains("/credentials") || path == "credentials" { return .absoluteDenied }
        guard let first = components.first else { return .unprotected }
        if first == ".git" { return .grantable }
        if components.contains(where: { $0 == ".git" }) { return .grantable }
        if first == ".ssh" { return .grantable }
        if components.contains(where: { $0 == ".ssh" }) { return .grantable }
        if first == ".env" || first.hasPrefix(".env.") { return .grantable }
        if components.contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) { return .grantable }
        return .unprotected
    }
}
