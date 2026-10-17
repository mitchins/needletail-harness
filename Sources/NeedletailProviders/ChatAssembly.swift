import Foundation
import OpenAPIRuntime
import NeedletailCore

/// M1-C pure Chat Completions assembly (SPEC §§5.2/11). Operates on decoded
/// SSE events — byte bounds are enforced upstream (`SSEBounds`) before the
/// parser ever accumulates. Complete tool calls are PROPOSALS (data); they
/// never execute during assembly. Unknown continuation-bearing blocks stop
/// compatibly instead of dropping. No network, no clock, no randomness.

public struct AssembledToolCall: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct AssembledTurn: Sendable, Equatable {
    public var text: String
    public var reasoningText: String
    public var toolCalls: [AssembledToolCall]
    public var isFinal: Bool
    public var truncated: Bool
    public var usageInput: Int?
    public var usageOutput: Int?
    public var returnedModel: String?

    public init(
        text: String = "", reasoningText: String = "", toolCalls: [AssembledToolCall] = [],
        isFinal: Bool = false, truncated: Bool = false,
        usageInput: Int? = nil, usageOutput: Int? = nil, returnedModel: String? = nil
    ) {
        self.text = text
        self.reasoningText = reasoningText
        self.toolCalls = toolCalls
        self.isFinal = isFinal
        self.truncated = truncated
        self.usageInput = usageInput
        self.usageOutput = usageOutput
        self.returnedModel = returnedModel
    }
}

public enum AssemblyError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedEvent(String)
    case duplicateToolID(String)
    case unknownDeltaKey(String)
    case invalidArguments(callID: String)
    case reservedOptionLeak(String)

    public var description: String {
        switch self {
        case .malformedEvent(let why): return "malformedEvent: \(why)"
        case .duplicateToolID(let id): return "duplicateToolID: '\(terminalSafe(id))'."
        case .unknownDeltaKey(let key): return "unknownDeltaKey: '\(terminalSafe(key))' — compatibility stop, never silent drop."
        case .invalidArguments(let callID): return "invalidArguments: assembled arguments for '\(terminalSafe(callID))' are not a JSON object."
        case .reservedOptionLeak(let key): return "reservedOptionLeak: '\(key)'."
        }
    }
}

/// Tool-call fragments keyed by NATIVE id (R8): per-call argument buffers
/// accumulate across ALL fragments sharing the id (any index, interleaved
/// or duplicate-index); the 8-call bound counts DISTINCT ids; id reuse
/// across indices, or a changed id mid-index, rejects.
struct CallAccumulator {
    var id: String
    var name: String = ""
    var arguments: String = ""
    var indices: Set<Int> = []
}

