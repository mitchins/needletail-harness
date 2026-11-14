import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import GRDB

private var m3aLiveEnabled3: Bool {
    ProcessInfo.processInfo.environment["M3A_LIVE"] == "1" && ProcessInfo.processInfo.environment["M3A_CONFIG_PATH"] != nil
}
private func m3aSnapshot3() throws -> ConfigSnapshot {
    guard let path = ProcessInfo.processInfo.environment["M3A_CONFIG_PATH"] else {
        throw ConfigError(path: "$", kind: .missingReference, message: "M3A_CONFIG_PATH not set", hint: "")
    }
    let snap = try validateConfig(try Data(contentsOf: URL(fileURLWithPath: path)))
    guard let p = snap.profiles["local-coder"], p.origin == "http://192.168.2.216:8731", p.modelID == "halogen-qwen3.8-flash-next", p.locality == .local else {
        throw ConfigError(path: "$", kind: .unsupportedCombination, message: "origin/model/locality mismatch", hint: "")
    }
    return snap
}
private func m3aIsolatedStorePath3() -> String {
    let base = ProcessInfo.processInfo.environment["NEEDLETAIL_STATE_DIR"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("m3a-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (base as NSString).appendingPathComponent("m3a-replay-\(UUID().uuidString).sqlite")
}
private func writeEvidence3(id: String, data: Data) throws -> (path: String, digest: String) {
    let base = ProcessInfo.processInfo.environment["M3A_EVIDENCE_DIR"] ?? ".needletail-dev/m3a-evidence"
    do {
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: base)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        guard perms & 0o777 == 0o700 else { throw ConfigError(path: base, kind: .unsupportedCombination, message: "evidence dir perms \(String(perms, radix: 8))", hint: "") }
    } catch { throw error }
    let path = (base as NSString).appendingPathComponent("\(id)-\(UUID().uuidString).json")
    do {
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        guard perms & 0o777 == 0o600 else { throw ConfigError(path: path, kind: .unsupportedCombination, message: "file perms \(String(perms, radix: 8))", hint: "") }
    } catch { throw error }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let persisted = try Data(contentsOf: URL(fileURLWithPath: path))
    let pd = SHA256.hash(data: persisted).map { String(format: "%02x", $0) }.joined()
    guard digest == pd else { throw ConfigError(path: path, kind: .unsupportedCombination, message: "digest mismatch", hint: "") }
    return (path, digest)
}

@Suite(.serialized)
struct M3AReplayLiveTests2 {
    @Test("M3-A 7: SessionActor replay preserves transcript (live, distinctive synthetic value)", .enabled(if: m3aLiveEnabled3, "M3A_LIVE=1"))
    func replay() async throws {
        let snap = try m3aSnapshot3()
        let profile = try #require(snap.profiles["local-coder"])
        let storePath = m3aIsolatedStorePath3()
        let store = try GRDBSessionStore(path: storePath)
        defer { try? store.close(); try? FileManager.default.removeItem(atPath: storePath) }
        let session = SessionID("m3a-replay-\(UUID().uuidString)")
        let writer = "m3a-writer"
        try store.claimWriterOwnership(session: session, writer: writer)
        let epoch = EpochDescriptor(epochID: EpochID("epoch-m3a"), parentEpochID: nil, configSnapshot: snap, profile: profile, effectiveCaps: effectiveCapabilities(build: .allAllowed, userConfig: snap.tools, workspaceGrant: .allAllowed, invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false)), route: selectRoute(snapshot: snap, requestedAlias: "local-coder", sealed: false))
        let state = SessionState(sessionID: session, epoch: epoch, trustMode: .workspace, phase: .idle)
        final class RequestLog: @unchecked Sendable {
            var requests: [[ChatMessage]] = []
            let lock = NSLock()
            func append(_ m: [ChatMessage]) { lock.withLock { requests.append(m) } }
            func all() -> [[ChatMessage]] { lock.withLock { requests } }
        }
        let log = RequestLog()
        let distinctive = "SYNTHETIC-RETRIEVED-9F3C2-\(UUID().uuidString.prefix(4))"
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        // No `await` in `defer` on Swift 6.1/Xcode 16.3 toolchains: the
        // unstructured task retains `client` until the drain completes, so
        // deinit still runs post-shutdown (no AHC trap). Nothing after the
        // invoke touches the client, so the concurrent drain is harmless.
        defer { Task { try? await client.shutdown().get() } }
        let messageProvider: @Sendable (ProviderInvocation) async throws -> [ChatMessage] = { _ in
            let msgs = try loadTranscript(from: store, session: session, limit: 1024)
            let data = try JSONEncoder().encode(msgs)
            let (_, d) = try writeEvidence3(id: "m3a-7-request", data: data)
            log.append(msgs)
            print("M3-A7 request log: count=\(msgs.count) digest=\(d)")
            if msgs.isEmpty { return [ChatMessage(role: .user, text: "Use the 'search' tool with pattern \"hello\" to look for files. You must call the tool.")] }
            return msgs
        }
        let transport = ChatCompletionsTransport(client: client, messageProvider: messageProvider, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 64), advertisedTools: ToolCapabilities(read: true, search: true, edit: false, write: false, exec: .denied, consult: false))
        final class DenyingExecutor: ToolExecutor, @unchecked Sendable {
            let distinctive: String
            var batches: [ToolBatch] = []
            let lock = NSLock()
            init(distinctive: String) { self.distinctive = distinctive }
            func describe(batch: ToolBatch) -> String { "denying \(batch.proposals.map(\.tool).joined())" }
            func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
                lock.withLock { batches.append(batch) }
                let outcomes = batch.proposals.map { p in ToolCallOutcome(callID: p.callID, status: "denied", summary: "synthetic", data: "synthetic result \(distinctive) for \(p.arguments ?? "")", started: false) }
                return ExecutorResult(receipt: ExecutorReceipt(callID: batch.proposals.first?.callID ?? "none", status: "denied", summary: "synthetic"), calls: outcomes)
            }
        }
        let executor = DenyingExecutor(distinctive: String(distinctive))
        struct SimpleApprovals: ApprovalGateway, Sendable { func decide(_ r: ApprovalRequest) async -> ApprovalDecision { .unavailable("no approval") } }
        let actor = try SessionActor(state: state, ids: DeterministicIDSource(prefix: "m3a"), clock: SystemClock(), transport: transport, executor: executor, store: store, approvals: SimpleApprovals(), writer: writer)
        await actor.submitText(commandID: CommandID("cmd-1"), text: "Use the 'search' tool with pattern \"hello\" to look for files. You must call the tool.", kind: .followUp, sealed: false)
        var firstCallID = ""
        var firstArgs = ""
        var saw = false
        for _ in 0..<100 {
            let batches = executor.lock.withLock { executor.batches }
            if let b = batches.first, let p = b.proposals.first { firstCallID = p.callID; firstArgs = p.arguments ?? ""; saw = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard saw else {
            let all = log.all()
            if let last = all.last { let data = try JSONEncoder().encode(last); let (_, d) = try writeEvidence3(id: "m3a-7-inconclusive", data: data); print("INCONCLUSIVE digest=\(d)") }
            Issue.record("INCONCLUSIVE: Halogen declined tool call")
            return
        }
        #expect(!firstCallID.isEmpty)
        #expect(firstArgs.contains("hello"))
        print("M3-A7 turn1: callID=\(firstCallID) args=\(firstArgs) distinctive=\(distinctive)")
        await actor.submitText(commandID: CommandID("cmd-2"), text: "What was the retrieved value from the search? Report it exactly.", kind: .followUp, sealed: false)
        var secondMessages: [ChatMessage] = []
        var secondText = ""
        for _ in 0..<100 {
            let all = log.all()
            if all.count >= 2 {
                secondMessages = all[1]
                let transcript = try loadTranscript(from: store, session: session, limit: 1024)
                if let last = transcript.last, last.text.contains(distinctive) { secondText = last.text; break }
            }
            if all.count >= 2 {
                let transcript = try loadTranscript(from: store, session: session, limit: 1024)
                if let last = transcript.last, last.text.contains(distinctive) { secondMessages = all[1]; secondText = last.text; break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let transcript = try loadTranscript(from: store, session: session, limit: 1024)
        let tData = try JSONEncoder().encode(transcript)
        let (_, tDigest) = try writeEvidence3(id: "m3a-7-transcript", data: tData)
        print("M3-A7 transcript: count=\(transcript.count) digest=\(tDigest)")
        #expect(!secondMessages.isEmpty, "second provider request sent")
        let hasCall = secondMessages.contains(where: { $0.toolCalls?.contains(where: { $0.callID == firstCallID }) ?? false })
        let hasResp = secondMessages.contains(where: { $0.toolCallID == firstCallID })
        #expect(hasCall, "preserves call ID \(firstCallID)")
        #expect(hasResp, "preserves paired tool response")
        if let tc = secondMessages.flatMap({ $0.toolCalls ?? [] }).first(where: { $0.callID == firstCallID }) { #expect(tc.arguments == firstArgs) }
        #expect(secondMessages.contains(where: { $0.text.contains(distinctive) }), "distinctive appears only via tool result")
        let batchCount = executor.lock.withLock { executor.batches.count }
        #expect(batchCount == 1, "exactly one batch, no unintended effects")
        let (page, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(page.contains(where: { if case .transcriptAppended = $0.record { return true }; return false }), "transcript appended to isolated GRDB store")
        if !secondText.isEmpty { print("M3-A7 second response contains distinctive: \(secondText.prefix(80))") }
        // Awaited drain (normal path); the deferred task is the throw-path backstop.
        try? await client.shutdown().get()
    }
}
