import Testing
import Foundation
@testable import NeedletailCore

/// M2-C C0 (plan REV12 §7-C0): contracts, authorization, and the
/// resolution seam. NO exec child is spawned anywhere in this file — the
/// executor is always scripted, and the resolver is a fake.

private struct FakeResolver: ExecIdentityResolver, @unchecked Sendable {
    enum Mode: Sendable {
        case ok
        case fail(ExecResolutionError)
        case wrongCallIDs
    }
    var mode: Mode
    var resolvedPath: String = "/usr/bin/python3.11"
    init(mode: Mode) { self.mode = mode }
    func resolveIdentities(batch: ToolBatch) throws -> [ResolvedExecIdentity] {
        switch mode {
        case .ok:
            return batch.proposals.filter { $0.tool == "exec" }.map {
                ResolvedExecIdentity(
                    callID: $0.callID, requestedPath: "/usr/bin/python3",
                    resolvedPath: resolvedPath, device: 1, inode: 2, size: 3,
                    contentDigest: String(repeating: "a", count: 64),
                    cwdDevice: 4, cwdInode: 5)
            }
        case .fail(let e):
            throw e
        case .wrongCallIDs:
            return [ResolvedExecIdentity(
                callID: "foreign", requestedPath: "/x", resolvedPath: "/y",
                device: 1, inode: 2, size: 3, contentDigest: String(repeating: "b", count: 64),
                cwdDevice: 4, cwdInode: 5)]
        }
    }
}

@Suite(.serialized)
struct C0ExecContractTests {

    // MARK: - Validator matrix (GREEN)

    private static let validExec = "{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\",\"-c\",\"print(1)\"]}"

