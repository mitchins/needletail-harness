import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport

/// WIRE-01..10 over the REAL adapter + loopback HTTP (byte-exact bodies,
/// real chunking, real deadlines). Given scripted server plans, when the
/// production transport dials, then assembled turns match the pure-oracle
/// expectations byte for byte. Forbidden: silent enlargement, discovery,
/// fallback, merges, drops, unqualified requests.
///
/// Serialized: under full-target parallelism one run in four showed an
/// ECONNREFUSED into a live loopback listener (test-support thread/listen
/// lifecycle churn, never the product path — the dial URL is fixed before
/// start). Serial costs nothing measurable here (the suite is
/// deadline-bound, ~7 s either way) and keeps the gate deterministic.
/// Cross-run parallelism of the three suites remains. Owned follow-up:
/// M1C3-3 (server productionization) re-examines the lifecycle.
@Suite(.serialized)
struct WireLoopbackTests {

    /// Builds one `data:` line from a dictionary — never hand-escaped JSON.
    /// Hand-rolled event literals previously shipped an unbalanced brace
    /// through three escape layers; this helper makes that class of test
    /// bug inexpressible (serialization of string/number values cannot fail).
    private static func eventLine(_ object: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }

    private static func run(
        script: SSEScript, alias: String = "loop",
        messages: [ChatMessage]? = nil, credential: String? = nil
    ) async throws -> (response: ProviderResponse, requests: [CapturedRequest], connections: Int) {
        let server = try LoopbackSSEServer()
        server.enqueue(script)
        server.start()
        defer { server.stop() }
        let (transport, _) = try LoopbackFixtures.transport(
            server: server, alias: alias, messages: messages, credential: credential)
        // Unwind-safe: a throwing invoke must still drain the client or
        // AHC traps on un-shut-down deinit and masks the real failure.
        defer { await LoopbackFixtures.shutdown(transport.client) }
        let result = try await transport.invoke(
            LoopbackFixtures.invocation(alias: alias),
            intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        return (result.response, server.requests, server.connectionCount)
    }

    @Test("WIRE-01 byte-split delivery assembles identically end to end")
    func WIRE_01_byteSplitsIdentical() async throws {
        let body = CannedTurn.text("hello there")
        let bytes = Array(body.utf8)
        // Control: whole-body single write.
        let control = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: bytes)]))
        guard case .textDeltaComplete(let text, _, let fin) = control.response.outcome else {
            Issue.record("control must complete, got \(control.response.outcome)"); return
        }
        #expect(text == "hello there" && fin)
        // Treatment: every byte as an independent chunk.
        var oneByte: [ScriptChunk] = []
        oneByte.reserveCapacity(bytes.count)
        for byte in bytes {
            oneByte.append(ScriptChunk(bytes: [byte]))
        }
        let split = try await Self.run(script: SSEScript(chunks: oneByte))
        #expect(split.response == control.response, "TCP chunking must not move adapter output")
    }

    @Test("WIRE-02 framing, comments and heartbeats behave over the wire")
    func WIRE_02_framingOverWire() async throws {
        let body = ": heartbeat comment\r\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\\r\\nb\"}}]}\r\n\r\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\n" +
            "data: [DONE]\r\n\r\n"
        let run = try await Self.run(script: SSEScript(chunks: [
            ScriptChunk(bytes: Array(body.utf8)),
        ]))
        guard case .textDeltaComplete(let text, _, _) = run.response.outcome else {
            Issue.record("expected completion, got \(run.response.outcome)"); return
        }
        #expect(text == "a\r\nb", "CRLF content preserved, comments never model content")
        #expect(!text.contains("heartbeat"))
    }

    @Test("WIRE-03 over-limit line, ninth call and stream cap refuse")
    func WIRE_03_boundsRefuse() async throws {
        // Unterminated 1 MiB+1 line: refused before accumulation completes.
        do {
            _ = try await Self.run(script: SSEScript(chunks: [
                ScriptChunk(bytes: [UInt8](repeating: 0x41, count: (1 << 20) + 1)),
            ]))
            Issue.record("over-limit line must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "bytes flowed: \(failure)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        // Ninth distinct tool call refuses (id-keyed count, not chunks).
        var nine = ""
        for i in 0..<9 {
            nine += "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(i),\"id\":\"id-\(i)\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}\n\n"
        }
        nine += "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
        do {
            _ = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(nine.utf8))]))
            Issue.record("9th distinct call must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "ninth call follows content: \(failure)")
            #expect(failure.message == "malformedEvent: more than 8 tool calls",
                    "typed eight-call bound: \(failure.message)")
        } catch {
            Issue.record("wrong error class for ninth tool call: \(error)")
        }
    }

    @Test("WIRE-03 gzipped responses and oversized streams refuse typed")
    func WIRE_03_gzipAndStreamCapRefuse() async throws {
        // Gunzip path does not exist (decompression disabled): a gzipped
        // body is refused by header, never decompressed, never parsed.
        // Bytes below are gzip.compress of a valid turn (generated offline,
        // embedded so the test needs no compression dependency).
        let gzipped: [UInt8] = [31,139,8,0,160,79,207,106,2,255,75,73,44,73,180,82,168,86,74,206,200,207,76,78,45,86,178,138,174,86,74,73,205,41,73,84,178,2,10,230,231,149,164,230,149,40,89,41,165,87,101,22,20,164,166,40,148,148,22,229,41,213,214,198,214,114,113,165,224,209,89,171,163,148,150,153,151,89,156,17,95,148,154,88,156,159,7,52,161,184,36,191,64,9,73,99,180,139,191,159,107,44,23,23,0,201,219,46,34,129,0,0,0]
        do {
            _ = try await Self.run(script: SSEScript(
                headers: [("Content-Type", "text/event-stream"), ("Content-Encoding", "gzip")],
                chunks: [ScriptChunk(bytes: gzipped)]))
            Issue.record("gzipped body must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "head arrived: \(failure)")
            #expect(failure.message.contains("contentEncodingRefused"), "typed: \(failure.message)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        // 1000 × ~20 KB content lines (20 MB total): every line fits the
        // 1 MiB line cap, but the 16 MiB stream cap trips mid-transfer.
        let bigLine = "data: {\"choices\":[{\"delta\":{\"content\":\"" + String(repeating: "a", count: 20_000) + "\"}}]}\n\n"
        var huge = ""
        huge.reserveCapacity(bigLine.utf8.count * 1000)
        for _ in 0..<1000 { huge += bigLine }
        do {
            _ = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(huge.utf8))]))
            Issue.record("oversized stream must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "bytes flowed: \(failure)")
            #expect(failure.message.contains("streamTooLarge"), "typed: \(failure.message)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }

    @Test("WIRE-04 interleaved calls assemble by native id over the wire")
    func WIRE_04_interleavedOverWire() async throws {
        func fragment(index: Int, id: String?, name: String?, arguments: String) -> [String: Any] {
            var function: [String: Any] = ["arguments": arguments]
            if let name { function["name"] = name }
            var frag: [String: Any] = ["index": index, "function": function]
            if let id { frag["id"] = id }
            return ["choices": [["delta": ["tool_calls": [frag]]]]]
        }
        let body =
            Self.eventLine(fragment(index: 0, id: "a", name: "read", arguments: "{\"p")) +
            Self.eventLine(fragment(index: 1, id: "b", name: "exec", arguments: "{\"c")) +
            Self.eventLine(fragment(index: 0, id: nil, name: nil, arguments: "ath\":\"f\"}")) +
            Self.eventLine(fragment(index: 1, id: nil, name: nil, arguments: "md\":\"ls\"}")) +
            Self.eventLine(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]])
        let run = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(body.utf8))]))
        guard case .textDeltaComplete(_, let proposals, let fin) = run.response.outcome else {
            Issue.record("expected proposals, got \(run.response.outcome)"); return
        }
        #expect(fin && proposals.count == 2, "two calls, final")
        #expect(proposals[0].callID == "a" && proposals[1].callID == "b", "provider order kept")
        #expect(proposals[0].tool == "read" && proposals[1].tool == "exec", "names bound to ids")
    }

    @Test("WIRE-05 malformed and duplicate calls fail with zero proposals")
    func WIRE_05_malformedFails() async throws {
        // Duplicate id across indices.
        func callEvent(index: Int, id: String, name: String) -> String {
            Self.eventLine(["choices": [["delta": ["tool_calls": [
                ["index": index, "id": id, "function": ["name": name, "arguments": "{}"]]]]]]])
        }
        let dup = callEvent(index: 0, id: "a", name: "read") +
            callEvent(index: 1, id: "a", name: "exec") +
            Self.eventLine(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]])
        do {
            _ = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(dup.utf8))]))
            Issue.record("duplicate ids must fail")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "bytes flowed: \(failure)")
            #expect(failure.message.contains("duplicateToolID"), "the duplicate identity — not a parse slip — must fire: \(failure.message)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        // Non-JSON event data fails closed (never guessed).
        do {
            _ = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array("data: not-json{{{\n\n".utf8))]))
            Issue.record("non-JSON data must fail")
        } catch let failure as TransportFailure {
            #expect(failure.message.contains("not a JSON object"), "typed parse failure: \(failure.message)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }

    @Test("WIRE-06 unknown blocks stop; reasoning passes through opaquely")
    func WIRE_06_unknownStopsReasoningPasses() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"x\",\"mystery\":{\"a\":1}}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        do {
            _ = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(body.utf8))]))
            Issue.record("unknown delta key must stop")
        } catch {
            #expect("\(error)".contains("mystery"), "names the key: \(error)")
        }
        // Signed/opaque reasoning_content is preserved, never interpreted.
        let signed = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"opaque-signed-bytes\",\"content\":\"y\"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        let run = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(signed.utf8))]))
        guard case .textDeltaComplete(let text, _, _) = run.response.outcome else {
            Issue.record("reasoning turn must complete, got \(run.response.outcome)"); return
        }
        #expect(text == "y")
    }

    @Test("WIRE-07 numeric strings and unicode survive the wire exactly")
    func WIRE_07_exactIdentities() async throws {
        let huge = "123456789012345678901234567890"
        let body = Self.eventLine([
            "id": "x", "object": "chat.completion.chunk", "created": 1, "model": "001234",
            "choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "id": huge, "function": ["name": "read", "arguments": "{}"]]]]]]]) +
            Self.eventLine(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]])
        let run = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(body.utf8))]))
        guard case .textDeltaComplete(_, let proposals, _) = run.response.outcome else {
            Issue.record("expected proposals, got \(run.response.outcome)"); return
        }
        #expect(proposals.first?.callID == huge, "huge digit id verbatim")
        #expect(run.response.returnedModel == "001234", "numeric-looking model id stays a string")
    }

    @Test("WIRE-08 stream end without completion has zero side effects")
    func WIRE_08_incompleteZeroEffects() async throws {
        let body = Self.eventLine(["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": "a", "function": ["name": "read", "arguments": "{}"]]]]]]])
        let run = try await Self.run(script: SSEScript(chunks: [ScriptChunk(bytes: Array(body.utf8))]))
        guard case .failed(let message) = run.response.outcome else {
            Issue.record("incomplete must fail typed, got \(run.response.outcome)"); return
        }
        #expect(message.contains("no authoritative completion"))
    }

    @Test("WIRE-09 history order and base stability hold over the wire")
    func WIRE_09_historyStable() async throws {
        let messages = [
            ChatMessage(role: .system, text: "base instructions"),
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .assistant, text: "answer"),
            ChatMessage(role: .user, text: "inserted follow-up"),
        ]
        let run = try await Self.run(
            script: SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("ok").utf8))]),
            messages: messages)
        let sent = try #require(run.requests.first, "server must capture the request")
        let body = try JSONSerialization.jsonObject(with: Data(sent.body)) as! [String: Any]
        let sentMessages = (body["messages"] as! [[String: Any]]).map { $0["content"] as! String }
        #expect(sentMessages == ["base instructions", "first", "answer", "inserted follow-up"],
                "append-only order preserved: \(sentMessages)")
    }

    @Test("WIRE-10 paced delivery completes bounded with one connection")
    func WIRE_10_pacedDeliveryBounded() async throws {
        let body = CannedTurn.text("paced")
        let paced = stride(from: 0, to: body.utf8.count, by: 64).map { offset -> ScriptChunk in
            let end = min(offset + 64, body.utf8.count)
            return ScriptChunk(bytes: Array(Array(body.utf8)[offset..<end]), delayMillis: 20)
        }
        let run = try await Self.run(script: SSEScript(chunks: paced))
        guard case .textDeltaComplete(let text, _, let fin) = run.response.outcome else {
            Issue.record("paced stream must complete, got \(run.response.outcome)"); return
        }
        #expect(text == "paced" && fin)
        #expect(run.connections == 1, "single connection, no retry, no drop")
    }
}
