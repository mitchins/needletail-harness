import Foundation
import NeedletailTestSupport

/// M4-D D1.1 loopback script language for chat composition tests.
/// Wraps the shared `LoopbackSSEServer` (raw POSIX sockets, 127.0.0.1,
/// ephemeral ports): deterministic canned Chat Completions SSE bodies
/// with controlled chunk splits, mid-stream `gate:<name>` hold points
/// (the injection barrier for "during stream" oracles), tool-call
/// turns, and error scripts. The server captures full requests, so
/// every test asserts the dummy-bearer `Authorization` header —
/// proving config/profile/`EnvFileCredentialStore` composition
/// through the real path (plan §D1.1).
enum ChatLoopback {
    static let credentialEnv = "NEEDLETAIL_CHAT_TEST_KEY"
    static let credentialValue = "chat-loopback-dummy-bearer"

    private static func json(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    private static func event(_ jsonBody: String) -> String {
        "data: \(jsonBody)\n\n"
    }

    private static func choice(delta: String, finish: String?) -> String {
        var inner = "{\"index\":0,\"delta\":\(delta)"
        if let finish { inner += ",\"finish_reason\":\"\(finish)\"" } else { inner += ",\"finish_reason\":null" }
        inner += "}"
        return "{\"id\":\"chatcmpl-t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[\(inner)]}"
    }

    /// A text turn split into `splits` content chunks. When `gateAfter`
    /// is set, the chunk at that index carries the hold gate: the
    /// server withholds it (and everything after) until the test calls
    /// `releaseGate`, so input injected after `waitUntilGateArmed` is
    /// provably mid-stream.
    static func textTurn(
        _ text: String,
        splits: Int = 1,
        gateAfter gateIndex: Int? = nil,
        gateName: String = "gate",
        usage: Bool = true
    ) -> SSEScript {
        var bodies: [String] = []
        bodies.append(choice(delta: "{\"role\":\"assistant\"}", finish: nil))
        let scalars = Array(text)
        let per = max(1, (scalars.count + max(1, splits) - 1) / max(1, splits))
        var index = 0
        while index < scalars.count {
            let piece = String(scalars[index..<min(index + per, scalars.count)])
            bodies.append(choice(delta: "{\"content\":\(json(piece))}", finish: nil))
            index += per
        }
        bodies.append(choice(delta: "{}", finish: "stop"))
        if usage {
            bodies.append("{\"id\":\"chatcmpl-t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
        }
        bodies.append("[DONE]")
        var chunks: [ScriptChunk] = []
        for (i, body) in bodies.enumerated() {
            // bodies[0] = role; content chunks start at bodies[1].
            let hold: String? = (gateIndex != nil && i == 1 + gateIndex!) ? gateName : nil
            chunks.append(ScriptChunk(bytes: Array(event(body).utf8), holdGate: hold))
        }
        return SSEScript(chunks: chunks)
    }

    /// A tool-call turn: optional prefix text, then `tool_calls` deltas
    /// for one call, finished with `finish_reason: tool_calls`.
    static func toolTurn(
        name: String,
        callID: String = "call_1",
        arguments: String,
        prefixText: String? = nil,
        argumentSplits: Int = 1,
        gateAfter gateIndex: Int? = nil,
        gateName: String = "gate"
    ) -> SSEScript {
        var bodies: [String] = []
        bodies.append(choice(delta: "{\"role\":\"assistant\"}", finish: nil))
        if let prefixText {
            bodies.append(choice(delta: "{\"content\":\(json(prefixText))}", finish: nil))
        }
        let argScalars = Array(arguments)
        let per = max(1, (argScalars.count + max(1, argumentSplits) - 1) / max(1, argumentSplits))
        var first = true
        var index = 0
        while index < argScalars.count {
            let piece = String(argScalars[index..<min(index + per, argScalars.count)])
            let call: String
            if first {
                call = "{\"tool_calls\":[{\"index\":0,\"id\":\"\(callID)\",\"type\":\"function\",\"function\":{\"name\":\"\(name)\",\"arguments\":\(json(piece))}}]}"
                first = false
            } else {
                call = "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\(json(piece))}}]}"
            }
            bodies.append(choice(delta: call, finish: nil))
            index += per
        }
        bodies.append(choice(delta: "{}", finish: "tool_calls"))
        bodies.append("[DONE]")
        var chunks: [ScriptChunk] = []
        for (i, body) in bodies.enumerated() {
            // Content/tool chunks start at bodies[1]; hold the gateIndex-th.
            let hold: String? = (gateIndex != nil && i == 1 + gateIndex!) ? gateName : nil
            chunks.append(ScriptChunk(bytes: Array(event(body).utf8), holdGate: hold))
        }
        return SSEScript(chunks: chunks)
    }

    /// A failing turn (HTTP error status, no SSE body).
    static func errorTurn(status: Int = 500) -> SSEScript {
        SSEScript(status: status, headers: [("Content-Type", "text/plain")], chunks: [])
    }

    /// Asserts every captured request carried the expected dummy bearer.
    /// Returns the failure description, or nil when the assertion holds.
    /// A test with zero captured requests fails (no vacuous pass).
    static func bearerViolation(server: LoopbackSSEServer, expected: String) -> String? {
        let requests = server.requests
        guard !requests.isEmpty else { return "no requests reached the loopback server" }
        for (i, request) in requests.enumerated() {
            // CapturedRequest.header matches against a lowercase name.
            let auth = request.header("authorization")
            guard auth == "Bearer \(expected)" else {
                return "request \(i) \(request.method) \(request.path): Authorization = \(auth ?? "<absent>")"
            }
        }
        return nil
    }
}
