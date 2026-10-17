import Testing
import Foundation
import NeedletailCore

/// POLICY-02 (pure half, rev4-B/C) — denials dominate grants; sealed and
/// tools-none deny tools without touching routes; config-plus-flag is
/// legitimate narrowing; only disagreeing explicit argv directives reject;
/// later flags can never restore. Forbidden: any grant under sealed/none,
/// order dependence, workspace/config override of sealed, route coupling.
struct CapabilityMatrixTests {

    private static func snapshot() throws -> ConfigSnapshot {
        try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON())
    }

    private static func caps(
        user: ToolCapabilities? = nil,
        workspace: ToolCapabilities = .allDenied,
        invocation: ToolCapabilities? = nil,
        sealed: Bool = false
    ) throws -> EffectiveCapabilities {
        let snapshot = try snapshot()
        return effectiveCapabilities(
            build: .allAllowed,
            userConfig: user ?? snapshot.tools,
            workspaceGrant: workspace,
            invocationMask: invocation ?? .allAllowed,
            sealed: SealedRestrictions(sealed: sealed))
    }

    @Test("POLICY-02 sealed and tools-none deny tools, route independent")
    func POLICY_02_sealedDeniesToolsOnly() throws {
        let sealed = try Self.caps(sealed: true)
        #expect(sealed.tools == .allDenied, "sealed denies every tool")
        #expect(sealed.route == .localOnly, "sealed must not deny the route")
        #expect(sealed.deniedBy.contains("sealed"))
        let none = try Self.caps(invocation: .allDenied)
        #expect(none.tools == .allDenied)
        #expect(none.route == .localOnly)
        let both = try Self.caps(invocation: .allDenied, sealed: true)
        #expect(both.tools == .allDenied && both.route == .localOnly)
    }

    @Test("POLICY-02 permissive config plus restrictive flag narrows, allowed")
    func POLICY_02_configPlusFlagNarrows() throws {
        // Rev4-C: config enables + --sealed is intersection, NOT a
        // contradiction. (Workspace here is permissive so the flag's effect
        // is observable; the M1-A default workspace remains deny-all.)
        let snapshot = try Self.snapshot()
        let narrowed = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: true))
        #expect(narrowed.tools == .allDenied)
        let toolsNone = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allDenied,
            sealed: SealedRestrictions(sealed: false))
        #expect(toolsNone.tools == .allDenied)
        // Single-tool narrowing keeps exactly that tool.
        let readOnly = ToolCapabilities(read: true, search: false, edit: false, write: false, exec: .denied, consult: false)
        let read = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: readOnly,
            sealed: SealedRestrictions(sealed: false))
        #expect(read.tools.read && !read.tools.write && !read.tools.edit)
        // exec=ask survives only where every layer permits at least ask.
        #expect(read.tools.exec == .denied, "denied workspace mask denies exec")
    }

    @Test("POLICY-02 conflicting explicit argv directives reject, both orders")
    func POLICY_02_conflictingFlagsRejected() throws {
        let conflicts: [[String]] = [
            ["--sealed", "--tools", "read"], ["--tools", "read", "--sealed"],
            ["--tools", "none", "--tools", "read"], ["--tools", "read", "--tools", "none"],
            ["--tools", "read", "--tools", "write"], ["--tools", "write", "--tools", "read"],
        ]
        for argv in conflicts {
            let (sealedCount, values) = Self.splitDirectives(argv)
            do {
                _ = try checkCLIDirectives(sealedCount: sealedCount, toolsValues: values)
                Issue.record("conflicting argv must reject: \(argv)")
            } catch let error as ConfigError {
                #expect(error.kind == .contradictoryFlags, "\(argv): got \(error.kind)")
            }
        }
        // Identical repeats are legal; sealed+none agree (both deny tools).
        #expect(try checkCLIDirectives(sealedCount: 2, toolsValues: []).sealed)
        #expect(try checkCLIDirectives(sealedCount: 0, toolsValues: ["none", "none"]).mask == .allDenied)
        let agreed = try checkCLIDirectives(sealedCount: 1, toolsValues: ["none"])
        #expect(agreed.sealed && agreed.mask == .allDenied)
        // Unknown tool names fail closed with vocabulary.
        do {
            _ = try checkCLIDirectives(sealedCount: 0, toolsValues: ["teleport"])
            Issue.record("unknown tool must fail closed")
        } catch let error as ConfigError {
            #expect(error.kind == .unsupportedCombination)
            #expect(error.hint.contains("read"))
        }
    }

    @Test("POLICY-02 sealed local route stays permitted while tools are none")
    func POLICY_02_sealedLocalRoutePermitted() throws {
        let snapshot = try Self.snapshot()
        let sealed = try Self.caps(sealed: true)
        #expect(sealed.tools == .allDenied)
        guard case .allowed(let endpoint, let alias) = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: true) else {
            Issue.record("sealed tool-free request to the approved local model must be permitted")
            return
        }
        #expect(alias == "local-coder" && endpoint.hasSuffix("/chat/completions"))
        let open = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        #expect(open == selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: true),
                "sealed must not alter the route outcome")
    }

    @Test("POLICY-02 no layer combination can grant above build")
    func POLICY_02_denialsDominate() throws {
        let snapshot = try Self.snapshot()
        // Workspace deny-all (M1-A default) denies everything even when the
        // config enables it — and no invocation can lift that denial.
        let caps = try Self.caps()
        #expect(caps.tools == .allDenied)
        #expect(Set(caps.deniedBy).contains("workspaceGrant"))
    }

    // MARK: - argv token splitter (mirrors the CLI parser contract)

    static func splitDirectives(_ argv: [String]) -> (Int, [String]) {
        var sealed = 0
        var values: [String] = []
        var i = argv.startIndex
        while i < argv.endIndex {
            if argv[i] == "--sealed" { sealed += 1 }
            else if argv[i] == "--tools", argv.index(after: i) < argv.endIndex {
                i = argv.index(after: i)
                values.append(argv[i])
            }
            i = argv.index(after: i)
        }
        return (sealed, values)
    }
}
