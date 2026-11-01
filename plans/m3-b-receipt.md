# M3-B Receipt — real five-tool coding loop (Halogen local-coder)

- Branch: `m3-planning`; code SHA: `7c3d4f8` (unchanged from M3-A qualified HEAD — **zero production-code changes**; this receipt is the only new file).
- Baseline: `main` @ `1ab0aa4` (tree `04cc08b`). Plan: `plans/m3-plan.md` M3-B.
- Model/server: alias `local-coder` → `http://192.168.2.216:8731/v1/chat/completions`, served `halogen-qwen3.8-flash-next` (probe re-check 1 request: 59/16 in 601 ms, identity unchanged — Halogen 0.18.20 per M3-A health record). Locality local, protocol openai-chat-completions.
- Isolation: fresh scratch repos `/tmp/m3b-scratch-{read,search,edit,write,exec,task}` (fixtures: deterministic, no secrets); state `/tmp/m3b-state` (0700) separate from every workspace; evidence `/tmp/m3b-evidence` (0600, gitignored path `/tmp`); config `/tmp/m3a-xdg` (0600, exact origin).
- Real-model gate: every tool call below originated from Halogen through the production `ChatCompletionsTransport` + `SessionActor` + `NativeToolExecutor` + GRDB store via the production CLI `needletail run`. No `--trusted`, no `--tools` scripted backend, no synthetic responses.

## Provider-request budget (hard ceiling 40)

Ledger: `.needletail-dev/m3b/ledger.jsonl` (0600). **Used 15 / 40, remaining 25.** Per run (counts = durable `requesting` events in the isolated GRDB store, not turns):

| Run | Session | Requests | Exit | Verdict |
|---|---|---|---|---|
| probe (identity re-check) | — | 1 | 0 | served identity confirmed |
| read | `sess-run-2D6F322D…` | 2 | 0 | **PASS** |
| search | `sess-run-C812F65F…` | 4 | 0 | **PASS** |
| edit | `sess-run-99D207FE…` | 2 | 3 | **SAFETY HOLD** approval-required |
| write | `sess-run-240F30D5…` | 1 | 3 | **SAFETY HOLD** approval-required |
| exec | `sess-run-AB37B906…` | 2 | 3 | **SAFETY HOLD** approval-required |
| integrated task | `sess-run-706814C7…` | 2 | 3 | **PARTIAL** — held at edit approval |
| unresolved-hold diagnostic (edit scratch re-run) | follow-up | 1 | 0 | gate clean (proves no durable ambiguity left) |

## Five-tool qualification matrix

| Tool | Model-originated call (verbatim arguments, real callID) | Receipt / outcome | Verdict |
|---|---|---|---|
| `read` | `read {"path": "poem.txt"}` `call_0eda97ca76234953aab5e68a` | native response bytes `line one\nM3B-READ-9182 marker line\nline three\n` = fixture exactly; model reported marker at line 2 | **PASS** |
| `search` | `search {"path": "docs", "pattern": "NEEDLE"}` `call_c3220840b8704cee9ab22cc0` (+ `read docs/notes.md` `call_82841d47761a47de9e1757fa`) | outcome `search NEEDLE` done; correct path `docs/notes.md` + match `M3B-NEEDLE-7331` reported | **PASS** |
| `edit` | `edit {"expectedHash": "000…0", "new_string": "RATE = 3", "old_string": "RATE = 2", "path": "calc.py"}` `call_d32583f390e948d0a8aba643` | gated at `authorising`; headless gateway `.unavailable` → approval-required exit 3; **no mutation** (`calc.py` sha256 `dee7982a…` unchanged) | **SAFETY HOLD** (operator approval requested) |
| `write` | `write {"content": "M3B-WRITE-4410 ledger\ncreated by the model\n", "path": "notes.md"}` `call_9a041d902d484ea389d354ea` | gated at `authorising` → exit 3; **scratch dir verified empty** — no file created | **SAFETY HOLD** (operator approval requested) |
| `exec` | `exec {"argv": ["/usr/bin/wc", "-l", "words.txt"], "executable": "/usr/bin/wc"}` `call_ce5c42a66e73452682c62b61` | two-factor gate: banner `native exec composed`, resolved `/usr/bin/wc` **digest `76e67523290e4a6c…`** timeout 120 s → approval-required exit 3; **nothing executed** | **SAFETY HOLD** (operator approval requested) |

