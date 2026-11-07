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
    case .completedBudgetBoundary(let detail):
        lines.append(SemanticLine(id: "status-budget-boundary", runs: [StyledRun(text: "completed (budget boundary): \(terminalSafe(detail))", role: .status)]))
    }
    for entry in state.queue {
        var text = "\(entry.kind) \(entry.state)\(entry.pending ? " (pending)" : "")"
        if entry.staleTarget {
            text += " [stale target]"
        }
        if entry.hasAttachments {
            text += " [attachments]"
        }
        lines.append(SemanticLine(
            id: "queue-\(entry.entryID)",
            runs: [StyledRun(text: terminalSafe(text), role: .normal)]))
    }
    if let agent = state.activeAgent {
        lines.append(SemanticLine(
            id: "agent",
            runs: [StyledRun(
                text: "\(terminalSafe(agent.modelAlias)) · \(terminalSafe(agent.locality)) · \(terminalSafe(agent.phase))",
                role: .status)]))
    }
    if let approval = state.pendingApproval {
        var text = "\(approval.sandbox ? "sandbox" : "human") approval: \(terminalSafe(approval.operation)) [\(terminalSafe(approval.requiredGrant))]"
        if !approval.protectedPaths.isEmpty {
            text += " scope: \(approval.protectedPaths.map(terminalSafe).joined(separator: ","))"
        }
        lines.append(SemanticLine(
            id: "approval-request",
            runs: [StyledRun(text: text, role: .candidateSelected)]))
        for (index, identity) in approval.execIdentities.enumerated() {
            lines.append(SemanticLine(
                id: "approval-exec-\(index)",
                runs: [StyledRun(
                    text: "exec: \(terminalSafe(identity.resolvedPath))#\(terminalSafe(identity.contentDigest))",
                    role: .normal)]))
        }
    }
    if let suggestion = state.suggestion {
        let selected = suggestion.selectedIndex ?? 0
        for (index, candidate) in suggestion.candidates.enumerated() {
            lines.append(SemanticLine(
                id: "candidate-\(index)",
                runs: [StyledRun(
                    text: terminalSafe(candidate.path),
                    role: index == selected ? .candidateSelected : .candidate)]))
        }
        if let error = suggestion.rangeError {
            lines.append(SemanticLine(
                id: "mention-range-error",
                runs: [StyledRun(text: terminalSafe(error), role: .errorNotice)]))
        }
    }
    if let inspection = state.inspection {
        switch inspection {
        case .sessions(let rows):
            for row in rows {
                lines.append(SemanticLine(
                    id: "session-\(row.row.sessionID.raw)",
                    runs: [StyledRun(
                        text: "\(row.row.sessionID.raw) \(row.liveness.rawValue) \(terminalSafe(row.row.modelAlias))",
                        role: .normal)]))
            }
        case .agents(let rows):
            for (index, agent) in rows.enumerated() {
                lines.append(SemanticLine(
                    id: "agent-\(index)",
                    runs: [StyledRun(
                        text: "\(terminalSafe(agent.alias)) · \(terminalSafe(agent.phase))",
                        role: .status)]))
                if let child = agent.childActivity {
                    lines.append(SemanticLine(
                        id: "agent-\(index)-child",
                        runs: [StyledRun(text: "child: \(terminalSafe(child))", role: .normal)]))
                }
            }
        case .models(let routes):
            for route in routes {
                lines.append(SemanticLine(
                    id: "model-\(route.alias)",
                    runs: [StyledRun(
                        text: "\(terminalSafe(route.alias)) [\(route.kind.rawValue)] \(terminalSafe(route.locality))",
                        role: .normal)]))
            }
        case .context(let usage):
            let tokens = usage.inputTokens.map(String.init) ?? "estimated"
            let cache: String
            if usage.cacheUnknown {
                cache = "cache unknown"
            } else if let hits = usage.cacheHits {
                cache = "cache \(hits) hits"
            } else {
                cache = "cache unknown"
            }
            lines.append(SemanticLine(
                id: "context-usage",
                runs: [StyledRun(
                    text: "tokens \(tokens)\(usage.estimated ? " (estimated)" : "") · \(cache) · receipts \(usage.receipts) · unverified \(usage.unverifiedClaims)",
                    role: .normal)]))
        case .epochs(let rows):
            for row in rows {
                let checkpoint: String
                switch row.checkpoint {
                case .none: checkpoint = "no checkpoint"
                case .success(let cost): checkpoint = "checkpoint ok (\(cost)ms)"
                case .failed(let reason): checkpoint = "failed: \(reason)"
                }
                var text = "\(row.epochID) <- \(row.parentID ?? "-") · \(checkpoint)"
                if let prefill = row.prefill {
                    text += " · prefill \(prefill)"
                }
                lines.append(SemanticLine(
                    id: "epoch-\(row.epochID)",
                    runs: [StyledRun(text: terminalSafe(text), role: .normal)]))
            }
        case .compact(let preview):
            lines.append(SemanticLine(
                id: "compact-estimate",
                runs: [StyledRun(
                    text: "compact dry-run: ~\(preview.estimatedTokens) tokens, \(preview.wouldReplaceEpoch ? "would replace epoch" : "no epoch change"), 0 provider calls (\(terminalSafe(preview.note)))",
                    role: .normal)]))
        case .queue(let ids):
            for id in ids {
                lines.append(SemanticLine(
                    id: "inspect-queue-\(id)",
                    runs: [StyledRun(text: id, role: .normal)]))
            }
        case .diff(let files):
            for file in files {
                // Paths are untrusted (dirty-tree filenames can carry
                // control/format scalars): sanitize the text AND derive
                // the id from the sanitized form.
                let safePath = terminalSafe(file.path)
                lines.append(SemanticLine(
                    id: "diff-\(safePath)",
                    runs: [StyledRun(
                        text: "\(safePath) [\(file.provenance.rawValue)]",
                        role: .normal)]))
                for (index, hunk) in file.hunks.enumerated() {
                    lines.append(SemanticLine(
                        id: "diff-\(safePath)#\(index)",
                        runs: [StyledRun(text: terminalSafe(hunk), role: .normal)]))
                }
            }
        case .undoPreview(let preview):
            lines.append(SemanticLine(
                id: "undo-preview-\(preview.groupID)",
                runs: [StyledRun(
                    text: "undo \(preview.groupID): \(preview.canRun ? "ready" : "blocked") — \(terminalSafe(preview.notice))",
                    role: preview.canRun ? .status : .errorNotice)]))
            for file in preview.files {
                var text = "\(file.path): \(file.eligible ? "eligible" : "ineligible")"
                if let conflict = file.conflict {
                    text += " (\(conflict))"
                }
                let safePath = terminalSafe(file.path)
                lines.append(SemanticLine(
                    id: "undo-file-\(safePath)",
                    runs: [StyledRun(text: terminalSafe(text), role: file.eligible ? .normal : .errorNotice)]))
            }
        case .undoOutcome(let outcome):
            lines.append(SemanticLine(
                id: "undo-outcome-\(outcome.groupID)",
                runs: [StyledRun(
                    text: "undo \(outcome.groupID): \(outcome.applied.count) applied, \(outcome.refused.count) refused, \(outcome.failed.count) failed — \(terminalSafe(outcome.notice))",
                    role: outcome.failed.isEmpty ? .status : .errorNotice)]))
        case .rewind(let view):
            lines.append(SemanticLine(
                id: "rewind-\(view.boundaryEpoch)",
                runs: [StyledRun(
                    text: "rewind to \(view.boundaryEpoch)#\(view.throughSequence)\(view.divergent ? " DIVERGENT" : ""): \(terminalSafe(view.warning))",
                    role: view.divergent ? .errorNotice : .status)]))
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
