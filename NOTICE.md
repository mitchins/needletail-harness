# Notices

Needletail original code is MIT licensed (see `LICENSE`). Third-party
components retain their own licences and notices; those notices travel with
every release (DEPENDENCIES.md release rules).

## Resolved direct dependencies (M0-B inventory)

Pins are the DEPENDENCIES.md candidate set; exact revisions are recorded in
`Package.resolved`. Licence identities below are the upstream licences as
declared by each project; the full inventory, including transitives, native
components and vendored code, is maintained in `dependency-inventory.json`
and re-verified before release (M0-D/M6).

| Package | Candidate | Upstream licence |
|---|---|---|
| apple/swift-argument-parser | 1.8.2 | Apache-2.0 |
| swift-server/async-http-client | 1.36.2 | Apache-2.0 |
| apple/swift-openapi-runtime | 1.13.0 | Apache-2.0 |
| swiftlang/swift-subprocess | 1.0.1 | Apache-2.0 |
| apple/swift-system | 1.8.1 | Apache-2.0 |
| apple/swift-crypto | 5.0.0 | Apache-2.0 |
| groue/GRDB.swift | 7.11.1 | MIT |

## Vendored / external components

- **replxx** is vendored as C++ source in `Sources/CReplxx/replxx/` (upstream
  commit `1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2`, licence in
  `Sources/CReplxx/replxx/LICENSE.md`). Only the bridge files are
  Needletail's: `shim.h`, `include/module.modulemap`, `README.provenance`,
  and `SHA256SUMS-vendored`. C++ runtime: the bundle links the system
  `libstdc++` (declared in the linkage manifest).

- **replxx** (candidate commit `1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2`) is
  vendored C/C++ source at M0-C with its BSD-style licence and copyright
  preserved. It is not a SwiftPM package dependency.
- **ripgrep** and **git** are operator-provisioned executables, never
  downloaded at runtime.
- **SQLite:** decision D-2 was resolved on 12 October 2026 (operator ruling):
  link the target OS SQLite (`libsqlite3-dev` 3.45.1-1ubuntu2.8 on the
  builder; runtime `libsqlite3-0` already present). GRDB links the
  NeedletailPrimitiveTests target and the STORE-01 reopen probe passes. A
  bundled pinned amalgamation remains an M6 packaging option to qualify.
- **Release runtime:** the M0-D bundle links the toolchain Swift runtime
  dynamically (static Swift stdlib failed to link on Swift 6.4.0 with
  `Synchronization._MutexHandle` undefined — a recorded toolchain finding);
  the bundle ships those libraries with a pure-shell launcher. Docker is a
  LOCAL qualification aid for the clean-host smoke only; it is not a
  product dependency and the harness never invokes it at runtime.
