# Needletail v0.3 — complete product and delivery specification

12 October 2026 · Linux first · Behaviour-labelled tests · Step 5 / DeepSeek / CodeRabbit

**Design contract, not an implemented or qualified product.** This reading edition is generated from the named source documents in the accompanying packet. It includes the full product, architecture, UX, development, testing, review, milestone, dependency and acceptance contracts. Role prompts, schemas and setup/report templates are included separately in the archive.

## Contents

1. START-HERE.md
2. SPEC.md
3. design/ARCHITECTURE-NOTES.md
4. UX-DX.md
5. DEVELOPMENT.md
6. TESTING.md
7. REVIEW.md
8. MILESTONES.md
9. DEPENDENCIES.md
10. ACCEPTANCE.md
11. CHANGELOG.md
12. SOURCES.md


---

## Part 1 — START-HERE.md

### Start here — Needletail v0.3

This is a complete specification and agent handoff, not a repository containing a working harness. Original v0.2 product/UX contracts are retained and reconciled with the Linux-first test/review methodology. No prior archive is required.

#### Read order

Read AGENTS.md, SPEC.md, DEVELOPMENT.md, TESTING.md, REVIEW.md and MILESTONES.md. Read design/ARCHITECTURE-NOTES.md before designing effects/storage and UX-DX.md before designing interactive state. DEPENDENCIES.md contains candidate pins, not a resolved graph. ACCEPTANCE.md and cases/catalog.json contain 200 declared cases; none is an executed pass.

README.md indexes schemas, examples, review prompts and templates. COMPLETE-SPEC.md is a generated one-file reading edition of the normative documents; edit source documents, not that generated copy. CODEX.md remains a compatibility pointer for a Codex handoff; all roles use the same contract.

#### First receiving-agent action

Inspect the selected Linux workspace without modifying unrelated files. Record current Git/toolchain/environment/model/reviewer bindings. Write only the bounded M0-A/M0 plan and initial tests/bootstrap structure after independent plan review. Establish actual dependency/runtime evidence; do not spend the first milestone drawing the finished terminal.

Use the existing OpenCode installation. `opencode models` returns configured `provider/model` IDs; choose the exact Step 5 Preview Free entry, not a guessed alias. The available installed `deepseek-reviewer` definition determines the reviewer route. A missing reviewer or expired free route is a hold, not permission to substitute. [S27–S30]

To start interactively, attach/paste prompts/step5-bootstrap.md in the source workspace. A CLI form supported by the current documentation is:

```sh
# Set this to the exact identifier listed by the installed client's model listing.
export NEEDLETAIL_IMPLEMENTER_MODEL='opencode-go/step-5-preview-free'
opencode run --model "$NEEDLETAIL_IMPLEMENTER_MODEL" \
  --file prompts/step5-bootstrap.md \
  'Follow the attached Needletail bootstrap instructions. Start with M0 planning and independent review.'
```

The identifier shown is an **example**, not a verified account binding. Do not execute it when the installed list/approved route differs. The environment variable is local shell configuration, not a product setting or credential. No npm install or hidden setup command is required by this handoff.

#### Authorization

M0–M3 are the initial implementation scope, with DeepSeek at minor gates, CodeRabbit at epic gates, maintainer-controlled merges and a stop after M3 viability. This packet does not authorize creating a remote repo, changing account billing, publishing code/artifacts, modifying an inference server, installing host software or merging a PR. Request the missing specific permission only when needed; continue independent authorized offline work.

M4–M6 are designed end-to-end to prevent late architecture invention. They begin only after the continuation decision. Mac qualification begins in M4, not as a prerequisite to Linux viability.


---

## Part 2 — SPEC.md

### Needletail — minimal Swift coding harness

**Working name; not a name-availability or trademark clearance.**  
**Specification version:** 0.3 / 12 October 2026 — consolidated Linux-first delivery contract  
**Status:** Implementation contract, not an implemented or qualified product.  
**Intended licence:** MIT for original code; retain all dependency notices.

#### 1. Decision and product boundary

Build a small, local-first coding harness, not an IDE, hosted agent platform or orchestration framework. The differentiator is not Swift alone. It is predictable prompt construction, cache-aware context management, honest execution boundaries, lossless provider conversations and installation without a language-package ecosystem on the target machine.

A useful release has one agent loop, five coding tools, a *responsive* scrollback terminal interface, a headless interface, resumable local sessions, and explicit local/cloud endpoint profiles. `UX-DX.md` is a normative companion defining file mentions, queueing, undo, agent/session inspection, presentation and testability. The harness speaks to an already-running inference service. It neither hosts models nor changes an inference server's configuration.

**The viability gate is M0–M3 in MILESTONES.md.** Demonstrate the packaging, streaming, subprocess and real-local-model path before investing in terminal polish or integrations. Existing Swift coding-agent work is useful feasibility evidence, not proof of this design's correctness. [S18]

##### 1.1 Required for the first complete product release

- Native Swift agent logic on macOS and Linux; no Node, npm, Bun, Python, Homebrew or Swift compiler required to run the released harness.
- Interactive chat and headless JSON Lines, with the same underlying agent loop. The user-facing M4 release additionally requires `@` file completion/preview, durable follow-up/steering queues, safe native-file undo, conversation rewind, `/agents` and compaction inspection, and readable Markdown/diff display (`UX-DX.md`).
- Direct OpenAI-compatible Chat Completions, OpenAI Responses and Anthropic Messages adapters. Each has its own qualified capability profile, not a universal lowest-common-denominator wrapper.
- `read`, `search`, `edit`, `write`, `exec`; optional, explicitly enabled `consult` for a single bounded tool-free model call.
- Local session persistence, resume, fork, explicit checkpoint/compaction, usage diagnostics and cancellation.
- User-owned workspace grants and explicit endpoint routing. No silent escalation, fallback, installation or remote discovery.

##### 1.2 Explicitly excluded

No GUI, web server, daemon, browser automation, editor implementation, IDE protocol, agent teams, recursive workers, task DAG, automatic project manager, background cron, embeddings, vector store, memory extraction, built-in code indexer, model downloads, extension marketplace, remote code loading, runtime package manager, automatic updater, or remote telemetry.

The no-runtime-install rule concerns the harness and its extensions. Existing project toolchains may be invoked under execution policy. Installing a project dependency is an explicit project operation requiring the applicable grant, never a hidden repair to the harness or appliance.

No automatic project-wide context dump. No mandatory skills catalogue. No repeated todo reminders inserted into the model history. Existing files such as `STATUS.md` remain the project's source of truth; the harness does not create a competing tracker.

MCP is a post-core, separately enabled adapter using the official Swift SDK. It is not an excuse to bundle dozens of tools or build another indexing service. Subscription/OAuth-provider parity with Pi is **not** promised by v0.1. Direct API credentials and explicit compatible endpoints are the initial authentication contract.

#### 2. Product invariants

These are release requirements, not marketing aspirations.

| ID | Invariant |
|---|---|
| I01 | No network request on startup, help, local configuration inspection or session listing. A model call or explicit network probe is required to initiate provider traffic. |
| I02 | No runtime download/install of harness dependencies or plug-ins, remote code import or executable plug-in loading. |
| I03 | Within a context epoch, already-admitted prompt material and cache-relevant settings are immutable. New information is appended. |
| I04 | Native provider continuation data is not discarded merely because it is not displayed. |
| I05 | Tool execution requires a complete, valid request plus an effective capability grant. Partial JSON never executes. |
| I06 | `--sealed` and `--tools none` can only remove capabilities; later flags cannot re-enable them. |
| I07 | No ambiguous tool side effect is automatically retried after a crash or lost response. |
| I08 | Model claims, process exit codes and independently checked evidence are separate records. |
| I09 | Local-only provider routing never silently becomes cloud routing. |
| I10 | Cache hits, token counts, prices, isolation and test success are reported only to the degree actually established. Unknown is a first-class value. |
| I11 | The original session remains recoverable after a failed or cancelled checkpoint. |
| I12 | Repo files and model output cannot modify endpoint credentials, tool grants or executable registrations. |
| I13 | Busy agent/tool work never destroys, submits or reorders unsent operator draft text. |
| I14 | A queued operator message has idempotent local admission and is dispatched only at its safe boundary. Network delivery/processing is not claimed exactly once; ambiguous delivery is held for reconciliation. |
| I15 | Stale/ungranted `@` attachments cannot silently refresh or cross the local/cloud boundary. |
| I16 | `/undo` checks exact postimages before restoring a native-file preimage; it cannot impersonate rollback of shell effects. |
| I17 | `/rewind` and checkpoint history never mutate or reset workspace files. |
| I18 | Rendered escape sequences originate from typed UI style primitives; untrusted bytes cannot control a terminal. |
| I19 | Interactive decisions/state transitions are reproducible with pure reducer tests and physical PTY gates. |
| I20 | `/agents` is a monitor over known one-loop sessions and consultations, not an unannounced recursive worker scheduler. |
| I21 | Delayed completions are accepted only for the active session/run/request/effect revision; cancellation cannot resurrect work. |
| I22 | Production reducers and effect boundaries are exercised by tests; test-only state machines cannot certify different production behaviour. |
| I23 | Every accepted native undo creates durable receipts and an appended model-visible workspace-change notice before the next request. |
| I24 | Every resource queue is bounded; exhausted durable capacity causes a visible stop, not dropped authoritative receipts or infinite buffering. |

#### 3. Platform, packaging and dependencies

Use **Swift 6.4**, Swift 6 language mode and strict concurrency for new code. The Swift 6.4 release and stable Subprocess API are now published. [S01]

Development starts on **Linux x86_64 / Ubuntu 24.04, Swift 6.4**, in a dedicated builder or VM. Linux is the mandatory execution gate for every slice. No Xcode project, Apple host or macOS runner is needed to establish M0–M3. A container on a Linux kernel is suitable for routine builds/tests; packaging and PTY claims require the corresponding real native interfaces.

Release targets are qualified in this order:

- M0–M3: Linux x86_64 / Ubuntu 24.04. This establishes viability, not a multi-platform release.
- M4: first Apple Silicon macOS build and native tests after Linux viability, before integrating the completed terminal experience. macOS 14 is a desired deployment floor, not a proven compatibility claim for the selected graph. Retain it only if the whole graph resolves and executes there; otherwise propose a reviewed minimum without contaminating the portable core.
- M6: Linux aarch64 and Debian 12 are additional qualification targets. Debian 12 support requires an appropriate older glibc baseline or a qualified alternative distribution, not merely an Ubuntu-built binary.

A platform not yet scheduled is `DEFERRED_BY_PLAN`; a required but unavailable platform is `UNQUALIFIED_ENVIRONMENT`. Neither is a pass. Publish only the actual tested platform matrix. See DEVELOPMENT.md for dependency/build/runtime separation.

Intel macOS is a later support claim unless it receives the same native tests. Cross-compilation or a passing build is not a substitute for native execution qualification.

The runtime-installation-free requirement is hard. A single executable is preferred, but a signed/checksummed release directory with explicitly bundled native libraries is acceptable. Do not claim a tiny or fully static binary before measuring the selected graph. Start with the Linux native SwiftPM build and a clean Ubuntu runtime bundle. Evaluate the Static Linux SDK as a bounded packaging experiment, not as a prerequisite that blocks the coding loop; a supported glibc/runtime bundle is acceptable. Additional distribution support requires its own baseline and deterministic loader paths. Test the resulting distribution on a clean host without a Swift toolchain. CA trust material and libc assumptions must be documented. [S17]

##### 3.1 Selected libraries

The complete decision and candidate pins are in DEPENDENCIES.md. Seven direct Swift packages and one vendored native line-editing library are allowed for **M0–M3**. `swift-markdown` 0.9.0 is an additional **M4 candidate** for completed-block rendering subject to linkage and build-cost qualification (`UX-DX.md`, `DEPENDENCIES.md`):

| Concern | Selection | Own only this glue |
|---|---|---|
| CLI parsing | `swift-argument-parser` | Commands, flags and validation |
| HTTP and streaming transport | `AsyncHTTPClient` | Endpoint policy, deadlines and provider requests |
| SSE framing | `swift-openapi-runtime` | Bounded upstream framing guard and provider event decoding |
| Processes | `swift-subprocess` | Process-group policy, resource limits and durable execution records |
| File descriptors and paths | `swift-system` | Workspace boundary and optimistic edit transaction |
| Hashing | `swift-crypto` | Digests and fingerprints; not a new cryptosystem |
| SQLite | `GRDB.swift` | Small schema, migrations and domain transactions |
| Terminal input | pinned `replxx`, via its C API | Swift bridge and minimal chat integration |

Foundation/Codable are available without another package. Use Swift Testing from the toolchain. `git` and `rg` are explicitly provisioned executables, not libraries to reimplement. Never install them automatically. `doctor` reports absence and the exact disabled capability.

This is not a claim that the dependency graph contains only seven packages. AsyncHTTPClient brings NIO/TLS and related dependencies; native and transitive code must appear in the resolved inventory and SBOM. Count resolved packages, linked targets, native libraries, installed bytes and runtime RSS separately. [S02–S09]

#### 4. Architecture: four core targets and one small pure presentation target

```text
NeedletailCLI (composition root, replxx, ANSI writer)
    -> NeedletailPresentation (pure state/frames from M1; full UX in M4)
    -> NeedletailCore         authoritative session/queue/epoch contracts
    -> NeedletailProviders    native wire adapters, transport
    -> NeedletailRuntime      tools, policy, persistence

Core imports neither terminal code nor HTTP/SQLite implementation details.
Presentation sees value/event projections of Core, not terminal, GRDB, HTTP or mutable session internals.
Providers and Runtime depend on Core contracts, not on CLI.
The fifth target begins in M1 with only value state/reducer contracts needed for test-first work. Product UI integration remains M4; do not build a UI framework.
```

Small test-support targets are allowed for adversarial child processes, mock HTTP servers, a PTY driver and deterministic UI fixtures. Do not add dependency injection, an event bus framework, reactive streams, service location or a generic workflow engine.

##### 4.1 Ownership and concurrency

One `SessionActor` owns a session's authoritative state transitions, operator-input queue and durable sequence number. UI state is a read-only projection and does not dispatch queued messages without acknowledgement. At most one foreground generation runs per session. Tool batches execute in model-declared order in v0.1. No speculative execution of streamed calls and no concurrent writes or shell commands.

The default HTTP transport uses one event-loop thread rather than allocating a thread per detected CPU; change this only after measurement. Shared immutable schemas and provider profiles are values. Blocking terminal input belongs on a dedicated blocking thread, not a Swift cooperative-executor task that never yields. UI updates cross an explicit bounded queue. HTTP and process output are consumed incrementally with backpressure.

An endpoint gate limits simultaneous requests in the current harness process. It is **not** a cross-process scheduler or an inference-server slot allocator. Independent sessions in independent processes still require server-side limits or external coordination.

##### 4.2 State machine

```text
idle -> admitting -> requesting -> streaming
                          |           |
                          |           +-> validating-tools -> authorising
                          |                                  -> executing
                          |                                  -> requesting
                          +-> failed
streaming -> completed -> idle
any active state -> cancelling -> interrupted -> idle
idle/safe turn boundary -> checkpointing -> new epoch or unchanged epoch
```

Only completed assistant responses can propose executable tool batches. `authorising` cannot mutate grants based on model text. A denied operation produces a typed tool error, not a pretend success or unrecorded omission.

All externally significant transitions produce a durable record. Token-by-token UI events need not each fsync; tool intents and irreversible state transitions do.

#### 5. Configuration and endpoint profiles

Use strict JSON with a versioned schema. No YAML dependency, JavaScript config, templating language or config execution. `schemas/config.schema.json` and `examples/config.local.json` define the initial public shape.

Load only the explicit `--config` path or the user-level default config location. Do not automatically load a repo's executable or endpoint configuration. A workspace may supply instructions after trust, but not credentials, permissions or remote endpoints.

Validation rejects duplicate object keys, duplicate model IDs, unknown structural configuration keys, contradictory flags, malformed origins, negative limits and references to missing model IDs. The single declared extension namespace is `models[].request_options`: inert, operator-owned native JSON options, frozen with the epoch. It cannot override harness-owned model/history/system/tool/stream/authentication fields. Unknown native options require explicit operator configuration and are marked unqualified until exercised; never guess, inject, remove or retry them invisibly. This namespace does not permit code execution or repo/model control over configuration. Give a field path and actionable error. Foundation decoding alone does not meet the duplicate/unknown-key contract; a bounded duplicate-key preflight plus strict typed validation is part of the small owned codec layer. Initial configuration limits are 1 MiB per file, 64 KiB per native-options object and 32 levels of JSON nesting; reject violations before unbounded decoding.

##### 5.1 Model identity

A profile contains a unique human alias, explicit protocol, API base URL, exact served model ID, declared context ceiling, maximum output, locality class, credential reference, request deadlines and maximum in-flight requests. Model IDs are opaque strings: never coerce numeric-looking strings to numbers.

Do not infer tool support, reasoning replay, context size, token counting or cache support from the label “OpenAI-compatible” or from `/models`. Discovery is an explicit `doctor --probe MODEL` operation using synthetic non-private input. It records the exact endpoint, server identity when available, model ID, template/capability fingerprint and test result. Unavailable fingerprint fields remain unknown.

The API base includes the protocol prefix explicitly: append `/chat/completions`, `/responses` or `/messages` to the configured base without guessing or adding another `/v1`. Origin grants contain only scheme, host and port; reject embedded credentials, query strings and fragments in endpoint configuration.

The `context_window` setting is the operator's ceiling, not proof that the server really accepts it. Admission uses the lower of configured and empirically established limits when both exist. A missing probe does not prevent an ordinary request, but the UI labels unqualified capabilities and approximate accounting.

##### 5.2 Three wire adapters

**Chat Completions:** native message/tool-call IDs, streaming deltas, reasoning fields and usage dialects belong to the endpoint adapter. Server extensions such as a slot selector or `cache_prompt` are never sent to an endpoint merely because another server supports them. llama.cpp's slot controls are backend-specific. [S16]

**Responses:** preserve native output items, call IDs and required opaque reasoning/continuation data. Do not flatten everything into assistant text. Stateless/local-history continuation is preferred where supported; a server response ID alone is not a durable local conversation. Retention-related settings must be explicit and qualified.

**Messages:** preserve content-block order, tool-use/result pairing, signed thinking and other required continuation blocks. Cache annotations and model/version capability differences belong here, not in generic tool schemas. [S11]

Keep an exact private record of received payloads. Build the next request from a validated, provider-specific replay projection. Do not blindly resend an entire response object, including response-only fields, as an input message. Preserve required native values losslessly; an unknown potentially continuation-bearing item must produce a compatibility stop rather than being silently dropped. UI projections may omit opaque content, but the replay record may not.

Changing model, endpoint, native protocol or incompatible reasoning/tool configuration is an explicit **new-epoch transition**. Never send another provider's signed or encrypted reasoning to the new provider as if it were compatible. A portable checkpoint is the handoff boundary.

##### 5.3 Credentials and networking

Support environment-variable references, a mode-0600 credential file and macOS Keychain using the OS Security framework. Credentials are resolved only for the relevant operation. Never serialize secret values in session exports, process environments, error bodies, command arguments or diagnostic logs.

`local-only` admits only configured profiles marked local, with an explicitly permitted origin. Loopback/LAN HTTP requires that exact origin in `allow_http_origins`. Cloud profiles require `configured-origins` mode and an explicit operator choice; switching an existing private workspace to a cloud route requires consent for sending that workspace's admitted context.

The locality label is an operator trust assertion about the server, not cryptographic proof that it never forwards traffic. DNS resolution and the actual peer should be recorded in network diagnostics where available. Do not automatically follow HTTP redirects, inherit proxy environment variables or fall back to a public endpoint. The v0.1 HTTP client disables redirects; a moved endpoint must be edited explicitly. TLS validation stays enabled. Custom local CAs are explicit configuration, never “disable verification”.

Provider routing restrictions govern the harness's HTTP client. They do **not** constrain arbitrary programs launched by `exec`. A complete no-egress guarantee requires the external sandbox described in section 10.

#### 6. The prompt is a versioned artifact

##### 6.1 Context epochs

An epoch freezes:

- The base instruction text and its version.
- Tool definitions, ordering, argument schemas and applicable native cache annotations.
- Admitted workspace instructions and explicit attachment snapshots.
- Model, native protocol and cache-relevant generation configuration.
- The provider-specific representation of historical messages and content blocks.

A new turn appends complete material. It does not rewrite an old tool result, refresh the beginning of the prompt with the current time, change dictionary ordering, strip old reasoning or regenerate a system message from mutable environment state.

Only the prompt-bearing content and settings must remain stable; request IDs, transport headers and audit timestamps may change outside the model context. Stable client bytes are a testable precondition, not proof of identical server-rendered tokens or a cache hit. Providers can add templates, change routing, evict state or impose cache lookup boundaries. [S10–S12]

Build new JSON from typed values. Keep already-validated replay blocks in a stable representation rather than repeatedly normalising them through lossy generic JSON number types. Never normalise Unicode, whitespace or numeric-looking strings in source text. The raw recording, replay projection and display projection have different purposes.

##### 6.2 Instruction admission

The compiled base prompt should be short enough to review in one sitting. Initial target: **at most 3,000 tokens, hard review threshold 4,000**, including the five default tool schemas, using a pinned reference tokenizer in the benchmark. These are design targets, not measured results or universal token counts across models.

User/project instructions and explicit attachments are reported separately. Their actual token contribution still counts toward admission. A small core prompt does not justify hiding a huge automatic attachment under a different accounting label.

A trusted workspace may load its root `AGENTS.md` once when explicitly enabled. No ancestor-home traversal, recursive repo scan, global skill enumeration or inclusion of every README. Nested instructions are discovered only along paths the agent is actually accessing, shown as new scoped context, and applied before a relevant write. Loaded instruction hashes are retained; changes require an explicit append or new epoch, never silent prefix mutation.

`/attach` and `--instructions` admit an exact file snapshot. `STATUS.md` is read when relevant; it is not automatically duplicated into the system prompt. Model-read text remains task data unless the operator has designated it an instruction source.

##### 6.3 Token and context admission

Define:

```text
C = usable context ceiling
G = next-generation output reserve
T = bounded next tool-result-round reserve
K = checkpoint generation/instruction reserve
S = uncertainty and template safety reserve

Normal work may continue only while projected admitted input + G + T + K + S <= C.
```

The checkpoint path reuses the reserved budget; do not allocate the whole remaining window to a normal answer and discover that compaction no longer fits. Tool-free sealed requests do not reserve a tool round or a checkpoint. Small-context profiles therefore remain useful.

Prefer an endpoint's qualified token-counting API or a matching local tokenizer. Otherwise use prior actual usage plus an explicitly labelled estimate and measured margin. Do not call `characters / 4` a guaranteed conservative bound. Binary/image modalities require separate support and accounting; they are excluded from v0.1 tool content.

There is no fixed 64K compaction threshold imposed on a larger context. Trigger at the profile's admission boundary or by `/compact`. Near-limit failure must preserve history and report the count uncertainty; do not repeatedly retry the same rejected payload or silently truncate arbitrary old messages.

##### 6.4 Tool-output discipline

The default model-visible preview is 8 KiB per tool result, subject to a stricter whole-round reserve. Read/search return ranges and continuation handles. `exec` returns command, cwd, exit status, duration, selected output and an artifact handle. It does not paste an entire build log into every subsequent prompt.

Artifacts are kept locally. Once a preview is admitted to an epoch it is immutable. Later requests for additional output append new ranges. Replacing old verbose results in place would undo the prefix stability being sought.

#### 7. Checkpoint/compaction: two different costs

The current Pi compaction implementation inspected during research builds a separate summarisation context from serialized conversation text. That is evidence about the inspected upstream source, **not a verified diagnosis of any particular installed Pi build**. Needletail's design addresses the avoidable construction cost while acknowledging the unavoidable context-replacement cost. [S12]

##### 7.1 Phase A — capture a warm checkpoint

At a safe boundary, create an isolated checkpoint branch from the current native conversation. Append a bounded user instruction asking for a continuation checkpoint. Preserve earlier native messages, tools, tool ordering, cache policy, `tool_choice`, thinking/effort and other cache-relevant settings. Do not introduce a new response-format schema at request level solely for checkpointing; ask for the checkpoint JSON in appended text and validate it afterwards.

**Disable actual tool execution in the executor, not by changing the provider request's tool configuration.** Changing `tool_choice` can itself invalidate message caching on Anthropic. Some other settings are also rendered into provider prompts. Capability qualifications must cover this path. [S10–S11]

A requested tool during checkpointing is never executed. The branch may receive one correctly paired, locally generated denial/result plus a retry instruction, under the same limits. A second invalid attempt stops checkpointing. Mandatory-tool-choice profiles that cannot produce a tool-free checkpoint must fail this qualification or use an explicitly different fallback; do not pretend they remained warm.

The checkpoint schema contains:

```text
task_goal
user_constraints[]           references to exact user/pin events
completed_work[]             claim + evidence references
current_files[]              path + observed hash + observation sequence
open_questions[]
failed_attempts[]
next_actions[]
uncertainties[]
```

The model may propose this content. The harness verifies structure and referenced record IDs, then merges the exact user-pinned constraints and unresolved execution records itself. It cannot mechanically prove that a free-text summary captures every semantic detail; retain the full history and test checkpoint retention on adversarial fixtures.

A model sentence saying “all tests pass” does not become verified evidence. It must point to a retained execution record, and even a zero exit code is described as a process result unless a specific test-report parser established more.

##### 7.2 Phase B — publish a shorter epoch

Construct a new epoch from the unchanged static base, the validated checkpoint, exact required user constraints, and a bounded recent tail of complete conversation/tool groups. Do not cut a tool call away from its result. Do not duplicate the entire checkpoint branch or its summarisation instructions into the resumed coding conversation.

Commit the checkpoint and the new active-epoch pointer in one database transaction only after the needed artifacts are durable. On malformed output, timeout, cancellation, disk-full or missing evidence references, the old epoch remains active.

The first request containing the new shorter context needs to prefill the changed suffix. A checkpoint cannot both discard the old conversation and keep its entire old KV prefix. Some static prefix may still be reusable. After rollover, the shorter context grows append-only again. Report separately:

1. Checkpoint-generation latency and actual cache reuse.
2. First-request latency and cache reuse in the new epoch.
3. Subsequent warm requests in that epoch.

Do not advertise zero-cost or perpetually warm compaction. Compare total time and cost over the whole transition, not just the summarisation request. [S10]

##### 7.3 Failures and alternatives

Automatic cloud fallback for a failed local checkpoint is forbidden. A user may explicitly choose an already-authorized alternate summarizer, acknowledging a different privacy/caching path. A cheap summary endpoint is not presumed better than a warm main endpoint.

A manual checkpoint import or explicit new session remains possible without deleting the old session. Checkpoints are a continuation aid, not a replacement for canonical repo files, test evidence or the original user request.

#### 8. Native tool contracts

All tool results share: `call_id`, `status`, `observed_at_seq`, `data`, `artifact_id?`, `truncated`, `warnings[]`, `error?`. Results distinguish success, no-match, denied, conflict, invalid-arguments, timeout, cancelled and failed. Paths and IDs are strings.

Built-in tools use strict Codable contracts plus hand-sized validators, not a generic JSON Schema interpreter. Unknown arguments, duplicate keys, overlong strings, invalid integer ranges and invalid enum values fail before side effects. Required capabilities are computed from the validated operation, not from a model-supplied `safe` property.

##### 8.1 `read`

The default native read/search boundary is the workspace root. An operator may add explicit read-only roots with repeated `--read-root PATH`; those roots never become write roots or exec working directories. Do not load instructions from an archive merely because it is readable. Native tools deny their own private state and credential paths; protected workspace paths such as `.git`, `.env` variants and `.ssh` require explicit user grants. Search includes useful hidden project files, subject to these exclusions, rather than hiding every dot-directory. These native-tool rules do not constrain trusted host execution.

Inputs: exactly one of an allowed path or current-session artifact ID, and a bounded line/range selection. Return exact text, line/range metadata, file content hash and truncation state. Default 200 lines, further limited by the result budget. Reject binary/non-UTF-8 content with an explicit unsupported-content result rather than replacement-character corruption. v0.1 is text-only.

Artifact IDs are scoped to the current session or explicitly granted fork ancestry. An ID is not a universal capability to read another session's private files.

##### 8.2 `search`

Inputs: `literal`, `regex` or `files` mode, a query for content-search modes, bounded glob filters and a result limit. File-discovery mode uses a bounded `rg --files` invocation and includes empty files without reading their contents. Use the approved `rg` executable with a harness-built argv and JSON output. Do not accept arbitrary ripgrep flags from the model. Disable ambient ripgrep configuration and external preprocessors, use `--` correctly, do not follow symlinks outside the workspace, and honour native-tool deny paths.

Return compact matches with path, line, snippet and a continuation descriptor. Results describe what was observed, not a claim that the worktree was frozen. If the relevant snapshot changes, invalidate continuation or label a restarted query; do not pretend offset pagination is a stable index.

No semantic navigation claims. A missing symbol index is missing, not a synthetic SCIP result.

##### 8.3 `edit`

Inputs: path, expected SHA-256, exact old UTF-8 bytes and replacement text. The old bytes must match exactly once. Reject zero matches, multiple matches, stale expected hash and an empty old string. A separate whole-file `write` handles complete replacement.

Operate on bytes to avoid Unicode-equivalence or line-ending normalisation changing what “exact” means. Preserve unrelated bytes, permissions and newline conventions. Use a same-directory temporary file, checked write, fsync where supported, and rename; retain a before-image artifact under the session quota.

Resolve paths through descriptor-relative, no-follow traversal. A string-prefix path check or a single `realpath` followed by an unguarded open is insufficient for the native-tool boundary. Reject unsupported special files and ambiguous link cases.

Re-read and hash immediately before committing under the harness's workspace write lock. **This is an optimistic conflict check, not a universal filesystem compare-and-swap.** Arbitrary external writers do not respect the harness lock; a narrow post-check race remains. Do not promise isolation from a malicious same-user process or atomic multi-file transactions. Tests must cover injected changes before the final check, and documentation must state the remaining boundary.

Return before/after hashes and an exact change receipt. No fuzzy matching, silent fallback overwrite, automatic `git reset`, or broad rollback of user changes.

##### 8.4 `write`

Inputs: path, content, and either `create_new=true` or an expected current hash. Exclusive creation must fail if the path already exists. Replacement requires the same boundary, optimistic check and artifact rules as `edit`. Parent-directory creation is explicit and confined to the workspace. Deletion is not a separate v0.1 native tool.

Single-file replacement is atomic at rename granularity. Several file writes are not collectively atomic. Preserve each receipt; a later failure does not undo unrelated successful work automatically.

##### 8.5 `exec`

Inputs: executable, argv, workspace-relative cwd, timeout and an optional explicitly allowed environment overlay. Direct argv execution is the default. It avoids accidental shell parsing; it is not a sandbox. Supplying `sh -c`, `python -c`, package-manager commands or similar interpreters still requires the corresponding execution authorization.

The model cannot extend the executable search path, inject library-loading variables, inherit provider keys or access secret files through a claimed read-only recipe. Resolve an executable to a known path before presenting the authorization request. Trusted local configuration can reference existing Conda environments or compiler paths without activating a shell or installing anything.

Capture stdout and stderr concurrently. Use bounded artifact storage and a tail buffer; continue draining after the artifact cap or terminate according to the explicit resource policy. Never stop reading a pipe and then wait forever for the child to exit. Report output omission and bytes discarded.

Run the process in its own process group/session where supported. Cancellation targets the group with interrupt, then termination, then kill on bounded deadlines. Reap the child and close descriptors. Descendants that deliberately detach into another session are outside a process-group guarantee; external containment is required to cover that case.

Default timeout: 120 seconds; the model may request up to 1,800 seconds, still subject to operator policy and the run deadline. No detached-background process feature in v0.1. A process may disobey that intent under trusted execution; do not claim the harness prevented it without an OS boundary.

##### 8.6 Optional `consult`

One call to a configured model, with an explicit task and bounded evidence packet. No tools, workspace discovery, automatic session history, root instructions, recursive consultation, execution or context borrowing. Default packet limit 24 KiB and requested output limit 4,096 tokens, further reduced by the consultant's actual context/admission limits.

The main agent receives a compact result plus artifact handle. Consultant text is advisory/model-produced, not independently verified truth. A labelling endpoint is not silently promoted into an adjudicator. Validation tasks must identify the actual evidence needed; a blind challenger must not receive the main model's verdict.

The consultant is disabled unless configured before the epoch begins. Enabling it changes the advertised tool set and creates a new epoch. Default scheduling is serial on a shared endpoint, and separate configured endpoints are preferred. Do not guess or reserve backend slots that the server has not exposed and qualified.

#### 9. Durable sessions and recovery

Use a small SQLite database via GRDB, with SQL-backed records rather than an elaborate object model. Suggested tables:

```text
sessions(id, created_at, workspace_identity, active_epoch_id, format_version)
epochs(id, session_id, parent_epoch_id, provider_fingerprint, base_artifact_id)
events(session_id, seq, epoch_id, kind, payload_json, artifact_id)
operations(id, session_id, request_id, call_id, state, before_hash, after_hash)
input_queue(id, session_id, kind, state, order_key, target_epoch_id, text_artifact_id, attachment_manifest_id)
file_preimages(operation_id, artifact_id, path_identity, original_mode, before_hash, after_hash)
artifacts(id, session_id, relative_path, sha256, bytes, kind)
```

Database schema version and export format version are independent. A newer unsupported schema opens read-only or fails with an actionable message; never recreate the database over existing data.

Use one writer lock per active session and SQLite transactions. Keep live storage on a local filesystem with supported locking semantics. Do not place a live WAL database on NFS/CIFS. Human-readable JSONL export is a view of the durable store, not a second authoritative journal.

##### 9.1 Side-effect ledger

Before a tool side effect: durably record the authorized intent and operation ID. After it: record the completion and receipt. If the process crashes between the side effect and completion, recovery marks it `outcome_unknown`. It must not run the command again because the completion record is absent. An unresolved outcome blocks automatic mutating continuation, including an agent issuing the same operation under a fresh call ID, until an explicit reconciliation decision.

An edit can sometimes be reconciled using exact before/after hashes. Arbitrary shell commands cannot be made exactly-once by a journal. Reconciliation is explicit and records how the outcome was determined.

Artifact files are written to a temporary path, fsynced and renamed before the transaction publishes their references. A crash can leave an unreferenced artifact; an explicit local cleanup operation can remove it after reconciliation. Never publish a success record pointing at a non-durable artifact.

##### 9.2 Privacy and quotas

Private state directories are mode 0700; files are mode 0600. Sessions can contain proprietary source and model-returned reasoning. No sync or sharing by default. Filesystem encryption is recommended for at-rest protection; mode bits are not encryption. SQLCipher and application-level encryption are not a v0.1 dependency.

Defaults: 32 MiB per exec artifact, 1 GiB per session, 5 GiB global store and 256 MiB free-space reserve. Exceeding quotas must produce a visible state, not silently delete evidence. Garbage collection is explicit and dry-run first. Large history is paged from the store, not all loaded into RAM when listing/resuming a session.

Export defaults to metadata and redacted event summaries. Content-bearing export requires an explicit flag. “Redacted” is not a guarantee of removing arbitrary secrets from arbitrary source text; show that distinction. Raw provider payloads are never included in routine support diagnostics.

#### 10. Permissions without imaginary security

##### 10.1 Effective capabilities

```text
effective capabilities = build capabilities
                       ∩ user configuration
                       ∩ workspace grant
                       ∩ invocation tool mask
                       ∩ sealed/checkpoint restrictions
```

No union or last-flag-wins interpretation may enlarge this result. Repository instructions, skills, tool outputs and model messages are absent from the grant calculation.

##### 10.2 Modes

| Policy | Native tools | Execution |
|---|---|---|
| `observe` | Read/search within approved roots | None |
| `workspace` | Read/search/edit/write inside trusted workspace | Explicit approved operations/recipes; otherwise ask or stop |
| `trusted-exec` | Workspace tools | Explicit session-level trust to execute as the current user |

Workspace trust is an operator action bound to the canonical root identity and policy configuration. Repo-controlled config cannot declare itself trusted. Root reads do not generate repeated approval questions after a suitable grant.

In headless mode `--approval never` means **do not ask and do not broaden permission**. An operation requiring a new grant ends with `approval_required` and a structured description; it is not treated as approved.

##### 10.3 Sealed requests

`--sealed` permits only an explicitly supplied prompt/evidence packet and a minimal fixed worker instruction. It disables tools, consultation, MCP, workspace/instruction discovery and inheritance from another session. It may read the operator-designated packet file, but that does not grant model-directed filesystem access. Sealed persistence is off by default; an explicit export is separate.

A tool-shaped response remains data. `--sealed --tools read` is rejected or resolves to no tools; never re-enabled. `--tools none` is similarly monotone, including across configuration layering.

##### 10.4 Shell and OS isolation

An executable allowlist is an authorization convenience, not containment. `python`, `find`, `xargs`, `git`, `swift test`, `npm test`, package manifests and build scripts can run arbitrary code or read configuration. Do not present their names as proof of read-only execution.

Native workspace path checks constrain the harness's own file tools. They do not constrain a permitted same-user shell. Denying `.env` in `read` while allowing arbitrary shell execution is not a promise that `.env` is inaccessible.

For hostile repositories or complete filesystem/network isolation, run the harness and/or executor in an externally provisioned container, VM or appropriately restricted Linux sandbox. No bespoke cross-platform sandbox ships in v0.1. The UI reports `host execution: not OS-isolated` unless a specific external containment profile was actually exercised. No silent Docker socket access or host mount expansion.

#### 11. Streaming, errors and resource bounds

SSE uses the existing OpenAPI runtime parser. Place bounded byte/line/event guards **upstream** of parser accumulation, including unterminated lines and events. An event-size check after full parsing is too late. [S03]

Initial bounds: 1 MiB SSE event, 256 KiB cumulative arguments per tool call, 8 tool calls per assistant response, 16 MiB provider response stream. These are explicit profile-adjustable limits with diagnostics; never silently enlarge them. Error response bodies are bounded and redacted.

Test arbitrary byte splits, split UTF-8 sequences, CR/LF framing, comments/heartbeats, interleaved call IDs, duplicate IDs, multiple content blocks, end-of-stream without completion and malformed usage. Execute a tool batch only after the provider-specific complete response boundary and full argument validation.

Transport connect deadline defaults to 10 seconds, read-idle deadline to 300 seconds and whole request deadline to 1,800 seconds. Heartbeats count as transport activity but do not remove the whole-request deadline. Local long-prefill profiles may explicitly extend these values. Every active client request is cancellable. Closing the client stream does not prove that an inference server stopped computing or billing; distinguish client cancellation from a server-confirmed stop when a qualified endpoint can establish the latter.

Retries are bounded and capability-aware. Before any streamed content or tool side effect, a transient failure may receive up to two retries with backoff and a provider-supported idempotency key where documented. An uncertain POST may still have incurred provider work or cost; never claim exactly-once inference. After partial content, record interruption and do not silently merge a fresh completion into the old one. Tool side effects are never automatically retried.

Three consecutive identical invalid/denied tool attempts stop the loop with a diagnostic. Default run limits: 80 model turns and four hours, explicitly configurable. A model's `final` response does not certify that the requested work is correct; the report separates claimed completion from receipts.

#### 12. Terminal and command interface

`UX-DX.md` is normative for the user-facing interactive path and its developer test contract. Use normal terminal scrollback and only a bounded transient composer/preview area. No alternate-screen dashboard, browser view, full-screen layout framework or bespoke Markdown parser. Code fences and ordinary Markdown remain readable text. Model and tool output are untrusted terminal data: render unsafe control characters, ESC sequences and bidi-control characters as visible escapes instead of allowing terminal-control execution. Preserve the original bytes in the private artifact; this is a display transformation only. A compact status line reports model alias, locality, context, cache/usage when known and active operation. Newlines and tabs in untrusted text are interpreted as bounded layout data (line breaks/tab expansion), **not** trusted control bytes.

Input requirements: multiline text, bracketed paste without accidental submission, Unicode, history scoped to workspace, predictable Ctrl-C, terminal resize and SSH/tmux operation. `replxx` already exposes C line editing, completion, highlighting and prompt/print hooks; safe simultaneous stream display, preview and draft preservation require an M0 PTY proof rather than assumption. [S09, S25]

One agent generation is foreground **as a session operation**, while the user composer stays live and can enqueue messages. `Enter` while busy queues a follow-up, `/steer TEXT` queues safe-boundary steering, and Ctrl+C during activity cancels and **holds** the queue. `Esc` closes an open completion. A small pure `NeedletailPresentation` state reducer feeds a single terminal output owner; it is not a separate asynchronous agent or full-screen TUI engine. At idle with empty draft/queue Ctrl+C exits. Always restore terminal modes on errors and signals.

##### 12.1 Commands

```sh
needletail                                      # interactive chat
needletail chat --model local-coder --cwd .
needletail run --model local-coder --prompt-file task.md --format jsonl --approval never
needletail run --model local-reviewer --sealed --tools none --prompt-file packet.md --format jsonl
needletail doctor                               # local checks only
needletail doctor --probe local-coder            # explicit synthetic provider requests
needletail config validate --config config.json
needletail trust --cwd . --policy workspace      # operator grant, no model call
needletail session list
needletail session resume SESSION_ID
needletail session fork SESSION_ID
needletail session export SESSION_ID --output session.jsonl
```

Interactive commands: `/model`, `/models`, `/agents`, `/sessions`, `/queue`, `/steer`, `/preview`, `/undo`, `/rewind`, `/context`, `/compact`, `/epochs`, `/attach`, `/pin`, `/diff`, `/keys`, `/help`, `/quit`. `@` mention completion and preview are composer features, not model tools. `/compact --dry-run` is offline; `/undo` is a hash-gated native-file compensation, not git reset. The full behaviour and exact queue boundaries are in `UX-DX.md`. `/model` previews an epoch/privacy transition before committing it. `/pin` records exact operator text for later checkpoint carry-forward; a model cannot create an authoritative pin.

`/diff` uses explicitly provisioned git with external diff/textconv disabled and bounded output. It does not commit, reset, checkout, push or copy the worktree. Git and repo configuration remain part of execution qualification, not inherently trusted because the subcommand sounds read-only.

##### 12.2 Machine interface

`--format jsonl` writes only versioned JSON events to stdout; diagnostics go to stderr. No ANSI escapes, banners, progress spinners or unescaped tool output in stdout. A closed consumer pipe cancels the run. Output schemas do not require consumers to scrape prose.

Every event has `format_version`, `session_id`, `seq`, `kind` and `payload`; deltas also have request IDs. A terminal `run_finished` carries `outcome`, `reason`, usage and evidence references. Unsupported future event kinds may be ignored by consumers; unknown format versions must be rejected.

Exit codes: 0 normal completed response; 2 invalid config/arguments; 3 approval required; 4 provider/protocol failure; 5 run budget exhausted; 6 persistence/integrity failure; 130 operator cancellation. A failed child command is normally a tool result the agent can investigate, not automatically process exit 4. Successful harness exit is not task correctness certification.

#### 13. Observability: measure the thing being complained about

Record queue time, connect/request time, time to first transport event, time to first displayed text, total generation time, tool time, durable-store time and harness-side overhead separately. A hidden-thinking phase can delay visible text after the stream begins; do not label that whole interval network delay.

Usage records keep the raw provider fields plus normalized values:

