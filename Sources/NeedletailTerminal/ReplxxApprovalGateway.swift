import Foundation
import NeedletailCore

/// M4-C interactive approval gateway (adapter tier).
///
/// `TerminalApprovalGateway` reads stdin directly and would steal
/// replxx input — it is NOT used in interactive mode. This gateway is
/// the SOLE decision path there: the actor calls `decide` (awaited in
/// its in-flight task, like every gateway); `decide` suspends on a
/// `CheckedContinuation` owned by a resume-once box and returns the
/// loop's decision. The loop-injected `presenter` renders the
/// validated request and hands the shared box to the runloop, which
/// resumes via the box when the operator's `y/N` line arrives
/// (serialized through replxx — never a second stdin reader). Task
/// cancellation (superseded in-flight), operator decision and loop
/// exit ALL funnel through the same box: exactly one resume wins,
/// never a double-resume crash; a settled box tells the loop the arm
/// is stale so the next line submits normally instead of wedging.
///
/// The actor still grants (reservation from validated
/// `protectedPaths`); this gateway is the decision, never path
/// minting. Sandbox runs keep `SandboxPolicyGateway`; sandbox UI rows
/// stay display-only (the reducer refuses sandbox grants).
public struct ReplxxApprovalGateway: ApprovalGateway, Sendable {
    public var presenter: @Sendable (ApprovalRequest, ContinuationBox) -> Void

    public init(presenter: @escaping @Sendable (ApprovalRequest, ContinuationBox) -> Void) {
        self.presenter = presenter
    }

    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        if Task.isCancelled { return .deny("approval superseded") }
        let box = ContinuationBox()
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                box.store(continuation)
                presenter(request, box)
            }
        } onCancel: {
            box.resumeDeny()
        }
        if Task.isCancelled { return .deny("approval superseded") }
        return decision
    }
}

/// Resume-once continuation box: exactly one resume wins (operator
/// decision or cancellation-deny, whichever first); late resumes are
/// ignored, never a double-resume crash. Shared by the gateway and
/// the runloop so every settle path converges.
public final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?
    private var resumed = false

    public init() {}

    func store(_ continuation: CheckedContinuation<ApprovalDecision, Never>) {
        // Cancel-first ordering: if the box already settled (onCancel
        // won the race before the continuation arrived), resume the
        // newcomer immediately with deny — never strand it, never leak.
        let settled = lock.withLock { () -> Bool in
            if resumed { return true }
            self.continuation = continuation
            return false
        }
        if settled {
            continuation.resume(returning: .deny("approval superseded"))
        }
    }

    /// True once any resume won (late resumes are ignored no-ops).
    public var isSettled: Bool {
        lock.withLock { resumed }
    }

    func resume(_ decision: ApprovalDecision) {
        let next: CheckedContinuation<ApprovalDecision, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            let c = continuation
            continuation = nil
            return c
        }
        next?.resume(returning: decision)
    }

    func resumeDeny() {
        resume(.deny("approval superseded"))
    }
}