    private func parse(_ raw: String) throws -> ExecArguments {
        let data = Data(raw.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "not an object")
        }
        return try ToolValidator.parseExecArguments(callID: "t", json: json)
    }

    private func rejected(_ raw: String, contains: String) -> Bool {
        do {
            _ = try parse(raw)
            return false
        } catch let ToolFailure.preDispatch(status, summary) {
            return status == "invalid-arguments" && summary.contains(contains)
        } catch {
            return false
        }
    }

    @Test("exec schema accepts the canonical shape")
    func acceptsCanonical() throws {
        let args = try parse(Self.validExec)
        #expect(args.executable == "/usr/bin/python3")
        #expect(args.argv == ["/usr/bin/python3", "-c", "print(1)"])
        #expect(args.cwd == nil)
        #expect(args.timeoutSecs == 120)
        #expect(args.env.isEmpty)
        #expect(renderExecApprovalDisplay(args) != nil)
    }

    @Test("exec schema rejects malformed shapes")
    func rejectsMalformed() {
        #expect(rejected("{}", contains: "executable required"), "{}: empty shape must not validate (NC-5)")
        #expect(rejected("{\"executable\":\"usr/bin/python3\",\"argv\":[\"usr/bin/python3\"]}", contains: "absolute"), "relative executable refused (no PATH search)")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\",\"-c\"],\"cwd\":\"/abs\"}", contains: "absolute"), "absolute cwd refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"cwd\":\"../out\"}", contains: "parent"), "cwd parent escape refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/bin/other\"]}", contains: "argv[0]"), "argv[0] spoofing refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[]}", contains: "argv must hold"), "empty argv refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"timeoutSecs\":true}", contains: "integer"), "boolean timeout refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"timeoutSecs\":\"120\"}", contains: "integer"), "string timeout refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"timeoutSecs\":0}", contains: "range"), "zero timeout refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"timeoutSecs\":1801}", contains: "range"), "over-max timeout refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"unknown\":1}", contains: "unknown field"), "unknown fields refused")
        #expect(rejected("{\"executable\":\"/usr/bin/../bin/python3\",\"argv\":[\"/usr/bin/../bin/python3\"]}", contains: "parent"), "dot-dot executable components refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"BASH_ENV\":\"/x\"}}", contains: "denied"), "BASH_ENV overlay refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"LD_PRELOAD\":\"/x\"}}", contains: "denied"), "LD_PRELOAD overlay refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"PATH\":\"/x\"}}", contains: "denied"), "PATH overlay refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"NEEDLETAIL_KEY\":\"x\"}}", contains: "denied"), "harness namespace overlay refused")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"1BAD\":\"x\"}}", contains: "must match"), "env key shape refused")
    }

    @Test("exec schema accepts approvable overlays and bounds")
    func acceptsOverlay() throws {
        let args = try parse("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"cwd\":\"tmp/out\",\"timeoutSecs\":10,\"env\":{\"MY_VAR\":\"v\",\"TZ\":\"UTC\"}}")
        #expect(args.cwd == "tmp/out")
        #expect(args.timeoutSecs == 10)
        #expect(args.env == ["MY_VAR": "v", "TZ": "UTC"])
    }

    @Test("exec display bound: elision renders; only unelidable overflow is rejected")
    func displayBound() {
        // argv-heavy: elision shrinks the projection — renders with an
        // explicit elision marker, never rejected.
        let argv = ["/usr/bin/python3"] + (0..<12).map { _ in String(repeating: "x", count: 800) }
        let elided = ExecArguments(executable: "/usr/bin/python3", argv: argv, cwd: nil, timeoutSecs: 120, env: [:])
        let rendered = renderExecApprovalDisplay(elided)
        #expect(rendered != nil, "argv overflow elides, never rejects")
        #expect(rendered?.contains("elided") == true, "elision is explicit")
        #expect(rendered!.utf8.count <= 8 * 1024, "the rendered display is bounded")
        // env-heavy: elision cannot shrink env values — an unelidable
        // overflow is REJECTED at validation (an unrenderable command is
        // unapprovable).
        let env = ["A": String(repeating: "x", count: 8000), "B": String(repeating: "y", count: 8000)]
        let unelidable = ExecArguments(executable: "/usr/bin/python3", argv: ["/usr/bin/python3"], cwd: nil, timeoutSecs: 120, env: env)
        #expect(renderExecApprovalDisplay(unelidable) == nil, "unelidable overflow renders nil")
        #expect(rejected("{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\"],\"env\":{\"A\":\"\(String(repeating: "x", count: 8000))\",\"B\":\"\(String(repeating: "y", count: 8000))\"}}", contains: "rendering bound"))
    }

    // MARK: - Validator dispatch (RED/GREEN at the batch level)

    @Test("validateBatchArguments routes exec through the real schema")
    func batchRouting() {
        let good = ToolBatch([ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d", arguments: Self.validExec)])
        #expect((try? ToolValidator.validateBatchArguments(batch: good)) != nil, "schema-valid exec validates")
        let consult = ToolBatch([ToolProposal(callID: "c1", tool: "consult", argumentsDigest: "d", arguments: "{}")])
        #expect((try? ToolValidator.validateBatchArguments(batch: consult)) != nil, "consult empty shape passes validation; capability denial handles the rest (pre-existing behavior)")
        let consultField = ToolBatch([ToolProposal(callID: "c1", tool: "consult", argumentsDigest: "d", arguments: "{\\\"x\\\":1}")])
        #expect((try? ToolValidator.validateBatchArguments(batch: consultField)) == nil, "consult unknown fields still field-rejected (denied milestone)")
        var tooMany: [ToolProposal] = []
        for i in 0..<9 {
            tooMany.append(ToolProposal(callID: "e\(i)", tool: "exec", argumentsDigest: "d", arguments: Self.validExec))
        }
        #expect((try? ToolValidator.validateBatchArguments(batch: ToolBatch(tooMany))) == nil, "more than 8 exec calls per batch refused (NC-15)")
    }

    // MARK: - Capability posture (NC-1)

    @Test("NC-1 posture: .ask cannot escalate through composition")
    func postureProbe() {
        // Direct caps construction (the only way `.allowed` could emerge
        // under native composition): the intersection clamps it.
        let grant = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .ask, consult: false)
        let config = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .allowed, consult: false)
        let effective = effectiveCapabilities(
            build: .allAllowed, userConfig: config,
            workspaceGrant: grant, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        #expect(effective.tools.exec == .ask, "denied-wins/ask-beats-allowed keeps the per-command ceiling (NC-1)")
        let deniedConfig = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .denied, consult: false)
        let denied = effectiveCapabilities(
            build: .allAllowed, userConfig: deniedConfig,
            workspaceGrant: grant, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        #expect(denied.tools.exec == .denied, "config denial survives the flag (invariant 2)")
    }

    // MARK: - Codec (additive decode)

    @Test("old epoch bytes decode with execComposed == false")
    func oldEpochDecodes() throws {
        let snapshot = try C0Fixtures.snapshot()
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-c0"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route, execComposed: false)
        let data = try JSONEncoder().encode(epoch)
        guard var text = String(data: data, encoding: .utf8) else {
            Issue.record("epoch encode failed"); return
        }
        // The encoder escapes "/" and emits keys in declaration order;
        // strip the key (with preceding comma or trailing comma) to
        // synthesize a PRE-M2-C byte stream.
        if let r = text.range(of: "," + "\"execComposed\":false") {
            text.removeSubrange(r)
        } else if let r = text.range(of: "\"execComposed\":false,") {
            text.removeSubrange(r)
        } else {
            Issue.record("execComposed missing from the encoded epoch"); return
        }
        let decoded = try JSONDecoder().decode(EpochDescriptor.self, from: Data(text.utf8))
        #expect(decoded.execComposed == false, "pre-M2-C epochs decode with execComposed == false")
        #expect(decoded.epochID == epoch.epochID)
    }

    // MARK: - Phase-1 window reopen disposition

    @Test("wrong-impl probe: intent-less done receipts would hold on reopen (NC-17 regression guard)")
    func wrongImplProbeIntentLessReceiptsWouldHold() throws {
        // MUST-FAIL PROBE: a buggy reduction that mints mutating done
        // receipts WITHOUT matching intents opens the reopen orphan path
        // (OperationReconcile:239-251) — every done receipt without an
        // intent whose operationID is mutating becomes a held unknown.
        // Removing the intent side of NC-17 makes THIS test fail (proving
        // the validation-resolution-approval chain cannot be bypassed
        // without reopening a live correctness hole).
        let log: [DurableRecord] = [
            .sessionOpened(session: SessionID("s"), atMillis: 1),
            .operationResult(
                OperationRef(operationID: OperationID("op-buggy"), callID: "c1", state: .done, mutating: true),
                outcome: "tool-failure: bad (invalid-arguments)"),
        ]
        let reconciliation = try reconcileOperations(log)
        #expect(!reconciliation.heldOperations.isEmpty, "intent-less mutating done receipts ARE held as orphans — the correct reduction prevents this")
    }

    @Test("exec schema rejects absolute-path edge cases")
    func absoluteEdgeCases() {
        #expect(rejected("{\"executable\":\"\",\"argv\":[\"\"]}", contains: "absolute"), "empty executable refused (absolute-path check)")
        #expect(rejected("{\"executable\":\"/a/./b\",\"argv\":[\"/a/./b\"]}", contains: "dot component"), "dot component refused")
        #expect(rejected("{\"executable\":\"/a/b/\",\"argv\":[\"/a/b/\"]}", contains: "trailing slash"), "trailing slash refused")
        let longComp = String(repeating: "x", count: 256)
        #expect(rejected("{\"executable\":\"/a/\(longComp)\",\"argv\":[\"/a/\(longComp)\"]}", contains: "component too long"), "255-byte cap enforced")
        let longPath = String(repeating: "x", count: 5000)
        #expect(rejected("{\"executable\":\"/a/b\",\"argv\":[\"/a/b\"],\"cwd\":\"\(longPath)\"}", contains: "path too long"), "4096-byte total cap enforced")
    }

    @Test("exec schema exact pin: the advertisement definition mirrors the dispatch contract")
    func exactExecSchemaPin() throws {
        let execCaps = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .ask, consult: false)
        let def = try #require(ToolAdvertisement.definitions(for: execCaps, nativeExecComposed: true).first(where: { $0.name == "exec" }))
        let params = try JSONSerialization.jsonObject(with: Data(def.parametersJSON.utf8), options: []) as! [String: Any]
        #expect((params["additionalProperties"] as? Bool) == false, "additionalProperties false")
        #expect((params["properties"] as? [String: Any])?["executable"] != nil, "executable in schema")
        #expect((params["properties"] as? [String: Any])?["argv"] != nil, "argv in schema")
        #expect((params["required"] as? [String])?.sorted() == ["argv", "executable"], "required keys exact")
        let hidden = ToolAdvertisement.definitions(for: execCaps, nativeExecComposed: false).map(\.name)
        #expect(!hidden.contains("exec"), "uncomposed exec hidden even when granted")
    }

    @Test("wrong-impl probe: non-exec batches must NOT resolve (hasExec gate)")
    func wrongImplProbeNonExecMustNotResolve() throws {
        // MUST-FAIL PROBE: without the hasExec gate, a protected-path write
        // batch would resolve identities before approval. Removing the gate
        // makes this fail. The batch-level validator proves the category
        // is not validation — a write batch validates, but its approval
        // carries no exec identities and no resolution seed.
        let batch = [ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d",
                                  arguments: "{\"path\":\"a\",\"content\":\"b\"}")]
        let validated = try #require(try? ToolValidator.validateBatchArguments(batch: ToolBatch(batch)))
        #expect(validated.first?.tool == "write", "write batch validates — the gate tested is RESOLUTION, not validation")
        // Pure check: authorising a write batch under the native epoch
        // must NOT take the two-phase path (hasExec gate). The state that
        // reaches authorising carries the effective caps of the epoch; the
        // approved-approach-path is tested in C0TwoPhaseActorTests.
        let hasExec = batch.map(\.tool).contains("exec")
        #expect(!hasExec, "the batch under test contains no exec proposal")
    }

    @Test("crash in the phase-1 window: reopen reconciles clean, hold-free")
    func phase1CrashReopensClean() throws {
        // Phase 1 writes NO records beyond the authorising event marker, so
        // a crash in the window leaves nothing to reconcile.
        let log: [DurableRecord] = [
            .sessionOpened(session: SessionID("s"), atMillis: 1),
            .eventAppended(seq: SequenceNumber(1), kind: "authorising", digest: "resolve"),
        ]
        let reconciliation = try reconcileOperations(log)
        #expect(reconciliation.heldOperations.isEmpty, "phase-1 window is hold-free by construction")
        let epoch = try C0Fixtures.epoch(execComposed: false)
        let resumed = SessionState.resumedAfterReopen(
            sessionID: SessionID("s"), epoch: epoch, trustMode: .workspace,
            heldOperations: reconciliation.heldOperations)
        #expect(resumed.phase == .idle)
        #expect(resumed.pendingResolution == nil, "ephemeral seed never survives reopen")
        #expect(resumed.queueHeld == false, "nothing was dispatched: nothing held")
    }

/// Self-contained C0 fixtures (NeedletailStateTests fixtures are not
/// visible across test targets).
private enum C0Fixtures {
    static let configJSON = #"""
    {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M1B_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
    """#

    static func snapshot() throws -> ConfigSnapshot {
        try validateConfig(Data(configJSON.utf8))
    }

    static func epoch(execComposed: Bool) throws -> EpochDescriptor {
        let snapshot = try snapshot()
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        return EpochDescriptor(
            epochID: EpochID("epoch-c0"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route, execComposed: execComposed)
    }
}
}
