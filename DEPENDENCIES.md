# Dependency decisions and supply-chain contract

Baseline pins researched 11 October 2026; retained in v0.3 on 12 October 2026. GRDB and Markdown release availability rechecked; the complete graph is still unqualified. This is a **selection of published candidate versions**, not a fabricated resolved graph or a tested binary. M0 must resolve these exact candidates, retain the actual commit identities in `Package.resolved`, build them together and publish the native test results. If resolution fails, preserve the failure and propose the smallest explained adjustment.

## Selected direct dependencies

| Package | Candidate pin | Product/use | Decision |
|---|---|---|---|
| apple/swift-argument-parser | 1.8.2 | ArgumentParser | Use; command parsing is not product differentiation. |
| swift-server/async-http-client | 1.36.2 | AsyncHTTPClient | Use one transport on Linux and macOS, including streamed bodies and cancellation. |
| apple/swift-openapi-runtime | 1.13.0 | OpenAPIRuntime SSE sequences | Use its existing parser; no OpenAPI generator or generated full provider SDK. |
| swiftlang/swift-subprocess | 1.0.1 | Subprocess | Use streaming APIs and cancellation hooks; independently qualify process-group handling. |
| apple/swift-system | 1.8.1 | SystemPackage | Use descriptor/path primitives, not string-only confinement. |
| apple/swift-crypto | 5.0.0 | Crypto | Use SHA-256 for receipts and prompt/artifact fingerprints. |
| groue/GRDB.swift | 7.11.1 | GRDB | Use SQLite migrations and transactions; Linux support arrived in 7.10.0. |
| AmokHuginnsson/replxx | commit `1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2` | Vendored C/C++ code, C API bridge | Use for terminal editing; preserve upstream copyright and licence. |

Published-release evidence: [S02–S08]. Replxx's inspected head ref supplies the commit candidate [S09]. Selection is not a claim that the newest release is always the safest. The patch versions here are deliberately concrete inputs to qualification, not an instruction to track moving branches.

Subprocess 1.0.1 includes streamed-descriptor and descriptor-inheritance fixes. This is a reason to test 1.0.1 rather than silently copying an older README example using a 0.x version. GRDB's historical lack of Linux support must not be used to reject current releases without checking them. [S04, S07]

### What remains to verify at M0

Resolve compatibility of the **whole graph**, SDK deployment availability, each package's actual licence at the chosen revision, transitive native components, build plugins, binary size, build requirements and runtime linkage. SwiftPM package-manifest dependencies are not all necessarily linked into the shipped executable. Conversely, a short direct-dependency list says nothing about total native code.

Produce `dependency-inventory.json` with package URL, exact revision, version, licence, target/product, whether build-only or runtime-linked, binary contribution where measurable and vendored notices. Do not invent the transitive list in advance. Produce an SPDX or CycloneDX SBOM, including the native terminal code and any bundled SQLite or ripgrep binary.

Audit crypto/TLS duplication between Swift Crypto and NIOSSL. It is acceptable to use their established implementations; it is not acceptable to claim no native crypto dependency or replace SHA/TLS with handwritten code to win a package-count metric.

## Conditional M4 presentation package

**`swiftlang/swift-markdown` candidate 0.9.0**, product `Markdown`. Swift Package Index identifies 0.9.0 as the published release, and upstream describes a cmark-gfm-backed immutable markup tree [S24]. This is **not part of the M0 pinned graph**. Once M0–M3 viability is established, qualify its actual package graph, C/native linkage, build-time delta, final binary size and Linux/macOS behavior before selecting it for completed-block terminal rendering. Do not turn the renderer into an unpinned branch dependency. A small ANSI style-span writer remains ours; Markdown parsing does not.

No other production packages are authorized by UX/DX work. The PTY driver uses a **test-only** C shim and OS interfaces rather than a runtime terminal emulator library. Swift Testing remains toolchain-provided. `replxx` completion/highlighting/write/prompt hooks are present in upstream C API [S25]; asynchronous redraw in the proposed configuration remains an M0-C qualification requirement.

## Native and external components

**SQLite:** link the target OS SQLite when the declared distribution contract permits it, or include a pinned upstream amalgamation in the release build. Choose and document the actual path at M0. Do not add SQLCipher for v0.1. GRDB does not make the database encrypted by default.

**replxx:** vendor the selected source and licence, with a tiny reproducible build recipe or SwiftPM C/C++ target. Its C callbacks support file completion and input hints; its output API must be PTY-tested for output during an active composer, not assumed safe from its public names. Prefer the C boundary over making C++ interoperability part of the public Swift API. If CMake is needed to reproduce the upstream build, it is a build-time dependency only; do not download or run it at application startup. Qualify bracketed paste, Unicode, signal cleanup and streamed output on each native target. If integration fails, record the specific failure. A temporary plain input mode may support headless development, but it does not pass interactive-release acceptance.