```text
input_total
input_cache_read
input_cache_write
input_ordinary
output_total
output_reasoning                  when separately reported
count_source                      provider / tokenizer / estimate / unknown
cost_estimate                     optional, with price source and effective date
```

Normalization is per dialect. In current OpenAI Responses accounting, cache-read and cache-write tokens are components of total input. Anthropic reports ordinary, cache-read and cache-creation input separately. Preserve unknown fields and avoid double-counting. Missing usage is unknown, not zero. [S10–S11]

No built-in live pricing fetch. Optional user-supplied pricing can yield a dated estimate. Local inference shows tokens and elapsed time; no claim that electricity, hardware and opportunity cost are zero. Prefix comparison is shown separately from provider-reported cache reuse.

`/context` displays core instructions, tool schemas, project instructions, conversation, admitted artifacts, reserves, last measured input and current estimate. Diagnostics identify an actual prefix change by component and epoch. Do not accuse the server of a cache miss simply because a response was slow.

#### 14. Extension boundary after the core

##### 14.1 MCP, separately enabled

Use the official Swift MCP SDK, pin it, and negotiate the supported protocol version. Do not handwrite MCP. The SDK's documented protocol version must not be assumed to match the newest specification. [S13–S14]

v0.2 may allow explicit stdio executables or explicitly authorized remote origins. No `npx`, package install, auto-start from untrusted repo files or credential inheritance. User approvals apply to each registered server and tool scope; server-provided read-only annotations are not permissions.

Prefer explicitly selecting a small set of tools before creating an epoch. If a large catalogue is later necessary, expose a compact discovery interface and append selected schemas in a qualified way or create a new epoch. Do not invent generic tool-search behavior before a real use case.

SCIP/LSP/navigation belongs in an existing independently qualified service. Require index provenance, freshness and real result evidence. Never substitute synthetic index output or grep and label it semantic traversal.

##### 14.2 No plug-in API yet

Local instruction files and shell composition cover initial customization. Any future executable extension runs out of process with explicit registration, a bounded contract and the same capabilities. “Extension” is not permission to mutate the system prompt or download dependencies invisibly.

#### 15. Acceptance and stop rules

ACCEPTANCE.md (including the preserved UX/DX cases and v0.3 delivery cases) is the normative fixture catalogue. `UX-DX.md` defines the pure reducer and bounded PTY strategy. MILESTONES.md defines milestone order; DEVELOPMENT.md, TESTING.md and REVIEW.md define implementation/review/evidence gates. CODEX.md is a compatibility entry point, not a competing workflow. All numerical performance goals below are **unmeasured targets**:

| Measure | Initial target |
|---|---|
| Release startup to ready prompt, no network | p95 ≤ 500 ms on declared reference hosts |
| Idle RSS after initialisation | ≤ 128 MiB on reference hosts |
| Core prompt + five schemas | target ≤ 3K, review threshold 4K reference-tokenizer tokens |
| Harness overhead around a mock turn | p95 ≤ 100 ms, excluding provider/network/tool/queue time |
| UI acknowledgement of cancellation | p95 ≤ 250 ms |
| Normal same-process-group child teardown | ≤ 5 seconds; escaped daemons are explicitly outside this guarantee |
| Unapproved startup/provider fallback network | zero |
| Runtime package downloads/installations | zero |
| Invalid/partial tool-call side effects | zero |

Report release size and dependency counts; do not trade correctness for an arbitrary binary-size slogan. A performance miss requires an explained measurement and explicit scope decision, not hiding allocations or relaxing the target after seeing the result.

Compare with the installed Pi baseline using the same model/server/settings, matched warm/cold state, bounded tasks, fixed budgets and repeated runs. Measure completed-task evidence, tool/protocol failures, retries, total input/output/cache tokens and end-to-end latency. A language rewrite is not evidence of better model reasoning. A small development suite does not establish statistical equivalence.

**Proceed to a public user-facing release only when packaging, recovery, native tools, local cache-aware checkpointing, the v0.2 interactive UX (M4) and its deterministic + native PTY tests pass on the declared platforms, and at least one real cloud route is qualified alongside the local route.** A provider adapter without live access may be mock-tested but must be labelled unqualified, not silently counted as supported.

If the result is merely Pi with a different implementation language and no deployment/control advantage, stop expanding it. The project earns its existence by making a small number of important behaviours observable and dependable.

#### 16. Delivery methodology is part of this contract

DEVELOPMENT.md, TESTING.md, REVIEW.md and MILESTONES.md are normative. Step 5 Preview Free is the initial implementation model, `deepseek-reviewer` is the independent plan/slice reviewer, and CodeRabbit performs GitHub epic reviews. These are **development roles**, not product features or production dependencies.

The root AGENTS.md is a small development entry point. It does not authorize Needletail to inject this entire design packet into every future model call. The application’s bounded instruction-admission rules still apply.

The default handoff authorizes the receiving developer agent to execute M0–M3 in order, through the required review gates, then stop for the explicit viability decision. Full M4–M6 design is supplied so interfaces are not invented later. It does not authorize remote repository creation, publishing, paid provider fallback, host modifications or automatic merges.

For this version, MILESTONES.md is the single milestone schedule; DEVELOPMENT.md controls platform order; TESTING.md controls evidence classification; REVIEW.md controls review authority. Conflicts outside those boundaries require a narrow written decision before the affected change, not selective interpretation of a convenient paragraph.


---

## Part 3 — design/ARCHITECTURE-NOTES.md

### Architecture decisions and implementation seams

Normative refinements to SPEC.md. These are concrete ownership boundaries, not a reusable agent framework.

#### 1. Production state is what tests exercise

The production session flow uses a pure transition function over typed state and events, driven by one `SessionActor`. The actor serializes admission/commit/dispatch and invokes injected effect adapters. Presentation has a separate pure reducer for composer/selection/view state; it consumes authoritative session events and issues operator commands. It cannot own a second queue or silently mutate session state.

Conceptual signatures (the implementation supplies concrete types):

```swift
func transition(_ state: SessionState, _ event: SessionEvent) -> Transition
func reduce(_ state: UIState, _ action: UIAction) -> (UIState, [UIEffect])
func render(_ state: UIState, width: Int, capabilities: TerminalCapabilities) -> RenderFrame
```

A `Transition` describes a proposed state, durable records and typed effects. It does not perform I/O. Events contain explicit IDs and timestamps when those values are needed; reducers do not call the wall clock, UUID generator, environment, filesystem or network. Keep this a handful of enums/structs/functions, not a general event-sourcing library.

Session state contains: session/run/epoch identity; phase; active request/batch/operation; effective capabilities; budgets; queue projection and hold reason; unresolved-outcome markers; last committed durable sequence. Canonical history is paged from storage, not duplicated into every copied state value. Presentation contains the draft, structured mentions, completion query revision, viewport/selection, pending command IDs and read-only session projection.

#### 2. Side effects and actor reentrancy

Each effect carries `(sessionID, runID, requestID?, effectID, expectedRevision)`. Before every `await`, record the reservation/state required to prevent conflicting work. After resumption, re-check ownership and generation. Late network/file/approval/preview completions cannot resurrect cancelled work or replace a newer draft. Cancellation is an explicit event, not just a cancelled Swift task.

For a side effect: validate complete input → check capability → secure required artifacts/preimages → commit intent and reservation → invoke the effect exactly once in the current process → capture outcome → commit result → publish completion. No model-visible success or execution dispatch before its required durable transaction.

If store commit fails before dispatch, do not dispatch. If it fails after the external operation, hold as unknown/uncommitted outcome and reconcile. Preserve known raw evidence without pretending it is a completed database transaction. Storage adapters must not hold a synchronous SQLite transaction across an `await`.

At most one generation/side-effect batch owns a session. Tools run in the declared order initially. Read-only tool parallelism is not an unrequested optimization. A global actor for all sessions is unnecessary; endpoint request admission remains an in-process limit, not global server scheduling.

#### 3. Queue semantics

`enqueue(commandID, ...)` is idempotent in local storage. The admission acknowledgement contains the durable entry ID and sequence. A lost UI acknowledgement may be retried with the same command ID without inserting another queue entry. Editing an undispatched entry increments its revision.

`queued`, `admittedToHistory`, `sending`, `responseComplete`, `deliveryUnknown`, `withdrawn` and `held` are semantically distinct. The concrete database can encode fewer states plus receipts, but cannot erase those distinctions. History admission is transactional/idempotent; remote delivery is not promised exactly once.

At a safe boundary, steer FIFO precedes the next continuation request. Follow-up FIFO begins only after the current run succeeds/completes. Errors, cancellation, stale attachments or permission changes hold the queue; no surprise automatic follow-up. Do not let an additional queue event skip the hold. The UI must show pending versus committed admission.

An in-flight provider request may have been processed when the client disconnects. Without a qualified provider idempotency mechanism, no automatic resend. This differs from an unstarted request or a known pre-send connection failure. Preserve that evidence distinction.

#### 4. Prompt/replay ownership

Store native provider records, immutable epoch projection and display projection separately. Stable JSON encoding alone does not establish identical rendered model tokens; model templates/settings and server behaviour also matter. Canonical key ordering is for deterministic client evidence, not a universal caching guarantee.

An operator action such as undo changes current workspace facts, so it appends a truthful change notice to the next admitted context. Never rewrite the historical tool result into what the file contains now. A late `/context` or `/agents` lookup is read-only and cannot invoke compaction or refresh instructions.

Checkpointing reserves a boundary, reuses the qualified current native prefix and does not execute model-proposed tools. Request settings and schemas remain unchanged when required for prefix preservation. A malformed or tool-only checkpoint response fails visibly. On validated success, transactionally publish the new epoch plus retained exact constraints/references; the original epoch remains reachable. Queued inputs are re-admitted against the new route/epoch without refreshing attachment bytes invisibly.

Changing provider may make native continuation data nonportable. Create an explicit checkpoint/branch transition under consent; never re-label signed/opaque reasoning from provider A as provider B's native block. A mock-only adapter is not marked live-qualified.

#### 5. Runtime adapters

Five principal core seams: model request/stream, tools, durable session store, clock/ID source and approval. File candidate/preview source and terminal sink serve Presentation. Small sub-protocols are allowed where they simplify a real boundary; no protocol per trivial struct.

Transport tests use both scripted decoded events and captured/synthetic raw wire bytes. Native-provider completion, not an arbitrary chunk boundary or a parseable JSON substring, determines whether a tool proposal is executable. Oversized events are stopped before accumulating an unbounded buffer. Unknown continuation-bearing extensions are preserved under a qualified profile or fail compatibility; they are not guessed away.

Filesystem operations use descriptor-relative/path-policy helpers in Runtime. Exact edits preserve bytes and use optimistic precondition checking; atomic file replacement is not universal compare-and-swap. Hardlinks, special files, mutable parent paths and noncooperating writers have explicit restrictions/limits. Fakes implement the declared contract; native fault tests establish real behaviour.

Process execution separates argv from intentional shell invocation. Sanitize inherited environment, bound both output streams, use recorded working directory/grants, and qualify process-group cancellation. A detached new session is outside a same-process-group guarantee. Test cleanup kills only test-owned processes; never `pkill` a generic process name.

#### 6. Bounded output and terminal isolation

Bound event channels by item count **and** byte budget. Do not use an unbounded `AsyncStream` default for model/process output. Persist/spool authoritative data within quotas and propagate bounded backpressure. Cancellation has a control path that does not wait behind a full repaint queue. On quota exhaustion, stop visibly; unlimited lossless storage cannot be promised.

Presentation may coalesce disposable progress/text projections while retaining canonical data. One serial terminal owner emits trusted ANSI. The blocking line-editor call stays off the Swift cooperative executor. Completion callbacks enqueue/version requests rather than synchronously traversing huge repositories.

Pure frames contain role-tagged text, typed breaks, bounded layout and stable identities. ANSI is an adapter detail. Markdown is parsed from bounded completed content, not reparsed over the whole transcript per token. Non-TTY JSONL bypasses decoration. Unknown terminal width/capability gets a conservative plain fallback.

Catchable exit paths restore terminal state. SIGKILL/power failure cannot execute cleanup. An external parent or user reset can restore modes; do not advertise a hidden terminal daemon to mask that limitation.

#### 7. Persistence and migrations

Use a single small GRDB-backed schema with transactions and versioned migrations. Core owns domain semantics; GRDB owns SQLite mechanics. Tables cover sessions/epochs, ordered native messages, requests/tool calls, operation intents/results, artifacts/preimages, operator queue and grants/route bindings as needed. Do not build a second general-purpose document database.

Artifact commit ordering is explicit: write temporary data in the private root, flush/rename according to the durability contract, then publish the database reference. Reconcile orphans/missing files at reopen. Pure/in-memory store tests cannot prove power-loss behaviour; native temp-file process-kill tests prove only their tested crash points.

Do not silently recreate a corrupt/future database. Open read-only when safely supported or return a specific error. Respect quotas; preserve unresolved operations and pinned ancestry. Logs/support exports redact secrets but raw local provider records may contain source content; export is explicit.

#### 8. Architecture gates

No Core/Presentation import of provider/storage/terminal implementations. No I/O in a pure reducer. No hidden model call in render/list/help. No duplicate queue authority. No effect before its durable authorization. No stale completion advancing state. No successful undo without truthful history. No terminal controls derived from untrusted raw bytes. No test-only path claiming production correctness.

These are exercised by behaviour tests plus small import/dependency checks. Static searches are a guard against accidental coupling, not a proof of every transitive semantic property.


---

## Part 4 — UX-DX.md

### Needletail — interactive UX and developer-experience contract

**Status:** normative v0.3 companion to `SPEC.md`, updated 12 October 2026. Working name. Specification only: no feature described here is implemented or native-qualified.  
**Scope:** rich *scrollback-first* terminal interaction, not a full-screen TUI, agent platform, or second state machine.

#### 1. Product boundary and definition of done

Users must be able to keep thinking and composing while the model works, include exactly the source they meant, understand what changed, interrupt/undo safely, and inspect session/context history without learning an extension system. Developers must be able to prove nearly all of this through deterministic in-process tests and a small bounded number of real pseudo-terminal exercises.

UX work does **not** add model-facing tool schemas. `@` mentions, queues, undo, session browsing, rendering and compaction controls are **operator/harness commands**. Preserve the frozen provider prefix and the five-tool core. `consult` remains an optional sixth model tool; `/agents` does not introduce recursive subagents.

The normal interface writes completed content to terminal scrollback. Only the current composer/candidate-preview region is transient; it may use a handful of cursor movements, but never owns an alternate screen or repaints historical output. A dumb terminal/non-TTY gets plain output and explicit commands, not broken escape sequences.

#### 2. Concrete interaction model

Illustrative transcript (text appearance depends on terminal):

```text
needletail  local-coder · local · ~/src/project    43K / 262K · 2 queued

YOU  Update authentication and examine @src/auth/Login.swift

AGENT  Investigating the login flow
  ✓ read 4 files
  ✓ edit src/auth/Login.swift               +18 -7
  … exec swift test                             00:12

> Also inspect @src/auth/Session.swift█
  [Tab] complete  [Enter] queue  [Ctrl+J] newline  [/steer] redirect

  /agents   /queue   /diff   /undo   /context   /compact   /help
```

Raw user/model/source text must **never** be permitted to emit active terminal control sequences. Render trusted UI escape sequences from typed style tokens only. Log/retain original content separately under existing privacy constraints.

##### 2.1 Input and predictable controls

- Single shared composer, usable during generation and tools. Typing does not block model/tool streaming. The draft survives resize, incoming output, completion selection, Ctrl+C and provider errors.
- `Enter` submits the draft; if agent busy, queues a **follow-up**. `Ctrl+J` inserts a newline; bracketed paste always inserts literal content and never submits. If a terminal does not distinguish configured combinations, display supported equivalents in `/keys`. Do not rely on Shift+Enter or Ctrl+Enter being distinguishable through SSH/tmux.
- `Tab` accepts an active file completion; arrow keys select suggestions while that list is visible, otherwise ordinary line-editing/history behavior. `Esc` closes an open candidate/preview first. No key shortcut may accidentally execute a slash command contained in pasted text.
- `/steer TEXT` queues a steering message; it may not retroactively revoke in-progress tool effects. `/queue` inspects, edits/reorders/withdraws entries. `Ctrl+C` cancels a busy run and **holds**, rather than dispatches, any queued follow-ups/steering. `/queue resume` explicitly resumes dispatch. At an idle non-empty composer Ctrl+C clears the draft (after normal terminal convention); empty idle Ctrl+C exits or asks on unsent/queued work. Ctrl+Z retains OS job-control semantics; do not bind it to file undo.
- `/help` and `/keys` must be discoverable, concise and mode-aware. Slash-command completion is static and offline. Progress/usage is small and never emitted as repeated context to the model.

##### 2.2 `@file` insertion and preview

**Trigger grammar:** explicit `@` at a token boundary (beginning or after whitespace/allowed punctuation) in operator-authored text. Treat email addresses, code literals, escaped `\@`, unselected suggestions and pasted content literally. A completed mention is a structured composer token, **not merely a regex match against message text**. Display text and token identity are separate so paths containing spaces/Unicode are unambiguous. Allow a quoted path selector where typed path input is necessary. Inline ranges use `@path#L10-L30` (1-based inclusive); reject inverted/out-of-bounds ranges. `@` in ordinary assistant text/tool output never triggers expansion.

On first mention, use an operator-authorized bounded file search in the selected workspace. Respect gitignore and excluded roots; do not index `.git`, `.env`/secrets or ignored files by default, follow external symlinks, invoke project scripts or add a new indexer. Do **not** scan the repo on startup. Deterministic basename/path subsequence matching with stable tie-break is sufficient; capped file enumeration and candidate count (e.g. 10) prevent huge trees from freezing typing. A later explicit query can narrow results, not lift policy.

A candidate shows path, type, optional size/line count and a **bounded preview** (default 8 lines / 4 KiB, capped) with line numbers; large/binary files get a labeled metadata-only preview. Preview is local; it does not send bytes to a model, add prompt context or alter permissions. If a non-destructive transient preview cannot be reliably drawn using replxx, write an explicit scrollback preview above the restored composer. No full-screen file browser. `/preview @path` is a keyboard-/dumb-terminal-compatible fallback.

**At submission/enqueue**, resolve the selected tokens against granted canonical roots; capture file identity, exact hash, range, size and operator intent into immutable attachment records. Reject missing, inaccessible or changed-under-read references, with a specific error. File content is **not automatically dumped in full**: default to a bounded excerpt for the prompt plus a tool-readable reference/manifest; explicitly full-attach only on user request and within context admission. A large reference is still visible to the model as a reference, but must not silently consume a huge context window. In sealed/tools-none mode, fail if a requested reference cannot be delivered as permitted bounded bytes; never promise the model a nonexistent read tool.

Queued mention snapshots stay fixed. If a referenced file changes before dispatch, show `stale @file` and require an operator reselect/confirmation; do not silently refresh the bytes. Switching to a cloud endpoint requires the existing explicit workspace export consent. Stale paths, secrets and out-of-root references cannot be smuggled through the UI completion layer.

##### 2.3 Queue: bounded, durable, explicit semantics

There are two operator-input kinds:

| Kind | Dispatch boundary | Safety |
|---|---|---|
| `followUp` (Enter while busy) | After current run completes and any steering has been resolved | Never interleaves mid-tool result or mid-message |
| `steer` (`/steer ...`) | After the **current complete assistant turn and its tool batch**, before the next provider request | Does **not** cancel an in-flight or already-authorized tool; explicit `/cancel` does |

One-at-a-time FIFO per kind is default. No hidden priority queue or agent scheduler. Persist queue entries durably when accepted, with `id`, `kind`, `state`, target session/epoch, draft text, attachment hashes, submission order and timestamp. `queued → dispatched → delivered` are different receipts; cancellation/withdrawal before dispatch must not appear in model history. Provider interruption leaves a dispatched-but-not-delivered item reconcilable, not silently submitted a second time.

Queue limit: 20 items; 64 KiB cumulative operator message text, excluding separately quota-governed immutable attachment bytes; explicit rejection when full. `Ctrl+C` while active sets `queueHeld`, and holds survive crash/restart. Changing model/endpoint/privacy policy between queueing and dispatch requires the same fresh admission/consent as a new prompt. When a queued item has become stale, hold it and later items until repaired/removed; no opportunistic skipping. The user can reorder/withdraw **undispatched** items. Every change is a recorded operator action.

##### 2.4 Undo, rewind and compaction history are separate operations

The word "undo" covers different domains. Do not conflate them:

1. **Composer undo:** delegated to the selected line editor and its supported keybindings; never claim Ctrl+Z file-undo on POSIX terminals.
2. **`/undo`:** reverses the latest eligible **native `edit`/`write` change group**, using the durable preimage and receipts. Show a dry-run preview with paths/changes and whether each file is eligible. First validate every candidate's current canonical path, file identity, permissions and **exact post-image hash**. Existing-file restore uses the saved preimage; create-new undo deletes only when the newly created file is still exactly the recorded postimage. Unknown or conflicting preconditions block reversal rather than overwrite user work. Prefer a preflight of the entire group before mutating; a mid-undo failure is recorded as partial, never mislabeled atomic. Multiple filesystems/noncooperating external writers are not covered by a fictitious transaction. Undo itself creates new append-only operation receipts, preserving the original audit history.
3. **`/rewind [TURN]`:** forks an earlier *conversation* at a selected turn/epoch. It changes neither files nor OS process results. Display a divergence warning when workspace contents are different from that point. The original branch remains inspectable.
4. **`/compact` rollback/revisit:** checkpoint epochs retain parent history. `/epochs` can inspect parent/child and `/rewind` can fork an earlier epoch; compacting never deletes the previous transcript or reverses side effects.

No `git reset`, `git checkout`, automatic reverse patch against a dirty tree or assumptions that a command like `swift test` or a formatter is read-only. `exec` writes are unmanaged unless a separate explicitly verified mechanism is added; `/undo` says exactly what it can and cannot restore. Backups participate in the existing private artifact quotas; if no preimage can be recorded, the native mutation fails closed or reports explicit *non-undoable* authorization before execution (default fail closed).

