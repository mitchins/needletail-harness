import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import OpenAPIRuntime
import NeedletailCore

/// M1-C Chat Completions transport over AsyncHTTPClient + the production
/// SSE parser (SPEC §§5.2/11). Single authority rules: the adapter
/// CLASSIFIES every failure at its site and throws (`TransportFailure`) —
/// it never retries, follows, guesses or falls back. Bounded intake runs
/// upstream of parser accumulation; heartbeats reset the idle deadline but
/// never the whole-request deadline; cancellation tears down promptly.
public enum ChatTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyMessages
    case requestTooLarge(bytes: Int)
    case httpStatus(Int, String)
    case redirectRefused(location: String?)
    case contentEncodingRefused(String)
    case contentTypeUnexpected(String)
    case modelMismatch(configured: String, returned: String)

    public var description: String {
        switch self {
        case .emptyMessages:
            return "emptyMessages: the adapter sends no request without messages."
        case .requestTooLarge(let bytes):
            return "requestTooLarge: serialized body \(bytes) bytes exceeds the bound."
        case .httpStatus(let code, let body):
            return "httpStatus: \(code) \(terminalSafe(body))."
        case .redirectRefused(let location):
            return "redirectRefused: server redirected to '\(terminalSafe(location ?? "?"))' — never followed."
        case .contentEncodingRefused(let encoding):
            return "contentEncodingRefused: '\(terminalSafe(encoding))' — this client sends identity only and never decompresses."
        case .contentTypeUnexpected(let type):
            return "contentTypeUnexpected: '\(terminalSafe(type))'."
        case .modelMismatch(let configured, let returned):
            return "modelMismatch: configured '\(terminalSafe(configured))' vs served '\(terminalSafe(returned))' (diagnostic only)."
        }
    }
}

/// Bounded SSE collection delegate: accumulates raw wire bytes under the
/// stream cap, tracks head metadata + last-activity per chunk, and fails
/// the transfer on bound breach (aborting before unbounded accumulation).
final class BoundedStreamDelegate: HTTPClientResponseDelegate, @unchecked Sendable {
    typealias Response = CollectedStream

    struct CollectedStream: Sendable {
        var status: Int
        var headers: [(String, String)]
        var body: [UInt8]
        var errorBody: [UInt8]
    }

    private let lock = NSLock()
    private var status: Int = 0
    private var headers: [(String, String)] = []
    private var body: [UInt8] = []
    private var budget = StreamBudget()
    private var boundBreach: (any Error)?
    private var errorBytes: [UInt8] = []
    /// Deadline verdict recorded by the supervisor BEFORE it cancels the
    /// request: the cancellation echo (Swift CancellationError or
    /// HTTPClientError.cancelled) otherwise races the typed verdict and the
    /// observed failure message flaps. First verdict wins; readers take it
    /// instead of classifying the echo.
    private var deadlineVerdict: TransportFailure?
    var lastActivity: NIODeadline
    /// Incremental streaming (M1-D D4): rolling buffer for SSE decoder
    /// state across arbitrary chunk boundaries. `deltaOffset` marks the
    /// start of the next undecoded event; `deltaSink` is called
    /// synchronously from the NIO thread for each complete `content`
    /// delta (text only, tool proposals stay atomic at finish).
    private var deltaOffset: Int = 0
    var deltaSink: (@Sendable (String) -> Void)?

    init(now: NIODeadline, deltaSink: (@Sendable (String) -> Void)? = nil) {
        self.lastActivity = now
        self.deltaSink = deltaSink
    }

    private func headerValue(_ name: String) -> String? {
        headers.first(where: { $0.0.lowercased() == name })?.1
    }

    /// Locked snapshot accessors (the supervisor task reads across threads).
    func activity() -> NIODeadline {
        lock.withLock { lastActivity }
    }

    func sawHead() -> Bool {
        lock.withLock { status != 0 }
    }

