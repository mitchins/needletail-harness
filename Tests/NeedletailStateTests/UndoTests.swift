import Testing
import NeedletailCore

/// M2-D D2 pure-state tests: change-group recording, undo eligibility
/// preflight, native compensation chains, idempotency, rewind lineage and
/// crash-boundary journal reconciliation — through the real reducer only
/// (no I/O). Filesystem fidelity (hashing, identity, no-follow, modes)
/// belongs to the Runtime UndoFiles tests; the actor loop to UndoActorTests.
struct UndoTests {

    // MARK: - Fixtures

    static func member(
        _ path: String, seed: UInt64, created: Bool = false,
        emptyOriginal: Bool = false, preimage: String? = nil,
        afterHash: String? = nil, beforeHash: String? = nil,
        grantedRoot: String = "/tmp/ws"
    ) -> ChangeGroupMember {
        let before = beforeHash ?? (created ? nil : "before-\(seed)")
        let after = afterHash ?? "after-\(seed)"
        return ChangeGroupMember(
            operationID: OperationID("eff-1/c\(seed)"), callID: "c\(seed)",
            path: path, grantedRoot: grantedRoot,
            created: created, beforeHash: before, afterHash: after,
            deviceBefore: created ? nil : 100 + seed,
            inodeBefore: created ? nil : 200 + seed,
            modeBefore: created ? nil : "644",
            preimageDigest: preimage ?? (created || emptyOriginal ? nil : "before-\(seed)"),
            emptyOriginal: emptyOriginal && !created,
            deviceAfter: 100 + seed, inodeAfter: 300 + seed, modeAfter: "644",
            receiptStatus: "success", receiptSummary: "edited \(path)")
    }

    static func group(_ members: [ChangeGroupMember], id: String = "chg-1", exec: Bool = false) -> ChangeGroup {
        ChangeGroup(
            groupID: id, runID: RunID("run-1"), effectID: EffectID("eff-1"),
            members: members, hadExecProposals: exec, hadReadProposals: false)
    }

    static func observation(
        _ inverseID: String, member: ChangeGroupMember,
        hash: String? = nil, device: UInt64? = nil, inode: UInt64? = nil,
        mode: String? = nil, readable: Bool = true, denyReason: String? = nil
    ) -> UndoFileObservation {
        UndoFileObservation(
            inverseID: inverseID, device: device ?? member.deviceAfter,
            inode: inode ?? member.inodeAfter, size: 12,
            hash: hash ?? member.afterHash, mode: mode ?? member.modeAfter,
            readable: readable, denyReason: denyReason)
    }

    static func needs(_ command: String, _ group: ChangeGroup) -> [UndoValidationNeed] {
        undoInverses(undoCommandID: command, group: group).map {
            UndoValidationNeed(inverseID: $0.inverseID, path: $0.path)
        }
    }

    static func observations(
        _ command: String, _ group: ChangeGroup, mutate: (UndoFileObservation) -> UndoFileObservation = { $0 }
    ) -> [UndoFileObservation] {
        let inverses = undoInverses(undoCommandID: command, group: group)
        return group.members.enumerated().map { (index, member) in
            mutate(Self.observation(inverses[index].inverseID, member: member))
        }
    }

    /// Drives a full validation round: run → validation result with
    /// all-eligible evidence. Returns the post-validation transition
    /// (first intent committed, applyInverse staged).
    static func runToFirstInverse(
        group: ChangeGroup, command: String = "undo-1",
        preimages: [String: Bool]? = nil, ids: inout DeterministicIDSource
    ) throws -> (SessionState, Transition, PendingUndo) {
        var state = try StateFixtures.idle()
        var t = transition(
            state,
            .undoRun(undoCommandID: command, group: group,
                     preimagesAvailable: preimages ?? Self.preimagesAvailable(for: group),
                     atMillis: 1000),
            &ids)
        state = t.state
        #expect(state.phase == .undoing(commandID: command), "run must enter the exclusive phase")
        let pending = try #require(state.pendingUndo, "run must stage pending undo")
        t = transition(
            state,
            .undoValidationResult(
                undoCommandID: command, isPreview: false,
                requested: Self.needs(command, group),
                observations: Self.observations(command, group),
                atMillis: 1001),
            &ids)
        let staged = try #require(t.state.pendingUndo, "validated run keeps pending")
        return (t.state, t, staged)
    }