##### 2.5 Agents, sessions, models and compaction controls

`/agents` displays locally known **one-loop sessions** and currently active bounded consultations. It is a view over the durable session registry and process heartbeat, not a controller for a recursively spawning team. Each row can show session ID, name, model alias/locality, running/idle/stale/unknown status, active operation, queue count, last-known time and checkpoint epoch. An old heartbeat is labeled *stale*, not proof a task is running. No remote kill or orchestration service.

`/sessions` filters/searches the same session data and can resume/fork an owned session; `/agents` is the activity-focused view. `/models` lists configured endpoint aliases, capability qualification and explicit locality. `/agents` must never be a synonym for a model list. One foreground interactive session per process; other sessions can be inspected without hijacking their writer locks.

`/context`: exact core/project/attachment components, last measured vs estimated tokens, remaining reserves, provider cache counters when present, last prefix mismatch and how many queued attachments would enter next request. `unknown` stays `unknown`.

`/compact --dry-run`: offline estimate of candidate checkpoint boundary, risk items and anticipated admission; **not** a generated summary. `/compact`: explicitly trigger the two-phase checkpoint and validate it. `/epochs`: lineage, checkpoint receipts/latency, summary vs first shorter request vs later warm calls, preserved constraints and failure reasons. Failed checkpoint leaves current epoch unchanged. No expensive automatic checkpoint merely because a UI panel opened.

`/diff`: visible file paths and bounded context hunks, additions/removals and summary, from the hardened git/native change receipt path. Show `untracked`, `staged`, `unstaged`, `agent-native` separately when provenance is known. Never imply a diff is wholly attributable to the agent when the working tree was already dirty.

##### 2.6 Presentation: readable, fast, not a terminal framework

A small **semantic terminal renderer** emits typed style spans, never raw model-supplied ANSI. Required: `#`–`######` headings, unordered/ordered lists, task checkboxes, paragraphs, blockquotes, bold/italic/inline code, fenced code blocks, file paths, tool summaries and unified diff additions/removals/hunk headers. Default 16-colour/256-colour palette and `NO_COLOR` / `TERM=dumb` plain-text mode; never require truecolor or Unicode box art to understand meaning. Preserve literal whitespace in code/fences/diff. Keep links text-first; no terminal OSC-8 hyperlink output until independently qualified.

Use **swiftlang/swift-markdown** (candidate 0.9.0; qualify at M4) for completed Markdown blocks if it demonstrably reduces authored parser code and has acceptable linkage. It uses cmark-gfm. Do not build a full Markdown AST/parser ourselves. During streaming, render bounded lines incrementally and then style completed blocks; avoid repeatedly parsing/repainting a multi-megabyte transcript on every token. The rendered view is always derived from canonical raw text, not stored as historical context. [S24]

Code syntax lexing for every language is **not** in the release; use legible fenced-code styling and diff-line colouring. `SwiftSyntax` is too language-specific and heavy for this baseline. `bat`, `delta`, tree-sitter grammars or generated terminal pages must not become an implicit dependency; an optional explicit external syntax highlighter can be a later feature with fallback.

Before styled spans reach the terminal, escape/neutralize untrusted ESC/C0/C1/OSC/DCS/control and bidi overrides. LF is transformed into a **typed line-break**, TAB expands into bounded spaces, and CR is rejected or made visible; raw control bytes are never passed through. Width calculation must handle combining marks, emoji, non-ASCII paths and terminal resize without truncating inside UTF-8. The sanitizer runs before ANSI generation, not after. Truncated diff/preview/output always has an honest `… truncated` marker and retained artifact reference.

#### 3. Developer experience: make the interactive layer mostly pure

##### 3.1 Ownership and one small pure module

Introduce **`NeedletailPresentation`** as a fifth small Swift target. It depends only on Foundation (and the optional Markdown parser) and the public *value/event* contracts of `NeedletailCore`. It imports **no** replxx, HTTP transport, OS terminal, GRDB or process implementation. `NeedletailCLI` owns replxx and writes terminal escape sequences; `NeedletailCore`/`SessionActor` remains the **only authority** for queue, session, epoch, capabilities and mutation state.

`Presentation` contains a reducer/projection, not a second agent/session engine:

```swift
struct UIState: Sendable, Equatable {
    var composer: ComposerState
    var suggestion: MentionSuggestionState?
    var queue: [QueueSummary]        // projection from SessionActor events
    var activeAgent: AgentSummary?
    var inspection: InspectionView?
    var status: UIStatus
}

enum UIAction: Sendable {   // keyboard event, model/tool event, completion response, resize, etc.
    case input(InputAction)
    case session(SessionEventProjection)
    case completion(CompletionResult)
    case terminal(TerminalCapabilityChange)
}

enum UIEffect: Sendable {   // *requests*, not effects performed by the reducer
    case submit(OperatorInput)
    case queue(OperatorInput, QueueKind)
    case previewFile(FileReference)
    case requestCompletions(Query, revision: UInt64)
    case cancelCurrent
    case inspect(InspectionCommand)
}

func reduce(_ state: UIState, _ action: UIAction) -> (UIState, [UIEffect])
func render(_ state: UIState, width: Int, capabilities: TerminalCapabilities) -> RenderFrame
```

Actual names can differ; separation, determinism, and event/command semantics are normative. `RenderFrame` is semantic (text runs, roles, lines, composer overlay), testable without ANSI or a PTY. `TerminalWriter` alone lowers it to escapes in one serial output owner. Never let the renderer write to the filesystem, store, process, network or user terminal directly.

Do not duplicate authoritative queue state in UIState: `queue` is a read-only *projection*. `UIEffect` is acknowledged by core events with unique IDs; optimistic pending display is visibly pending until acknowledged. Typed model/tool events enter the same projection used by headless JSONL, avoiding a second output semantics path.

##### 3.2 Fast deterministic tests (the main gate)

Run with Swift Testing (already in the Swift toolchain). Use small JSON fixture scripts/golden tests, not dependency injection frameworks or snapshot-test dependencies. Fixtures supply a sequence of `UIAction`/session events, expected `UIEffect`s, queue/epoch state and **semantic render lines**. `schemas/ux-fixture.schema.json` and `examples/ux/queue-during-stream.json` define a sample fixture envelope and action/effect oracle; the full typed action vocabulary is implemented by Codex, not guessed from arbitrary JSON. Freeze a deterministic test clock, ID generator, file catalogue, transport script and receipts; tests never call a real provider, spawn shell commands or sleep.

Use protocol seams already defined in CODEX (`ModelTransport`, `ToolExecutor`, `SessionStore`, `Clock`, approvals), plus **one** `FileCandidateSource` for `@` lookup/preview and one terminal output sink for PTY test composition. Keep fakes tiny and scripted. Integration tests use in-memory SQLite, temporary protected file roots, scripted stream chunks and stubbed exec receipts; production `SessionActor` still decides dispatch/undo/compaction. Fault injection points are named, not random delays.

A semantic/golden expectation compares content/style roles/links and stable sequence IDs—not terminal colours, wall-clock timestamps, random UUIDs or byte-for-byte ANSI. ANSI writer has separate small byte-level tests. Each fixture records initial state, actions, emitted effects, visible frames/lines, persisted receipts and forbidden side effects.

Test layers:

| Layer | What is real | Primary checks | Target fast-loop budget* |
|---|---|---|---|
| **A: reducer + semantic renderer** | Pure Swift value code | 100s–1000s of transition/sanitizer/mention/queue cases | ≤ 3s warm suite |
| **B: core integration** | SessionActor, real in-memory GRDB, scripted provider/files/process seams | queue dispatch, undo conflicts, epoch changes, stream chunking | ≤ 15s warm suite |
| **C: ANSI + line-editor adapter** | ANSI writer, replxx C bridge, injected I/O | cursor, wrapping, input line preservation, output ordering | ≤ 15s warm suite |
| **D: physical PTY smoke** | Actual built terminal binary, kernel PTY + tty signals | real keystrokes, paste, resize, interleaved stream, restore termios | ≤ 30s native suite |
| **E: real-provider qualification** | User-authorized local or cloud model endpoint | genuine prompt/caching/replay metrics | separate, gated, never on routine PR suite |

*Indicative **targets**, not measurements. Run one fixture family with a single filter in seconds after an incremental build. Report cold-build/SwiftPM resolve separately; CI publishes actual wall times and host.

##### 3.3 Small native PTY harness, no terminal emulator project

Use a test-only ~C shim (`forkpty`/`openpty`, termios, `ioctl(TIOCSWINSZ)` and signaling; platform-specific linking qualified on Linux/macOS) with a Swift Testing driver that spawns the **same interactive CLI composition root** with a scripted local fake provider. Send real UTF-8 key bytes, bracketed-paste start/end, resize and Ctrl+C into the slave PTY; collect bounded output and exit status. Where detailed cursor layout matters, use a small known VT screen fixture or a vetted **test-only** emulator dependency, not a production rendering framework. Never implement a full terminal emulator merely to test an 8-line preview.

The native suite is deliberately small and high-value: start/exit mode restoration, multiline/paste, `@` completion and preview, queue during streaming, ANSI-safe tool/model output, interrupt and held queue, renderer with 40/80/120 columns, SSH/tmux escape fallback and kill/error cleanup. Per-test hard deadlines and global teardown; no sleeps standing in for readiness. From M4 onward, CI must run the required PTY matrix on **both** operating systems and record actual `TERM` and terminal capabilities. M0 runs one feasibility scenario on Linux only, not the full PTY suite. Failing PTY checks block an interactive release even when the pure state suite passes.

A debug-only fixture executable can inject models/files/clock, but shipping `--pretend-test-passed` knobs or bypassing grants in the release is prohibited. A separate release-binary smoke run against an isolated synthetic loopback server catches wiring mistakes in the composition root. Keep headless JSONL tests independent from ANSI.

##### 3.4 Renderer and reducer invariants

- Same event transcript + explicit terminal capabilities + width + deterministic IDs => same semantic frames/effects.
- Model deltas and file-search results carry monotonically increasing revisions; late results cannot replace a newer composer query or overwrite user typing.
- Only the owner of stdout may write styled terminal bytes. The input thread cannot race the model writer into interleaved escape sequences.
- Backpressure bounds UI updates during fast streamed output. Coalesce display deltas without dropping **provider/session** events or durable tool receipts. Do not make network consumption wait on each terminal repaint. Coalesce/drop replaceable display projections; authoritative data uses bounded backpressure/spooling and an explicit overflow failure when durable capacity is exhausted.
- Queued messages are never sent while held, stale, unauthorized, or before safe delivery boundary.
- A raw source string/preview never becomes a terminal-control operation, runnable slash command or authorized tool invocation.
- `/undo` never reverts a file that differs from the recorded after-image; earlier receipts remain intact.
- `/rewind` and compaction manipulate session lineage, not filesystem state.

##### 3.5 Development commands and evidence

Planned targets and scripts (names are contracts to implement, not claims they presently run):

```sh
swift test --filter PresentationTests              # all-pure UX loop
swift test --filter InteractiveCoreTests            # scripted queue/undo/context
swift test --filter TerminalAdapterTests            # ANSI/replxx adapter
swift test --filter PhysicalPTYTests                # few real PTY tests, Linux/macOS
swift test                                          # all offline suites
needletail doctor                                   # no network
```

Add repeatable scripted fixtures `Tests/Fixtures/ux/*.json` and golden semantic frames `Tests/Fixtures/render/*.json`. Every test report includes runtime, OS/compiler, deterministic fixture ID, mock-vs-native classification and retained failure transcript. An update cannot bless an existing failure by regenerating all snapshots; golden changes need an explicit reviewed diff.

The release gate is **zero escaped controls, dropped/corrupted drafts, mis-dispatched queue entries, incorrect undo, hidden prompt additions or duplicate side effects** in mandatory fixtures. A passing screenshot alone is insufficient; match semantic state, emitted effects and durable receipts. A test's fixture oracle must not be regenerated from the program under test during that same run.

#### 4. Libraries and no-bloat decision

- **Keep** pinned `replxx`: documented C callbacks for completion, syntax highlighting, state, key binding, multiline, `write` and changing the prompt. This is suggestive but **does not prove** safe concurrent output/draft preservation. Perform the M0-C PTY spike before promising type-ahead. [S09, S25]
- **Add candidate** `swiftlang/swift-markdown` 0.9.0 **for M4 only**: published Swift Package Index candidate, AST backed by cmark-gfm. Resolve/pin/test linkage and measure incremental-build and binary cost. Prefer it to authoring full Markdown; if it does not meet the native/binary gate, explicitly scope down to plain styled lines and record that limitation rather than silently add a renderer framework. [S24]
- **Do not add** SwiftTUI, TerminalUI full-screen frameworks, SwiftSyntax, tree-sitter/grammar packs, an async UI scheduler, Rx/Combine or JS/TS. The UI is a reducer plus a line-editor adapter and a small ANSI writer. Other native packages remain the existing seven.
- **No test-only Python/Node runtime requirement**: `swift test`, Swift scripts/fixtures and a tiny C PTY shim are sufficient. Developers may locally use other tooling, but CI/release tests don't depend on it.

#### 5. Exact success/failure boundary

**UX can release** when the pure and physical tests demonstrate simultaneous streaming/composer stability, bounded `@` completion with safe preview, correctly ordered/persisted queues, side-effect-safe undo, informative agents/context/epoch views, useful Markdown/diff display and no regressions to the five-tool/core cache contract.

**UX cannot release** with a perfect mock renderer but unreadable native terminal, fast PTY mock but a broken SessionActor, duplicate UI-authoritative queue state, optimistic undo against modified user files, unavailable zero-dependency fallback advertised as working, or any requirement to install npm/Python on an appliance.

**M0–M3 remain the Linux viability gate.** The one bounded Linux PTY/redraw feasibility spike belongs in M0. Pure presentation contracts start in M1, queue/persistence contracts in M1/M2. Complete physical-terminal integration is separately authorized **M4**, including the first macOS qualification. Before M4, macOS tests are deferred, not passed. Complete UX is required before declaring a user-facing release. Do not let UI polish delay proving the real local coding/cache loop, but do not call the eventual product complete with a blocking composer and no safe undo.

#### 6. v0.3 concurrency and recovery clarifications

Queue admission is an idempotent local transaction keyed by operator command ID, not a promise that a remote provider processed a request exactly once. A lost provider response after sending is `deliveryUnknown`; automatic resend is forbidden unless a qualified provider-specific idempotency contract proves it safe. Local enqueue retries with the same ID return the original acknowledgement.

A native undo runs only at a quiescent session boundary with no in-flight tool or unresolved outcome. It creates new operation receipts and appends a concise workspace-change notice containing the affected paths/hashes/results before the next model request. It does not rewrite the earlier tool history. Partial compensation receives an equally explicit notice. The operator must still be warned that shell effects are outside undo.

Catchable termination, ordinary errors and orderly EOF must restore terminal modes. **SIGKILL, power loss and an unhandled fatal crash cannot guarantee in-process cleanup.** The PTY crash fixture distinguishes these from recoverable exits and checks durable recovery and the documented external terminal-reset procedure; it must not assert impossible signal handling.

`TERM` simulation proves capability fallback, not an actual SSH transport or tmux integration. Label simulated and real terminal paths separately; perform one real SSH/tmux spot-check at M4/release without adding it to the every-change loop.


---

## Part 5 — DEVELOPMENT.md

### Development contract — Linux first, small slices, independent evidence

Specification v0.3 · 12 October 2026. Normative for the development of Needletail, not a new feature set for the product.

#### 1. Decisions that are already made

Build the agreed local-first harness in Swift. Start on Linux, prove the headless coding loop and recovery, then integrate the terminal. Reuse qualified libraries rather than rewriting transport, SSE, SQLite, process execution or line editing. Keep the production model boundary independent of the model used to implement it.

The initial implementer is OpenCode's **Step 5 Preview Free**; `deepseek-reviewer` attacks each plan and completed minor milestone; CodeRabbit reviews the aggregate GitHub pull request for each major milestone/epic. The human owns scope, expenditure, unresolved risk and merges. Reviewers advise; executable evidence establishes what passed.

No new platform, generic agent engine, runtime dependency installer, schema universe, developer web dashboard or home-grown BDD framework. A small durable state model, a small scenario wrapper and normal Swift tests are enough.

#### 2. Platform order

**Primary builder:** Linux x86_64, Ubuntu 24.04, Swift 6.4, Swift 6 language mode. Provision a dedicated user, container or VM. Record the exact compiler build, distribution, kernel, libc, architecture, installed native build tools and container image digest where applicable. Pin the chosen image/toolchain after qualification; do not use `latest` in CI.

Every implementation slice is built and tested on Linux before it can pass. M0–M3 must run without a Mac, Xcode project, Apple-only runtime, real terminal for core tests, or credentials for live tests. The provisioned Swift toolchain is a developer dependency, not a runtime installation requirement.

M4 introduces native macOS qualification after the Linux viability decision. Fix differences in narrow adapters, not with a second session loop. Continue running Linux on every change. macOS initially targets Apple Silicon; a desired older OS deployment floor is qualified against all dependency availability requirements. M6 adds Linux aarch64 and the additional distribution claims that actually pass.

No `AppKit`, `SwiftUI`, `Combine`, `Darwin`, `Security` or platform-specific process/terminal implementation in Core or Presentation. Foundation *value types* are permitted. OS imports belong in Runtime/CLI platform shims. Keychain is optional macOS credential storage later; env/file references establish the first credential contract. Linux-only convenience code must likewise stay behind the platform boundary.

Test case sensitivity, raw UTF-8 filenames, Unicode-equivalent spellings, path separators, executable modes, symlinks, filesystem replacement, CA roots, process groups and clocks intentionally. Filesystem capabilities are recorded; an APFS default is not assumed equivalent to ext4. A Linux container tests a Linux kernel, not a macOS kernel. QEMU/cross-compilation establishes build coverage unless native execution is separately demonstrated.

#### 3. Workspace and operational safety

Use one dedicated source checkout. Inspect and record existing dirty/untracked files before doing anything; do not stash, reset, clean or overwrite unrelated work. Build outputs and scratch fixtures stay in explicit project-owned directories. Never recursively inspect the user's home, mail archives, private repositories or model volumes looking for context.

The public specification and new open-source code may be sent to the selected development/review services. Existing private source, request dumps, mailbox content, financial/legal material, credentials and LAN deployment notes may not. Synthetic protocol fixtures are the default. An allowlisted, bounded explicit packet defines what each reviewer receives. A provider's stated retention policy does not waive this boundary.

No sudo, host reconfiguration, driver/kernel changes, service restart, model reload, GPU eviction, template editing or server-slot manipulation to make a test pass. Preserve the existing Pi baseline and serving workloads. Build/test concurrency is bounded by the builder's assigned resources; begin with four build jobs and one live inference request, adjust from measurements and operator-approved limits. Never infer that all host CPUs/GPUs/memory are available.

Existing project environments, including Conda, can be invoked with approved executable paths. Do not activate/repair/install packages globally. If a build tool is missing, identify it and use the provisioned builder path; do not install Node/npm/Bun on an appliance. Build-time SwiftPM fetches for reviewed pinned dependencies are separate from forbidden application-runtime installation.

#### 4. Role and model binding

Before the first slice, record the installed OpenCode version, exact available implementer `provider/model` identifier, local `deepseek-reviewer` agent binding, protocol, tools, endpoint locality and granted spend. Do not copy secret values into the manifest.

The public OpenCode Go documentation currently lists `step-5-preview-free`, with a limited-time free offer. Resolve the full identifier from `opencode models`; do not assume `opencode/...` and `opencode-go/...` are interchangeable. [S27–S29]

`deepseek-reviewer` is the user's existing **agent alias**, not permission to invent a new DeepSeek model name. Inspect the locally configured definition and verify it is independent from the implementer. Use its configured local/cloud route under existing approval; do not replace it or copy its credentials into repo config. Reviewer absence is `BLOCKED_REVIEW`, not self-review under a renamed label.

At the start of each development session, confirm the selected route is still available under the approved terms. Rate limits/expiry/auth failure produce a recorded blocked state with the branch intact. Retry only bounded transient failures (at most two, obeying Retry-After); do not rotate accounts, buy credits, enable automatic top-ups or fall back to a paid/other model. Alternative routes require operator choice. The product itself remains provider-neutral.

OpenCode is an already-provisioned development client. Do not embed its runtime, provider catalogue, tasks, plugins or config loader in Needletail. Disable unnecessary development-client automatic share/update/plugin/LSP download behaviour using supported settings for the installed version. This is configuration, not a private OpenCode fork. [S29–S30]

#### 5. Test-first slice loop

A minor milestone is a small coherent behaviour change, normally one to three use cases or one closely coupled boundary. Rough target: no more than about 400 hand-written production lines or ten meaningful source files in a slice. These are reviewability guides, not incentives to compress code, hide files or split an atomic safety fix incorrectly. Larger slices need an explicit rationale and a bounded reviewed plan.

**Plan:** inspect the actual baseline; state goal, exclusions, use-case IDs, invariants, Given/When/Then outcomes, effects forbidden, proposed seams, changed files, tests, fault points and finish conditions. Do not describe an imaginary codebase. DeepSeek reviews the plan before implementation. Resolve blockers or hold the affected slice.

**Red:** add the smallest executable behaviour tests. Build the necessary empty interface/stub when needed, but distinguish a compile failure from a real assertion failure. Record the old production revision failing the new assertion for the intended reason. For a brand-new interface, first demonstrate a deliberately incorrect implementation/no-op fails the oracle. Missing imports, network failure and a broken fixture are not useful RED evidence.

**Green:** implement the smallest correct production path. Use the real reducer and adapters behind explicit test seams. Do not introduce a parallel test implementation, special canned success, a hidden live endpoint, or CLI-only behaviour that is absent from headless operation.