    func setDeadlineVerdict(_ failure: TransportFailure) {
        lock.withLock {
            if deadlineVerdict == nil { deadlineVerdict = failure }
        }
    }

    func takeDeadlineVerdict() -> TransportFailure? {
        lock.withLock { deadlineVerdict }
    }

    func takeBoundBreach() -> BoundBreach? {
        lock.withLock { boundBreach as? BoundBreach }
    }

    func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {}
    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {}
    func didSendRequest(task: HTTPClient.Task<Response>) {}

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        lock.withLock {
            status = Int(head.status.code)
            headers = head.headers.map { ($0.name, $0.value) }
            lastActivity = .now()
        }
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        var deltasToEmit: [String] = []
        lock.withLock {
            lastActivity = .now()
            var chunk = buffer
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                if status != 200 {
                    // Error bodies: bounded collection, then stop caring.
                    if errorBytes.count < SSEBounds.maxErrorBytes {
                        errorBytes.append(contentsOf: bytes.prefix(SSEBounds.maxErrorBytes - errorBytes.count))
                    }
                    return
                }
                do {
                    try budget.consume(bytes)
                } catch {
                    if boundBreach == nil {
                        boundBreach = error
                        task.cancel()
                    }
                    return
                }
                body.append(contentsOf: bytes)
                // Incremental SSE decode: scan for complete events
                // (blank line = \n\n) and extract text deltas via the
                // PRODUCTION JSON shape, preserving decoder state across
                // arbitrary chunk boundaries.
                if deltaSink != nil {
                    deltasToEmit = extractNewDeltasLocked()
                }
            }
        }
        // Emit outside the lock (sink is thread-safe, may do file I/O).
        // Deltas are hints only; final assembly remains authoritative.
        if let sink = deltaSink {
            for text in deltasToEmit where !text.isEmpty {
                sink(text)
            }
        }
        return task.eventLoop.makeSucceededVoidFuture()
    }

    /// Scans `body[deltaOffset...]` for complete SSE events (delimited by
    /// `\n\n`), parses each event's `data:` JSON, and returns any
    /// `content` deltas. Malformed events emit nothing (final assembly
    /// still fails closed). Must be called with lock held; advances
    /// `deltaOffset` past decoded events only.
    private func extractNewDeltasLocked() -> [String] {
        var deltas: [String] = []
        while deltaOffset < body.count {
            // Find next "\n\n" delimiter from deltaOffset
            var found: Int? = nil
            for i in deltaOffset..<(body.count - 1) {
                if body[i] == 0x0A && body[i + 1] == 0x0A {
                    found = i
                    break
                }
                // Also handle "\r\n\r\n" (0x0D 0x0A 0x0D 0x0A)
                if i + 3 < body.count,
                   body[i] == 0x0D, body[i + 1] == 0x0A,
                   body[i + 2] == 0x0D, body[i + 3] == 0x0A {
                    found = i
                    break
                }
            }
            guard let delimiter = found else { break }
            let isCRLF = body[delimiter] == 0x0D
            let eventEnd = delimiter + (isCRLF ? 4 : 2)
            let eventBytes = Array(body[deltaOffset..<delimiter])
            deltaOffset = eventEnd
            guard let eventString = String(bytes: eventBytes, encoding: .utf8),
                  !eventString.isEmpty else { continue }
            // Collect "data:" lines (SSE spec: each event may have multiple)
            var dataPayload = ""
            var hasData = false
            for line in eventString.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    hasData = true
                    let after = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !dataPayload.isEmpty { dataPayload += "\n" }
                    dataPayload += after
                } else if trimmed == "data" {
                    hasData = true
                }
            }
            guard hasData, !dataPayload.isEmpty, dataPayload != "[DONE]" else { continue }
            guard let jsonData = dataPayload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty
            else { continue }
            // Delta projection is display-only; never emit raw model text
            // directly into terminals. Authoritative JSONL stays separate.
            deltas.append(terminalSafe(content))
        }
        return deltas
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {}

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        try lock.withLock {
            if let breach = boundBreach {
                throw breach
            }
            return CollectedStream(status: status, headers: headers, body: body, errorBody: errorBytes)
        }
    }

    func collectedErrorBody() -> [UInt8] {
        lock.withLock { errorBytes }
    }
}

