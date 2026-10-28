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
    /// Intake bound for one proposal's argument JSON. Sized to admit the
    /// largest reachable payload — provider-assembled arguments cap at
    /// 256 KiB (SSEBounds.maxArgumentsBytes), so the total MUST exceed
    /// that (plus JSON overhead) or legitimate model traffic is refused
    /// while larger per-tool limits stay unreachable. Direct callers
    /// remain bounded; per-tool limits (e.g. write's 32 MiB, enforced
    /// against streamed executor I/O) still apply inside validation.
    private static let maxTotalArgumentsSize = 512 * 1024

    public static func validateBatchArguments(batch: ToolBatch) throws -> [ValidatedToolCall] {
        // Check total batch size
        var validated: [ValidatedToolCall] = []
        // NC-15: resolution (and later spawn) work is bounded per batch.
        let execCalls = batch.proposals.filter { $0.tool == "exec" }.count
        if execCalls > ExecArguments.maxExecCallsPerBatch {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "too many exec calls in batch (\(execCalls) > \(ExecArguments.maxExecCallsPerBatch))")
        }
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
            case "exec":
                // M2-C C0: a real schema (plan REV12 §3.3). Shape-validated
                // here; existence/identity are bound later by the
                // resolution phase (Runtime) — the validator stays pure.
                _ = try validateExec(callID: proposal.callID, json: json)
                validatedCall = ValidatedToolCall(callID: proposal.callID, tool: proposal.tool, paths: [], isMutating: true, rawArguments: argsStr)
            case "consult":
                // Still denied/unadvertised; keep the deterministic
                // per-field rejection until its own milestone.
                try validateExecConsult(callID: proposal.callID, json: json, raw: argsStr)
                validatedCall = ValidatedToolCall(callID: proposal.callID, tool: proposal.tool, paths: [], isMutating: false, rawArguments: argsStr)
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
        // Alias pairs are alternatives, not supplements: providing both
        // spellings is ambiguous and fails closed (first-wins would
        // silently discard operator/model content).
        if json["oldBytes"] != nil && json["old_string"] != nil {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "oldBytes and old_string are mutually exclusive for edit \(callID)")
        }
        if json["newBytes"] != nil && json["new_string"] != nil {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "newBytes and new_string are mutually exclusive for edit \(callID)")
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
        // For consult, just check no unknown fields? But they are denied anyway.
        // Allow no args or empty, but check types
        for key in json.keys {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for exec/consult")
        }
    }

    // MARK: - exec schema (M2-C C0, plan REV12 §3.3)

    private static let execAllowedKeys: Set<String> = ["executable", "argv", "cwd", "timeoutSecs", "env"]

    /// Strict exec validation: parse + shape-check, then the bounded
    /// approval-display guard. Returns the validated call (mutating).
    static func validateExec(callID: String, json: [String: Any]) throws -> ValidatedToolCall {
        _ = try parseExecArguments(callID: callID, json: json)
        return ValidatedToolCall(callID: callID, tool: "exec", paths: [], isMutating: true, rawArguments: "")
    }
    private static let maxEnvKeyBytes = 256
    private static let maxEnvValueBytes = 8 * 1024
    private static let maxComponentBytes = 255

    /// Absolute-path component rules (plan REV12 §3.3): byte-exact split at
    /// "/", no empty/`.`/`..`/trailing-slash components, each ≤ 255 B, total
    /// ≤ 4096 B, no NUL. Mirrors validatePath's byte discipline for the
    /// absolute (executable) case.
    static func validateAbsoluteComponents(_ path: String, what: String, callID: String) throws {
        if path.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(what) contains NUL for exec \(callID)") }
        if path.utf8.count > maxPathLength { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(what) too long for exec \(callID)") }
        guard path.utf8.first == 0x2F else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(what) must be absolute for exec \(callID) (no PATH search)")
        }
        if path.utf8.last == 0x2F {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "trailing slash in \(what) for exec \(callID)")
        }
        // Byte-exact: Character splitting would hide an embedded "/" + combining mark.
        for p in Self.byteComponents(of: path).dropFirst() {
            let c = p
            if c.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty component in \(what) for exec \(callID)") }
            if c == "." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "dot component not allowed in \(what) for exec \(callID)") }
            if c == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "parent escape not allowed in \(what) for exec \(callID)") }
            if c.utf8.count > maxComponentBytes { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "component too long in \(what) for exec \(callID)") }
        }
    }

    private static func printableSafe(_ s: String) -> Bool {
        // Printable ASCII plus tab and UTF-8 multibyte sequences; raw C0
        // control bytes (except tab) are refused — the approval display
        // would otherwise need lossy handling for model-authored text.
        var i = s.startIndex
        while i < s.endIndex {
            let scalar = s.unicodeScalars[i]
            if scalar.value < 0x20 && scalar.value != 0x09 { return false }
            if scalar.value == 0x7F { return false }
            i = s.index(after: i)
        }
        return true
    }

    /// Pure parse+shape-check for the exec schema. Throws preDispatch on
    /// any violation; returns the typed arguments on success.
    public static func parseExecArguments(callID: String, json: [String: Any]) throws -> ExecArguments {
        for key in json.keys where !execAllowedKeys.contains(key) {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field \(key) for exec \(callID)")
        }
        guard let executable = json["executable"] as? String else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "executable required (string, absolute) for exec \(callID)")
        }
        try validateAbsoluteComponents(executable, what: "executable", callID: callID)
        guard let argv = json["argv"] as? [Any] else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv required (array of strings) for exec \(callID)")
        }
        guard !argv.isEmpty, argv.count <= ExecArguments.maxArgvEntries else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv must hold 1...\(ExecArguments.maxArgvEntries) entries for exec \(callID)")
        }
        var argvStrings: [String] = []
        for entry in argv {
            guard let s = entry as? String else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv entries must be strings for exec \(callID)")
            }
            if s.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv entry contains NUL for exec \(callID)") }
            if s.utf8.count > maxPathLength { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv entry too long for exec \(callID)") }
            if !printableSafe(s) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv entry carries control bytes for exec \(callID)") }
            argvStrings.append(s)
        }
        // Identity honesty: argv[0] IS the executable (prevents argv[0]
        // spoofing the displayed command).
        guard argvStrings[0] == executable else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "argv[0] must equal executable for exec \(callID)")
        }
        var cwd: String? = nil
        if json.keys.contains("cwd") {
            guard let c = json["cwd"] as? String else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "cwd must be a string for exec \(callID)")
            }
            // Shape only (workspace-relative, byte-exact components);
            // existence/identity bind in the resolution phase.
            try validatePath(c, callID: callID, tool: "exec")
            cwd = c
        }
        var timeoutSecs = ExecArguments.defaultTimeoutSecs
        if json.keys.contains("timeoutSecs") {
            // Strict integer: JSON booleans and number-strings are refused.
            // NSNumber type-puns on corelibs (`0 is Bool` answers true), so
            // the ObjC type encoding is the discriminator: only "i"/"q"/"l"
            // (integer encodings) are accepted; "c" (boolean) and "d"
            // (double) are refused.
            guard let number = json["timeoutSecs"] as? NSNumber else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "timeoutSecs must be an integer for exec \(callID)")
            }
            let encoding = String(cString: number.objCType)
            guard encoding == "i" || encoding == "q" || encoding == "l", let t = number as? Int else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "timeoutSecs must be an integer for exec \(callID)")
            }
            guard t >= 1, t <= ExecArguments.maxTimeoutSecs else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "timeoutSecs out of range 1...\(ExecArguments.maxTimeoutSecs) for exec \(callID)")
            }
            timeoutSecs = t
        }
        var env: [String: String] = [:]
        if json.keys.contains("env") {
            guard let rawEnv = json["env"] as? [String: Any] else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env must be an object for exec \(callID)")
            }
            guard rawEnv.count <= ExecArguments.maxEnvEntries else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "too many env entries for exec \(callID)")
            }
            for (key, value) in rawEnv {
                guard key.utf8.count <= maxEnvKeyBytes, !key.isEmpty else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env key out of bounds for exec \(callID)")
                }
                let bytes = Array(key.utf8)
                func isNameByte(_ b: UInt8) -> Bool {
                    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F
                }
                func isNameStart(_ b: UInt8) -> Bool {
                    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
                }
                // [A-Za-z_][A-Za-z0-9_]*: the first byte may not be a digit.
                guard let first = bytes.first, isNameStart(first), bytes.dropFirst().allSatisfy(isNameByte) else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env key must match [A-Za-z_][A-Za-z0-9_]* for exec \(callID)")
                }
                if ExecEnvPolicy.isDenied(key: key) {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env key \(key) is denied for exec \(callID)")
                }
                guard let v = value as? String else {
                    throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env values must be strings for exec \(callID)")
                }
                if v.utf8.contains(0) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env value contains NUL for exec \(callID)") }
                if v.utf8.count > maxEnvValueBytes { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env value too large for exec \(callID)") }
                if !printableSafe(v) { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env value carries control bytes for exec \(callID)") }
                env[key] = v
            }
        }
        let args = ExecArguments(executable: executable, argv: argvStrings, cwd: cwd, timeoutSecs: timeoutSecs, env: env)
        // Bounded approval display: an unrenderable command is unapprovable.
        guard renderExecApprovalDisplay(args) != nil else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "command display exceeds the approval rendering bound for exec \(callID)")
        }
        return args
    }

    /// Re-parse path for the resolution phase (Runtime): JSON + duplicate
    /// keys + the same shape rules, returning the typed arguments.
    public static func execArguments(fromRaw raw: String) throws -> ExecArguments {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ExecResolutionError.qualification("exec arguments are not a JSON object")
        }
        return try parseExecArguments(callID: "resolve", json: json)
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
        // Protected-name matching is ASCII case-insensitive: on
        // case-insensitive filesystems ".NEEDLETAIL" IS ".needletail", so a
        // case variant must classify identically. This affects CLASSIFICATION
        // only — isApprovedPath/byteEqual stay byte-exact, so no approval
        // can be forged across case variants.
        func folded(_ s: String) -> String {
            // ASCII-only case fold (A-Z → a-z); every other byte passes
            // through, so UTF-8 validity is preserved by construction.
            String(bytes: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, encoding: .utf8) ?? s
        }
        let components = Self.byteComponents(of: path)
        for c in components.map(folded) {
            if c == ".needletail" { return .absoluteDenied }
            if c == "credentials" || c == ".credentials" { return .absoluteDenied }
            if c == "artifacts" || c.hasSuffix("-artifacts") { return .absoluteDenied }
        }
        let lowered = folded(path)
        if lowered.contains(".needletail/") || lowered == ".needletail" { return .absoluteDenied }
        if lowered.contains("/credentials") || lowered == "credentials" { return .absoluteDenied }
        guard let first = components.first.map(folded) else { return .unprotected }
        if first == ".git" { return .grantable }
        if components.map(folded).contains(where: { $0 == ".git" }) { return .grantable }
        if first == ".ssh" { return .grantable }
        if components.map(folded).contains(where: { $0 == ".ssh" }) { return .grantable }
        if first == ".env" || first.hasPrefix(".env.") { return .grantable }
        if components.map(folded).contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) { return .grantable }
        return .unprotected
    }
}
