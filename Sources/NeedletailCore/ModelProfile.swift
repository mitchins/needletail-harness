import Foundation // Value types only (Data): no platform I/O.

/// M1-A immutable model profiles and configuration snapshots (SPEC
/// §5.1–5.3). All values; `let`-only. A snapshot is built once per process
/// start (or `config validate` run) and shared by value through a request
/// epoch. The epoch transition that consumes `requiresNewEpoch` is M1-B.
///
/// Layering note: the wire-protocol and locality vocabularies are mirrored
/// here as `WireProtocol`/`Locality` (same raw strings as Providers'
/// `NativeProtocol`/`LocalityClass`) so Core never imports Providers.
/// An integration test pins the two vocabularies equal.
public enum WireProtocol: String, Sendable, Equatable, CaseIterable {
    case openAIChatCompletions = "openai-chat-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"

    /// The single path suffix appended to the configured base (rev4-A: the
    /// configured prefix is preserved; nothing is guessed, no `/v1` added).
    public var endpointSuffix: String {
        switch self {
        case .openAIChatCompletions: return "/chat/completions"
        case .openAIResponses: return "/responses"
        case .anthropicMessages: return "/messages"
        }
    }
}

public enum Locality: String, Sendable, Equatable {
    case local
    case cloud
}

public struct ModelProfile: Sendable, Equatable {
    public let alias: String
    public let wireProtocol: WireProtocol
    /// Normalized base: trailing slash stripped, otherwise verbatim
    /// (explicit `/v1`-style prefixes preserved).
    public let baseURL: String
    /// Origin derived from `baseURL` at construction
    /// (`scheme://host[:port]`, lowercased host, default port omitted).
    /// Diagnostics only — authorization re-derives from `baseURL` at the
    /// security boundary and never trusts this field (H1).
    public let origin: String
    /// The preserved path prefix (`""` for a bare origin).
    public let pathPrefix: String
    /// Opaque served model ID: stored and compared as a string, never
    /// coerced, never normalized.
    public let modelID: String
    public let contextWindow: Int
    public let maxOutput: Int
    public let locality: Locality
    public let credential: CredentialReference?
    public let connectTimeout: Int
    public let readIdleTimeout: Int
    public let requestTimeout: Int
    public let maxInFlight: Int
    public let requestOptions: [String: JSONValue]
    /// Verbatim source bytes of the `request_options` object for lossless
    /// epoch comparison (never `Dictionary` iteration order).
    public let requestOptionsRaw: Data
    public let unqualifiedOptions: [String]

    /// The only construction path (H1): the origin and prefix are derived
    /// from `baseURL` here, so a profile can never hold a base URL that
    /// disagrees with its stored origin. Post-construction mutation is
    /// impossible (`let` throughout) — the stale-origin bypass has no
    /// expression in this API. Range checks mirror the loader's so a
    /// hand-built profile cannot smuggle invalid limits either.
    public init(
        alias: String, wireProtocol: WireProtocol, baseURL: String,
        modelID: String, contextWindow: Int, maxOutput: Int,
        locality: Locality, credential: CredentialReference?,
        connectTimeout: Int, readIdleTimeout: Int, requestTimeout: Int,
        maxInFlight: Int, requestOptions: [String: JSONValue],
        requestOptionsRaw: Data, unqualifiedOptions: [String] = [],
        path: String = "$.profile"
    ) throws {
        guard !alias.isEmpty else {
            throw ConfigError(
                path: "\(path).alias", kind: .typeMismatch,
                message: "alias must not be empty.",
                hint: "give the profile a short unique handle.")
        }
        guard !modelID.isEmpty else {
            throw ConfigError(
                path: "\(path).model", kind: .typeMismatch,
                message: "served model ID must not be empty.",
                hint: "use the exact served ID as a string.")
        }
        let parsed = try parseBaseURL(baseURL, path: "\(path).base_url")
        try Self.checkRange(contextWindow, range: ConfigLimits.contextWindow, path: "\(path).context_window")
        try Self.checkRange(maxOutput, range: ConfigLimits.maxOutput, path: "\(path).max_output")
        try Self.checkRange(connectTimeout, range: ConfigLimits.connectTimeout, path: "\(path).connect_timeout_s")
        try Self.checkRange(readIdleTimeout, range: ConfigLimits.readIdleTimeout, path: "\(path).read_idle_timeout_s")
        try Self.checkRange(requestTimeout, range: ConfigLimits.requestTimeout, path: "\(path).request_timeout_s")
        try Self.checkRange(maxInFlight, range: ConfigLimits.maxInFlight, path: "\(path).max_in_flight")
        guard connectTimeout <= readIdleTimeout, readIdleTimeout <= requestTimeout else {
            throw ConfigError(
                path: path, kind: .unsupportedCombination,
                message: "timeouts must satisfy connect ≤ read_idle ≤ request.",
                hint: "raise the outer deadlines or lower the inner ones.")
        }
        self.alias = alias
        self.wireProtocol = wireProtocol
        self.baseURL = parsed.base
        self.origin = parsed.origin
        self.pathPrefix = parsed.prefix
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.locality = locality
        self.credential = credential
        self.connectTimeout = connectTimeout
        self.readIdleTimeout = readIdleTimeout
        self.requestTimeout = requestTimeout
        self.maxInFlight = maxInFlight
        self.requestOptions = requestOptions
        self.requestOptionsRaw = requestOptionsRaw
        self.unqualifiedOptions = unqualifiedOptions
    }