**Refactor:** remove duplication and clarify boundaries while rerunning the focused tests. No speculative framework, unrelated cleanup, new dependency or protocol change under a feature slice. Concurrency checking stays enabled. `@unchecked Sendable`, unsafe flags and unchecked continuations require an explained audited boundary, never a blanket compiler-silencing patch.

**Attack:** run the relevant negative/no-op/conflict/recovery cases and named fault injections. Ask DeepSeek to attack the frozen diff and executed evidence. Findings require concrete counterexamples or clearly marked uncertainty. Fix substantive findings, add regression tests, rerun and re-review changed contracts. Do not modify frozen expectations just to obtain green.

**Close:** freeze code/tests/fixtures at a commit; record exact tests, outputs, timing, coverage tier, review disposition and limitations. Minor milestones advance automatically inside the authorized epic once all gates are satisfied. Do not request approval after each tiny green test. Stop at the designated viability/scope/remote-write boundaries, not at arbitrary context limits.

#### 6. Evidence and status are not prose votes

For each slice retain: source SHA and tree hash; baseline SHA; plan digest; dependency-lock digest; OS/toolchain/architecture; exact commands; exit codes; test-run and per-case results; RED/GREEN evidence; case/variant counts; timing and memory where relevant; review receipts; limitation/disposition list. Failure output must be retained, not replaced by a summary sentence.

Use `PASS`, `FAIL`, `BLOCKED_REVIEW`, `UNQUALIFIED_ENVIRONMENT`, `DEFERRED_BY_PLAN` and `NOT_IMPLEMENTED`. Keep test, review and environment status as separate fields. A model's “PASS”, a successful process exit, a registry entry, a skipped test or a generated JSON result is not interchangeable with a completed native test.

Use one `STATUS.md` for current milestone and blockers. Specifications express desired behaviour; do not continually rewrite them to describe whatever happened. Plans live under `plans/`. Local raw reports live under gitignored `.needletail-dev/`; public summaries must be sanitized. Do not generate a report commit after the final CodeRabbit review and pretend the new head was reviewed; keep final evidence in GitHub review comments/CI artifacts attached to the reviewed SHA.

A planned script command in this packet is an implementation requirement, not a claim it already exists. M0 implements the developer entry points and proves them. Exact dependency hashes, CI action hashes, container digests and repository URLs are captured from real systems; this packet intentionally does not manufacture them.

#### 7. Change control without paperwork theatre

Write a short decision record only for a meaningful choice: changing a dependency, public wire/tool contract, persistence schema, platform floor, security boundary, semantic oracle, evidence classification or milestone scope. State the problem, smallest options, chosen tradeoff, test consequences and rollback. Routine naming or local refactoring does not require an ADR.

A discovered specification defect can be fixed. First retain the failing counterexample, explain why the written requirement is wrong/impossible, obtain adversarial review, and record the amended oracle before measuring the new outcome. Never hide it as “fixture maintenance”. Do not soften safety requirements to chase a speed target.

Timing targets are diagnostic budgets before a measured baseline exists. Once qualified on the reference runner, baseline them and investigate material regressions; separate compile/resolve time from warm test execution. Fewer reliable assertions are better than thousands of sleeps or duplicated scenarios. Do not remove important cases to hit a vanity runtime.

#### 8. GitHub and release hygiene

One integration branch/PR per epic is the default, with reviewed minor commits. Split a large epic into coherent prerequisite PRs rather than one unreviewable dump; the epic closeout still reviews aggregate integration risk and acceptance coverage. Preserve an explicit base commit.

No automatic merge. CodeRabbit full review, Linux CI, the scheduled native platform matrix, case/evidence reconciliation and the human risk decision must apply to the latest intended head. M0 bootstraps the GitHub review installation/branch protection when a remote has been authorized; missing access is a visible gate, not permission to create a repository elsewhere.

CI runs offline application tests with no provider/reviewer secrets. Source fetching occurs only in a separate pinned dependency/build stage. Fork PRs do not receive credentials or run untrusted checkout code inside a privileged `pull_request_target` job. Pin third-party actions to verified immutable revisions; token permissions default to read-only. Release uploads, signatures and credentials belong to a separate trusted workflow. [S34–S35]

Release readiness means the actual packaged executable works on each claimed target with no Swift compiler or Node/Python runtime. Shipping a folder with declared native libraries is acceptable. Publish an MIT licence for original code, dependency notices, hashes, SBOM, supported platforms, migration/recovery instructions and isolation limits. Signing/notarization is claimed only when performed with provisioned credentials.

#### 9. Stop rules

Stop the affected work on: an unapproved route/cost; unavailable independent review; native-platform gate failure; unknown side effect; unexpected private data exposure; dependency licence/resolution conflict; loss of boundedness; incoherent semantics after two substantive review cycles; a required remote action without permission; or M3 completion awaiting the viability decision.

Leave the workspace intact, record the smallest concrete blocker and complete independent offline work already authorized. Do not endlessly debate, quietly waive the gate or throw away the project. The complete M4–M6 plan is present, but a missing resource is not evidence that it passed.


---

## Part 6 — TESTING.md

### Testing contract — behaviour labels, real assertions, cheap state exploration

Normative v0.3. No Cucumber/Gherkin runner, step-definition layer, Quick/Nimble requirement, UI automation framework or bespoke testing product.

#### 1. The unit of coverage is a behaviour

Use Swift Testing from the toolchain: ordinary `@Test`, descriptive names, feature/layer tags, parameterized cases and `#expect`/`#require`. It already supports these facilities on Linux and Apple platforms. [S31]

Each product acceptance case has one stable ID, a feature, a meaningful stimulus and a required outcome. `ACCEPTANCE.md` is the reviewed human catalogue; `cases/catalog.json` is its normalized index for automation. They must agree. Tests bind to those IDs rather than creating a second prose scenario universe. Detailed Given/When/Then lives next to the actual test/fixture; do not require the author to restate it in three formats.

The test body makes setup, action and observation evident. For example, `UX-UNDO-02 / user changed file after native edit` has:

```text
Given: an original file, a completed native edit receipt, and a later external edit.
When: the user requests undo at a quiescent boundary.
Then: a conflict is reported; the later file bytes and original receipt remain intact.
Forbidden: any restore/delete attempt, successful undo receipt, or hidden history rewrite.
Evidence: a fast reducer case plus a native temporary-filesystem integration case.
```

A success, denied/no-op, malformed-input, conflict, interrupted/recovery and boundary case are different behaviours when they produce meaningfully different obligations. Merely changing a name, seed, whitespace or input chunk size is a **variant**, not additional semantic coverage. A parameterized test can cover many variants of one case.

#### 2. Lightweight registration, not a new framework

A test display name begins with the stable case ID. Use a tiny test-support wrapper only to associate `(caseID, variantID, evidenceLayer)` with the current Swift Testing invocation and output. Keep native assertions and failure handling in Swift Testing. Do not wrap assertions in a DSL, parse English steps or write a custom discovery runner.

An illustrative test shape is in `examples/testing/BehaviourTest.swift.txt`. It intentionally references future product APIs; it is an authoring pattern, not compiled application code. The wrapper must not swallow throws, known issues, crashes or assertion failures. M0 qualifies the selected Swift toolchain's discovery/result output with a passing, failing, skipped and parameterized fixture before adopting a reporter.

A small Swift reporting target may join **actual runner results** to the catalogue using full discovered test IDs. Use the documented machine-readable result format supported by the pinned toolchain; verify it rather than invent flags or call unsupported testing SPI. If stable per-case output is unavailable, use a bounded per-case invocation/exit record for the gate until a reviewed better route exists. Never infer passing tests from grep of the source code.

Registration alone is not coverage. The reducer must have been exercised and relevant observable assertions inspected. A runtime result proves execution, not that an assertion is meaningful; reviewer inspection and deliberate failing-oracle probes supply the second part. A no-op body with the correct case label does not qualify.

Do not add a production dependency for these helpers. The initial wrapper/reporter should remain a few small files (rough review threshold: 500 hand-written lines excluding fixture data). Exceeding that threshold requires simplifying the design or explaining an actual unmet requirement, not packaging it into a new framework.

#### 3. Minimum case metadata

Required authoring concepts:

| Field | Meaning |
|---|---|
| `case_id` | Existing stable ID from the catalogue. |
| `variant_id` | Stable meaningful variant, e.g. `modified-postimage`, not a random UUID. |
| feature / invariant | Which behaviour and safety obligation the case exercises. |
| Given / When / Then | Explicit preconditions, stimulus, observable required outcome. Comments plus test code are sufficient. |
| forbidden effects | What must **not** happen; assert calls/receipts/bytes as appropriate. |
| evidence layer | Pure, integration, native process/filesystem, terminal adapter, PTY, live provider, packaging, or review/process evidence. |
| deterministic inputs | Clock, IDs, seed, event/chunk sequence, fixture revision. |

Per-run records add the subject SHA/tree, toolchain, platform, timestamps/duration, actual test identifier, result, command/exit code and artifact references/hashes. `schemas/case-result.schema.json` supplies the report contract; example files use synthetic identities and are marked examples, never gate evidence.

#### 4. Test layers and planned commands

M0 implements these entry points. They are not scripts already executed by this packet.

| Command | Included work | Warm execution target | When it runs |
|---|---|---:|---|
| `./dev test case UX-UNDO-02` | All currently implemented deterministic variants of one case | Seconds | During a change |
| `./dev test quick` | Pure core/reducer/render/policy/codec tests; no real I/O | ≤3 s | Every edit/commit |
| `./dev test integration` | Production actor/store logic, scripted providers and bounded real temp-file/SQLite checks | ≤15 s | Relevant slice, every PR |
| `./dev test native` | Process groups, pipes, disk faults, migrations, socket/HTTP adapter contracts | Measured, bounded; initial ≤30 s | Relevant slice, every PR |
| `./dev test terminal` | ANSI/line-editor adapter, no live model | ≤15 s | Terminal changes from M4 |
| `./dev test pty` | Eight real terminal scenarios, actual PTY/keystrokes/signals | ≤30 s | M4 terminal slices, epics/release |
| `./dev test offline` | All scheduled offline layers; no external model/reviewer traffic | Measured aggregate | Epic/release |
| `./dev test live --profile NAME` | Explicit live endpoint qualification, separate budget/consent | Separate | M3/M5/release only |
| `./dev coverage` | Reconcile case IDs, results, required tiers, skips and pending gates | Small | Every PR/epic |

Targets exclude dependency resolution and compilation. Report incremental build, cold build, warm suite and individual slow tests separately. Report runner hardware and SwiftPM jobs. No performance pass before measurement. One slow budget miss gets diagnosis, not deletion of tests or arbitrary expectation relaxation.

Bare `swift test` remains usable, but `./dev test quick` is the routine loop. Make test targets and filters explicit so physical PTY/native stress/live calls are not accidentally part of every save. Live suites require explicit authorization and are absent/disabled by default with reasons. No external credentials are necessary for any offline suite.

#### 5. Pure/virtual state tests first

Run the **production** transition/reduce/render functions. Supply a virtual monotonic clock, deterministic IDs, fixed file candidates, scripted model events and explicit completion actions. No sleeps, actual shell, terminal, filesystem, network, environment variables or random wall-clock seeding in the pure layer.

Check both resulting state and requested effects. Examples: queueing while busy yields one admission effect; stale preview completion yields no mutation; cancellation holds the queue and suppresses the late request completion; opening a panel yields no provider effect. Compare semantic frames, text roles and stable IDs, not ANSI colour numbers or random timestamps.

At minimum exhaust legal transition cases plus relevant illegal transitions. Explore bounded event permutations for cancellation vs completion, enqueue vs commit acknowledgement, checkpoint vs queued input, preview revisions and undo vs external change. Bound generated traces (e.g. length ≤20 with named fixed seeds), retain the shortest failing trace and promote it to a named regression. A few deterministic loops are sufficient; no scheduler/model-checking framework is required.

The expected result cannot be regenerated from the same reducer during the run. Use independently reviewed expected events/frames and small invariants. A second model implemented as “oracle” that shares the production bug is not independent evidence.

#### 6. Integration and adapter qualification

In-memory GRDB tests check production SQL/domain transactions without disk overhead. Real temporary-file SQLite tests separately check reopen, ownership/migration and process-kill points. Do not report in-memory tests as crash durability. Use resource ownership scopes for temporary roots; no global fixture paths.

Scripted model tests must include raw wire bytes as well as convenient decoded events. Exercise stream splitting inside UTF-8, SSE syntax, argument JSON and native completion signals. Fakes and real adapters share a conformance suite where meaningful. Wire fixtures retain provenance and are synthetic/sanitized; no private request dumps in public fixtures.

Native process tests use a small test executable with modes for dual-pipe flood, blocked reads, same-group grandchildren, ignored interrupt and deliberately detached descendants. Use explicit readiness handshake/barriers, not guessed sleep durations. Test teardown owns exact PIDs/groups and bounded deadlines. Concurrent test workers cannot share process groups, ports or databases.

Filesystem tests distinguish supported optimistic/cooperative checks from an impossible universal CAS claim. Cover exact bytes, duplicate match refusal, parent-path escape, changed postimages and mid-compensation failure. Native faults must retain before/after hashes and operation receipts. Do not mark a case native because the fixture itself wrote a temp file while the operation under test remained fake.

#### 7. The deliberately small physical-terminal bill

M0 has **one bounded Linux feasibility spike**: line editor live; synthetic streaming output; unsent multiline/Unicode draft; simple completion callback; resize; cancel; verify preservation/cleanup. This tests the risky library fit before relying on it. It is not product TUI development or a Mac gate.

M1–M3 work mainly with virtual state and headless integration. M4 implements full `@`/queue/undo/navigation/rendering behaviour in pure tests first, attaches the line editor/ANSI writer second, then runs the eight existing `PTY-01`–`PTY-08` scenarios on Linux and macOS.

The test driver uses real `openpty`/`forkpty`-family facilities, terminal attributes, key bytes and `TIOCSWINSZ`, through a small test-only platform shim. A structured readiness protocol is mandatory. Each case has a hard deadline; global cleanup terminates only its child/group and captures transcript on failure. No browser, GUI scripting, OCR or screenshot matching.

Detailed cursor assertions need a bounded tested VT projection or a vetted **test-only** parser; do not write a whole terminal emulator. Distinguish output-byte correctness from screen-state correctness. An ANSI substring alone does not prove a preserved draft or correct cursor position.

Recoverable exits must restore modes. SIGKILL/power loss cannot run cleanup: test durable recovery and the documented external reset rather than a fabricated restoration guarantee. `TERM` emulation is not actual SSH/tmux execution. Add one real path spot-check for release, separately labelled.

Use the same production interactive composition root with injected test adapters. A small release-binary smoke against an isolated synthetic loopback endpoint catches accidental debug-only behaviour; no shipping “test success” or bypass-grant flag.

#### 8. Coverage reporting that cannot inflate itself

Report a matrix: feature → case → variants → required evidence tiers → actual results. Within each family show planned cases, implemented cases, executed cases, passing cases, failed cases, skipped/deferred/blocked cases and unqualified layers. Keep variant counts separate. Unioning 100 seeds of a case adds one semantic case, not 100.

A case is satisfied for a gate only when all of its required variants/tier/platform obligations due at that milestone pass. A pure render pass cannot satisfy a PTY obligation. A Linux pass cannot satisfy a macOS obligation. A reviewer-completed governance check cannot satisfy a runtime assertion. A later case is explicitly deferred, not silently removed from the denominator.

The catalogue starts with the preserved 168 product/UX cases and adds 32 development/concurrency/portability/review cases. **All 200 are specifications, not executed passes.** `cases/catalog.json` records the initial due milestone and evidence needs; each slice refines the concrete variants without renumbering existing cases. Requirements pending until M4/M6 are visible from the beginning.

An exact duplicate coverage key is an error. Redundant tests are allowed for regression/localization but do not boost distinct-case coverage. Missing IDs, unknown IDs, zero executed assertions, skipped variants, absent raw results and mismatched subject SHAs fail reconciliation. Do not claim “100% semantic coverage” of all possible behaviour; report coverage of the declared reviewed cases.

#### 9. Oracle strength, metamorphic checks and fault injections

For each high-risk family, prove at least one deliberately wrong implementation is caught: execute an incomplete tool call; skip postimage checking; dispatch a held queue; accept a stale effect; bypass local-only routing; replace old prompt material; pass raw ESC to the terminal; replay an unknown operation. Keep these changes in disposable test branches/patches and restore the baseline; do not add production fault switches to pass certification.

Useful metamorphic checks: arbitrary stream chunking does not alter native events; display width/colour does not change canonical prompt bytes; duplicate enqueue acknowledgement does not duplicate history; irrelevant file-name changes do not change authorization; compaction inspection does not create network traffic. State the transformation's assumptions; filename changes are not invariants where identity/policy depends on the filename.

Named faults at commit/rename/dispatch/receipt boundaries are repeatable. Fixed-seed generative tests and minimized counterexamples supplement examples, not substitute for them. CI may run extra bounded seeds at epic/release; failures remain blocking even if a rerun happens to pass. No automatic “retry until green” classification.

#### 10. Live model and quality comparisons

Use the existing local service on explicit operator approval. Do not change its context/slots/templates or warm/cold state destructively. Compare with the installed Pi baseline using the bounded task protocol in ACCEPTANCE.md, retaining all failures and task-level outcomes. Exclude model/network latency from pure harness-overhead claims.

Live tests use synthetic repositories/evidence, bounded requests and no private data. Cache hit counters, client-prefix equality, latency and model quality are separate observations. Unknown backend counters remain unknown. Same-process endpoint limits do not control other clients. Cloud access is optional until the scheduled live cloud milestone, never a routine CI dependency.

There is no model-judged replacement for executable tool/protocol/security assertions. A model may propose adversarial tests or evaluate subjective findings with explicit provenance; it cannot declare a missing integration passed.

#### 11. Report validation is deliberately bounded

Schema validity checks shape, not truth. The gate additionally rejects `kind: example`, placeholder/all-zero identities, unknown or duplicate case/variant/tier keys, mismatched real source/runner identities, missing evidence files, digest mismatches and stale results. A valid-looking JSON object written by the implementer cannot certify its own run. Review accepts require actual packet/source evidence; an open blocker or unresolved major prevents acceptance even if the JSON `verdict` says accept. Do not pretend schema validation can prove assertion quality or reviewer independence.

The native cloud protocol cases require offline conformance for each adapter; a separate M5 live route report must qualify at least one authorized cloud route. Do not read a family label as requiring every possible provider/account to be live-tested. The release support matrix must identify which adapter routes have only offline evidence. `CACHE-13` (main/consult contention) closes in M5 when consultation exists; its in-process admission primitive is tested earlier.


---

## Part 7 — REVIEW.md

### Review protocol — Step 5 builds, DeepSeek attacks, CodeRabbit integrates

Normative v0.3. Review tooling is external to the Needletail runtime.

#### 1. Responsibility and cadence

| Role | Responsibility | Not authorized |
|---|---|---|
| Step 5 Preview Free | Inspect, plan, write tests, implement the approved slice, run evidence, fix findings | Self-certify independent review; silently switch model; change scope or spend; auto-merge |
| `deepseek-reviewer` | Independent plan review and completed minor-milestone/diff review | Edit source/oracles; merge; grant itself tools/credentials; recursively delegate |
| CodeRabbit on GitHub | Aggregate epic PR review, cross-file integration, missing cases and boundary regressions | Substitute for CI or human approval; silently apply unreviewed patches |
| Human maintainer | Resolve genuine ambiguities, accept bounded risk, authorize remote/cost/scope changes, merge | A bot's status is not their approval |

DeepSeek reviews each minor plan before implementation and each completed minor milestone. CodeRabbit reviews each major milestone/epic, not every keystroke. The first major gate is M0, including the specification/testing/bootstrap design where code is not yet substantial. M3 adds the explicit product-viability decision. The schedule in MILESTONES.md is authoritative.

#### 2. Independent reviewer packet

Create an explicit immutable packet with task/scope; relevant specification clauses; invariant/case IDs; plan; base/head SHA and diff; concrete affected files; dependency changes; exact test commands/results/failure traces; unknowns; and required review type. Include enough unchanged context to check the boundary. Do not dump the whole repository/history by default or omit a risky file merely to fit a budget.

Each review invocation records alias plus actual provider/model route, packet digest, subject code/tree/plan digests, timestamp and tool access. Record whether the reviewer inspected source, raw evidence, or actually reran tests. Read-only source/search is allowed; shell access is not magically read-only. Test re-execution uses a disposable source snapshot/scratch environment under its own limits, not write access to the implementer's working tree.

Review output is structured findings plus a disposition recommendation. Each finding has stable ID, severity, affected invariant/case, concrete location, failing input/trace or missing-evidence argument, expected vs observed behaviour, and suggested smallest test/fix. Speculation is marked as such. The reviewer can return `NEEDS_EVIDENCE`, not force a false binary certainty.

The reviewer sees the contract and evidence, not an instruction that the implementer is correct. After review, the implementer owns fixes. Prompt text, repo comments or model output cannot change this authority boundary.

#### 3. Severity and bounded convergence

- **Blocker:** data loss, unauthorized access/exfiltration, duplicated side effect, fabricated evidence, unsound continuation/cancellation, or another violated core invariant. Must be fixed before the gate; not waived by the implementation agent.
- **Major:** broken required use case, significant concurrency/recovery/portability error, missing required native test or unreviewable integration. Fix before closure unless the human explicitly changes the affected scope with a traceable decision.
- **Minor:** localized maintainability/performance issue without a demonstrated required-behaviour failure. Fix or document a bounded follow-up with owner and rationale.
- **Suggestion:** optional improvement/style preference. It is not automatically a blocker.

