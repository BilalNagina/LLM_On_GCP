#!/usr/bin/env bash
# Usage: scripts/deploy.sh <v1|v2> [prestop_seconds]
# Applies base + gateway, then the llm-server Deployment for the given model version.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
export MODEL_VERSION="${1:?model version, e.g. v1}"
# 45 s = endpoint removal + the longest generation (~25 s p99 at 256 tokens) + margin.
# llama-server stops generating on SIGTERM, so anything still running then is lost.
export PRESTOP_SECONDS="${2:-45}"
# HPA bounds are part of the manifest, so every deploy re-applies them.
# rollout-test.sh sets both to 2 to hold capacity fixed.
export HPA_MIN="${HPA_MIN:-2}" HPA_MAX="${HPA_MAX:-6}"
export REGISTRY=$(terraform -chdir=terraform output -raw registry)
export BUCKET=$(terraform -chdir=terraform output -raw models_bucket)
export LLAMA_IMAGE=$(gcloud storage cat "gs://$BUCKET/import/image-digests.txt" | grep '/llama-cpp-server@sha256:')

kubectl apply -f k8s/00-base.yaml
kubectl apply -f k8s/20-gateway.yaml
kubectl -n llm create configmap k6-scripts --from-file=loadtest/chat.js \
  --dry-run=client -o yaml | kubectl apply -f -
envsubst '${LLAMA_IMAGE} ${BUCKET} ${MODEL_VERSION} ${PRESTOP_SECONDS} ${HPA_MIN} ${HPA_MAX}' < k8s/10-llm-server.yaml \
  | kubectl apply -f -
kubectl -n llm annotate deployment/llm-server kubernetes.io/change-cause="model ${MODEL_VERSION}, preStop ${PRESTOP_SECONDS}s" --overwrite