**ripgrep:** required for the native `search` tool. An operator-provisioned version-checked executable is sufficient. An official release bundle may include a pinned binary and its notices. No auto-install, no arbitrary `rg` flags and no `RIPGREP_CONFIG_PATH` inheritance.

**git:** required for `/diff` and git-aware diagnostics, not for reading/writing an ordinary non-git directory. Use the provisioned executable; no libgit2 dependency. Missing git disables git-specific features with a clear explanation.

**OS/runtime:** libc, threading, SQLite linkage, C++ runtime, CA roots and Swift runtime/static-SDK linkage must be captured in the release manifest. “No Node” does not mean “no dependencies”.

## Deliberately not selected

| Alternative | Why not the core choice |
|---|---|
| Foundation URLSession / FoundationNetworking | A potential future size reduction, but this spec chooses one established server-side streamed transport rather than betting correctness on unqualified platform differences. Do not maintain both transports in v0.1. |
| MacPaw/OpenAI | Not dismissed as bloated: its manifest is relatively small. The unresolved question is lossless support for all required local dialect/continuation metadata, not dependency count. The core needs three native protocol adapters regardless. [S19] |
| AnyLanguageModel | Interesting unified model abstraction, but provider-native continuation fidelity and cache control must be proved before entrusting session persistence to an abstract conversation API. Not required for this small loop. [S20] |
| SwiftTUI | Its library target is not dependency-heavy. The reason to decline it is unnecessary full-screen/declarative UI scope, not a false bloat accusation. [S21] |
| Noora | Useful CLI design components, but a design system is not the required multiline streamed chat editor. Not needed alongside the chosen line editor. [S22] |
| JSONL as the only database | Human-readable, but durable operation state, transactions and migrations would become a custom storage subsystem. Export JSONL instead. |
| SwiftSyntax, tree-sitter, embeddings, vector databases | No built-in semantic-indexing project. Use an existing separately qualified service when needed. |
| A general agent framework | The owned state machine is the product. Importing orchestration semantics defeats the boundary. |
| A fork of an existing Swift coding agent | Useful reference, but its task DAG, recursive agents and injected reminders are outside this design. [S18] |

## Optional MCP, not a hidden core dependency

Use `modelcontextprotocol/swift-sdk` only in the separately enabled follow-on. Pin and qualify the version when that milestone begins; do not fabricate a future pin now. No handwritten MCP transport or protocol. An official SDK's documented protocol support must be negotiated with the server; “official” does not prove support for every newer spec. [S13–S14]

For selected MCP tools, validate their schemas using a maintained library rather than claiming that the core's five typed tool validators implement all JSON Schema. `ajevans99/swift-json-schema` is a research candidate, **not an approved v0.1 dependency**; review its non-macro validation target, compatibility and dependency graph at that milestone. [S23]

## Release rules

Use exact package candidates and a committed lockfile. Production builds may not track branch heads or resolve a new version implicitly. CI may explicitly fetch pinned sources during build; the released harness never resolves packages. No unreviewed build plugins or repository-local executable configuration. Required third-party notices travel with every release. Dependency updates are explicit PRs with the same streaming, persistence, process and packaging tests.

The first release must be runnable from a clean machine with no Node/npm/Bun/Python/Homebrew/Swift compiler. Project-specific tools used by the coding agent, such as a Python environment or Xcode, remain separately provisioned user tools; this is not a promise to build arbitrary projects without their toolchains.

## Linux-first qualification order (v0.3)

M0 resolves/builds/tests candidates on Linux x86_64 first. Do not replace a Linux-capable dependency with an Apple-only shortcut, or spend M0 implementing Keychain/macOS terminal paths. First macOS compilation/execution is M4; dependency minimum OS requirements are documented then, before advertising support. No earlier dual-platform phrase overrides this schedule.

Toolchain-provided Swift Testing, Foundation value types and a tiny in-repo scenario wrapper cover routine tests. No Cucumber, Gherkin, Quick/Nimble, snapshot framework, Python/Node test runner or property-testing framework is authorized by default. Add a package only after an ADR demonstrates a real unmet contract and measured total cost; package count alone is not the decision metric.

The development host may already have OpenCode and GitHub tooling. They are not Needletail runtime dependencies. Do not install npm/Bun to bootstrap the development workflow on a hardened appliance. Use the separately provisioned Linux builder, preserve existing Conda/toolchain environments and do not alter model-serving machines.
