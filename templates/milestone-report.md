# Milestone closeout report — M0 (M0-A + M0-B)

> Template per MILESTONES.md "Required report at every closeout". Reports
> attest to work already executed; they never promise later evidence. The
> packet's own `templates/milestone-report.md` was not present in this
> workspace; this minimal template records the same required fields and is
> itself subject to slice review.

## Identity

- Milestone / minor slices:
- Base SHA / tree hash:
- Head SHA / tree hash:
- Plan digest (`plans/<slice>-plan.md` sha256):
- Dependency-lock digest (`Package.resolved` sha256):
- OS / toolchain / architecture:
- Timestamp / duration:

## Scope

- Cases in scope (IDs), invariants touched:
- Changed files (added/modified/deleted):
- Dependency delta vs previous slice:

## Evidence

- Exact commands run (verbatim):
- Exit codes and raw outputs retained under `.needletail-dev/` (paths):
- RED evidence: failing observation and intended reason per new behaviour:
- GREEN evidence: first passing observation:
- Cold build / warm suite / per-slow-test timings; pure vs native split:

## Results by evidence layer and platform

| Layer | Platform | Cases | PASS | FAIL | BLOCKED_REVIEW | UNQUALIFIED_ENVIRONMENT | DEFERRED_BY_PLAN | NOT_IMPLEMENTED |
|---|---|---|---|---|---|---|---|---|
| pure | Linux x86_64 | | | | | | | |
| integration | Linux x86_64 | | | | | | | |
| nativeProcess | Linux x86_64 | | | | | | | |

## Review

- Reviewer alias / actual route / packet digest / subject digests / timestamp:
- Findings and dispositions (ID, severity, resolution, evidence):
- Review type performed (plan / minor-milestone / epic):

## Limitations and gate status

- Known limitations, hold items, unresolved operations:
- Gate status (satisfied / held) and the next authorized action:
