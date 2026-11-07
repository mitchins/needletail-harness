import Testing
import Foundation
import NeedletailCore

/// Queue admission/idempotence/edit/withdraw/resume + the honest retention
/// boundary (C2): same commandID replays the same ack while indexed; the
/// 512th+1 admission prunes oldest-first and a pruned retry admits as a NEW
/// entry with a visibly different ack (never silent).
/// Darwin-debug: suite gated (B2 G14-class — the debug runner SIGBUSes
/// on these deep transition chains; Linux-debug + Darwin `-O` green).
#if canImport(Glibc)
struct QueueContractTests {

    private static func busyState(ids: inout DeterministicIDSource) throws -> SessionState {
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        let dispatched = transition(
            admitting,
            .requestDispatched(requestID: admitting.activeRun!.requestID, atMillis: 1001), &ids)
        return dispatched.state
    }

    @Test("CORE-02 queue admission is idempotent per commandID")
    func CORE_02_queueAdmissionIdempotent() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        let first = transition(state, StateFixtures.input("follow", id: "f-1", kind: .followUp), &ids)
        state = first.state
        #expect(state.queue.count == 1)
        let ack1 = try #require(state.admittedCommands[CommandID("f-1")])
        // Lost-ack retry with identical AND different text: same ack, no dup.
        for text in ["follow", "totally different"] {
            let retry = transition(state, StateFixtures.input(text, id: "f-1", kind: .followUp), &ids)
            #expect(retry.state.queue.count == 1, "retry must not insert")
            #expect(retry.state.admittedCommands[CommandID("f-1")] == ack1, "identical ack on retry")
        }
    }

    @Test("CORE-02 queue edits bump revisions; stale bases reject with current")
    func CORE_02_queueEditRevisionGuard() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("v1", id: "e-1"), &ids).state
        let entryID = try #require(state.queue.first?.entryID)
        let edited = transition(state, .queueEdit(entryID: entryID, newText: "v2", baseRevision: 1, atMillis: 1002), &ids)
        #expect(edited.state.queue.first?.revision == 2)
        #expect(edited.state.admittedCommands[CommandID("e-1")]?.revision == 2)
        let stale = transition(edited.state, .queueEdit(entryID: entryID, newText: "v3", baseRevision: 1, atMillis: 1003), &ids)
        #expect(stale.state.queue.first?.text == "v2", "stale edit must not overwrite")
    }

    @Test("CORE-02 queue withdraw tombstones; dispatched entries refuse")
    func CORE_02_queueWithdrawTombstones() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        state = transition(state, StateFixtures.input("bye", id: "w-1"), &ids).state
        let entryID = try #require(state.queue.first?.entryID)
        let withdrawn = transition(state, .queueWithdraw(entryID: entryID, atMillis: 1002), &ids)
        #expect(withdrawn.state.queue.first?.state == .withdrawn)
        // Retry of a withdrawn ID returns the withdrawn ack — never a new entry.
        let retry = transition(withdrawn.state, StateFixtures.input("bye again", id: "w-1"), &ids)
        #expect(retry.state.queue.count == 1, "no resurrection of withdrawn entries")
    }

    @Test("CORE-02 queue resume unholds; resume while busy refuses")
    func CORE_02_queueResumeRules() throws {
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        // Hold via cancel, then resume at a terminal phase.
        let cancelled = transition(state, .cancelRequested(atMillis: 1005), &ids)
        #expect(cancelled.state.queueHeld)
        let interrupted = transition(cancelled.state, .tick(nowMillis: 1005 + cancelGraceMillis), &ids)
        guard case .interrupted = interrupted.state.phase else {
            Issue.record("cancel grace must land interrupted"); return
        }
        let resumed = transition(interrupted.state, .queueResume(atMillis: 2000), &ids)
        #expect(!resumed.state.queueHeld, "explicit resume clears the hold")
        // Resume while busy refuses without side effects.
        let busyResume = transition(state, .queueResume(atMillis: 1006), &ids)
        #expect(busyResume.state.queueHeld == state.queueHeld)
    }

    @Test("CORE-02 retention boundary at full scale stays honest")
    func CORE_02_admittedIndexBoundaryHonest() throws {
        // Full 513-admission scale, pure and fast: withdraw cycles free
        // queue slots while the ack index accumulates, forcing the prune.
        var ids = StateFixtures.ids()
        var state = try Self.busyState(ids: &ids)
        var round = 0
        while state.admittedCommands.count < 512 {
            round += 1
            #expect(round <= 40, "must reach the cap within bounded rounds")
            for i in 1...20 {
                let id = "m-\(round)-\(i)"
                state = transition(state, StateFixtures.input("n", id: id), &ids).state
            }
            for entry in state.queue.filter({ $0.state == .queued }) {
                state = transition(state, .queueWithdraw(entryID: entry.entryID, atMillis: 9000), &ids).state
            }
        }
        #expect(state.admittedCommands.count == 512, "index capped at 512")
        #expect(state.admittedCommands[CommandID("m-1-1")] == nil, "oldest pruned first")
        // Retry of the pruned ID admits as NEW (tombstones don't consume
        // the live cap, so it lands immediately with a fresh sequence).
        state = transition(state, StateFixtures.input("retry", id: "m-1-1"), &ids).state
        let renewed = try #require(state.admittedCommands[CommandID("m-1-1")])
        #expect(renewed.sequence.value > 520, "renewed ack carries a fresh sequence — tellable, never silent")
        #expect(state.admittedCommands.count == 512, "cap holds after renewal")
    }

    @Test("PORT-02 core imports stay effect-free as new files land")
    func PORT_02_coreImportGate() throws {
        var testFile = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { testFile.deleteLastPathComponent() }
        let core = testFile.appendingPathComponent("Sources/NeedletailCore").path
        let forbidden = [
            "AsyncHTTPClient", "OpenAPIRuntime", "Subprocess", "SystemPackage",
            "GRDB", "Crypto", "ArgumentParser",
            "Darwin", "Glibc", "Security", "AppKit", "SwiftUI", "Combine",
        ]
        for file in try FileManager.default.contentsOfDirectory(atPath: core).filter({ $0.hasSuffix(".swift") }) {
            let text = try String(contentsOfFile: core + "/" + file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst(7).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                #expect(!forbidden.contains(module), "\(file): forbidden import '\(module)'")
            }
        }
    }

    @Test("UX-QUEUE-09 queue caps refuse loudly: 21st entry and 64 KiB text")
    func UX_QUEUE_09_capsRefuse() throws {
        var ids = StateFixtures.ids()
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        var state = transition(admitting, .requestDispatched(requestID: admitting.activeRun!.requestID, atMillis: 1001), &ids).state
        // 64 KiB single text refused on the BYTE budget from a nearly
        // empty queue (count cap not involved: only 2 entries present).
        state = transition(state, StateFixtures.input("t-1", id: "c-1", kind: .followUp), &ids).state
        state = transition(state, StateFixtures.input("t-2", id: "c-2", kind: .followUp), &ids).state
        let big = transition(state, StateFixtures.input(String(repeating: "x", count: 65_536), id: "c-big", kind: .followUp), &ids)
        #expect(!big.effects.contains(where: {
            if case .emitUI(let p) = $0 { return p.kind == "admitted" }
            return false
        }), "over-budget text is not admitted")
        #expect(big.state.admittedCommands[CommandID("c-big")] == nil, "no ack for over-budget text")
        // 21st entry refused on the COUNT cap (budget not involved).
        for i in 3...20 {
            state = transition(state, StateFixtures.input("t-\(i)", id: "c-\(i)", kind: .followUp), &ids).state
        }
        #expect(state.queue.count == 20, "twenty queued")
        let refused = transition(state, StateFixtures.input("t-21", id: "c-21", kind: .followUp), &ids)
        #expect(refused.state.queue.count == 20, "21st refused, nothing silently dropped")
        #expect(refused.state.admittedCommands[CommandID("c-21")] == nil, "no ack for the refused entry")
        #expect(refused.effects.contains(where: {
            if case .emitUI(let p) = $0 { return p.kind == "denied" }
            return false
        }), "typed refusal, got: \(refused.effects)")
    }
}
#endif
