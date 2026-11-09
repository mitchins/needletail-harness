import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation

/// M4-D D4.2 Unicode cell-width/layout acceptance: the AS-BUILT
/// grapheme-cluster rule. `render()`/`wrapLine` count Swift Characters
/// (never bytes, never wcwidth columns) and never split inside a
/// cluster. CJK counts ONE unit per character (wcwidth-2 is explicitly
/// out of scope per the M4-B rule — pinned here, limitation recorded
/// in the receipt). Scalar neutralization (Cf/controls/TAB/ZWJ) is
/// owned by `DisplaySanitizerTests`; this suite owns WRAP placement.
/// All expectations are hand-computed, never generated.
struct ChatWidthTests {
    /// Probe carrier: `submitDraft` parks the composer text in the
    /// status-busy line, which IS wrapped (the inline composer is
    /// appended post-wrap and never wraps — layout probes must not
    /// use it).
    private static func statusParts(_ text: String, width: Int) -> [String] {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText(text)))
        (state, _) = reduce(state, .input(.submitDraft(commandID: CommandID("w-1"))))
        let frame = render(state, width: width, capabilities: .dumb)
        return frame.lines
            .filter { $0.id.hasPrefix("status-busy") }
            .map { $0.runs.map(\.text).joined() }
    }

    @Test("D4.2 CJK counts one wrap unit per character (as-built grapheme rule, not wcwidth-2)")
    func cjkCountsOneUnit() {
        // 41 CJK chars at width 40: a wcwidth-correct layout would need
        // 82 columns; the as-built rule wraps at 40 Characters
        // (limitation: East-Asian wide columns display wider than
        // counted — recorded, not changed).
        let text = String(repeating: "漢", count: 41)
        let parts = Self.statusParts(text, width: 40)
        #expect(parts.count == 2, "expected exactly one wrap, got \(parts.count)")
        #expect(parts[0] == String(repeating: "漢", count: 40))
        #expect(parts[1] == "漢")
    }

    @Test("D4.2 CJK char at the wrap edge moves whole to the next line")
    func cjkEdgeNeverSplits() {
        // Exactly 40 chars at width 40: no wrap. One more char wraps
        // WHOLE (Characters are indivisible here).
        let exact = String(repeating: "字", count: 40)
        #expect(Self.statusParts(exact, width: 40).count == 1)
        let plusOne = String(repeating: "字", count: 41)
        let parts = Self.statusParts(plusOne, width: 40)
        #expect(parts.count == 2)
        #expect(parts[0] == exact)
        #expect(parts[1] == "字")
    }

    @Test("D4.2 combining sequences count one unit and never split base from mark")
    func combiningSequencesUnsplittable() {
        // "é" as e + U+0301 (decomposed: two scalars, one Character).
        let pair = "é"
        #expect(pair.count == 1, "precondition: combining pair is one Character")
        // 25 pairs at width 40: one line.
        let pairs = String(repeating: pair, count: 25)
        #expect(Self.statusParts(pairs, width: 40).count == 1)
        // Width 20: 20 pairs + 5 pairs.
        let parts = Self.statusParts(pairs, width: 20)
        #expect(parts.count == 2)
        #expect(parts[0] == String(repeating: pair, count: 20))
        #expect(parts[1] == String(repeating: pair, count: 5))
        // No line may end with a bare base "e" (stranded mark).
        for part in parts {
            #expect(!part.hasSuffix("e"), "combining mark must not strand its base: \(part.suffix(8))")
        }
    }

    @Test("D4.2 regional-indicator flags wrap whole at the boundary")
    func flagsWrapWhole() {
        // 21 flags at width 20: 20 flags on line 1, one whole flag on
        // line 2 — never lone halves.
        let flags = String(repeating: "🇺🇸", count: 21)
        #expect(flags.count == 21, "precondition: flag is one Character")
        let parts = Self.statusParts(flags, width: 20)
        #expect(parts.count == 2)
        #expect(parts[0] == String(repeating: "🇺🇸", count: 20))
        #expect(parts[1] == "🇺🇸")
        let joined = parts.joined()
        #expect(joined.filter({ $0 == "🇺" }).isEmpty, "no lone regional indicator may strand")
        #expect(joined.filter({ $0 == "🇸" }).isEmpty, "no lone regional indicator may strand")
    }

    @Test("D4.2 mixed-script wrap matches the hand-computed boundary exactly")
    func mixedScriptExactWrap() {
        // "ab"(2) + 10 CJK(10) + flag(1) + "cdefghij"(8) = 21 units at
        // width 20 → line 1 takes the first 20, line 2 keeps "j".
        // Roles never change across the wrap (DX-01).
        let text = "ab" + String(repeating: "漢", count: 10) + "🇺🇸" + "cdefghij"
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText(text)))
        (state, _) = reduce(state, .input(.submitDraft(commandID: CommandID("w-1"))))
        let frame = render(state, width: 20, capabilities: .dumb)
        let parts = frame.lines.filter { $0.id.hasPrefix("status-busy") }
        #expect(parts.count == 2)
        #expect(parts[0].runs.map(\.text).joined() == "ab" + String(repeating: "漢", count: 10) + "🇺🇸cdefghi")
        #expect(parts[1].runs.map(\.text).joined() == "j")
        #expect(parts[0].id == "status-busy#0" && parts[1].id == "status-busy#1")
        #expect(parts.flatMap(\.runs).allSatisfy { $0.role == .status },
            "roles are invariant across the wrap (DX-01)")
    }

    @Test("D4.2 TAB in the draft renders as a visible escape, counted literally")
    func tabRendersVisible() {
        // TAB never reaches the terminal as a control: terminalSafe
        // escapes it ("\\u{9}", six units), and wrap counts the escape.
        let parts = Self.statusParts("a\tb", width: 40)
        #expect(parts.count == 1)
        #expect(parts[0] == "a\\u{9}b")
    }
}
