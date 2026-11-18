#!/usr/bin/env bash
# Writes a kubeconfig for the lab cluster. Uses an exec credential that wraps
# `gcloud auth print-access-token` (pinned to the llm-lab gcloud config), so the
# gke-gcloud-auth-plugin package is not required.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

mkdir -p ~/.kube ~/.local/bin
cat > ~/.local/bin/llm-lab-k8s-token <<'EOF'
#!/usr/bin/env bash
T=$(CLOUDSDK_ACTIVE_CONFIG_NAME=__GCLOUD_CONFIG__ gcloud auth print-access-token)
E=$(date -u -d "+45 min" +%Y-%m-%dT%H:%M:%SZ)
printf '{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"%s","expirationTimestamp":"%s"}}\n' "$T" "$E"
EOF
sed -i "s/__GCLOUD_CONFIG__/$CLOUDSDK_ACTIVE_CONFIG_NAME/" ~/.local/bin/llm-lab-k8s-token
chmod +x ~/.local/bin/llm-lab-k8s-token

ENDPOINT=$(terraform -chdir=terraform output -raw cluster_endpoint)
terraform -chdir=terraform output -raw cluster_ca | base64 -d > ~/.kube/llm-lab-ca.crt

kubectl config set-cluster llm-lab --server="https://$ENDPOINT" \
  --certificate-authority="$HOME/.kube/llm-lab-ca.crt" --embed-certs=true
kubectl config set-credentials llm-lab --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command="$HOME/.local/bin/llm-lab-k8s-token" --exec-interactive-mode=Never
kubectl config set-context llm-lab --cluster=llm-lab --user=llm-lab --namespace=llm
kubectl config use-context llm-lab
kubectl get nodes -o wide
