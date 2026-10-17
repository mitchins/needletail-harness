import Foundation

/// M1-A configuration loading and semantic validation (SPEC §5).
/// Pipeline: byte-size gate → bounded duplicate preflight → strict typed
/// decode → semantic checks (ranges, origins, aliases, references, reserved
/// namespace). Everything is pure over the input bytes; file reading stays
/// in the CLI. No network, no credential resolution, no secret output.
public func validateConfig(_ data: Data) throws -> ConfigSnapshot {
    guard data.count <= ConfigLimits.maxFileBytes else {
        throw ConfigError(
            path: "$", kind: .fileTooLarge,
            message: "configuration exceeds \(ConfigLimits.maxFileBytes) bytes.",
            hint: "split native options out or shrink the file; files are rejected before decoding.")
    }
    let bytes = Array(data)
    let preflight = try scanJSONStructure(bytes)
    let document: ConfigDocument
    do {
        document = try JSONDecoder().decode(ConfigDocument.self, from: data)
    } catch let error as DecodingError {
        throw configError(from: error)
    }
    return try validateDocument(document, preflight: preflight, bytes: bytes)
}

private func validateDocument(_ document: ConfigDocument, preflight: PreflightResult, bytes: [UInt8]) throws -> ConfigSnapshot {
    guard document.version == 1 else {
        throw ConfigError(
            path: "$.version", kind: .unsupportedCombination,
            message: "unsupported configuration version \(document.version).",
            hint: "M1-A reads version 1 only; newer versions fail closed, never migrate silently.")
    }
    guard ConfigLimits.allowOrigins.contains(document.allowHTTPOrigins.count) else {
        throw ConfigError(
            path: "$.allow_http_origins", kind: .limitExceeded,
            message: "too many origin entries.",
            hint: "keep at most \(ConfigLimits.allowOrigins.upperBound) explicit origins.")
    }
    var origins: [String] = []
    for (index, entry) in document.allowHTTPOrigins.enumerated() {
        origins.append(try parseOriginEntry(entry, path: "$.allow_http_origins[\(index)]"))
    }
    guard !document.models.isEmpty else {
        throw ConfigError(
            path: "$.models", kind: .missingField,
            message: "at least one model profile is required.",
            hint: "configure the explicit local profile in examples/config.local.json.")
    }
    var profiles: [String: ModelProfile] = [:]
    // Byte-exact duplicate detection (CFG-05): Swift String equality is
    // canonical (composed == decomposed), so identities compare as UTF-8
    // bytes and are never normalized or merged. Pairs that are byte-distinct
    // but canonically equivalent are refused loudly (never merged): the
    // snapshot dictionary cannot hold both, and silent merging would be
    // normalization by another name.
    var aliasBytes: Set<[UInt8]> = []
    var canonicalAliases: [String: String] = [:]
    var identities: Set<[UInt8]> = []
    for (index, model) in document.models.enumerated() {
        let base = "$.models[\(index)]"
        let profile = try validateModel(model, path: base, origins: origins, preflight: preflight, bytes: bytes)
        if !aliasBytes.insert(Array(profile.alias.utf8)).inserted {
            throw ConfigError(
                path: "\(base).alias", kind: .duplicateKey,
                message: "duplicate model alias '\(profile.alias)'.",
                hint: "aliases are byte-exact unique handles (no Unicode normalization); rename one.")
        }
        if let first = canonicalAliases[profile.alias],
           !first.utf8.elementsEqual(profile.alias.utf8) {
            throw ConfigError(
                path: "\(base).alias", kind: .duplicateKey,
                message: "alias '\(profile.alias)' is canonically equivalent to '\(first)' under Unicode.",
                hint: "the two names differ only by normalization and cannot coexist in one file; rename to differ beyond normalization.")
        }
        canonicalAliases[profile.alias] = profile.alias
        // Normalized identity (S5): origin (lowercased host, default port
        // omitted) plus the preserved prefix, so host-case or explicit
        // default-port spellings of one endpoint still collide.
        let identity = Array("\(profile.origin)\n\(profile.pathPrefix)\n\(profile.wireProtocol.rawValue)\n\(profile.modelID)".utf8)
        if !identities.insert(identity).inserted {
            throw ConfigError(
                path: base, kind: .duplicateKey,
                message: "duplicate endpoint plus model identity.",
                hint: "the same model ID on the same base URL and protocol must appear once.")
        }
        profiles[profile.alias] = profile
    }
    guard profiles[document.defaultModel] != nil else {
        throw ConfigError(
            path: "$.default_model", kind: .missingReference,
            message: "default model '\(document.defaultModel)' names no configured alias.",
            hint: "point default_model at one of: \(profiles.keys.sorted().joined(separator: ", ")).")
    }
    return ConfigSnapshot(
        version: 1, profiles: profiles,
        defaultAlias: document.defaultModel,
        allowHTTPOrigins: origins, tools: mapTools(document.tools))
}

