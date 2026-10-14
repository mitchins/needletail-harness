/// M1-C chat message values (shared session/adapter vocabulary — lives in
/// Core so the module graph stays acyclic; Providers maps these to wire
/// JSON). Opaque strings, never coerced; unknown roles rejected at the
/// mapping boundary, never guessed.
public enum ChatRole: String, Sendable, Equatable, Codable {
    case system
    case user
    case assistant
    case tool
}

public struct NativeToolCall: Sendable, Equatable, Codable {
    public let callID: String
    public let tool: String
    public let arguments: String

    public init(callID: String, tool: String, arguments: String) {
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public let role: ChatRole
    public let text: String
    public let toolCalls: [NativeToolCall]?
    public let toolCallID: String?

    public init(role: ChatRole, text: String, toolCalls: [NativeToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}
