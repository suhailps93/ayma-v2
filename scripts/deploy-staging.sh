#!/usr/bin/env bash
# Deploy the STAGING backend to Cloud Run. Mirrors scripts/deploy-api.sh and
# scripts/deploy-agent.sh (see docs/deploy.md and docs/STAGING.md).
#
#   scripts/deploy-staging.sh [--full] [--firebase-project ID] [--api-only|--agent-only]
#
# Modes (same convention as the prod scripts):
#   (default)  code-only redeploy of both staging services (keeps env + secrets)
#   --full     also (re)sets every env var and secret mount (two-pass: deploys,
#              reads back the assigned Cloud Run URLs, then sets AYMA_AGENT_URL
#              and GOOGLE_IMPORT_REDIRECT_URI which depend on those URLs)
#
# Flags:
#   --firebase-project ID   Firestore/Auth/Storage project the staging services
#                           talk to. UNSET by default = same project as PROD
#                           (ayma-ai): staging then shares prod data — fine for a
#                           smoke test, NOT for destructive testing. A separate
#                           staging Firebase project is preferred; pass its id
#                           here. Sets GOOGLE_CLOUD_PROJECT + STORAGE_BUCKET.
#                           (firebase_admin honors GOOGLE_CLOUD_PROJECT via ADC;
#                           verify on first deploy — see docs/STAGING.md.)
#   --api-only / --agent-only
#                           deploy just one of the two staging services.
#   --check                 pre-flight only: verify every required secret exists
#                           in Secret Manager and print what would be deployed.
#                           Makes no changes. Run this first.
#
# Staging services (same GCP project + region as prod, scale to zero):
#   ayma-api-staging    (--source build, like prod ayma-api)
#   ayma-agent-staging  (Dockerfile.agent image tagged :staging, like prod)
#
# Secrets: staging-only values live in *-staging Secret Manager secrets
# (CRON_SECRET_STAGING, ADMIN_PASSWORD_STAGING, DEV_PANEL_PASSWORD_STAGING,
# REVENUECAT_WEBHOOK_SECRET_STAGING); shared infra secrets (LiveKit, Google
# OAuth client secret, Instagram, agent Gemini key) are re-mounted from the
# existing prod secrets. Sentry is OFF on staging by default (no SENTRY_DSN
# mount) — see docs/STAGING.md to enable it. Full matrix: docs/STAGING.md.
set -euo pipefail

PROJECT=ayma-ai
REGION=us-central1
API_SERVICE=ayma-api-staging
AGENT_SERVICE=ayma-agent-staging
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/functions/bootstrap"
AGENT_IMAGE="us-central1-docker.pkg.dev/${PROJECT}/cloud-run-source-deploy/ayma-agent:staging"

