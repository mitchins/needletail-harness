# M1-A plan — strict configuration, capabilities and immutable profiles

Slice type: M1-A (first M1 minor). Planning-only; **no implementation authorized by this document.**
Status: REV4 FOR TARGETED DELTA REVIEW (rev3 digest `99cbeff1…03e430` reviewed READY; this revision applies only the three authorized corrections A/B/C from the implementation authorization, see §14; full re-review not required).
Prepared: 13 October 2026.
Baseline: `main` at `e3c0527` (M0 squash `ffbc677` + ledger `9d14153`/`c8c3c4e` + STATUS `e3c0527`; matches `origin/main`).
Implementer route (actual, this session): `muse-spark-1.3-contributor` (Muse Spark; prior session ran `muse-spark-1.3-contributor-free` per F-5; Step 5 Preview Free path retained only as example, not claimed).
Reviewer (independent): `deepseek-reviewer` subagent (route resolved at review time from installed definition; read-only; no edits; no secrets copied).
Baseline evidence (executed 13 Oct, this session): `git status --porcelain` clean; `swift --version` 6.4 (swift-6.4-RELEASE, x86_64-unknown-linux-gnu); `Package.resolved` sha256 `de95226e…cc` (7394 bytes, GRDB-linked M0 graph); `./dev build` ok; `./dev test quick` 20/20 pass; `./dev coverage` reconciles (BDD suites green).

Normative sources: COMPLETE-SPEC.md §§ 5, 5.1–5.3, 10.1–10.3, 12 (`doctor`), MILESTONES M1-A, ACCEPTANCE CFG/NET/POLICY rows, DEVELOPMENT §§ 4–5, TESTING §§ 1–5/9, REVIEW §§ 1–2/4, DEPENDENCIES.md (no new packages).

## 1. Goal

Deliver the smallest pure, test-first configuration/capability/profile layer that M1-B can build the session state on — with **zero network, zero secret leakage, zero silent grants**:

- Strict versioned-JSON configuration with typed decoding, bounded inputs, duplicate-key rejection at every nesting level, unknown-field rejection, and actionable field-path errors.
- Pure deterministic capability-intersection function (denials dominate; `--sealed` / `--tools none` monotone).
- Immutable model-profile values with exact endpoint/model identity, explicit local-origin allow-listing, and epoch-snapshot semantics.
- Offline `doctor`/`--help` preserved; network probing explicitly deferred to a later `doctor --probe` operation (M1-C transport), not snuck into M1-A.
- Linux env-var + mode-0600 credential-file support planned; macOS Keychain **interface** preserved with **no macOS implementation** in M1-A.

What this slice is NOT: session state/actor (M1-B), wire adapters/SSE/transport (M1-C), headless JSONL loop (M1-D), any provider traffic, any discovery, any new package dependency, any macOS code (`Security`, `Darwin`), any YAML/templating/executable config, any M2+ tool/store/queue work.

Do not reimplement M0 or change its accepted contracts (`NeedletailVersion` canonical parsing, `CaseLedger` semantics, `Doctor` offline behaviour, replxx seam, transport red-green fixes at `df6dcc9`/`ffbc677`).

## 2. Baseline findings that constrain the plan

1. `schemas/config.schema.json` and `examples/config.local.json` (SPEC §5) **do not exist** in the repo at `e3c0527` (verified: no `*.schema.json` anywhere; repo root has no `schemas/` or `examples/`). M1-A **creates** them as reviewed contracts — this is new content, not a rewrite of M0.
2. `Sources/NeedletailCore` has one pure type (`NeedletailVersion`); `NeedletailProviders` has `ProviderIdentity` (`alias`, `nativeProtocol`, `locality`); `NeedletailRuntime` has `WorkspaceRoot`; `NeedletailCLI` has `NeedletailCLI` + offline `Doctor`. No config/capability/profile code exists — no behaviour to preserve, only gates (§8) to respect.
3. `Doctor` is offline by construction (no network imports; PATH lookup only). `--help`/`--version` are offline (ArgumentParser). M1-A must keep it that way and prove it (NET-06 offline variant).
4. M1 catalogue due: 45 cases. M1-A takes **10** (below). The other **35 are explicitly NOT in M1-A** (§9).

## 3. Strict configuration (SPEC §5)

### 3.1 Document shape (versioned JSON only)

```json
{
  "version": 1,
  "default_model": "local-coder",
  "allow_http_origins": ["http://127.0.0.1:11434"],
  "models": [
    {
      "alias": "local-coder",
      "protocol": "openai-chat-completions",
      "base_url": "http://127.0.0.1:11434",
      "model": "qwen2.5-coder-32b",
      "context_window": 262144,
      "max_output": 4096,
      "locality": "local",
      "credential": { "env": "NEEDLETAIL_LOCAL_KEY" },
      "connect_timeout_s": 10,
      "read_idle_timeout_s": 300,
      "request_timeout_s": 1800,
      "max_in_flight": 1,
      "request_options": { "temperature": 0.2 }
    }
  ],
  "tools": { "read": true, "search": true, "edit": true, "write": true, "exec": "ask", "consult": false }
}
```

- `version: 1` required, integer, exactly `1`. Missing/unknown version → field-path error `$.version`, no silent default (forward-compat: newer unsupported version opens read-only/fails actionable, never migrates silently — §9 DB rule applied to config).
- Top-level allow-list: `version`, `default_model`, `allow_http_origins`, `models`, `tools`. Anything else → `unknownField($.field)`.
- Model allow-list: `alias`, `protocol`, `base_url`, `model`, `context_window`, `max_output`, `locality`, `credential`, `connect_timeout_s`, `read_idle_timeout_s`, `request_timeout_s`, `max_in_flight`, `request_options`. Anything else → `unknownField($.models[i].field)`.
- `tools` allow-list: `read`, `search`, `edit`, `write`, `exec`, `consult`. Values: `true|false` for read/search/edit/write/consult; `exec` is `true|false|"ask"` (`"ask"` = headless approval-required; default `"ask"` when absent? No — absent means denied; explicitness over convenience. Decision: absent tool key = `false`/`denied`, recorded in diagnostics).
- Rejections (all before any provider request, exit 2): duplicate JSON keys at **every** nesting level (including inside `request_options`); duplicate `alias` (case-sensitive exact); duplicate exact `model` IDs **only when same `base_url`+`protocol`** (same served ID on two different endpoints is legal; same endpoint+protocol+ID twice is a duplicate); unknown structural fields; contradictory flags; malformed origins; negative/zero/out-of-range limits; reference to missing `default_model` alias; reserved `request_options` overrides.
- Limits (explicit, profile-adjustable later only via config edit, never silently enlarged):
  - File: **1 MiB** max (`$.fileTooLarge`). Enforced by **bounded read, not stat** (R6): reject non-regular files (`S_ISREG`, no FIFO/socket/device); read at most `1 MiB + 1` bytes; if a byte remains → `fileTooLarge`. A `/dev/zero` or concurrently-grown file therefore fails closed instead of OOM/hang. ACLs granting extra readers beyond mode bits are out of scope for the bit check — documented limitation; the check is `st_mode & 0o077 == 0` + `O_NOFOLLOW`, and the plan records that a permissive ACL is not detected (R6).
  - `request_options` serialized UTF-8: **64 KiB** max.
  - JSON nesting: **32 levels** max (scanner depth counter; deeper → `limitExceeded`).
  - `context_window`: 1..16_777_216; `max_output`: 1..131_072; timeouts: `connect` 1..120, `read_idle` 1..1800, `request` 1..1800 with invariant `connect ≤ read_idle ≤ request` (else `contradictoryLimits`); `max_in_flight`: 1..16.
  - `allow_http_origins`: 0..32 entries; each `scheme://host[:port]`, scheme `http` only for local (https allowed syntactically but local profiles should be http loopback/LAN; cloud origins constrained in M5 — M1-A records but does not route cloud).
