#!/usr/bin/env bash
# M4-D PTY acceptance runner (B6 run-b6final.sh precedent): builds the
# release product, runs the physical PTY suites, and verifies every
# required case executed its expected NONZERO test count. A zero-test
# pass is FAIL, not PASS. Transcripts persist under
# .needletail-dev/m4d-pty/ on failure (the tests preserve them).
set -u
cd "$(dirname "$0")" || exit 1

LOG=".needletail-dev/logs/m4d-pty-run.log"
mkdir -p .needletail-dev/logs .needletail-dev/m4d-pty
: > "$LOG" # fresh log per run (appending masks regressions)

echo "== m4d-pty: release build =="
swift build -c release --product needletail >>"$LOG" 2>&1 || {
    echo "FAIL: release build failed (see $LOG)"; exit 1
}
BIN=".build/release/needletail"
[ -x "$BIN" ] || { echo "FAIL: release binary missing at $BIN"; exit 1; }
echo "release binary: $(du -h "$BIN" | cut -f1) ($(stat -f%z "$BIN" 2>/dev/null || stat -c%s "$BIN") bytes)"

echo "== m4d-pty: ChatPTYTests (physical release-binary PTY) =="
OUT=$(swift test --filter ChatPTYTests 2>&1); RC=$?
echo "$OUT" >>"$LOG"
if [ "$RC" -ne 0 ]; then
    echo "FAIL: swift test exited $RC (see $LOG)"
    exit 1
fi
SUMMARY=$(echo "$OUT" | grep -aE "Test run with [0-9]+ tests" | tail -1)
echo "$SUMMARY"
TOTAL=$(echo "$SUMMARY" | tr -d "\0" | sed -E 's/.*Test run with ([0-9]+) tests.*/\1/')
if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
    echo "FAIL: ChatPTYTests executed zero tests (see $LOG)"
    exit 1
fi
# Every required PTY case must have STARTED (a silently skipped case is
# a missing tier, BDD-04 — visible here, never promoted).
for N in 01 02 03 04 05 06 07 08; do
    COUNT=$(echo "$OUT" | grep -ac "PTY-$N")
    if [ "$COUNT" -eq 0 ]; then
        echo "FAIL: PTY-$N never started (see $LOG)"
        exit 1
    fi
done
# Residual-acceptance legs (hygiene, byte-identical resubmission,
# TERM-04 refusal) must likewise have started.
for LEG in "confirm hygiene" "byte-identical second Enter" "TERM-04" "PARITY fixed scenario"; do
    COUNT=$(echo "$OUT" | grep -ac "$LEG")
    if [ "$COUNT" -eq 0 ]; then
        echo "FAIL: PTY leg '$LEG' never started (see $LOG)"
        exit 1
    fi
done
if echo "$OUT" | grep -aqE "✘|failed after|failed with"; then
    echo "FAIL: PTY failures present (see $LOG)"
    exit 1
fi
echo "M4D-PTV-OK: ChatPTYTests $TOTAL tests green, all PTY-01…08 started"
