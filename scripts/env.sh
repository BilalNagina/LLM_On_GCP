# Source this in WSL/Linux:  source scripts/env.sh
# Pins every gcloud / terraform / kubectl call to one gcloud configuration + project.
#   PROJECT_ID                    your lab project (or put it in ~/.llm-lab-project)
#   CLOUDSDK_ACTIVE_CONFIG_NAME   gcloud configuration to use (default: llm-lab)
export CLOUDSDK_ACTIVE_CONFIG_NAME="${CLOUDSDK_ACTIVE_CONFIG_NAME:-llm-lab}"
export PROJECT_ID="${PROJECT_ID:-$(cat ~/.llm-lab-project 2>/dev/null)}"
[ -n "$PROJECT_ID" ] || { echo "set PROJECT_ID (or write it to ~/.llm-lab-project)" >&2; return 1 2>/dev/null || exit 1; }
export REGION=us-central1
export ZONE=us-central1-a
export TF_VAR_project_id="$PROJECT_ID"
# Terraform authenticates with this configuration's short-lived token, not ADC.
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
export KUBECONFIG="$HOME/.kube/llm-lab.yaml"
export PATH="$HOME/.local/bin:$PATH"