One initial review plus one substantive re-review is the normal budget. A third narrow verification is allowed only to check a concrete already-fixed issue; it must not restart a wholesale design debate. Remaining fundamental disagreement is `BLOCKED_REVIEW` for the human, not automatic acceptance after a retry count. Never ask the reviewer repeatedly until it happens to say PASS.

A justified rejection is legitimate: retain the finding, counterexample analysis and evidence showing why it does not apply. Do not implement contradictory reviewer suggestions, gratuitous frameworks or an impossible cleanup guarantee just to clear comments. No blanket “all resolved” response.

#### 4. Subject identity and freshness

Plan review binds to plan digest plus baseline commit. Minor review binds to exact base/head and relevant file tree. Changed source, tests, fixtures, dependency locks, CI or contracts invalidate affected review results. A previous passing review cannot be relabelled with a new SHA.

Finalize code before asking for the final review. Store raw local review outputs outside the source tree; attach final report/artifact links to the PR/CI run rather than creating an unreviewed “report update” commit. If a commit changes only documentation, still disclose it and obtain the appropriate incremental review; never silently declare an exclusion after the fact.

For an epic, freeze the intended PR head, run required CI, request the full CodeRabbit review, address findings, then obtain an incremental review at the new final head. The final review must account for the aggregate base-to-head change, not only the last patch. Small prerequisite PRs are allowed when an epic becomes too large; record aggregate integration coverage explicitly.

#### 5. CodeRabbit operation

The supplied `.coderabbit.yaml` opts into epic-labelled, non-draft review, keeps actual review status visible, disables decorative poetry and automatic code-generation/finishing touches, and supplies boundary-focused path instructions. The current official configuration reference documents these fields. Validate the configuration against the installed service schema in M0; account/organization settings and plan features can still differ. [S32]

When an epic is ready, request `@coderabbitai full review`. This reviews the entire PR; `@coderabbitai review` is incremental. Use the latter after fixes with the subject SHA recorded. Do not invoke resolve/approve commands merely to turn a status green. [S33]

No comments is not proof a full review happened. Confirm completion, base/head, included files and any skipped/excluded files, rate-limit errors or truncation. A summary-only response or failed review leaves the gate incomplete. `review_status` reports state; `fail_commit_status` addresses service review errors. Neither proves there are no substantive findings. Do not confuse them with safety checks.

Branch/ruleset settings must require real Linux CI and the actual observed CodeRabbit check/review signal appropriate to the installed service, plus the maintainer's acceptance. Never invent a check name. If CodeRabbit is absent or unavailable, retain the draft/review-ready PR and report `BLOCKED_REVIEW`; no silent substitute. [S34]

CodeRabbit reads only the new project and explicit relevant context. Disable automatic cross-repository knowledge/MCP/web expansion for this project. Do not upload private diagnostics. Cloud review is an explicit development boundary, not permission for the shipped harness to export user work.

#### 6. Merge evidence and governance

CI artifacts are generated by a trusted runner for the actual subject SHA; checked-in JSON saying `PASS` cannot satisfy a required gate. A contributor must not bypass validation by editing the validator/workflow in the same unreviewed PR. Changes to gates/fixtures/workflows receive explicit maintainer review and are evaluated using trusted baseline controls where possible.

GitHub secrets and self-hosted runners are not exposed to untrusted fork PR code. Review-generated patch suggestions are untrusted proposed source changes: apply deliberately, test, review. The reviewer is not a privileged execution channel. [S35]

An epic closes only with zero unresolved blockers, acceptable dispositions for every other finding, required runtime evidence for its current scope, latest-head review and maintainer merge authorization. Passing AI review is not a substitute for any of these.

A review receipt may have `actual_model: null` for a managed CodeRabbit service whose exact underlying model is not disclosed. Record that as unknown, with the actual service/run identity and URL. For the locally configured DeepSeek alias, resolve the actual model from its authorized definition; missing identity is an explicit qualification gap, not a guessed model name.


---

## Part 8 — MILESTONES.md

### Milestones and epic gates

Normative v0.3. M0–M6 are **major milestones / epics**. M0-A, M0-B etc. are minor milestones. Every minor plan and completed slice gets `deepseek-reviewer`; every epic gets a GitHub CodeRabbit review. The maintainer owns merges and the M3 viability decision.

The receiving implementation agent is initially authorized to work through **M0–M3 only**, subject to these gates. M4–M6 are fully specified but require the continuation decision. Do not seek permission after each routine passing slice; do not skip independent review or remote-write authorization.

#### Gate schedule

| Epic | Product outcome | Mandatory native platform | Physical terminal spend | Closeout |
|---|---|---|---|---|
| M0 | Real Linux build/dependency/test foundation | Linux x86_64 | One bounded feasibility probe | CodeRabbit + maintainer |
| M1 | Pure state, strict config, headless protocol loop | Linux x86_64 | None beyond M0 regression when relevant | CodeRabbit + maintainer |
| M2 | Safe tools, persistence, queue/undo contracts and recovery | Linux x86_64 | None | CodeRabbit + maintainer |
| M3 | Real local coding and two-phase checkpoint qualification | Linux x86_64 | None | CodeRabbit + explicit viability decision |
| M4 | Complete UX and native macOS port | Linux + Apple Silicon macOS | Eight PTY cases after pure/adapter tests | CodeRabbit + maintainer |
| M5 | Native cloud routes, bounded consultation and accounting | Linux + macOS for shipped paths | Relevant regression only | CodeRabbit + maintainer |
| M6 | Clean-host distribution and release qualification | Every claimed target | Bounded final matrix + real path spot-check | CodeRabbit + release approval |

#### M0 — prove the building blocks on Linux

##### M0-A: bootstrap, case ledger and independent review

Inspect the supplied source directory and current Git state; no destructive initialization. Verify the installed Swift toolchain/OpenCode and exact Step 5 route; inspect `deepseek-reviewer` binding without copying secrets. Record provisioned resources and allowed scratch roots. Read the spec and make a short M0 plan that identifies risky dependency/terminal assumptions.

Start with native Swift Testing. Implement the small `./dev` entry points for build/quick tests and case reconciliation. Qualify test discovery/reporting using intentional pass/fail/skip/parameterized examples; keep demonstration failures outside the ordinary green suite. Prove the reporter cannot treat a missing/skipped/unexecuted case as passing. Freeze the acceptance catalogue and keep future cases visible as NOT_IMPLEMENTED/DEFERRED, not false passes.

Create a minimal `STATUS.md`, source layout, MIT licence/notices scaffolding and gitignore. No web dashboard, framework or BDD parser. Establish GitHub remote/CodeRabbit/ruleset only when the repository has been explicitly selected and remote changes authorized; unavailable access is a named review gate.

##### M0-B: dependency graph and native primitives

Resolve the retained exact candidate pins on Linux. Commit the real Package.resolved, identify build plugins/native/transitive code and notices, and test minimal streamed HTTP/SSE, cancellation, subprocess dual-pipe output and SQLite reopen. Record real errors before proposing a small reviewed pin adjustment. No fabricated package graph; no downgrade merely to silence an uninvestigated Linux error.

The primitives use the selected production libraries, not an entirely different convenience stack. Keep synthetic loopback servers and child executables test-only. Separate pure tests from native/process work and record warm/cold timings.

##### M0-C: line-editor feasibility only

Bridge the pinned replxx C API on Linux. With input live, stream synthetic output, preserve an unsent Unicode/multiline draft, invoke a simple synthetic completion/preview callback, resize and cancel. Drive the real PTY with bounded deadlines and readiness. This is one feasibility scenario, not eight product PTY scenarios or a macOS requirement.

If concurrent redraw is not viable, document the exact failing trace and compare the smallest maintained line-editor alternative under a narrow ADR. Do not build a custom full-screen terminal framework. Headless work may continue only within an explicitly recorded affected-feature hold; no claim of passing interactive viability.

##### M0-D: clean Linux runtime and CI foothold

Build a release executable/bundle with declared native linkage; execute help, offline config inspection and a synthetic smoke on clean Ubuntu without Node/Python/Swift compiler. A dynamic runtime bundle is acceptable. Do not make fully static linking a months-long prerequisite.

Create minimal Linux CI using verified pinned actions/toolchain. Tests run without model secrets. Record compile/native/runtime evidence separately. Request the first full CodeRabbit epic review, including testing/bootstrap and boundary decisions; fix/triage findings before merging.

**Exit:** actual Linux foundation, credible reporter and primitive evidence, measured dependency/runtime inventory, one PTY feasibility result, independent review. Full PKG/native-release catalogue remains due at M6; a thin M0 smoke is not complete product acceptance.

#### M1 — pure session model and headless request loop

##### M1-A: strict configuration, capabilities and immutable profiles

Test before implementation: duplicate JSON keys/aliases; unknown fields; forbidden native overrides; tools-none/sealed intersection; malformed origins; offline help/doctor; repo attempts to grant tools or routes. Implement typed configuration and first local Chat Completions profile. No discovery traffic or secret values in logs/config exports.

##### M1-B: production transition model and durable admission shape

Build SessionState/Event/Effect and production transition function, SessionActor reservation semantics and generation checks. Introduce the small pure Presentation target now for composer/event contracts, not terminal integration. Prove cancellation cannot resurrect work, queue acknowledgement is idempotent and pure render has no I/O. Define request/operation/history IDs and storage contracts needed by M2.

##### M1-C: streamed wire fidelity

Implement the first native adapter using the chosen transport/SSE components. Test byte splits, native completion, interleaved calls, signed/opaque/unknown blocks, resource bounds and partial-response errors. Complete tool calls are proposals; they do not execute during stream assembly. Raw record, native replay and display projection are distinct.

##### M1-D: headless end-to-end with scripted effects

Exercise the real composition root through a scripted read/edit/test/repair loop with mocked tool effects and production session transitions. Deliver structured JSONL and correct exit/status distinctions. Include denied tools, approval-required stops, budgets, cancellation and hold behaviour. No terminal escape output in JSONL.

**Exit:** due CFG/NET/WIRE/CORE/POLICY cases at the specified mocked/pure tier, deterministic state tests, stable instructions/schema fingerprints, no Core/Presentation platform leakage, CodeRabbit review. Real tool effects and complete durability remain M2.

#### M2 — tools, storage and recoverable user operations

##### M2-A: artifacts/store/operation ledger

Implement GRDB migrations, session ownership, paging, artifact commit ordering, quotas, intents/results and reopen reconciliation. First in-memory tests, then real temporary databases and named process-kill faults. No transaction held over an await; no automatic re-execution of unknown side effects.

##### M2-B: exact native file tools and search

Implement read/search/edit/write with bounded content and explicit root grants, safe rg invocation and disabled ambient config. Secure quota-accounted preimages before eligible writes. Test zero/one/multiple edit matches, byte fidelity, parent escapes, optimistic conflicts and partial batches. Preserve dirty user work. Do not claim an arbitrary same-user writer can be defeated by hash checks alone.

##### M2-C: execution and permission gates

Implement argv/intentional shell distinction, approved environments, dual-stream draining, deadlines, process-group teardown and failure receipts. Test existing Conda executable invocation, refusal in observe mode and headless approval-required behaviour. Escaped daemons remain an exposed limit, not a silently accepted guarantee.

##### M2-D: queue, attachments and undo in virtual/headless form

Implement authoritative durable queue admission/hold/reconcile; structured mention snapshots and stale dispatch rules using injected candidates; native change groups/preimages; undo eligibility and compensation; rewind lineage without filesystem mutation. Test all required behaviour through pure state and core/temp-file integration before wiring terminal controls. Append truthful undo notices to later model context. Quiescence and unresolved-outcome checks are mandatory.

**Exit:** due TOOL/PROC/STORE/POLICY and core queue/undo/state obligations pass with native effects where required; no dropped evidence under faults; CodeRabbit review. Full UX rendering/PTY obligations remain M4, not falsely claimed here.

#### M3 — real local coding, cache-aware checkpoint and viability

##### M3-A: bind and probe existing endpoint

Use an explicitly authorized existing local endpoint, synthetic prompts and bounded output. Record served model ID and exposed server/template/capability identity. Never restart/reconfigure the server or touch other active sessions. A historical endpoint note is not live verification.

##### M3-B: real five-tool coding loop

Run scratch-repository tasks using the actual tools and installed build environments. Retain file diffs, tool requests, executed test outputs and failure classifications. A scripted/mocked model pass cannot satisfy this gate. Keep tasks bounded and undoable where the native ledger permits; shell effects remain explicit.

##### M3-C: checkpoint the warm native history, then roll the epoch

Implement and test the two-phase contract: capture against the existing qualified native prefix with execution locally blocked; validate and publish a shorter epoch. Test failed/cancelled/tool-only checkpoints and queue interactions. Preserve exact constraints/unknown operations/receipts. Measure summary request, first new-epoch request and subsequent warm request separately. Prefix equality alone is not a cache-hit claim.

##### M3-D: matched Pi comparison and decision

Run the existing 12-task development comparison in ACCEPTANCE.md, with paired repeats, fixed budgets, installed Pi/server versions and controlled or honestly observational cache state. Do not change a benchmark oracle after seeing the result, cherry-pick successes or count repeats as independent tasks.

**Exit:** local capability record, due CACHE/REAL cases, all preceding Linux tests, aggregate CodeRabbit review and a candid benefit/cost report. **STOP after the M3 report.** The human decides whether deployment/control/context-management advantages warrant M4–M6. Swift alone is not the advantage.

#### M4 — full UX, then native terminal integration on both systems

##### M4-A: first macOS build/adapter qualification

After Linux viability authorization, build/run the unchanged portable core on Apple Silicon macOS. Qualify package OS floors and native differences. Add only the required platform shims. Re-run Linux after every portability change. Do not claim macOS 14 support without actual compatible dependency/runtime evidence.

##### M4-B: complete use cases in pure state

Implement remaining mention completion/preview, queue edit/reorder/withdraw, held-state recovery, sessions/agents/models/context/epochs views, compact dry-run, diff provenance and undo/rewind flows. Most of these already have M1/M2 foundations. Use virtual clock/IDs and semantic frame fixtures; no terminal required to assert correctness.

##### M4-C: Markdown/ANSI/replxx adapter

Qualify the deferred swift-markdown pin/build impact. Implement bounded completed-block parsing and semantic roles, streamed fallback, escaped controls and plain mode. Bind one output owner plus line editor, retain draft during stream and resize, ignore stale callbacks. No language lexer framework or new full-screen UI.

##### M4-D: eight PTY scenarios and release-binary wiring smoke

Run PTY-01–08 using actual key/paste/resize/cancel signals on Linux and macOS after pure and adapter gates pass. Distinguish catchable exit from impossible SIGKILL cleanup, and TERM simulation from a real SSH/tmux spot-check. Exercise the actual release binary against a synthetic loopback provider to catch composition-root/test-only discrepancies.

**Exit:** all UX-MENTION/QUEUE/UNDO/NAV/RENDER, DX, TERM and PTY obligations due here pass on the scheduled native matrix; prior Linux core/cache contracts stay green; CodeRabbit epic review. A pretty screenshot does not pass a failed state or PTY gate.

#### M5 — explicit cloud support and one-shot consultation

##### M5-A: native Responses and Messages protocols

Implement each adapter without flattening continuation data or pretending protocols are interchangeable. Reuse shared transport, not shared-lossy semantics. Offline fixtures cover signed/opaque blocks, complete pairing, errors, usage distinctions and replay. Test explicit transitions between provider epochs.

##### M5-B: privacy/accounting and live route

Qualify at least one authorized actual cloud route with synthetic source. Missing credentials mean unqualified, not implicitly compatible. Enforce explicit export consent when switching a private/local session to cloud. No CLI OAuth imitation or subscription portability claim. Unknown tokens/cost/cache fields remain unknown.

##### M5-C: bounded consult

Implement optional single request, tools-none, no inherited full history/repo access and no recursive tasks. Record evidence packet and model role; `/agents` displays consultation as activity rather than another autonomous worker. The provider may be local or cloud, subject to the same route/data grants.

##### M5-D: integration review

Run cross-adapter regression and Linux/macOS integration; retain actual live/mocked capability matrix and CodeRabbit review. Add no MCP/plugin/runtime provider catalogue.

**Exit:** due CLOUD/CONSULT cases plus preserved locality/context/cancellation invariants. Only live-qualified routes are advertised as such; others are explicitly experimental/mock-tested.

#### M6 — release, migration and support claims

##### M6-A: claimed-platform qualification

Repeat clean-host packaging for Linux x86_64 and macOS; add native aarch64 and additional Linux distribution testing before claiming them. Record glibc/runtime/CA/SQLite/C++ dependencies. Cross-build is not native execution. Any reduced release matrix is an explicit maintainer scope decision, not a relabelled skipped test.

##### M6-B: lifecycle hardening

Test migrations/future-schema refusal, bounded large history, disk full, descriptors/process groups, cancellation/reopen, terminal recovery, quotas and privacy-preserving exports. Benchmark startup/RSS/overhead on named reference hosts. Keep durable side-effect evidence under all failures.

##### M6-C: final acceptance and unseen tasks

Reconcile all 200 declared cases and due evidence/platform variants. Deferred or missing mandatory product features prevent a complete-release claim. Run 12 unseen paired comparison tasks without tuning to them; retain all failures and qualified statistical limits. Review/package tests cannot be replaced by model opinions.

##### M6-D: release approval

Full CodeRabbit epic review, final CI and maintainer approval at the intended head. Produce real SBOM, notices, checksums, actual signatures/notarization when provisioned, migration/recovery docs and minimal local-endpoint setup. No automatic publication or made-up credentials. Preserve last known-good artifacts and explain rollback/schema compatibility.

**Exit:** a small native harness with measured, declared capabilities. MCP, images, interactive child-terminal emulation, deep syntax highlighting and provider OAuth remain separately scoped future work.

#### Required report at every closeout

Use templates/milestone-report.md. Include base/head/tree/plan/lock identities; scope/cases/invariants; changed files; RED/GREEN commands and raw outputs; pass/fail/skip/deferred by evidence layer/platform; runtimes; dependency delta; reviewer identity/subject/finding dispositions; limitations; gate status and the next authorized action. Reports attest to work already executed, never promise later evidence.


---

## Part 9 — DEPENDENCIES.md

### Dependency decisions and supply-chain contract

Baseline pins researched 11 October 2026; retained in v0.3 on 12 October 2026. GRDB and Markdown release availability rechecked; the complete graph is still unqualified. This is a **selection of published candidate versions**, not a fabricated resolved graph or a tested binary. M0 must resolve these exact candidates, retain the actual commit identities in `Package.resolved`, build them together and publish the native test results. If resolution fails, preserve the failure and propose the smallest explained adjustment.

#### Selected direct dependencies

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

##### What remains to verify at M0

Resolve compatibility of the **whole graph**, SDK deployment availability, each package's actual licence at the chosen revision, transitive native components, build plugins, binary size, build requirements and runtime linkage. SwiftPM package-manifest dependencies are not all necessarily linked into the shipped executable. Conversely, a short direct-dependency list says nothing about total native code.

Produce `dependency-inventory.json` with package URL, exact revision, version, licence, target/product, whether build-only or runtime-linked, binary contribution where measurable and vendored notices. Do not invent the transitive list in advance. Produce an SPDX or CycloneDX SBOM, including the native terminal code and any bundled SQLite or ripgrep binary.

Audit crypto/TLS duplication between Swift Crypto and NIOSSL. It is acceptable to use their established implementations; it is not acceptable to claim no native crypto dependency or replace SHA/TLS with handwritten code to win a package-count metric.

#### Conditional M4 presentation package

**`swiftlang/swift-markdown` candidate 0.9.0**, product `Markdown`. Swift Package Index identifies 0.9.0 as the published release, and upstream describes a cmark-gfm-backed immutable markup tree [S24]. This is **not part of the M0 pinned graph**. Once M0–M3 viability is established, qualify its actual package graph, C/native linkage, build-time delta, final binary size and Linux/macOS behavior before selecting it for completed-block terminal rendering. Do not turn the renderer into an unpinned branch dependency. A small ANSI style-span writer remains ours; Markdown parsing does not.

No other production packages are authorized by UX/DX work. The PTY driver uses a **test-only** C shim and OS interfaces rather than a runtime terminal emulator library. Swift Testing remains toolchain-provided. `replxx` completion/highlighting/write/prompt hooks are present in upstream C API [S25]; asynchronous redraw in the proposed configuration remains an M0-C qualification requirement.

#### Native and external components

**SQLite:** link the target OS SQLite when the declared distribution contract permits it, or include a pinned upstream amalgamation in the release build. Choose and document the actual path at M0. Do not add SQLCipher for v0.1. GRDB does not make the database encrypted by default.

**replxx:** vendor the selected source and licence, with a tiny reproducible build recipe or SwiftPM C/C++ target. Its C callbacks support file completion and input hints; its output API must be PTY-tested for output during an active composer, not assumed safe from its public names. Prefer the C boundary over making C++ interoperability part of the public Swift API. If CMake is needed to reproduce the upstream build, it is a build-time dependency only; do not download or run it at application startup. Qualify bracketed paste, Unicode, signal cleanup and streamed output on each native target. If integration fails, record the specific failure. A temporary plain input mode may support headless development, but it does not pass interactive-release acceptance.

**ripgrep:** required for the native `search` tool. An operator-provisioned version-checked executable is sufficient. An official release bundle may include a pinned binary and its notices. No auto-install, no arbitrary `rg` flags and no `RIPGREP_CONFIG_PATH` inheritance.

**git:** required for `/diff` and git-aware diagnostics, not for reading/writing an ordinary non-git directory. Use the provisioned executable; no libgit2 dependency. Missing git disables git-specific features with a clear explanation.

**OS/runtime:** libc, threading, SQLite linkage, C++ runtime, CA roots and Swift runtime/static-SDK linkage must be captured in the release manifest. “No Node” does not mean “no dependencies”.

#### Deliberately not selected

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

#### Optional MCP, not a hidden core dependency

