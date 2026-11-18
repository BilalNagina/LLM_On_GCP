#!/usr/bin/env bash
# Model-swap tests under load (v1 -> v2), run with and without the preStop hook.
#   Run A "naive": old pods have preStop 0s
#   Run B "safe" : old pods have preStop 20s
# HPA is held at 2 replicas so autoscaling does not change capacity mid-test.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p results/raw

wait_rollout() { kubectl -n llm rollout status deploy/llm-server --timeout=600s 2>&1 | grep -v reflector | tail -1; }
wait_job() { kubectl -n llm wait --for=condition=complete --timeout=900s "job/k6-$1" >/dev/null || true
             kubectl -n llm logs "job/k6-$1" > "results/raw/k6-$1.log" 2>&1; }

# deploy.sh re-applies the HPA on every call, so the bounds go through it
# (a one-off kubectl patch here was silently undone in the first run).
export HPA_MIN=2 HPA_MAX=2

run() {  # name prestop
  local name=$1 prestop=$2
  echo "== $name: baseline v1, preStop ${prestop}s"
  bash scripts/deploy.sh v1 "$prestop" >/dev/null; wait_rollout
  bash scripts/loadtest.sh "$name" 4 4m "$MAX_TOKENS" >/dev/null
  sleep 60
  echo "== $name: swapping to v2 at $(date -u +%T)"
  bash scripts/deploy.sh v2 "$prestop" >/dev/null; wait_rollout
  echo "== $name: rollout done at $(date -u +%T)"
  wait_job "$name"
  grep -E "checks_succeeded|checks_failed|http_req_failed|http_req_duration|failed_requests|served_by_version|http_reqs" "results/raw/k6-$name.log" || tail -40 "results/raw/k6-$name.log"
}

# MAX_TOKENS=48 gives ~1-2 s requests (a terminating pod is rarely mid-request);
# MAX_TOKENS=256 gives ~10 s generations, so old pods are reliably busy at SIGTERM.
MAX_TOKENS="${MAX_TOKENS:-48}"
SUFFIX="${SUFFIX:-}"
SAFE_PRESTOP="${SAFE_PRESTOP:-45}"
[ -z "${ONLY_SAFE:-}" ] && run "swap-naive$SUFFIX" 0
run "swap-safe$SUFFIX" "$SAFE_PRESTOP"

kubectl -n llm rollout history deploy/llm-server | tail -6
echo "--- HPA events during this run (should show no rescale) ---"
kubectl -n llm get events --field-selector involvedObject.kind=HorizontalPodAutoscaler \
  --sort-by=.lastTimestamp -o custom-columns=LAST:.lastTimestamp,MSG:.message | tail -4
kubectl -n llm get hpa llm-server
