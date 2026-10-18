import Foundation

/// M2-A A0: lossless persistence conformances for the durable record graph
/// (SPEC §9). Additive only — no behavior changes, no new imports. ID
/// wrappers (SessionIDs.swift), QueueKind/QueueEntryState, NativeToolCall
/// and JSONValue were already Codable; the remaining types carry `Codable`
/// AT THEIR DECLARATION SITES (Swift 6.4 requires same-file declaration
/// for synthesis when a type declares its own inits).
///
/// INTEGRITY RULE (H1 analogue): `ModelProfile` is the ONE hand-written
/// conformance. Its `init(from:)` routes through the VALIDATING public
/// init, which re-derives `origin` and `pathPrefix` from `baseURL` —
/// synthesized decoding would assign fields directly and let a tampered
/// store row resurrect a profile whose stored origin disagrees with its
/// base URL. The stale-origin bypass has no expression in this API, and
/// decoding is not allowed to add one. The derived fields (`origin`,
/// `pathPrefix`) are likewise never ENCODED.
extension ModelProfile: Codable {
    enum CodingKeys: String, CodingKey {
        case alias, wireProtocol, baseURL, modelID
        case contextWindow, maxOutput, locality, credential
        case connectTimeout, readIdleTimeout, requestTimeout, maxInFlight
        case requestOptions, requestOptionsRaw, unqualifiedOptions
        // `origin` and `pathPrefix` are DERIVED at construction and are
        // deliberately absent: they are never written and never trusted
        // back (re-derived by the validating init below).
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode through the VALIDATING init: range checks and origin
        // derivation run exactly as for configuration loading, so a
        // corrupted row fails the decode instead of constructing an
        // invalid profile.
        try self.init(
            alias: try container.decode(String.self, forKey: .alias),
            wireProtocol: try container.decode(WireProtocol.self, forKey: .wireProtocol),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            modelID: try container.decode(String.self, forKey: .modelID),
            contextWindow: try container.decode(Int.self, forKey: .contextWindow),
            maxOutput: try container.decode(Int.self, forKey: .maxOutput),
            locality: try container.decode(Locality.self, forKey: .locality),
            credential: try container.decodeIfPresent(CredentialReference.self, forKey: .credential),
            connectTimeout: try container.decode(Int.self, forKey: .connectTimeout),
            readIdleTimeout: try container.decode(Int.self, forKey: .readIdleTimeout),
            requestTimeout: try container.decode(Int.self, forKey: .requestTimeout),
            maxInFlight: try container.decode(Int.self, forKey: .maxInFlight),
            requestOptions: try container.decode([String: JSONValue].self, forKey: .requestOptions),
            requestOptionsRaw: try container.decode(Data.self, forKey: .requestOptionsRaw),
            unqualifiedOptions: try container.decodeIfPresent([String].self, forKey: .unqualifiedOptions) ?? [],
            path: "$.store.model-profile")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encode(wireProtocol.rawValue, forKey: .wireProtocol)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(maxOutput, forKey: .maxOutput)
        try container.encode(locality.rawValue, forKey: .locality)
        try container.encodeIfPresent(credential, forKey: .credential)
        try container.encode(connectTimeout, forKey: .connectTimeout)
        try container.encode(readIdleTimeout, forKey: .readIdleTimeout)
        try container.encode(requestTimeout, forKey: .requestTimeout)
        try container.encode(maxInFlight, forKey: .maxInFlight)
        try container.encode(requestOptions, forKey: .requestOptions)
        try container.encode(requestOptionsRaw, forKey: .requestOptionsRaw)
        try container.encode(unqualifiedOptions, forKey: .unqualifiedOptions)
    }
}