- No YAML, no JS config, no templating, no env expansion inside JSON strings (except the `credential.env` **name** lookup at resolution time), no comments (strict JSON), no trailing garbage, no runtime package installation. A `.yaml`/`.js` path passed to `--config` → `unsupportedFormat` (extension + magic-byte check), not a parse attempt.
- Explicit user configuration only. Load order (first found wins, never merged):
  1. `--config PATH` (explicit; missing file → error, never fall through).
  2. `$XDG_CONFIG_HOME/needletail/config.json` or `~/.config/needletail/config.json`.
  3. No file → built-in **deny-all** defaults (zero models, all tools denied) + actionable `configNotFound` diagnostic. Never auto-load `./config.json`, `./.needletail.json`, repo `AGENTS.md`, or any workspace file as configuration.
- Opaque identities: `model` (served ID) is **String-only**. JSON number/bool/null for `model` or `alias` → `typeMismatch` (never coerce; `001234` stays `"001234"`, huge digit strings never become `Double`). Paths/aliases preserve Unicode exactly (no NFC/NFKC normalization); invalid UTF-8 path encoding → `unsupportedPathEncoding` (CFG-05).
- `request_options` namespace: inert operator-owned native JSON, frozen with the epoch. Value type `JSONValue` (string/number/bool/null/array/object, bounded as above; numbers kept as raw source bytes — no `Double` conversion, no `RawJSONNumber` framework type: the validated raw subtree bytes are retained verbatim alongside the typed value for deterministic re-serialization, cf. R3/R14). **Reserved keys rejected before serialization, never silently rewritten**: `model`, `messages`, `input`, `tools`, `tool_choice`, `parallel_tool_calls`, `stream`, `stream_options`, `system`, `history`, `auth`, `authorization`, `api_key`, `apikey`, `api-key`, `x-api-key`, `credentials`, `credential`, `bearer`, `cookie`, `password`, `passwd`, `proxy`, `base_url`, `url`, `endpoint`, `response_format` (harness-owned in checkpoint path), `store`, `metadata`. Match is **ASCII-case-insensitive with `-`/`_` collapsed** at the top level of `request_options` (R4: `API_KEY`, `Authorization`, `apiKey`, `X-Api-Key` all rejected); nested objects may use those names freely (they are not harness fields). Unknown **non-reserved** keys allowed but marked `unqualified: true` in the snapshot + `unqualifiedOption` warning (never guessed/injected/retried invisibly). Canonical serialization for epoch comparison and future requests: sorted keys, minimal escapes, UTF-8 — defined here so `Dictionary` ordering can never cause spurious epochs (R3).

### 3.2 Codec layer (small, owned, no new dependency)

Foundation `JSONDecoder` alone does **not** meet the duplicate/unknown-key contract. Layer:

1. **Bounded preflight** `scanJSONStructure(_ bytes: Data) throws -> Void` (pure, ~150 lines, no `Foundation.JSONSerialization` for key extraction — operates on UTF-8 bytes with a documented state machine: strings with escapes/`\u` **unescaped to scalar values before key comparison** (R1-risk/R13: `"\u0061lias"` equals `"alias"`; surrogate pairs `"\uD83D\uDE00"` decoded to the scalar before comparison so `{"\uD83D\uDE00":1,"😀":2}` is a duplicate), numbers, literals, structural chars, depth counter). Leading UTF-8 BOM is rejected with `unsupportedFormat(bom)` (explicit, R13). It records per-object key sets at every depth → `duplicateKey(path)`; rejects trailing garbage, premature EOF, depth > 32; measures the `request_options` subtree byte range for the 64 KiB check. It does **not** build a value tree (bounded memory: key stack + current-path only, never accumulates the whole document).
2. **Strict typed decode** via `Codable` with custom `init(from:)` that: rejects unknown keys explicitly (decode `DynamicKey` set, compare against allow-list → `unknownField`); validates ranges/formats with field paths (`models[1].context_window`); decodes `model`/`alias` as `String` only (numeric JSON → `typeMismatch`, no coercion); decodes `request_options` into `JSONValue` with raw-number preservation + reserved-key check + 64 KiB re-check on re-serialization.
3. All errors are `ConfigError` with `path`, `kind`, `message`, `hint` (e.g. `$.models[0].base_url: malformedOrigin — expected 'scheme://host[:port]', no credentials/query/fragment; fix: set "http://127.0.0.1:11434"`). Messages never include secret values (redaction §7).

## 4. Capability intersection (SPEC §10.1–10.3)

```swift
struct ToolCapabilities: Sendable, Equatable { var read, search, edit, write: Bool; var exec: ExecPolicy; var consult: Bool }
enum ExecPolicy: Sendable, Equatable { case denied, ask, allowed }
struct EffectiveCapabilities: Sendable, Equatable { var tools: ToolCapabilities; var route: RoutePolicy }
// R14-rev3: M1-A has no cloud routing — .configuredOrigins is deferred to M5;
// the case exists only as a documented future variant, never constructed in M1-A.
enum RoutePolicy: Sendable, Equatable { case none, localOnly }
```

Pure deterministic function, no filesystem/network/clock (takes all inputs as values):

```swift
// R8: exactly one value per SPEC §10.1 layer — the CLI tools flag is folded
// into invocationMask at argv-parse time, never a sixth parameter.
func effectiveCapabilities(build: ToolCapabilities, userConfig: ToolCapabilities,
    workspaceGrant: ToolCapabilities, invocationMask: ToolCapabilities,
    sealedRestrictions: SealedRestrictions) -> EffectiveCapabilities
// SealedRestrictions = { sealed: Bool } — no tool content, so last-wins is unrepresentable.
```

