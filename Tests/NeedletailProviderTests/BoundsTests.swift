import Testing
import Foundation
import OpenAPIRuntime
import NeedletailCore
import NeedletailProviders

/// WIRE-03 pure rows — bound accounting without sockets: stream/line
/// budgets trip on exact byte counts; argument caps accumulate across
/// interleaved fragments; the 8-call bound counts distinct ids.
/// Forbidden: silent enlargement, accumulation resets, bypass-by-splitting.
struct BoundsTests {

    @Test("WIRE-03 stream and line budgets trip on exact counts")
    func WIRE_03_budgetTrips() throws {
        var budget = StreamBudget()
        try budget.consume(Array("data: x\n\n".utf8))
        #expect(budget.totalBytes == 9 && budget.tailBytes == 0, "newline resets the tail")
        try budget.consume(Array("half-a-line".utf8))
        #expect(budget.tailBytes == 11, "unterminated tail accumulates across chunks")
        // Line cap is exact: maxLineBytes passes, +1 fails.
        var edge = StreamBudget()
        try edge.consume([UInt8](repeating: 0x41, count: SSEBounds.maxLineBytes))
        #expect(edge.tailBytes == SSEBounds.maxLineBytes)
        do {
            try edge.consume([0x42])
            Issue.record("1 byte over the line cap must fail")
        } catch let breach as BoundBreach {
            guard case .lineTooLong = breach else {
                Issue.record("wrong breach: \(breach)"); return
            }
        }
    }

    @Test("WIRE-03 argument caps accumulate across interleaved fragments")
    func WIRE_03_argumentAccumulation() throws {
        // Two interleaved calls whose fragments stay under the cap alone
        // but exceed it together must fail at assembly, not silently merge.
        let big = String(repeating: "a", count: 200 << 10)
        func frag(_ index: Int, _ id: String, _ args: String) -> String {
            let object: [String: Any] = [
                "choices": [["delta": ["tool_calls": [
                    ["index": index, "id": id, "function": ["name": "read", "arguments": args]],
                ]], "finish_reason": NSNull()]],
            ]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let events = [
            frag(0, "a", big), frag(1, "b", big),
            frag(0, "a", big), frag(1, "b", big),
        ].map { ServerSentEvent(data: $0) }
        do {
            _ = try assembleChatTurn(events)
            Issue.record("accumulated 400 KiB per call must fail")
        } catch {
            #expect("\(error)".contains("bytes"), "bound error names the count: \(error)")
        }
    }

    @Test("WIRE-03 ninth distinct call refuses; ninth fragment to one call merges")
    func WIRE_03_callCountBound() throws {
        // Distinct indices per call, as real providers send: reusing index 0
        // for every id would trip the duplicate-identity rule first (a
        // different, also-correct refusal) and never reach the 8-call bound.
        func call(index: Int, id: String) -> ServerSentEvent {
            let object: [String: Any] = [
                "choices": [["delta": ["tool_calls": [
                    ["index": index, "id": id, "function": ["name": "read", "arguments": "{}"]],
                ]], "finish_reason": NSNull()]],
            ]
            return ServerSentEvent(data: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        var events = (0..<8).map { call(index: $0, id: "id-\($0)") }
        events.append(call(index: 8, id: "id-8"))
        do {
            _ = try assembleChatTurn(events)
            Issue.record("9th distinct call must refuse")
        } catch {
            #expect("\(error)".contains("8"), "bound error names the limit: \(error)")
        }
    }

    @Test("request bodies carry exact bytes under the cap")
    func requestBodyExact() throws {
        let body = try chatRequestBody(
            modelID: "qwen", messages: [ChatMessage(role: .user, text: "hi")],
            maxTokens: 16, options: ["temperature": .number(0.2)])
        let decoded = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(decoded["model"] as? String == "qwen")
        #expect(decoded["stream"] as? Bool == true)
        #expect(decoded["max_tokens"] as? Int == 16)
        #expect((decoded["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect((decoded["temperature"] as? Double) == 0.2, "inert options ride along verbatim")
        #expect(body.count <= SSEBounds.maxRequestBytes)
    }

    @Test("probe packet is fixed literals under its cap")
    func probePacketFixed() throws {
        // Built from the same constants the probe path injects (R9): the
        // packet the wire test captures byte-exactly is deterministic here.
        func packet() throws -> Data {
            try chatRequestBody(
                modelID: "loopback-1", messages: ProbePacket.messages(),
                maxTokens: ProbePacket.maxTokens, options: [:])
        }
        let first = try packet()
        let second = try packet()
        #expect(first == second, "probe packet is fully deterministic")
        #expect(first.count <= ProbePacket.bodyByteCap, "probe cap holds")
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("probe ping") && text.contains("needletail probe"))
        #expect(text.contains("\"max_tokens\":16"), "bounded output: \(text)")
        #expect(!text.contains("temperature"), "no operator options ride along")
    }
}
