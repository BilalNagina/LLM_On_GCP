#!/usr/bin/env bash
# Deterministic check: does llama-server finish an in-flight generation when it
# gets SIGTERM? Starts one long request on a pod, deletes that pod mid-generation.
# Usage: scripts/sigterm-test.sh <prestop_seconds>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
PRESTOP="${1:-0}"

HPA_MIN=2 HPA_MAX=2 bash scripts/deploy.sh v2 "$PRESTOP" >/dev/null
kubectl -n llm rollout status deploy/llm-server --timeout=600s 2>&1 | grep -v reflector | tail -1
POD=$(kubectl -n llm get pod -l app=llm-server,model-version=v2 --field-selector=status.phase=Running -o name | head -1)
echo "target: $POD  preStop=${PRESTOP}s"

kubectl -n llm port-forward "$POD" 18080:8080 >/dev/null 2>&1 &
PF=$!; sleep 3

t0=$(date +%s.%N)
( curl -s -m 150 -o /tmp/sigterm-resp.json -w "%{http_code} %{time_total}\n" \
    http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Write a detailed 600-word explanation of Kubernetes rolling updates."}],"max_tokens":400,"temperature":0.2}' \
    > /tmp/sigterm-curl.txt 2>&1; echo "curl exit $?" >> /tmp/sigterm-curl.txt ) &
CURL=$!
sleep 4
echo "deleting pod at +$(echo "$(date +%s.%N) - $t0" | bc | cut -c1-5)s"
kubectl -n llm delete "$POD" --wait=false >/dev/null
wait $CURL || true
kill $PF 2>/dev/null || true

echo "result: $(cat /tmp/sigterm-curl.txt | tr '\n' ' ')"
python3 - <<'EOF' 2>/dev/null || echo "response: (no complete JSON body)"
import json
r = json.load(open('/tmp/sigterm-resp.json'))
print("response: complete, %d tokens generated, finish_reason=%s"
      % (r["usage"]["completion_tokens"], r["choices"][0]["finish_reason"]))
EOF