- Semantics: bitwise AND across all five layers for **tool capabilities** (`effectiveTools = build ∩ user ∩ workspace ∩ invocation ∩ sealedRestrictions`). No union, no last-flag-wins. Repository instructions/skills/tool outputs/model messages are **not parameters** — they cannot appear in the computation (enforced by signature; CFG-04/POLICY-05 tests attempt to smuggle them and assert unchanged output). **Route authorization is independent of tool intersection** (rev4-B): `selectRoute` takes the snapshot + requested alias + sealed flag and decides the route from profile locality/origin/allow-list alone — tool denial never denies a route and route denial never grants a tool.
- CLI folding rule (R8 + rev4-C + D4): conflict detection scans the **ordered raw argv directives before folding**; config-file values never participate (config + flag is always intersection, never contradiction). Only two explicit argv directives that disagree reject as `contradictoryFlags` (exit 2, both spellings quoted): `--sealed` + `--tools <anything-but-none>`; `--tools none` + `--tools <anything-but-none>`; `--tools X` + `--tools Y` (X≠Y). Identical repeats (`--sealed --sealed`, `--tools none --tools none`) are fine. Because disagreeing argv pairs reject on the raw tokens (not the folded masks — folding `--tools none --tools read` into `mask=read` would silently last-win), a later flag can never restore a removed capability — restoration is unrepresentable, and both flag orders reject identically (order-independence tests). §3.1's "contradictory flags" rejection means argv-only conflicts throughout.
- `--sealed` / `--tools none` monotone over tools only (rev4-B): `sealedRestrictions.sealed=true` forces `{all tools denied, consult denied}` regardless of other inputs but **does not prohibit an explicitly authorized model request** — a sealed, tool-free request to an approved local model is permitted (route allowed, tools none). `invocationMask==.none` likewise denies tools without touching the route. Cloud routing stays explicitly restricted (sealed or not: cloud → denied in M1-A). Config-vs-flag narrowing (e.g. config all-true + `--sealed`, config `exec:allowed` + `--tools none`) is allowed intersection, never `contradictoryFlags` (rev4-C supersedes the rev3 sentence that listed config+flag pairs as contradictions).
- Fail closed: unknown tool names, unknown `exec` strings, unsupported route/mode combos → error with the exact flag/field and the allowed vocabulary; never default-open.
- Diagnostics: on denial, report which layer denied which tool (`deniedBy: [workspaceGrant, invocationMask]`) without secrets.
- Provenance (R9): in M1-A `workspaceGrant` is constructed **only** from the explicit operator `trust` state default (deny-all until the M2 `trust` command exists) — never from parsed workspace/repo file content. A doc-comment on the parameter states the invariant, and a test asserts that feeding parsed `AGENTS.md` text into `workspaceGrant` construction is rejected (`untrustedSource`). The future `trust` command (M2) must gate its origin; recorded here so M1-B/M2 cannot silently source it from the workspace.

Session authorization vs provider capabilities vs per-request restrictions are **separate inputs** to the function (not conflated): `workspaceGrant` (operator trust action), `userConfig` (file), `invocationMask` (CLI), `sealedRestrictions` (request mode). Provider capability qualification (what the server proved) is **not** a grant — in M1-A it is uniformly `.unknown` (no `QualificationLabel` type; the probe that could establish otherwise arrives in M1-C); M1-A never uses it to enlarge grants.

## 5. Immutable model profiles (SPEC §5.1–5.3)

```swift
// R5: credential descriptor is exactly one kind — custom init rejects
// zero, two, or unknown keys ({"env":..,"file":..} → typeMismatch;
// {"env":..,"bogus":1} → unknownField($.models[i].credential.bogus)).
struct CredentialReference: Sendable, Equatable { enum Kind: Sendable, Equatable { case env(name: String), file(path: String), keychain(account: String) }; var kind: Kind }
struct ModelProfile: Sendable, Equatable { alias, proto: NativeProtocol, baseURL: URL, modelID: String, contextWindow, maxOutput: Int, locality: LocalityClass, credential: CredentialReference?, connectTimeout, readIdleTimeout, requestTimeout: Int, maxInFlight: Int, requestOptions: [String: JSONValue], requestOptionsRaw: Data, unqualifiedOptions: [String] }
struct ConfigSnapshot: Sendable, Equatable { version: Int; profiles: [String: ModelProfile] (keyed by alias); defaultAlias: String; allowHTTPOrigins: [String]; tools: ToolCapabilities }
// R14: no QualificationLabel in M1-A — qualification is uniformly .unknown
// until the M1-C probe exists; no RoutePolicy.configuredOrigins either
// (M1-A routes local-only or denies; cloud is denied, not routed).
struct ProfileSnapshot: Sendable, Equatable { profile: ModelProfile; effectiveCaps: EffectiveCapabilities }
```

- Unique aliases (case-sensitive); `default_model` must reference an existing alias.
- `base_url` (rev4-A): `scheme://host[:port][/path-prefix]` — an **explicit API path prefix such as `/v1` is allowed and preserved**. Grammar: scheme `http`/`https`; host (no userinfo — any `@` before the host → `malformedOrigin`); optional port; optional path prefix of one or more non-empty segments. Rejected: userinfo/credentials, query (`?`), fragment (`#`), whitespace/controls, backslash, empty segments (`//`), dot-segments (`.`/`..`, including percent-encoded forms in either case — `%2e`, `%2E`, and mixed `.%2e`/`%2e.` — segments are percent-decoded before comparison, so `/%2e%2e/evil` is a traversal), and a prefix that already ends with the protocol's endpoint suffix (`/chat/completions`, `/responses`, `/messages` — any of the three, regardless of the profile's own protocol, so a wrong impl cannot join a double suffix). One trailing slash is stripped for joining; anything else malformed → `malformedOrigin` with the offending part quoted. The adapter appends exactly one of `/chat/completions`, `/responses`, `/messages` to the stripped base (`base + suffix`, single `/` join) — the configured prefix is preserved verbatim, never duplicated, never guessed: `http://127.0.0.1:11434/v1` + chat → `http://127.0.0.1:11434/v1/chat/completions`. A wrong impl that unconditionally prepends `/v1` (`…/v1/v1/chat/completions`) or drops the prefix is a red-probe failure. Duplicate-model detection uses the normalized base (trailing slash stripped) + protocol + model ID.
- `allow_http_origins` entries are origins only (`scheme://host[:port]`, no path — a path in an entry → `malformedOrigin`). Origin comparison derives the origin from `base_url` by **discarding the path prefix** and comparing scheme+host+port (lowercased host, default-port normalized): a prefixed base never widens the origin (rev4-A: `http://h:11434/v1` matches entry `http://h:11434` but never `http://other:11434` or `http://h:9999`). Loopback/LAN HTTP requires exact entry match (no subdomain wildcard, no CIDR in M1-A). A local profile whose derived origin is not listed → `originNotAllowlisted` at load (fail closed), not at request time.
- `locality` is an operator trust assertion, not proof. No inheritance of proxy env (`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` ignored by construction — pure layer takes no environment; transport in M1-C must also ignore; NET-03 pure variant asserts the route decision is identical with hostile proxy env set).
- Snapshots stable through a request epoch: `ConfigSnapshot`/`ProfileSnapshot` are `let` values; `requiresNewEpoch(old:new:) -> Bool` returns true on any change to `alias-target`, `proto`, `baseURL`, `modelID`, `locality`, tool-set, or cache-relevant generation settings, comparing `requestOptionsRaw` bytes and origin strings (R3 — never `Dictionary` iteration order). M1-A implements the predicate + tests; M1-B owns the epoch transition that consumes it (R14: predicate lives here because the 10 cases need it; the transition stays M1-B).
- No implicit cloud fallback (NET-01): route decision `selectRoute(snapshot:requestedAlias:sealed:) -> Route` is pure — single canonical signature (R10; the `profile:` spelling elsewhere in this plan is superseded). The `sealed` parameter is outcome-inert by invariant (D3): it exists so call sites stay explicit, but the returned `Route` is byte-identical under `sealed ∈ {true,false}` for the same snapshot (pinned by an explicit test) — sealing is enforced tool-side in `effectiveCapabilities`, never route-side, so no future caller can mistake route selection for sealing enforcement. Sealed + approved local → allowed (tool-free); sealed or unsealed + cloud → denied. M1-A rule: any request naming a `locality==.cloud` profile, or any cloud selection under a local-only snapshot, → `.denied(localOnlyViolation)` with no alternate-provider retry, no network effect (assert via forbidden-effect probes: no socket, no DNS, no file write). Cloud **allowed-decisions** do not exist in M1-A; they arrive with transport in M1-C. `default_model` and `locality` are required fields (R13: missing either → `missingField` with path); an empty `models: []` with deny-all tools is the only valid tool-less shape. Endpoint construction: `endpointURL(for:)` = stripped base + protocol suffix (rev4-A); tests assert prefix preservation and single-suffix join.
- Credential references only (CFG-03): config stores `{env|file|keychain}` descriptors, never secret values. Resolution (`resolveCredential(_:for:)`) is a **separate** explicit call taking the operation as a parameter, reading at most one variable/file, asserting `0600` (owner-only; group/other bits → `insecurePermissions` unless the operator passes an explicit override flag — default fail closed), never placing the value in child environments/argv/logs/exports. Keychain: define `CredentialStore` protocol + `EnvFileCredentialStore` (Linux, M1-A) + `KeychainCredentialStore` **protocol conformance stub that throws `.unsupportedOnLinux`** (no `Security` import; preserves the interface requirement without macOS implementation).

