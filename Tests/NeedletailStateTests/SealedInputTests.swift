import Testing
import Foundation
import NeedletailCore

/// POLICY-03 pure core + correction C1: sealed restrictions bind
/// CAPABILITIES and ACTIONS, not prose. Harmless textual mentions of tool
/// calls or absolute paths still admit as text; only ACTIONABLE
/// invocations (whole-message tool JSON, explicit absolute-path
/// directives) deny. Forbidden: workspace reads on denial paths (asserted
/// in the actor suite — the pure function performs no I/O by construction).
struct SealedInputTests {

    @Test("POLICY-03 whole-message tool JSON denies as an action")
    func POLICY_03_wholeMessageToolJSONDenied() throws {
        for shape in [
            #"{"tool":"read","arguments":{"path":"/x"}}"#,
            #"{"tool": "exec", "arguments": {"argv": ["ls"]}}"#,
            "  \n\t" + #"{"tool":"write","arguments":{}}"# + "\n",
        ] {
            guard case .deniedToolShape = validateSealedInput(shape) else {
                Issue.record("actionable tool JSON must deny: \(shape)"); return
            }
        }
    }

    @Test("POLICY-03 explicit absolute-path directives deny")
    func POLICY_03_absolutePathDirectivesDenied() throws {
        for text in [
            "/read /etc/shadow",
            "please\n/exec /bin/ls -la",
            "@/etc/passwd",
            "/WRITE /tmp/x",
        ] {
            let admission = validateSealedInput(text)
            guard case .deniedPathScope = admission else {
                Issue.record("absolute-path directive must deny: \(text)"); return
            }
        }
    }

    @Test("POLICY-03 harmless mentions still admit as text")
    func POLICY_03_mentionsAdmit() throws {
        // Correction C1: these are PROSE about tools/paths, not actions.
        for text in [
            #"see {"tool":"read"} for the schema"#, // inline mention, not the whole message
            "the file /tmp is full, retry later", // path mention without a directive verb
            "run the tests when ready", // "run" without an absolute path
            "contact ops@example.com for access", // @-mention, not a path
            "@relative/path is fine", // relative @-reference, not absolute
            #"["tool","list"]"#, // an array, not a tool-call object
            #"{"tool":42}"#, // "tool" is not a string — not an invocation shape
            "plain task text with no directives at all",
        ] {
            guard case .admittedText(let kept) = validateSealedInput(text) else {
                Issue.record("harmless mention must admit: \(text)"); return
            }
            #expect(kept == text, "admitted text passes through byte-identical")
        }
    }
}
