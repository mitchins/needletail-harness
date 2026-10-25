// swift-tools-version:6.1
import PackageDescription

// Needletail v0.3 — dependency manifest.
//
// Pins are the DEPENDENCIES.md candidate set, resolved for real on Linux
// x86_64 and committed in Package.resolved. GRDB now links the
// NeedletailPrimitiveTests target: decision D-2 was resolved on
// 12 October 2026 when the operator installed libsqlite3-dev (3.45.1) on
// the builder, so the STORE-01 SQLite-reopen probe compiles and runs.
// replxx is NOT a package dependency (no Package.swift at revision
// 1f149bfe…); it is vendored at M0-C per DEPENDENCIES.md.

let package = Package(
    name: "needletail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "needletail", targets: ["NeedletailCLI"]),
        .library(name: "NeedletailCore", targets: ["NeedletailCore"]),
        .library(name: "NeedletailProviders", targets: ["NeedletailProviders"]),
        .library(name: "NeedletailRuntime", targets: ["NeedletailRuntime"]),
        .library(name: "NeedletailTestSupport", targets: ["NeedletailTestSupport"]),
        .library(name: "NeedletailPresentation", targets: ["NeedletailPresentation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.2"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.0"),
        // M1-C: NIOCore becomes a DIRECT edge (already resolved at 2.104.0
        // via AsyncHTTPClient — no version change) because bounded
        // incremental consumption names ByteBuffer/EventLoopFuture/NIODeadline.
        // No new package, no new code, no version churn; disclosed + reviewed.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "NeedletailCore",
            dependencies: []
        ),
        .target(
            name: "NeedletailProviders",
            dependencies: [
                "NeedletailCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "NeedletailRuntime",
            dependencies: [
                "NeedletailCore",
                .product(name: "SystemPackage", package: "swift-system"),
                // M2-A decision D-2 extension: the durable GRDB store lives
                // in Runtime (the I/O-bearing target). ImportGateTests keep
                // GRDB out of Core/CLI; the linkage activates with A1.
                .product(name: "GRDB", package: "GRDB.swift"),
                // A4-1: SHA-256 for artifact fingerprints. Pre-authorized
                // use (DEPENDENCIES.md): Core must not import Crypto, so
                // the digest lives in Runtime with the store that needs it.
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "NeedletailTestSupport",
            dependencies: [
                "NeedletailCore",
                // B3-A: InMemorySessionStore.publishArtifact needs SHA-256
                // (same swift-crypto edge as production targets; no new
                // resolved package).
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "NeedletailPresentation",
            dependencies: ["NeedletailCore"]
        ),
        .target(
            name: "CReplxx",
            dependencies: [],
            cSettings: [.headerSearchPath("replxx"), .headerSearchPath("include")],
            cxxSettings: [.headerSearchPath("replxx"), .headerSearchPath("include")]
        ),
        .target(
            name: "NeedletailLineEditor",
            dependencies: ["CReplxx"]
        ),
        .executableTarget(
            name: "NeedletailTypingProbe",
            dependencies: ["NeedletailLineEditor", "PTYShim"]
        ),
        .executableTarget(
            name: "NeedletailCLI",
            dependencies: [
                "NeedletailCore",
                "NeedletailRuntime",
                "NeedletailProviders",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                // B5-C: WorkspaceResolver pins execution roots via FilePath.
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(
            name: "BehaviourTests",
            dependencies: ["NeedletailCore", "NeedletailTestSupport"]
        ),
        .testTarget(
            name: "NeedletailPrimitiveTests",
            dependencies: [
                "NeedletailCore",
                "NeedletailTestSupport",
                // M2-A A0: native-tier reach for the production store — the
                // STORE certification tests must execute the real Runtime
                // store, and the ingestion tier map classifies this target.
                "NeedletailRuntime",
                // A5-1: CLI wiring evidence runs the real `needletail`
                // product binary. Depending on the executable target makes
                // `swift test` build it fresh first, so spawn-binary tests
                // can never pass against a stale binary (no silent
                // staleness; a missing binary still fails loudly).
                "NeedletailCLI",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                // GRDB was declared-but-unlinked while decision D-2 (SQLite
                // headers) was open. The operator installed libsqlite3-dev
                // on 12 October 2026; the STORE-01 reopen probe is linked.
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "PTYShim",
            path: "Tests/PTYShim"
        ),
        .testTarget(
            name: "NeedletailTerminalTests",
            dependencies: [
                "NeedletailCore",
                "NeedletailRuntime",
                "NeedletailLineEditor",
                "PTYShim",
            ]
        ),
        .testTarget(
            name: "NeedletailQualificationProbes",
            dependencies: ["NeedletailCore", "NeedletailTestSupport"]
        ),
        // M1-A: pure configuration/capability/profile suites (fast; joins
        // `./dev test quick`). No filesystem, environment, network or clock.
        .testTarget(
            name: "NeedletailConfigTests",
            dependencies: ["NeedletailCore"]
        ),
        // M1-B: pure transition/state/queue/budget/sealed/channel suites.
        .testTarget(
            name: "NeedletailStateTests",
            dependencies: ["NeedletailCore", "NeedletailTestSupport"]
        ),
        // M1-B: actor + scripted seams (fast, no I/O; layer=integration by
        // seam). Runs under `test case` + `test offline`, not quick.
        .testTarget(
            name: "NeedletailActorTests",
            dependencies: ["NeedletailCore", "NeedletailTestSupport"]
        ),
        // M1-B: pure reducer/render/golden suites (Crypto for golden
        // manifest hashes only — never in product targets).
        .testTarget(
            name: "NeedletailPresentationTests",
            dependencies: [
                "NeedletailPresentation",
                "NeedletailCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // M1-C: pure adapter mapping/assembly/bounds suites (fast; joins
        // `./dev test quick`). No sockets, no processes, no network.
        .testTarget(
            name: "NeedletailProviderTests",
            dependencies: [
                "NeedletailCore",
                "NeedletailProviders",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        // M1-C: loopback integration (synthetic endpoints, real HTTP over
        // POSIX loopback; runs under `./dev test case` + `test offline`).
        .testTarget(
            name: "NeedletailProviderIntegrationTests",
            dependencies: [
                "NeedletailCore",
                "NeedletailRuntime",
                "NeedletailProviders",
                "NeedletailTestSupport",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        // M1-A: spawn-binary + temp-filesystem integration (offline; runs
        // under `./dev test case <ID>` and `./dev test offline`, never quick).
        .testTarget(
            name: "NeedletailConfigIntegrationTests",
            dependencies: [
                "NeedletailCore",
                "NeedletailRuntime",
                "NeedletailProviders",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
    ]
)
