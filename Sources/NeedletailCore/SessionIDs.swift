import Foundation // Value types only (UUID, Date): no platform I/O.

/// M1-B deterministic identities, clocks and ID sources (ARCH §1).
/// Timestamps and IDs are stamped onto events by the actor BEFORE the
/// transition runs: reducers never read clocks or UUID generators, so every
/// event is replayable from explicit values. All value types; no I/O.
public struct SessionID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public struct RunID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct RequestID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct EffectID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct EpochID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct OperationID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Operator queue idempotence key. Opaque string, never coerced.
public struct CommandID: Sendable, Equatable, Hashable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Per-session monotonic generation. Every mutating continuation carries
/// the revision it was authorized under; anything older drops (I21).
public struct Revision: Sendable, Equatable, Comparable, Hashable, Codable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public static func < (lhs: Revision, rhs: Revision) -> Bool { lhs.value < rhs.value }
}

/// Durable ordering counter. M1-B assigns it in memory with the full shape
/// M2 persists; durable assignment across restarts is M2-A work.
public struct SequenceNumber: Sendable, Equatable, Comparable, Hashable, Codable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public static func < (lhs: SequenceNumber, rhs: SequenceNumber) -> Bool { lhs.value < rhs.value }
}

public protocol Clock: Sendable {
    func nowMillis() -> UInt64
}

/// Production clock (wall time). Tests use VirtualClock.
public struct SystemClock: Clock, Sendable {
    public init() {}
    public func nowMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}

/// Frozen + manually advanced clock. Deterministic: time moves only when
/// the test driver says so — never real sleeps in the pure layer.
public struct VirtualClock: Clock, Sendable {
    public var now: UInt64
    public init(now: UInt64 = 0) { self.now = now }
    public func nowMillis() -> UInt64 { now }
    public mutating func advance(by millis: UInt64) { now += millis }
}

public protocol IDSource: Sendable {
    mutating func nextRunID() -> RunID
    mutating func nextRequestID() -> RequestID
    mutating func nextEffectID() -> EffectID
    mutating func nextEpochID() -> EpochID
    mutating func nextOperationID() -> OperationID
    mutating func nextSequence() -> SequenceNumber
    /// M2-D D0: advance the sequence counter past a durable high-water
    /// mark (reopen replay). A resumed session must never mint IDs its
    /// own log already contains — duplicate queue admissions fail the
    /// reconcile closed. No-op when already past the mark.
    mutating func advance(past watermark: UInt64)
}

/// Production source (UUID-backed). Randomness never leaks into state
/// except through stamped event fields.
public struct RandomIDSource: IDSource, Sendable {
    private var sequence: UInt64 = 0
    public init() {}
    public mutating func nextRunID() -> RunID { RunID(UUID().uuidString) }
    public mutating func nextRequestID() -> RequestID { RequestID(UUID().uuidString) }
    public mutating func nextEffectID() -> EffectID { EffectID(UUID().uuidString) }
    public mutating func nextEpochID() -> EpochID { EpochID(UUID().uuidString) }
    public mutating func nextOperationID() -> OperationID { OperationID(UUID().uuidString) }
    public mutating func nextSequence() -> SequenceNumber {
        sequence += 1
        return SequenceNumber(sequence)
    }
    public mutating func advance(past watermark: UInt64) {
        if sequence < watermark { sequence = watermark }
    }
}

/// Deterministic source (tests, replays). Same seed + same call order =
/// same IDs, so transitions replay byte-identically.
public struct DeterministicIDSource: IDSource, Sendable {
    public var prefix: String
    public var counter: UInt64
    public init(prefix: String = "id", counter: UInt64 = 0) {
        self.prefix = prefix
        self.counter = counter
    }
    private mutating func next(_ kind: String) -> String {
        counter += 1
        return "\(prefix)-\(kind)-\(counter)"
    }
    public mutating func nextRunID() -> RunID { RunID(next("run")) }
    public mutating func nextRequestID() -> RequestID { RequestID(next("req")) }
    public mutating func nextEffectID() -> EffectID { EffectID(next("eff")) }
    public mutating func nextEpochID() -> EpochID { EpochID(next("epoch")) }
    public mutating func nextOperationID() -> OperationID { OperationID(next("op")) }
    public mutating func nextSequence() -> SequenceNumber {
        counter += 1
        return SequenceNumber(counter)
    }
    public mutating func advance(past watermark: UInt64) {
        if counter < watermark { counter = watermark }
    }
}

/// Deterministic non-cryptographic fingerprint (FNV-1a, 64-bit) for
/// invalid-attempt identity. Core must not import Crypto (architecture
/// gate); this is a discriminator, not a security digest — raw secrets are
/// never fingerprinted or logged (callers hash KINDS, not content).
public func fnv1aHex(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}
