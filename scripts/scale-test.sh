#!/usr/bin/env bash
# Autoscaling test: HPA 2..6 on CPU, cluster autoscaler 1..4 spot nodes.
# Drives 12 concurrent users for 6 minutes and samples pods/nodes every 15 s.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p results/raw
OUT=results/scaling.csv

kubectl -n llm patch hpa llm-server --type=merge -p '{"spec":{"minReplicas":2,"maxReplicas":6}}'
bash scripts/loadtest.sh scale 12 6m 48 >/dev/null

echo "elapsed_s,hpa_cpu_pct,desired_pods,ready_pods,pending_pods,nodes" > "$OUT"
start=$(date +%s)
while :; do
  t=$(( $(date +%s) - start ))
  cpu=$(kubectl -n llm get hpa llm-server -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "")
  desired=$(kubectl -n llm get hpa llm-server -o jsonpath='{.status.desiredReplicas}')
  ready=$(kubectl -n llm get deploy llm-server -o jsonpath='{.status.readyReplicas}')
  pending=$(kubectl -n llm get pods -l app=llm-server --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
  nodes=$(kubectl get nodes --no-headers | grep -c " Ready")
  echo "$t,${cpu:-},$desired,${ready:-0},$pending,$nodes" | tee -a "$OUT"
  if kubectl -n llm get job k6-scale -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q True; then break; fi
  [ "$t" -gt 900 ] && break
  sleep 15
done
kubectl -n llm logs job/k6-scale > results/raw/k6-scale.log 2>&1
grep -E "checks_succeeded|checks_failed|http_req_failed|http_req_duration|http_reqs|failed_requests" results/raw/k6-scale.log
