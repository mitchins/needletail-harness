import Testing
import Foundation
import NeedletailCore
import NeedletailProviders

/// B5 advertisement: harness-owned JSON Schema definitions.
/// Exact wire-shape pins + validator-agreement proofs (schema-conformant
/// arguments pass dispatch validation; strictness violations fail it) +
/// capability gating (exec/consult/diff never advertised) + OpenAI
/// envelope compatibility (best-effort strict:false on the wire, strict
/// validation at dispatch).
struct ToolAdvertisementTests {

    private static func defs(_ caps: ToolCapabilities) -> [ToolDefinition] {
        ToolAdvertisement.definitions(for: caps)
    }

    @Test("advertisement exact schema: read")
    func exactRead() {
        let def = Self.defs(.allAllowed).first(where: { $0.name == "read" })
        let got = try? #require(def).json()
        #expect(got == #"{"description":"Read a file or a previously published artifact. Exactly one of path or artifactId selects the source; limit\/offset page long files. Read-only: never mutates.","name":"read","parameters":{"additionalProperties":false,"properties":{"artifact_id":{"description":"Alias of artifactId.","type":"string"},"artifactId":{"description":"64-hex digest of a previously published artifact.","type":"string"},"limit":{"description":"Max lines returned (1-10000).","type":"integer"},"offset":{"description":"First line index (0-based).","type":"integer"},"path":{"description":"Workspace-relative file path.","type":"string"}},"required":[],"type":"object"},"strict":false}"#)
    }

    @Test("advertisement exact schema: search")
    func exactSearch() {
        let def = Self.defs(.allAllowed).first(where: { $0.name == "search" })
        let got = try? #require(def).json()
        #expect(got == #"{"description":"Search workspace files. Pattern is required; path scopes the search to one directory. Read-only: never mutates.","name":"search","parameters":{"additionalProperties":false,"properties":{"path":{"description":"Workspace-relative directory scope.","type":"string"},"pattern":{"description":"Ripgrep pattern (required, non-empty).","type":"string"}},"required":["pattern"],"type":"object"},"strict":false}"#)
    }

    @Test("advertisement exact schema: edit")
    func exactEdit() {
        let def = Self.defs(.allAllowed).first(where: { $0.name == "edit" })
        let got = try? #require(def).json()
        #expect(got == #"{"description":"Replace exactly one occurrence of old text in a file. expectedHash authorizes the replacement against the exact current bytes (optimistic concurrency). Mutating.","name":"edit","parameters":{"additionalProperties":false,"properties":{"expectedHash":{"description":"64-hex SHA-256 of the exact current file bytes.","type":"string"},"new_string":{"description":"Replacement text (alias newBytes).","type":"string"},"newBytes":{"description":"Replacement text (alias new_string).","type":"string"},"old_string":{"description":"Text to replace, exactly once (alias oldBytes).","type":"string"},"oldBytes":{"description":"Text to replace, exactly once (alias old_string).","type":"string"},"path":{"description":"Workspace-relative file path.","type":"string"}},"required":["expectedHash","path"],"type":"object"},"strict":false}"#)
    }

    @Test("advertisement exact schema: write")
    func exactWrite() {
        let def = Self.defs(.allAllowed).first(where: { $0.name == "write" })
        let got = try? #require(def).json()
        #expect(got == #"{"description":"Create a new file (exclusive; never overwrites) or, with expectedHash, replace a whole file whose current bytes hash exactly. Mutating.","name":"write","parameters":{"additionalProperties":false,"properties":{"content":{"description":"Full file content for create or replacement.","type":"string"},"expectedHash":{"description":"64-hex SHA-256 authorizing whole-file replacement.","type":"string"},"path":{"description":"Workspace-relative file path.","type":"string"}},"required":["content","path"],"type":"object"},"strict":false}"#)
    }

