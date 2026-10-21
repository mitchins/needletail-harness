import Testing
import Foundation
import NeedletailCore
import NeedletailProviders

/// M1-D scripted backend rows (D3): FIFO exact matching on VERBATIM
/// arguments (never digests), capability denial before matching, honest
/// exhaustion/mismatch errors. No sockets, no filesystem.
struct BackendTests {

    private static func backend(
        _ entries: [(tool: String, arguments: String, result: String)] = [("read", "{\"path\":\"f\"}", "file-bytes")],
        caps: ToolCapabilities = .allAllowed
    ) -> ScriptedToolBackend {
        ScriptedToolBackend(
            script: entries.map { ScriptedToolBackend.Entry(tool: $0.tool, arguments: $0.arguments, result: $0.result) },
            caps: caps)
    }

    private static func reservation(batch: ToolBatch) -> EffectReservation {
        EffectReservation(
            effectID: EffectID("eff-b"), runID: RunID("run-b"), requestID: RequestID("req-b"),
            generation: Revision(1), revision: Revision(1), mutating: false, batch: batch, kind: .executor)
    }

    private static func batch(_ proposals: (String, String, String)...) -> ToolBatch {
        ToolBatch(proposals.map { ToolProposal(callID: $0.0, tool: $0.1, argumentsDigest: "d", arguments: $0.2) })
    }

    @Test("WIRE-05 exact verbatim match executes; digest never consulted")
    func exactMatchExecutes() async throws {
        let backend = Self.backend([
            ("read", "{\"path\":\"f\"}", "file-bytes"),
            ("read", "{\"a\":1,\"b\":2}", "second"),
        ])
        let first = try await backend.execute(batch:
            Self.batch(("c1", "read", "{\"path\":\"f\"}")),
            reservation: Self.reservation(batch: Self.batch(("c1", "read", "{\"path\":\"f\"}"))))
        #expect(first.receipt.summary == "file-bytes")
        #expect(first.receipt.callID == "c1", "receipt pairs to the call")
        // Reordered keys match by CONTENT (JSON semantics — still exact,
        // as the mismatch test proves for changed values).
        let second = try await backend.execute(batch:
            Self.batch(("c2", "read", "{\"b\":2,\"a\":1}")),
            reservation: Self.reservation(batch: Self.batch(("c2", "read", "{\"b\":2,\"a\":1}"))))
        #expect(second.receipt.summary == "second")
    }

    @Test("WIRE-05 changed value mismatches honestly")
    func mismatchHonest() async throws {
        let backend = Self.backend()
        do {
            _ = try await backend.execute(batch:
                Self.batch(("c1", "read", "{\"path\":\"OTHER\"}")),
                reservation: Self.reservation(batch: Self.batch(("c1", "read", "{\"path\":\"OTHER\"}"))))
            Issue.record("mismatch must fail")
        } catch let error as ScriptedBackendError {
            #expect(error == .scriptMismatch(expected: "read {\"path\":\"f\"}", got: "read {\"path\":\"OTHER\"}"), "typed: \(error)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }

    @Test("WIRE-05 capability denial precedes matching and never executes")
    func denialFirst() async throws {
        let backend = Self.backend(caps: .allDenied)
        do {
            _ = try await backend.execute(batch:
                Self.batch(("c1", "read", "{\"path\":\"f\"}")),
                reservation: Self.reservation(batch: Self.batch(("c1", "read", "{\"path\":\"f\"}"))))
            Issue.record("denied tool must refuse")
        } catch let error as ScriptedBackendError {
            #expect(error == .capabilityDenied(tool: "read"), "typed: \(error)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }

    @Test("WIRE-05 exhausted script fails honest with the expectation shown")
    func exhaustionHonest() async throws {
        let backend = Self.backend()
        _ = try await backend.execute(batch:
            Self.batch(("c1", "read", "{\"path\":\"f\"}")),
            reservation: Self.reservation(batch: Self.batch(("c1", "read", "{\"path\":\"f\"}"))))
        do {
            _ = try await backend.execute(batch:
                Self.batch(("c2", "read", "{\"path\":\"f\"}")),
                reservation: Self.reservation(batch: Self.batch(("c2", "read", "{\"path\":\"f\"}"))))
            Issue.record("exhausted script must fail")
        } catch let error as ScriptedBackendError {
            #expect(error == .scriptExhausted, "typed: \(error)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }
}