## 6. Offline inspection (SPEC I01, ACCEPTANCE NET-06)

- `--help`/`--version`/`config validate`/`doctor` (no args) perform **zero** network I/O (no imports of HTTP client in those paths; architecture gate test asserts `NeedletailCore` imports no HTTP/SQLite/terminal — extend existing gate to new files).
- `doctor` gains only: config-load diagnostics (always redacted — no `--redacted` flag; redacted is the only safe default, R14), executable presence (existing), and a `--probe MODEL` **argument recognizer** that in M1-A validates the alias/route purely and then reports `probeDeferredToM1C` with **exit 4** (R11: deliberate reuse of the provider/protocol-failure code documented here because SPEC §12.2 provides no deferral code; the output states `deferred, not failed — traffic arrives in M1-C`). Full synthetic bounded-input probing is **M1-C** work (transport + deadlines + redaction). NET-06 is therefore **partial in M1-A (offline half only)** and must be counted as such in `./dev coverage` — the traffic half stays `DEFERRED_BY_PLAN`, never claimed satisfied (R11). This satisfies NET-06's offline variant in M1-A without premature network code; the plan explicitly forbids adding `AsyncHTTPClient` usage to the CLI in M1-A.
- Linux env-var + mode-0600 file support designed now (above); Keychain interface without implementation (above).

## 7. Behaviour-first acceptance (10 cases; one passing variant never satisfies all variants)

Conventions: each case lists **semantic variants** (different obligations, each needs its own test), Given/When/Then, forbidden effects, evidence layer (pure = no FS/network/clock/env; integration = temp-file/PATH only, still no network), fixture boundary, and red/green expectation. IDs are the stable catalogue IDs; variant IDs are stable kebab-case.

### CFG-01 — duplicate model IDs and duplicate JSON keys, including nested keys (pure + integration)

- Variants (8): `top-dup-key`; `nested-dup-key`; `deep-dup-key`; `unicode-escape-dup` (`"\u0061lias"` vs `"alias"`); `surrogate-dup` (emoji literal vs `\uD83D\uDE00`); `dup-alias`; `dup-endpoint-model`; `case-sensitive-alias-ok` (`"A"` vs `"a"` distinct, accepted).
- G/W/T (representative): Given a config file with `models[0]` containing `"alias"` twice, When `config validate` loads it, Then exit 2 with `duplicateKey($.models[0].alias)` and no provider request.
- Forbidden: any network, any partial profile construction, any silent first-wins/last-wins.
- Evidence: pure (byte-string inputs to `scanJSONStructure` + `decodeConfig`) for all variants; one integration (`./dev test case CFG-01` via temp file) proving file path → same error.
- Red: pre-M1-A decoder (Foundation only) accepts duplicates (demonstrate with a no-op/wrong impl probe); green: new codec rejects each variant with the exact path.

### CFG-02 — unknown field, bad numeric limit, missing alias reference (pure + integration)

- Variants (24): `unknown-top/model/tools-field`; `bad-limit-negative/zero/order`; `missing-alias` (`default_model:"ghost"`); `missing-default_model`; `missing-locality`; `bad-version` (`99`, `"1"`); `bom-rejected`; `base-prefix-preserved` (`…:11434/v1` → endpoint `…/v1/chat/completions`); `no-dup-v1` (unconditional-`/v1`-prepend probe → `/v1/v1/…` caught); `base-prefix-already-suffix-rejected` (D1: base ending in `/chat/completions`, `/responses`, or `/messages` → `malformedOrigin`, no double-suffix join); `base-traversal-rejected` (`/v1/../evil`); `base-encoded-traversal-rejected` (D2: `/%2e%2e/evil`, `/%2E%2E/evil`, `/mixed.%2e/x` → `malformedOrigin`); `base-empty-segment-rejected` (D2: `//v1`); `base-backslash-rejected` (D2); `base-fragment-rejected` (D2); `base-whitespace-rejected` (D2); `base-query-rejected`; `base-credentials-rejected` (`user:pass@host`); `origin-derived-from-prefixed-base` (prefix matches origin-only entry; other host/port rejected); `origin-default-port-equality` (D2: entry `http://h` ≡ base `http://h:80`; `http://h:81` rejected).
- G/W/T: Given `{"version":1,…,"zzz":1}`, When validated, Then `unknownField($.zzz)` with allowed-vocabulary hint.
- Forbidden: silent ignore, default substitution, any request.
- Evidence: pure table tests (each variant its own assertion, not one mega-test); integration via `config validate` exit codes.
- Red: current code has no config loader (missing → not silent pass); wrong-impl probe (lenient decoder ignoring unknown keys) must fail the new oracle.

### CFG-03 — credential in env/file/Keychain (pure + integration)

- Variants: `env-present` (value resolved for the named operation only); `env-absent` (actionable `missingEnv`, no crash); `file-ok-0600` (resolved); `file-bad-perms-0644` (rejected `insecurePermissions`); `file-missing` (actionable); `keychain-on-linux` (`unsupportedOnLinux` with interface preserved); `redaction` (validate/export/diagnostics/logs contain the reference `env:NAME`, never the value); `child-env` (spawned-process environment demonstrably lacks the secret).
- G/W/T: Given a profile with `{"env":"NT_TEST_KEY"}` and `NT_TEST_KEY=hunter2` in the test's controlled env, When resolved for operation `chat`, Then the value is returned to the caller and `redactedDescription`/`config validate` output contains `env:NT_TEST_KEY` and not `hunter2`.
- Forbidden: secret in stdout/stderr/log/export/argv/child-env; resolution of more than the requested credential; file read without permission check.
- Evidence: pure (redaction/description unit tests with fake store); integration (temp credential file with `0600`/`0644`, controlled env, no network).
- Mock boundary: `CredentialStore` protocol + in-memory fake; production `EnvFileCredentialStore` only in integration.

