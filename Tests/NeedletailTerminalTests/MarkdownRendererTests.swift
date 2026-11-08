import Testing
import Foundation
@testable import NeedletailTerminal

/// C1 adapter legs: block structure, roles, links text-first, diff
/// prefix roles, hostile bytes, chunk-invariance, truncation marker.
struct MarkdownRendererTests {
    private var ctx: RenderContext { RenderContext(sessionID: "s", requestID: "r") }

    @Test("headings, emphasis, lists, task lists, code")
    func blockStructure() {
        let lines = renderMarkdownBlock("# Title\n\nHello **bold** and *em* with `code`.\n\n- a\n- [ ] task\n- [x] done\n\n1. first\n2. second\n", context: ctx)
        let headed = lines.filter { $0.spans.contains(where: { $0.role == .heading }) }
        #expect(headed.count == 1)
        #expect(headed[0].plainText == "Title")
        #expect(lines.flatMap(\.spans).contains(where: { $0.role == .strong && $0.text == "bold" }))
        #expect(lines.flatMap(\.spans).contains(where: { $0.role == .emphasis && $0.text == "em" }))
        #expect(lines.flatMap(\.spans).contains(where: { $0.role == .code && $0.text == "code" }))
        #expect(lines.flatMap(\.spans).contains(where: { $0.role == .taskCheckbox }))
        let markers = lines.flatMap(\.spans).filter { $0.role == .listMarker }
        #expect(!markers.isEmpty)
    }

    @Test("fenced code blocks keep fences and language")
    func fencedCode() {
        let lines = renderMarkdownBlock("```swift\nlet x = 1\n```", context: ctx)
        #expect(lines.count == 3)
        #expect(lines[0].plainText == "```swift")
        #expect(lines[1].spans.allSatisfy { $0.role == .codeBlock })
        #expect(lines[2].plainText == "```")
    }

    @Test("blockquotes prefix every line, links are text-first")
    func quoteAndLinks() {
        let lines = renderMarkdownBlock("> quoted **strong**\n\nSee [docs](https://example.com/x).", context: ctx)
        #expect(lines[0].plainText.hasPrefix("> "))
        #expect(lines[0].spans.contains(where: { $0.role == .quote && $0.text == "> " }))
        let linkLine = lines.first(where: { $0.plainText.contains("docs") })
        #expect(linkLine?.plainText.contains("(https://example.com/x)") == true)
        #expect(linkLine?.plainText.contains("\u{1B}]8") == false)
        #expect(!ANSISpans.encodeLines(lines, caps: TerminalCaps()).contains("]8;;"))
    }

    @Test("hostile content neutralized before ANSI")
    func hostileNeutralized() {
        let evil = "Hi\u{1B}[2J\u{202E}\u{200B}\u{0} [x](javascript:\u{1B}]8;;evil\u{7})"
        let lines = renderMarkdownBlock(evil, context: ctx)
        let encoded = ANSISpans.encodeLines(lines, caps: TerminalCaps())
        let escCount = encoded.unicodeScalars.filter { $0 == "\u{1B}" }.count
        // Only renderer SGR framing may contain ESC.
        #expect(!encoded.contains("\u{1B}[2J"))
        #expect(!hasScalar(encoded, 0x202E))
        #expect(escCount <= lines.count * 2 + 2)
    }

    @Test("committed render invariant: determinism + stream-boundary normalization (C5.2)")
    func chunkInvariant() {
        // The renderer only ever sees completed text (no partial-parse
        // API exists): the committed render is a pure function of the
        // completed block. Two genuine properties, not a tautology:
        // (1) fresh parses are deterministic (mid-emoji content
        // included); (2) stream-boundary artifacts (split trailing
        // newlines, leading blank lines) normalize to the same render.
        let text = "# T 👨\u{200D}👩\u{200D}👧\n\nParagraph with **bold**, `code`, and a [link](https://e.com).\n\n- item 1\n- [ ] task\n\n```swift\nlet x = 1\n```\n\n> quote"
        let first = renderMarkdownBlock(text, context: ctx)
        #expect(!first.isEmpty)
        #expect(renderMarkdownBlock(text, context: ctx) == first)
        #expect(renderMarkdownBlock(text + "\n", context: ctx) == first)
        #expect(renderMarkdownBlock(text + "\n\n\n", context: ctx) == first)
        #expect(renderMarkdownBlock("\n\n" + text, context: ctx) == first)
        // Splits never crash the renderer and never leak partial-parse
        // state into later renders (each call parses fresh).
        var idx = text.startIndex
        while idx < text.endIndex {
            _ = renderMarkdownBlock(String(text[..<idx]), context: ctx)
            #expect(renderMarkdownBlock(text, context: ctx) == first)
            idx = text.index(after: idx)
        }
    }

    @Test("tables render head cells and body rows pipe-joined")
    func tables() {
        let lines = renderMarkdownBlock("| a | b |\n|---|---|\n| 1 | 2 |\n", context: ctx)
        #expect(lines.count == 2)
        #expect(lines[0].plainText == "a | b")
        #expect(lines[1].plainText == "1 | 2")
    }

