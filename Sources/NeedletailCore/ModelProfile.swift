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
    public var alias: String
    public var wireProtocol: WireProtocol
    /// Normalized base: trailing slash stripped, otherwise verbatim
    /// (explicit `/v1`-style prefixes preserved).
    public var baseURL: String
    /// Origin derived by discarding the path prefix
    /// (`scheme://host[:port]`, lowercased host, default port omitted).
    public var origin: String
    /// The preserved path prefix (`""` when the base is a bare origin).
    public var pathPrefix: String
    /// Opaque served model ID: stored and compared as a string, never
    /// coerced, never normalized.
    public var modelID: String
    public var contextWindow: Int
    public var maxOutput: Int
    public var locality: Locality
    public var credential: CredentialReference?
    public var connectTimeout: Int
    public var readIdleTimeout: Int
    public var requestTimeout: Int
    public var maxInFlight: Int
    public var requestOptions: [String: JSONValue]
    /// Verbatim source bytes of the `request_options` object for lossless
    /// epoch comparison (never `Dictionary` iteration order).
    public var requestOptionsRaw: Data
    public var unqualifiedOptions: [String]

    public init(
        alias: String, wireProtocol: WireProtocol, baseURL: String, origin: String,
        pathPrefix: String, modelID: String, contextWindow: Int, maxOutput: Int,
        locality: Locality, credential: CredentialReference?,
        connectTimeout: Int, readIdleTimeout: Int, requestTimeout: Int,
        maxInFlight: Int, requestOptions: [String: JSONValue],
        requestOptionsRaw: Data, unqualifiedOptions: [String]
    ) {
        self.alias = alias
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.origin = origin
        self.pathPrefix = pathPrefix
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

    /// Reference-only rendering: origins and references, never secret
    /// values and never `request_options` values.
    public var redactedDescription: String {
        let credential = credential?.redactedDescription ?? "none"
        return "profile \(alias) \(wireProtocol.rawValue) \(origin) \(locality.rawValue) model \(modelID) ctx \(contextWindow) out \(maxOutput) credential \(credential) unqualified:\(unqualifiedOptions.count)"
    }
}

public struct ConfigSnapshot: Sendable, Equatable {
    public var version: Int
    public var profiles: [String: ModelProfile]
    public var defaultAlias: String
    public var allowHTTPOrigins: [String]
    public var tools: ToolCapabilities

    public init(version: Int, profiles: [String: ModelProfile], defaultAlias: String, allowHTTPOrigins: [String], tools: ToolCapabilities) {
        self.version = version
        self.profiles = profiles
        self.defaultAlias = defaultAlias
        self.allowHTTPOrigins = allowHTTPOrigins
        self.tools = tools
    }

    public var redactedDescription: String {
        "config version \(version) default \(defaultAlias) models \(profiles.count) origins \(allowHTTPOrigins.count)"
    }
}

public struct ProfileSnapshot: Sendable, Equatable {
    public var profile: ModelProfile
    public var effectiveCaps: EffectiveCapabilities

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
