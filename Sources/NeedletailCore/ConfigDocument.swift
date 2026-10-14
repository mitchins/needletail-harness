import Foundation // Value types only (Data, JSONDecoder): no platform I/O.

/// M1-A typed configuration document (SPEC §5). Strict `Codable` layer:
/// unknown structural fields are rejected (Foundation ignores them by
/// default), and identity strings decode as `String` only — a JSON number
/// where an alias or model ID belongs is a `typeMismatch`, never coerced.
/// Duplicate keys cannot reach this layer: the bounded preflight runs first
/// on the same bytes. No filesystem, network or clock access.
public struct ConfigDocument: Sendable, Equatable, Decodable {
    public let version: Int
    public let defaultModel: String
    public let allowHTTPOrigins: [String]
    public let models: [ConfigModel]
    public let tools: ConfigTools

    enum Known: String, CaseIterable {
        case version, default_model, allow_http_origins, models, tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        try StrictKey.rejectUnknown(container, known: Known.allCases.map(\.rawValue), path: "$")
        do {
            version = try decodeInt(container, StrictKey("version"), path: "$.version")
            defaultModel = try container.decode(String.self, forKey: StrictKey("default_model"))
            allowHTTPOrigins = try container.decode([String].self, forKey: StrictKey("allow_http_origins"))
            models = try container.decode([ConfigModel].self, forKey: StrictKey("models"))
            tools = try container.decode(ConfigTools.self, forKey: StrictKey("tools"))
        } catch let error as DecodingError {
            throw configError(from: error)
        }
    }
}

/// A dynamic coding key for strict shape checks.
public struct StrictKey: CodingKey, Sendable, Hashable {
    public let stringValue: String
    public let intValue: Int?

    public init(_ string: String) { stringValue = string; intValue = nil }
    public init?(stringValue: String) { self.init(stringValue) }
    public init?(intValue: Int) { stringValue = "\(intValue)"; self.intValue = intValue }

    static func rejectUnknown(_ container: KeyedDecodingContainer<StrictKey>, known: [String], path: String) throws {
        let keys = Set(container.allKeys.map(\.stringValue))
        if let extra = keys.subtracting(known).sorted().first {
            throw ConfigError(
                path: path == "$" ? "$.\(extra)" : "\(path).\(extra)",
                kind: .unknownField,
                message: "unknown field '\(extra)'.",
                hint: "allowed fields here: \(known.sorted().joined(separator: ", ")).")
        }
    }
}

public struct ConfigModel: Sendable, Equatable, Decodable {
    public let alias: String
    public let proto: String
    public let baseURL: String
    public let model: String
    public let contextWindow: Int
    public let maxOutput: Int
    public let locality: String
    public let credential: CredentialDescriptor?
    public let connectTimeout: Int
    public let readIdleTimeout: Int
    public let requestTimeout: Int
    public let maxInFlight: Int
    public let requestOptions: [String: JSONValue]

    enum Known: String, CaseIterable {
        case alias, `protocol`, base_url, model, context_window, max_output
        case locality, credential
        case connect_timeout_s, read_idle_timeout_s, request_timeout_s
        case max_in_flight, request_options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        let path = formatFieldPath(decoder.codingPath)
        try StrictKey.rejectUnknown(container, known: Known.allCases.map(\.rawValue), path: path)
        do {
            alias = try container.decode(String.self, forKey: StrictKey("alias"))
            proto = try container.decode(String.self, forKey: StrictKey("protocol"))
            baseURL = try container.decode(String.self, forKey: StrictKey("base_url"))
            model = try container.decode(String.self, forKey: StrictKey("model"))
            contextWindow = try decodeInt(container, StrictKey("context_window"), path: "\(path).context_window")
            maxOutput = try decodeInt(container, StrictKey("max_output"), path: "\(path).max_output")
            locality = try container.decode(String.self, forKey: StrictKey("locality"))
            credential = try container.decodeIfPresent(CredentialDescriptor.self, forKey: StrictKey("credential"))
            connectTimeout = try decodeInt(container, StrictKey("connect_timeout_s"), path: "\(path).connect_timeout_s")
            readIdleTimeout = try decodeInt(container, StrictKey("read_idle_timeout_s"), path: "\(path).read_idle_timeout_s")
            requestTimeout = try decodeInt(container, StrictKey("request_timeout_s"), path: "\(path).request_timeout_s")
            maxInFlight = try decodeInt(container, StrictKey("max_in_flight"), path: "\(path).max_in_flight")
            requestOptions = try container.decodeIfPresent([String: JSONValue].self, forKey: StrictKey("request_options")) ?? [:]
        } catch let error as DecodingError {
            throw configError(from: error)
        }
    }
}

