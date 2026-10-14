import AsyncHTTPClient
import Foundation
import NeedletailCore

/// M1-C explicit probe path (NET-06 traffic half). Everything transport-
/// shaped stays inside Providers: the CLI calls exactly one function and
/// prints the returned record. The packet is fixed literals (never
/// workspace/history/session bytes); credentials resolve per-operation via
/// the caller's store and never enter logs.
public struct ProbeResult: Sendable, Equatable {
    public var endpoint: String
    public var configuredModel: String
    public var returnedModel: String?
    public var usageInput: Int?
    public var usageOutput: Int?
    public var elapsedMillis: UInt64

    public init(
        endpoint: String, configuredModel: String, returnedModel: String? = nil,
        usageInput: Int? = nil, usageOutput: Int? = nil, elapsedMillis: UInt64 = 0
    ) {
        self.endpoint = endpoint
        self.configuredModel = configuredModel
        self.returnedModel = returnedModel
        self.usageInput = usageInput
        self.usageOutput = usageOutput
        self.elapsedMillis = elapsedMillis
    }
}

/// Probe request constants (R9): fixed literals, max_tokens 16, no operator
/// options, whole packet ≤ 4 KiB (asserted on the captured wire bytes by
/// the DX-04 loopback test — never estimated, never profile-derived).
public enum ProbePacket {
    public static let maxTokens = 16
    public static let bodyByteCap = 4 * 1_024

    public static func messages() -> [ChatMessage] {
        [ChatMessage(role: .system, text: "needletail probe"),
         ChatMessage(role: .user, text: "probe ping")]
    }
}

/// Probes one configured alias end to end: authorize, resolve credential,
/// send the synthetic packet, decode the turn. Throws TransportFailure /
/// ChatTransportError / AssemblyError / CredentialError on every failure
/// path (callers map to exits, never to estimated successes).
public func probeRoute(
    snapshot: ConfigSnapshot,
    alias: String,
    credentialStore: any CredentialStore
) async throws -> ProbeResult {
    guard let profile = snapshot.profiles[alias] else {
        throw ConfigError(
            path: "$.models", kind: .missingReference,
            message: "unknown model alias '\(terminalSafe(alias))'.",
            hint: "probe a configured alias.")
    }
    let route = authorizeRequestDestination(snapshot: snapshot, requestedAlias: alias, sealed: true)
    guard case .allowed(let endpoint, _) = route else {
        // Refused pre-dial: zero traffic, so preSend (nothing left the
        // process) with the denial as the message — never a retry loop here
        // (the CLI calls once; the actor policy would count it if wired).
        throw TransportFailure(phase: .preSend, message: "route refused before dial")
    }
    var credential: String?
    if let reference = profile.credential {
        credential = try credentialStore.resolve(reference, for: "probe")
    }
    let resolvedCredential = credential
    let client = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: ChatTransportPolicy.configuration(profile: profile))
    defer { try? await client.shutdown().get() }
    let transport = ChatCompletionsTransport(
        client: client,
        messageProvider: { _ in ProbePacket.messages() },
        credentialProvider: { _, _ in resolvedCredential },
        snapshotProvider: { snapshot },
        requestOverride: ChatRequestOverride(maxTokens: ProbePacket.maxTokens))
    let invocation = ProviderInvocation(
        effectID: EffectID("probe"), requestID: RequestID("probe"), runID: RunID("probe"),
        generation: Revision(0), alias: alias, epochID: EpochID("probe"), sealed: true,
        turnsLeft: 1, deadlineMillis: nil, historyDigest: "probe")
    let started = Date()
    // Probe-level whole cap (60 s) regardless of profile timeouts: a probe
    // is a liveness check, never a workload (focused correction recorded
    // in the milestone report).
    let result = try await withThrowingTaskGroup(of: TransportResult.self) { group in
        group.addTask {
            try await transport.invoke(
                invocation,
                intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw TransportFailure(phase: .postContent, message: "probe whole-request cap (60 s) exceeded")
        }
        guard let first = try await group.next() else {
            throw TransportFailure(phase: .ambiguous, message: "probe produced nothing")
        }
        group.cancelAll()
        return first
    }
    let elapsed = UInt64(Date().timeIntervalSince(started) * 1000.0)
    return ProbeResult(
        endpoint: endpoint, configuredModel: profile.modelID,
        returnedModel: result.response.returnedModel,
        usageInput: result.response.usageInput,
        usageOutput: result.response.usageOutput, elapsedMillis: elapsed)
}
