#!/usr/bin/env bash
# Tears the lab down in the right order:
#  1. delete the Gateway/Service so GKE removes the load balancer and NEGs it created
#     (Terraform doesn't own them, and they would block deleting the VPC)
#  2. terraform destroy
#  3. check nothing billable is left
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

kubectl -n llm delete gateway llm-gateway --ignore-not-found --wait=true || true
kubectl -n llm delete service llm-server --ignore-not-found --wait=true || true
echo "waiting for GKE to remove load balancer + NEGs..."
for i in $(seq 1 40); do
  n=$(gcloud compute network-endpoint-groups list --format="value(name)" 2>/dev/null | wc -l)
  f=$(gcloud compute forwarding-rules list --format="value(name)" 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && [ "$f" -eq 0 ] && break
  sleep 15
done

terraform -chdir=terraform destroy -input=false -auto-approve

echo "--- leftovers (should all be empty) ---"
gcloud compute instances list
gcloud compute disks list
gcloud compute forwarding-rules list
gcloud compute addresses list
gcloud compute network-endpoint-groups list
