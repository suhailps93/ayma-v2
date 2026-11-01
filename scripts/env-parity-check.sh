#!/usr/bin/env bash
# Environment parity gate — diff two Ayma environments and report capability
# gaps, so a promotion (staging -> main, or vice versa) can never silently ship
# an environment that is missing config another one has. Born from the
# 2026-11-01 miss where ayma-staging had only Email auth while the build offered
# Google/Phone, and from the founder directive "make sure nothing is missing
# like this" when staging is promoted to main.
#
#   scripts/env-parity-check.sh [--from <env>] [--to <env>]
#
# <env> is `prod` or `staging` (default: --from staging --to prod, i.e. "what
# does PROD lack that STAGING has", the promotion direction). It reports, for
# each dimension, what the --from env has that the --to env lacks (and flags
# differing values). READ-ONLY: it changes nothing, it only reports. Exit code
# is non-zero when any gap is found, so it can gate a deploy in CI or a script.
#
# Dimensions compared (same ones the staging audit covered):
#   1. Cloud Run env vars + mounted secrets (api + agent services)
#   2. Enabled GCP services/APIs
#   3. Firebase Auth providers (email/phone/anonymous + federated IdPs)
#   4. Firestore composite indexes
# Quotas and OAuth redirect URIs can't be read uniformly via CLI — it prints a
# manual-check reminder for those rather than guessing.
set -uo pipefail

PROD_PROJECT=ayma-ai
STAGING_PROJECT=ayma-staging
REGION=us-central1
PROD_API=ayma-api;         PROD_AGENT=ayma-agent
STAGING_API=ayma-api-staging; STAGING_AGENT=ayma-agent-staging

FROM=staging; TO=prod
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

resolve() { # env -> "project api_service agent_service"
  case "$1" in
    prod)    echo "$PROD_PROJECT $PROD_API $PROD_AGENT" ;;
    staging) echo "$STAGING_PROJECT $STAGING_API $STAGING_AGENT" ;;
    *) echo "bad env: $1 (use prod|staging)" >&2; exit 2 ;;
  esac
}
read -r FROM_PROJ FROM_API FROM_AGENT < <(resolve "$FROM")
read -r TO_PROJ   TO_API   TO_AGENT   < <(resolve "$TO")
# Cloud Run services for both envs physically live in the ayma-ai GCP project.
RUN_PROJECT=ayma-ai

GAPS=0
note_gap() { GAPS=$((GAPS+1)); echo "  GAP: $*"; }

echo "== env parity: what does '$TO' lack that '$FROM' has =="
echo "   from: $FROM ($FROM_PROJ)   to: $TO ($TO_PROJ)"
echo ""

svc_keys() { # service -> "ENV:name" and "SEC:name" lines
  gcloud run services describe "$1" --project "$RUN_PROJECT" --region "$REGION" \
    --format=json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); c=d['spec']['template']['spec']['containers'][0]
for e in c.get('env',[]):
    print(('ENV:' if 'value' in e else 'SEC:')+e['name'])
"
}

compare_service() {
  local label="$1" from_svc="$2" to_svc="$3"
  echo "-- Cloud Run $label: $to_svc vs $from_svc --"
  local from_keys to_keys
  from_keys="$(svc_keys "$from_svc")"; to_keys="$(svc_keys "$to_svc")"
  # Names present in FROM but missing in TO. Known intentional staging-only
  # keys are never promoted TO prod, so skip them when TO=prod.
  local skip="ENV:LIVEKIT_ROOM_PREFIX ENV:SENTRY_ENVIRONMENT ENV:IMAGE_VARIANTS_ENABLED ENV:IMAGE_VARIANTS_PUSH_SA ENV:OPEN_WEIGHTS_BASE_URL ENV:GEMINI_LIVE_USE_DEV_API ENV:GOOGLE_CLOUD_PROJECT ENV:STORAGE_BUCKET ENV:AYMA_AGENT_URL ENV:GOOGLE_IMPORT_REDIRECT_URI"
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if ! grep -qxF "$k" <<<"$to_keys"; then
      if [[ "$TO" == prod && " $skip " == *" $k "* ]]; then
        echo "  (skip staging-only $k)"
      else
        note_gap "$label missing ${k%%:*} ${k#*:}"
      fi
    fi
  done <<<"$from_keys"
}

compare_service "api"   "$FROM_API"   "$TO_API"
compare_service "agent" "$FROM_AGENT" "$TO_AGENT"

