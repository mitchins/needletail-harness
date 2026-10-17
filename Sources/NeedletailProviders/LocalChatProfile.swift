import NeedletailCore

/// M1-A first-profile validation: the local Chat Completions shape only.
/// Pure — no transport, no discovery, no network. It confirms that a
/// Core-validated profile is the one M1-A knows how to route (local
/// locality, Chat Completions protocol); every other shape fails closed
/// with the milestone that owns it. Calls only Core predicates, so the
/// Providers → Core layering is preserved (no Core → Providers import).
public func validateLocalChatProfile(_ profile: ModelProfile) throws -> ModelProfile {
    guard profile.locality == .local else {
        throw ConfigError(
            path: "$.models[\(profile.alias)]", kind: .unsupportedCombination,
            message: "alias '\(profile.alias)' is not a local profile.",
            hint: "M1-A routes local profiles only; cloud adapters arrive in M5.")
    }
    guard profile.wireProtocol == .openAIChatCompletions else {
        throw ConfigError(
            path: "$.models[\(profile.alias)]", kind: .unsupportedCombination,
            message: "protocol '\(profile.wireProtocol.rawValue)' is not the M1-A Chat Completions shape.",
            hint: "Responses/Messages adapters arrive in M5; keep openai-chat-completions for M1.")
    }
    return profile
}
