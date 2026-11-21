import Testing
import Foundation

/// M4-D D3: the test-only VT projection is itself unit-tested over a
/// fixture corpus (spec ¶1134 "bounded tested VT projection"). These
/// oracles pin cursor tracking, the OSC title model, and the
/// ignore-and-record policy — PTY-05/PTY-06 consume the projection.
struct VTProjectionTests {

    @Test("cursor addressing tracks CUP/CHA/CUU/CUD/CUF/CUB/CNL/CPL")
    func cursorMoves() {
        var p = VTProjection(rows: 24, cols: 80)
        p.feed("\u{1B}[10;20H")
        #expect(p.cursorRow == 10 && p.cursorCol == 20, "CUP, got \(p.cursorRow),\(p.cursorCol)")
        #expect(!p.sawUnsupported)
        p.feed("\u{1B}[5A")
        #expect(p.cursorRow == 5, "CUU")
        p.feed("\u{1B}[2B")
        #expect(p.cursorRow == 7, "CUD")
        p.feed("\u{1B}[3C")
        #expect(p.cursorCol == 23, "CUF")
        p.feed("\u{1B}[30D")
        #expect(p.cursorCol == 1, "CUB clamps at 1")
        p.feed("\u{1B}[40G")
        #expect(p.cursorCol == 40, "CHA")
        p.feed("\u{1B}[2E")
        #expect(p.cursorRow == 9 && p.cursorCol == 1, "CNL")
        p.feed("\u{1B}[1F")
        #expect(p.cursorRow == 8 && p.cursorCol == 1, "CPL")
        p.feed("\u{1B}[3;4f")
        #expect(p.cursorRow == 3 && p.cursorCol == 4, "HPR f-form")
        #expect(!p.sawUnsupported, "no unsupported in the cursor corpus")
    }

    @Test("empty CSI parameter fields stay positional")
    func emptyParamsStayPositional() {
        var p = VTProjection(rows: 24, cols: 80)
        p.feed("\u{1B}[;5H")
        #expect(p.cursorRow == 1 && p.cursorCol == 5, "omitted row defaults to 1, got \(p.cursorRow),\(p.cursorCol)")
        #expect(!p.sawOutOfRange)
        p.feed("\u{1B}[3;H")
        #expect(p.cursorRow == 3 && p.cursorCol == 1, "omitted column defaults to 1, got \(p.cursorRow),\(p.cursorCol)")
        p.feed("\u{1B}[;81H")
        #expect(p.cursorRow == 1 && p.cursorCol == 81, "column clamps at cols+1, got \(p.cursorRow),\(p.cursorCol)")
        #expect(p.sawOutOfRange, "out-of-range column latches on the column axis")
    }

    @Test("erase, SGR, modes and paste markers move nothing and stay silent")
    func benignSequencesIgnored() {
        var p = VTProjection(rows: 24, cols: 80)
        p.feed("\u{1B}[10;20H")
        // SGR styling, erase line/screen, bracketed-paste toggles,
        // cursor visibility, charset selects, reverse index.
        p.feed("\u{1B}[1;31m\u{1B}[0m\u{1B}[K\u{1B}[2J\u{1B}[?2004h\u{1B}[?2004l\u{1B}[?25l\u{1B}[?25h\u{1B}[200~\u{1B}[201~\u{1B}(B\u{1B}M")
        #expect(p.cursorRow == 9 && p.cursorCol == 20, "only M moved, got \(p.cursorRow),\(p.cursorCol)")
        #expect(!p.sawUnsupported, "benign set must stay silent")
    }

    @Test("printables advance, CR/LF behave, clamping holds")
    func printablesAndNewlines() {
        var p = VTProjection(rows: 24, cols: 10)
        p.feed("hello")
        #expect(p.cursorCol == 6, "five cells, got \(p.cursorCol)")
        p.feed("\r")
        #expect(p.cursorCol == 1, "CR returns carriage")
        p.feed("\n")
        #expect(p.cursorRow == 2 && p.cursorCol == 1, "LF advances row")
        p.feed(String(repeating: "x", count: 40))
        #expect(p.cursorCol == 11, "clamps at cols+1, got \(p.cursorCol)")
        p.feed("\u{1B}[1;1H")
        #expect(p.cursorRow == 1 && p.cursorCol == 1)
        #expect(!p.sawUnsupported)
    }