echo ""
echo "-- Enabled GCP services (app-capability only) --"
# Build/deploy infra, Google-Workspace integrations, and Google-internal APIs
# are tied to the GCP project that OWNS the build + workspace connectors
# (ayma-ai), not to a data-plane's app capability — so a difference in these is
# NOT a capability gap. Only the APIs the running app actually calls matter.
INFRA_APIS="cloudbuild.googleapis.com containerregistry.googleapis.com artifactregistry.googleapis.com run.googleapis.com compute.googleapis.com secretmanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com oslogin.googleapis.com cloudasset.googleapis.com cloudaicompanion.googleapis.com geminicloudassist.googleapis.com designcenter.googleapis.com discoveryengine.googleapis.com recommender.googleapis.com fpnv.googleapis.com playdeveloperreporting.googleapis.com firebaseapptesters.googleapis.com firebaseappcheck.googleapis.com cloudscheduler.googleapis.com gmail.googleapis.com calendar-json.googleapis.com photoslibrary.googleapis.com androidpublisher.googleapis.com cloudresourcemanager.googleapis.com cloudtrace.googleapis.com logging.googleapis.com monitoring.googleapis.com clouddebugger.googleapis.com cloudprofiler.googleapis.com"
mapfile -t FROM_SVCS < <(gcloud services list --enabled --project "$FROM_PROJ" --format='value(config.name)' 2>/dev/null | sort)
TO_SVCS="$(gcloud services list --enabled --project "$TO_PROJ" --format='value(config.name)' 2>/dev/null | sort)"
for s in "${FROM_SVCS[@]}"; do
  [[ " $INFRA_APIS " == *" $s "* ]] && continue   # infra/workspace, not a capability
  grep -qxF "$s" <<<"$TO_SVCS" || note_gap "app API not enabled on $TO: $s"
done

echo ""
echo "-- Firebase Auth providers --"
auth_providers() {
  local proj="$1" tok; tok="$(gcloud auth print-access-token 2>/dev/null)"
  curl -s -H "Authorization: Bearer $tok" -H "x-goog-user-project: $proj" \
    "https://identitytoolkit.googleapis.com/admin/v2/projects/$proj/config" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);s=d.get('signIn',{});print('\n'.join(p for p in ('email','phoneNumber','anonymous') if s.get(p,{}).get('enabled')))" 2>/dev/null
  curl -s -H "Authorization: Bearer $tok" -H "x-goog-user-project: $proj" \
    "https://identitytoolkit.googleapis.com/admin/v2/projects/$proj/defaultSupportedIdpConfigs" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('\n'.join(c['name'].split('/')[-1] for c in d.get('defaultSupportedIdpConfigs',[]) if c.get('enabled')))" 2>/dev/null
}
FROM_AUTH="$(auth_providers "$FROM_PROJ")"; TO_AUTH="$(auth_providers "$TO_PROJ")"
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  grep -qxF "$p" <<<"$TO_AUTH" || note_gap "Auth provider not enabled on $TO: $p"
done <<<"$FROM_AUTH"

echo ""
echo "-- Firestore composite indexes --"
idx_sig() {
  firebase firestore:indexes --project "$1" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for i in d.get('indexes',[]):
    fs=tuple((f.get('fieldPath'),f.get('order'),json.dumps(f.get('vectorConfig')) if f.get('vectorConfig') else None) for f in i.get('fields',[]) if f.get('fieldPath')!='__name__')
    print(i.get('collectionGroup'),i.get('queryScope','COLLECTION'),fs)
"
}
FROM_IDX="$(idx_sig "$FROM_PROJ")"; TO_IDX="$(idx_sig "$TO_PROJ")"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  grep -qxF "$line" <<<"$TO_IDX" || note_gap "Firestore index missing on $TO: $line"
done <<<"$FROM_IDX"

echo ""
echo "-- Manual checks (not CLI-readable) --"
echo "  [ ] OAuth client authorized redirect URI for $TO's api /google/oauth-complete"
echo "  [ ] Vertex/Imagen + model quotas in $REGION match between projects"
echo "  [ ] Apple Sign-In key (.p8/KeyID) present if Apple is a provider"

echo ""
if [[ $GAPS -eq 0 ]]; then
  echo "== PARITY OK: '$TO' has every CLI-checkable capability '$FROM' has =="
  exit 0
fi
echo "== $GAPS GAP(S) FOUND — '$TO' is missing capabilities '$FROM' has (see above) =="
exit 1
