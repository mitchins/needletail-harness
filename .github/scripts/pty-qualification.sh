#!/bin/sh
# M4-OPS-10 adversarial process-lifecycle qualification. Runs ONLY in a
# disposable GitHub-hosted VM (workflow_dispatch, no secrets, no live
# traffic) and is removed from the tree after its evidence run. It
# exercises the REAL stream_bounded (extracted verbatim from ./dev, not
# a copy) plus the real aggregate entry points, and asserts bounded
# process-ownership invariants. Every phase is bounded; diagnostics go
# to the job log and the uploaded artifact.
set -u
cd "${GITHUB_WORKSPACE:-$(pwd)}"
root_dir="$(pwd)"
mkdir -p .needletail-dev/logs
PASS=0; FAIL=0
LATCH=.needletail-dev/logs/PHASE-TIMEOUT-LATCH
ok()  { echo "SCENARIO-OK   [$1] $2"; PASS=$((PASS+1)); }
bad() { echo "SCENARIO-FAIL [$1] $2"; FAIL=$((FAIL+1)); }

# The code under test, extracted verbatim — not a reimplementation.
sed -n '/^stream_bounded() {/,/^}/p' dev > /tmp/sb-extracted.sh
grep -q '^stream_bounded() {' /tmp/sb-extracted.sh || { echo "FATAL: stream_bounded extraction failed"; exit 2; }
. /tmp/sb-extracted.sh

# S8 setup: an unrelated bystander process that must survive EVERYTHING.
# 2 h lifetime — far beyond the script's duration (the job timeout kills
# the VM tree long before expiry); the earlier 5-min value expired
# NATURALLY mid-script in CI and produced a false "signalled" verdict.
sleep 7200 &
BYSTANDER=$!
check_bystander() {
    if kill -0 "$BYSTANDER" 2>/dev/null; then
        ok S8 "unrelated process (pid $BYSTANDER) untouched"
    else
        bad S8 "unrelated process was signalled"
    fi
}

# ---- S1: phase leader exits 0 while a descendant survives -> latch ----
rm -f "$LATCH"
stream_bounded s1 20 sh -c 'sleep 120 & exec sleep 0' >/tmp/s1.log 2>&1
sleep 1
if [ -f "$LATCH" ]; then
    ok S1 "leader-exited survivor detected; latch engaged"
else
    bad S1 "surviving descendant escaped the normal-exit survivor check"
fi

# ---- S4: the latch blocks subsequent lanes; latch-clear restores ----
# stream_bounded's latch refusal exits the process (correct aggregate
# semantics), so the probe runs in a subshell and the harness survives.
( stream_bounded s4 20 sh -c 'true' ) >/tmp/s4.log 2>&1
S4RC=$?
if [ "$S4RC" -ne 0 ] && grep -q "PHASE-TIMEOUT-LATCH" /tmp/s4.log; then
    ok S4 "latched survivor blocks subsequent lanes"
else
    bad S4 "a lane started on top of surviving processes"
fi
./dev latch-clear >/dev/null 2>&1
rm -f "$LATCH"

# ---- S2: descendant ignores TERM; group SIGKILL required; no latch ----
stream_bounded s2 5 sh -c 'trap "" TERM; sleep 120' >/tmp/s2.log 2>&1
RC=$?
sleep 1
if grep -q "deadline kill" /tmp/s2.log && [ ! -f "$LATCH" ]; then
    ok S2 "TERM-ignoring descendant killed by group escalation; no false latch"
else
    bad S2 "TERM-ignoring phase mishandled (rc=$RC, latch=$([ -f "$LATCH" ] && echo set || echo clear))"
fi
rm -f "$LATCH"

# ---- S3: escalation completes BEFORE the runner reports cleanup ----
stream_bounded s3 5 sh -c 'echo $$ > /tmp/s3.pid; trap "" TERM; sleep 120' >/tmp/s3.log 2>&1
RC=$?
# $$ inside the setsid'd sh IS the group leader pid = pgid.
if [ "$RC" = 124 ] && grep -q "CLEANUP COMPLETE" /tmp/s3.log \
   && ! kill -0 -- "-$(cat /tmp/s3.pid)" 2>/dev/null; then
    ok S3 "process group already dissolved when the runner returned 124"
else
    bad S3 "escalation incomplete at runner return (rc=$RC)"
fi

# ---- S6: deadline kill is a 124 FAIL, never a pass ----
NEEDLETAIL_PHASE_SECS_OVERRIDE=5 ./dev test timing >/tmp/s6.log 2>&1
RC=$?
if [ "$RC" = 124 ] && grep -q "deadline kill after 5s" /tmp/s6.log \
   && grep -q "Not a pass" /tmp/s6.log; then
    ok S6 "interrupted lane reports 124 + FAIL diagnostics; no false pass"
else
    bad S6 "timeout exit semantics broken (rc=$RC)"
fi

# ---- S7: dedicated-socket scoping; failed creation never destroys ----
apt-get -v >/dev/null 2>&1 || true
command -v tmux >/dev/null 2>&1 || { echo "FATAL: tmux missing"; exit 2; }
QSOCK=/tmp/qual-$$.sock
tmux -S "$QSOCK" new-session -d -s qual-owned -x 80 -y 24 || { echo "FATAL: qual server"; exit 2; }
# A bystander session on the DEFAULT server: must never be touched.
tmux new-session -d -s qual-default-bystander -x 80 -y 24 || { echo "FATAL: default server"; exit 2; }
# Duplicate name on the dedicated socket = failed creation.
tmux -S "$QSOCK" new-session -d -s qual-owned -x 80 -y 24 2>/dev/null
if tmux -S "$QSOCK" has-session -t qual-owned 2>/dev/null \
   && tmux has-session -t qual-default-bystander 2>/dev/null; then
    ok S7 "failed creation left the existing session untouched; default server untouched"
else
    bad S7 "session ownership violated by a failed creation"
fi
# Ownership-scoped teardown only (our own creations).
tmux -S "$QSOCK" kill-session -t qual-owned 2>/dev/null
tmux kill-session -t qual-default-bystander 2>/dev/null
rm -f "$QSOCK"

# ---- S5: aggregate executes REAL case-group commands (exact exec) ----
if ./dev test case-group m1a >/tmp/s5.log 2>&1 && grep -q "Test run with" /tmp/s5.log; then
    ok S5 "case-group command executed exactly as supplied (real runner)"
else
    bad S5 "aggregate case-group invocation broken (swift prefix leaked?)"
fi

check_bystander
echo "=============================================="
echo "QUALIFICATION RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
