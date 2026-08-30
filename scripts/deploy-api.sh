#!/usr/bin/env bash
# Deploy the Main API (ayma-api) to Cloud Run. See docs/deploy.md.
#
#   scripts/deploy-api.sh            # code-only redeploy (keeps env + secrets)
#   scripts/deploy-api.sh --full     # also (re)sets every env var and secret mount
set -euo pipefail

PROJECT=ayma-ai
REGION=us-central1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/functions/bootstrap"

ENV_VARS="USE_VERTEX=true,VERTEX_LOCATION=us-central1,GEMINI_MODEL=gemini-2.5-flash,GOOGLE_CLOUD_PROJECT=${PROJECT},LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,STORAGE_BUCKET=${PROJECT}.firebasestorage.app"
SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,CRON_SECRET=CRON_SECRET:latest,ADMIN_PASSWORD=ADMIN_PASSWORD:latest,INSTAGRAM_APP_SECRET=INSTAGRAM_APP_SECRET:latest"

args=(run deploy ayma-api
  --source "$SRC" --region "$REGION" --project "$PROJECT"
  --allow-unauthenticated
  --min-instances 0 --max-instances 4 --cpu 1 --memory 512Mi)

if [[ "${1:-}" == "--full" ]]; then
  args+=(--set-env-vars "$ENV_VARS" --set-secrets "$SECRETS")
fi

exec gcloud "${args[@]}"
