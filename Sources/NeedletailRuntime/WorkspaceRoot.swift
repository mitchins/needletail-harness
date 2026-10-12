import SystemPackage

/// NeedletailRuntime will own the five native tools, execution policy and the
/// side-effect ledger. M0-A seeds only the workspace-root value type the
/// layout needs. The full boundary checks (descriptor-relative no-follow
/// traversal, optimistic conflict checks) are M2-B work and are deliberately
/// absent here; nothing in this type claims containment yet.

/// The operator-designated canonical workspace root. Path handling uses
/// SystemPackage descriptor/path primitives rather than string-only
/// confinement (SPEC §3.1).
public struct WorkspaceRoot: Sendable, Equatable {
    public let path: FilePath

    public init?(path: FilePath) {
        // A root must be a usable path. Empty is rejected here rather than
        // silently defaulting, which would fabricate a workspace identity.
        guard !path.string.isEmpty else { return nil }
        self.path = path
    }

    public var description: String { path.string }
}
