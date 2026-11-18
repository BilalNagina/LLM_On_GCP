#!/usr/bin/env bash
# Runs the controlled import (images + checksum-verified model files) in Cloud Build.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
REGISTRY=$(terraform -chdir=terraform output -raw registry)
BUCKET=$(terraform -chdir=terraform output -raw models_bucket)
MIRROR_SA=$(terraform -chdir=terraform output -raw mirror_sa)

gcloud builds submit --no-source \
  --config import/cloudbuild-import.yaml \
  --region "$REGION" \
  --service-account "projects/$PROJECT_ID/serviceAccounts/$MIRROR_SA" \
  --substitutions "_REGISTRY=$REGISTRY,_BUCKET=$BUCKET"

gcloud storage cat "gs://$BUCKET/import/image-digests.txt"
