import Testing
import Foundation
import OpenAPIRuntime
import NeedletailCore
import NeedletailProviders

/// WIRE-04/05/06/07 pure assembly rows: id-keyed argument accumulation,
/// malformed/duplicate rejection, unknown-key compatibility stops, and
/// lossless identity preservation — all without sockets (transport-free).
/// Forbidden: last-wins merging, silent unknown drops, normalization.
struct AssemblyTests {

    private static func event(_ json: String) -> ServerSentEvent {
        ServerSentEvent(data: json)
    }

    private static func chunk(
        index: Int, id: String?, name: String?, args: String?, finish: String? = nil
    ) -> ServerSentEvent {
        var function: [String: String] = [:]
        if let name { function["name"] = name }
        if let args { function["arguments"] = args }
        var call: [String: Any] = ["index": index, "function": function]
        if let id { call["id"] = id }
        let delta: [String: Any] = ["tool_calls": [call]]
        var choice: [String: Any] = ["delta": delta]
        if let finish { choice["finish_reason"] = finish }
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
        return event(data)
    }

    private static func textChunk(_ text: String, finish: String? = nil, model: String? = nil) -> ServerSentEvent {
        var choice: [String: Any] = ["delta": ["content": text]]
        if let finish { choice["finish_reason"] = finish }
        var top: [String: Any] = ["choices": [choice]]
        if let model { top["model"] = model }
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: top), as: UTF8.self)
        return event(data)
    }

    @Test("WIRE-04 interleaved tool streams assemble by native id")
    func WIRE_04_interleavedAssembly() throws {
        let events = [
            Self.chunk(index: 0, id: "a", name: "read", args: #"{"pa"#),
            Self.chunk(index: 1, id: "b", name: "exec", args: #"{"cm"#),
            Self.chunk(index: 0, id: nil, name: nil, args: #"th":"f"}"#),
            Self.chunk(index: 1, id: nil, name: nil, args: #"d":"ls"}"#, finish: "tool_calls"),
        ]
        let turn = try assembleChatTurn(events)
        #expect(turn.toolCalls.count == 2)
        #expect(turn.toolCalls[0] == AssembledToolCall(callID: "a", name: "read", arguments: #"{"path":"f"}"#))
        #expect(turn.toolCalls[1] == AssembledToolCall(callID: "b", name: "exec", arguments: #"{"cmd":"ls"}"#))
        #expect(turn.isFinal, "finish_reason tool_calls is final")
    }

    @Test("WIRE-05 malformed, duplicate and incomplete calls reject")
    func WIRE_05_malformedReject() throws {
        // Duplicate id across indices.
        let dup = [
            Self.chunk(index: 0, id: "a", name: "read", args: nil),
            Self.chunk(index: 1, id: "a", name: "exec", args: nil, finish: "tool_calls"),
        ]
        do {
            _ = try assembleChatTurn(dup)
            Issue.record("duplicate id across indices must reject")
        } catch let error as AssemblyError {
            guard case .duplicateToolID = error else {
                Issue.record("wrong error: \(error)"); return
            }
        }
        // Changed id mid-index.
        let changed = [
            Self.chunk(index: 0, id: "a", name: "read", args: nil),
            Self.chunk(index: 0, id: "b", name: nil, args: "x", finish: "tool_calls"),
        ]
        do {
            _ = try assembleChatTurn(changed)
            Issue.record("mid-index id change must reject")
        } catch let error as AssemblyError {
            guard case .duplicateToolID = error else {
                Issue.record("wrong error: \(error)"); return
            }
        }
        // Unnamed call at completion.
        let unnamed: [ServerSentEvent] = [
            Self.chunk(index: 0, id: "a", name: nil, args: nil, finish: "tool_calls"),
        ]
        do {
            _ = try assembleChatTurn(unnamed)
            Issue.record("unnamed call must reject")
        } catch let error as AssemblyError {
            guard case .malformedEvent = error else {
                Issue.record("wrong error: \(error)"); return
            }
        }
        // Non-JSON arguments at completion.
        let badArgs = [
            Self.chunk(index: 0, id: "a", name: "read", args: "not-json{{{", finish: "tool_calls"),
        ]
        do {
            _ = try assembleChatTurn(badArgs)
            Issue.record("non-JSON arguments must reject")
        } catch let error as AssemblyError {
            guard case .invalidArguments = error else {
                Issue.record("wrong error: \(error)"); return
            }
        }
    }

    @Test("WIRE-06 unknown delta keys stop compatibly, never drop")
    func WIRE_06_unknownDeltaStops() throws {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["content": "hi", "mystery_extension": [1, 2]], "finish_reason": "stop"]],
        ])
        do {
            _ = try assembleChatTurn([Self.event(String(decoding: data, as: UTF8.self))])
            Issue.record("unknown delta key must stop")
        } catch let error as AssemblyError {
            guard case .unknownDeltaKey(let key) = error, key == "mystery_extension" else {
                Issue.record("wrong error: \(error)"); return
            }
        }
    }

    @Test("WIRE-07 identities and bytes stay lossless")
    func WIRE_07_losslessIdentities() throws {
        let huge = "123456789012345678901234567890"
        let events = [
            Self.textChunk("héllo 🌍", model: "001234"),
            Self.textChunk("", finish: "stop"),
        ]
        let turn = try assembleChatTurn(events)
        #expect(turn.text == "héllo 🌍")
        #expect(turn.returnedModel == "001234", "numeric-looking model IDs stay strings")
        _ = huge
        let idTurn = try assembleChatTurn([
            Self.chunk(index: 0, id: huge, name: "read", args: "{}", finish: "tool_calls"),
        ])
        #expect(idTurn.toolCalls.first?.callID == huge, "huge digit ids never become floating point")
    }

    @Test("WIRE-08 stream end without completion is incomplete, never partial")
    func WIRE_08_incompleteNeverPartial() throws {
        let turn = try assembleChatTurn([Self.textChunk("half")])
        #expect(!turn.isFinal, "no finish_reason means incomplete")
        let response = providerResponseForTurn(
            turn, requestID: RequestID("r"), generation: Revision(1))
        guard case .failed(let message) = response.outcome else {
            Issue.record("incomplete must map to a typed failure, got \(response.outcome)"); return
        }
        #expect(message.contains("no authoritative completion"))
        #expect(response.usageInput == nil && response.usageOutput == nil, "unknown stays unknown, never zero")
    }

    @Test("usage maps when present, stays unknown when absent")
    func usageMapping() throws {
        let data = try! JSONSerialization.data(withJSONObject: [
            "usage": ["prompt_tokens": 10, "completion_tokens": 3],
            "choices": [["delta": ["content": "x"], "finish_reason": "stop"]],
        ])
        let turn = try assembleChatTurn([Self.event(String(decoding: data, as: UTF8.self))])
        #expect(turn.usageInput == 10 && turn.usageOutput == 3)
    }
}
