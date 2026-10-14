import NeedletailCore

/// macOS Keychain interface placeholder (SPEC §5.3, DEVELOPMENT §2). The
/// `CredentialStore` conformance preserves the required interface without
/// introducing any macOS implementation in M1-A: no `Security` import, no
/// platform branch, no silent fallback. Every call fails closed with an
/// actionable error; Linux resolution lives in `EnvFileCredentialStore`.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    public init() {}

    public func resolve(_ reference: CredentialReference, for operation: String) throws -> String {
        throw CredentialError.unsupportedOnLinux(
            what: "\(reference.redactedDescription) for '\(operation)' (macOS Keychain arrives after Linux viability)")
    }
}
