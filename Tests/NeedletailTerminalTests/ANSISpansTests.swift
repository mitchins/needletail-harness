import Testing
@testable import NeedletailTerminal

/// C1 adapter legs: role→SGR mapping, adjacent merge, empty safety.
struct ANSISpansTests {
    private var caps: TerminalCaps { TerminalCaps(color: true, cursorAddressing: true, width: 80) }

    @Test("unstyled roles pass through, styled roles wrap SGR")
    func roleMapping() {
        #expect(ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "x", role: .normal)]), caps: caps) == "x")
        #expect(ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "x", role: .composerText)]), caps: caps) == "x")
        let strong = ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "x", role: .strong)]), caps: caps)
        #expect(strong == "\u{1B}[1mx\u{1B}[0m")
        let add = ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "+x", role: .diffAdd)]), caps: caps)
        #expect(add == "\u{1B}[32m+x\u{1B}[0m")
        let del = ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "-x", role: .diffDel)]), caps: caps)
        #expect(del == "\u{1B}[31m-x\u{1B}[0m")
        let hunk = ANSISpans.encode(RenderedLine(spans: [TextSpan(text: "@@ x @@", role: .diffHunk)]), caps: caps)
        #expect(hunk.hasPrefix("\u{1B}[36;1m") && hunk.hasSuffix("\u{1B}[0m"))
    }

    @Test("adjacent same-role spans merge into one SGR region")
    func mergeAdjacent() {
        let line = RenderedLine(spans: [
            TextSpan(text: "a", role: .strong),
            TextSpan(text: "b", role: .strong),
            TextSpan(text: "c", role: .normal),
        ])
        #expect(ANSISpans.encode(line, caps: caps) == "\u{1B}[1mab\u{1B}[0mc")
    }

    @Test("empty line and empty input produce no bytes")
    func emptySafety() {
        #expect(ANSISpans.encode(RenderedLine(spans: []), caps: caps) == "")
        #expect(ANSISpans.encodeLines([], caps: caps) == "")
        #expect(ANSISpans.encodeLines([RenderedLine(spans: [])], caps: caps) == "\n")
    }

    @Test("encode assumes sanitized input (boundary documented)")
    func encodeAssumesSanitized() {
        // Contract: sanitization happens upstream (DisplaySanitizer →
        // renderer); encode frames spans blindly. Raw ESC in a span
        // passes through — the pipeline tests prove sanitized input
        // never contains it. Here open+close framing is exact.
        let line = RenderedLine(spans: [TextSpan(text: "a\u{1B}b", role: .strong)])
        let out = ANSISpans.encode(line, caps: caps)
        #expect(out == "\u{1B}[1ma\u{1B}b\u{1B}[0m")
    }
}
