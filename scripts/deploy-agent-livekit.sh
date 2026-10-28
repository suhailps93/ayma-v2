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
  "GOOGLE_CLOUD_PROJECT=${PROJECT_GCP}"
  "GEMINI_LIVE_USE_DEV_API=true"
  "CONTEXT_OPT_LEVEL=3"
  "CONTEXT_OPT_MEASURE=true"
  "LLM_PROVIDER_VOICE=meta"
  "LLM_PROVIDER_VOICE_MAIN=meta"
  "META_CASCADE_TTS_VOICE_FEMALE=Ashley"
  "META_CASCADE_TTS_VOICE_MALE=Alex"
)

# Secrets pulled from GCP Secret Manager → injected into LiveKit's secret store
# as env vars. Format: "ENV_NAME=secret-manager-name".
SECRET_MAP=(
  "GOOGLE_API_KEY=GOOGLE_API_KEY"
  "META_API_KEY=META_API_KEY"
  "SENTRY_DSN=SENTRY_DSN_AGENT"
  "LK_AGENT_FIRESTORE_SA=LK_AGENT_FIRESTORE_SA"
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
