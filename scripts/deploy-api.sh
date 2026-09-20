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

# Model ids + their Vertex locations are LOCKED in functions/bootstrap/config.py
# (the "LOCKED MODELS" block) and deliberately NOT set here — one source of truth.
#
# AYMA_AGENT_URL is ayma-agent's own Cloud Run URL — used only to send it a
# "wake" ping when a voice call starts (functions/bootstrap/agent_wake.py),
# since ayma-agent runs min-instances=0 (docs/deploy.md §12.2) and nothing
# else would ever start that container before the client tries to join.
ENV_VARS="USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=${PROJECT},LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,STORAGE_BUCKET=${PROJECT}.firebasestorage.app,AYMA_AGENT_URL=https://ayma-agent-4qy2nxz2aa-uc.a.run.app,GOOGLE_IMPORT_CLIENT_ID=235381544962-3u4bvacg15bhr6sfmr5bqat4p7heu6so.apps.googleusercontent.com,GOOGLE_IMPORT_REDIRECT_URI=https://ayma-api-235381544962.us-central1.run.app/google/oauth-complete"
SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,CRON_SECRET=CRON_SECRET:latest,ADMIN_PASSWORD=ADMIN_PASSWORD:latest,INSTAGRAM_APP_SECRET=INSTAGRAM_APP_SECRET:latest,GOOGLE_IMPORT_CLIENT_SECRET=GOOGLE_IMPORT_CLIENT_SECRET:latest"

args=(run deploy ayma-api
  --source "$SRC" --region "$REGION" --project "$PROJECT"
  --allow-unauthenticated
  --min-instances 0 --max-instances 4 --cpu 1 --memory 512Mi)

if [[ "${1:-}" == "--full" ]]; then
  args+=(--set-env-vars "$ENV_VARS" --set-secrets "$SECRETS")
fi

exec gcloud "${args[@]}"
