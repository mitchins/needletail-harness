import Testing
@testable import NeedletailTerminal

/// C5.3/C5.6: Cf deny-by-default battery + control neutralization.
/// ONLY U+200D ZWJ survives; every other Cf → U+FFFD. Asserted on
/// sanitized output (the final-byte-stream oracle lives in the owner/
/// span tests with ZWJ-aware expectations — never a blanket "no Cf").
struct DisplaySanitizerTests {
    @Test("only ZWJ survives the Cf classes")
    func onlyZWJSurvives() {
        // Preserved: ZWJ + combining marks (Mn/Mc/Me are not Cf).
        #expect(displaySafe("a\u{200D}b") == "a\u{200D}b")
        #expect(displaySafe("e\u{301}") == "e\u{301}")
        // Neutralized: full Cf battery → U+FFFD.
        for scalar in ["\u{00AD}", "\u{0600}", "\u{200B}", "\u{200C}", "\u{200E}",
                       "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
                       "\u{202E}", "\u{2060}", "\u{2061}", "\u{2062}", "\u{2063}",
                       "\u{2064}", "\u{2066}", "\u{2069}", "\u{206A}", "\u{206F}",
                       "\u{061C}", "\u{FEFF}", "\u{FFF9}", "\u{E0001}"] {
            #expect(displaySafe("x\(scalar)y") == "x�y", "Cf \(scalar.debugDescription) must neutralize")
        }
    }

    @Test("C0/C1 controls escape, LF preserved, NUL/CR visible")
    func controlsEscape() {
        #expect(displaySafe("a\u{0}b") == "a\\u{0}b")
        #expect(displaySafe("a\u{1B}b") == "a\\u{1b}b")
        #expect(displaySafe("a\u{7}b") == "a\\u{7}b")
        #expect(displaySafe("a\u{7F}b") == "a\\u{7f}b")
        #expect(displaySafe("a\u{80}b") == "a\\u{80}b")
        #expect(displaySafe("a\u{9B}b") == "a\\u{9b}b")
        // CSI-neutralized by introducer escape: no live sequence remains.
        #expect(!hasScalar(displaySafe("\u{1B}[31mRED"), 0x1B))
        #expect(displaySafe("a\nb") == "a\nb")
        #expect(displaySafe("a\rb") == "a\\u{d}b")
        // OSC introducer neutralized.
        #expect(!hasScalar(displaySafe("\u{1B}]8;;http://evil\u{7}click"), 0x1B))
    }

    @Test("TAB expands to 8-stop, columns track newlines")
    func tabExpansion() {
        #expect(displaySafe("a\tb") == "a       b")
        #expect(displaySafe("\t") == "        ")
        #expect(displaySafe("1234567\tb") == "1234567 b")
        #expect(displaySafe("a\n\tb") == "a\n        b")
    }

    @Test("emoji ZWJ sequences survive, no split")
    func emojiZWJPreserved() {
        // Family emoji: single grapheme cluster joined by ZWJ.
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(displaySafe(family) == family)
        #expect(displaySafe(family).count == 1)
        // Flag: regional indicators (not Cf) pass through.
        #expect(displaySafe("🇺🇸") == "🇺🇸")
    }

    @Test("plain printable text is byte-identical")
    func printablePassthrough() {
        let text = "Hello, world! 123 #hashtag @mention — café naïve"
        #expect(displaySafe(text) == text)
    }
}
