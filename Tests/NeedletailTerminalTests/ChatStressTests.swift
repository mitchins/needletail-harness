import Testing
import Foundation
import NeedletailCore
import NeedletailPresentation
@testable import NeedletailTerminal
@testable import NeedletailLineEditor

/// M4-D D4.1/D4.4 concurrent output-owner stress + boundedness and
/// seeded submission fuzz. Deterministic: fixed seeds, barrier joins
/// (`flush`/`close`, task-group joins, scripted input) — no timing
/// assumptions. Unit quota/stale/priority semantics live in
/// `TerminalOutputOwnerTests`; this suite proves the SINGLE-OWNER
/// invariant and exact admission accounting hold under concurrency.
@Suite(.serialized)
struct ChatStressTests {
    private func ownerCaps() -> TerminalCaps {
        TerminalCaps(color: false, cursorAddressing: false, width: 80)
    }

    private static func emptySnapshot() -> QueueSyncSnapshot {
        QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                          heldReason: nil, pendingApproval: nil,
                          admittedCommandIDs: [], liveEpoch: EpochID("e"))
    }

    @Test("D4.1 owner stress: concurrent control storm writes every line exactly once, stale generation drops")
    func concurrentControlStormExact() async {
        let written = LockedBox()
        let owner = TerminalOutputOwner(caps: ownerCaps(), writer: { written.append($0) })
        let gen = owner.currentGeneration
        // 8 concurrent writers × 50 control lines. The control lane
        // never drops, so the cumulative count is exact regardless of
        // writer-thread interleaving — this is the single-owner proof.
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<50 {
                        owner.emitText("cstorm-\(t)-\(String(format: "%02d", i))", generation: gen, lane: .control)
                    }
                }
            }
        }
        owner.flush()
        // Stale-generation emit after invalidate: reported dropped,
        // writes nothing (cancellation/supersede suppression).
        owner.invalidate()
        #expect(owner.currentGeneration == gen + 1, "invalidate must bump exactly once")
        let stale = owner.emitText("cstorm-stale", generation: gen, lane: .control)
        #expect(stale.droppedStale, "old-generation emit must report droppedStale")
        owner.close()
        let out = written.joined()
        for t in 0..<8 {
            for i in 0..<50 {
                let marker = "cstorm-\(t)-\(String(format: "%02d", i))"
                let hits = out.components(separatedBy: marker).count - 1
                #expect(hits == 1, "\(marker) written \(hits)x, expected exactly once")
            }
        }
        #expect(!out.contains("cstorm-stale"), "stale line must never reach the writer")
    }

    @Test("D4.1 droppable quota accounting is exact under a gated writer with concurrent producers")
    func droppableQuotaGatedWriter() async {
        let written = LockedBox()
        // The writer gate stays closed while two tasks enqueue 300
        // droppable lines each. Writer-thread drain timing decides HOW
        // MANY truncate, but every enqueued line is either written or
        // reported truncated exactly once — the accounting below is
        // exact under any interleaving.
        let gate = LockedGate()
        let owner = TerminalOutputOwner(caps: ownerCaps(), writer: {
            gate.wait()
            written.append($0)
        })
        let gen = owner.currentGeneration
        let truncatedBox = LockedValue(0)
        let trimmingEmitsBox = LockedValue(0)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<2 {
                group.addTask {
                    for i in 0..<300 {
                        let r = owner.emitText("dstorm-\(t)-\(String(format: "%04d", i))", generation: gen)
                        truncatedBox.mutate {
                            $0 += r.truncated
                            if r.truncated > 0 { trimmingEmitsBox.mutate { $0 += 1 } }
                        }
                    }
                }
            }
        }
        gate.release()
        owner.flush()
        owner.close()
        let truncatedTotal = truncatedBox.get()
        // Every trimming emit inserts one quota marker (which later
        // trims may themselves drop): markersInserted is exact, and
        // markersWritten is counted in the drained output, so marker
        // drops are exact too — the accounting below closes exactly.
        let markersInserted = trimmingEmitsBox.get()
        let out = written.joined()
        let markersWritten = out.components(separatedBy: "…[output truncated]").count - 1
        #expect(truncatedTotal > 0, "600 rapid enqueues against a gated writer must engage the quota")
        #expect(markersWritten > 0, "quota marker must reach the writer")
        var distinctWritten = 0
        for t in 0..<2 {
            for i in 0..<300 {
                let marker = "dstorm-\(t)-\(String(format: "%04d", i))"
                let hits = out.components(separatedBy: marker).count - 1
                #expect(hits <= 1, "\(marker) written \(hits)x — concurrent emit must never duplicate")
                if hits == 1 { distinctWritten += 1 }
            }
        }
        let markerDrops = markersInserted - markersWritten
        #expect(distinctWritten + truncatedTotal == 600 + markerDrops,
            "exact accounting: written(\(distinctWritten)) + truncated(\(truncatedTotal)) == enqueued(600) + markerDrops(\(markerDrops))")
    }

    @Test("D4.1 loop storm: 64 concurrent submissions admit 64 distinct turns, none lost, none doubled")
    func concurrentSubmitsDistinct() async throws {
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(caps: ownerCaps(), writer: { written.append($0) })
        let counter = LockedValue(0)
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { ChatStressTests.emptySnapshot() },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: {
                var id = 0
                counter.mutate { $0 += 1; id = $0 }
                return CommandID("storm-\(id)")
            })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        let runTask = Task { await loop.run(scriptedInput: []) }
        // Readiness: the initial frame renders before the inbox drains.
        let readyDeadline = Date().addingTimeInterval(5)
        while !written.joined().contains("idle"), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard written.joined().contains("idle") else {
            Issue.record("loop never rendered initial frame")
            loop.post(.inputLine(nil))
            await runTask.value
            return
        }
        // 64 submissions race into the thread-safe inbox from 64
        // tasks; the serialized main task admits each exactly once.
        // Keyboard repeat is N Enters = N submissions (each explicit);
        // a single event can never double-admit (one inbox entry).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask { loop.post(.inputLine("storm text \(i)")) }
            }
        }
        loop.post(.inputLine(nil))
        await runTask.value
        let fx = await effects.all()
        #expect(fx.count == 64, "expected 64 effect batches, got \(fx.count)")
        var ids: [CommandID] = []
        for batch in fx {
            for effect in batch {
                if case .submit(let input) = effect { ids.append(input.commandID) }
                if case .queue(let input, _) = effect { ids.append(input.commandID) }
            }
        }
        #expect(ids.count == 64, "every submission must dispatch exactly one admission, got \(ids.count)")
        #expect(Set(ids).count == 64, "command IDs must be distinct per submission event")
        owner.close()
    }

    @Test("D4.1 seeded submission fuzz: fixed 200-event interleaving dispatches exactly once per line, IDs distinct")
    func seededSubmissionFuzz() async throws {
        // Mulberry-style LCG, fixed seed: the interleaving is frozen,
        // so this is a regression pin, not a random walk.
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: UInt64) -> UInt64 {
            rng ^= rng >> 30; rng &*= 0xBF58476D1CE4E5B9
            rng ^= rng >> 27; rng &*= 0x94D049BB133111EB
            rng ^= rng >> 31
            return rng % bound
        }
        let verbs = ["queue", "cancel", "keys", "diff", "compact", "nope", "undo", "preview @f"] // no steer: a steer IS a submission
        var script: [String?] = []
        var plainCount = 0
        for i in 0..<200 {
            switch next(10) {
            case 0, 1, 2, 3, 4, 5:
                script.append("fuzz line \(i)")
                plainCount += 1
            case 6, 7:
                script.append("/" + verbs[Int(next(UInt64(verbs.count)))])
            case 8:
                script.append("") // empty Enter: ignored, never dispatches
            default:
                script.append("fuzz line \(i) suffix")
                plainCount += 1
            }
        }
        script.append(nil)
        let written = LockedBox()
        let effects = LockedEffects()
        guard let editor = LineEditorSession() else { Issue.record("replxx_init failed headless"); return }
        let owner = TerminalOutputOwner(caps: ownerCaps(), writer: { written.append($0) })
        let counter = LockedValue(0)
        let config = ChatLoop.Config(
            caps: ownerCaps(), sessionID: "sess",
            snapshotProvider: { ChatStressTests.emptySnapshot() },
            onEffects: { fx in await effects.append(fx) },
            mintCommandID: {
                var id = 0
                counter.mutate { $0 += 1; id = $0 }
                return CommandID("fuzz-\(id)")
            })
        let loop = ChatLoop(config: config, lineEditor: editor, owner: owner)
        await loop.run(scriptedInput: script)
        let fx = await effects.all()
        let nonEmpty = script.compactMap { $0 }.filter { !$0.isEmpty }.count
        #expect(fx.count == nonEmpty, "one effect batch per non-empty line: \(fx.count) vs \(nonEmpty)")
        var submits = 0
        var ids: [CommandID] = []
        for batch in fx {
            for effect in batch {
                switch effect {
                case .submit(let input):
                    submits += 1
                    ids.append(input.commandID)
                case .queue(let input, _):
                    submits += 1
                    ids.append(input.commandID)
                default: break
                }
            }
        }
        #expect(submits == plainCount, "every plain line dispatches exactly one admission: \(submits) vs \(plainCount)")
        #expect(Set(ids).count == ids.count, "fuzzed command IDs must all be distinct")
        owner.close()
    }
}

/// Test-local writer gate (blocks the owner writer thread until opened).
private final class LockedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func wait() {
        while true {
            let isOpen = lock.withLock { open }
            if isOpen { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    func release() { lock.withLock { open = true } }
}
