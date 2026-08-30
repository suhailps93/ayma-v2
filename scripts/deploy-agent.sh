#!/usr/bin/env bash
# Build + deploy the LiveKit voice agent worker (ayma-agent). See docs/agent.md.
#
#   scripts/deploy-agent.sh          # build the image, then deploy code-only
#   scripts/deploy-agent.sh --full   # also (re)set env vars + secret mounts
#   scripts/deploy-agent.sh --release # --full AND flip to min-instances 1 (Step 72)
set -euo pipefail

PROJECT=ayma-ai
REGION=us-central1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/functions/bootstrap"
IMAGE="us-central1-docker.pkg.dev/${PROJECT}/cloud-run-source-deploy/ayma-agent:latest"

# The Live model id + voice + its Vertex location are LOCKED in
# functions/bootstrap/config.py ("LOCKED MODELS" block) — not set here.
#
# GEMINI_LIVE_USE_DEV_API=true routes voice to the Gemini Developer API so it
# can run gemini-3.1-flash-live-preview (Vertex tops out at Live 2.5). That
# path needs an API key: GOOGLE_API_KEY is mounted from Secret Manager below,
# never a plaintext value here. Text / matching / embeddings stay keyless on
# Vertex (Main API is unaffected). Set to false to fall back to Vertex
# gemini-live-2.5-flash-native-audio.
ENV_VARS="LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=${PROJECT},GEMINI_LIVE_USE_DEV_API=true"
SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,GOOGLE_API_KEY=GOOGLE_API_KEY:latest"

MIN_INSTANCES=0
mode="${1:-}"
[[ "$mode" == "--release" ]] && MIN_INSTANCES=1

echo ">> building agent image"
( cd "$SRC" && gcloud builds submit --project "$PROJECT" --config cloudbuild.agent.yaml . )

args=(run deploy ayma-agent
  --project "$PROJECT" --region "$REGION" --image "$IMAGE"
  --no-allow-unauthenticated
  --min-instances "$MIN_INSTANCES" --max-instances 20
  --no-cpu-throttling --memory 2Gi)

if [[ "$mode" == "--full" || "$mode" == "--release" ]]; then
  args+=(--set-env-vars "$ENV_VARS" --set-secrets "$SECRETS")
fi

echo ">> deploying ayma-agent (min-instances=$MIN_INSTANCES)"
exec gcloud "${args[@]}"
