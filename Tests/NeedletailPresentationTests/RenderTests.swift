import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// Semantic rendering: content roles stable across width/capabilities;
/// only layout moves. Untrusted strings render escaped (H2 carry-over).
struct RenderTests {

    private static func busyState() -> UIState {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText("draft text here")))
        (state, _) = reduce(state, .session(.admitted(commandID: CommandID("q-1"), revision: 1)))
        return state
    }

    @Test("DX-01 width changes layout, never content roles")
    func DX_01_widthOnlyLayouts() throws {
        let state = Self.busyState()
        let narrow = render(state, width: 40, capabilities: TerminalCapabilities())
        let wide = render(state, width: 120, capabilities: TerminalCapabilities())
        #expect(narrow.width == 40 && wide.width == 120)
        func roles(_ frame: RenderFrame) -> [StyleRole] {
            frame.lines.flatMap(\.runs).map(\.role)
        }
        #expect(Set(roles(narrow)) == Set(roles(wide)), "same content roles at any width")
        #expect(narrow.lines.count >= wide.lines.count, "narrower wraps to at least as many lines")
        // Minimum width clamps instead of breaking.
        #expect(render(state, width: 4, capabilities: TerminalCapabilities()).width == 20)
    }

    @Test("DX-01 dumb terminals get inline composer with identical content")
    func DX_01_capabilityFallback() throws {
        let state = Self.busyState()
        let full = render(state, width: 80, capabilities: TerminalCapabilities())
        let dumb = render(state, width: 80, capabilities: .dumb)
        #expect(full.composerOverlay != nil, "capable terminal overlays the composer")
        #expect(dumb.composerOverlay == nil, "dumb terminal never overlays")
        let dumbText = dumb.lines.flatMap(\.runs).map(\.text).joined()
        #expect(dumbText.contains("draft text here"), "draft content preserved inline")
        let fullText = full.lines.flatMap(\.runs).map(\.text).joined()
            + (full.composerOverlay?.text ?? "")
        #expect(fullText.contains("draft text here"))
    }

    @Test("rendered output escapes untrusted controls")
    func renderEscapesUntrusted() throws {
        var state = UIState()
        (state, _) = reduce(state, .input(.insertText("a\u{1B}[2Jb")))
        (state, _) = reduce(state, .session(.denied(cause: "x\u{07}y")))
        let frame = render(state, width: 80, capabilities: TerminalCapabilities())
        let bytes = frame.lines.flatMap(\.runs).map(\.text).joined() + (frame.composerOverlay?.text ?? "")
        #expect(!bytes.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }),
                "no executable controls in frames (newlines only where layout owns them)")
        #expect(bytes.contains("\\u{1b}"), "ESC renders visibly")
    }

    @Test("wrap never splits inside a grapheme cluster")
    func wrapPreservesClusters() throws {
        var state = UIState()
        // 30 flag emoji (each one cluster, two scalars) at width 40.
        (state, _) = reduce(state, .input(.insertText(String(repeating: "🇺🇸", count: 30))))
        let frame = render(state, width: 40, capabilities: .dumb)
        let inline = frame.lines.last(where: { $0.id == "composer-inline" })
        let text = try #require(inline).runs.map(\.text).joined()
        #expect(text.filter({ $0 == "🇺" }).isEmpty && text.filter({ $0 == "🇸" }).isEmpty,
                "regional indicators must never split")
    }
}
