import Foundation
import NeedletailCore

/// M1-C bounded SSE intake (SPEC §11). Every bound is enforced UPSTREAM of
/// the OpenAPI-runtime parser accumulation — including unterminated lines
/// and events. Numbers are the SPEC §11 initial bounds, profile-adjustable
/// later only via config edit, never silently enlarged.
public enum SSEBounds {
    /// Reject an unterminated line/event over this size (bytes, UTF-8).
    public static let maxLineBytes = 1 << 20
    /// Whole-stream cap (wire bytes as received).
    public static let maxStreamBytes = 16 << 20
    /// Per-tool-call argument buffer cap (accumulated across ALL fragments
    /// sharing the native id — R8).
    public static let maxArgumentsBytes = 256 << 10
    /// Distinct tool-call ids per response.
    public static let maxToolCalls = 8
    /// Error-body collection cap.
    public static let maxErrorBytes = 8 << 10
    /// Probe/loopback request-body sanity cap.
    public static let maxRequestBytes = 4 << 20
}

public enum BoundBreach: Error, Sendable, Equatable, CustomStringConvertible {
    case lineTooLong(bytes: Int)
    case streamTooLarge(bytes: Int)
    case argumentsTooLarge(callID: String, bytes: Int)
    case tooManyToolCalls(count: Int)
    case errorBodyTooLarge

    public var description: String {
        switch self {
        case .lineTooLong(let bytes):
            return "lineTooLong: unterminated SSE line/event exceeds \(SSEBounds.maxLineBytes) bytes (saw \(bytes))."
        case .streamTooLarge(let bytes):
            return "streamTooLarge: response stream exceeds \(SSEBounds.maxStreamBytes) bytes (saw \(bytes))."
        case .argumentsTooLarge(let callID, let bytes):
            return "argumentsTooLarge: tool call '\(terminalSafe(callID))' exceeds \(SSEBounds.maxArgumentsBytes) bytes (saw \(bytes))."
        case .tooManyToolCalls(let count):
            return "tooManyToolCalls: \(count) distinct tool calls exceed \(SSEBounds.maxToolCalls)."
        case .errorBodyTooLarge:
            return "errorBodyTooLarge: error body exceeds \(SSEBounds.maxErrorBytes) bytes."
        }
    }
}

/// Byte-budget tracker for the delegate path: total stream bytes plus the
/// current unterminated-tail length (bytes after the last `\n`, accumulated
/// across chunks). Both are checked per chunk, so a 2 MiB unterminated
/// line fails BEFORE 16 MiB accumulate. Value type; the delegate holds one
/// under lock.
public struct StreamBudget: Sendable, Equatable {
    public var totalBytes: Int
    public var tailBytes: Int

    public init(totalBytes: Int = 0, tailBytes: Int = 0) {
        self.totalBytes = totalBytes
        self.tailBytes = tailBytes
    }

    public mutating func consume(_ chunk: [UInt8]) throws {
        totalBytes += chunk.count
        if let lastNewline = chunk.lastIndex(of: 0x0A) {
            tailBytes = chunk.count - lastNewline - 1
        } else {
            tailBytes += chunk.count
        }
        guard totalBytes <= SSEBounds.maxStreamBytes else {
            throw BoundBreach.streamTooLarge(bytes: totalBytes)
        }
        guard tailBytes <= SSEBounds.maxLineBytes else {
            throw BoundBreach.lineTooLong(bytes: tailBytes)
        }
    }
}
