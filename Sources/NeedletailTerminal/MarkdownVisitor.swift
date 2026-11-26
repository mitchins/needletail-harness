import Foundation
import Markdown
import NeedletailPresentation

/// M4-C Markup tree walk (swift-markdown `.exact("0.9.0")`).
///
/// Operates on COMPLETED block text only. Every leaf string passes
/// through `displaySafe` before it lands in a span — structure comes
/// from the parse, bytes from the sanitizer. Unknown/unsafe nodes
/// (raw HTML, directives, custom nodes) render as sanitized literal
/// text, never interpreted. Fallback role for unmapped inline nodes
/// is `.normal` (documented, never silent restyle).
enum MarkdownVisitor {
    static func render(_ source: String) -> [RenderedLine] {
        let document = Document(parsing: source)
        var out: [RenderedLine] = []
        for child in document.children {
            out.append(contentsOf: renderBlock(child, indent: ""))
        }
        return out
    }

    // MARK: - Blocks

    /// Adversarial nesting guard (G13/G14): recursion depth is capped;
    /// deeper blocks render as one sanitized literal line, never a
    /// debug-stack overflow. 64 levels exceed any honest document.
    private static let maxDepth = 64

    private static func renderBlock(_ node: Markup, indent: String, depth: Int = 0) -> [RenderedLine] {
        if depth > maxDepth {
            return [line(prefix: indent, spans: [TextSpan(text: displaySafe(node.debugDescription()), role: .normal)])]
        }
        switch node {
        case let heading as Heading:
            return [line(prefix: indent, spans: inline(heading, role: .heading))]
        case let paragraph as Paragraph:
            return [line(prefix: indent, spans: inline(paragraph, role: .normal))]
        case let code as CodeBlock:
            var lines: [RenderedLine] = []
            let fence = "```" + (code.language.map { displaySafe($0) } ?? "")
            lines.append(line(prefix: indent, spans: [TextSpan(text: fence, role: .codeBlock)]))
        // cmark terminates code with LF: drop the single trailing
        // split, keep interior blank lines byte-exact.
        var parts = code.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        for raw in parts {
            lines.append(line(prefix: indent, spans: [TextSpan(text: displaySafe(raw), role: .codeBlock)]))
        }
            lines.append(line(prefix: indent, spans: [TextSpan(text: "```", role: .codeBlock)]))
            return lines
        case let quote as BlockQuote:
            var lines: [RenderedLine] = []
            for child in quote.children {
                for rendered in renderBlock(child, indent: "", depth: depth + 1) {
                    var spans = [TextSpan(text: indent + "> ", role: .quote)]
                    spans.append(contentsOf: rendered.spans)
                    lines.append(RenderedLine(spans: spans))
                }
            }
            return lines
        case let list as UnorderedList:
            return renderListItems(list.children, indent: indent, ordered: nil, depth: depth + 1)
        case let list as OrderedList:
            return renderListItems(list.children, indent: indent, ordered: list.startIndex, depth: depth + 1)
        case is ThematicBreak:
            return [line(prefix: indent, spans: [TextSpan(text: "---", role: .normal)])]
        case let table as Table:
            // Head children are Cells directly (not Rows); Body
            // children are Rows of Cells. Both render pipe-joined.
            var lines: [RenderedLine] = []
            for section in table.children {
                if section is Table.Head {
                    lines.append(renderCells(Array(section.children), indent: indent))
                } else {
                    for row in section.children {
                        lines.append(renderCells(Array(row.children), indent: indent))
                    }
                }
            }
            return lines
        case let html as HTMLBlock:
            return [line(prefix: indent, spans: [TextSpan(text: displaySafe(html.rawHTML), role: .normal)])]
        default:
            // BlockDirective, CustomBlock, unknown: sanitized literal.
            var spans: [TextSpan] = []
            collectInline(node, role: .normal, into: &spans, depth: depth)
            if spans.isEmpty {
                spans = [TextSpan(text: displaySafe(node.debugDescription()), role: .normal)]
            }
            return [line(prefix: indent, spans: spans)]
        }
    }

    private static func renderListItems(_ items: MarkupChildren, indent: String, ordered start: UInt?, depth: Int) -> [RenderedLine] {
        var lines: [RenderedLine] = []
        var number = start ?? 1
        for item in items {
            let marker: String
            if let listItem = item as? ListItem, let checkbox = listItem.checkbox {
                marker = checkbox == .checked ? "[x] " : "[ ] "
                lines.append(contentsOf: renderListItem(item, marker: marker, markerRole: .taskCheckbox, indent: indent, depth: depth))
            } else if start != nil {
                marker = "\(number). "
                number += 1
                lines.append(contentsOf: renderListItem(item, marker: marker, markerRole: .listMarker, indent: indent, depth: depth))
            } else {
                lines.append(contentsOf: renderListItem(item, marker: "- ", markerRole: .listMarker, indent: indent, depth: depth))
            }
        }
        return lines
    }

