#!/usr/bin/env bash
# Build + deploy the LiveKit voice agent worker (ayma-agent). See docs/deploy.md.
#
#   scripts/deploy-agent.sh          # build the image, then deploy code-only
#   scripts/deploy-agent.sh --full   # also (re)set env vars + secret mounts
#   scripts/deploy-agent.sh --release # alias for --full, kept for muscle memory
#                                       (see the min-instances note below — it
#                                       no longer flips anything)
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
# can run gemini-3.8-live (Vertex tops out at Live 2.5). That
# path needs an API key: GOOGLE_API_KEY is mounted from Secret Manager below,
# never a plaintext value here. Text / matching / embeddings stay keyless on
# Vertex (Main API is unaffected). Set to false to fall back to Vertex
# gemini-live-2.5-flash-native-audio.
#
# AYMA_AGENT_URL is this service's own URL: each active call holds a
# keep-alive request open against it (agent_keepalive.py) so Cloud Run does
# not scale the instance down mid-call.
ENV_VARS="LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,AYMA_AGENT_URL=https://ayma-agent-4qy2nxz2aa-uc.a.run.app,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=${PROJECT},GEMINI_LIVE_USE_DEV_API=true,CONTEXT_OPT_LEVEL=3,CONTEXT_OPT_MEASURE=true,LLM_PROVIDER_VOICE=meta,LLM_PROVIDER_VOICE_MAIN=meta"
SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,GOOGLE_API_KEY=GOOGLE_API_KEY:latest,SENTRY_DSN=SENTRY_DSN_AGENT:latest,META_API_KEY=META_API_KEY:latest"

# min-instances=0 is the PERMANENT intended config (founder decision,
# 2026-09-19, docs/deploy.md §12.2) — ayma-agent scales to zero when idle
# instead of holding 1 vCPU + 2GB warm 24/7 (~$75/mo of idle compute). This
# reverses the earlier "Step 72 pre-release flip" to min-instances=1: that
# flip existed only because nothing ever woke the container for an incoming
# voice call, so scale-to-zero silently meant "voice is broken" until the
# next manual redeploy (see the "ayma-agent needs --release" incident,
# 2026-09-13). The actual fix for that is main.py's /bootstrap and
# /welcome/token now firing an authenticated wake ping at this service's own
# URL the moment a call starts (functions/bootstrap/agent_wake.py) — Cloud
# Run only cold-starts a container in response to inbound HTTP traffic
# hitting its own URL, which nothing in the LiveKit room-creation flow did
# before. The client shows a "Waking Ayma…" state and tolerates the extra
# join latency (VoiceSessionController._wakingTimeout, ~25s).
#
# Do NOT hardcode min-instances back to 1 here "to be safe" — that silently
# reintroduces the exact idle cost this change removes. If a cold start ever
# starts failing again, fix the wake ping / client timeout, don't paper over
# it by going warm again.
MIN_INSTANCES=0
mode="${1:-}"

echo ">> building agent image"
( cd "$SRC" && gcloud builds submit --project "$PROJECT" --config cloudbuild.agent.yaml . )

args=(run deploy ayma-agent
  --project "$PROJECT" --region "$REGION" --image "$IMAGE"
  --no-allow-unauthenticated
  --min-instances "$MIN_INSTANCES" --max-instances 20
  # --no-cpu-throttling stays ON even at min-instances=0: once an instance IS
  # running (cold-started or not), the LiveKit worker's audio processing
  # happens in a background asyncio task outside any single HTTP
  # request/response cycle, and a throttled instance never finishes LiveKit
  # worker registration (confirmed Step 13) — this flag is about real-time
  # work *within* a running instance's lifetime, orthogonal to min-instances.
  # --cpu-boost speeds up exactly the cold-start path scale-to-zero now
  # depends on (extra CPU during container startup / import / first
  # LiveKit-registration handshake).
  --no-cpu-throttling --cpu-boost --memory 2Gi
  # Each call's keep-alive request (agent_keepalive.py) lasts as long as the
  # call; the 300 s default would cut it every 5 minutes. The client reopens
  # a hold that ends mid-call, so calls past 60 min stay covered. Free.
  --timeout 3600)

if [[ "$mode" == "--full" || "$mode" == "--release" ]]; then
  args+=(--set-env-vars "$ENV_VARS" --set-secrets "$SECRETS")
fi

echo ">> deploying ayma-agent (min-instances=$MIN_INSTANCES, scale-to-zero intended)"
exec gcloud "${args[@]}"