Use `modelcontextprotocol/swift-sdk` only in the separately enabled follow-on. Pin and qualify the version when that milestone begins; do not fabricate a future pin now. No handwritten MCP transport or protocol. An official SDK's documented protocol support must be negotiated with the server; “official” does not prove support for every newer spec. [S13–S14]

For selected MCP tools, validate their schemas using a maintained library rather than claiming that the core's five typed tool validators implement all JSON Schema. `ajevans99/swift-json-schema` is a research candidate, **not an approved v0.1 dependency**; review its non-macro validation target, compatibility and dependency graph at that milestone. [S23]

#### Release rules

Use exact package candidates and a committed lockfile. Production builds may not track branch heads or resolve a new version implicitly. CI may explicitly fetch pinned sources during build; the released harness never resolves packages. No unreviewed build plugins or repository-local executable configuration. Required third-party notices travel with every release. Dependency updates are explicit PRs with the same streaming, persistence, process and packaging tests.

The first release must be runnable from a clean machine with no Node/npm/Bun/Python/Homebrew/Swift compiler. Project-specific tools used by the coding agent, such as a Python environment or Xcode, remain separately provisioned user tools; this is not a promise to build arbitrary projects without their toolchains.

#### Linux-first qualification order (v0.3)

M0 resolves/builds/tests candidates on Linux x86_64 first. Do not replace a Linux-capable dependency with an Apple-only shortcut, or spend M0 implementing Keychain/macOS terminal paths. First macOS compilation/execution is M4; dependency minimum OS requirements are documented then, before advertising support. No earlier dual-platform phrase overrides this schedule.

Toolchain-provided Swift Testing, Foundation value types and a tiny in-repo scenario wrapper cover routine tests. No Cucumber, Gherkin, Quick/Nimble, snapshot framework, Python/Node test runner or property-testing framework is authorized by default. Add a package only after an ADR demonstrates a real unmet contract and measured total cost; package count alone is not the decision metric.

The development host may already have OpenCode and GitHub tooling. They are not Needletail runtime dependencies. Do not install npm/Bun to bootstrap the development workflow on a hardened appliance. Use the separately provisioned Linux builder, preserve existing Conda/toolchain environments and do not alter model-serving machines.


---

## Part 10 — ACCEPTANCE.md

### Adversarial acceptance catalogue

These are tests/checks to implement, not reported passes. The 168 inherited case IDs remain; v0.3 adds 32 cases and explicitly corrects the impossible uncatchable-terminal-cleanup assertion. Governance checks are classified separately from runtime tests. `VALIDATION.json` elsewhere in this packet concerns document/schema consistency only. A fixture family is not a statistical sample of coding quality.

Each fixture records: ID, platform, preconditions, exact input or injected fault, expected state transition, permitted side effects, forbidden side effects, observed events and retained evidence. Parameterize byte splits, permission combinations, crash points and path cases rather than writing one happy-path test per heading.

#### Packaging and dependencies

| ID | Scenario | Required result |
|---|---|---|
| PKG-01 | Launch release on supported clean host without Node/npm/Bun/Python/Homebrew/Swift compiler | Help, config validation and mock session run; no dependency download. |
| PKG-02 | Execute with all network blocked | Startup/help/session metadata succeed; explicit model request fails honestly. |
| PKG-03 | Rebuild locked graph in clean builder | Same source revisions and documented artifact variation; no floating branch resolution. |
| PKG-04 | Inspect linked libraries and distributable | Runtime/native libraries, notices and SBOM agree; undeclared dependency fails gate. |
| PKG-05 | Missing git or rg | Specific capability disabled; no installation attempt or pretend search results. |
| PKG-06 | Unsupported OS/arch or missing dynamic runtime | Clear compatibility error; no release support claim. |

#### Configuration and routes

| ID | Scenario | Required result |
|---|---|---|
| CFG-01 | Duplicate model IDs and duplicate JSON keys, including nested keys | Validation fails before any provider request. |
| CFG-02 | Unknown top-level/model field, bad numeric limit, missing alias reference | Field-path error; no silent ignore. |
| CFG-03 | Credential in env/file/Keychain | Only reference stored/exported; secret absent from child environment and ordinary logs. |
| CFG-04 | Repo file attempts to register an endpoint or grant trusted execution | Treated as untrusted data; effective capabilities unchanged. |
| CFG-05 | Literal `001234`, huge integer-looking IDs, Unicode paths | IDs preserved as strings; invalid path encoding explicitly unsupported. |
| CFG-06 | Reserved native request-options override (`model`, `tools`, `messages`, credentials) | Rejected before serialization; only declared inert option namespace allowed. |
| NET-01 | Local-only profile plus cloud model selection | Route denied; no cloud request or alternate-provider retry. |
| NET-02 | Authorized origin returns redirect to another origin | Redirect not followed; no credential leak. |
| NET-03 | Proxy env vars and malicious CA/config environment | Not inherited; invalid TLS rejected. |
| NET-04 | Very slow local prefill with transport heartbeats | Separate idle and whole-request deadlines; explicit cancellation works. |
| NET-05 | Transient pre-stream error versus mid-stream disconnect | Bounded visible pre-stream retry; partial output never silently merged/replayed. |
| NET-06 | `doctor` versus `doctor --probe MODEL` | First is offline; second sends only synthetic bounded inputs to the selected route. |

#### Streaming and provider fidelity

| ID | Scenario | Required result |
|---|---|---|
| WIRE-01 | SSE input split at every byte boundary, including multi-byte UTF-8 | Exactly the expected decoded events, no duplicate/lost data. |
| WIRE-02 | CRLF/LF, comments, heartbeat, multiline event, empty lines | Correct parser behavior and accounting; not mistaken for model content. |
| WIRE-03 | Over-limit unterminated SSE line/event and decompressed response expansion | Bounded memory; error before unbounded parser accumulation. |
| WIRE-04 | Two interleaved tool-call argument streams | Correct assembly by native call identity and provider ordering. |
| WIRE-05 | Malformed/incomplete/duplicate-ID tool call, missing final completion | No tool execution; typed compatibility/protocol error. |
| WIRE-06 | Unknown continuation-bearing block or signed/opaque reasoning | Preserve qualified native replay or compatibility-stop; never silently drop. |
| WIRE-07 | Numeric-looking strings, CRLF source, Unicode-equivalent-but-different bytes | Lossless raw recording and stable replay; no normalization. |
| WIRE-08 | Stream ends after tool data but before authoritative completion | Zero side effects; incomplete request retained for diagnosis. |
| WIRE-09 | User instruction inserted mid-history | Appended in the adapter's qualified role; base prompt remains stable. |
| WIRE-10 | Slow consumer / fast provider | Bounded backpressure without dropping protocol events. |

#### Core and tool behavior

| ID | Scenario | Required result |
|---|---|---|
| CORE-01 | Scripted multi-turn read/edit/test/repair loop | One loop, complete receipts, correct tool pairing and final state. |
| CORE-02 | Cancellation at every active state | No orphan state transition; old session remains inspectable. |
| CORE-03 | Three identical invalid/denied attempts | Bounded stop with cause, not endless repair chatter. |
| CORE-04 | Run wall-clock/turn budget exhaustion | Structured stop, no hidden next request, preserved evidence. |
| TOOL-01 | `read` exceeds line/byte budget or sees binary data | Visible truncation/range or explicit unsupported-content error. |
| TOOL-02 | Search query begins with `-`, includes regex/glob metacharacters | Safe harness-built argv; no command or ripgrep-option injection. |
| TOOL-03 | `RIPGREP_CONFIG_PATH`, `--pre`, symlinked external directory | Ambient config/preprocessor ignored; outside-root content not read by native search. |
| TOOL-04 | Exact edit with zero, one and multiple occurrences | Only exactly one occurrence succeeds. |
| TOOL-05 | File changes after read and before final commit check | Conflict, no replacement; keep expected/current hash evidence. |
| TOOL-06 | CRLF, no final newline, combining characters, emoji | Unrelated bytes unchanged; “exact” means exact UTF-8 bytes. |
| TOOL-07 | Symlink/parent swap, hardlink/special file, `../` escape | Native file policy enforced; unsupported cases explicitly denied. |
| TOOL-08 | Create-new path already exists / stale overwrite hash | No silent overwrite. |
| TOOL-09 | Second file in a multi-file operation fails | First receipt retained; no fake whole-batch atomicity or broad rollback. |
| TOOL-10 | Diff in dirty worktree with user changes and external diff config | Bounded safe diff invocation; no reset/checkout or external diff execution. |
| TOOL-11 | Artifact ID belonging to another session | Denied unless explicit fork-ancestry capability exists. |
| TOOL-12 | ANSI OSC/CSI/DCS, control characters and bidi controls in model/tool text | Terminal-rendered output escapes unsafe controls; stored source bytes stay unchanged. |

The final optimistic file check is not an OS compare-and-swap. Do not create a dishonest test claiming to prove protection against an arbitrary write after that check. Document this assumption, and qualify cooperative/injected-change cases separately from malicious same-user concurrency.

#### Processes and policies

| ID | Scenario | Required result |
|---|---|---|
| PROC-01 | Child floods stdout and stderr simultaneously | Both drained; bounded memory and artifact size; no pipe deadlock. |
| PROC-02 | Parent and grandchild in same process group ignore interrupt | Bounded termination/kill, child reaped, descriptors closed. |
| PROC-03 | Repeated cancel/timeout cycles | No accumulating descriptors, unreaped children or unbounded task growth. |
| PROC-04 | Child deliberately detaches into a new session | Limitation exposed; no false process-tree or OS-isolation guarantee. |
| PROC-05 | Artifact cap/disk-full while child continues printing | Visible omission/failure, continued drain or deliberate teardown, no hang. |
| PROC-06 | Existing Conda/compiler binary selected by absolute path | Uses existing environment; no activation/install side effect. |
| POLICY-01 | Observe mode receives an exec request | Denied even for `python`, `git`, `swift test` or a “read-only” label. |
| POLICY-02 | All permutations of `--sealed`, `--tools none`, config tool enables | Never grant tools; contradictory flags fail or intersect downward. |
| POLICY-03 | Sealed prompt requests absolute-path read or emits tool JSON | No workspace read/tool action beyond the explicit packet input. |
| POLICY-04 | Headless command requires approval | Exit 3 and structured request; no prompt/hang/automatic approval. |
| POLICY-05 | Workspace instruction requests cloud upload or permission mutation | No grant/routing change. |
| POLICY-06 | Trusted exec accesses something denied to native `read` | Report trusted-host boundary accurately; do not call native deny list OS containment. |
| POLICY-07 | Prior unknown-outcome command followed by automatic resume | Block automatic mutation/continuation pending explicit reconciliation. |

#### Persistence and exports

| ID | Scenario | Required result |
|---|---|---|
| STORE-01 | Transaction commit/reopen on native platform | Correct schema and durable records. |
| STORE-02 | Crash before intent, after intent, after side effect, before completion | Appropriate absent/pending/unknown state; never automatic side-effect replay. |
| STORE-03 | Artifact rename succeeds but DB transaction does not | Orphan found by reconciliation; no false published reference. |
| STORE-04 | DB completion tries to refer to absent/uncommitted artifact | Transaction rejected or integrity failure; no reported success. |
| STORE-05 | Future schema version or corrupt database | Read-only/explicit failure, never silent recreation. |
| STORE-06 | Two writers open same session | One writer obtains ownership; other fails or opens read-only. |
| STORE-07 | Huge transcript resume/list | Metadata/paged loading; no unconditional full-history RAM expansion. |
| STORE-08 | Export and support diagnostics | Secret references only; raw source/payload export opt-in and clearly labelled. |
| STORE-09 | Session/global quota reached | Visible stop/limitation; no automatic evidence deletion. |

Process-crash recovery is the initial durability claim. Sudden power loss, filesystem faults and storage-controller failure require separate qualification; do not report them as tested merely because `kill -9` tests passed.

#### Context, caching and checkpointing

| ID | Scenario | Required result |
|---|---|---|
| CACHE-01 | Ordinary appended turns with unchanged profile | Prior prompt-bearing blocks and relevant settings remain stable. |
| CACHE-02 | Timestamp, cwd metadata or git status changes | Metadata changes do not rewrite the prefix. |
| CACHE-03 | Tool result first preview, then additional artifact range | Prior preview unchanged; extra range appended. |
| CACHE-04 | Same client prefix with server cache counters unavailable | “Prefix stable; cache unknown”, not invented percentage. |
| CACHE-05 | Warm checkpoint request | Same native history, tools, tool choice, effort/thinking and output-format profile; executor denies tools. |
| CACHE-06 | Checkpoint malformed, references nonexistent receipts, cancels or exceeds quota | No active-epoch replacement; original session remains usable. |
| CACHE-07 | New shorter epoch after successful checkpoint | Report actual first prefill separately; no promise of full old-cache reuse. |
| CACHE-08 | Constraint, failed attempt or unresolved command in long history | Exact pins/unresolved ledger preserved; semantic retention measured on fixtures. |
| CACHE-09 | Model/provider/tool-set switch | Explicit new epoch and privacy grant where required; no incompatible opaque replay. |
| CACHE-10 | Near-context limit with approximate tokenizer | Reserved checkpoint budget, uncertainty visible, no blind repeated overflow. |
| CACHE-11 | 32K sealed consultant versus 262K main profile | Different reserves, no forced main-model-sized instructions on the small worker. |
| CACHE-12 | Model claims “tests passed” without evidence | Claim remains unverified; missing/invalid reference fails validation where required. |
| CACHE-13 | Main plus consultant contend on same endpoint | Configured serial behavior within process; no promise of global/server slot reservation. |

#### Terminal, consultation and cloud

| ID | Scenario | Required result |
|---|---|---|
| HEAD-01 | JSONL mode with streamed tool output and errors | Parseable JSON only on stdout; diagnostics on stderr. |
| HEAD-02 | Consumer closes output pipe | Bounded cancellation and process cleanup. |
| HEAD-03 | Each terminal run outcome | Documented exit code and one final terminal event when writable. |
| TERM-01 | Bracketed paste contains newlines and shell-looking text | No premature submission/execution. |
| TERM-02 | Unicode, resize, long line, SSH and tmux | Usable input/display; no broken terminal state. |
| TERM-03 | Ctrl-C during input, provider call and exec | Defined behavior; modes restored after exit/error. |
| TERM-04 | Non-TTY/dumb terminal | Supported plain/headless fallback, no escape-sequence soup. |
| CONSULT-01 | Worker packet omits main verdict and history | No hidden inheritance; actual transmitted packet audited privately. |
| CONSULT-02 | Worker asks for a tool or recursively consults | No execution; result handled under tools-none contract. |
| CONSULT-03 | Large packet/output or main/worker endpoint ID collision | Bounded rejection/truncation policy and duplicate-ID validation. |
| CONSULT-04 | Provisional label presented as adjudicated truth | Evidence type remains model-produced; no automatic status promotion. |
| CLOUD-01 | Responses native reasoning/tool sequence replay | Required native items retained; real route qualified separately from mocks. |
| CLOUD-02 | Messages signed thinking/tool blocks replay | Correct ordering/signatures and stable checkpoint settings. |
| CLOUD-03 | Different cache-read/write input conventions | Correct normalization; unknown and partial fields remain unknown. |
| CLOUD-04 | Pricing absent/stale and usage missing | No fabricated zero cost/token count; dated estimate only when configured. |
| CLOUD-05 | Sensitive local session requests cloud switch | Explicit admission/route consent before sending any context. |

#### Real endpoint and Pi comparison

| ID | Scenario | Required result |
|---|---|---|
| REAL-01 | Synthetic probe on actual authorized local endpoint | Binding and transcript for streaming, tool calls, numeric strings and multi-turn replay. |
| REAL-02 | Coding loop on scratch copy/worktree without altering baseline | Real file changes and test execution receipts, not a mocked success. |
| REAL-03 | Matched Pi comparison | Installed version recorded; same server/model/settings and controlled cache condition. |
| REAL-04 | Long-context and checkpoint transition | Adequate admission reserve; separate warm-summary/new-epoch timings. |
| REAL-05 | User endpoint already serving another session | No server restart, model reload, slot manipulation or config edit by benchmark. |

##### Benchmark design

Maintain a small static development set, not a new benchmark platform. Start M3 with 12 bounded tasks, two matched runs per harness, covering Swift, Python, PHP and TypeScript plus language-neutral repository operations. Use tasks with executable/inspectable oracles: exact edit conflict, test repair, change confined to scope, compile failure diagnosis, quoted identifier preservation, long-context constraints and interrupted-run recovery. Kotlin can be a normal shell-driven build task where its existing environment is provisioned; no semantic-backend claim is implied.

Before public release, add 12 unseen tasks and repeat the paired procedure. Freeze task definitions, expected outcomes, budgets and excluded setup time before running the candidate. Counterbalance harness order; classify cold/warm conditions using actual backend controls or observations. Do not erase another user's/server session's cache to manufacture a cold run. If matched cache state cannot be established, label the comparison observational.

Report per-task outcome and resource totals, paired latency/token differences, confidence intervals clustered by task, and exact failure categories. Repetitions of the same task are not independent semantic cases. A 12- or 24-task experiment does not establish general coding-quality equivalence. No post-hoc significance claim, cherry-picked example or loosened margin.

The release gate is zero failure on mandatory deterministic safety/protocol fixtures, no unexplained regression on critical coding fixtures, and an honest task-level comparison. The project must demonstrate a useful deployment, control or context-management advantage; statistical superiority on all coding tasks is not a prerequisite for a small useful tool.

#### Interactive UX and deterministic presentation (v0.2 amendment)

The following fixtures are **additional** and do not renumber or relax the original 100 scenarios. The authoritative behavioural contract is `UX-DX.md`. Most tests run without a terminal, network, filesystem or process; PTY tests are intentionally few. Every item must record initial state, action/event sequence, expected effects and projection, durable receipt (where relevant), and forbidden side effects. Test-only clock/IDs/events are fixed. Relevant `TERM-*` tests above remain in force.

##### File mentions, selection and bounded preview

| ID | Scenario | Required result |
|---|---|---|
| UX-MENTION-01 | Typing `@` in allowed boundary and basename/path fragments | Deterministic bounded candidates, no eager file content sent to provider. |
| UX-MENTION-02 | `foo@bar`, escaped `\\@`, code/paste literal and assistant/tool output | No accidental file-reference interpretation. |
| UX-MENTION-03 | Tab choose Unicode/space-containing path and move cursor | Structured token identity survives editing; no ambiguous string parsing. |
| UX-MENTION-04 | Candidate changes from revision N+1 arrive before N | Old result ignored; composer/selection unchanged. |
| UX-MENTION-05 | 100K+ path synthetic catalogue, long basename and ignored secrets | Hard caps; search does not hang or expose ignored/out-of-root content. |
| UX-MENTION-06 | Preview text with ANSI/OSC/bidi and 20 MiB file | Sanitized 8-line/4-KiB preview, explicit truncation; no provider request. |
| UX-MENTION-07 | Binary, symlink outside root, denied file and missing file | Metadata/typed error; never illicit content or partial admission. |
| UX-MENTION-08 | Selected range `#L10-L30`, reversed/out-of-bounds ranges | Exact 1-based boundaries or visible validation failure. |
| UX-MENTION-09 | File modified during snapshot or before queued dispatch | Consistent snapshot or refusal; stale queue held, no silent refresh. |
| UX-MENTION-10 | 2 MiB referenced file in tool-enabled vs sealed mode | Bounded excerpt/manifest with real read tool, or explicit sealed admission failure. |
| UX-MENTION-11 | Preview selected then cancelled or draft withdrawn | Zero provider requests, no prompt epoch mutation, no orphan authoritative context. |
| UX-MENTION-12 | Cloud switch before queued attachment dispatch | Reapply route/context consent, hold until explicit approval. |

##### Queue and interrupt

| ID | Scenario | Required result |
|---|---|---|
| UX-QUEUE-01 | User types while streaming 500 model chunks | Full draft survives; stream and terminal output remain correctly ordered. |
| UX-QUEUE-02 | Enter while busy | Durable follow-up enqueued once, not sent during current turn. |
| UX-QUEUE-03 | `/steer` during streamed incomplete tool call | Appended only at safe post-batch boundary; never interleaved tool JSON. |
| UX-QUEUE-04 | Two steers and three follow-ups | FIFO, one at a time by kind; no duplicate/drop across turns. |
| UX-QUEUE-05 | `/queue` edit/reorder/withdraw before dispatch | Durable mutation of queue only; withdrawn text absent from provider history. |
| UX-QUEUE-06 | Crash at queued, dispatched, delivered boundary | Correct receipts; no automatic duplicate provider input/side effect. |
| UX-QUEUE-07 | Ctrl+C during active generation with pending queue | Active cancellation and held queue; no next automatic request. |
| UX-QUEUE-08 | Stale attachment or missing route grant at head of queue | Queue holds rather than skips; operator can fix or remove. |
| UX-QUEUE-09 | 21st queue item / cumulative text exceeds 64 KiB | Typed refusal without silently dropping older entries. |
| UX-QUEUE-10 | Model/endpoint epoch changed since enqueue | Correct new-epoch admission and privacy checks before dispatch. |
| UX-QUEUE-11 | Headless mode cannot request permission | Structured approval-required stop; no implicit queue consent. |
| UX-QUEUE-12 | Busy stream ends in failure with queued items | Queue state visible, delivery policy explicit, no surprise continuation. |

##### Undo, rewind and provenance

