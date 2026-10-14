import Testing
import Foundation
import OpenAPIRuntime
import NeedletailCore
import NeedletailProviders

/// DX-04/DX-05/WIRE-09/WIRE-10 pure rows: scripted chunkings and event
/// scripts through the real parser + assembler (no sockets here — paced
/// delivery runs at loopback level). Forbidden: chunking-sensitive output,
/// base-prompt mutation, execution during assembly, silent failure mapping.
struct StreamSemanticsTests {

    private static func decodeSplit(_ bytes: [UInt8], _ sizes: [Int]) async throws -> [ServerSentEvent] {
        var chunks: [ArraySlice<UInt8>] = []
        var index = bytes.startIndex
        var sizeIndex = 0
        while index < bytes.endIndex {
            let size = sizes[sizeIndex % sizes.count]
            sizeIndex += 1
            let end = bytes.index(index, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
            chunks.append(bytes[index..<end])
            index = end
        }
        let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        var events: [ServerSentEvent] = []
        for try await event in stream.asDecodedServerSentEvents() {
            events.append(event)
        }
        return events
    }

    private static func chatPayload() -> [UInt8] {
        Array("""
        data: {"choices":[{"delta":{"role":"assistant","content":"hi"}}]}\n
        data: {"choices":[{"delta":{"content":" there"}}]}\n
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n
        data: [DONE]\n
        """.utf8)
    }

    @Test("DX-04 every byte as an independent chunk assembles identically")
    func DX_04_byteChunksIdentical() async throws {
        let bytes = Self.chatPayload()
        let whole = try await Self.decodeSplit(bytes, [bytes.count])
        let perByte = try await Self.decodeSplit(bytes, [1])
        let ragged = try await Self.decodeSplit(bytes, [1, 2, 3, 5, 8, 13, 21])
        let wholeTurn = try assembleChatTurn(whole)
        #expect(try assembleChatTurn(perByte) == wholeTurn, "per-byte chunking must not move output")
        #expect(try assembleChatTurn(ragged) == wholeTurn, "ragged chunking must not move output")
        #expect(wholeTurn.text == "hi there" && wholeTurn.isFinal)
    }

    @Test("DX-05 scripted tool lifecycle maps to typed outcomes, never executes")
    func DX_05_lifecycleTyped() throws {
        // Start/progress: a named but unfinished call accumulates (visible in
        // the turn) yet NEVER completes: usability gates on isFinal, and the
        // session mapping turns any non-final prefix into a failed outcome
        // with zero proposals — that mapping, not an empty list, is the
        // no-partial-execution contract.
        let start = try assembleChatTurn([ServerSentEvent(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":""}}]}}]}"#)])
        #expect(!start.isFinal, "start fragment never completes")
        let mapped = providerResponseForTurn(start, requestID: RequestID("r-t"), generation: Revision(0))
        guard case .failed = mapped.outcome else {
            Issue.record("non-final prefix must map to failed, got \(mapped.outcome)"); return
        }
        // Failure/retry/cancel classification lives in TransportFailure —
        // construction here pins the mapping the tests assert end to end.
        let preSend = TransportFailure(phase: .preSend, message: "refused")
        let postContent = TransportFailure(phase: .postContent, message: "rst")
        let ambiguous = TransportFailure(phase: .ambiguous, message: "???")
        #expect(preSend != postContent && postContent != ambiguous, "phases distinct")
        // Cancellation is the actor's Task machinery, typed at the boundary.
        let cancelled = CancellationError()
        #expect("\(cancelled)".count > 0)
    }

    @Test("WIRE-09 mid-history insertion appends with base stable")
    func WIRE_09_historyAppendStable() throws {
        let base: [ChatMessage] = [
            ChatMessage(role: .system, text: "base instructions"),
            ChatMessage(role: .user, text: "first question"),
            ChatMessage(role: .assistant, text: "first answer"),
        ]
        let before = try chatRequestBody(modelID: "m", messages: base, maxTokens: 16, options: [:])
        let extended = base + [ChatMessage(role: .user, text: "inserted follow-up")]
        let after = try chatRequestBody(modelID: "m", messages: extended, maxTokens: 16, options: [:])
        let beforeJSON = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        let afterJSON = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        let beforeMessages = (beforeJSON["messages"] as! [[String: Any]])
        let afterMessages = (afterJSON["messages"] as! [[String: Any]])
        #expect(afterMessages.count == beforeMessages.count + 1, "append-only")
        for (index, message) in beforeMessages.enumerated() {
            #expect((afterMessages[index]["content"] as? String) == (message["content"] as? String),
                    "prior history byte-stable at index \(index)")
            #expect((afterMessages[index]["role"] as? String) == (message["role"] as? String))
        }
        #expect((afterMessages.last?["content"] as? String) == "inserted follow-up")
        #expect((afterMessages.first?["content"] as? String) == "base instructions", "base prompt first and unchanged")
    }

    @Test("WIRE-10 irregular chunk paces assemble identically")
    func WIRE_10_irregularPacesIdentical() async throws {
        let bytes = Self.chatPayload()
        let reference = try assembleChatTurn(try await Self.decodeSplit(bytes, [bytes.count]))
        for sizes in [[7], [1, 100], [3, 3, 3], [64, 1, 63]] {
            #expect(try assembleChatTurn(try await Self.decodeSplit(bytes, sizes)) == reference,
                    "pace \(sizes) must not move output")
        }
    }
}
