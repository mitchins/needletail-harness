import Foundation

/// B5 harness-owned tool advertisement (REV25 §5/B5, discovery-only).
///
/// The harness — never the model, never config — owns the strict JSON
/// Schema definitions for the four file tools. `definitions(for:)`
/// intersects the ALREADY-folded effective capabilities: a tool is
/// advertised iff its capability bit is on. `exec`, `consult` and `diff`
/// are NEVER advertised under any capabilities (denied in M2-B, tested).
///
/// Advertisement is discovery-only: execution still validates every
/// argument through `ToolValidator.validateBatchArguments` (strict
/// Codable/hand validators). A schema-conformant proposal can still be
/// rejected at dispatch (stale hashes, protected paths, quotas); a
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
    public func json() -> String {
        let obj: [String: Any] = [
            "description": description,
            "name": name,
            "parameters": (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8), options: [])) ?? [:],
            "strict": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum ToolAdvertisement {
    /// Definitions visible under the given (already intersected) effective
    /// tool capabilities, in fixed order read/search/edit/write. Never
    /// contains exec, consult or diff.
    public static func definitions(for tools: ToolCapabilities) -> [ToolDefinition] {
        var out: [ToolDefinition] = []
        if tools.read { out.append(readDefinition) }
        if tools.search { out.append(searchDefinition) }
        if tools.edit { out.append(editDefinition) }
        if tools.write { out.append(writeDefinition) }
        return out
    }

    public static func names(for tools: ToolCapabilities) -> [String] {
        definitions(for: tools).map(\.name)
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