/// Builds the exact request body (sorted keys, verbatim option values).
/// Reserved harness-owned keys can never appear via options: they were
/// rejected at config load (unknown non-reserved keys ride along inertly).
/// `tools`/`toolChoice` are HARNESS-OWNED (B5-C): the transport derives
/// them from effective capabilities via `ToolAdvertisement`, never from
/// operator configuration or model output. exec, consult and diff are
/// never advertised under any capabilities.
public func chatRequestBody(modelID: String, messages: [ChatMessage], maxTokens: Int, options: [String: JSONValue], tools: [[String: Any]]? = nil, toolChoice: String? = nil) throws -> Data {
    var body: [String: Any] = [
        "model": modelID,
        "stream": true,
        "stream_options": ["include_usage": true],
        "max_tokens": maxTokens,
        "messages": messages.map(messageJSON),
    ]
    for (key, value) in options {
        body[key] = jsonValueToAny(value)
    }
    if let tools, !tools.isEmpty {
        body["tools"] = tools
        body["tool_choice"] = toolChoice ?? "auto"
    }
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    guard data.count <= SSEBounds.maxRequestBytes else {
        throw ChatTransportError.requestTooLarge(bytes: data.count)
    }
    return data
}

/// Harness-owned OpenAI function-tool envelope for one advertised
/// definition (B5-C): `{"type":"function","function":{...}}`. The inner
/// object is the definition's canonical JSON (sorted keys), including its
/// explicit `"strict": false` (see `ToolDefinition`: optional/XOR
/// contracts are not strict-expressible; generation is best-effort while
/// dispatch validation stays strict).
public func openAIToolEnvelopes(_ definitions: [ToolDefinition]) -> [[String: Any]] {
    definitions.map { definition in
        let inner = (try? JSONSerialization.jsonObject(
            with: Data(definition.json().utf8), options: [])) as? [String: Any] ?? [:]
        return ["type": "function", "function": inner]
    }
}

private func messageJSON(_ message: ChatMessage) -> [String: Any] {
    var object: [String: Any] = ["role": message.role.rawValue, "content": message.text]
    if let calls = message.toolCalls {
        object["tool_calls"] = calls.map { call in
            ["id": call.callID, "type": "function",
             "function": ["name": call.tool, "arguments": call.arguments]]
        }
    }
    if let callID = message.toolCallID {
        object["tool_call_id"] = callID
    }
    return object
}

func jsonValueToAny(_ value: JSONValue) -> Any {
    switch value {
    case .string(let text): return text
    case .number(let number): return number
    case .bool(let flag): return flag
    case .null: return NSNull()
    case .array(let items): return items.map(jsonValueToAny)
    case .object(let entries): return entries.mapValues(jsonValueToAny)
    }
}

/// Probe request override (R9): the liveness probe sends a fixed packet —
/// max_tokens 16 and NO operator options — regardless of profile budgets.
/// Set only by `probeRoute`; normal traffic always uses profile values.
public struct ChatRequestOverride: Sendable, Equatable {
    public var maxTokens: Int
    public var options: [String: JSONValue]

    public init(maxTokens: Int, options: [String: JSONValue] = [:]) {
        self.maxTokens = maxTokens
        self.options = options
    }
}

