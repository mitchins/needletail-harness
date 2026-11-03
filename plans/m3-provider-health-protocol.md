# Provider-Health Protocol (frozen — governs all future scored inference)

Status: FROZEN 2026-11-03. Any change requires a dated amendment; no silent tuning.

## 1. Synthetic canary (no benchmark content, no task fixtures)

Before any scored session and every 60 minutes during one, run 3 sequential trivial probes against the active endpoint:
`{"messages":[{"role":"user","content":"Reply with exactly: CANARY-OK"}],"max_tokens":16,"temperature":0}`.
Record: HTTP status, total seconds, model id, content, usage tokens.

## 2. Health thresholds (explicit, frozen)

- HEALTHY: all 3 probes HTTP 200, each < 60 s wall, model id equals the configured id, content exactly `CANARY-OK`.
- DEGRADED: any probe fails, exceeds 60 s, returns another model id, or returns empty/wrong content.
- A task timeout alone NEVER establishes a wedge (timeouts are scored evidence unless the window below applies).

## 3. Degraded-provider procedure

1. Stop launching new scored requests immediately (in-flight requests finish; do not kill containers mid-turn).
2. Preserve the affected attempt verbatim (logs, ledger, timestamps).
3. Identify the complete affected window: first degraded canary (or first anomalous provider signal) through the next HEALTHY triple-probe.
4. Mark affected cells INVALID_INFRA (not PASS/FAIL). No model/harness failure may be excused without window membership.
5. Do NOT restart, reload, or reconfigure the inference server.
6. Resume only after an independent HEALTHY triple-probe.

## 4. Replacement policy (bounded, pre-authorized)

- At most ONE replacement attempt per INVALID_INFRA cell, under identical prompts/fixtures/oracles/limits, in a fresh container.
- Both attempts stay visible (original marked INVALID_INFRA, replacement marked REPLACEMENT); the replacement never overwrites history.
- For a matched comparison, rerun the affected Needletail/Pi PAIR when the invalidation hits one side mid-pair, to restore comparable conditions.
- Any further repetition needs separate maintainer authorization.

## 5. Budget treatment

Canary probes do NOT count against task ceilings or the scored budget (recorded separately as health overhead). Replacement attempts count against the comparison's request budget like any scored cell.