    @Test("adversarial nesting is bounded (depth guard)")
    func depthGuard() {
        // Depths stay comfortably below Darwin-debug stack limits
        // (G14); the guard (64) still fires deterministically.
        let deep = String(repeating: "> ", count: 120) + "deep"
        let lines = renderMarkdownBlock(deep, context: ctx)
        // Guard fires: literal fallback, no stack overflow, bounded count.
        #expect(!lines.isEmpty)
        #expect(lines.count < 20)
        // Inline nesting is guarded too (120 nested strongs).
        var inline = "x"
        for _ in 0 ..< 120 { inline = "**" + inline + "**" }
        let inlineLines = renderMarkdownBlock(inline, context: ctx)
        // Guard fires: literal fallback, no stack overflow, bounded count.
        #expect(!inlineLines.isEmpty)
        #expect(inlineLines.count < 20)
    }

    @Test("partial prefixes parse without crashing and deterministically")
    func partialRobustness() {
        let text = "# T\n\nParagraph **bold\n\n- item\n\n```swift\nlet x = "
        var idx = text.startIndex
        while idx < text.endIndex {
            let prefix = String(text[..<idx])
            // No crash on any partial input; pure function ⇒ identical.
            #expect(renderMarkdownBlock(prefix, context: ctx) == renderMarkdownBlock(prefix, context: ctx))
            idx = text.index(after: idx)
        }
    }

    @Test("over-bound blocks truncate with the exact SPEC 805 marker")
    func truncationMarker() {
        let small = RenderContext(sessionID: "s", requestID: "r", maxBytes: 64)
        let lines = renderMarkdownBlock(String(repeating: "x", count: 10_000), context: small)
        let last = lines.last?.plainText ?? ""
        #expect(last == "…[block truncated at 0 KiB: full text in transcript session=s request=r]")
        #expect(lines.last?.spans.first?.role == .warning)
        // Multibyte boundary: truncation never splits a scalar, and the
        // marker shows whole KiB with sanitized IDs.
        let big = RenderContext(sessionID: "s\u{1B}[31m", requestID: "r\u{202E}", maxBytes: 2048)
        let lines2 = renderMarkdownBlock(String(repeating: "👨\u{200D}👩\u{200D}👧", count: 1000), context: big)
        let last2 = lines2.last?.plainText ?? ""
        #expect(last2 == "…[block truncated at 2 KiB: full text in transcript session=s\\u{1b}[31m request=r�]")
        #expect(lines2.last?.spans.first?.role == .warning)
    }

    @Test("final byte stream: Cf battery neutralized, only ZWJ survives (C5.3)")
    func finalStreamCfBattery() {
        // Every Cf class through the full pipeline (parse → sanitize →
        // encode): only ZWJ reaches the stream; the rest → U+FFFD.
        // ZWJ-aware oracle: NO blanket "no Cf" assertion.
        let battery = "a\u{00AD}b\u{0600}c\u{200B}d\u{200C}e\u{200E}f\u{200F}g\u{202A}h\u{202E}i\u{2060}j\u{2066}k\u{061C}l\u{FEFF}m\u{FFF9}n\u{E0020}o\u{200D}p"
        let lines = renderMarkdownBlock(battery, context: ctx)
        let encoded = ANSISpans.encodeLines(lines, caps: TerminalCaps())
        for scalar in ["\u{00AD}", "\u{0600}", "\u{200B}", "\u{200C}", "\u{200E}",
                       "\u{200F}", "\u{202A}", "\u{202E}", "\u{2060}", "\u{2066}",
                       "\u{061C}", "\u{FEFF}", "\u{FFF9}", "\u{E0020}"] {
            // Scalar-level (see ScalarAsserts.swift): lone-Cf
            // `String.contains` is platform-divergent.
            #expect(!hasScalar(encoded, scalar.unicodeScalars.first!.value), "\(scalar.debugDescription) must not survive")
        }
        #expect(hasScalar(encoded, 0x200D))
        let fffdCount = encoded.unicodeScalars.filter { $0 == "�" }.count
        #expect(fffdCount == 14)
        // No raw control bytes outside SGR framing.
        for b in encoded.utf8 {
            if b < 0x20 && b != 0x0A && b != 0x1B {
                Issue.record("raw control byte \(b) in final stream")
            }
        }
    }

    @Test("diff hunks classify by prefix; hostile bytes sanitized")
    func diffRoles() {
        let lines = DiffRenderer.renderHunks([
            "diff --git a/f b/f",
            "--- a/f",
            "+++ b/f",
            "@@ -1 +1 @@",
            "+added\u{1B}[31m",
            "-removed\u{202E}",
            " context",
        ])
        #expect(lines[0].spans.first?.role == .diffHunk)
        #expect(lines[3].spans.first?.role == .diffHunk)
        #expect(lines[4].spans.first?.role == .diffAdd)
        #expect(!hasScalar(lines[4].plainText, 0x1B))
        #expect(lines[5].spans.first?.role == .diffDel)
        #expect(!hasScalar(lines[5].plainText, 0x202E))
        #expect(lines[6].spans.first?.role == .normal)
    }
}
