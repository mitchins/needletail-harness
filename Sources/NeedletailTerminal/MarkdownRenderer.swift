import Foundation
import NeedletailPresentation

/// M4-C completed-block Markdown renderer (adapter tier).
///
/// Parses COMPLETED blocks only (`Document(parsing:)` from swift-markdown,
/// pinned `.exact("0.9.0")`). Partial stream input is never parsed — the
/// streaming contract shows a transient progress line and commits only
/// finished blocks. Canonical bytes stay in the store; display
/// transforms are one-way. Every leaf text passes through
/// `displaySafe` BEFORE any ANSI span is emitted.
///
/// UX-RENDER adapter legs: semantic roles map 1:1 to `StyleRole`
/// (extended additively in Presentation); the ANSI stage is a separate
/// pass (`ANSISpans.encode`), so plain mode (`caps.color == false`)
/// keeps identical semantics with zero ANSI bytes. Never claim
/// physical-terminal qualification from these semantic tests.
public struct TextSpan: Sendable, Equatable {
    public var text: String
    public var role: StyleRole

    public init(text: String, role: StyleRole) {
        self.text = text
        self.role = role
    }
}

public struct RenderedLine: Sendable, Equatable {
    public var spans: [TextSpan]

    public init(spans: [TextSpan]) {
        self.spans = spans
    }

    public var plainText: String {
        spans.map(\.text).joined()
    }
}

public struct RenderContext: Sendable, Equatable {
    public var sessionID: String
    public var requestID: String
    /// Authoritative-text byte bound (default 256 KiB per plan).
    public var maxBytes: Int

    public init(sessionID: String = "", requestID: String = "", maxBytes: Int = 256 * 1024) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.maxBytes = maxBytes
    }
}

/// Renders one completed assistant block. Over-bound input truncates
/// with the exact SPEC ¶805 marker (transcript is the retained
/// artifact). Output is deterministic: same text + context ⇒ same
/// lines, regardless of how the stream was chunked.
public func renderMarkdownBlock(_ text: String, context: RenderContext = RenderContext()) -> [RenderedLine] {
    var source = text
    var truncated = false
    if source.utf8.count > context.maxBytes {
        // Truncate on a UTF-8 boundary, never mid-scalar.
        var prefix = source.prefix(context.maxBytes)
        while prefix.utf8.count > context.maxBytes { prefix = prefix.dropLast() }
        source = String(prefix)
        truncated = true
    }
    var lines = MarkdownVisitor.render(source)
    if truncated {
        // Session/request IDs are unvalidated operator-model strings:
        // sanitize before they land in a span (security invariant: no
        // unsanitized string reaches ANSISpans.encode).
        let session = displaySafe(context.sessionID)
        let request = displaySafe(context.requestID)
        lines.append(RenderedLine(spans: [TextSpan(
            text: "…[block truncated at \(context.maxBytes / 1024) KiB: full text in transcript session=\(session) request=\(request)]",
            role: .warning)]))
    }
    return lines
}
