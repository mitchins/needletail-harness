import Foundation // JSONSerialization for shape detection only: no I/O.

/// M1-B sealed-prompt admission (POLICY-03 + correction C1). Sealed
/// restrictions bind CAPABILITIES and ACTIONS — not prose. A sealed message
/// that merely MENTIONS tool calls (`see {"tool":"read"}`) or paths
/// (`/tmp is full`) still admits as text; only an ACTIONABLE invocation is
/// denied: (a) the whole trimmed message parses as a tool-call object, or
/// (b) a line issues an explicit execution directive for an absolute path.
/// Denial is typed and never reads the workspace (the packet's own byte
/// range is the only sealed-readable path, resolved by the caller — never
/// by model-directed access).
public enum SealedAdmission: Sendable, Equatable {
    case admittedText(String)
    case deniedToolShape(String)
    case deniedPathScope(String)
}

private let toolDirectivePrefixes = ["/read", "/exec", "/run", "/write", "/edit"]

public func validateSealedInput(_ text: String) -> SealedAdmission {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // (a) Whole-message tool-call object: {"tool": "...", ...}.
    if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       object["tool"] is String {
        return .deniedToolShape("message is a tool invocation, not a prompt")
    }
    // (b) Explicit execution directives for absolute paths, line by line:
    // a command prefix followed by whitespace and an absolute path, or an
    // @-reference to an absolute path.
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        for prefix in toolDirectivePrefixes where lower.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            if let first = rest.first, first.isWhitespace {
                let target = rest.trimmingCharacters(in: .whitespaces)
                if target.hasPrefix("/") {
                    return .deniedPathScope("sealed directive targets '\(terminalSafe(String(target.prefix(64))))'")
                }
            }
        }
        if line.hasPrefix("@/") {
            return .deniedPathScope("sealed reference targets '\(terminalSafe(String(line.prefix(64))))'")
        }
    }
    return .admittedText(text)
}