    private static func renderCells(_ cells: [Markup], indent: String) -> RenderedLine {
        var spans: [TextSpan] = [TextSpan(text: indent, role: .normal)]
        var first = true
        for cell in cells {
            if !first { spans.append(TextSpan(text: " | ", role: .normal)) }
            first = false
            spans.append(contentsOf: inline(cell, role: .normal))
        }
        return RenderedLine(spans: spans)
    }

    private static func renderListItem(_ item: Markup, marker: String, markerRole: StyleRole, indent: String, depth: Int) -> [RenderedLine] {
        var lines: [RenderedLine] = []
        var first = true
        for child in item.children {
            // Children render unindented; the item applies the marker to
            // the first line and a hanging indent below (no double
            // indent for nested blocks — the child carries none).
            let continuation = indent + String(repeating: " ", count: marker.count)
            for rendered in renderBlock(child, indent: "", depth: depth + 1) {
                if first {
                    var spans = [TextSpan(text: indent + marker, role: markerRole)]
                    spans.append(contentsOf: rendered.spans)
                    lines.append(RenderedLine(spans: spans))
                    first = false
                } else {
                    var spans = [TextSpan(text: continuation, role: .normal)]
                    spans.append(contentsOf: rendered.spans)
                    lines.append(RenderedLine(spans: spans))
                }
            }
        }
        if first {
            lines.append(line(prefix: indent, spans: [TextSpan(text: marker.trimmingCharacters(in: .whitespaces), role: markerRole)]))
        }
        return lines
    }

    // MARK: - Inline

    private static func inline(_ node: Markup, role: StyleRole, depth: Int = 0) -> [TextSpan] {
        var spans: [TextSpan] = []
        collectInline(node, role: role, into: &spans, depth: depth)
        return spans
    }

    private static func collectInline(_ node: Markup, role: StyleRole, into spans: inout [TextSpan], depth: Int) {
        // Same adversarial cap as blocks: degenerate inline nesting
        // renders one sanitized literal instead of recursing.
        if depth > maxDepth {
            spans.append(TextSpan(text: displaySafe(node.debugDescription()), role: role))
            return
        }
        switch node {
        case let text as Text:
            spans.append(TextSpan(text: displaySafe(text.string), role: role))
        case let code as InlineCode:
            spans.append(TextSpan(text: displaySafe(code.code), role: .code))
        case let strong as Strong:
            for child in strong.children { collectInline(child, role: .strong, into: &spans, depth: depth + 1) }
        case let emphasis as Emphasis:
            for child in emphasis.children { collectInline(child, role: .emphasis, into: &spans, depth: depth + 1) }
        case let strike as Strikethrough:
            // No strikethrough role (documented fallback): normal.
            for child in strike.children { collectInline(child, role: .normal, into: &spans, depth: depth + 1) }
        case let link as Link:
            for child in link.children { collectInline(child, role: role, into: &spans, depth: depth + 1) }
            if let destination = link.destination {
                // Text-first links, never OSC-8 (SPEC ¶805).
                spans.append(TextSpan(text: " (\(displaySafe(destination)))", role: .filePath))
            }
        case let image as Image:
            for child in image.children { collectInline(child, role: role, into: &spans, depth: depth + 1) }
            if let source = image.source {
                spans.append(TextSpan(text: " (image: \(displaySafe(source)))", role: .filePath))
            }
        case is SoftBreak:
            spans.append(TextSpan(text: " ", role: role))
        case is LineBreak:
            spans.append(TextSpan(text: "\n", role: role))
        case let symbol as SymbolLink:
            for child in symbol.children { collectInline(child, role: role, into: &spans, depth: depth + 1) }
            if let destination = symbol.destination {
                spans.append(TextSpan(text: " (symbol: \(displaySafe(destination)))", role: .filePath))
            }
        case let html as InlineHTML:
            spans.append(TextSpan(text: displaySafe(html.rawHTML), role: role))
        default:
            for child in node.children { collectInline(child, role: role, into: &spans, depth: depth + 1) }
        }
    }

    private static func line(prefix: String, spans: [TextSpan]) -> RenderedLine {
        if prefix.isEmpty { return RenderedLine(spans: spans) }
        var out = [TextSpan(text: prefix, role: .normal)]
        out.append(contentsOf: spans)
        return RenderedLine(spans: out)
    }
}
