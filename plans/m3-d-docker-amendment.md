# M3-D Docker Execution Amendment (2026-11-03, prospective — no scores taken)

Maintainer decision: replace human-attended benchmark execution with isolated, unattended Docker execution. This EXPLICITLY SUPERSEDES the protocol's per-run interactive-approval requirement (§3 of `plans/m3-d-protocol.md`). Ordinary host execution policy is unchanged.

`plans/m3-tasks.json` REV2 (prompts, fixtures, oracles, AB/BA order, budgets) is PRESERVED unchanged. The 48-run / 850-request envelope is unchanged. No benchmark results exist: methodology change, not post-result tuning.

## 1. Why

Attending 22+ Needletail runs (every mutation needs a human on a real TTY) makes the matrix impractical ("becoming a chore"). Docker gives: disposable per-run isolation, php toolchain without host installs, reproducible images by digest, and — with a sandbox-scoped policy — unattended Needletail runs WITHOUT weakening host policy.

## 2. Isolation model

- Fresh container per scored attempt: newly seeded disposable `/workspace`, private `/state`, non-root uid, dropped Linux capabilities + `no-new-privileges`, no privileged mode, no host home/SSH/project/credential/docker-socket mounts, bounded CPU/memory/PIDs, wall time via scorer `timeout`, read-only root filesystem with explicitly provisioned writable `/workspace`, `/state`, `/tmp`.
- Network: NO default-bridge egress. Scoring containers join an `internal:true` network with no external route; the ONLY egress is a pinned single-purpose TCP forwarder (alpine+socat, L4 forward `forwarder:8731 → 192.168.2.216:8731`) that itself bridges internal↔default. Both agents' configs point at the forwarder. Restriction is PROVEN per build with negative probes (direct Halogen IP unreachable, external hosts unreachable, no docker socket, non-root, read-only outside workspace) — an ordinary bridge is not accepted as proof.
- Rootless Docker is NOT available (daemon rootful + apparmor/seccomp); proceeding with daemon + the above restrictions. No host daemon/firewall changes.
- The real dev checkout is NEVER mounted into execution containers. Images are built from `git archive` of the frozen SHA (Needletail) and the installed Pi 1.4.0 dist (pinned).

## 3. Needletail sandbox approval (container-only)

- New `ApprovalGateway` (`SandboxPolicyGateway`, Runtime): honors an immutable grant file issued by the trusted launcher (runID, containerID, workspace, allowed tools/exec allowlist). Binding: grant.containerID MUST equal the runtime hostname (a model cannot change it); workspace MUST canonicalize to exactly the provisioned `/workspace` (outside it → fail closed); grant file lives on a read-only mount outside the workspace (model tools cannot rewrite it). Missing/mismatched/unparseable grant → `.unavailable` (exit 3, run fails honestly). `/.dockerenv` or env vars alone are NOT accepted as proof.
- The policy evaluates the VALIDATED `ToolBatch` structurally (parsed arguments, validator-derived paths, bound exec identities, effective caps) — never the rendered `operation` display text. Allowed in-sandbox: workspace-confined read/search; workspace-confined edit/write; exec IFF every call has bound+verified identities AND requested AND resolved executable basenames are both in the grant's exec allowlist (frozen per benchmark: python3, node, swiftc, php, git). Scored runs pass `--allow-exec` (config `exec:ask`) so model-initiated test commands flow through identity resolution + sandbox approval. Everything else — including absolute-deny tools, escapes, stale hashes, identity failures — stays denied; a denial is NEVER converted to approval.
- All existing machinery is preserved: tool validator, path confinement, hash conflicts, exec identity resolution, operation journal, preimages, cancellation, unknown-outcome holds.
- Decisions are recorded as sandbox-policy approvals (distinct ledger marking, not fabricated human `y`). Host behavior is byte-identical: TTY approval default intact, `--trusted` untouched, no piped-y/scripted-executor paths added.
- Threat model (documented limitation): the trust root is the launcher + container boundary + read-only grant mount. residual: a host user with file-write+exec can mint grants — equivalent in power to the pre-existing `--trusted` flag, and strictly narrower in scope.
- Run-loop integration (review-driven): under `--sandbox-grant` the CLI waits through the transient authorising state instead of exiting 3 on first sight (the policy decides asynchronously); a decided-unavailable approval holds the queue (`approvalPending`), which the next poll observes for exit 3. Host headless behavior unchanged.
- Compose-time guard: a grant file inside `--workspace` is refused at startup (a model-writable grant would be self-approval).
- Budget interplay: checkpoint runs take `max(12, NEEDLETAIL_REQUEST_BUDGET)` — the M3-C 12-request floor never shrinks (T08 needs up to 45).