    @Test("OSC 0/2 sets the modeled title; other OSC ignored silently")
    func oscTitleModel() {
        var p = VTProjection()
        p.feed("\u{1B}]0;baseline\u{07}")
        #expect(p.title == "baseline", "BEL-terminated title, got \(p.title)")
        p.feed("\u{1B}]2;pwned\u{1B}\\")
        #expect(p.title == "pwned", "ESC-backslash-terminated title")
        #expect(!p.sawUnsupported, "OSC never latches (title-modeled or ignored)")
        var q = VTProjection()
        q.feed("\u{1B}]99;weird\u{07}")
        #expect(q.title.isEmpty, "non-title OSC leaves the baseline")
        #expect(!q.sawUnsupported)
    }

    @Test("unknown sequences latch sawUnsupported without moving the model")
    func unknownLatches() {
        var p = VTProjection(rows: 24, cols: 80)
        p.feed("\u{1B}[10;20H")
        p.feed("\u{1B}[9q") // DECSCUSR (cursor style): unlisted.
        #expect(p.sawUnsupported, "unlisted CSI must latch")
        #expect(p.cursorRow == 10 && p.cursorCol == 20, "latch must not move the model")
        var q = VTProjection()
        q.feed("\u{1B}7") // DECSC: unlisted.
        #expect(q.sawUnsupported)
        var r = VTProjection()
        r.feed("\u{1B}[38;5;196m") // Extended SGR color: final m is listed.
        #expect(!r.sawUnsupported, "SGR final m stays silent regardless of params")
    }

    @Test("allowlist passes harness sequences, flags OSC and strays")
    func allowlistScan() {
        #expect(VTAllowlist.violation(in: "\u{1B}[1;31mhi\u{1B}[0m\u{1B}[23G\u{1B}[K\u{1B}[?2004h> ") == nil,
            "harness set must scan clean")
        let osc = VTAllowlist.violation(in: "x\u{1B}]0;pwned\u{07}y")
        #expect(osc != nil, "raw OSC must flag: \(osc ?? "clean")")
        let stray = VTAllowlist.violation(in: "x\u{1B}7y")
        #expect(stray != nil, "stray ESC must flag")
        #expect(VTAllowlist.violation(in: "plain text, no escapes") == nil)
        #expect(VTAllowlist.violation(in: "\u{1B}[9q") != nil, "unlisted CSI final must flag")
    }

    @Test("absolute addresses outside the viewport latch sawOutOfRange")
    func outOfRangeLatches() {
        // Stale-width cursor math (the PTY-05 resize-storm failure
        // mode): G/CUP past the edge must latch, and the model still
        // clamps so projection continues.
        var wide = VTProjection(rows: 24, cols: 80)
        wide.feed("\u{1B}[90G")
        #expect(wide.sawOutOfRange, "CHA past the edge must latch")
        #expect(wide.cursorCol == 81, "latch must still clamp")
        var cup = VTProjection(rows: 24, cols: 80)
        cup.feed("\u{1B}[30;90H")
        #expect(cup.sawOutOfRange, "CUP past the edge must latch")
        #expect(cup.cursorRow == 24 && cup.cursorCol == 81, "latch must still clamp")
        // In-range addressing and normal overflow stay silent:
        // printables wrap and newlines scroll on real terminals.
        var ok = VTProjection(rows: 24, cols: 80)
        ok.feed("\u{1B}[10;20H")
        ok.feed(String(repeating: "x", count: 200))
        ok.feed("\n\n\n")
        #expect(!ok.sawOutOfRange, "in-range CUP + wrap/scroll overflow must not latch")
        #expect(!ok.sawUnsupported)
    }
}
