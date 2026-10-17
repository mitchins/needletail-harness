import Foundation
import NeedletailCore

/// M1-D scripted tool backend (D3): a TEST/FIXTURE executor, clearly
/// labeled — it never touches the real filesystem, processes, or network.
/// Constructed from an ordered script of `{tool, arguments, result}`
/// triples plus the run's effective capabilities. `execute` enforces the
/// SAME grant table the transition authoriser checked (single definition:
/// `toolAllowed`), then matches every proposal against consecutive script
/// entries by parsed-JSON content equality (key order insignificant, values
/// exact — digests are never consulted). Any deviation is a typed throw
/// (the actor pairs it through `failEffect`); exhaustion, mismatch, and
/// denial are never silent. M2 owns real effects.
public final class ScriptedToolBackend: ToolExecutor, @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public var tool: String
        public var arguments: String
        public var result: String

        public init(tool: String, arguments: String, result: String) {
            self.tool = tool
            self.arguments = arguments
            self.result = result
        }
    }

    private let lock = NSLock()
    private var script: [Entry]
    public let caps: ToolCapabilities

    public init(script: [Entry], caps: ToolCapabilities) {
        self.script = script
        self.caps = caps
    }

    public var remaining: Int {
        lock.withLock { script.count }
    }

    public func describe(batch: ToolBatch) -> String {
        "scripted batch: \(batch.proposals.map(\.tool).joined(separator: ",")) (\(scriptCount) entries remain)"
    }

    private var scriptCount: Int {
        lock.withLock { script.count }
    }

    public func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
        _ = reservation
        // Grants first: denied tools never reach matching (fail closed).
        for proposal in batch.proposals {
            guard toolAllowed(proposal.tool, caps: caps) else {
                throw ScriptedBackendError.capabilityDenied(tool: proposal.tool)
            }
        }
        // Defense in depth: execution receives the VERBATIM native
        // arguments, but only a canonical JSON object may ever dispatch.
        for proposal in batch.proposals {
            let arguments = proposal.arguments ?? ""
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [.fragmentsAllowed]),
                  parsed is [String: Any] else {
                throw ScriptedBackendError.argumentsNotObject(tool: proposal.tool)
            }
        }
        // Ordered exact matching: every proposal consumes the script head.
        var summaries: [String] = []
        var firstCallID = ""
        try lock.withLock {
            for proposal in batch.proposals {
                guard !script.isEmpty else {
                    throw ScriptedBackendError.scriptExhausted
                }
                let head = script.removeFirst()
                guard head.tool == proposal.tool,
                      jsonEqual(head.arguments, proposal.arguments ?? "")
                else {
                    throw ScriptedBackendError.scriptMismatch(
                        expected: "\(head.tool) \(head.arguments)",
                        got: "\(proposal.tool) \(proposal.arguments ?? "")")
                }
                if firstCallID.isEmpty { firstCallID = proposal.callID }
                summaries.append(head.result)
            }
        }
        return ExecutorResult(receipt: ExecutorReceipt(
            callID: firstCallID, status: "ok", summary: summaries.joined(separator: "\n")))
    }

    /// Parsed-JSON content equality (order-insensitive); unparseable sides
    /// compare as raw strings (exact bytes — still never guessed).
    private func jsonEqual(_ scripted: String, _ actual: String) -> Bool {
        guard let a = try? JSONSerialization.jsonObject(with: Data(scripted.utf8), options: [.fragmentsAllowed]),
              let b = try? JSONSerialization.jsonObject(with: Data(actual.utf8), options: [.fragmentsAllowed])
        else {
            return scripted == actual
        }
        return jsonCanonical(a) == jsonCanonical(b)
    }

    private func jsonCanonical(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            let parts = dict.keys.sorted().map { key in
                "\(jsonString(key)):\(jsonCanonical(dict[key]!))"
            }
            return "{\(parts.joined(separator: ","))}"
        }
        if let array = value as? [Any] {
            return "[\(array.map(jsonCanonical).joined(separator: ","))]"
        }
        if let text = value as? String { return jsonString(text) }
        // Bool before NSNumber: JSONSerialization boxes booleans distinctly.
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber { return "\(number)" }
        return String(describing: value)
    }

    private func jsonString(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"?\"".utf8), as: UTF8.self)
    }
}

public enum ScriptedBackendError: Error, Sendable, Equatable, CustomStringConvertible {
    case capabilityDenied(tool: String)
    case argumentsNotObject(tool: String)
    case scriptMismatch(expected: String, got: String)
    case scriptExhausted

    public var description: String {
        switch self {
        case .capabilityDenied(let tool):
            return "capabilityDenied: scripted backend refuses '\(terminalSafe(tool))' (no effective grant; never executed)."
        case .scriptMismatch(let expected, let got):
            return "scriptMismatch: expected '\(terminalSafe(expected))', got '\(terminalSafe(got))'."
        case .argumentsNotObject(let tool):
            return "argumentsNotObject: native arguments for '\(terminalSafe(tool))' are not a JSON object; execution never dispatches."
        case .scriptExhausted:
            return "scriptExhausted: no script entries remain for this batch."
        }
    }
}