/// The M1-C transport: explicit messages in, one assembled turn out.
/// Constructed with the policy client + three Sendable closures (R1/R3):
/// message/credential/snapshot suppliers. Session wiring (M1-D) replaces
/// the suppliers — never the transport. Conforms to ModelTransport so the
/// production actor drives it; tests inject scripted suppliers.
public struct ChatCompletionsTransport: DeltaStreamingTransport, Sendable {
    public var client: HTTPClient
    public var messageProvider: @Sendable (ProviderInvocation) async throws -> [ChatMessage]
    public var credentialProvider: @Sendable (CredentialReference, String) async throws -> String?
    public var snapshotProvider: @Sendable () -> ConfigSnapshot
    public var requestOverride: ChatRequestOverride?
    /// Harness-owned advertisement source (B5-C): the RUN's effective tool
    /// capabilities, set once at composition. Nil (the default for every
    /// pre-B5-C construction site and test) advertises nothing — request
    /// bodies are byte-identical to before. Sealed invocations suppress
    /// advertisement regardless.
    public var advertisedTools: ToolCapabilities?
    /// Incremental streaming sink (M1-D D4): called synchronously from the
    /// NIO delegate for each `content` delta before final assembly.
    /// Actor wires it to `UISink.emit(.delta)`; tests inject InMemory sink.
    public var deltaSink: (@Sendable (String) -> Void)?

    public init(
        client: HTTPClient,
        messageProvider: @Sendable @escaping (ProviderInvocation) async throws -> [ChatMessage],
        credentialProvider: @Sendable @escaping (CredentialReference, String) async throws -> String?,
        snapshotProvider: @Sendable @escaping () -> ConfigSnapshot,
        requestOverride: ChatRequestOverride? = nil,
        deltaSink: (@Sendable (String) -> Void)? = nil,
        advertisedTools: ToolCapabilities? = nil
    ) {
        self.client = client
        self.messageProvider = messageProvider
        self.credentialProvider = credentialProvider
        self.snapshotProvider = snapshotProvider
        self.requestOverride = requestOverride
        self.deltaSink = deltaSink
        self.advertisedTools = advertisedTools
    }