| ID | Scenario | Required result |
|---|---|---|
| UX-UNDO-01 | Edit/create native operations with durable preimages | `/undo` preview shows exact reversible set, before/after hashes and limits. |
| UX-UNDO-02 | Native edit followed by user edit of same file | Hash conflict; zero overwrite of later user change. |
| UX-UNDO-03 | Undo created file now modified or repurposed | Refuse deletion; original user data survives. |
| UX-UNDO-04 | Three-file change group with one preflight conflict | No reversal starts, per-file conflicts visible. |
| UX-UNDO-05 | I/O failure after first inverse operation | Partial compensation logged; never claim atomic success. |
| UX-UNDO-06 | Exec ran formatter and modified file | Do not claim shell-produced changes are undoable via native ledger. |
| UX-UNDO-07 | History compacted since original edit | Change ledger still available; eligible undo governed by current file hashes. |
| UX-UNDO-08 | `/rewind` to old turn with a dirty worktree | New lineage fork; no file mutation, explicit divergence warning. |
| UX-UNDO-09 | Duplicate undo request after success / interrupted reversal | Idempotent-safe error/reconciliation; no second destructive inverse. |
| UX-UNDO-10 | Unstored/missing preimage due to quota before native edit | Fail closed or request explicit non-undoable authorization; default no mutation. |
| UX-UNDO-11 | Symlink/inode/permission change between preflight and restore | Revalidate at commit, refuse/record conflict; no out-of-root write. |

##### Agent/context controls and formatting

| ID | Scenario | Required result |
|---|---|---|
| UX-NAV-01 | `/agents` with active, idle, stale and unknown sessions | Correct status provenance; old heartbeat not represented as live proof. |
| UX-NAV-02 | `/agents` during a bounded consult | Consult visible as child activity record, no recursive team implied. |
| UX-NAV-03 | `/models` vs `/sessions` vs `/agents` | Separate meanings, no network request just to list. |
| UX-NAV-04 | `/context` on profile with unavailable cache stats | Unknown labeled unknown; component totals/reserve distinguish estimates. |
| UX-NAV-05 | `/compact --dry-run` then cancel | Offline inspection only, no summary provider call or epoch replacement. |
| UX-NAV-06 | `/epochs` after failed and successful checkpoints | Parent lineage, failure and distinct prefill phases visible. |
| UX-NAV-07 | `/diff` in dirty/staged/untracked tree with agent edits | Correct provenance and bounded hunks, no claim of exclusive authorship. |
| UX-RENDER-01 | Markdown headings 1–6, nested ordered/unordered/task lists | Semantic spans/indentation stable in ANSI and plain modes. |
| UX-RENDER-02 | Inline code, bold, italic, blockquote, fence across split stream chunks | No malformed/stale style or leaked Markdown control. |
| UX-RENDER-03 | Unified diff including `+`, `-`, `@@`, path, no-newline note | Correct source-change roles; source text preserved exactly in artifacts. |
| UX-RENDER-04 | C0/C1, ESC/OSC/DCS, bidi controls in source/model/tool streams | Neutralization before ANSI generation; no screen-control injection. |
| UX-RENDER-05 | Unicode combining/emoji paths at 40/80/120 widths | No mid-codepoint split, corrupt cursor or phantom line wrap. |
| UX-RENDER-06 | `NO_COLOR`, `TERM=dumb`, non-TTY, narrow terminal | Identical semantic content with sensible plain-text fallback. |
| UX-RENDER-07 | Gigabyte-equivalent synthetic stream through bounded chunks | UI memory/queued updates bounded; core evidence never dropped. |
| UX-RENDER-08 | Styled source is reparsed/reflowed for display | Canonical provider/prompt bytes unchanged; no epoch mutation. |

##### Developer fast-loop and real PTY

| ID | Scenario | Required result |
|---|---|---|
| DX-01 | Replay identical `UIAction`s twice with frozen clock and IDs | Equal semantic UI state, frames and requested effects. |
| DX-02 | Late async `@` candidate result after newer input | Pure reducer discards old revision and preserves newer draft. |
| DX-03 | UI requests queueing while SessionActor denies due to policy | Pending optimistic projection rolls back; no duplicate source-of-truth. |
| DX-04 | Mock provider emits every SSE byte as independent chunk | Identical UX/model/tool projection to unsplit stream. |
| DX-05 | Mock emits tool start/progress/failure/retry or cancellations | Correct minimal status without inventing success. |
| DX-06 | Concurrent model/status/draft events in adversarial interleavings | Deterministic allowed outcomes; no lost input or unexpected effect. |
| DX-07 | Snapshot golden intentionally changed by implementation | Fixture failure until independently reviewed update; never auto-regenerate pass. |
| DX-08 | `swift test` with network disabled and no Node/Python installed | All offline presentation/core and native tests run from provisioned Swift toolchain. |
| DX-09 | UI frame test vs actual PTY disagree | Interactive gate fails; unit-only pass is insufficient. |
| DX-10 | Tests run repeatedly with stress seeds, no sleeps | Bounded repeatability; no flaky timing assumptions. |
| PTY-01 | Real CLI opens/closes editor and receives Ctrl+C | termios/bracketed paste state restored and clean exit. |
| PTY-02 | Paste multi-line text while streaming; user submits after paste | Exact submitted text once, never command execution during paste. |
| PTY-03 | `@` candidates and bounded preview while model/tool writes output | Draft/popup intact, no ghost cursor/interleaved escapes. |
| PTY-04 | Queue message during 100s of streamed chunks; interrupt | Queue visible/held, no unintentional auto-send; no lost draft. |
| PTY-05 | `TIOCSWINSZ` 40→120→80 while cursor in multi-line composer | Correct redraw/width; no hang/out-of-bounds ANSI. |
| PTY-06 | Stream malicious OSC title / cursor motion / control bytes | Terminal title/state not changed by untrusted content. |
| PTY-07 | Catchable SIGTERM/EOF versus SIGKILL or fatal crash while active | Catchable exits restore modes and clean owned children; uncatchable termination has no in-process cleanup guarantee. Verify durable recovery and documented external terminal reset separately. |
| PTY-08 | macOS and Linux with tmux/SSH-like TERM capabilities | Mode-aware fallback and stable editing. Simulated TERM is not real SSH/tmux coverage; retain one separately labelled real-path release spot-check. |

#### v0.3 methodology, concurrency, portability and review cases

These cases do not turn governance into an AI pass/fail oracle. Runtime cases require executable evidence; process/review cases require actual bounded checks and review receipts. M0 defines the evidence plumbing; later gates supply their scheduled native evidence.

| ID | Scenario | Required result |
|---|---|---|
| BDD-01 | Required behaviour test has no catalogue ID or an unknown ID | Case reconciliation fails with exact missing/unknown identifier; no unlabeled requirement is silently counted. |
| BDD-02 | Ten seeds and duplicate test functions exercise the same behaviour | One distinct semantic case is counted; variants and redundant tests are reported separately. |
| BDD-03 | A registered case has no executed test body or only a no-op assertion | Not covered; require real runner evidence plus reviewed relevant observations, not registry membership. |
| BDD-04 | A required variant is skipped, filtered out, pending or marked known issue | The due gate remains unsatisfied; the missing variant/tier is visible. |
| BDD-05 | Only a pure mock passes for a case requiring native filesystem or PTY evidence | Higher-tier obligation stays unqualified; no evidence-layer promotion. |
| BDD-06 | Deliberately remove a critical guard in a disposable wrong-implementation probe | The corresponding test fails for the expected observable violation; baseline is restored before ordinary runs. |
| BDD-07 | Golden is regenerated from production output during the same run | Validation/review rejects the oracle; independently reviewed expectations are required. |
| BDD-08 | Replay a failed interleaving with frozen clock, IDs and seed | The same minimized trace reproduces the failure without sleeps or live I/O. |
| REV-01 | Implementation begins before independent review of its required plan | Slice gate blocks; local work does not manufacture a reviewer receipt. |
| REV-02 | deepseek-reviewer is unavailable or resolves to the implementer under another name | BLOCKED_REVIEW; no self-review or silent route substitution. |
| REV-03 | Code, tests, fixture, lock or plan changes after the recorded review subject | Affected receipt is stale; require review of the actual revised subject. |
| REV-04 | A finding lacks evidence or reviewer cannot inspect a required boundary | NEEDS_EVIDENCE or a documented disputed finding, never fabricated certainty/pass. |
| REV-05 | Two review cycles leave a substantive unresolved contradiction | Preserve the counterexample and hold for maintainer decision; no endless retries or budget-based auto-pass. |
| REV-06 | CodeRabbit returns summary-only, failed, skipped or truncated epic review | Epic remains review-incomplete; identify actual base/head/files and missing review. |
| REV-07 | Aggregate epic review omits a risky file or sees only the last fix | Review coverage fails; include base-to-head integration and account for excluded files. |
| REV-08 | Author asks to resolve every finding or a bot proposes automatic code changes | No blanket acceptance or auto-merge; dispositions and changes get evidence and review. |
| PORT-01 | M0-M3 execute on provisioned Linux with no Apple host/toolchain | Required Linux gates run; future macOS obligations are DEFERRED_BY_PLAN, not passed or needed now. |
| PORT-02 | Apple-only or Linux-specific implementation imports leak into Core/Presentation | Portable-boundary check and native Linux build fail the gate; move code to a qualified shim. |
| PORT-03 | Case-sensitive and Unicode-equivalent filenames differ across filesystems | Exact identity/bytes and capability semantics remain explicit; no platform-assumed normalization. |
| PORT-04 | In-memory storage tests pass but native process-kill/reopen test fails | Persistence native gate fails; mocks cannot claim crash durability. |
| PORT-05 | Ubuntu-built bundle has undeclared runtime/glibc requirements on a claimed target | Packaging/support claim fails until native clean-host qualification or explicit reduced scope. |
| PORT-06 | A macOS portability patch regresses an existing Linux case | Linux gate blocks merge; no platform fork or bypass justified by the Mac pass. |
| STATE-01 | Late request/effect completion arrives after cancellation or new run revision | Recorded as stale/diagnostic only; no state resurrection or new tool/provider dispatch. |
| STATE-02 | Queue admission commits but its UI acknowledgement is lost and retried | Same command ID returns the original admission exactly once locally; no duplicate history. |
| STATE-03 | Provider may have processed a dispatched message before connection/crash | Delivery unknown is held; no exactly-once network claim or unsafe automatic resend. |
| STATE-04 | Output buffers and durable artifact quota fill while user cancels | Control path remains responsive; bounded backpressure/visible stop without dropped authoritative receipts. |
| STATE-05 | Successful or partial native undo precedes the next model request | Append truthful paths/hashes/outcome notice; preserve earlier history and audit receipts. |
| STATE-06 | Process receives an uncatchable signal while terminal is raw | Do not claim in-process cleanup; exercise documented recovery/external terminal-reset boundary. |
| DEV-01 | The free implementer route expires, rate-limits or starts requiring paid access | Retain work and record the blocker; bounded transient retries only, no account rotation/payment/fallback. |
| DEV-02 | A review packet includes private corpus/source/credentials or implicit linked-repo context | Prevent transmission until sanitized/explicitly authorized; retain data-classification evidence. |
| DEV-03 | A fork PR or edited workflow attempts to read secrets or self-certify its own gate | Trusted CI boundary prevents privilege escalation; checked-in PASS JSON is insufficient. |
| DEV-04 | A test tries to evict serving workloads, alter model slots or kill generic processes | Denied; operate only on explicit test-owned resources without disturbing the baseline. |


---

## Part 11 — CHANGELOG.md

### v0.3 change record

This is a consolidated successor to v0.2, not a patch requiring an older archive.

#### Delivery changes

Linux x86_64/Ubuntu 24.04/Swift 6.4 becomes the first mandatory development gate. M0–M3 no longer require macOS; Apple Silicon native qualification begins in M4. Broader Linux targets remain explicit M6 claims to qualify. Static linking is a bounded packaging experiment, not a prerequisite that blocks the local coding loop.

Step 5 Preview Free is the initial implementer; the existing `deepseek-reviewer` independently reviews minor plans and code; CodeRabbit reviews each GitHub epic. Roles stay outside the product. Current-head evidence, bounded review rounds, no silent spend/fallback and maintainer merges are specified.

Behaviour-labelled Swift Testing replaces any interpretation that BDD requires a framework. Pure production state, virtual time/IDs, forbidden-effect assertions, case-versus-variant reporting, native evidence distinctions and fast-layer budgets are explicit. The pure Presentation contract begins in M1 rather than being designed only after the core is finished. Full terminal integration stays M4.

#### Correctness clarifications

Local idempotent queue admission is not exactly-once network delivery; ambiguous provider dispatch is held. Late asynchronous effects cannot resurrect cancelled work. Native undo appends a truthful workspace-change notice before the next request. Bounded backpressure/overflow is specified rather than promising infinite lossless buffering.

PTY-07 is corrected: catchable exits can restore modes; SIGKILL/power failure/fatal crashes cannot promise in-process cleanup. PTY-08 distinguishes TERM simulation from an actual SSH/tmux path. These changes correct overbroad claims, not observed application-test regressions; no implementation tests existed in the input packet.

All 168 original acceptance IDs are retained, with these explicit qualifications. Thirty-two delivery/concurrency/portability/review cases bring the declared catalogue to 200. They are specifications/checks, not 200 tests run or a proof of exhaustive semantic coverage.

#### Added handoff material

Development/testing/review/milestone documents; architecture refinements; a compact AGENTS entry point; four role-specific prompts; new-project CodeRabbit/PR templates; normalized case index; result/review schemas; illustrative non-executed fixtures; one-file reading edition and packet validation/checksums. No repository creation, remote review, account change or product build was performed.


---

## Part 12 — SOURCES.md

### Primary research sources

Checked 11 October 2026. These references support factual library/protocol observations. The normative behavior and numerical targets in SPEC.md are design decisions, not features claimed to exist upstream or measured results.

#### Selected foundations

- **S01 — Swift 6.4 release, 15 September 2026.** Toolchain release and Subprocess 1.0 availability. https://www.swift.org/blog/swift-6.4-released/
- **S02 — Swift Argument Parser releases.** Selected candidate 1.8.2; the page also contains a later-published maintenance release on the older 1.7 line, so page order alone is not semantic-version selection. https://github.com/apple/swift-argument-parser/releases
- **S03 — Swift OpenAPI Runtime.** Selected candidate 1.13.0. Public ServerSentEvent and decoding sequences are in its EventStreams directory. https://github.com/apple/swift-openapi-runtime/releases ; https://github.com/apple/swift-openapi-runtime/tree/main/Sources/OpenAPIRuntime/EventStreams
- **S04 — Swift Subprocess.** Selected candidate 1.0.1; cross-platform async processes, streamed-output/descriptor fixes. https://github.com/swiftlang/swift-subprocess/releases ; https://github.com/swiftlang/swift-subprocess
- **S05 — AsyncHTTPClient.** Selected candidate 1.36.2; SwiftNIO-based HTTP client. https://github.com/swift-server/async-http-client/releases ; https://github.com/swift-server/async-http-client
- **S06 — Swift System.** Selected candidate 1.8.1. https://github.com/apple/swift-system/releases
- **S07 — GRDB.** Selected candidate 7.11.1; release 7.10.0 explicitly introduced Linux/Android/Windows support. https://github.com/groue/GRDB.swift/releases
- **S08 — Swift Crypto.** Selected candidate 5.0.0, published 16 September 2026; Swift 6.2 minimum noted upstream. https://github.com/apple/swift-crypto/releases
- **S09 — replxx.** UTF-8/multiline line editor with C API and BSD-style licence. Candidate commit `1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2` obtained from the upstream head ref; inspect/license/test that exact revision before vendoring. https://github.com/AmokHuginnsson/replxx ; https://github.com/AmokHuginnsson/replxx/blob/master/include/replxx.h ; https://api.github.com/repos/AmokHuginnsson/replxx/git/ref/heads/master

#### Provider and cache behavior

- **S10 — OpenAI prompt caching.** Rendered-prefix matching, settings/breakpoints, context replacement and per-model accounting; current Responses accounting includes cache-read/write components in total input. Do not hard-code a historical pricing or retention assumption. https://developers.openai.com/api/docs/guides/prompt-caching
- **S11 — Anthropic prompt caching.** Tools/system/messages hierarchy, tool-choice and thinking-setting invalidation, native thinking preservation, usage-field distinctions. Model and platform capabilities differ. https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- **S12 — Pi compaction source.** The inspected current implementation serializes conversation text into a separate summarisation context. This does not identify the version installed on a particular user's machine or prove the observed latency's sole cause. https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/compaction/compaction.ts
- **S13 — Official Swift MCP SDK.** Client/server SDK; inspect and pin actual supported protocol versions at the optional MCP milestone. https://github.com/modelcontextprotocol/swift-sdk
- **S14 — MCP tools specification.** Current researched spec path, including tool behavior/order considerations; its date is not a claim of SDK feature parity. https://modelcontextprotocol.io/specification/2026-07-28/server/tools
- **S15 — OpenAI Responses streaming.** Typed stream events and provider-specific completion semantics. https://developers.openai.com/api/docs/guides/streaming-responses
- **S16 — llama.cpp server documentation.** Backend-specific slots and request features, not a universal OpenAI-compatible contract. https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- **S17 — Swift Static Linux SDK.** Packaging route to qualify for the actual graph, not proof that every selected library is fully static on every target. https://www.swift.org/documentation/articles/static-linux-getting-started.html

#### Alternatives and prior art

- **S18 — swift-coding-agent.** Existing staged Swift coding-agent implementation. Feasibility/reference material, not production qualification or a selected dependency. https://github.com/ivan-magda/swift-coding-agent
- **S19 — MacPaw/OpenAI.** SDK and manifest examined; rejected here on unqualified fit to the lossless three-protocol boundary, not an accusation of a large dependency graph. https://github.com/MacPaw/OpenAI ; https://github.com/MacPaw/OpenAI/blob/main/Package.swift
- **S20 — AnyLanguageModel.** Unified model API research alternative; not selected. https://github.com/huggingface/AnyLanguageModel
- **S21 — SwiftTUI.** Declarative terminal UI; unnecessary scope for the scrollback-first design, not rejected as dependency-heavy. https://github.com/rensbreur/SwiftTUI
- **S22 — Noora.** CLI design-system alternative. https://github.com/tuist/Noora
- **S23 — Swift JSON Schema.** Potential non-macro validation reuse for optional MCP; not yet approved or pinned. https://github.com/ajevans99/swift-json-schema

#### Interactive experience and testability additions

- **S24 — Swift Markdown.** `swiftlang/swift-markdown` is a GFM parser backed by cmark-gfm; Swift Package Index reported release `0.9.0` as the newest published candidate on 11 October 2026. Qualify/pin its exact code and linkage at M4; this is not an already resolved package. https://github.com/swiftlang/swift-markdown ; https://swiftpackageindex.com/swiftlang/swift-markdown
- **S25 — replxx C API.** Completion callbacks, modify/highlighting callbacks, multiline key actions, `replxx_write`, `replxx_set_prompt` and key-binding APIs are present. Their existence does not establish race-free concurrent redraw; PTY testing is mandatory. https://raw.githubusercontent.com/AmokHuginnsson/replxx/master/include/replxx.h
- **S26 — Pi RPC queue semantics.** The reference distinguishes `steer` (after the current assistant turn/tool calls), `followUp` (after the run) and `clear_queue`/`abort`. Needletail's queue behavior is explicitly defined in `UX-DX.md` rather than being inherited from an SDK. https://pi.dev/docs/latest/rpc-commands

#### Evidence limits

Source inspection and published release notes establish candidate availability and documented behavior, not compatibility of the entire pinned graph. No Swift build, library resolution, native terminal test, model-endpoint call, cache measurement, process-isolation test or live cloud qualification was performed while preparing this packet. The executable work is assigned to M0–M6.

Private conversation history informed the requirements but is not copied into the public packet. A separate private deployment/history note records the retrieved criticisms and distinguishes user statements from prior diagnostic conclusions. Historical endpoint descriptions are not live endpoint verification.

#### v0.3 development, test and review sources

Rechecked 12 October 2026; volatile account/model/CLI/service settings must be resolved on the actual developer installation. Older S01–S26 entries retain their original research date; this update is not a new full dependency resolution.

- **S27 — OpenCode Go model/endpoint documentation.** Lists Step 5 Preview Free / `step-5-preview-free` as a limited-time offering. This is not a guarantee of future availability, local account entitlement or unlimited uninterrupted service. https://opencode.ai/docs/go/
- **S28 — OpenCode Zen.** Current free-model descriptions and provider-stated retention/training policies. These policies do not authorize sending private material. https://opencode.ai/docs/zen/
- **S29 — OpenCode CLI.** `opencode models`, provider/model identity, `run --model --file`, configuration and disable-auto-download/share-related settings. Qualify against installed version. https://opencode.ai/docs/cli/
- **S30 — OpenCode agents/permissions.** Agent modes, read/write/task permission controls and configuration. A named agent alias must be resolved locally rather than guessed from a product model list. https://opencode.ai/docs/agents/ ; https://opencode.ai/docs/permissions/
- **S31 — Swift Testing upstream.** Toolchain inclusion, native assertions, descriptive names, tags, parameterization and Linux/Apple support. No separate framework dependency is needed. https://github.com/swiftlang/swift-testing
- **S32 — CodeRabbit configuration reference.** Current review status, labels/manual controls, path instructions, finishing touches and knowledge-base settings. Server/account configuration validation is still a bootstrap gate. https://docs.coderabbit.ai/reference/configuration
- **S33 — CodeRabbit review commands.** Full versus incremental review and approval/resolution controls. https://docs.coderabbit.ai/guides/commands
- **S34 — GitHub protected branches.** Required reviews/status checks and branch protection; actual check names/settings come from the installed app/repository. https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- **S35 — GitHub Actions secure use.** Immutable action pinning, least privilege and untrusted-code/secret boundaries. https://docs.github.com/en/actions/reference/security/secure-use
- **S36 — Rechecked selected release pages.** GRDB 7.11.1 and Swift Markdown 0.9.0 remain concrete published candidates. Their presence is not whole-graph/platform qualification. https://github.com/groue/GRDB.swift/releases ; https://github.com/swiftlang/swift-markdown/releases

No Step 5/DeepSeek/CodeRabbit execution was performed in preparing this packet. No account, repository, billing, remote app configuration, dependency resolution or product native-platform qualification is claimed. The configuration is supplied for the receiving implementation workflow, not silently applied.