## 4. Pi parity

Whole Pi 1.4.0 process in an equivalent container (node:24 base + installed dist + halogen-local config). Flags frozen: `-p --provider halogen-local --model halogen-qwen3.8-flash-next --api-key local --no-session --no-context-files --no-approve --no-extensions --no-mcp`. Pi needs no per-call approvals (OS-permission model); `--approve` is project-trust only, not tool authorization. Same fixtures/endpoint/budgets/comparable limits. Documented deltas: Pi usage is Pi-computed (`totalFromProvider:false`), cache fields zero; system-prompt overhead differs; approval UX not comparable by design.

## 5. Preflight gates (≤6 diagnostic requests; global allowance now 8 remaining)

Zero-request unless noted: (1) both agents execute in-container (whoami/hostname/pwd/container-id match); (2) unattended Needletail edit/write/test completes (~3-5 requests); (3) host binary still exits 3 on piped-stdin edit; (4) invalid paths/stale hashes/identity failures denied (deterministic unit tests); (5-6) negative probes (no host files/socket/creds/direct-LAN/external egress; read-only escape fails); (7) artifact export works; (8) both reach same Halogen model+template (2 requests, one per agent); (9) Pi JSON parsed for real failures. Genuine isolation failure → STOP. Plus one focused DeepSeek review of the sandbox policy + wiring; fix criticals first.

## Addendum A. Pinned base images (2026-11-03, `docker pull` at build)

- `node:24-bookworm-slim` → `node@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c`
- `alpine:3.21` → `alpine@sha256:ee16d92f96db08d9d2d07da48555a27f3a69d8f0759021dbc601195ed0d2b5bd`
- `php:8.4-cli` → `php@sha256:7e7413ed31b8c42b31c939cc83b3758b1cd618f7bf3803f5a0c39f98d4adcbee`
- `ubuntu:24.04` → `ubuntu@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`
- `swift:6.4-bookworm` → `swift@sha256:d1bbd901832322ba5590888d687419e199b3a4d693db476c8aadba44038f8b18`

## Addendum B. Egress control (2026-11-03, proven by probe)

- Network `m3d-internal` (`internal:true`, bridge; no host firewall/daemon changes). Forwarder `m3d-forwarder:1` (alpine:3.21+socat, image `sha256:4acb4add598f6fc5bb233b1dc2917edb92703822bc378fc328a2c14b9024e40d`, container `ef2946bc…fbf`) joins `m3d-internal` + default bridge; L4 forward `*:8731 → 192.168.2.216:8731`. Scoring containers join ONLY `m3d-internal` and address the model as `http://m3d-forwarder:8731`.
- Negative probes from an unprivileged (`uid=65534`) probe container on `m3d-internal` (2026-11-03): (1) `GET http://m3d-forwarder:8731/v1/models` → Halogen model list (`halogen-qwen3.8-flash-next`) — allowed path works; (2) direct `http://192.168.2.216:8731/v1/models` → `Network unreachable`; (3) `http://example.com/` → DNS failure (`bad address`); (4) `/var/run/docker.sock` absent. Ordinary-bridge egress NOT relied upon.

## Addendum B. Execution images (2026-11-03, built from frozen `f4fef24` archive)