FULL=false
CHECK_ONLY=false
API_ONLY=false
AGENT_ONLY=false
FIREBASE_PROJECT=""

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --api-only) API_ONLY=true; shift ;;
    --agent-only) AGENT_ONLY=true; shift ;;
    --firebase-project)
      [[ $# -ge 2 ]] || { echo "error: --firebase-project needs a value" >&2; exit 2; }
      FIREBASE_PROJECT="$2"; shift 2 ;;
    --firebase-project=*) FIREBASE_PROJECT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if $API_ONLY && $AGENT_ONLY; then
  echo "error: --api-only and --agent-only are mutually exclusive" >&2
  exit 2
fi

# Data plane: default = prod project (shared data); override with the flag.
DATA_PROJECT="${FIREBASE_PROJECT:-$PROJECT}"
STORAGE_BUCKET="${DATA_PROJECT}.firebasestorage.app"

# Model ids + Vertex locations are LOCKED in functions/bootstrap/config.py
# ("LOCKED MODELS" block) — never set here, same as the prod scripts.

# Staging-only values (vs prod): DATA_PROJECT-scoped GOOGLE_CLOUD_PROJECT +
# STORAGE_BUCKET, ayma-staging- LiveKit room prefix, staging Sentry
# environment tag. AYMA_AGENT_URL + GOOGLE_IMPORT_REDIRECT_URI are resolved
# after the first deploy (pass 2) since Cloud Run assigns the URL hashes.
# OPEN_WEIGHTS_BASE_URL wires the Modal-hosted open-weights cheap path (L4 vLLM,
# OpenAI-compatible `/v1`, Llama-3.1-8B under META_OPEN_WEIGHTS_MODEL). Non-secret
# endpoint only — it does NOT route any traffic on its own: a surface reaches it
# solely when its LLM_PROVIDER_* flag is `open-weights` (prod/staging default stays
# gemini), so wiring it here just makes the hackathon surface available behind flags.
OPEN_WEIGHTS_BASE_URL="https://suhailps93--ayma-open-weights-serve.us-east.modal.run/v1"
# DEDICATED staging LiveKit project (wss://ayma-staging-cyofszqr.livekit.cloud /
# p_484u2zjk8ob), NOT prod's (aimma-wt34nu3l / p_4jk3pqz7u9r). This is a hard
# isolation boundary: staging + prod agents are both Cloud Run workers, and the
# dispatch guard only separates cloudrun-vs-livekit-cloud, so on a SHARED LiveKit
# project the prod agent could grab a staging call and write app_commands to prod
# Firestore (voice app-nav silently failed on staging, founder 2026-11-01). A
# separate LiveKit project means the prod agent never sees staging rooms. Key +
# secret are the staging project's, in ayma-ai Secret Manager under the _STAGING
# names (prod's bare LIVEKIT_API_KEY/SECRET are left untouched).
API_ENV_BASE="USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=${DATA_PROJECT},LIVEKIT_URL=wss://ayma-staging-cyofszqr.livekit.cloud,STORAGE_BUCKET=${STORAGE_BUCKET},GOOGLE_IMPORT_CLIENT_ID=235381544962-3u4bvacg15bhr6sfmr5bqat4p7heu6so.apps.googleusercontent.com,CONTEXT_OPT_LEVEL=3,CONTEXT_OPT_MEASURE=true,LIVEKIT_PROJECT_ID=p_484u2zjk8ob,LIVEKIT_ROOM_PREFIX=ayma-staging-,SENTRY_ENVIRONMENT=staging,OPEN_WEIGHTS_BASE_URL=${OPEN_WEIGHTS_BASE_URL}"

# Cloud image variants (Perf Phase 2 PREP chunk A, staging-only): enabled ONLY
# when the staging data plane is the staging Firebase project. A staging
# deploy sharing prod data (no --firebase-project) must never generate
# variants into the prod bucket, so the flag stays unset there (fail closed).
if [[ "$DATA_PROJECT" == "ayma-staging" ]]; then
  API_ENV_BASE="${API_ENV_BASE},IMAGE_VARIANTS_ENABLED=true,IMAGE_VARIANTS_PUSH_SA=pubsub-push-invoker@ayma-staging.iam.gserviceaccount.com"
fi
AGENT_ENV_BASE="LIVEKIT_URL=wss://ayma-staging-cyofszqr.livekit.cloud,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=${DATA_PROJECT},GEMINI_LIVE_USE_DEV_API=true,CONTEXT_OPT_LEVEL=3,CONTEXT_OPT_MEASURE=true,SENTRY_ENVIRONMENT=staging"

# Same env names as prod, staging-only values where it matters — see docs/STAGING.md.
# META_API_KEY: the Meta Model API key (Muse Spark) shared with prod — required
# so the in-app Brain selector's "Meta Muse Spark" option actually reaches Meta
# on staging; without it MetaProvider silently falls back to Gemini (the demo's
# Meta path is the user-driven brain switch, not a default flip — voice stays
# Gemini Live).
API_SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY_STAGING:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET_STAGING:latest,CRON_SECRET=CRON_SECRET_STAGING:latest,ADMIN_PASSWORD=ADMIN_PASSWORD_STAGING:latest,INSTAGRAM_APP_SECRET=INSTAGRAM_APP_SECRET:latest,GOOGLE_IMPORT_CLIENT_SECRET=GOOGLE_IMPORT_CLIENT_SECRET:latest,REVENUECAT_WEBHOOK_SECRET=REVENUECAT_WEBHOOK_SECRET_STAGING:latest,DEV_PANEL_PASSWORD=DEV_PANEL_PASSWORD_STAGING:latest,META_API_KEY=META_API_KEY:latest"
AGENT_SECRETS="LIVEKIT_API_KEY=LIVEKIT_API_KEY_STAGING:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET_STAGING:latest,GOOGLE_API_KEY=GOOGLE_API_KEY:latest"

REQUIRED_STAGING_SECRETS="CRON_SECRET_STAGING ADMIN_PASSWORD_STAGING DEV_PANEL_PASSWORD_STAGING REVENUECAT_WEBHOOK_SECRET_STAGING"
REQUIRED_SHARED_SECRETS="LIVEKIT_API_KEY_STAGING LIVEKIT_API_SECRET_STAGING INSTAGRAM_APP_SECRET GOOGLE_IMPORT_CLIENT_SECRET GOOGLE_API_KEY META_API_KEY"

service_url() {
  gcloud run services describe "$1" --project "$PROJECT" --region "$REGION" \
    --format='value(status.url)'
}

preflight() {
  echo "== pre-flight: staging deploy =="
  echo "gcp project:      $PROJECT"
  echo "region:           $REGION"
  echo "data project:     $DATA_PROJECT"
  if [[ -z "$FIREBASE_PROJECT" ]]; then
    echo "  !! no --firebase-project: staging shares PROD Firestore/Auth/Storage."
    echo "     OK for a smoke test; create a staging Firebase project before any"
    echo "     destructive testing (docs/STAGING.md)."
  fi
  echo "api service:      $API_SERVICE"
  echo "agent service:    $AGENT_SERVICE (image tag: staging)"
  echo "mode:             $(if $FULL; then echo full; else echo code-only; fi)"
  echo ""
  echo "-- required Secret Manager secrets --"
  local missing=0 s
  for s in $REQUIRED_STAGING_SECRETS $REQUIRED_SHARED_SECRETS; do
    if gcloud secrets describe "$s" --project "$PROJECT" >/dev/null 2>&1; then
      echo "  ok:      $s"
    else
      echo "  MISSING: $s"
      missing=1
    fi
  done
  if [[ -n "$FIREBASE_PROJECT" ]]; then
    echo ""
    echo "-- separate data project ($DATA_PROJECT): also verify manually --"
    echo "  [ ] staging project exists with Firestore + Storage provisioned"
    echo "  [ ] firestore rules/indexes deployed to it"
    echo "    (firebase deploy --only firestore:rules,firestore:indexes --project $DATA_PROJECT)"
    echo "  [ ] Cloud Run runtime service account has datastore + storage access in it"
  fi
  echo ""
  echo "-- manual pre-flight (see handoff note) --"
  echo "  [ ] secretAccessor IAM grants for any NEW staging secret (script fails the"
  echo "      revision otherwise — same rule as prod, docs/deploy.md §Secrets)"
  echo "  [ ] GOOGLE_IMPORT_REDIRECT_URI for the staging API URL registered as an"
  echo "      authorized redirect URI on the Google OAuth client (pass 2 prints it)"
  echo "  [ ] no Cloud Scheduler jobs point at staging (staging cron stays manual)"
  if [[ $missing -ne 0 ]]; then
    echo ""
    echo "pre-flight FAILED: create the MISSING secrets first (docs/STAGING.md)."
    return 1
  fi
  echo ""
  echo "pre-flight passed."
}

deploy_api() {
  local args=(run deploy "$API_SERVICE"
    --source "$SRC" --region "$REGION" --project "$PROJECT"
    --allow-unauthenticated
    --min-instances 0 --max-instances 4 --cpu 1 --memory 512Mi)
  if $FULL; then
    # URL-dependent vars are set in pass 2 (update), after the URL exists.
    args+=(--set-env-vars "$API_ENV_BASE" --set-secrets "$API_SECRETS")
  fi
  echo ">> deploying $API_SERVICE"
  gcloud "${args[@]}"
}

deploy_agent() {
  echo ">> building agent image ($AGENT_IMAGE)"
  ( cd "$SRC" && gcloud builds submit --project "$PROJECT" \
      --config cloudbuild.agent.yaml \
      --substitutions "_IMAGE=${AGENT_IMAGE}" . )
  local args=(run deploy "$AGENT_SERVICE"
    --project "$PROJECT" --region "$REGION" --image "$AGENT_IMAGE"
    --no-allow-unauthenticated
    --min-instances 0 --max-instances 20
    --no-cpu-throttling --cpu-boost --memory 2Gi
    --timeout 3600)
  if $FULL; then
    # AYMA_AGENT_URL (own URL) is set in pass 2, after the URL exists.
    args+=(--set-env-vars "$AGENT_ENV_BASE" --set-secrets "$AGENT_SECRETS")
  fi
  echo ">> deploying $AGENT_SERVICE (min-instances=0, scale-to-zero like prod)"
  gcloud "${args[@]}"
}

if $CHECK_ONLY; then
  preflight
  exit $?
fi

# Always pre-flight first; abort before deploying anything if secrets are missing.
preflight || exit 1

if ! $AGENT_ONLY; then
  deploy_api
fi
if ! $API_ONLY; then
  deploy_agent
fi

if $FULL && ! $API_ONLY && ! $AGENT_ONLY; then
  echo ">> pass 2: wiring staging service URLs"
  AGENT_URL="$(service_url "$AGENT_SERVICE")"
  API_URL="$(service_url "$API_SERVICE")"
  echo "   agent: $AGENT_URL"
  echo "   api:   $API_URL"
  gcloud run services update "$API_SERVICE" --project "$PROJECT" --region "$REGION" \
    --update-env-vars "AYMA_AGENT_URL=${AGENT_URL},GOOGLE_IMPORT_REDIRECT_URI=${API_URL}/google/oauth-complete"
  gcloud run services update "$AGENT_SERVICE" --project "$PROJECT" --region "$REGION" \
    --update-env-vars "AYMA_AGENT_URL=${AGENT_URL}"
  echo ""
  echo "ACTION REQUIRED: register this redirect URI on the Google OAuth client:"
  echo "  ${API_URL}/google/oauth-complete"
elif $FULL; then
  echo ""
  echo "NOTE: single-service --full deploy — cross-service URLs not rewired."
  echo "Run a full both-services --full deploy (or copy AYMA_AGENT_URL /"
  echo "GOOGLE_IMPORT_REDIRECT_URI from the other staging service) to finish."
fi

echo "== staging deploy done =="
