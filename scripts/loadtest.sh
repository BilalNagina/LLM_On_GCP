#!/usr/bin/env bash
# Usage: scripts/loadtest.sh <run_id> [vus] [duration] [max_tokens]
# Starts an in-cluster k6 Job; logs land in results/raw/k6-<run_id>.log when done.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export RUN_ID="${1:?run id}" VUS="${2:-4}" DURATION="${3:-4m}" MAX_TOKENS="${4:-48}"
export NO_REUSE="${NO_REUSE:-0}"
export REGISTRY=$(terraform -chdir=terraform output -raw registry)
mkdir -p results/raw
kubectl -n llm delete job "k6-$RUN_ID" --ignore-not-found
envsubst '${REGISTRY} ${RUN_ID} ${VUS} ${DURATION} ${MAX_TOKENS} ${NO_REUSE}' < k8s/30-k6-job.yaml | kubectl apply -f -
