#!/bin/bash
# M3-D scoring matrix: 12 tasks x 2 reps x 2 harnesses = 48 runs, AB/BA ordered.
# Resumable: completed runs (verdict-bearing result.json) are skipped unless --force.
# Stops on global budget exhaustion. Usage: m3d-matrix.sh [--force]
set -u
FORCE=""
if [ "${1:-}" = "--force" ]; then FORCE="--force"; fi
RUNS=/tmp/m3d/runs
GLOBAL_CEILING=850
PASS=0; FAILN=0; BLOCKED=0; SKIPPED=0
declare -a ORDER
for rep in 1 2; do
  if [ "$rep" = "1" ]; then HS="nt pi"; else HS="pi nt"; fi
  for task in T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12; do
    for h in $HS; do ORDER+=("$task $rep $h"); done
  done
done
total_requests() {
  python3 - "$RUNS" <<'EOF'
import json, os, sys
runs = sys.argv[1]
total = 0
for root, _, files in os.walk(runs):
    for f in files:
        if f in ("result.json", "result-leg1.json", "result-leg2.json"):
            try:
                d = json.load(open(os.path.join(root, f)))
                total += int(d.get("requests", 0) or 0)
            except Exception:
                pass
print(total)
EOF
}
for cell in "${ORDER[@]}"; do
  set -- $cell
  task=$1; rep=$2; h=$3
  used=$(total_requests)
  if [ "$used" -ge "$GLOBAL_CEILING" ]; then
    echo "GLOBAL BUDGET EXHAUSTED at $used/$GLOBAL_CEILING — stopping matrix"
    break
  fi
  if [ "$task" = "T09" ]; then
    python3 docker/m3d-run.py "$task" "$rep" "$h" --leg 1 $FORCE || true
    # leg 2 only if leg 1 recorded an interruption
    if python3 -c "import json; d=json.load(open('$RUNS/$task-R$rep-$h/result-leg1.json')); assert d.get('verdict')=='INTERRUPTED-LEG-DONE'" 2>/dev/null; then
      python3 docker/m3d-run.py "$task" "$rep" "$h" --leg 2 $FORCE || true
    else
      echo "$task R$rep $h: leg1 missing/blocked, skipping leg2"
    fi
  else
    python3 docker/m3d-run.py "$task" "$rep" "$h" $FORCE || true
  fi
done
echo "=== matrix done ==="
python3 - "$RUNS" <<'EOF'
import json, os, sys
from collections import Counter
c = Counter()
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if f in ("result.json", "result-leg2.json"):
            try:
                c[json.load(open(os.path.join(root, f))).get("verdict", "?")] += 1
            except Exception:
                pass
print(dict(c))
EOF
