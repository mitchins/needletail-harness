# M3-D Benchmark Protocol (pre-registration — no scored run has executed)

Frozen companion to `plans/m3-tasks.json` (frozen 2026-11-03). No scored runs, no oracle edits after the first scored run. Scoring is NOT authorized by this document — it is BLOCKED on the operator decisions in §7.

## 1. Design

- 12 tasks × 2 matched repetitions × 2 harnesses = 48 scored runs. Repetitions use byte-identical regenerated fixtures in fresh dirs; reps differ only by execution order, never by content.
- AB/BA per pair: R1 runs Needletail then Pi; R2 runs Pi then Needletail (order-effect counterbalance for server load / cache warmth; cache stays observational regardless).
- Isolation per repetition: fresh scratch dir + fresh Needletail `NEEDLETAIL_STATE_DIR` + fresh Pi session (`--no-session` or fresh `--session-dir`). No shared state between runs.
- Setup (fixture write + `git init`/`git add -A`) is excluded from scoring; the clock starts at run invocation.
- PHP tasks T03/T11 are CONDITIONAL (see §2): if `php` remains unprovisioned they are reported BLOCKED (40 scored + 8 blocked, adjusted transparently — never silently dropped, never counted as failed).

## 2. Environment record (pre-registration, 2026-11-03)

- Needletail: `m3-planning` @ `9bdfd94` (`M3-C QUALIFIED…`, tree `24dc471e…`), release binary rebuilt from this tree for live runs. Re-verify SHA before scoring; any code change after the freeze requires re-freeze.
- Halogen (last-known, MUST re-verify before first scored run with 1 `doctor --probe` diagnostic request): `http://192.168.2.216:8731/v1`, api/engine 0.18.20, served model `halogen-qwen3.8-flash-next`, context 262144 (per M3-A receipt). Re-verification is counted in the diagnostic allowance.
- Needletail model config: alias `local-coder`, temperature 0.2, max_output 4096, context 262144 (`/tmp/m3a-xdg` pattern, isolated per-run state dirs).
- Pi: 1.4.0 at `/home/mitch/.local/bin/pi`, config `~/.pi/agent/` (defaultProvider `opencode-go`, defaultModel `kimi-k3` — cloud defaults NOT used for scoring).
- Toolchains: python3 3.15, node v24.22 (TS via native type-stripping of erasable syntax ONLY — verified; `tsc` absent, no downloads), swiftc 6.4, `php` ABSENT (`which php` fails; T03/T11 blocked), rg/git present.
- Pi provider compatibility: OPEN. Pi supports OpenAI-compatible LAN registration (`~/.pi/agent/models.json` `providers` map — the ST7-B1 `gemma-local` entry at `http://192.168.1.14:8000/v1` proves the mechanism), but NO entry exists for Halogen (`192.168.2.216:8731`). Required operator step: add a `halogen-local` entry (`baseUrl http://192.168.2.216:8731/v1`, `api openai-completions`, model `halogen-qwen3.8-flash-next`, contextWindow 262144) mirroring that pattern. Do NOT edit the operator's `~/.pi` without explicit approval. Open compat questions (answer before scoring): Pi temperature control (match 0.2 if exposed, else document default); Pi `-p` approval behavior (auto-approve vs prompt — determines Pi-side attendance); Pi usage reporting (`--mode json` schema for tokens — determines token metric support); Pi resume procedure for T09 (`--continue` semantics). If Pi cannot use this server/model correctly, STOP and report the compatibility blocker (no substitute model).

## 3. Attended execution procedure

- Needletail rule (frozen, from `batchNeedsApproval` + headless `.unavailable` → exit 3): read/search need no approval; ANY edit/write/exec batch in workspace mode requires explicit operator approval on a REAL TTY (stdin+stderr both TTYs). Forbidden workarounds (enforced): no automatic `y`, no preloaded stdin, no scripted gateway, no `--trusted`, no config downgrade.
- Approval policy (frozen, avoids biasing results): the operator approves ONLY in-scratch, non-destructive commands and file batches (test runners `python3 -m unittest`, `node`, `swiftc -typecheck`, `php -l`; edit/write batches confined to the scratch dir); denies anything touching network, absolute paths outside scratch, or destructive operations. Denials are data (counted, run continues or fails honestly).
- Attendance matrix: T12 needs NO attendance (read-only, headless-safe both sides). All other Needletail runs are ATTENDED (11 tasks × 2 reps = 22 attended runs). Pi attendance per run: attended until its `-p` approval behavior is proven otherwise.
- Per attended run record: approval count (Needletail: durable `authorising` events; Pi: session record) + human wait time (operator stopwatch per run, started at prompt display) + model/tool time split (best-effort from stage timings where available, else wall only with a note).

## 4. Budgets (frozen)

- Per-task: default 10 turns / 15 requests / 1200 s; T08 40 turns / 45 requests / 3600 s; T09 10 / 15 / 1800 s. T08's `--checkpoint` capture+post runs count against its 45.
- Diagnostic allowance 10 (compat probe ≤3, Halogen re-verify 1, usage-delta validation ≤5, Pi resume-probe ≤1). Global ceiling 850 provider requests across scored + diagnostic traffic. Ceiling breach FAILS the run (per-task) or STOPS scoring (global). Counting: Needletail durable `requesting` events; Pi session record; M3-C budget gate where applicable. Turn limits enforced by the harness (`--max-turns`); request ceilings verified post-hoc from durable records (fail-closed accounting, no silent extension, no reruns).
- Token gap (pre-scoring delta REQUIRED): per-request usage is NOT durably recorded for plain `run`s (only the M3-C checkpoint flow prints usage lines; the trace sink carries UI events, not usage). Before scoring, add minimal additive usage logging (same one-line-per-request stderr shape for all runs; no behavior change), review it, and validate within the diagnostic allowance. Until then, tokens are UNKNOWN by construction.

## 5. Metrics and analysis (per run; retained raw)

- Oracle PASS/FAIL/BLOCKED (BLOCKED only for unprovisioned-php tasks or harness incompatibility — never for poor performance); unified diff + changed-file scope; provider requests; tokens in/out (or UNKNOWN with reason); wall time; provider/tool split (best-effort); approval count + human wait; tool/exec failures; recovery failures; end transcript size + checkpoint events; cache evidence (observational only).
- T08 context sub-oracle: post usage_in < capture usage_in AND retainedFromSeq > first transcript seq (Needletail only; NOT-APPLICABLE if history ≤ 64 records — recorded, not failed).
- Analysis: paired task-level results; uncertainty intervals clustered by task where estimable; explicitly separated: coding success, protocol reliability, durability/recoverability, context behavior, runtime/token efficiency, operator friction, deployment simplicity. 12 tasks cannot establish statistical coding superiority — the recommendation weighs defensible advantage, not p-values.
- Verdict scale: PROCEED (sustained advantage justifies continued investment) / CONDITIONAL (narrow, with named conditions) / STOP. TUI/UX/approval friction are known deferred costs and count against PROCEED. No M4-readiness claim from headless operation alone.

## 6. Stop rules

No scored run until: (a) Pi Halogen registration confirmed + compat answers recorded; (b) operator attendance scheduled (or formally declined → stop with bottleneck report); (c) php provisioned or T03/T11 formally BLOCKED; (d) usage-logging delta implemented, reviewed, validated. First scored run freezes the file set; any later change voids prior scores.
