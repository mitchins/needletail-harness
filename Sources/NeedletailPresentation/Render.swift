import Foundation
import NeedletailCore

/// M1-B semantic renderer (UX-DX §3.1). Pure: same state + width +
/// capabilities ⇒ same frame. Returns SEMANTIC frames (roles + text),
/// never ANSI bytes — styling belongs to a future M4 adapter. Untrusted
/// strings render through `terminalSafe` (H2 carry-over); the canonical
/// bytes stay in the session store.

public enum StyleRole: String, Sendable, Equatable, Codable {
    case normal
    case status
    case composerText
    case candidate
    case candidateSelected
    case errorNotice
}

public struct StyledRun: Sendable, Equatable {
    public var text: String
    public var role: StyleRole

    public init(text: String, role: StyleRole) {
        self.text = text
        self.role = role
    }
}

public struct SemanticLine: Sendable, Equatable {
    public var id: String
    public var runs: [StyledRun]

    public init(id: String, runs: [StyledRun]) {
        self.id = id
        self.runs = runs
    }
}

public struct StatusLine: Sendable, Equatable {
    public var text: String
    public var tone: StyleRole

    public init(text: String, tone: StyleRole) {
        self.text = text
        self.tone = tone
    }
}

public struct ComposerOverlay: Sendable, Equatable {
    public var text: String
    public var cursor: Int

    public init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

public struct RenderFrame: Sendable, Equatable {
    public var lines: [SemanticLine]
    public var statusLine: StatusLine?
    public var composerOverlay: ComposerOverlay?
    public var width: Int

    public init(lines: [SemanticLine], statusLine: StatusLine? = nil, composerOverlay: ComposerOverlay? = nil, width: Int) {
        self.lines = lines
        self.statusLine = statusLine
        self.composerOverlay = composerOverlay
        self.width = width
    }
}

public enum ColorLevel: Sendable, Equatable {
    case none
    case sixteen
    case twoFiftySix
}

public struct TerminalCapabilities: Sendable, Equatable {
    public var color: ColorLevel
    public var cursorAddressing: Bool

    public init(color: ColorLevel = .sixteen, cursorAddressing: Bool = true) {
        self.color = color
        self.cursorAddressing = cursorAddressing
    }

    public static let dumb = TerminalCapabilities(color: .none, cursorAddressing: false)
}

/// Wraps pre-wrapped logical lines to the width (never splits inside a
/// grapheme cluster — Swift String indices). Content roles never change
/// with width or capabilities (DX-01); only layout does.
public func render(_ state: UIState, width: Int, capabilities: TerminalCapabilities) -> RenderFrame {
    let safeWidth = max(20, width)
    var lines: [SemanticLine] = []
    switch state.status {
    case .idle:
        lines.append(SemanticLine(id: "status-idle", runs: [StyledRun(text: "idle", role: .status)]))
    case .busy(let operation):
        lines.append(SemanticLine(id: "status-busy", runs: [StyledRun(text: terminalSafe(operation), role: .status)]))
    case .held(let reason):
        lines.append(SemanticLine(id: "status-held", runs: [StyledRun(text: "held: \(terminalSafe(reason))", role: .status)]))
    case .failed(let cause):
        lines.append(SemanticLine(id: "status-failed", runs: [StyledRun(text: terminalSafe(cause), role: .errorNotice)]))
    }
    for entry in state.queue {
        lines.append(SemanticLine(
            id: "queue-\(entry.entryID)",
            runs: [StyledRun(text: "\(entry.kind) \(entry.state)\(entry.pending ? " (pending)" : "")", role: .normal)]))
    }
    if let agent = state.activeAgent {
        lines.append(SemanticLine(
            id: "agent",
            runs: [StyledRun(
                text: "\(terminalSafe(agent.modelAlias)) · \(terminalSafe(agent.locality)) · \(terminalSafe(agent.phase))",
                role: .status)]))
    }
    if let suggestion = state.suggestion {
        for (index, candidate) in suggestion.candidates.enumerated() {
            lines.append(SemanticLine(
                id: "candidate-\(index)",
                runs: [StyledRun(
                    text: terminalSafe(candidate.path),
                    role: index == 0 ? .candidateSelected : .candidate)]))
        }
    }
    let wrapped = lines.flatMap { wrapLine($0, width: safeWidth) }
    // Dumb/non-addressable terminals get an inline composer (no overlay);
    // content is identical either way (DX-01 capability fallback).
    if capabilities.cursorAddressing {
        let composer = state.composer
        return RenderFrame(
            lines: wrapped,
            statusLine: nil,
            composerOverlay: ComposerOverlay(text: terminalSafe(composer.text), cursor: composer.cursor),
            width: safeWidth)
    }
    var inline = wrapped
    inline.append(SemanticLine(
        id: "composer-inline",
        runs: [StyledRun(text: "> " + terminalSafe(state.composer.text), role: .composerText)]))
    return RenderFrame(lines: inline, statusLine: nil, composerOverlay: nil, width: safeWidth)
}

private func wrapLine(_ line: SemanticLine, width: Int) -> [SemanticLine] {
    var out: [SemanticLine] = []
    var part = 0
    // Roles never change across visual lines in M1-B: a logical line longer
    // than the width wraps as run-preserving continuations with stable ids.
    // Width counts grapheme clusters, not East-Asian wide columns (M4 owns
    // wcwidth-correct layout; never splits inside a cluster here).
    var budget = width
    var pending: [StyledRun] = []
    for run in line.runs {
        var text = run.text
        while !text.isEmpty {
            if text.count <= budget {
                pending.append(StyledRun(text: text, role: run.role))
                budget -= text.count
                text = ""
            } else {
                let index = text.index(text.startIndex, offsetBy: budget)
                pending.append(StyledRun(text: String(text[..<index]), role: run.role))
                out.append(SemanticLine(id: "\(line.id)#\(part)", runs: pending))
                part += 1
                pending = []
                text = String(text[index...])
                budget = width
            }
        }
    }
    if !pending.isEmpty {
        out.append(SemanticLine(id: part == 0 ? line.id : "\(line.id)#\(part)", runs: pending))
    }
    if out.isEmpty {
        out.append(SemanticLine(id: line.id, runs: []))
    }
    return out
}
