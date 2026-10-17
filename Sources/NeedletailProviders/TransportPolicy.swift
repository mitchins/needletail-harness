import AsyncHTTPClient
import Foundation
import NeedletailCore
import NIOCore // NIODeadline + TimeAmount only (no channels/sockets here).

/// M1-C transport policy (SPEC §§5.3/10.3/11). One shared `HTTPClient` per
/// adapter instance. Verified against AsyncHTTPClient 1.36.2 sources:
/// - redirects: `.disallow` — a 3xx is a typed error, never followed, no
///   credential forwarding (NET-02);
/// - proxy: never set (the client reads no proxy env vars — NET-03 by
///   construction; the hostile-env test proves it end to end);
/// - TLS: default validation; custom local CAs deferred (no config field
///   exists; unknown-CA https fails honestly);
/// - decompression: `.disabled`, stated explicitly (R5 — no gunzip path
///   exists, so caps measure wire bytes = decoded bytes trivially);
/// - event loop: the shared singleton (no group lifecycle to leak; the
///   SPEC §4.1 one-thread default is revisited on profiles in M3 — a
///   dedicated single-thread group needs an NIOPosix edge this slice
///   deliberately avoids; recorded, reviewer-judged).
public enum ChatTransportPolicy {
    public static func configuration(profile: ModelProfile) -> HTTPClient.Configuration {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.decompression = .disabled
        // Single deadline authority: the transport supervisor owns read-idle
        // AND whole-request (typed phases, heartbeat-aware). A client-level
        // read timeout would duplicate that authority with an untyped
        // HTTPClientError.readTimeout that races the supervisor's verdict
        // (observed end to end: the client's 1 s timer beat the
        // supervisor's typed read-idle). Connect stays client-enforced:
        // pre-head by construction, classified preSend at the catch site.
        configuration.timeout = .init(
            connect: .seconds(Int64(profile.connectTimeout)),
            read: nil)
        return configuration
    }

    public static func wholeRequestDeadline(profile: ModelProfile, startedAt: NIODeadline) -> NIODeadline {
        startedAt + .seconds(Int64(profile.requestTimeout))
    }
}
