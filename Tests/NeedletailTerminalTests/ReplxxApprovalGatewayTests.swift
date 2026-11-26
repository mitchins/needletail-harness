import Testing
import Foundation
import NeedletailCore
@testable import NeedletailTerminal

/// C5: approve/deny pass through the shared box; resume-once holds
/// (double resume impossible); cancellation denies (nothing
/// auto-approves, no suspended task leaks).
struct ReplxxApprovalGatewayTests {
    private func request() -> ApprovalRequest {
        ApprovalRequest(requestID: RequestID("r"), runID: RunID("r"), generation: Revision(1),
                        operation: "read files", requiredGrant: "read",
                        protectedPaths: ["/ws"], execIdentities: [])
    }

    @Test("explicit yes approves via the shared box")
    func approve() async {
        let gateway = ReplxxApprovalGateway { _, box in
            box.resume(.approve)
        }
        let decision = await gateway.decide(request())
        #expect(decision == .approve)
    }

    @Test("deny reason passes through; confirm lines fail closed")
    func deny() async {
        let denying = ReplxxApprovalGateway { _, box in
            box.resume(.deny("operator said no"))
        }
        #expect(await denying.decide(request()) == .deny("operator said no"))
        // Empty/EOF-style confirm lines deny at the loop layer.
        #expect(ComposerBridge.interpretConfirmLine(nil) == false)
        #expect(ComposerBridge.interpretConfirmLine("") == false)
        #expect(ComposerBridge.interpretConfirmLine("n") == false)
        #expect(ComposerBridge.interpretConfirmLine("y") == true)
        #expect(ComposerBridge.interpretConfirmLine("YES") == true)
    }

    @Test("cancelled task denies even if the presenter never resumes")
    func cancellationDenies() async {
        let gateway = ReplxxApprovalGateway { _, _ in
            // Never resumes: cancellation must win via the shared box.
        }
        let task = Task { await gateway.decide(request()) }
        task.cancel()
        let decision = await task.value
        #expect(decision == .deny("approval superseded"))
    }

    @Test("resume-once: first resume wins, late resumes are ignored")
    func resumeOnce() async {
        let gateway = ReplxxApprovalGateway { _, box in
            box.resume(.approve)
            box.resume(.deny("late"))
            box.resumeDeny()
        }
        #expect(await gateway.decide(request()) == .approve)
    }

    @Test("stale arm after cancel is detectable (isSettled)")
    func staleDetectable() {
        let box = ContinuationBox()
        #expect(box.isSettled == false)
        box.resumeDeny()
        #expect(box.isSettled == true)
        box.resume(.approve) // ignored noop, never a double-resume crash
        #expect(box.isSettled == true)
    }

    @Test("cancel-before-store resumes the late continuation immediately (no hang)")
    func cancelBeforeStore() async {
        let box = ContinuationBox()
        box.resumeDeny() // onCancel won the race before store()
        let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
            box.store(cont) // must resume at once, never strand
        }
        #expect(decision == .deny("approval superseded"))
    }
}
