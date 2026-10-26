import Foundation

/// B5 harness-owned tool advertisement (REV25 §5/B5, discovery-only).
///
/// The harness — never the model, never config — owns the JSON Schema
/// definitions for the four file tools. `definitions(for:)`
/// intersects the ALREADY-folded effective capabilities: a tool is
/// advertised iff its capability bit is on. `exec`, `consult` and `diff`
/// are NEVER advertised under any capabilities (denied in M2-B, tested).
///
/// Interop note: the emitted envelopes advertise `"strict": false`
/// EXPLICITLY. OpenAI strict mode requires every property in `required`,
/// which these contracts cannot satisfy (read: all-optional with a
/// path/artifactId XOR; edit/write: alias pairs and a conditional
/// expectedHash) — and must not be "fixed" by weakening the contracts.
/// Provider-side generation is therefore best-effort: the schema guides
/// the model, while `ToolValidator.validateBatchArguments` remains the
/// strict authority at dispatch. A schema-conformant proposal can still
/// be rejected (stale hashes, protected paths, quotas); a
/// schema-violating proposal never reaches the executor. The exact-schema
/// tests pin the wire shape; the round-trip test proves an advertised
/// proposal reaches the executor through the real actor loop.
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    /// Canonical parameters schema (sorted keys, no whitespace) — the
    /// exact bytes a provider request carries.
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// Canonical full definition JSON (sorted keys), as carried on the wire.
    /// `strict` is false (see the interop note above): the schemas carry
    /// optional and alternative (XOR/alias) properties that strict mode
    /// cannot express, so the flag must never be flipped to true without
    /// also making every property required — which would misrepresent
    /// the dispatch contracts.
    public func json() -> String {
        let obj: [String: Any] = [
            "description": description,
            "name": name,
            "parameters": (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8), options: [])) ?? [:],
            "strict": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum ToolAdvertisement {
    /// Definitions visible under the given (already intersected) effective
    /// tool capabilities, in fixed order read/search/edit/write. Never
    /// contains consult or diff. `exec` is advertised iff its effective
    /// policy is not denied AND the native executor is actually composed
    /// (plan REV12 §3.8 / NC-7): the demo/scripted backend never advertises
    /// exec, so `--trusted` cannot gain the tool by caps alone.
    public static func definitions(for tools: ToolCapabilities, nativeExecComposed: Bool = false) -> [ToolDefinition] {
        var out: [ToolDefinition] = []
        if tools.read { out.append(readDefinition) }
        if tools.search { out.append(searchDefinition) }
        if tools.edit { out.append(editDefinition) }
        if tools.write { out.append(writeDefinition) }
        if tools.exec != .denied && nativeExecComposed { out.append(execDefinition) }
        return out
    }

    public static func names(for tools: ToolCapabilities, nativeExecComposed: Bool = false) -> [String] {
        definitions(for: tools, nativeExecComposed: nativeExecComposed).map(\.name)
    }

    // MARK: - Strict schemas (mirror ToolValidator contracts)

    private static func schema(properties: [(String, String)], required: [String], descriptions: [String: String]) -> String {
        var props: [String: Any] = [:]
        for (key, type) in properties {
            var prop: [String: Any] = ["type": type]
            if let d = descriptions[key] { prop["description"] = d }
            props[key] = prop
        }
        let obj: [String: Any] = [
            "additionalProperties": false,
            "properties": props,
            "required": required,
            "type": "object",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let readDefinition = ToolDefinition(
        name: "read",
        description: "Read a file or a previously published artifact. Exactly one of path or artifactId selects the source; limit/offset page long files. Read-only: never mutates.",
        parametersJSON: schema(
            properties: [("artifactId", "string"), ("artifact_id", "string"), ("limit", "integer"), ("offset", "integer"), ("path", "string")],
            required: [],
            descriptions: [
                "artifactId": "64-hex digest of a previously published artifact.",
                "artifact_id": "Alias of artifactId.",
                "limit": "Max lines returned (1-10000).",
                "offset": "First line index (0-based).",
                "path": "Workspace-relative file path.",
            ]))

    private static let searchDefinition = ToolDefinition(
        name: "search",
        description: "Search workspace files. Pattern is required; path scopes the search to one directory. Read-only: never mutates.",
        parametersJSON: schema(
            properties: [("path", "string"), ("pattern", "string")],
            required: ["pattern"],
            descriptions: [
                "path": "Workspace-relative directory scope.",
                "pattern": "Ripgrep pattern (required, non-empty).",
            ]))

    private static let editDefinition = ToolDefinition(
        name: "edit",
        description: "Replace exactly one occurrence of old text in a file. expectedHash authorizes the replacement against the exact current bytes (optimistic concurrency). Mutating.",
        parametersJSON: schema(
            properties: [("expectedHash", "string"), ("newBytes", "string"), ("new_string", "string"), ("oldBytes", "string"), ("old_string", "string"), ("path", "string")],
            required: ["expectedHash", "path"],
            descriptions: [
                "expectedHash": "64-hex SHA-256 of the exact current file bytes.",
                "newBytes": "Replacement text (alias new_string).",
                "new_string": "Replacement text (alias newBytes).",
                "oldBytes": "Text to replace, exactly once (alias old_string).",
                "old_string": "Text to replace, exactly once (alias oldBytes).",
                "path": "Workspace-relative file path.",
            ]))

    /// M2-C C0 (plan REV12 §3.3): the exec discovery schema mirrors the
    /// strict dispatch contract exactly. Direct argv execution, absolute
    /// executable, workspace-relative cwd, bounded timeout, explicitly
    /// authorized environment overlay. Interpreters are ordinary host
    /// execution — never "read-only" by name (SPEC §10.4).
    static let execDefinition = ToolDefinition(
        name: "exec",
        description: "Run one explicitly authorized local command by absolute path. Direct argv execution (no shell, no PATH search): executable must be an absolute path and argv[0] must equal it. cwd is workspace-relative; timeoutSecs bounds the run (default 120, max 1800); env is an operator-approved overlay (loader variables, PATH and credential names are refused). Every invocation requires explicit operator approval of the resolved command. Not sandboxed: interpreters and build scripts execute with this session's privileges.",
        parametersJSON: schema(
            properties: [("argv", "array"), ("cwd", "string"), ("env", "object"), ("executable", "string"), ("timeoutSecs", "integer")],
            required: ["argv", "executable"],
            descriptions: [
                "argv": "Argument vector; argv[0] must equal executable. 1-64 string entries, no NUL or control bytes.",
                "cwd": "Workspace-relative working directory (optional; default: workspace root). Read-only roots are never exec cwds.",
                "env": "Additional environment entries approved verbatim by the operator (optional; denied names refused).",
                "executable": "Absolute path of the program to run. Resolved and content-hashed before approval; no PATH search.",
                "timeoutSecs": "Integer 1-1800 (optional; default 120). Effective deadline is min(requested, policy ceiling, remaining run deadline).",
            ]))

    private static let writeDefinition = ToolDefinition(
        name: "write",
        description: "Create a new file (exclusive; never overwrites) or, with expectedHash, replace a whole file whose current bytes hash exactly. Mutating.",
        parametersJSON: schema(
            properties: [("content", "string"), ("expectedHash", "string"), ("path", "string")],
            required: ["content", "path"],
            descriptions: [
                "content": "Full file content for create or replacement.",
                "expectedHash": "64-hex SHA-256 authorizing whole-file replacement.",
                "path": "Workspace-relative file path.",
            ]))
}
