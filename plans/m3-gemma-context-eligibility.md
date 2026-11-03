# Gemma Context Eligibility (frozen tasks vs 110K limit)

Date: 2026-11-03. vLLM reports `max_model_len: 110000` (shared input+output).

Method: per task, max observed `usage_in` across all 48 scored M3-D runs (both harnesses) × 2 growth headroom + 16K max-output reserve + 8K tool-definition reserve. Reserves cover transcript growth to the turn ceiling, checkpoint capture (full-history + instruction), and tool schemas.

| Task | max NT in | proj NT | max Pi in | proj Pi | < 110K |
|------|-----------|---------|-----------|---------|--------|
| T01 | 17800 | 59600 | 854 | 25708 | yes |
| T02 | 25234 | 74468 | 12913 | 49826 | yes |
| T03 | 22567 | 69134 | 871 | 25742 | yes |
| T04 | 22376 | 68752 | 2582 | 29164 | yes |
| T05 | 22346 | 68692 | 1265 | 26530 | yes |
| T06 | 23009 | 70018 | 2720 | 29440 | yes |
| T07 | 21642 | 67284 | 1852 | 27704 | yes |
| T08 | 17824 | 59648 | 2834 | 29668 | yes |
| T09 | 16245 | 56490 | 610 | 25220 | yes |
| T10 | 21345 | 66690 | 1914 | 27828 | yes |
| T11 | 23891 | 71782 | 3077 | 30154 | yes |
| T12 | 14886 | 53772 | 786 | 25572 | yes |

Worst case: T02-NT 74468 < 110000 (32% headroom remaining).

Verdict: **all 12 frozen tasks are COMPARABLE on Gemma 4** — no task exceeds the context ceiling, no fixture shortening, no oracle modification. Proceed to the matched 48-run comparison.