/// Exactly one credential reference kind; zero, two or unknown keys fail.
/// The value is a reference (name/path/account), never a secret.
public struct CredentialDescriptor: Sendable, Equatable, Decodable {
    public let kind: String
    public let value: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        let path = formatFieldPath(decoder.codingPath)
        let keys = container.allKeys.map(\.stringValue)
        let known = ["env", "file", "keychain"]
        for key in keys.sorted() where !known.contains(key) {
            throw ConfigError(
                path: "\(path).\(key)", kind: .unknownField,
                message: "unknown credential kind '\(key)'.",
                hint: "use exactly one of: env, file, keychain.")
        }
        guard keys.count == 1, let only = keys.first else {
            throw ConfigError(
                path: path, kind: .typeMismatch,
                message: "credential holds \(keys.count) references; exactly one is required.",
                hint: #"use one shape, e.g. {"env":"VAR_NAME"}."#)
        }
        do {
            let value = try container.decode(String.self, forKey: StrictKey(only))
            guard !value.isEmpty else {
                throw ConfigError(
                    path: "\(path).\(only)", kind: .typeMismatch,
                    message: "credential reference must not be empty.",
                    hint: "name the variable, file path or keychain account.")
            }
            kind = only
            self.value = value
        } catch let error as DecodingError {
            throw configError(from: error)
        }
    }
}

public struct ConfigTools: Sendable, Equatable, Decodable {
    public let read: Bool
    public let search: Bool
    public let edit: Bool
    public let write: Bool
    public let exec: ExecPolicy
    public let consult: Bool

    enum Known: String, CaseIterable {
        case read, search, edit, write, exec, consult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictKey.self)
        let path = formatFieldPath(decoder.codingPath)
        try StrictKey.rejectUnknown(container, known: Known.allCases.map(\.rawValue), path: path)
        do {
            // Absent tool keys default to denied (explicitness over
            // convenience); nothing here can grant.
            read = try container.decodeIfPresent(Bool.self, forKey: StrictKey("read")) ?? false
            search = try container.decodeIfPresent(Bool.self, forKey: StrictKey("search")) ?? false
            edit = try container.decodeIfPresent(Bool.self, forKey: StrictKey("edit")) ?? false
            write = try container.decodeIfPresent(Bool.self, forKey: StrictKey("write")) ?? false
            consult = try container.decodeIfPresent(Bool.self, forKey: StrictKey("consult")) ?? false
            if container.contains(StrictKey("exec")) {
                if let execBool = try? container.decode(Bool.self, forKey: StrictKey("exec")) {
                    exec = execBool ? .allowed : .denied
                } else if let execString = try? container.decode(String.self, forKey: StrictKey("exec")),
                          execString == "ask" {
                    exec = .ask
                } else {
                    throw ConfigError(
                        path: "\(path).exec", kind: .typeMismatch,
                        message: "exec policy must be true, false or \"ask\".",
                        hint: "use true, false or \"ask\"; absent means denied.")
                }
            } else {
                exec = .denied
            }
        } catch let error as DecodingError {
            throw configError(from: error)
        }
    }
}

/// Integer decode with a precise field error. (On this toolchain a JSON
/// fraction for an `Int` throws the private `JSONError` — not a
/// `DecodingError` — which the decoder machinery re-wraps as `dataCorrupted`
/// "not valid JSON" even though the document is valid JSON (verified by
/// probe in `.needletail-dev/logs/`). Catching everything here replaces
/// that misleading error with an exact `typeMismatch`: a successful decode
/// is the only non-throwing path, so any throw means the wrong type.)
func decodeInt(_ container: KeyedDecodingContainer<StrictKey>, _ key: StrictKey, path: String) throws -> Int {
    do {
        return try container.decode(Int.self, forKey: key)
    } catch {
        throw ConfigError(
            path: path, kind: .typeMismatch,
            message: "expected an integer here.",
            hint: "use whole digits in range; fractions, strings and booleans are never coerced.")
    }
}

/// Inert operator-owned native JSON (SPEC §5). Numbers decode as `Double`
/// for the typed view; the verbatim source bytes are retained separately
/// (`requestOptionsRaw`) for lossless epoch comparison and future requests.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Double.self) { self = .number(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        if let value = try? single.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? single.decode([String: JSONValue].self) { self = .object(value); return }
        throw configError(from: DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected JSON scalar, array or object")))
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let value): try single.encode(value)
        case .number(let value): try single.encode(value)
        case .bool(let value): try single.encode(value)
        case .null: try single.encodeNil()
        case .array(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        }
    }
}

/// Deterministic serialization: sorted keys, minimal escapes. The same
/// semantic content always renders the same bytes regardless of input key
/// order or process, so display and diagnostics stay stable.
public func canonicalJSON(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): return canonicalJSONString(text)
    case .number(let value):
        if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    case .array(let items): return "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
    case .object(let entries):
        return "{" + entries.keys.sorted().map { "\(canonicalJSONString($0)):\(canonicalJSON(entries[$0]!))" }.joined(separator: ",") + "}"
    }
}

public func canonicalJSONData(_ value: JSONValue) -> Data {
    Data(canonicalJSON(value).utf8)
}

private func canonicalJSONString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}