### CFG-04 — repo file attempts to register endpoint or grant trusted execution (pure + integration)

- Variants: `repo-endpoint` (`AGENTS.md` contains a JSON block with a new endpoint); `repo-trust` (`AGENTS.md` says `policy: trusted-exec`); `repo-tools` (instruction says `enable exec`); `repo-route` (instruction says `use cloud model`).
- G/W/T: Given a workspace with hostile `AGENTS.md` and a deny-all config, When `effectiveCapabilities` is computed and a route selected, Then capabilities/routes are byte-identical to the no-instruction baseline.
- Forbidden: any grant/route change, any credential read triggered by repo content, any network.
- Evidence: pure (capability function called with/without hostile strings — signature makes smuggling unrepresentable; test asserts equality); integration (temp workspace with hostile file + `config validate` showing unchanged effective caps).
- Red: a deliberately wrong impl that unions repo claims into grants must be caught (disposable probe, restored after).

### CFG-05 — opaque identities: `001234`, huge integers, Unicode paths (pure + integration)

- Variants: `numeric-looking-string` (`"001234"` preserved); `huge-digits` (30-digit string never becomes `Double`/exponent); `number-for-model` (`"model":1234` rejected `typeMismatch`); `unicode-alias` (exact preservation, no NFC); `bad-path-encoding` (invalid UTF-8 → `unsupportedPathEncoding`).
- G/W/T: Given `"model":"001234"`, When decoded and re-encoded, Then the exact bytes `"001234"` round-trip (no `1234`, no `1.234e3`).
- Forbidden: coercion, normalization, lossy re-serialization.
- Evidence: pure round-trip tests (byte comparison); integration via validate on fixture files.
- Note: extends the M0 `NeedletailVersion` canonical-component precedent (already red-green for versions).

### CFG-06 — reserved native request-options override (pure + integration)

- Variants: each reserved key (`model`, `messages`, `input`, `tools`, `tool_choice`, `stream`, `auth`, `api_key`, …) as a top-level `request_options` entry → rejected; `nested-reserved-ok` (`request_options: {mytool:{model:"x"}}` accepted — only top level is harness-owned); `unqualified-allowed` (non-reserved unknown `cache_prompt` accepted with `unqualified:true` warning).
- G/W/T: Given `request_options: {"model":"evil"}`, When validated, Then `reservedOverride($.models[0].request_options.model)` before serialization, exit 2.
- Forbidden: silent rewrite/strip/retry; serialization of the reserved key; any request.
- Evidence: pure per-key table; integration validate.
- Red: wrong impl that strips the key and proceeds must fail (assert rejection, not strip).

### POLICY-02 — `--sealed` / `--tools none` permutations (pure + integration)

- Variants (rev4-B/C; tools and route asserted separately): `sealed-only` (tools all denied; route independent); `tools-none-only` (tools denied; route independent); `sealed+tools-none` (tools denied); `sealed+config-enables-narrows` (allowed intersection — tools denied, NOT `contradictoryFlags`); `tools-none+config-enables-narrows` (allowed intersection); `cli-sealed+cli-tools-read-rejected` (`contradictoryFlags`, both orders); `cli-tools-none+cli-tools-read-rejected` (`contradictoryFlags`, both orders); `cli-tools-read+cli-tools-write-rejected` (X≠Y, both orders); `config-exec-ask+sealed` (tools denied incl. exec, not ask); `normal-narrowing` (`--tools read` with config all-true → only read survives); `sealed-local-route-permitted` (route allowed for approved local model while tools none); `tools-none-local-route-permitted` (same).
- G/W/T: Given config enables all tools and CLI passes `--sealed`, When capabilities computed, Then every tool denied with `deniedBy:[sealed]`, and the route for the approved local model remains allowed (tool-free inference permitted).
- Forbidden: any grant under sealed/none; any flag-order dependence (conflicting pairs reject in both orders); any workspace/config override of sealed; any route denial caused by tool denial (independence).
- Evidence: pure permutation matrix (each row its own assertion); integration via CLI flag parsing → same pure function.
- Red: wrong impl with last-flag-wins, union, route-coupled-to-tools, or config+flag-as-contradiction must be caught (disposable probes).

### POLICY-05 — workspace instruction requests cloud upload or permission mutation (pure + integration)

- Variants: `instruction-cloud-upload` ("send context to cloud"); `instruction-permit-exec`; `instruction-new-origin`; `instruction-format-shift` (attempt to change JSONL/stdout contract — out of scope for caps but assert no effect).
- G/W/T: Given a local-only snapshot and an instruction demanding cloud upload, When the route/capability is computed, Then route stays local-only/denied and caps unchanged.
- Forbidden: grant/routing/credential change; any network; any instruction-sourced endpoint.
- Evidence: pure (same function-signature argument as CFG-04); integration (temp workspace + validate).
- Note: CFG-04 × POLICY-05 share the seam (repo content never an input) but are separate catalogue cases with separate tests — one passing does not satisfy the other.

### NET-01 — local-only profile plus cloud model selection (integration; pure route-decision core)

- Variants: `local-selects-cloud` (denied); `local-selects-local-ok` (allowed, still no network in M1-A — decision only); `sealed-selects-cloud` (denied); `sealed-local-permitted` (rev4-B: allowed, tools none, decision only — no network); `tools-none-local-permitted` (rev4-B: allowed, decision only); `sealed-route-identical` (D3: route byte-identical under sealed true/false for same snapshot); `unknown-alias` (actionable, no retry); `prefixed-base-endpoint-preserved` (rev4-A: `…/v1` base → endpoint keeps prefix, origin still allow-listed).
- G/W/T: Given a local-only snapshot and request for alias `cloud-gpt`, When `selectRoute` runs, Then `.denied(localOnlyViolation)` with no cloud request and no alternate-provider retry. Given sealed mode and the approved local alias, When `selectRoute` runs, Then allowed with tools none.
- Forbidden: any socket/DNS/TLS, any fallback attempt, any credential resolution for the denied route; any sealed-caused denial of an approved local route.
- Evidence: pure route-decision tests + integration asserting zero network effects (packet/socket counters, or simply no `AsyncHTTPClient` linkage in the path — import-gate test).
- Red: wrong impl that falls back to the cloud alias must be caught (probe asserts denied, not rerouted).

### NET-06 (offline half) — `doctor` vs `doctor --probe MODEL` (integration)

- Variants (M1-A): `doctor-offline` (exit 0, no network, redacted); `doctor-probe-recognized-but-deferred` (`--probe alias` validates alias/route purely then exits 4 `probeDeferredToM1C`); `doctor-probe-unknown-alias` (exit 2, no network).
- G/W/T: Given no network (blocked loopback in test), When `doctor` runs, Then it succeeds with zero connection attempts. When `doctor --probe local-coder` runs in M1-A, Then it reports the validated route and `probeDeferredToM1C`, still with zero connection attempts.
- Forbidden: any DNS/socket/TLS in either path; any real-model traffic; any secret in output.
- Evidence: integration (run `needletail doctor` / `--probe` under assertions + network-effect probes); full synthetic-probe traffic variants explicitly deferred to M1-C (recorded as `DEFERRED_BY_PLAN` for the traffic half, not claimed now).
- Mock boundary: no mock server in M1-A (that would be traffic); assert absence of traffic instead.

