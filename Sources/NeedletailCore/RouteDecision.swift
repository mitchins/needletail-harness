/// M1-A route selection (SPEC §5.3, I09; rev4-B, D3). Pure: the decision is
/// a function of the immutable snapshot and the requested alias only. The
/// `sealed` parameter is outcome-inert by invariant — it keeps call sites
/// explicit, but the returned route is byte-identical under either value
/// (pinned by test); sealing is enforced tool-side, never route-side.
/// Cloud routing is denied in M1-A; no fallback, no retry, no transport.
public enum Route: Sendable, Equatable {
    case allowed(endpoint: String, alias: String)
    case denied(RouteDenial)
}

public struct RouteDenial: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unknownAlias
        case localOnlyViolation
        case originNotAllowlisted
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public func selectRoute(snapshot: ConfigSnapshot, requestedAlias: String, sealed: Bool) -> Route {
    _ = sealed // Outcome-inert by invariant (D3); sealing binds tools, not routes.
    guard let profile = snapshot.profiles[requestedAlias] else {
        return .denied(RouteDenial(
            kind: .unknownAlias,
            message: "unknown model alias '\(requestedAlias)'; configured aliases: \(snapshot.profiles.keys.sorted().joined(separator: ", "))."))
    }
    guard profile.locality == .local else {
        return .denied(RouteDenial(
            kind: .localOnlyViolation,
            message: "alias '\(requestedAlias)' is a cloud profile; M1-A routes local-only with no fallback."))
    }
    guard snapshot.allowHTTPOrigins.contains(profile.origin) else {
        return .denied(RouteDenial(
            kind: .originNotAllowlisted,
            message: "origin \(profile.origin) is not allow-listed for alias '\(requestedAlias)'."))
    }
    return .allowed(endpoint: endpointURL(for: profile), alias: requestedAlias)
}

/// Joins the preserved base with the protocol suffix exactly once (rev4-A).
public func endpointURL(for profile: ModelProfile) -> String {
    profile.baseURL + profile.wireProtocol.endpointSuffix
}