private func validateModel(
    _ model: ConfigModel, path: String, origins: [String],
    preflight: PreflightResult, bytes: [UInt8]
) throws -> ModelProfile {
    guard let wire = WireProtocol(rawValue: model.proto) else {
        throw ConfigError(
            path: "\(path).protocol", kind: .typeMismatch,
            message: "unknown protocol '\(model.proto)'.",
            hint: "use one of: \(WireProtocol.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    guard let locality = Locality(rawValue: model.locality) else {
        throw ConfigError(
            path: "\(path).locality", kind: .typeMismatch,
            message: "unknown locality '\(model.locality)'.",
            hint: "use \"local\" or \"cloud\"; the label is an operator trust assertion.")
    }
    // URL consistency, emptiness and ranges are enforced by the single
    // construction choke point with this model's exact path (H1). Only the
    // raw-bytes attachment and reserved-namespace check happen here, after
    // which the profile is rebuilt with its verbatim evidence attached.
    let credential: CredentialReference?
    if let descriptor = model.credential {
        credential = try CredentialReference(descriptor: descriptor)
    } else {
        credential = nil
    }
    let optionsPath = "\(path).request_options"
    let raw: Data
    if model.requestOptions.isEmpty, preflight.requestOptionsRanges[optionsPath] == nil {
        raw = Data()
    } else {
        guard let range = preflight.requestOptionsRanges[optionsPath] else {
            throw ConfigError(
                path: optionsPath, kind: .malformedJSON,
                message: "request_options range missing from preflight.",
                hint: "re-run validation on the unmodified file.")
        }
        raw = Data(bytes[range])
    }
    guard raw.count <= ConfigLimits.maxRequestOptionsBytes else {
        throw ConfigError(
            path: optionsPath, kind: .limitExceeded,
            message: "request_options exceeds \(ConfigLimits.maxRequestOptionsBytes) bytes.",
            hint: "shrink native options; the namespace stays inert and bounded.")
    }
    try checkReservedKeys(model.requestOptions, path: optionsPath)
    let profile = try ModelProfile(
        alias: model.alias, wireProtocol: wire, baseURL: model.baseURL,
        modelID: model.model, contextWindow: model.contextWindow,
        maxOutput: model.maxOutput, locality: locality, credential: credential,
        connectTimeout: model.connectTimeout, readIdleTimeout: model.readIdleTimeout,
        requestTimeout: model.requestTimeout, maxInFlight: model.maxInFlight,
        requestOptions: model.requestOptions, requestOptionsRaw: raw,
        unqualifiedOptions: model.requestOptions.keys.sorted(), path: path)
    guard origins.contains(profile.origin) else {
        throw ConfigError(
            path: "\(path).base_url", kind: .originNotAllowlisted,
            message: "origin \(profile.origin) is not allow-listed.",
            hint: "add exactly this origin to allow_http_origins, or fix the base URL.")
    }
    return profile
}

private func mapTools(_ tools: ConfigTools) -> ToolCapabilities {
    ToolCapabilities(
        read: tools.read, search: tools.search, edit: tools.edit,
        write: tools.write, exec: tools.exec, consult: tools.consult)
}

/// Harness-owned `request_options` keys (SPEC §5). Compared normalized:
/// ASCII-lowercased with `-`/`_` removed, so `API_KEY`, `apiKey` and
/// `X-Api-Key` cannot slip past the exact spellings. Only the top level of
/// `request_options` is harness-owned; nested objects are operator data.
private let reservedOptionKeys: Set<String> = [
    "model", "messages", "input", "tools", "toolchoice", "paralleltoolcalls",
    "stream", "streamoptions", "system", "history", "auth", "authorization",
    "apikey", "xapikey", "credentials", "credential", "bearer", "cookie",
    "password", "passwd", "proxy", "baseurl", "url", "endpoint",
    "responseformat", "store", "metadata",
]

func normalizeOptionKey(_ key: String) -> String {
    key.lowercased().filter { $0 != "-" && $0 != "_" }
}

private func checkReservedKeys(_ options: [String: JSONValue], path: String) throws {
    for key in options.keys.sorted() where reservedOptionKeys.contains(normalizeOptionKey(key)) {
        throw ConfigError(
            path: "\(path).\(key)", kind: .reservedOverride,
            message: "request_options key '\(key)' overrides a harness-owned field.",
            hint: "remove it; inert native options can never set model, history, tools, stream or auth fields.")
    }
}

// MARK: - Base URLs and origins (rev4-A)

public struct ParsedBaseURL: Sendable, Equatable {
    /// Normalized base: lowercased scheme, verbatim authority, preserved
    /// prefix, single trailing slash stripped.
    public var base: String
    /// Origin with the path prefix discarded (lowercased host, default
    /// port omitted) for allow-list comparison — a prefix never widens it.
    public var origin: String
    /// The preserved path prefix (`""` for a bare origin).
    public var prefix: String
}

private let endpointSuffixes = ["/chat/completions", "/responses", "/messages"]

/// Parses `scheme://host[:port][/path-prefix]` strictly. Rejects userinfo,
/// queries, fragments, whitespace, backslashes, empty segments,
/// dot-segments (including percent-encoded forms in either case), encoded
/// slashes, and prefixes that already end in a protocol suffix.
public func parseBaseURL(_ string: String, path: String) throws -> ParsedBaseURL {
    let malformed: (String, String) -> ConfigError = { message, hint in
        ConfigError(path: path, kind: .malformedOrigin, message: message, hint: hint)
    }
    guard !string.isEmpty else {
        throw malformed("base URL must not be empty.", "use \"http://127.0.0.1:11434\" or an explicit \"/v1\"-style prefix.")
    }
    guard let colon = string.firstIndex(of: ":") else {
        throw malformed("base URL '\(string)' has no scheme.", "start with http:// or https://.")
    }
    let scheme = String(string[..<colon])
    guard scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil else {
        throw malformed("bad scheme in '\(string)'.", "start with http:// or https://.")
    }
    guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else {
        throw malformed("scheme '\(scheme)' is not http or https.", "use an http(s) origin.")
    }
    var rest = String(string[string.index(after: colon)...])
    guard rest.hasPrefix("//") else {
        throw malformed("base URL '\(string)' needs \"//\" after the scheme.", "use the form scheme://host[:port][/prefix].")
    }
    rest = String(rest.dropFirst(2))
    if rest.contains("?") || rest.contains("#") {
        throw malformed("queries and fragments are not endpoint configuration.", "use a bare origin plus path prefix only.")
    }
    // Authority ends at the first "/"; anything after is the path.
    let authority: String
    var rawPath = ""
    if let slash = rest.firstIndex(of: "/") {
        authority = String(rest[..<slash])
        rawPath = String(rest[slash...])
    } else {
        authority = rest
    }
    if authority.contains("@") {
        throw malformed("userinfo/credentials do not belong in endpoint configuration.", "configure credentials via the credential reference, not the URL.")
    }
    let (host, port) = try splitAuthority(authority, path: path, malformed: malformed)
    guard !host.isEmpty else {
        throw malformed("empty host in '\(string)'.", "name the loopback or LAN host explicitly.")
    }
    // H2-2: reject every control (C0, DEL and C1 alike — not just ASCII)
    // and every whitespace separator (space is Zs, not Cc), so no
    // ambiguous byte can reach origin/endpoint display strings.
    for scalar in host.unicodeScalars
        where scalar.properties.generalCategory == .control || scalar.properties.isWhitespace || scalar == "\\" {
        throw malformed("host contains whitespace, controls or a backslash.", "use a plain hostname or IP literal.")
    }
    let lowerHost = host.lowercased()
    let defaultPort = scheme.lowercased() == "http" ? 80 : 443
    let portSuffix: String
    if let explicit = port {
        portSuffix = explicit == defaultPort ? "" : ":\(explicit)"
    } else {
        portSuffix = ""
    }
    let hostForOrigin = authority.hasPrefix("[") ? "[\(lowerHost)]" : lowerHost
    let origin = "\(scheme.lowercased())://\(hostForOrigin)\(portSuffix)"
    // Path validation on the raw text first (structural), then decoded.
    if rawPath.contains("\\") {
        throw malformed("backslashes are not path separators.", "use forward slashes.")
    }
    if rawPath.contains("//") {
        throw malformed("empty path segments (\"//\") are ambiguous.", "write each prefix segment once.")
    }
    var stripped = rawPath
    if stripped.hasSuffix("/"), stripped.count > 1 {
        stripped = String(stripped.dropLast())
    }
    if stripped == "/" {
        throw malformed("a lone \"/\" is not a prefix.", "use a bare origin or a real prefix like /v1.")
    }
    var segments: [String] = []
    if !stripped.isEmpty {
        guard stripped.hasPrefix("/") else {
            throw malformed("internal path error.", "report this input.")
        }
        for rawSegment in stripped.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            guard !rawSegment.isEmpty else {
                throw malformed("empty path segments (\"//\") are ambiguous.", "write each prefix segment once.")
            }
            for scalar in rawSegment.unicodeScalars
                where scalar.properties.generalCategory == .control || scalar.properties.isWhitespace || scalar == "\\" {
                throw malformed("whitespace, controls or backslashes cannot appear in a base URL.",
                                "write the literal prefix without spaces or escapes.")
            }
            let decoded = try decodePathSegment(rawSegment, path: path, malformed: malformed)
            guard decoded != ".", decoded != ".." else {
                throw malformed("dot-segments cannot appear in a base URL.", "write the literal prefix; traversal is rejected.")
            }
            segments.append(rawSegment)
        }
    }
    let prefix = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    let lowerPrefix = prefix.lowercased()
    for suffix in endpointSuffixes where lowerPrefix == suffix || lowerPrefix.hasSuffix(suffix) {
        throw malformed("base URL already ends in the protocol suffix '\(suffix)'.",
                        "configure the base (with any /v1-style prefix); the harness appends the suffix once.")
    }
    return ParsedBaseURL(
        base: "\(scheme.lowercased())://\(authority)\(prefix)",
        origin: origin, prefix: prefix)
}