## 8. Architecture and implementation plan (no code in this slice)

### Proposed Swift types and file boundaries (all `Sendable` value types unless noted)

| File | Types / functions | Notes |
|---|---|---|
| `Sources/NeedletailCore/ConfigDocument.swift` | `ConfigDocument`, `ConfigModel`, `ConfigTools`, `CredentialDescriptor`, `JSONValue` (raw bytes retained, no `RawJSONNumber` type — R14) | `Codable` with strict custom `init`; no I/O |
| `Sources/NeedletailCore/ConfigLimits.swift` | `ConfigBounds` (1 MiB / 64 KiB / 32 levels / numeric ranges), `checkBounds` | Pure constants + checks |
| `Sources/NeedletailCore/ConfigDuplicatePreflight.swift` | `scanJSONStructure(_:)`, `DuplicateKeyError` | Bounded byte scanner; no value tree |
| `Sources/NeedletailCore/ConfigError.swift` | `ConfigError(path:kind:message:hint:)`, `ConfigErrorKind` | `path` like `$.models[1].context_window`; redacted `description` |
| `Sources/NeedletailCore/ConfigLoader.swift` | `loadConfig(from: Data, origin:)`, `validateConfig(_:) -> ConfigSnapshot` | Pure `Data`→snapshot; file read stays in CLI |
| `Sources/NeedletailCore/ModelProfile.swift` | `ModelProfile`, `ConfigSnapshot`, `ProfileSnapshot`, `requiresNewEpoch(old:new:)` | Immutable; `let`-only |
| `Sources/NeedletailCore/Capabilities.swift` | `ToolCapabilities`, `ExecPolicy`, `EffectiveCapabilities`, `RoutePolicy`, `effectiveCapabilities(…)` | Pure, no env/FS/net |
| `Sources/NeedletailCore/RouteDecision.swift` | `selectRoute(snapshot:requestedAlias:sealed:)`, `endpointURL(for:)`, `Route`, `RouteDenial` | Pure; no transport; endpoint join preserves prefix, single suffix (rev4-A); sealed never alters route outcome (rev4-B) |
| `Sources/NeedletailCore/CredentialReference.swift` | `CredentialReference`, `CredentialStore` protocol, `CredentialError` | Protocol only in Core |
| `Sources/NeedletailRuntime/EnvFileCredentialStore.swift` | `EnvFileCredentialStore: CredentialStore` | `0600` check, redaction; Linux M1-A |
| `Sources/NeedletailRuntime/KeychainCredentialStore.swift` | `KeychainCredentialStore: CredentialStore` (stub) | Throws `unsupportedOnLinux`; no `Security` import |
| `Sources/NeedletailProviders/LocalChatProfile.swift` | `validateLocalChatProfile(_:)` (origin/protocol/locality/request-option checks) | No HTTP; pure validation of the first local Chat Completions shape |
| `Sources/NeedletailCLI/ConfigValidate.swift` | `config validate --config PATH` (always redacted, no opt-out) | Bounded-read gate, loader call, redacted diagnostics, exit 2/0 |
| `Sources/NeedletailCLI/DoctorProbe.swift` | `doctor --probe` argument path | Pure validation + `probeDeferredToM1C`; no client |
| `schemas/config.schema.json` | JSON Schema for editors only | Informative; **not** the validator (validator is the Swift codec above) |
| `examples/config.local.json` | Minimal local-only example | Synthetic identities, marked example |

Prefer value types + pure functions; no DI framework (one `CredentialStore` protocol is the only seam, already justified by the Keychain/Linux split); no registries; no custom JSON framework (Foundation `Codable` + one bounded scanner); no premature provider abstraction (only `NativeProtocol`/`LocalityClass` already in `ProviderIdentity` + one local-profile validator).

Integration seam (R2-rev3): `NeedletailCLI` is an `executableTarget` and cannot be imported by tests. M1-A integration variants therefore **spawn the built `needletail` binary** via the already-resolved package dependency `swift-subprocess` streaming API in the test target (no new dependency; readiness via exit code, no sleeps). Pure variants call the Core functions directly. `Package.swift` gains a `NeedletailConfigTests` test target (deps: `NeedletailCore`, `NeedletailTestSupport`, `NeedletailRuntime`, `NeedletailProviders`, `Subprocess` — Runtime/Providers included because CFG-03 file-permission integration exercises `EnvFileCredentialStore` and local-chat shape checks); `NeedletailCLI` gains deps on `NeedletailProviders` + `NeedletailRuntime` only if its new files import them — otherwise ConfigValidate/DoctorProbe stay Core-only (no layering change). Layering (Providers→Core preserved): syntactic origin validation (`scheme://host[:port]`, no credentials/query/fragment) lives in the Core loader and runs at load; `validateLocalChatProfile(_:)` in Providers checks only the Chat Completions shape (protocol/locality/timeout ordering) by calling Core's pure predicates — no duplication, no Core→Providers inversion.

### Error taxonomy (exit codes per SPEC §12.2)

- Exit `2`: all config/flag/route-denial-at-load failures (`duplicateKey`, `unknownField`, `typeMismatch`, `limitExceeded`, `malformedOrigin`, `originNotAllowlisted`, `reservedOverride`, `missingReference`, `contradictoryFlags`, `unsupportedCombination`, `unsupportedFormat`, `configNotFound`).
- Exit `3`: headless approval-required (defined for M1-B consumption; M1-A only defines the `ask` value, never triggers it).
- Exit `4`: provider/protocol failure — used in M1-A **only** for `probeDeferredToM1C` (no real provider failure possible without transport).
- All errors carry `path`, `kind`, `message`, `hint`; never include secret values, file bytes beyond the offending key path, or stack traces in user output.

### Configuration precedence (explicit, never merged)

`--config PATH` > user-default location > deny-all built-ins. Within one file: no deep-merge, no environment overlay (except credential **resolution**, not config mutation), no workspace contribution. CLI flags (`--sealed`, `--tools`, `--model`) only **narrow**; narrowing to zero is legal, widening is unrepresentable (no flag adds a model/origin/grant).

### Immutable snapshot semantics

`ConfigSnapshot` is built once per process start (or `config validate` run) and shared by value. `ProfileSnapshot` pairs one profile with its effective caps (no qualification label in M1-A — uniformly unknown until the M1-C probe). Epoch rule: any `requiresNewEpoch==true` difference needs a subsequent epoch transition (M1-B); M1-A tests the predicate across every field (including `requestOptionsRaw` byte-equality and origin-string equality).

### Sensitive-data redaction

`redactedDescription` on all config/profile/credential/error types prints references (`env:NAME`, `file:/path`, `keychain:account`) and `base_url` origins but never secret values and never file contents. `request_options` values are **redacted by default in all diagnostics** (R12: the prior `token|secret|key|auth` containment heuristic had gaps — `password`, `passwd`, `bearer`, `cookie`, `session`, `credential` all escaped it); `config validate` prints types/shapes and the `unqualified` flags, not values. Error bodies are bounded and redacted. Tests plant canaries (`hunter2-bearer`, `cookie-canary`, `passwd-canary`, …) in env/file/request_options and assert absence on every diagnostic path.