Integrated coding task (`mathlib.py` integer-division bug): model read `README.md`/`mathlib.py`/`test_mathlib.py` (`call_9e718547…`, `call_6be7527b…`, `call_7985ad72…`), **correctly diagnosed the `//` truncation defect**, proposed the exact minimal edit (`sum(chunk) // window` → `sum(chunk) / window`, `call_e83a498a…`) → approval-required exit 3. Repo hashes unchanged (`mathlib.py 6d58508d…`, `test_mathlib.py 2da06b03…`, `README.md 4af599d4…`). No regression test added, no tests executed. Verdict: **PARTIAL** — diagnosis complete, correction gated, awaiting operator.

## Operator approvals

**None granted, none refused — all gated batches stopped at approval-required** (headless `ApprovalGateway.unavailable` per POLICY-04; the development agent did not and will not auto-answer). Per authorization, M3-B stops at this boundary. Exact requests awaiting a human decision:

1. `edit` batch (task): `mathlib.py` `old: results.append(sum(chunk) // window)` → `new: results.append(sum(chunk) / window)` (model also supplied a fabricated `expectedHash` — see classification below; the dispatch validator will re-verify against the real file hash and must be expected to refuse that specific proposal form).
2. `write` batch: create `notes.md` (2 lines, content verbatim above).
3. `exec`: `/usr/bin/wc` resolved digest `76e67523290e4a6c…`, argv `['/usr/bin/wc','-l','words.txt']`, cwd scratch root, timeout 120 s.

## Failure classification (ticket §6)

- **Harness defects:** none. Gates, fencing, persistence and classification behaved as designed. One observation (not a defect): `search` results expose `/proc/self/fd/NN/…` absolute paths to the model (rg receives the workspace via fd for containment); the model correctly fell back to workspace-relative paths — record for M4/DX.
- **Model defects (correctly contained):** (a) both `edit` proposals fabricated `expectedHash` `000…0` instead of the observed file hash — the dispatch validator would refuse these at execution (optimistic-concurrency contract); (b) in the search scenario the model twice attempted `read` with absolute `/proc/self/fd/87/...` paths — `tool-failure: absolute path not allowed for read (invalid-arguments)` denied by the validator, and the model recovered with workspace-relative paths. Both denied exactly as designed.
- **Environment defects:** none (all fixtures/executables present; server available throughout).
- **Inconclusive:** completion of edit/write/exec and the integrated repair/verify legs — awaiting a human approval decision, not a model or harness failure.
- **Safety holds:** the three approval-required stops + integrated-task hold (above).

## Real-model vs offline evidence

Real-model (this receipt): all tool calls, proposals, diagnostics and summaries above. Offline/scripted (prior milestones, unchanged): C2 `C2ExecDurableTests` 41, C3 `C3ExecQualificationTests` 18, D3 integration lanes — these certify reducer/store/executor mechanics and are NOT counted as real-model evidence here.

## Persistence and containment

- Every run appended `sessionOpened`/`epochOpened` + transcripts + intents/results to the isolated GRDB store under `/tmp/m3b-state` (outside all workspaces). Example fidelity: `read` tool response transcript bytes = fixture bytes exactly.
- Post-hold diagnostic run in the edit scratch completed exit 0 with no cross-run gate block — **no unresolved or ambiguous markers were durably left** (mutating intents are recorded only after approval, so a refused/unanswered batch leaves nothing ambiguous).
- No scratch file was created or modified by any gated batch (hash + directory listings above). No operator workspace, repository content, network egress (beyond the authorized endpoint), or host command execution occurred.

## Raw evidence

`/tmp/m3b-evidence/` (0600): `{read,search,edit,write,exec,task}-{stdout.jsonl,trace.jsonl,stderr.txt}`. Key digests: read `05d1454f…`, search `6460c2bb…`, edit `799a881d…`, write `6e3f2d34…`, exec `f4cbe521…`, task `57fd789a…` (stdout=trace JSONL). Ledger `.needletail-dev/m3b/ledger.jsonl` (0600, gitignored path). Scratch repos retained under `/tmp/m3b-scratch-*` for operator inspection of the exact gated proposals.

## Verdict

**M3-B PARTIAL QUALIFIED — 2/5 tools PASS with genuine real-model calls; 3/5 + integrated task held at the production approval boundary** (edit, write, exec, integrated repair all stopped at approval-required with exact structured requests; zero mutations, zero executions, zero unresolved side effects). This is the ticket-mandated outcome absent a human operator: the approval two-factor gate demonstrably works against real model proposals. No harness defect was found; two model defect classes (fabricated `expectedHash`, absolute-path reads) were produced and correctly contained by the production validators.

## Smallest follow-up authorization request (to complete M3-B)

Authorize a bounded completion delta (≤15 provider requests, remaining ceiling 25): an operator-approved mechanism for the three held operations — (a) an interactive TTY session for `edit`/`write`/`exec` batches in the retained scratch repos (human answers the prompts), or (b) an operator-supplied ApprovalGateway decision for the exact requests listed above. Scope: complete the gated edit/write/exec receipts, finish the integrated task (fix + regression test + `/usr/bin/python3 -m unittest` run + repair loop), keep the same ledger and evidence discipline.