private func splitAuthority(
    _ authority: String, path: String,
    malformed: (String, String) -> ConfigError
) throws -> (host: String, port: Int?) {
    if authority.hasPrefix("[") {
        guard let close = authority.firstIndex(of: "]") else {
            throw malformed("unbalanced IPv6 brackets.", "write [::1] with a closing bracket.")
        }
        let host = String(authority[authority.index(after: authority.startIndex)..<close])
        let tail = String(authority[authority.index(after: close)...])
        if tail.isEmpty { return (host, nil) }
        guard tail.hasPrefix(":"), tail.count > 1, tail.dropFirst().allSatisfy({ $0.isNumber }) else {
            throw malformed("bad port after IPv6 literal.", "use [host]:port with digits.")
        }
        return try (host, checkedPort(String(tail.dropFirst()), path: path, malformed: malformed))
    }
    let colons = authority.filter { $0 == ":" }.count
    if colons > 1 {
        throw malformed("unbracketed colons in host.", "bracket IPv6 literals like [::1].")
    }
    if colons == 1 {
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isNumber }) else {
            throw malformed("bad host:port split in '\(authority)'.", "use host or host:digits.")
        }
        return try (parts[0], checkedPort(parts[1], path: path, malformed: malformed))
    }
    return (authority, nil)
}

