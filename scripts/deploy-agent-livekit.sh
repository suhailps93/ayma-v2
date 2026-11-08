#!/usr/bin/env bash
# Build + deploy the Ayma voice agent worker (agent.py) to LiveKit Cloud Agents.
# The Cloud Run twin (scripts/deploy-agent.sh) stays the production default; this
# is the flagged, opt-in deployment reached when a user's `voice_agent_cloud`
# pref is "livekit" (ARCHITECTURE §1.1). See docs/LIVEKIT_AGENT_MIGRATION.md.
#
#   scripts/deploy-agent-livekit.sh create   # first time: create the agent
#   scripts/deploy-agent-livekit.sh deploy   # subsequent: deploy a new version
#   scripts/deploy-agent-livekit.sh update-secrets   # rotate secrets only
#
# Target environment: prod by default. For the STAGING agent
# (ayma-lk-stg, which must write to the ayma-staging Firestore):
#
#   AGENT_TARGET_ENV=staging scripts/deploy-agent-livekit.sh update-secrets
#
# Staging flips GOOGLE_CLOUD_PROJECT to ayma-staging, reads the Firestore SA
# key from Secret Manager secret LK_AGENT_FIRESTORE_SA_STAGING (a key for
# lk-agent-firestore@ayma-staging), and sets AGENT_NAME_LIVEKIT /
# LIVEKIT_ROOM_PREFIX / SENTRY_ENVIRONMENT to their staging values. Secret
# Manager reads themselves always stay on project ayma-ai (both SA keys and
# the LiveKit keys live there). With AGENT_TARGET_ENV unset the prod values
# below are byte-identical to the original hardcoded ones.
#
# Requires: a recent `lk` CLI (>= 2.19 — LiveKit Cloud Agents rejects older
# CLIs with a "version header is required" error; set LK_BIN to point at it),
# `gcloud` with Secret Manager read on project ayma-ai, Docker (the build runs
# on LiveKit's side from the uploaded context), and the least-privilege
# Firestore SA key stored in Secret Manager as LK_AGENT_FIRESTORE_SA.
#
# Auth is by the project LIVEKIT_API_KEY / LIVEKIT_API_SECRET (from Secret
# Manager) — no interactive `lk cloud auth` browser session needed. See
# docs/LIVEKIT_AGENT_MIGRATION.md.
#
# NEVER prints secret values. The secrets file is a 600-perm tempfile, removed
# on exit.
set -euo pipefail

PROJECT_GCP=ayma-ai

# Per-environment agent target. Prod defaults reproduce the original
# hardcoded values exactly; AGENT_TARGET_ENV=staging overrides them.
AGENT_TARGET_ENV="${AGENT_TARGET_ENV:-prod}"
if [[ "$AGENT_TARGET_ENV" == "staging" ]]; then
  TARGET_FIRESTORE_PROJECT="${TARGET_FIRESTORE_PROJECT:-ayma-staging}"
  TARGET_SA_SECRET="${TARGET_SA_SECRET:-LK_AGENT_FIRESTORE_SA_STAGING}"
  TARGET_AGENT_NAME="${TARGET_AGENT_NAME:-ayma-lk-stg}"
  TARGET_ROOM_PREFIX="${TARGET_ROOM_PREFIX:-ayma-staging-}"
  TARGET_SENTRY_ENV="${TARGET_SENTRY_ENV:-staging}"
else
  TARGET_FIRESTORE_PROJECT="${TARGET_FIRESTORE_PROJECT:-ayma-ai}"
  TARGET_SA_SECRET="${TARGET_SA_SECRET:-LK_AGENT_FIRESTORE_SA}"
  TARGET_AGENT_NAME="${TARGET_AGENT_NAME:-ayma-lk}"
  TARGET_ROOM_PREFIX="${TARGET_ROOM_PREFIX:-ayma-}"
  TARGET_SENTRY_ENV="${TARGET_SENTRY_ENV:-production}"
fi
LK_URL="wss://aimma-wt34nu3l.livekit.cloud"
# LiveKit Cloud Agents region (available: us-east me-central eu-central
# ap-south). us-east is closest to our us-central1 Firestore/Vertex.
LK_REGION="${LK_REGION:-us-east}"
LK_BIN="${LK_BIN:-lk}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/functions/bootstrap"

mode="${1:-deploy}"

LK_KEY="$(gcloud secrets versions access latest --secret LIVEKIT_API_KEY \
  --project "$PROJECT_GCP" 2>/dev/null)"
LK_SECRET="$(gcloud secrets versions access latest --secret LIVEKIT_API_SECRET \
  --project "$PROJECT_GCP" 2>/dev/null)"
if [[ -z "$LK_KEY" || -z "$LK_SECRET" ]]; then
  echo "!! could not read LIVEKIT_API_KEY / LIVEKIT_API_SECRET from Secret Manager" >&2
  exit 1
fi
LK_AUTH=(--url "$LK_URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET")

