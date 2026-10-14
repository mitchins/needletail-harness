/// M1-A route selection (SPEC §5.3, I09; rev4-B, D3, H1). Pure: the decision
/// is a function of the immutable snapshot and the requested alias only.
/// The `sealed` parameter is outcome-inert by invariant — it keeps call
/// sites explicit, but the returned route is byte-identical under either
/// value (pinned by test); sealing is enforced tool-side, never route-side.
/// Cloud routing is denied in M1-A; no fallback, no retry, no transport.
///
/// H1: authorization re-derives the destination from the profile's
/// effective `baseURL` at decision time and checks the DERIVED origin
/// against the snapshot's allow-list. The stored `origin` field is
/// diagnostics only and is never consulted for routing, so stale or
/// hand-built origins cannot authorize anything.
public enum Route: Sendable, Equatable {
    case allowed(endpoint: String, alias: String)
    case denied(RouteDenial)
}

public struct RouteDenial: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unknownAlias
        case localOnlyViolation
        case originNotAllowlisted
        case malformedDestination
    }

    public let kind: Kind
    public let message: String

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
            message: "unknown model alias '\(terminalSafe(requestedAlias))'; configured aliases: \(snapshot.profiles.keys.sorted().map(terminalSafe).joined(separator: ", "))."))
    }
    guard profile.locality == .local else {
        return .denied(RouteDenial(
            kind: .localOnlyViolation,
            message: "alias '\(terminalSafe(requestedAlias))' is a cloud profile; M1-A routes local-only with no fallback."))
    }
    let destination: ParsedBaseURL
    do {
        destination = try parseBaseURL(profile.baseURL, path: "$.models[\(terminalSafe(requestedAlias))].base_url")
    } catch {
        return .denied(RouteDenial(
            kind: .malformedDestination,
            message: "effective destination for alias '\(terminalSafe(requestedAlias))' is malformed; refusing to route."))
    }
    guard snapshot.allowHTTPOrigins.contains(destination.origin) else {
        return .denied(RouteDenial(
            kind: .originNotAllowlisted,
            message: "effective origin \(destination.origin) is not allow-listed for alias '\(terminalSafe(requestedAlias))'."))
    }
    return .allowed(endpoint: destination.base + profile.wireProtocol.endpointSuffix, alias: requestedAlias)
}

/// M1-C transport entry point (H1): call this — not `selectRoute` —
/// immediately before dispatch, with the snapshot live at that moment, and
/// dial ONLY the returned endpoint. It re-runs selection and then
/// re-verifies the exact endpoint bytes against the allow-list, so a
/// destination smuggled between selection and dispatch still fails closed.
/// M1-C must never cache the endpoint across an `await`.
public func authorizeRequestDestination(snapshot: ConfigSnapshot, requestedAlias: String, sealed: Bool) -> Route {
    let route = selectRoute(snapshot: snapshot, requestedAlias: requestedAlias, sealed: sealed)
    guard case .allowed(let endpoint, _) = route else { return route }
    let lowered = endpoint.lowercased()
    let covered = snapshot.allowHTTPOrigins.contains(where: { origin in
        lowered == origin.lowercased() || lowered.hasPrefix(origin.lowercased() + "/")
    })
    guard covered else {
        return .denied(RouteDenial(
            kind: .originNotAllowlisted,
            message: "final destination check refused the endpoint for alias '\(terminalSafe(requestedAlias))'."))
    }
    return route
}

/// Joins the preserved base with the protocol suffix exactly once (rev4-A).
/// Routing decisions must come from `selectRoute` /
/// `authorizeRequestDestination`, never from calling this directly on an
/// unvalidated profile.
public func endpointURL(for profile: ModelProfile) -> String {
    profile.baseURL + profile.wireProtocol.endpointSuffix
}