/// Assembles one complete turn from decoded SSE events. Throws on the
/// first protocol violation (fail closed — partial results are never
/// returned as complete). Empty input yields a non-final empty turn
/// (stream-end-without-completion is decided by the caller via isFinal).
public func assembleChatTurn(_ events: [ServerSentEvent]) throws -> AssembledTurn {
    var text = ""
    var reasoning = ""
    var order: [String] = []
    var calls: [String: CallAccumulator] = [:]
    var indexToID: [Int: String] = [:]
    var usageInput: Int?
    var usageOutput: Int?
    var returnedModel: String?
    var finishReason: String?
    var truncated = false

    for event in events {
        guard let data = event.data, !data.isEmpty else { continue }
        // OpenAI-dialect stream terminator: end-of-stream marker, never
        // model content and never a completion verdict (a stream that ends
        // here without a finish_reason still fails as incomplete).
        if data == "[DONE]" { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw AssemblyError.malformedEvent("event data is not a JSON object")
        }
        if let model = object["model"] as? String, returnedModel == nil {
            returnedModel = model
        }
        if let usage = object["usage"] as? [String: Any] {
            if let prompt = usage["prompt_tokens"] as? Int { usageInput = prompt }
            if let completion = usage["completion_tokens"] as? Int { usageOutput = completion }
        }
        guard let choices = object["choices"] as? [[String: Any]] else { continue }
        for choice in choices {
            if let finish = choice["finish_reason"] as? String {
                // Last non-null finish wins (providers send exactly one).
                finishReason = finish
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            for key in delta.keys.sorted() where !["role", "content", "tool_calls", "reasoning_content"].contains(key) {
                throw AssemblyError.unknownDeltaKey(key)
            }
            if let content = delta["content"] as? String {
                text += content
            } else if delta["content"] != nil, !(delta["content"] is NSNull) {
                throw AssemblyError.malformedEvent("delta.content is not a string")
            }
            if let reasoningDelta = delta["reasoning_content"] as? String {
                reasoning += reasoningDelta
            }
            guard let fragments = delta["tool_calls"] as? [[String: Any]] else { continue }
            for fragment in fragments {
                let index = fragment["index"] as? Int ?? -1
                let id = fragment["id"] as? String ?? ""
                let function = fragment["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                let args = function["arguments"] as? String ?? ""
                // Key rule (R8): an explicit id binds; bare fragments join
                // the index's call; an id-less fragment with no index entry
                // is malformed (nothing to join).
                let key: String
                if !id.isEmpty {
                    if let bound = indexToID[index], bound != id {
                        throw AssemblyError.duplicateToolID("\(id)@\(index)")
                    }
                    indexToID[index] = id
                    key = id
                } else if let bound = indexToID[index] {
                    key = bound
                } else {
                    throw AssemblyError.malformedEvent("tool fragment without id or known index")
                }
                // R8: an id bound to one index stream never joins another —
                // same id, different index is a duplicate identity.
                if let existing = calls[key], !existing.indices.contains(index), !existing.indices.isEmpty {
                    throw AssemblyError.duplicateToolID(key)
                }
                if calls[key] == nil {
                    guard calls.count < SSEBounds.maxToolCalls else {
                        throw AssemblyError.malformedEvent("more than \(SSEBounds.maxToolCalls) tool calls")
                    }
                    order.append(key)
                    calls[key] = CallAccumulator(id: key)
                }
                guard var acc = calls[key] else {
                    throw AssemblyError.malformedEvent("tool call '\(key)' vanished mid-assembly")
                }
                if !name.isEmpty {
                    if !acc.name.isEmpty, acc.name != name {
                        throw AssemblyError.duplicateToolID(key)
                    }
                    acc.name = name
                }
                if !args.isEmpty {
                    acc.arguments += args
                    guard acc.arguments.utf8.count <= SSEBounds.maxArgumentsBytes else {
                        throw AssemblyError.malformedEvent("tool arguments exceed \(SSEBounds.maxArgumentsBytes) bytes")
                    }
                }
                acc.indices.insert(index)
                calls[key] = acc
            }
        }
    }

    var assembled: [AssembledToolCall] = []
    for key in order {
        let call = calls[key]!
        guard !call.name.isEmpty else {
            throw AssemblyError.malformedEvent("tool call '\(key)' never named its function")
        }
        if !call.arguments.isEmpty {
            guard let data = call.arguments.data(using: .utf8),
                  let _ = try? JSONSerialization.jsonObject(with: data) else {
                throw AssemblyError.invalidArguments(callID: key)
            }
        }
        assembled.append(AssembledToolCall(callID: key, name: call.name, arguments: call.arguments))
    }
    // Note: `order` holds each id once by construction (first-seen
    // insertion above); cross-index id reuse is already rejected at bind
    // time via `indexToID`, and mid-index id changes via the name/id
    // stability checks — no second pass needed.

    let isFinal = finishReason.map { ["stop", "length", "tool_calls"].contains($0) } ?? false
    truncated = finishReason == "length"
    return AssembledTurn(
        text: text, reasoningText: reasoning, toolCalls: assembled,
        isFinal: isFinal, truncated: truncated,
        usageInput: usageInput, usageOutput: usageOutput, returnedModel: returnedModel)
}

/// Maps an assembled turn to the session-layer response (M1-B shape).
/// Incomplete streams (no native completion) become typed protocol
/// failures with zero proposals — never silent, never partial execution.
public func providerResponseForTurn(
    _ turn: AssembledTurn, requestID: RequestID, generation: Revision
) -> ProviderResponse {
    guard turn.isFinal else {
        return ProviderResponse(
            requestID: requestID, generation: generation,
            outcome: .failed("incomplete stream: no authoritative completion; transcript retained for diagnosis"),
            usageInput: turn.usageInput, usageOutput: turn.usageOutput,
            returnedModel: turn.returnedModel)
    }
    let proposals = turn.toolCalls.map {
        ToolProposal(callID: $0.callID, tool: $0.name, argumentsDigest: fnv1aHex($0.arguments), arguments: $0.arguments)
    }
    return ProviderResponse(
        requestID: requestID, generation: generation,
        outcome: .textDeltaComplete(text: turn.text, toolProposals: proposals, isFinal: true),
        usageInput: turn.usageInput, usageOutput: turn.usageOutput,
        returnedModel: turn.returnedModel)
}