### Connection to M1-B

M1-B imports `ConfigSnapshot`, `ProfileSnapshot`, `EffectiveCapabilities` as **constructor inputs** to `SessionState.init(snapshot:capabilities:…)`; the transition function treats them as immutable epoch fields (no setter, no mutation event). This plan defines those types and their purity; M1-B defines the state machine that holds them. No `SessionState`/`SessionActor` code in M1-A.

## 9. Anticipated test list and execution commands (write before implementation)

New suite `Tests/NeedletailConfigTests/` (pure Swift Testing, `≤3 s` warm; temp-file integration in the same target but tagged `integration`, still offline):

| # | Test (display name starts with case ID) | Variants | Layer |
|---|---|---|---|
| 1 | `CFG-01 duplicate keys and aliases rejected` | 8: `top-dup-key`, `nested-dup-key`, `deep-dup-key`, `unicode-escape-dup` (`\u0061lias` vs `alias`), `surrogate-dup` (literal vs `\uD83D\uDE00`), `dup-alias`, `dup-endpoint-model`, `case-sensitive-alias-ok` | pure (+1 binary-spawn integration) |
| 2 | `CFG-02 unknown fields, limits, references, base URLs rejected` | 24 (§7: prior 11 + `base-prefix-preserved`, `no-dup-v1`, `base-prefix-already-suffix-rejected` (D1), `base-traversal/encoded-traversal/empty-segment/backslash/fragment/whitespace/query/credentials-rejected` (D2), `origin-derived-from-prefixed-base`, `origin-default-port-equality` (D2)) | pure (+spawn integration) |
| 3 | `CFG-03 credential references resolve and redact` | 8 (4 pure + 4 integration) + `two-kinds-rejected`, `unknown-cred-key-rejected` (R5) | pure+integration |
| 4 | `CFG-04 repo files cannot grant or route` | 4 | pure+integration (spawn) |
| 5 | `CFG-05 opaque identities preserved` | 6: prior 5 + `number-for-model-rejected` round-trip with raw bytes | pure |
| 6 | `CFG-06 reserved request-options rejected` | per-key table incl. `API_KEY`, `Authorization`, `apiKey`, `X-Api-Key` case variants (R4) + `nested-reserved-ok` + `unqualified-allowed` | pure |
| 7 | `POLICY-02 sealed and tools-none never grant (tools/route independent)` | 12-row matrix (§7 rev4-B/C: config-narrows-allowed ×2, cli-conflict rejections ×3 pairs both orders, sealed/tools-none-local-route-permitted ×2) | pure+integration (spawn) |
| 8 | `POLICY-05 workspace instructions change nothing` | 4 | pure+integration (spawn) |
| 9 | `NET-01 local-only denies cloud with no fallback` | 8 (§7 + `sealed-route-identical` (D3)) | pure+integration |
| 10 | `NET-06 doctor offline; probe deferred without traffic (PARTIAL — traffic half deferred to M1-C)` | 3 | integration (spawn) |
| 11 | `ARCH-import-gate: Core imports no HTTP/SQLite/terminal (PORT-02 method precursor, non-gate)` | 1 static import-gate | pure tooling — display name deliberately does NOT begin with a catalogue ID so `./dev test case PORT-02` cannot match it and `./dev coverage` keeps PORT-02 `DEFERRED_BY_PLAN` for M1-B (R1-rev3) |
| 12 | `Disposable wrong-impl probes (BDD-06 evidence method, NOT a case claim — R1/R7)` | 4 temporary production patches (union-grant, last-wins, strip-reserved, cloud-fallback), each with RED log on the real production function then baseline restore | pure (review evidence; BDD-06 itself stays M1-B) |

Wrong-impl probe mechanism (R7): each probe is a **temporary patch to the production file** (guard removed), `git stash`-free — copy, patch, run the §9 oracle, retain RED output, restore byte-identical baseline (`git diff` clean after). A test-local reimplementation never counts as a probe. Coercion probe (`001234`→`1234`) included.

Commands (existing workflow + R2 seam):

```sh
./dev build                          # builds needletail binary used by spawn-integration
./dev test quick                     # BehaviourTests + NeedletailPrimitiveTests + NeedletailConfigTests(pure-only filter)
./dev test case CFG-01               # per-case deterministic variants (each of the 10; spawn variants included)
./dev test case CFG-02
./dev test case CFG-03
./dev test case CFG-04
./dev test case CFG-05
./dev test case CFG-06
./dev test case POLICY-02
./dev test case POLICY-05
./dev test case NET-01
./dev test case NET-06
./dev coverage                       # reconcile: 9 cases (pure+offline variants) + NET-06 PARTIAL; traffic halves + 35 M1 cases DEFERRED_BY_PLAN
```

Red-before/green-after: for each case, first land the test on the pre-M1-A baseline (no loader → actionable `notImplemented`, or a disposable wrong impl → caught), retain the RED log, then implement and retain the GREEN log. Missing/skipped/unexecuted never counts as pass (BDD-03/04 machinery reused).

## 10. Explicit allocation of remaining M1 cases (not M1-A)

| Slice | Cases | Reason |
|---|---|---|
| M1-B | CORE-02, CORE-03, CORE-04, POLICY-03, POLICY-04, STATE-01, STATE-04, PORT-02, BDD-06, BDD-08, DX-01, DX-02, DX-03, DX-06, DX-07 | Needs SessionState/actor/reducer contracts this slice deliberately does not build |
| M1-C | WIRE-01..WIRE-10, NET-02, NET-03, NET-04, NET-05, NET-06 (traffic half), DX-04, DX-05 | Needs transport/SSE/deadlines this slice forbids |
| M1-D | CORE-01, HEAD-01, HEAD-02, HEAD-03 | Needs composed headless loop over B+C |

No M1-A test claims these; `./dev coverage` must still show them `DEFERRED_BY_PLAN`.

## 11. Risks and open questions for the reviewer (rev2 answers to rev1 findings in §13)

1. Scanner: `\u`-unescaping + surrogate decoding specified (§3.2); BOM rejected. Surrogate-vs-literal duplicate covered by test.
2. Contradictory flags: reject chosen for explicit CLI-vs-CLI; narrowing intersects downward. Documented in §4.
3. `RawJSONNumber` removed (R14) — raw subtree bytes retained instead; no framework type.
4. Permissions: bounded read + `S_ISREG` + `O_NOFOLLOW`; ACL limitation documented as out of scope (R6).
5. NET-06 explicitly partial (R11); traffic half deferred to M1-C, counted as such.

## 12. Stop condition

M1-A planning is done when: this plan has an independent DeepSeek **plan-review disposition** (READY / NEEDS-EVIDENCE / BLOCKED with findings), valid findings are folded into a revision with its digest recorded, `STATUS.md` shows **M1-A PLAN REVIEWED** (not implemented), and no M1-A production/test code has been written. Implementation waits for its own authorization.

## 13. Revision log (rev1 → rev2; reviewer M1A-R1..R15, NEEDS-EVIDENCE)

