/// M1-A strict-configuration errors (SPEC §5). Every failure carries the
/// JSON field path (`$.models[1].context_window`), a machine-readable kind,
/// a human message and an actionable hint. Descriptions never include secret
/// values, file bytes beyond the offending key path, or stack traces.
public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        case duplicateKey
        case unknownField
        case typeMismatch
        case missingField
        case limitExceeded
        case malformedJSON
        case malformedOrigin
        case originNotAllowlisted
        case reservedOverride
        case missingReference
        case contradictoryFlags
        case unsupportedCombination
        case unsupportedFormat
        case configNotFound
        case fileTooLarge
        case unsupportedPathEncoding
    }

    public var path: String
    public var kind: Kind
    public var message: String
    public var hint: String

    public init(path: String, kind: Kind, message: String, hint: String) {
        self.path = path
        self.kind = kind
        self.message = message
        self.hint = hint
    }

    /// Display boundary (H2): path, message and hint may carry
    /// operator-supplied names with smuggled controls; all three render
    /// through `terminalSafe`. The stored fields keep the exact bytes.
    public var description: String {
        "error \(terminalSafe(path)): \(kind.rawValue) — \(terminalSafe(message)) Fix: \(terminalSafe(hint))"
    }
}

/// Formats a `Decoder` coding path as a `$`-rooted field path
/// (`$.models[1].context_window`).
public func formatFieldPath(_ codingPath: [CodingKey]) -> String {
    var out = "$"
    for key in codingPath {
        if let index = key.intValue {
            out += "[\(index)]"
        } else {
            out += ".\(key.stringValue)"
        }
    }
    return out
}

/// Converts Foundation decoding failures into field-path errors without
/// losing the location. `ConfigError` values pass through untouched.
public func configError(from decodingError: DecodingError) -> ConfigError {
    switch decodingError {
    case .keyNotFound(let key, let context):
        return ConfigError(
            path: formatFieldPath(context.codingPath + [key]),
            kind: .missingField,
            message: "required field '\(key.stringValue)' is missing.",
            hint: "add the field; see schemas/config.schema.json for the required shape.")
    case .typeMismatch(_, let context):
        return ConfigError(
            path: formatFieldPath(context.codingPath),
            kind: .typeMismatch,
            message: "wrong JSON type here (\(context.debugDescription)).",
            hint: "match the documented type exactly; model IDs and aliases are strings, never numbers.")
    case .valueNotFound(_, let context):
        return ConfigError(
            path: formatFieldPath(context.codingPath),
            kind: .typeMismatch,
            message: "null is not accepted here.",
            hint: "provide a value or remove the key (absent tool keys default to denied).")
    case .dataCorrupted(let context):
        return ConfigError(
            path: formatFieldPath(context.codingPath),
            kind: .malformedJSON,
            message: "undecodable value (\(context.debugDescription)).",
            hint: "check number ranges and UTF-8 encoding around this path.")
    @unknown default:
        return ConfigError(
            path: "$", kind: .malformedJSON,
            message: "undecodable configuration.",
            hint: "validate the file as strict JSON first.")
    }
}
