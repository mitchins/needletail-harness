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
        } catch let error as ToolFailure {
            #expect(error == .preDispatch(status: "denied", summary: "capabilityDenied: read"), "typed: \(error)")
            #expect(backend.remaining == 1, "denied tool must not consume script")
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

    @Test("B0 ScriptedToolBackend success→failure→unstarted preserves earlier success")
    func b0SuccessFailureUnstarted() async throws {
        let b = Self.backend([("read","{\"path\":\"a\"}","ok"), ("edit","{\"path\":\"b\"}","tool-failure: bad")])
        let batch = Self.batch(("c1","read","{\"path\":\"a\"}"), ("c2","edit","{\"path\":\"b\"}"), ("c3","edit","{\"path\":\"c\"}"))
        let result = try await b.execute(batch: batch, reservation: Self.reservation(batch: batch))
        #expect(result.calls.count == 3)
        #expect(result.calls[0].status == "success" && result.calls[0].callID == "c1")
        #expect(result.calls[1].status == "failed")
        #expect(result.calls[2].status == "cancelled" && result.calls[2].started == false, "third must be unstarted after halt")
        #expect(result.calls[0].data == "ok", "earlier success preserved")
        #expect(b.remaining == 0)
    }

    @Test("B0 ScriptedToolBackend success→exhaustion→unstarted")
    func b0SuccessExhaustionUnstarted() async throws {
        let b = Self.backend([("read","{\"path\":\"a\"}","ok")])
        let batch = Self.batch(("c1","read","{\"path\":\"a\"}"), ("c2","edit","{\"path\":\"b\"}"), ("c3","edit","{\"path\":\"c\"}"))
        let result = try await b.execute(batch: batch, reservation: Self.reservation(batch: batch))
        #expect(result.calls[0].status == "success")
        #expect(result.calls[1].status == "failed" && result.calls[1].started == true)
        #expect(result.calls[2].status == "cancelled" && result.calls[2].started == false)
        #expect(result.calls[0].data == "ok")
    }

    @Test("B0 ScriptedToolBackend success→mismatch→unstarted")
    func b0SuccessMismatchUnstarted() async throws {
        let b = Self.backend([("read","{\"path\":\"a\"}","ok"), ("edit","{\"path\":\"WRONG\"}","bad")])
        let batch = Self.batch(("c1","read","{\"path\":\"a\"}"), ("c2","edit","{\"path\":\"b\"}"), ("c3","edit","{\"path\":\"c\"}"))
        let result = try await b.execute(batch: batch, reservation: Self.reservation(batch: batch))
        #expect(result.calls[0].status == "success")
        #expect(result.calls[1].status == "failed")
        #expect(result.calls[2].status == "cancelled" && result.calls[2].started == false)
    }

    @Test("B0 ScriptedToolBackend pre-dispatch denial consumes no script")
    func b0PreDispatchDenialNoConsumption() async throws {
        let b = Self.backend([("read","{\"path\":\"a\"}","ok")], caps: .allDenied)
        let before = b.remaining
        do {
            _ = try await b.execute(batch: Self.batch(("c1","read","{\"path\":\"a\"}")), reservation: Self.reservation(batch: Self.batch(("c1","read","{\"path\":\"a\"}"))))
            Issue.record("should throw")
        } catch let e as ToolFailure {
            #expect(e == .preDispatch(status: "denied", summary: "capabilityDenied: read"))
        }
        #expect(b.remaining == before, "denied must not consume script")
    }
}