- R1 (Major): §9 tests 11–12 fixed — test 11 is now `PORT-02 (partial, pure)` non-gate tooling (not counted as satisfaction; PORT-02 itself stays M1-B); test 12 is disposable-probe evidence method, not a BDD-06 claim (BDD-06 stays M1-B). Case counts: 9 full + NET-06 partial.
- R2 (Major): integration seam specified (spawn built binary via vendored `swift-subprocess`); `Package.swift` + `./dev test quick` filter changes required before implementation.
- R3 (Major): deterministic `request_options` — raw bytes + canonical sorted-keys serialization; `requiresNewEpoch` compares bytes.
- R4 (Major): reserved match ASCII-case-insensitive, `-`/`_` collapsed; per-variant tests added.
- R5 (Major): credential descriptor exactly-one-kind strict init + tests.
- R6 (Major): bounded read (`1 MiB+1`, `S_ISREG`, `O_NOFOLLOW`); ACL limitation documented.
- R7 (Major): wrong-impl probe = temporary production patch + RED log + byte-identical restore; coercion probe included.
- R8 (Minor): 5-layer signature (tools flag folded at parse); contradiction rejected at parse.
- R9 (Minor): `workspaceGrant` provenance — deny-all default, never from repo content; invariant doc + rejection test; `trust` deferred to M2.
- R10 (Minor): single `selectRoute(snapshot:…)` signature; M1-A cloud rule = denied.
- R11 (Minor): NET-06 marked PARTIAL everywhere; exit-4 reuse documented as deliberate (no spare code in SPEC §12.2).
- R12 (Minor): `request_options` values redacted by default; canary tests extended.
- R13 (Minor): requiredness explicit (`default_model`+`locality` required); BOM/surrogate variants added.
- R14 (Suggestion): deferred `RawJSONNumber` type, `QualificationLabel`, `configuredOrigins`, `--redacted` flag; kept `requiresNewEpoch` predicate (cases need it), transition stays M1-B.
- R15 (governance): digest recomputed with unrestricted shell after rev2 (§13 + receipt); `git status` clean except this file confirmed before re-review.
- Rev3 (R1/R2/R14 residuals from second review): test 11 renamed to `ARCH-import-gate` (no catalogue-ID prefix; explicitly excluded from case-filter/coverage); test-target/CLI dependency graph completed (Runtime+Providers in test deps; CLI deps conditional; origin-validation layering stated; "vendored subprocess" corrected to "resolved package dependency"); `RoutePolicy` trimmed to `{none, localOnly}` with `.configuredOrigins` documented as M5-future; qualification descriptor corrected to uniformly-unknown; stray non-ASCII removed.

## 14. Revision log (rev3 → rev4; implementation authorization corrections A/B/C)

- A (base_url prefix): `base_url` now allows an explicit path prefix (`scheme://host[:port][/path-prefix]`); endpoint = stripped base + protocol suffix, prefix preserved verbatim, never duplicated/guessed. `allow_http_origins` stays origin-only; origin derived by discarding the prefix (no widening). Rejects: userinfo/query/fragment/whitespace/backslash/`//`/dot-segments (incl. `%2e`)/prefix-already-ending-in-suffix. New CFG-02 variants (6) + NET-01 `prefixed-base-endpoint-preserved`; `endpointURL(for:)` added to §8; duplicate-model rule uses normalized base.
- B (sealed inference): sealed/tools-none deny **tools only**; route authorization independent. Sealed + approved local → route allowed (tool-free inference permitted); sealed + cloud → still denied. §4 struct/route text, §5 `selectRoute` rule, POLICY-02 G/W/T + `sealed-local-route-permitted` / `tools-none-local-route-permitted` variants, NET-01 `sealed-local-permitted` / `tools-none-local-permitted` variants updated.
- C (config-to-CLI narrowing): config + restrictive flag = allowed intersection (rev3's config+flag `contradictoryFlags` examples superseded); only disagreeing explicit argv pairs reject (`--sealed`+`--tools X≠none`, `--tools none`+`--tools X≠none`, `--tools X`+`--tools Y≠X`; identical repeats fine; both orders reject; later flags can never restore). POLICY-02 matrix 8→12 rows (config-narrows-allowed ×2, cli-conflict rejections ×3 pairs, route-permitted ×2); NET-01 5→7 variants. Implementation must add these regression variants.
- Nothing else changed; all rev3 READY dispositions and §10/§13 stand.
- Rev5 (delta-review D1–D4, NEEDS-EVIDENCE → fix before implementation): D1 `base-prefix-already-suffix-rejected` variant (all three suffixes); D2 encoded-traversal (both cases + mixed), empty-segment, backslash, fragment, whitespace, default-port-equality variants + decode-before-compare rule; D3 `sealed` outcome-inert invariant + `sealed-route-identical` test; D4 raw-argv-before-folding rule + §3.1 argv-only scope. Counts: CFG-02 17→24 variants, NET-01 7→8, POLICY-02 unchanged at 12 rows.

## 15. Revision log (rev5 → rev6; completed-slice review S1–S11)

Mechanical hardening only; no contract direction changes:

- S1: `readBoundedConfigFile` replaced by Runtime `readBoundedFile` (`O_RDONLY|O_NOFOLLOW|O_NONBLOCK` + `fstat` `S_ISREG` before any read; FIFO/symlink red-green tests); `O_NONBLOCK` added to the credential-file open.
- S2: snapshot-level `requiresNewEpoch(old:new: ConfigSnapshot)` overload (tools/default/origins/profiles) alongside the profile predicate.
- S3: `surrogate-dup` oracle now uses a real `\uD83D\uDE00` escape plus lone-surrogate rejections.
- S5: duplicate-endpoint identity compares normalized `origin + pathPrefix` (host-case/default-port spellings collide).
- S6: pure-loader size gate is `<= maxFileBytes` (off-by-one fixed).
- S7: `config validate` wires `--sealed`/`--tools` through `checkCLIDirectives` (conflicts exit 2; folded directives echoed as `invocation:`) — the real production caller for the conflict oracle; full observability awaits M2 trust.
- S8: decoded backslashes rejected in path segments.
- S9: `grant(fromUntrustedSource:)` reports byte length, never echoes input.
- S11: locality vocabulary cross-check added.
- D-c SUPERSEDED: §5's "`models: []` is the only valid tool-less shape" is withdrawn — empty `models` is rejected (`missingField`), because R13 requires `default_model` to reference a configured alias and a dangling reference would fail open. Tool-less operation stays possible via deny-all tools with a configured profile.
- Counts: CFG-02 24→31 variants (S3/S5/S8 additions), POLICY-02 +3 spawn-flag tests (S7), NET-01 unchanged at 8.

---

## Review ask (for `deepseek-reviewer` — TARGETED DELTA ONLY)

Baseline SHA `e3c0527`; subject §14 corrections A/B/C only against rev3 READY (`99cbeff1…03e430`). Do not re-debate unchanged sections.

Answer specifically: (A) can a crafted `base_url` (userinfo/query/fragment/traversal/`//`/encoded dots/double suffix) escape validation, widen the origin, or drop/duplicate the prefix — with the exact input? (B) can sealed/tools-none prohibit an approved local tool-free request, or can sealing grant anything / leak into route denial — which function? (C) can ordinary config+flag narrowing reject, or can later/conflicting flags restore capabilities — which argv pair? Concrete findings with severity + disposition (READY / NEEDS-EVIDENCE with minimal fix) required.