    public func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
        _ = intake // M1-C consumes internally (single-shot API); display streaming is M4.
        // Every failure below this line is pre-dial (nothing sent), so every
        // one classifies preSend HERE — the actor must never see an
        // ambiguous verdict for a request that never left the process.
        let messages: [ChatMessage]
        do {
            messages = try await messageProvider(invocation)
        } catch {
            throw TransportFailure(phase: .preSend, message: "transcript paging failed: \(error)")
        }
        guard !messages.isEmpty else {
            throw TransportFailure(phase: .preSend, message: ChatTransportError.emptyMessages.description)
        }
        let snapshot = snapshotProvider()
        // Authorize-before-dial (R4): the CURRENT snapshot decides, and only
        // the returned endpoint is dialed. A mutated snapshot refuses here
        // with zero bytes sent (server-side connection count stays 0).
        let route = authorizeRequestDestination(
            snapshot: snapshot, requestedAlias: invocation.alias, sealed: invocation.sealed)
        guard case .allowed(let endpoint, _) = route else {
            throw TransportFailure(phase: .preSend, message: "route refused before dial")
        }
        guard let profile = snapshot.profiles[invocation.alias] else {
            throw TransportFailure(phase: .preSend, message: "profile vanished after authorization")
        }
        var credential: String?
        if let reference = profile.credential {
            do {
                credential = try await credentialProvider(reference, "chat")
            } catch {
                // Credential errors are reference-shaped by store contract
                // (names/paths, never secret values) — safe to carry.
                throw TransportFailure(phase: .preSend, message: "credential resolution failed: \(error)")
            }
        }
        let body: Data
        do {
            // B5-C harness-owned advertisement: tools + tool_choice derive
            // SOLELY from the run's effective capabilities (sealed
            // invocations advertise nothing). Operator configuration cannot
            // carry these keys (reserved at config load) and model output
            // never influences the schema — proposals are validated at
            // dispatch regardless of what was advertised.
            let definitions: [ToolDefinition]
            if invocation.sealed {
                definitions = []
            } else {
                definitions = advertisedTools.map { ToolAdvertisement.definitions(for: $0) } ?? []
            }
            body = try chatRequestBody(
                modelID: profile.modelID, messages: messages,
                maxTokens: requestOverride?.maxTokens ?? profile.maxOutput,
                options: requestOverride?.options ?? profile.requestOptions,
                tools: definitions.isEmpty ? nil : openAIToolEnvelopes(definitions),
                toolChoice: definitions.isEmpty ? nil : "auto")
        } catch let chat as ChatTransportError {
            throw TransportFailure(phase: .preSend, message: chat.description)
        }
        let started = NIODeadline.now()
        let wholeDeadline = started + .seconds(Int64(profile.requestTimeout))
        let delegate = BoundedStreamDelegate(now: started, deltaSink: deltaSink)
        // Legacy request type: delegate-based execute only accepts
        // HTTPClient.Request (the new HTTPClientRequest has no delegate
        // overload in AsyncHTTPClient 1.36).
        let request: HTTPClient.Request
        do {
            var headers = HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Accept", "text/event-stream"),
            ])
            if let secret = credential {
                headers.add(name: "Authorization", value: "Bearer \(secret)")
            }
            var buffer = ByteBufferAllocator().buffer(capacity: body.count)
            buffer.writeBytes(body)
            request = try HTTPClient.Request(
                url: endpoint, method: .POST, headers: headers, body: .byteBuffer(buffer))
        } catch {
            // Pre-dial local failure: nothing was sent.
            throw TransportFailure(phase: .preSend, message: "invalid endpoint: \(terminalSafe(endpoint))")
        }
        // Whole-request enforcement belongs to OUR supervisor (deadline: nil
        // here); the client config keeps connect/read safety nets only.
        let task = client.execute(request: request, delegate: delegate, deadline: nil)
        return try await withThrowingTaskGroup(of: TransportResult.self) { group in
            group.addTask {
                do {
                    let collected = try await task.futureResult.get()
                    return try await self.finish(
                        collected: collected, profile: profile, invocation: invocation)
                } catch {
                    // Deadline verdicts win deterministically: the
                    // supervisor records before cancelling, so whether its
                    // own (now non-throwing) loop or the cancellation echo
                    // arrives first, the typed deadline surfaces.
                    if let verdict = delegate.takeDeadlineVerdict() {
                        throw verdict
                    }
                    if let bound = delegate.takeBoundBreach() {
                        throw TransportFailure(phase: .postContent, message: bound.description)
                    }
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    if let failure = error as? TransportFailure {
                        throw failure
                    }
                    if let chat = error as? ChatTransportError {
                        // Typed local/protocol failures surface with their
                        // kind; the actor treats unclassified errors as
                        // ambiguous, so re-tag here where context is known.
                        throw TransportFailure(phase: .postContent, message: chat.description)
                    }
                    if let bound = error as? BoundBreach {
                        throw TransportFailure(phase: .postContent, message: bound.description)
                    }
                    if let assembly = error as? AssemblyError {
                        throw TransportFailure(phase: .postContent, message: assembly.description)
                    }
                    throw self.classify(taskError: error, delegate: delegate)
                }
            }
            group.addTask {
                await self.supervise(
                    delegate: delegate, profile: profile,
                    wholeDeadline: wholeDeadline, task: task)
                // Reachable only via group teardown (the supervisor returns
                // when cancelled after the verdict already won): discard path.
                throw TransportFailure(phase: .ambiguous, message: "supervisor exited without a verdict")
            }
            guard let first = try await group.next() else {
                throw TransportFailure(phase: .ambiguous, message: "transport group produced nothing")
            }
            group.cancelAll()
            return first
        }
    }

    /// Classifies client-thrown errors the delegate never saw. No response
    /// head means no streamed content and no observable side effect, so
    /// SPEC §11's bounded pre-stream retry (priced-in uncertainty) applies:
    /// preSend. Anything after the first head byte is postContent. The
    /// head flag — not the error's type name — is the authority, so refused
    /// connections and DNS failures (opaque NIO errors) classify correctly.
    private func classify(taskError: Error, delegate: BoundedStreamDelegate) -> TransportFailure {
        if let clientError = taskError as? HTTPClientError, clientError == .connectTimeout {
            return TransportFailure(phase: .preSend, message: String(describing: clientError))
        }
        if delegate.sawHead() {
            return TransportFailure(phase: .postContent, message: String(describing: taskError))
        }
        return TransportFailure(phase: .preSend, message: String(describing: taskError))
    }

    /// Deadline supervisor: read-idle expiry (no chunk for readIdleTimeout)
    /// records by head state (pre-head → preSend, post-head → postContent);
    /// whole-deadline expiry records postContent (bytes demonstrably flowed
    /// or the send completed). The verdict is recorded BEFORE cancelling so
    /// the request task's cancellation echo maps back to it (see the
    /// invoke catch site). Returns on group teardown; never throws, so the
    /// verdict cannot lose a race with its own delivery. Heartbeats/comments
    /// are chunks — they reset idle but never the whole timer (NET-04).
    private func supervise(
        delegate: BoundedStreamDelegate, profile: ModelProfile,
        wholeDeadline: NIODeadline,
        task: HTTPClient.Task<BoundedStreamDelegate.Response>
    ) async -> Void {
        // Releasing the socket on any exit, including outer task-group
        // cancellation, prevents a stalled HTTP future from pinning the run.
        defer { task.cancel() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            let now = NIODeadline.now()
            if now >= wholeDeadline {
                // Same head-state rule as read-idle: no head means nothing
                // flowed, so a whole-cap trip on a stalled connect is
                // preSend (retryable); post-head it is postContent.
                delegate.setDeadlineVerdict(TransportFailure(
                    phase: delegate.sawHead() ? .postContent : .preSend,
                    message: "whole-request deadline exceeded"))
                task.cancel()
            } else {
                let idle = now - delegate.activity()
                if idle >= .seconds(Int64(profile.readIdleTimeout)) {
                    delegate.setDeadlineVerdict(TransportFailure(
                        phase: delegate.sawHead() ? .postContent : .preSend,
                        message: "read-idle deadline exceeded"))
                    task.cancel()
                }
            }
        }
    }

    private func finish(
        collected: BoundedStreamDelegate.Response, profile: ModelProfile,
        invocation: ProviderInvocation
    ) async throws -> TransportResult {
        guard collected.status == 200 else {
            if 300..<400 ~= collected.status {
                let location = collected.headers.first(where: { $0.0.lowercased() == "location" })?.1
                throw ChatTransportError.redirectRefused(location: location)
            }
            let body = String(decoding: collected.errorBody.prefix(SSEBounds.maxErrorBytes), as: UTF8.self)
            throw ChatTransportError.httpStatus(collected.status, body)
        }
        if let encoding = collected.headers.first(where: { $0.0.lowercased() == "content-encoding" })?.1,
           encoding.lowercased() != "identity" {
            throw ChatTransportError.contentEncodingRefused(encoding)
        }
        let events = try await decodeBounded(collected.body)
        let turn = try assembleChatTurn(events)
        // Served-model mismatch (turn.returnedModel vs profile.modelID) is
        // a diagnostic flag only (servers may alias): never failed, never
        // coerced. The surfacing channel is `returnedModel` on the response
        // (M1-B-frozen shape); the `modelMismatch` case names the condition
        // for future session records. No separate signal at this layer.
        let response = providerResponseForTurn(turn, requestID: invocation.requestID, generation: invocation.generation)
        return TransportResult(response: response, rawBody: collected.body)
    }

    /// Decodes bounded wire bytes through the production SSE parser.
    /// The byte caps already ran upstream (delegate); this layer only feeds.
    func decodeBounded(_ bytes: [UInt8]) async throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
            continuation.yield(bytes[...])
            continuation.finish()
        }
        for try await event in stream.asDecodedServerSentEvents(while: { _ in true }) {
            events.append(event)
        }
        return events
    }
}
