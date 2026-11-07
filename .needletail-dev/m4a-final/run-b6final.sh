#!/bin/zsh
# M4-B final macOS evidence battery (clean run).
# 1. Fresh tree assumed at $HOME/m4b (caller extracts before invoking).
# 2. Debug behavior per B6 suite (gated suites report 0 tests on Darwin; Linux debug covers them; ungated suites pass).
# 3. Precise G14-only lift (suite-gate lines only: next line is "struct"),
#    -O per suite, byte-identical restore verified by SHA-256.
setopt SH_WORD_SPLIT
cd $HOME/m4b || exit 99
export PATH=/usr/local/bin:$PATH
LOG=$HOME/m4bfinal-run.log
: > $LOG
echo "=== 0. tree identity ===" | tee -a $LOG
git rev-parse HEAD 2>/dev/null | tee -a $LOG || echo "(no git; tarball tree)" | tee -a $LOG
echo "=== 1. debug behavior ===" | tee -a $LOG
for s in QueueIntegrationTests QueueAttachmentActorTests QueueCrashActorTests UndoFilesTests UndoTests UndoJournalTests QueueContractTests QueueDurabilityTests QueueReorderTests; do
  swift test --filter "$s" > "$HOME/m4bfinal-dbg-$s.log" 2>&1
  code=$?
  line=$(grep -a "Test run with" "$HOME/m4bfinal-dbg-$s.log" | head -1)
  sig=$(grep -a "signal code" "$HOME/m4bfinal-dbg-$s.log" | head -1)
  echo "DBG $s exit=$code :: $line $sig" | tee -a $LOG
done
echo "=== 2. precise G14-only lift ===" | tee -a $LOG
FILES="Tests/NeedletailActorTests/QueueIntegrationTests.swift Tests/NeedletailActorTests/QueueAttachmentActorTests.swift Tests/NeedletailActorTests/QueueCrashActorTests.swift Tests/NeedletailStateTests/QueueContractTests.swift Tests/NeedletailStateTests/QueueDurabilityTests.swift Tests/NeedletailStateTests/UndoTests.swift Tests/NeedletailStateTests/QueueReorderTests.swift"
for f in $FILES; do
  [ -f "$f" ] || { echo "MISSING $f" | tee -a $LOG; continue }
  cp "$f" "$f.pristine-b6final"
  shasum -a 256 "$f" | cut -d' ' -f1 > "$f.sha-b6final"
done
for f in $FILES; do
  [ -f "$f" ] || { echo "MISSING $f" | tee -a $LOG; continue }
  python3 - "$f" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).readlines()
n = 0
for i, l in enumerate(lines):
    if l.strip() == '#if canImport(Glibc)' and i + 1 < len(lines) and lines[i+1].lstrip().startswith('struct '):
        lines[i] = '#if true // LIFTED for -O (B6 final evidence; reverted after)\n'
        n += 1
open(p, 'w').write(''.join(lines))
print(n)
PYEOF
done | tee -a $LOG
echo "=== 3. -O battery ===" | tee -a $LOG
for s in QueueIntegrationTests QueueAttachmentActorTests QueueCrashActorTests QueueContractTests QueueDurabilityTests UndoTests QueueReorderTests; do
  swift test -c release --filter "$s" > "$HOME/m4b-final-opt-$s.log" 2>&1
  code=$?
  line=$(grep -a "Test run with" "$HOME/m4b-final-opt-$s.log" | head -1)
  echo "OPT $s exit=$code :: $line" | tee -a $LOG
done
echo "=== 4. restore + verify ===" | tee -a $LOG
bad=0
for f in $FILES; do
  if [ -f "$f.pristine-b6final" ]; then mv "$f.pristine-b6final" "$f"; fi
  if [ -f "$f.sha-b6final" ]; then
    now=$(shasum -a 256 "$f" | cut -d' ' -f1)
    exp=$(cat "$f.sha-b6final")
    if [ "$now" = "$exp" ]; then echo "OK identical: $f" | tee -a $LOG; else echo "MISMATCH: $f" | tee -a $LOG; bad=$((bad+1)); fi
    rm -f "$f.sha-b6final"
  fi
done
leftovers=$(grep -rl 'LIFTED for -O' Tests/ 2>/dev/null | wc -l | tr -d ' ')
echo "leftover lifted markers (expect 0): $leftovers" | tee -a $LOG
if [ "$bad" = "0" ] && [ "$leftovers" = "0" ]; then echo "REVERT-CLEAN" | tee -a $LOG; else echo "REVERT-DIRTY" | tee -a $LOG; fi
echo B6FINAL-DONE | tee -a $LOG