private func checkedPort(
    _ text: String, path: String,
    malformed: (String, String) -> ConfigError
) throws -> Int? {
    guard let port = Int(text), (1...65_535).contains(port) else {
        throw malformed("port '\(text)' is out of range.", "use 1...65535 or omit the port.")
    }
    return port
}

/// Percent-decodes one segment; rejects encoded slashes and malformed
/// escapes. Comparison is on the decoded form in either `%2e` case.
private func decodePathSegment(
    _ segment: String, path: String,
    malformed: (String, String) -> ConfigError
) throws -> String {
    var bytes: [UInt8] = []
    let raw = Array(segment.utf8)
    var i = 0
    while i < raw.count {
        if raw[i] == 0x25 {
            guard i + 2 < raw.count,
                  let hi = hexValue(raw[i + 1]), let lo = hexValue(raw[i + 2]) else {
                throw malformed("bad percent-escape in path segment.", "use %XX with hex digits.")
            }
            let decoded = hi * 16 + lo
            guard decoded != 0x2F else {
                throw malformed("encoded slashes cannot appear in a base URL.", "write literal segments; masking structure is rejected.")
            }
            bytes.append(decoded)
            i += 3
        } else {
            bytes.append(raw[i])
            i += 1
        }
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else {
        throw malformed("path segment is not valid UTF-8.", "re-encode the base URL.")
    }
    for scalar in decoded.unicodeScalars
        where scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
        throw malformed("whitespace or controls cannot appear in a base URL, encoded or not.",
                        "write the literal prefix without spaces or escapes.")
    }
    // Defense in depth (S8): a decoded backslash would survive the raw-text
    // check above, so reject it here too.
    if decoded.contains("\\") {
        throw malformed("backslashes cannot appear in a base URL, encoded or not.",
                        "use forward slashes.")
    }
    return decoded
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x41...0x46: return byte - 0x41 + 10
    case 0x61...0x66: return byte - 0x61 + 10
    default: return nil
    }
}

/// Origin entries are origins only: the same grammar with no path.
public func parseOriginEntry(_ string: String, path: String) throws -> String {
    let parsed = try parseBaseURL(string, path: path)
    guard parsed.prefix.isEmpty else {
        throw ConfigError(
            path: path, kind: .malformedOrigin,
            message: "origin entries carry no path ('\(parsed.prefix)').",
            hint: "list scheme://host[:port] only; the profile base keeps its own prefix.")
    }
    return parsed.origin
}