    @Test("advertisement capability gating: exec consult diff never advertised")
    func gating() throws {
        #expect(Self.defs(.allDenied).isEmpty, "denied caps advertise nothing")
        let full = Self.defs(.allAllowed).map(\.name)
        #expect(full == ["read", "search", "edit", "write"], "full caps advertise exactly the four file tools, got \(full)")
        #expect(!full.contains("exec") && !full.contains("consult") && !full.contains("diff"), "exec/consult/diff never advertised")
        let readOnly = ToolCapabilities(read: true, search: true, edit: false, write: false, exec: .denied, consult: false)
        #expect(ToolAdvertisement.names(for: readOnly) == ["read", "search"], "read-only caps advertise read+search only")
        let execAsk = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .ask, consult: true)
        let execNames = ToolAdvertisement.names(for: execAsk)
        #expect(!execNames.contains("exec") && !execNames.contains("consult"), "ask/exec caps still advertise no exec/consult, got \(execNames)")
    }

    // MARK: - Schema/validator agreement (advertisement is discovery-only;
    // dispatch validation stays authoritative)

    private static func batch(_ tool: String, _ args: String) -> ToolBatch {
        ToolBatch([ToolProposal(callID: "c1", tool: tool, argumentsDigest: "d", arguments: args)])
    }

    @Test("advertisement schema-conformant arguments pass dispatch validation")
    func conformantPasses() throws {
        let hex = String(repeating: "a", count: 64)
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("read", #"{"path":"f.txt"}"#))
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("read", #"{"artifactId":"\#(hex)","limit":10,"offset":0}"#))
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("search", #"{"pattern":"hello","path":"sub"}"#))
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("edit", #"{"path":"f.txt","expectedHash":"\#(hex)","old_string":"a","new_string":"b"}"#))
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("write", #"{"path":"n.txt","content":"x"}"#))
        _ = try ToolValidator.validateBatchArguments(batch: Self.batch("write", #"{"path":"n.txt","content":"x","expectedHash":"\#(hex)"}"#))
    }

    @Test("advertisement strictness violations fail dispatch validation")
    func violationsFail() {
        // Unknown field (additionalProperties:false counterpart).
        #expect(throws: ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown field extra for read c1")) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("read", #"{"path":"f.txt","extra":1}"#))
        }
        // Missing required pattern.
        #expect(throws: ToolFailure.self) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("search", #"{"path":"sub"}"#))
        }
        // Wrong type (limit must be int).
        #expect(throws: ToolFailure.self) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("read", #"{"path":"f.txt","limit":"10"}"#))
        }
        // XOR violations the schema documents but the validator enforces.
        #expect(throws: ToolFailure.self) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("read", #"{"path":"f.txt","artifactId":"\#(String(repeating: "a", count: 64))"}"#))
        }
        // Unadvertised tools are denied at dispatch.
        #expect(throws: ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown tool diff")) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("diff", #"{"path":"f.txt"}"#))
        }
        #expect(throws: ToolFailure.self) {
            try ToolValidator.validateBatchArguments(batch: Self.batch("exec", #"{"cmd":"x"}"#))
        }
    }

    @Test("advertisement OpenAI envelope compatibility for every definition")
    func openAIEnvelopeCompatibility() throws {
        // Structural compatibility with the OpenAI function-tool shape,
        // checked WITHOUT any provider: a synthetic loopback that accepts
        // arbitrary tool JSON proves nothing about schema compatibility,
        // so every emitted envelope is asserted field by field here.
        // Interop pin: strict is EXPLICITLY false (strict mode requires
        // every property in `required`, which the XOR/alias/conditional
        // contracts cannot satisfy); generation is best-effort while
        // dispatch validation stays strict.
        let all = ToolCapabilities(
            read: true, search: true, edit: true, write: true,
            exec: .denied, consult: false)
        let definitions = ToolAdvertisement.definitions(for: all)
        #expect(definitions.count == 4)
        #expect(Set(definitions.map(\.name)) == ["read", "search", "edit", "write"])
        let envelopes = openAIToolEnvelopes(definitions)
        #expect(envelopes.count == 4)
        var sawPartialRequired = false
        for envelope in envelopes {
            #expect(envelope["type"] as? String == "function")
            let function = try #require(envelope["function"] as? [String: Any])
            let name = try #require(function["name"] as? String)
            #expect(!name.isEmpty)
            #expect((function["description"] as? String)?.isEmpty == false)
            let parameters = try #require(function["parameters"] as? [String: Any])
            #expect(parameters["type"] as? String == "object")
            #expect(parameters["additionalProperties"] as? Bool == false)
            let properties = try #require(parameters["properties"] as? [String: Any])
            #expect(!properties.isEmpty)
            let required = try #require(parameters["required"] as? [String])
            // Every required entry names a real property with a real type.
            for key in required {
                let prop = try #require(
                    properties[key] as? [String: Any],
                    "required key \(key) of \(name) must be a declared property")
                #expect((prop["type"] as? String)?.isEmpty == false)
            }
            // Every property is a typed schema object.
            for key in properties.keys {
                let prop = try #require(
                    properties[key] as? [String: Any],
                    "property \(key) of \(name) must be a schema object")
                #expect(["string", "integer", "number", "boolean", "array", "object"].contains(prop["type"] as? String ?? ""),
                        "property \(key) of \(name) carries a JSON Schema type")
            }
            // Strict is explicitly false: flipping it to true without
            // making every property required would ship an incompatible
            // contract to any strict-mode provider.
            #expect(function["strict"] as? Bool == false,
                    "\(name) must advertise strict:false (optional/XOR contracts are not strict-expressible)")
            if required.count < properties.count { sawPartialRequired = true }
        }
        // At least one definition has optional properties — the reason
        // strict:false is load-bearing, not cosmetic (read: all-optional
        // with a path/artifactId XOR; edit/write: alias + conditional keys).
        #expect(sawPartialRequired, "optional properties must exist, or strict:false is unjustified")
    }
}
