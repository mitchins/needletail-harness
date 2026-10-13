/// NeedletailProviders will own the three native wire adapters (Chat
/// Completions, Responses, Messages) and transport policy. M0-A seeds only
/// the identity value type the layout needs; no HTTP or stream behaviour is
/// implemented or implied here yet.

/// A configured endpoint's identity: the operator's alias, the native
/// protocol exactly as configured (never inferred from a label), and the
/// locality class the operator asserts about the server (SPEC §5.1).
public enum NativeProtocol: String, Sendable, Equatable, Codable, CaseIterable {
    case openAIChatCompletions = "openai-chat-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
}

public enum LocalityClass: String, Sendable, Equatable, Codable {
    case local
    case cloud
}

public struct ProviderIdentity: Sendable, Equatable, Hashable, Codable {
    public var alias: String
    public var nativeProtocol: NativeProtocol
    public var locality: LocalityClass

    public init(alias: String, nativeProtocol: NativeProtocol, locality: LocalityClass) {
        self.alias = alias
        self.nativeProtocol = nativeProtocol
        self.locality = locality
    }
}
