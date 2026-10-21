/// M1-A credential references (SPEC §5.3). Configuration stores exactly
/// one reference (variable name, file path, or keychain account) — never a
/// secret value. Resolution is a separate explicit call scoped to one
/// operation; diagnostics render the reference only. No filesystem,
/// environment or network access in this file: stores live in Runtime.
public struct CredentialReference: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case env(name: String)
        case file(path: String)
        case keychain(account: String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public init(descriptor: CredentialDescriptor) throws {
        switch descriptor.kind {
        case "env": self.init(kind: .env(name: descriptor.value))
        case "file": self.init(kind: .file(path: descriptor.value))
        case "keychain": self.init(kind: .keychain(account: descriptor.value))
        default:
            throw ConfigError(
                path: "$.models[].credential", kind: .unknownField,
                message: "unknown credential kind '\(descriptor.kind)'.",
                hint: "use exactly one of: env, file, keychain.")
        }
    }

    /// Reference-only rendering for every diagnostic path. The secret value
    /// can never appear here because it is never stored in this type. The
    /// reference itself renders through `terminalSafe` (H2).
    public var redactedDescription: String {
        switch kind {
        case .env(let name): return "env:\(terminalSafe(name))"
        case .file(let path): return "file:\(terminalSafe(path))"
        case .keychain(let account): return "keychain:\(terminalSafe(account))"
        }
    }
}

public enum CredentialError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingEnv(name: String)
    case unreadableFile(path: String, reason: String)
    case insecurePermissions(path: String, actual: String)
    case unsupportedOnLinux(what: String)
    case credentialTooLarge(path: String)

    /// Display boundary (S-2): names and paths are operator-supplied and
    /// render escaped, so a hostile variable name cannot smuggle terminal
    /// controls into a future diagnostic that prints this error.
    public var description: String {
        switch self {
        case .missingEnv(let name):
            return "missingEnv: environment variable '\(terminalSafe(name))' is not set for this operation."
        case .unreadableFile(let path, let reason):
            return "unreadableFile: credential file '\(terminalSafe(path))' cannot be read (\(reason))."
        case .insecurePermissions(let path, let actual):
            return "insecurePermissions: credential file '\(terminalSafe(path))' has mode \(actual); require owner-only (0600)."
        case .unsupportedOnLinux(let what):
            return "unsupportedOnLinux: '\(terminalSafe(what))' needs macOS Keychain; unavailable on this host."
        case .credentialTooLarge(let path):
            return "credentialTooLarge: credential file '\(terminalSafe(path))' exceeds \(ConfigLimits.maxCredentialBytes) bytes."
        }
    }
}

/// The single resolution seam (TESTING §5). Production Linux stores and the
/// macOS stub both conform; tests use a tiny scripted fake. Exactly one
/// credential is resolved per call — never a sweep.
public protocol CredentialStore: Sendable {
    func resolve(_ reference: CredentialReference, for operation: String) throws -> String
}
