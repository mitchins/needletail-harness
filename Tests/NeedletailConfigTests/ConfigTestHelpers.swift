import Testing
import Foundation
import NeedletailCore

/// Shared builders for the M1-A pure suites. Every helper takes explicit
/// inputs and returns deterministic bytes; no filesystem, clock,
/// environment or network is touched here.
enum ConfigTestHelpers {

    static func modelJSON(
        alias: String = "local-coder",
        proto: String = "openai-chat-completions",
        base: String = "http://127.0.0.1:11434",
        model: String = "qwen2.5-coder-32b",
        locality: String = "local",
        credential: String = #"{"env":"NEEDLETAIL_M1A_KEY"}"#,
        options: String = #"{"temperature":0.2}"#
    ) -> String {
        """
        {"alias":"\(alias)","protocol":"\(proto)","base_url":"\(base)","model":"\(model)","context_window":262144,"max_output":4096,"locality":"\(locality)","credential":\(credential),"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1,"request_options":\(options)}
        """
    }

    static func configJSON(
        models: [String]? = nil,
        tools: String = #"{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}"#,
        version: String = "1",
        defaultModel: String = "local-coder",
        origins: String = #"["http://127.0.0.1:11434"]"#
    ) -> Data {
        let modelList = (models ?? [modelJSON()]).joined(separator: ",")
        return Data("""
        {"version":\(version),"default_model":"\(defaultModel)","allow_http_origins":\(origins),"models":[\(modelList)],"tools":\(tools)}
        """.utf8)
    }

    /// Runs the full M1-A validation pipeline on inline bytes.
    static func validate(_ text: String) throws -> ConfigSnapshot {
        try validateConfig(Data(text.utf8))
    }

    static func validateData(_ data: Data) throws -> ConfigSnapshot {
        try validateConfig(data)
    }

    /// Asserts the pipeline fails with the exact kind (and, when given, a
    /// path fragment). Returns the error for further inspection.
    @discardableResult
    static func expectFailure(
        _ data: Data,
        kind: ConfigError.Kind,
        pathFragment: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ConfigError {
        do {
            _ = try validateConfig(data)
        } catch let error as ConfigError {
            #expect(error.kind == kind, "expected \(kind), got \(error.kind): \(error)", sourceLocation: sourceLocation)
            if let fragment = pathFragment {
                #expect(error.path.contains(fragment), "path \(error.path) lacks \(fragment)", sourceLocation: sourceLocation)
            }
            return error
        } catch {
            Issue.record("expected ConfigError(\(kind)), got \(type(of: error)): \(error)", sourceLocation: sourceLocation)
            throw error
        }
        Issue.record("expected ConfigError(\(kind)) but validation passed", sourceLocation: sourceLocation)
        throw ConfigError(path: "$", kind: kind, message: "test harness: expected failure did not occur", hint: "fix the test")
    }
}
