import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport

/// Shared loopback fixtures for M1-C integration: scripted SSE server,
/// synthetic snapshots, and real-adapter transports. All traffic stays on
/// 127.0.0.1 with ephemeral ports; no external network, no credentials
/// beyond test-scoped values, no sleeps standing in for readiness on the
/// assertion side (server-side pacing delays are explicit script steps).
enum LoopbackFixtures {
    static let configTemplate = """
        {"version":1,"default_model":"MODEL","allow_http_origins":["ORIGIN"],"models":[{"alias":"MODEL","protocol":"openai-chat-completions","base_url":"BASE","model":"test-model","context_window":4096,"max_output":128,"locality":"local","credential":{"env":"NEEDLETAIL_LOOPBACK_TEST_KEY"},"connect_timeout_s":CONNECT,"read_idle_timeout_s":READIDLE,"request_timeout_s":WHOLE,"max_in_flight":1}],"tools":{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}}
        """

    static func snapshot(
        alias: String = "loop",
        baseURL: String,
        connectTimeout: Int = 5,
        readIdleTimeout: Int = 10,
        requestTimeout: Int = 60,
        requestOptions: String? = nil
    ) throws -> ConfigSnapshot {
        let origin = try parseBaseURL(baseURL, path: "$").origin
        // Optional operator options (verbatim JSON object text) to prove
        // they ride normal traffic but never the probe packet.
        let optionsFragment = requestOptions.map { ",\"request_options\":\($0)" } ?? ""
        let text = configTemplate
            .replacingOccurrences(of: "MODEL", with: alias)
            .replacingOccurrences(of: "ORIGIN", with: origin)
            .replacingOccurrences(of: "BASE", with: baseURL)
            .replacingOccurrences(of: "CONNECT", with: "\(connectTimeout)")
            .replacingOccurrences(of: "READIDLE", with: "\(readIdleTimeout)")
            .replacingOccurrences(of: "WHOLE", with: "\(requestTimeout)")
            .replacingOccurrences(of: "\"max_in_flight\":1", with: "\"max_in_flight\":1\(optionsFragment)")
        return try validateConfig(Data(text.utf8))
    }

    static func client(profile: ModelProfile) -> HTTPClient {
        HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: ChatTransportPolicy.configuration(profile: profile))
    }

    static func transport(
        server: LoopbackSSEServer,
        alias: String = "loop",
        messages: [ChatMessage]? = nil,
        credential: String? = nil,
        connectTimeout: Int = 5,
        readIdleTimeout: Int = 10,
        requestTimeout: Int = 60,
        requestOptions: String? = nil
    ) throws -> (ChatCompletionsTransport, ConfigSnapshot) {
        let snapshot = try snapshot(
            alias: alias, baseURL: server.baseURL,
            connectTimeout: connectTimeout, readIdleTimeout: readIdleTimeout,
            requestTimeout: requestTimeout, requestOptions: requestOptions)
        let profile = try #require(snapshot.profiles[alias])
        let fixed = messages ?? [ChatMessage(role: .user, text: "synthetic probe input")]
        let transport = ChatCompletionsTransport(
            client: client(profile: profile),
            messageProvider: { _ in fixed },
            credentialProvider: { reference, _ in
                guard reference.kind == CredentialReference.Kind.env(name: "NEEDLETAIL_LOOPBACK_TEST_KEY") else {
                    throw LoopbackCheckFailed.unreached
                }
                return credential ?? "loopback-test-secret"
            },
            snapshotProvider: { snapshot })
        return (transport, snapshot)
    }

    static func invocation(alias: String = "loop") -> ProviderInvocation {
        ProviderInvocation(
            effectID: EffectID("eff-t"), requestID: RequestID("req-t"),
            runID: RunID("run-t"), generation: Revision(1),
            alias: alias, epochID: EpochID("epoch-t"), sealed: false,
            turnsLeft: 80, deadlineMillis: nil, historyDigest: "test")
    }

    static func shutdown(_ client: HTTPClient) async {
        // shutdown() returns an EventLoopFuture: awaiting it WITHOUT .get()
        // discards the future and deinits the client mid-shutdown (AHC
        // traps on un-shut-down deinit in debug builds). .get() suspends
        // until the pool actually drained.
        try? await client.shutdown().get()
    }
}

enum LoopbackCheckFailed: Error {
    case unreached
}

/// A complete canned Chat Completions SSE body (OpenAI dialect).
enum CannedTurn {
    static func text(_ text: String, model: String = "test-model", usage: Bool = true) -> String {
        var body = "data: {\"id\":\"chatcmpl-t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\(jsonString(text))},\"finish_reason\":null}]}\n\n"
        body += "data: {\"id\":\"chatcmpl-t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        if usage {
            body += "data: {\"id\":\"chatcmpl-t\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"\(model)\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
        }
        body += "data: [DONE]\n\n"
        return body
    }

    static func jsonString(_ text: String) -> String {
        // JSONSerialization rejects top-level strings; the encoder emits
        // the exact JSON string literal (escaping included).
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }
}
