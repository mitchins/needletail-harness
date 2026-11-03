#!/bin/bash
# Gemma matched comparison: 12 tasks x 2 reps x 2 harnesses = 48 runs,
# AB/BA ordered (R1: nt,pi per task; R2: pi,nt). Separate from M3-D.
# Resumable; stops on the separate 850-request ceiling (durable
# max(requests, budgetUsed) ledger). Provider-health gated: canary
# triple-probe at start and every 12 cells; stops on DEGRADED.
set -u
RUNS=/tmp/m3d-gemma/runs
GLOBAL_CEILING=850
GEMMA_ID="reinforce20001/gemma4-26b-a4b-it-qat-w4a16-ct"
export M3D_RUNS="$RUNS"
export M3D_NT_IMAGE="m3d-needletail:remediation"
export M3D_CFG="/tmp/m3d-gemma/cfg"
export M3D_PI_PROVIDER="gemma-local"
export M3D_PI_MODEL="$GEMMA_ID"
export M3D_PI_MODELS_DIR="/tmp/m3d-gemma"
CANARY_LOG=/tmp/m3d-gemma/health.log
mkdir -p "$RUNS" "$(dirname "$CANARY_LOG")"

spent() {
  python3 - "$RUNS" <<'EOF'
import json, os, sys
runs = sys.argv[1]
total = 0
for root, _, files in os.walk(runs):
    for f in files:
        if f in ("result.json", "result-leg1.json", "result-leg2.json"):
            try:
                d = json.load(open(os.path.join(root, f)))
                u = int(d.get("requests", 0) or 0)
                b = d.get("budgetUsed")
                total += max(u, b if isinstance(b, int) else u)
            except Exception:
                pass
print(total)
EOF
}

canary() {
  # Frozen protocol: 3 sequential trivial probes; HEALTHY iff all 200,
  # <60s, exact model id, exact CANARY-OK content. Returns 0 when healthy.
  local degraded=0
  for i in 1 2 3; do
    raw=$(curl -s -m 90 -w '\nHTTP=%{http_code} TIME=%{time_total}' \
      http://192.168.1.14:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d "{\"model\":\"$GEMMA_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: CANARY-OK\"}],\"temperature\":0,\"max_tokens\":16}")
    echo "$(date -u +%FT%TZ) canary-$i $(echo "$raw" | tail -c 300)" >> "$CANARY_LOG"
    body=$(echo "$raw" | sed '$d')
    meta=$(echo "$raw" | tail -1)
    id=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('model','?'))" 2>/dev/null || echo "?")
    content=$(echo "$body" | python3 -c "import json,sys; print((json.load(sys.stdin)['choices'][0]['message'] or {}).get('content','?'))" 2>/dev/null || echo "?")
    t=$(echo "$meta" | sed 's/.*TIME=//')
    code=$(echo "$meta" | sed 's/.*HTTP=\([0-9]*\).*/\1/')
    slow=$(python3 -c "print(float('$t') >= 60.0)" 2>/dev/null || echo True)
    if [ "$code" != "200" ] || [ "$slow" = "True" ] || [ "$id" != "$GEMMA_ID" ] || [ "$content" != "CANARY-OK" ]; then
      echo "CANARY DEGRADED probe-$i code=$code time=${t}s id=$id content=$(echo "$content" | head -c 60)"
      degraded=1
    else
      echo "canary-$i healthy (${t}s)"
    fi
  done
  return $degraded
}

echo "=== gemma health gate: initial triple-probe ==="
if ! canary; then
  echo "PROVIDER DEGRADED at start — refusing scored runs (protocol §3)"
  exit 3
fi

declare -a ORDER
for rep in 1 2; do
  if [ "$rep" = "1" ]; then HS="nt pi"; else HS="pi nt"; fi
  for task in T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12; do
    for h in $HS; do ORDER+=("$task $rep $h"); done
  done
done

n=0
for cell in "${ORDER[@]}"; do
  set -- $cell
  task=$1; rep=$2; h=$3
  used=$(spent)
  if [ "$used" -ge "$GLOBAL_CEILING" ]; then
    echo "GLOBAL BUDGET EXHAUSTED at $used/$GLOBAL_CEILING — stopping matrix"
    break
  fi
  n=$((n+1))
  if [ $((n % 12)) -eq 1 ] && [ "$n" -gt 1 ]; then
    echo "=== periodic health gate (cell $n) ==="
    if ! canary; then
      echo "PROVIDER DEGRADED mid-matrix — stopping new scored requests (protocol §3)"
      break
    fi
  fi
  if [ "$task" = "T09" ]; then
    python3 docker/m3d-run.py "$task" "$rep" "$h" --leg 1 || true
    if python3 -c "import json; d=json.load(open('$RUNS/$task-R$rep-$h/result-leg1.json')); assert d.get('verdict')=='INTERRUPTED-LEG-DONE'" 2>/dev/null; then
      python3 docker/m3d-run.py "$task" "$rep" "$h" --leg 2 || true
    else
      echo "$task R$rep $h: leg1 missing/blocked, skipping leg2"
    fi
  else
    python3 docker/m3d-run.py "$task" "$rep" "$h" || true
  fi
done
echo "=== gemma matrix done, spent=$(spent)/850 ==="
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