# Non-secret runtime config, mirrored from scripts/deploy-agent.sh ENV_VARS
# (minus the Cloud-Run-only AYMA_AGENT_URL / LIVEKIT_URL — LiveKit injects
# LIVEKIT_URL/KEY/SECRET itself; AGENT_RUNTIME=livekit is baked into the image).
NONSECRET_ENV=(
  "USE_VERTEX=true"
  "VERTEX_LOCATION=us-central1"
  "GOOGLE_CLOUD_PROJECT=${TARGET_FIRESTORE_PROJECT}"
  "GEMINI_LIVE_USE_DEV_API=true"
  "CONTEXT_OPT_LEVEL=3"
  "CONTEXT_OPT_MEASURE=true"
  # Gemini is the default everywhere (founder rule). The signed-in main voice
  # runs on the LOCKED Gemini Live RealtimeModel (config.py), so both the main
  # and the per-surface secondary voice provider are pinned to gemini — mirror
  # of the Cloud Run twin (scripts/deploy-agent.sh).
  "LLM_PROVIDER_VOICE=gemini"
  "LLM_PROVIDER_VOICE_MAIN=gemini"
  "VOICE_CREDITED_PROVIDERS=inworld,deepgram,fishaudio,assemblyai,rime,gradium,google,elevenlabs,openai,cartesia"
  # No TTS model/voice ids here (AGENTS.md): the default TTS (fishaudio/s2.1-pro,
  # voice Hannah) and the gender-matched voices (Hannah/Adrian) are the committed
  # config.py defaults — the single source of truth.
)

# Prod relies on the config.py defaults for these three (ayma-lk / ayma- /
# production), so they are only sent for staging, whose values differ.
if [[ "$AGENT_TARGET_ENV" == "staging" ]]; then
  NONSECRET_ENV+=(
    "AGENT_NAME_LIVEKIT=${TARGET_AGENT_NAME}"
    "LIVEKIT_ROOM_PREFIX=${TARGET_ROOM_PREFIX}"
    "SENTRY_ENVIRONMENT=${TARGET_SENTRY_ENV}"
    # Staging only (founder orders 2026-11-07): only LiveKit-credit
    # inference may be offered or served — Meta Muse Spark bills the card
    # directly, so the credited brain set is the LiveKit Inference set
    # (Gemini + the LiveKit-wired vendors). Prod is NOT pinned (its config
    # default additionally keeps meta/open-weights).
    "BRAIN_CREDITED_PROVIDERS=gemini,gemma,openai,openai-chat,openai-oss,kimi,deepseek,grok"
  )
fi

# Secrets pulled from GCP Secret Manager → injected into LiveKit's secret store
# as env vars. Format: "ENV_NAME=secret-manager-name".
SECRET_MAP=(
  "GOOGLE_API_KEY=GOOGLE_API_KEY"
  "META_API_KEY=META_API_KEY"
  "CARTESIA_API_KEY=CARTESIA_API_KEY"
  "SENTRY_DSN=SENTRY_DSN_AGENT"
  "LK_AGENT_FIRESTORE_SA=${TARGET_SA_SECRET}"
)

echo ">> staging build context (Dockerfile.livekit -> Dockerfile)"
STAGE="$(mktemp -d)"
SECRETS_FILE="$(mktemp)"
chmod 600 "$SECRETS_FILE"
cleanup() { rm -rf "$STAGE" "$SECRETS_FILE"; }
trap cleanup EXIT

rsync -a --delete \
  --exclude '__pycache__/' --exclude '*.pyc' --exclude '.pytest_cache/' \
  --exclude '.venv/' --exclude '.venv-agent/' --exclude 'venv/' \
  --exclude 'tests/' --exclude '.env' --exclude '.env.local' \
  "$SRC"/ "$STAGE"/
cp "$SRC/Dockerfile.livekit" "$STAGE/Dockerfile"
cp "$SRC/livekit.toml" "$STAGE/livekit.toml"
# `lk agent` validates that the project declares livekit-agents by scanning
# requirements.txt — in staging that file is the Main API's (no agent runtime).
# The agent image is self-contained on requirements-agent.txt, so make the
# staging requirements.txt the agent closure for both the check and the build.
cp "$SRC/requirements-agent.txt" "$STAGE/requirements.txt"

echo ">> collecting secrets from Secret Manager (values never printed)"
for pair in "${NONSECRET_ENV[@]}"; do
  echo "$pair" >> "$SECRETS_FILE"
done
for pair in "${SECRET_MAP[@]}"; do
  env_name="${pair%%=*}"
  sm_name="${pair#*=}"
  val="$(gcloud secrets versions access latest \
    --secret "$sm_name" --project "$PROJECT_GCP" 2>/dev/null || true)"
  if [[ -z "$val" ]]; then
    echo "!! missing Secret Manager secret: $sm_name (skipping $env_name)" >&2
    continue
  fi
  if [[ "$env_name" == "LK_AGENT_FIRESTORE_SA" ]]; then
    # Compact the SA key JSON to ONE line — the secrets file is KEY=VALUE per
    # line and db.py json.loads() a single-line value fine.
    val="$(printf '%s' "$val" | tr -d '\n' | sed 's/  */ /g')"
  fi
  printf '%s=%s\n' "$env_name" "$val" >> "$SECRETS_FILE"
done

cd "$STAGE"
case "$mode" in
  create)
    echo ">> lk agent create ($LK_URL, region $LK_REGION)"
    exec "$LK_BIN" agent create "${LK_AUTH[@]}" --region "$LK_REGION" \
      --secrets-file "$SECRETS_FILE" --silent "$STAGE"
    ;;
  deploy)
    echo ">> lk agent deploy ($LK_URL)"
    exec "$LK_BIN" agent deploy "${LK_AUTH[@]}" \
      --secrets-file "$SECRETS_FILE" "$STAGE"
    ;;
  update-secrets)
    echo ">> lk agent update-secrets ($LK_URL)"
    exec "$LK_BIN" agent update-secrets "${LK_AUTH[@]}" \
      --secrets-file "$SECRETS_FILE" "$STAGE"
    ;;
  *)
    echo "usage: $0 {create|deploy|update-secrets}" >&2
    exit 2
    ;;
esac