    private static func checkRange(_ value: Int, range: ClosedRange<Int>, path: String) throws {
        guard range.contains(value) else {
            throw ConfigError(
                path: path, kind: .limitExceeded,
                message: "value \(value) is outside \(range.lowerBound)...\(range.upperBound).",
                hint: "set a value inside the documented range.")
        }
    }

    /// Reference-only rendering: origins and references, never secret
    /// values and never `request_options` values. Operator-supplied
    /// identity fields render through `terminalSafe` (H2); the stored
    /// values keep their exact bytes.
    public var redactedDescription: String {
        let credential = credential?.redactedDescription ?? "none"
        return "profile \(terminalSafe(alias)) \(wireProtocol.rawValue) \(origin) \(locality.rawValue) model \(terminalSafe(modelID)) ctx \(contextWindow) out \(maxOutput) credential \(credential) unqualified:\(unqualifiedOptions.count)"
    }
}

public struct ConfigSnapshot: Sendable, Equatable {
    public let version: Int
    public let profiles: [String: ModelProfile]
    public let defaultAlias: String
    public let allowHTTPOrigins: [String]
    public let tools: ToolCapabilities

    public init(version: Int, profiles: [String: ModelProfile], defaultAlias: String, allowHTTPOrigins: [String], tools: ToolCapabilities) {
        self.version = version
        self.profiles = profiles
        self.defaultAlias = defaultAlias
        self.allowHTTPOrigins = allowHTTPOrigins
        self.tools = tools
    }

    public var redactedDescription: String {
        "config version \(version) default \(terminalSafe(defaultAlias)) models \(profiles.count) origins \(allowHTTPOrigins.count)"
    }
}

public struct ProfileSnapshot: Sendable, Equatable {
    public let profile: ModelProfile
    public let effectiveCaps: EffectiveCapabilities

    public init(profile: ModelProfile, effectiveCaps: EffectiveCapabilities) {
        self.profile = profile
        self.effectiveCaps = effectiveCaps
    }
}

/// True when switching from `old` to `new` requires a subsequent epoch
/// transition: any identity, route, or cache-relevant generation change.
/// `request_options` compare on retained raw bytes, origins as strings.
public func requiresNewEpoch(old: ModelProfile, new: ModelProfile) -> Bool {
    old.alias != new.alias
        || old.wireProtocol != new.wireProtocol
        || old.baseURL != new.baseURL
        || old.modelID != new.modelID
        || old.locality != new.locality
        || old.contextWindow != new.contextWindow
        || old.maxOutput != new.maxOutput
        || old.requestOptionsRaw != new.requestOptionsRaw
}

/// Snapshot-level epoch predicate (S2): the tool-set lives on the
/// snapshot, not the profile, so a tools-config change must also force a
/// new epoch. M1-B compares snapshot tools itself where finer granularity
/// helps; this predicate is the coarse gate.
public func requiresNewEpoch(old: ConfigSnapshot, new: ConfigSnapshot) -> Bool {
    old.defaultAlias != new.defaultAlias
        || old.tools != new.tools
        || old.allowHTTPOrigins != new.allowHTTPOrigins
        || old.profiles.keys != new.profiles.keys
        || old.profiles.keys.contains(where: { key in
            guard let a = old.profiles[key], let b = new.profiles[key] else { return true }
            return requiresNewEpoch(old: a, new: b)
        })
}