    static func preimagesAvailable(for group: ChangeGroup) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for member in group.members {
            if let digest = member.preimageDigest {
                out[digest] = true
            }
        }
        return out
    }

    // MARK: - Change-group recording (UNDO-01)

    @Test("UNDO-01: proven native successes record a group; unknowns and non-natives excluded")
    func groupRecordingExcludesUnproven() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d"),
            ToolProposal(callID: "c3", tool: "read", argumentsDigest: "d"),
            ToolProposal(callID: "c4", tool: "exec", argumentsDigest: "d"),
            ToolProposal(callID: "c5", tool: "edit", argumentsDigest: "d"),
        ])
        let outcomes: [String: ToolCallOutcome] = [
            "c1": ToolCallOutcome(callID: "c1", status: "success", summary: "edited a", data: "edited", path: "a.txt", mode: "644", beforeHash: "bh1", afterHash: "ah1", started: true, deviceBefore: 1, inodeBefore: 2, deviceAfter: 1, inodeAfter: 3, grantedRoot: "/tmp/ws"),
            "c2": ToolCallOutcome(callID: "c2", status: "success", summary: "wrote b", data: "written", path: "b.txt", mode: "600", afterHash: "ah2", started: true, deviceAfter: 1, inodeAfter: 4, created: true, grantedRoot: "/tmp/ws"),
            "c3": ToolCallOutcome(callID: "c3", status: "success", summary: "read", data: "body", path: "c.txt", mode: "644", afterHash: "ah3", started: true, deviceAfter: 1, inodeAfter: 5, grantedRoot: "/tmp/ws"),
            "c5": ToolCallOutcome(callID: "c5", status: "conflict", summary: "hash mismatch", data: "", error: "conflict", path: "e.txt", beforeHash: "bh5", started: true, deviceBefore: 1, inodeBefore: 6, deviceAfter: 1, inodeAfter: 6, grantedRoot: "/tmp/ws"),
        ]
        let group = try #require(buildChangeGroup(
            groupID: "chg-9", runID: RunID("run-1"), effectID: EffectID("eff-1"),
            proposals: batch.proposals, outcomes: outcomes,
            doneCallIDs: ["c1", "c2", "c3"]))
        #expect(group.members.count == 2, "only proven edit + create become members")
        #expect(group.members[0].path == "a.txt" && !group.members[0].created)
        #expect(group.members[1].path == "b.txt" && group.members[1].created)
        #expect(group.hadExecProposals, "exec proposals flag the disclaimer")
        #expect(group.hadReadProposals)
        _ = ids
    }

    @Test("UNDO-01: group records commit atomically with batch results")
    func groupCommitsWithBatch() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d")])
        var state = try StateFixtures.idle(permissive: true)
        let run = RunDescriptor(runID: RunID("run-1"), requestID: RequestID("req-1"), revision: Revision(1), startedAtMillis: 1000, sealed: false)
        state = state.replacing(phase: .executing, activeRun: run, liveReservations: [
            EffectReservation(effectID: EffectID("eff-1"), runID: run.runID, requestID: run.requestID, generation: run.revision, revision: run.revision, mutating: true, batch: batch, kind: .executor),
        ], generation: 1)
        let result = ExecutorResult(receipt: ExecutorReceipt(callID: "batch", status: "ok", summary: "batch"), calls: [
            ToolCallOutcome(callID: "c1", status: "success", summary: "edited a.txt", data: "edited", path: "a.txt", mode: "644", beforeHash: "bh", afterHash: "ah", started: true, mutating: true, deviceBefore: 7, inodeBefore: 8, deviceAfter: 7, inodeAfter: 9, grantedRoot: "/tmp/ws"),
        ])
        let out = transition(state, .effectCompleted(effectID: EffectID("eff-1"), runID: run.runID, generation: run.revision, expectedRevision: run.revision, mutating: true, outcome: .perCall(result), atMillis: 1002), &ids)
        let groups = out.records.compactMap { if case .changeGroup(let g) = $0 { return g } else { return nil } }
        #expect(groups.count == 1, "exactly one group commits with the batch")
        #expect(groups[0].members.count == 1 && groups[0].members[0].path == "a.txt")
        #expect(groups[0].members[0].preimageDigest == nil, "scripted outcome carries no preimage artifact")
    }

    @Test("UNDO-01/11: out-of-root and identity-less outcomes never become members")
    func groupRejectsBadMembers() throws {
        let batch = ToolBatch([
            ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d"),
            ToolProposal(callID: "c3", tool: "edit", argumentsDigest: "d"),
        ])
        func outcome(_ call: String, path: String, deviceAfter: UInt64?) -> ToolCallOutcome {
            ToolCallOutcome(callID: call, status: "success", summary: "ok", data: "ok", path: path, mode: "644", beforeHash: "bh", afterHash: "ah", started: true, deviceBefore: 1, inodeBefore: 2, deviceAfter: deviceAfter, inodeAfter: 3, grantedRoot: "/tmp/ws")
        }
        let outcomes = [
            "c1": outcome("c1", path: "../evil.txt", deviceAfter: 1),
            "c2": outcome("c2", path: "ok.txt", deviceAfter: nil),
            "c3": outcome("c3", path: "/abs.txt", deviceAfter: 1),
        ]
        #expect(buildChangeGroup(groupID: "chg-x", runID: RunID("r"), effectID: EffectID("e"), proposals: batch.proposals, outcomes: outcomes, doneCallIDs: ["c1", "c2", "c3"]) == nil, "no member qualifies — no empty group")
    }

    // MARK: - Eligibility preflight (UNDO-02/03/04/10/11)

    @Test("UNDO-02: user edit after the batch refuses the whole group with zero inverses")
    func userEditRefusesGroup() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        var state = try StateFixtures.idle()
        var t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids)
        state = t.state
        // The user changed the file after the batch: hash drift.
        t = transition(state, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: Self.observations("undo-1", group) { obs in
                UndoFileObservation(inverseID: obs.inverseID, device: obs.device, inode: obs.inode, size: obs.size, hash: "user-bytes", mode: obs.mode, readable: true)
            },
            atMillis: 1001), &ids)
        #expect(!t.records.contains(where: { if case .operationIntent = $0 { return true } else { return false } }), "zero inverse intents on conflict")
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }), "zero inverses run on conflict")
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .refused, "conflict is a durable refused disposition")
        #expect(t.state.phase == .idle && t.state.pendingUndo == nil, "phase restored, pending cleared")
        #expect(t.records.contains(where: { if case .transcriptAppended(.workspaceChangeNotice) = $0 { return true } else { return false } }), "refusal still publishes its notice")
    }

    @Test("UNDO-03: created file intact deletes; created file modified refuses")
    func createdFileRules() throws {
        // Intact: removeCreated applies through the full chain.
        var ids = StateFixtures.ids()
        let created = Self.member("new.txt", seed: 2, created: true)
        let group = Self.group([created])
        let (state, first, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        #expect(first.effects.contains(where: {
            if case .applyInverse(_, let inverse) = $0 {
                if case .removeCreated = inverse.kind { return true }
            }
            return false
        }), "create inverse is an exact-identity delete")
        let inverseID = undoInverses(undoCommandID: "undo-1", group: group)[0].inverseID
        let done = transition(state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverseID, outcome: .applied(detail: "removed created file new.txt"), atMillis: 1002), &ids)
        let dispositions = done.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .completed)
        // Modified after creation: conflict refuses.
        var ids2 = StateFixtures.ids()
        var state2 = try StateFixtures.idle()
        var t2 = transition(state2, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: [:], atMillis: 1000), &ids2)
        state2 = t2.state
        t2 = transition(state2, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: Self.observations("undo-1", group) { obs in
                UndoFileObservation(inverseID: obs.inverseID, device: obs.device, inode: obs.inode, size: 99, hash: "changed-after-create", mode: obs.mode, readable: true)
            },
            atMillis: 1001), &ids2)
        let d2 = t2.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(d2.count == 1 && d2[0].outcome == .refused, "modified create refuses — no wrong-file delete")
    }

    @Test("UNDO-04: three-file group with one conflict performs zero inverses")
    func threeFileOneConflict() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([
            Self.member("a.txt", seed: 1),
            Self.member("b.txt", seed: 2),
            Self.member("c.txt", seed: 3),
        ])
        var state = try StateFixtures.idle()
        var t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids)
        state = t.state
        t = transition(state, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: Self.observations("undo-1", group) { obs in
                if obs.inverseID.contains("eff-1/c2") {
                    return UndoFileObservation(inverseID: obs.inverseID, device: obs.device, inode: 999, size: obs.size, hash: obs.hash, mode: obs.mode, readable: true)
                }
                return obs
            },
            atMillis: 1001), &ids)
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }), "one conflict ⇒ zero inverses")
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .refused)
        #expect(dispositions[0].reason.contains("b.txt"), "per-file conflict is operator-visible")
    }

    @Test("UNDO-10: missing preimage fails closed with zero inverses")
    func missingPreimageFailsClosed() throws {
        var ids = StateFixtures.ids()
        var missing = Self.member("a.txt", seed: 1)
        // Strip the preimage: a replace with no proven original.
        missing = ChangeGroupMember(
            operationID: missing.operationID, callID: missing.callID,
            path: missing.path, grantedRoot: missing.grantedRoot,
            created: false, beforeHash: missing.beforeHash, afterHash: missing.afterHash,
            deviceBefore: missing.deviceBefore, inodeBefore: missing.inodeBefore,
            modeBefore: missing.modeBefore, preimageDigest: nil, emptyOriginal: false,
            deviceAfter: missing.deviceAfter, inodeAfter: missing.inodeAfter,
            modeAfter: missing.modeAfter, receiptStatus: missing.receiptStatus,
            receiptSummary: missing.receiptSummary)
        let group = Self.group([missing])
        var state = try StateFixtures.idle()
        var t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: [:], atMillis: 1000), &ids)
        state = t.state
        t = transition(state, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: Self.observations("undo-1", group),
            atMillis: 1001), &ids)
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }))
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .refused)
        #expect(dispositions[0].reason.contains("preimage"), "missing preimage named in the refusal")
    }

    @Test("UNDO-11: symlink, mode and identity drift all refuse without mutation")
    func driftRefuses() throws {
        // Symlink swap: unreadable observation.
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        var state = try StateFixtures.idle()
        var t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids)
        state = t.state
        t = transition(state, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: [UndoFileObservation(inverseID: Self.needs("undo-1", group)[0].inverseID, device: 0, inode: 0, size: -1, hash: "", mode: "", readable: false, denyReason: "symlink encountered (no-follow)")],
            atMillis: 1001), &ids)
        let symRefused = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(symRefused.first?.outcome == .refused)
        // Mode drift with intact hash/identity still refuses.
        var ids2 = StateFixtures.ids()
        var s2 = try StateFixtures.idle()
        var t2 = transition(s2, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids2)
        s2 = t2.state
        t2 = transition(s2, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: Self.observations("undo-1", group) { obs in
                UndoFileObservation(inverseID: obs.inverseID, device: obs.device, inode: obs.inode, size: obs.size, hash: obs.hash, mode: "600", readable: true)
            },
            atMillis: 1001), &ids2)
        let modeRefused = t2.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(modeRefused.first?.outcome == .refused, "mode drift refuses")
    }

    @Test("UNDO-02/11: reverse chain rule — broken same-path linkage refuses the group")
    func brokenChainRefuses() throws {
        var ids = StateFixtures.ids()
        // Two edits to the same path where the later beforeHash does NOT
        // equal the earlier afterHash: not a provable reverse chain.
        let first = Self.member("a.txt", seed: 1, afterHash: "after-1")
        let second = Self.member("a.txt", seed: 2, beforeHash: "unrelated")
        let group = Self.group([first, second])
        #expect(!undoChainLinks(members: group.members))
        let state = try StateFixtures.idle()
        let t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids)
        #expect(!t.effects.contains(where: { if case .validateUndo = $0 { return true } else { return false } }), "broken chain never reaches validation")
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .refused)
    }

    @Test("same-path create+edit refuses the create leg even when hashes link (exact identity)")
    func samePathCreateEditRefuses() throws {
        var ids = StateFixtures.ids()
        // Linked: edit.beforeHash == create.afterHash. The chain rule
        // passes, but the create leg's expected postimage (the created
        // inode) cannot equal the live file (the edit's inode) — exact
        // identity refuses, zero inverses.
        let create = Self.member("a.txt", seed: 1, created: true, afterHash: "H1")
        var edit = Self.member("a.txt", seed: 2, afterHash: "H2", beforeHash: "H1")
        edit = ChangeGroupMember(
            operationID: edit.operationID, callID: edit.callID,
            path: edit.path, grantedRoot: edit.grantedRoot,
            created: false, beforeHash: edit.beforeHash, afterHash: edit.afterHash,
            deviceBefore: edit.deviceBefore, inodeBefore: edit.inodeBefore,
            modeBefore: edit.modeBefore, preimageDigest: "H1", emptyOriginal: false,
            deviceAfter: 101, inodeAfter: 999, modeAfter: edit.modeAfter,
            receiptStatus: edit.receiptStatus, receiptSummary: edit.receiptSummary)
        let group = Self.group([create, edit])
        #expect(undoChainLinks(members: group.members), "hashes link — the structural gate passes")
        var state = try StateFixtures.idle()
        var t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: ["H1": true], atMillis: 1000), &ids)
        state = t.state
        // Both legs observe the ONE live file (the edit postimage): the
        // create leg's recorded postimage (the created inode) no longer
        // exists, so exact identity refuses even though hashes link.
        let live = Self.observations("undo-1", group)[1]
        let createSeesLive = UndoFileObservation(
            inverseID: Self.needs("undo-1", group)[0].inverseID,
            device: live.device, inode: live.inode, size: live.size,
            hash: live.hash, mode: live.mode, readable: true)
        t = transition(state, .undoValidationResult(
            undoCommandID: "undo-1", isPreview: false,
            requested: Self.needs("undo-1", group),
            observations: [createSeesLive, live],
            atMillis: 1001), &ids)
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }), "create-leg identity divergence refuses the group")
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == UndoDispositionOutcome.refused)
        #expect(dispositions[0].reason.contains("identity changed"), "refusal names the identity rule")
    }

    @Test("reverse chain rule — linked same-path edits are eligible")
    func linkedChainEligible() throws {
        let first = Self.member("a.txt", seed: 1, afterHash: "mid")
        let second = Self.member("a.txt", seed: 2, afterHash: "final", beforeHash: "mid")
        #expect(undoChainLinks(members: [first, second]))
        // Reverse application order: the later edit inverts first.
        let inverses = undoInverses(undoCommandID: "undo-1", group: Self.group([first, second]))
        #expect(inverses.count == 2 && inverses[0].path == "a.txt")
    }

    // MARK: - Full compensation chain (UNDO-05 partial, UNDO-09 idempotency)

    @Test("UNDO-05: I/O failure after first applied inverse is partial, never atomic")
    func appliedThenCleanFailureIsPartial() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1), Self.member("b.txt", seed: 2)])
        let (state, first, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        var t = transition(state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[0].inverseID, outcome: .applied(detail: "restored b.txt"), atMillis: 1002), &ids)
        #expect(t.effects.contains(where: {
            if case .applyInverse(_, let inverse) = $0 { return inverse.inverseID == inverses[1].inverseID }
            return false
        }), "chain continues past an applied inverse")
        // Second inverse fails cleanly (applier attests nothing mutated):
        // the chain HALTS and the disposition is partial.
        t = transition(t.state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[1].inverseID, outcome: .failed(error: "tmp create failed", possiblyMutated: false), atMillis: 1003), &ids)
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .partial, "applied + clean failure is partial, never atomic")
        #expect(dispositions[0].fileOutcomes.count == 2)
        #expect(!t.state.queueHeld, "clean failure holds nothing (nothing mutated)")
        #expect(t.state.phase == .idle, "phase restored after disposition")
        _ = first
    }

    @Test("UNDO-05: ambiguous failure holds as unknown with queue barrier")
    func ambiguousFailureHoldsUnknown() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1), Self.member("b.txt", seed: 2)])
        let (state, _, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        var t = transition(state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[0].inverseID, outcome: .applied(detail: "restored b.txt"), atMillis: 1002), &ids)
        // Second inverse: rename succeeded but post-verify failed — unknown.
        t = transition(t.state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[1].inverseID, outcome: .failed(error: "post-commit read failed", possiblyMutated: true), atMillis: 1003), &ids)
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .needsReconciliation)
        #expect(t.state.queueHeld, "unknown inverse holds the queue")
        #expect(t.state.unresolvedOperations.contains(where: { $0.operationID.raw == inverses[1].inverseID && $0.state == .unknown }), "unknown inverse seeds a recovery marker")
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }), "nothing further runs after an unknown")
    }

    @Test("UNDO-09 core: duplicate undo returns the recorded disposition with no second inverse")
    func duplicateUndoIsIdempotent() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        let (oldState, _, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        var t = transition(oldState, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[0].inverseID, outcome: .applied(detail: "restored a.txt"), atMillis: 1002), &ids)
        let first = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(first.count == 1 && first[0].outcome == .completed)
        let state = t.state
        // Duplicate resubmission of the same command: pure answer, no records.
        t = transition(state, .undoRun(undoCommandID: "undo-1", group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 2000), &ids)
        #expect(t.records.isEmpty, "duplicate commits no new records")
        #expect(!t.effects.contains(where: { if case .validateUndo = $0 { return true } else { return false } }), "duplicate stages no validation")
        #expect(!t.effects.contains(where: { if case .applyInverse = $0 { return true } else { return false } }), "duplicate runs no second inverse")
        #expect(t.state.phase == .idle, "duplicate never re-enters the exclusive phase")
    }

    @Test("UNDO-04 partial through the chain: applied then refused is partial")
    func appliedThenRefusedIsPartial() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1), Self.member("b.txt", seed: 2)])
        let (state, _, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        // Inverses run in reverse batch order: b.txt first.
        var t = transition(state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[0].inverseID, outcome: .refused(reason: "b.txt: content changed"), atMillis: 1002), &ids)
        // Chain continues past a refused inverse.
        #expect(t.effects.contains(where: {
            if case .applyInverse(_, let inverse) = $0 { return inverse.inverseID == inverses[1].inverseID }
            return false
        }), "chain continues past a refused inverse")
        t = transition(t.state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[1].inverseID, outcome: .applied(detail: "restored a.txt"), atMillis: 1003), &ids)
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .partial, "refused + applied is partial")
    }

    // MARK: - Quiescence + exclusivity (spec §6 ¶924)

    @Test("quiescence: undo refused with an active run, an approval, or unknown markers")
    func quiescenceRefusals() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        // Active run: use an executing state.
        var executing = try StateFixtures.idle()
        let run = RunDescriptor(runID: RunID("run-9"), requestID: RequestID("req-9"), revision: Revision(1), startedAtMillis: 1, sealed: false)
        executing = executing.replacing(phase: .executing, activeRun: run)
        #expect(!undoQuiescent(executing))
        let refused = transition(executing, .undoRun(undoCommandID: "undo-9", group: group, preimagesAvailable: [:], atMillis: 1), &ids)
        #expect(refused.records.count == 1, "quiescence refusal leaves only its marker")
        #expect(!refused.effects.contains(where: { if case .validateUndo = $0 { return true } else { return false } }))
        // Unresolved markers block even at idle.
        let held = try StateFixtures.idle().replacing(unresolvedOperations: [
            OperationRef(operationID: OperationID("e/c"), callID: "c", state: .unknown, mutating: true),
        ])
        #expect(!undoQuiescent(held))
        // Undoing phase is never quiescent for a second command.
        let undoing = try StateFixtures.idle().replacing(phase: .undoing(commandID: "undo-1"))
        #expect(!undoQuiescent(undoing))
        let second = transition(undoing, .undoRun(undoCommandID: "undo-2", group: group, preimagesAvailable: [:], atMillis: 1), &ids)
        #expect(second.state.phase == .undoing(commandID: "undo-1"), "second command never preempts the first")
    }

    @Test("exclusive phase: dispatch-adjacent work is held off while undo owns the session")
    func undoingHoldsOffDispatch() throws {
        var ids = StateFixtures.ids()
        let undoing = try StateFixtures.idle().replacing(phase: .undoing(commandID: "undo-1"))
        let resume = transition(undoing, .queueResume(atMillis: 1), &ids)
        #expect(resume.state.phase == .undoing(commandID: "undo-1"), "resume refused during undo")
        let queued = transition(undoing, StateFixtures.input("later", id: "cmd-9"), &ids)
        #expect(queued.state.queue.count == 1, "queue accumulation still allowed (undispatchable until undo exits)")
    }

    // MARK: - Preview (dry run)

    @Test("preview performs no mutation and reports eligibility")
    func previewIsDryRun() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        var state = try StateFixtures.idle()
        var t = transition(state, .undoPreview(group: group, preimagesAvailable: Self.preimagesAvailable(for: group), atMillis: 1000), &ids)
        state = t.state
        #expect(state.phase == .idle, "preview never enters the exclusive phase")
        #expect(state.pendingUndo?.isPreview == true)
        #expect(t.effects.contains(where: { if case .validateUndo(let id, let preview, _) = $0 { return id == "preview" && preview } else { return false } }))
        t = transition(state, .undoValidationResult(
            undoCommandID: "preview", isPreview: true,
            requested: Self.needs("preview", group),
            observations: Self.observations("preview", group),
            atMillis: 1001), &ids)
        #expect(t.state.pendingUndo == nil, "preview clears pending")
        #expect(!t.records.contains(where: { if case .undoDisposition = $0 { return true } else { return false } }), "preview records no disposition")
        #expect(!t.records.contains(where: { if case .operationIntent = $0 { return true } else { return false } }), "preview commits no intents")
    }

    // MARK: - Notice (UNDO-06) + STATE-05 ordering

    @Test("UNDO-06: exec disclaimer rides every notice; STATE-05 notice precedes the next request")
    func noticeCarriesDisclaimerAndOrdering() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)], exec: true)
        let (state, _, _) = try Self.runToFirstInverse(group: group, ids: &ids)
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        let t = transition(state, .inverseCompleted(undoCommandID: "undo-1", inverseID: inverses[0].inverseID, outcome: .applied(detail: "restored a.txt"), atMillis: 1002), &ids)
        let notices = t.records.compactMap { record -> WorkspaceChangeNotice? in
            if case .transcriptAppended(.workspaceChangeNotice(let notice)) = record { return notice }
            return nil
        }
        #expect(notices.count == 1)
        #expect(notices[0].hadExecProposals, "exec exclusion is explicit per batch")
        let rendered = renderWorkspaceNotice(notices[0])
        #expect(rendered.contains("shell-produced effects are never ledger-undoable"), "UNDO-06 disclaimer is literal")
        #expect(rendered.contains("undo-1"))
        // STATE-05: the notice commits atomically WITH its disposition, so
        // any later provider request necessarily carries it.
        let indices = t.records.enumerated().compactMap { (index, record) -> (Int, String)? in
            switch record {
            case .undoDisposition: return (index, "disposition")
            case .transcriptAppended(.workspaceChangeNotice): return (index, "notice")
            default: return nil
            }
        }
        #expect(indices.map(\.1) == ["disposition", "notice"] && indices[1].0 == indices[0].0 + 1, "disposition + notice commit adjacently")
        // Projection ordering: the notice renders as model context at its
        // transcript position, never as user text or a tool call.
        let sequenced = t.records.enumerated().map { (index, record) in
            SequencedRecord(sequence: SequenceNumber(UInt64(index)), record: record)
        }
        let messages = try transcriptMessages(sequenced.filter {
            if case .transcriptAppended = $0.record { return true } else { return false }
        })
        #expect(messages.count == 1 && messages[0].role == .assistant, "notice projects as assistant-context, never user/tool")
        #expect(messages[0].text.contains("undo-1"))
    }

    // MARK: - Lineage (UNDO-08)

    @Test("UNDO-08: lineage fork records with boundary checks; parent preserved")
    func lineageForkRecords() throws {
        var ids = StateFixtures.ids()
        var state = try StateFixtures.idle()
        // Advance history so a past boundary exists.
        state = state.replacing(lastSequence: 40)
        let boundary = LineageBoundary(epochID: state.epoch.epochID, throughSequence: 12)
        let t = transition(state, .lineageForkRequest(boundary: boundary, atMillis: 1000), &ids)
        let forks = t.records.compactMap { if case .lineageFork(let fork) = $0 { return fork } else { return nil } }
        #expect(forks.count == 1, "fork commits exactly one lineage record")
        #expect(forks[0].parentEpochID == state.epoch.epochID, "parent conversation preserved by identity")
        #expect(forks[0].boundary == boundary)
        #expect(forks[0].divergenceNote.contains("NOT restored"), "divergence is honest about the worktree")
        #expect(t.records.filter({ if case .transcriptAppended = $0 { return true } else { return false } }).isEmpty, "fork rewrites no history")
        // Future boundary refused.
        let future = transition(state, .lineageForkRequest(boundary: LineageBoundary(epochID: state.epoch.epochID, throughSequence: 41), atMillis: 1001), &ids)
        #expect(!future.records.contains(where: { if case .lineageFork = $0 { return true } else { return false } }), "boundary beyond live history refuses")
        // Cross-epoch boundary refused.
        let cross = transition(state, .lineageForkRequest(boundary: LineageBoundary(epochID: EpochID("epoch-9"), throughSequence: 3), atMillis: 1002), &ids)
        #expect(!cross.records.contains(where: { if case .lineageFork = $0 { return true } else { return false } }), "cross-epoch fork refuses")
    }

    // MARK: - Crash-boundary journal (boundaries 1-7)

    @Test("journal: intent without result is unknown and held (boundary 2)")
    func intentWithoutResultIsUnknown() {
        let inverseID = "undo/undo-1/chg-1/eff-1/c1"
        let intent = OperationRef(operationID: OperationID(inverseID), callID: inverseID, state: .intent, mutating: true)
        let (entries, unknowns) = reconcileUndoJournal([.operationIntent(intent)])
        #expect(entries["undo-1"]?.disposition == nil)
        #expect(unknowns.count == 1 && unknowns[0].operationID.raw == inverseID && unknowns[0].state == .unknown, "intent-only inverse holds as unknown")
    }

    @Test("journal: settled inverses without disposition recover via finalize (boundary 5)")
    func settledWithoutDispositionFinalizes() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1)])
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        // Simulate the durable log: intent + done result, no disposition.
        let intent = OperationRef(operationID: OperationID(inverses[0].inverseID), callID: inverses[0].inverseID, state: .intent, mutating: true)
        let result = OperationRef(operationID: OperationID(inverses[0].inverseID), callID: inverses[0].inverseID, state: .done, mutating: true)
        let (entries, unknowns) = reconcileUndoJournal([
            .operationIntent(intent),
            .operationResult(result, outcome: "applied: restored a.txt"),
        ])
        #expect(unknowns.isEmpty, "settled inverse is not unknown")
        #expect(entries["undo-1"]?.disposition == nil)
        // Driver-stamped recovery commits disposition + notice atomically.
        let state = try StateFixtures.idle()
        let t = transition(state, .undoFinalize(
            undoCommandID: "undo-1", group: group,
            fileOutcomes: [UndoFileOutcome(
                inverseID: inverses[0].inverseID, path: "a.txt",
                result: "applied", detail: "restored a.txt (recovered)")],
            atMillis: 2000), &ids)
        let dispositions = t.records.compactMap { if case .undoDisposition(let d) = $0 { return d } else { return nil } }
        #expect(dispositions.count == 1 && dispositions[0].outcome == .completed, "recovery completes the journal")
        #expect(t.records.contains(where: { if case .transcriptAppended(.workspaceChangeNotice) = $0 { return true } else { return false } }), "recovery publishes the notice before any provider continuation")
        // And a duplicate finalize after recovery answers idempotently.
        let dup = transition(t.state, .undoFinalize(
            undoCommandID: "undo-1", group: group,
            fileOutcomes: [], atMillis: 2001), &ids)
        #expect(dup.records.isEmpty, "finalize after disposition is a pure duplicate answer")
    }

    @Test("journal: partial coverage refuses finalize (missing legs never complete)")
    func finalizeRequiresFullCoverage() throws {
        var ids = StateFixtures.ids()
        let group = Self.group([Self.member("a.txt", seed: 1), Self.member("b.txt", seed: 2)])
        let state = try StateFixtures.idle()
        let t = transition(state, .undoFinalize(
            undoCommandID: "undo-1", group: group,
            fileOutcomes: [UndoFileOutcome(inverseID: "x", path: "a.txt", result: "applied", detail: "half")],
            atMillis: 2000), &ids)
        #expect(!t.records.contains(where: { if case .undoDisposition = $0 { return true } else { return false } }), "partial legs never finalize")
    }

    @Test("journal: duplicate undo after success performs no second mutation (boundary 6)")
    func journalDuplicateHasDisposition() {
        let record = UndoDispositionRecord(
            undoCommandID: "undo-1", groupID: "chg-1", outcome: .completed,
            fileOutcomes: [UndoFileOutcome(inverseID: "i", path: "a.txt", result: "applied", detail: "ok")],
            reason: "done", atMillis: 1)
        let (entries, _) = reconcileUndoJournal([.undoDisposition(record)])
        #expect(entries["undo-1"]?.disposition == record, "recorded disposition answers duplicates")
    }

    // MARK: - Pure helpers

    @Test("undoPathContained rejects escapes, absolutes and empties")
    func pathContainment() {
        #expect(undoPathContained("a.txt"))
        #expect(undoPathContained("dir/sub/file.md"))
        #expect(!undoPathContained(""))
        #expect(!undoPathContained("/abs/path"))
        #expect(!undoPathContained("../evil"))
        #expect(!undoPathContained("a/../../b"))
        #expect(!undoPathContained("a/\0b"))
        #expect(!undoPathContained("a//b"))
    }

    @Test("inverse IDs derive, parse and order in reverse batch order")
    func inverseIdentity() throws {
        let op = OperationID("eff-1/c1")
        let id = undoInverseID(undoCommandID: "undo-3", groupID: "chg-7", operationID: op)
        let parsed = try #require(parseUndoInverseID(id))
        #expect(parsed.command == "undo-3" && parsed.group == "chg-7" && parsed.original == op.raw)
        #expect(parseUndoInverseID("eff-1/c1") == nil, "tool IDs never parse as inverses")
        #expect(parseUndoInverseID("undo//chg-1/op") == nil)
    }

    @Test("undoDispositionOutcome maps settled files to completed/partial/refused/needsReconciliation")
    func dispositionMapping() {
        func outcome(_ results: String...) -> UndoDispositionOutcome {
            undoDispositionOutcome(for: results.map { UndoFileOutcome(inverseID: "i", path: "p", result: $0, detail: "d") })
        }
        #expect(outcome() == .refused, "empty is refused, never completed")
        #expect(outcome("applied") == .completed)
        #expect(outcome("applied", "applied") == .completed)
        #expect(outcome("applied", "refused") == .partial)
        #expect(outcome("applied", "failed") == .partial)
        #expect(outcome("refused", "refused") == .refused)
        #expect(outcome("applied", "unknown") == .needsReconciliation)
    }

    @Test("UNDO-07: change groups reconcile from the log in first-recorded order")
    func groupsReconcileInOrder() {
        let g1 = Self.group([Self.member("a.txt", seed: 1)], id: "chg-1")
        let g2 = Self.group([Self.member("b.txt", seed: 2)], id: "chg-2")
        let groups = reconcileChangeGroups([.changeGroup(g2), .eventAppended(seq: SequenceNumber(3), kind: "x", digest: "y"), .changeGroup(g1), .changeGroup(g1)])
        #expect(groups.map(\.groupID) == ["chg-2", "chg-1"], "first-recorded order, deduplicated")
    }

    @Test("zero-byte originals restore empty without a preimage artifact")
    func zeroByteOriginalEligible() {
        let member = Self.member("empty.txt", seed: 4, emptyOriginal: true, preimage: nil)
        #expect(member.emptyOriginal && member.preimageDigest == nil)
        // Pure preflight: proven-empty originals need no preimage bytes.
        let group = Self.group([member])
        let inverses = undoInverses(undoCommandID: "undo-1", group: group)
        guard case .restore(let digest, _) = inverses[0].kind else {
            Issue.record("empty original must restore, not delete")
            return
        }
        #expect(digest.isEmpty, "empty original carries the empty-preimage marker, not a missing digest")
        let obs = Self.observation(inverses[0].inverseID, member: member)
        #expect(undoPreflight(member: member, observation: obs, preimageAvailable: false) == .eligible)
    }
}