- `m3d-needletail:1` = `sha256:b7c2336bc8aa71460cc02ae70e1abbd839c268cca6b366205f44b79665ecc46a` (multi-stage: `swift:6.4-bookworm` builder compiles `git archive` of the frozen tree; runtime `node:24-bookworm-slim` + `python3` + bundled Swift runtime libs; non-root `bench`, entrypoint `needletail`; verified in-container: `0.3.0`, `python3 3.11.2`, `node v24.22.2`). Rebuilt 2026-11-03: the first build used a pre-fix source archive and wrongly denied versioned interpreter resolves (`python3` → `python3.11`); two scored attempts ran on that stale image and are DISCARDED as harness-invalid with ~12 wasted requests counted against the global ceiling (T01-R1-nt exit-3, T02-R1-nt incomplete).
- `m3d-pi:1` = `sha256:55e429c5be4767c11434f4e644a114e7ede41436d496b4cc44ccce800b682436` (`node:24-bookworm-slim` + `python3` + installed Pi 1.4.0 dist + frozen halogen-only `models.json` (`samplingParams.temperature: 0.2`) + settings; non-root `bench`; verified in-container: `1.4.0`, `python3 3.11.2`, `node v24.22.2`, no php/swiftc).
- Model toolchain symmetry (verified in both images): python3 ✓ / node ✓ / swiftc ✗ / php ✗. Oracles cover swiftc (host) and php (`php:8.4-cli` container).
- `m3d-forwarder:1` = `sha256:4acb4add598f6fc5bb233b1dc2917ebd92703822bc378fc328a2c14d9024e40d` (see Addendum A).
- Scoring-tree equivalence: `Sources/` + `Tests/` are byte-identical between the image build tree (`f4fef24`) and HEAD (verified `git diff f4fef24 HEAD -- Sources Tests` empty); only docs/harness scripts differ.

## Addendum C. Preflight evidence (2026-11-03; diagnostic spend 10/10, allowance exhausted)

- (1) Both agents execute in containers: `m3d-needletail:1` → `0.3.0`, `m3d-pi:1` → `1.4.0` (non-root host-mapped uid, hostnames set; per-run identity = container hostname + launcher grant).
- (2) Unattended Needletail edit/write/test: scratch read→edit→write completed with ZERO human input; model-proposed `exec /bin/sh -c …` resolved to `/usr/bin/dash` and was DENIED by the allowlist (not in [python3,node,swiftc,php,git]) → headless exit 3, no hang. Ledger: `sandbox-granted` event (auto-approved batch) + `approval-required`/`unavailable` hold (denied exec). 6 requests via forwarder.
- (3) Host binary (piped stdin, edit task): exit 3, `approval required`, file byte-identical. Host policy intact.
- (4) Deterministic: 15 SandboxPolicy + grant-transition + budget + usage tests green.
- (5-6) Negative probes: direct Halogen IP unreachable, external DNS fails, no docker socket, no host home, read-only root enforced, workspace/tmp writable only. Live images lack shell probing tools; network shape proven on `m3d-internal` + per-run ledger/usage evidence.
- (7)Artifacts: per-run dirs on host post-run (workspace, state incl. GRDB, logs, grant); ledger queried read-only (`sandbox-granted` verified).
- (8) Same model via forwarder: Needletail 6 requests + Pi exact-echo (`PI-DOCKER-OK`, exit 0, `--mode json` usage schema captured: Pi-computed totals, `totalFromProvider:false`).
- (9) Pi JSON stream parsed for failures (message_end/usage/responseId schema recorded in scorer).
- Spend: compat probes 2 + NT preflight run 6 + host exit-3 1 + Pi container probe 1 = 10/10 diagnostic. No further pre-scoring live traffic. T09 resume mechanics validated in-situ during scoring (leg 1 interrupt is itself polled + logged).
- Pi config fix found in preflight: read-only root breaks Pi's settings lockfile → scorer sets `PI_CODING_AGENT_DIR=/state/pi-config` (seeded per run from frozen `docker/pi-models.json` + `docker/pi-settings.json`).

## 6. Execution and closeout

Resumable scorer runs the 48 AB/BA matrix unattended (skip completed, per-run timeout, durable per-run dirs). Enforcement: Needletail turn limits + per-request budget accounting; Pi counted post-hoc with abort-on-exceed. Preserve logs/events/GRDB/diffs/oracles/usage/container+image identity per attempt. Then: paired analysis, `plans/m3-d-receipt.md`, final M3 report with PROCEED/CONDITIONAL/STOP, CodeRabbit aggregate + CI before any merge recommendation. STOP after: no M4, no push/PR/merge.
