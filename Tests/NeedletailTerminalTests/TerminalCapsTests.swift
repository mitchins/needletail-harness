import Testing
@testable import NeedletailTerminal

/// C5.7/C5.3-adjacent: plain mode keeps semantics with zero ANSI.
struct TerminalCapsTests {
    @Test("NO_COLOR present non-empty disables color only")
    func noColor() {
        let caps = TerminalCaps.fromEnvironment(["NO_COLOR": "1"], isTTYStdout: true, columns: 100)
        #expect(caps.color == false)
        #expect(caps.cursorAddressing == true)
        #expect(caps.width == 100)
    }

    @Test("TERM=dumb disables color and addressing")
    func dumb() {
        let caps = TerminalCaps.fromEnvironment(["TERM": "dumb"], isTTYStdout: true, columns: 80)
        #expect(caps.color == false)
        #expect(caps.cursorAddressing == false)
    }

    @Test("non-TTY stdout is plain")
    func nonTTY() {
        let caps = TerminalCaps.fromEnvironment([:], isTTYStdout: false, columns: 120)
        #expect(caps.color == false)
        #expect(caps.cursorAddressing == false)
        #expect(caps.width == 120)
    }

    @Test("width clamps at 20, defaults to 80")
    func widthRules() {
        #expect(TerminalCaps.fromEnvironment([:], isTTYStdout: true, columns: 5).width == 20)
        #expect(TerminalCaps.fromEnvironment([:], isTTYStdout: true, columns: nil).width == 80)
        #expect(TerminalCaps.fromEnvironment([:], isTTYStdout: true, columns: 200).width == 200)
    }

    @Test("column derivation: explicit, COLUMNS, default, clamp")
    func columns() {
        #expect(TerminalCaps.resolveColumns(env: [:], explicit: 100, ioctlWidth: 50) == 100)
        #expect(TerminalCaps.resolveColumns(env: ["COLUMNS": "120"], explicit: nil, ioctlWidth: 50) == 120)
        #expect(TerminalCaps.resolveColumns(env: ["COLUMNS": "junk"], explicit: nil, ioctlWidth: 50) == 50)
        #expect(TerminalCaps.resolveColumns(env: [:], explicit: nil, ioctlWidth: nil) == 80)
        #expect(TerminalCaps.resolveColumns(env: [:], explicit: 5, ioctlWidth: nil) == 20)
        #expect(TerminalCaps.resolveColumns(env: ["COLUMNS": "-3"], explicit: nil, ioctlWidth: nil) == 80)
        // ioctl probe runs without crashing (nil when non-TTY).
        _ = TerminalCaps.ioctlColumns()
    }

    @Test("plain keeps semantics with zero ANSI bytes")
    func plainZeroANSI() {
        let line = RenderedLine(spans: [
            TextSpan(text: "Hello ", role: .normal),
            TextSpan(text: "bold", role: .strong),
        ])
        let plain = ANSISpans.encode(line, caps: .plain)
        #expect(plain == "Hello bold")
        #expect(!hasScalar(plain, 0x1B))
    }
}