---

## Completion delta (Phase A corrections + Phase B boundary), 2026-11-02

**Code SHA:** `dc18702` — Phase A production correction (two tool-contract defects fixed with RED/GREEN; committed separately from evidence):

1. **Model-visible read receipt (A1).** Defect: the native executor computed the exact full-file SHA-256 (`ToolCallOutcome.beforeHash`) on every read, but `continueAfterEffectPerCall` emitted only `outcome.data`, so the model never saw the hash — the live loop fabricated `expectedHash 000…0`. Fix: successful native reads now emit `[read receipt] path/sha256/truncated` from the executor-computed hash over the COMPLETE bytes; `edit.expectedHash` validation and optimistic conflict checks untouched. RED/GREEN (`Tests/NeedletailActorTests/M3BReadReceiptTests.swift`, production actor + native executor + real FS): RED = transcript lacked hash; GREEN = receipt carries exact hash; edit-with-observed-hash succeeds; stale hash conflicts with zero overwrite; truncated preview reports the complete-file hash (`truncated: true`).
2. **Logical search paths (A2).** Defect: `filterSearchJSON` computed the approved logical workspace-relative path but appended the ORIGINAL rg line, exposing `/proc/self/fd/NN/…` to the model. Fix: kept lines are rebuilt through structured JSON re-serialization with `data.path.text` = logical path (no blind string replacement); match text/line numbers/offsets preserved; exact Unicode names byte-exact; lossy (unrepresentable) names dropped fail-closed with the truncation flag; protected classification, FD-anchored traversal, bounds and redaction unchanged. RED/GREEN in `B2ReadSearchTests` (+4): logical path usable directly by `read`, read-root base joined, protected dropped, Unicode preserved, lossy flagged, real-rg end-to-end shows `docs/notes.md` with zero `/proc/self/fd`.

**Regression gate:** B2 14/14, B3+TOOL09+TOOL10 65/65, QueueAttachment 19/19 + actor 19/19, D3 15/15, Undo actor/files/journal + export/codec green. No regressions; only the two targeted behaviors changed.

**Live confirmation (delta budget: 5 of the 15 authorized requests; cumulative 20/40, 20 remaining):**
- read2 (`2` requests): model read `poem.txt`, receipt `sha256: 03ff0a237b1b178ba45cfba91c4433421e06d285cc8132e5816ef9d7512641c1` in the durable transcript, model reported it verbatim — matches `sha256sum`. exit 0.
- search2 (`3` requests): model-visible search results carry `docs/notes.md`; model confirmed zero `/proc/self/fd` appeared. exit 0.

**Phase B — operator-attended completion (prepared, stopped at the approval boundary):**

No human operator was available in this session, so per the authorization the boundary stands. The exact runnable command (real terminal required — stdin and stderr must be TTYs for `TerminalApprovalGateway`; do not pipe or redirect them):

```sh
cd /tmp/m3b-scratch-task
XDG_CONFIG_HOME=/tmp/m3a-xdg NEEDLETAIL_STATE_DIR=/tmp/m3b-state \
  /data/coding/needletail/.build/release/needletail run \
  --workspace /tmp/m3b-scratch-task \
  --allow-exec \
  --max-turns 10 \
  --prompt "This project has a failing unit test. (1) read README.md, mathlib.py and test_mathlib.py (each read receipt carries the file's exact sha256 — use it for expectedHash); (2) edit mathlib.py to fix the moving_average defect (integer division truncates; the spec requires the exact mean); (3) write a new file test_regression.py with a regression test for the spec example; (4) run /usr/bin/python3 -m unittest test_mathlib -v via the exec tool and repair if needed; (5) summarize the diff."
```

Pre-state hashes (repo unchanged since the first hold): `mathlib.py 6d58508d…`, `test_mathlib.py 2da06b03…`, `README.md 4af599d4…`. The attending human independently approves or denies each prompt (edit batch, write batch, exec identity `/usr/bin/python3` resolved at prompt time — prior `/usr/bin/wc` approval, if any, does not carry over). The development agent does not type `y` or simulate the operator. Result feeds the M3-B completion ledger: approved+executed → tool PASS evidence; denied or absent → SAFETY HOLD stands.

**Reviewer status:** DeepSeek route remains unavailable (`Insufficient account funds`, two attempts 2026-11-02, hold recorded in `.needletail-dev/m3b/ledger.jsonl`). No substitute reviewer used; no APPROVED claimed. **M3-B IMPLEMENTED — REVIEW HOLD.**
