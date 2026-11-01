#!/usr/bin/env bash
#
# sync-prod-to-staging.sh — STRICTLY ONE-WAY data copy: PRODUCTION -> STAGING.
#
# Copies a full 1:1 snapshot of prod (ayma-ai) into staging (ayma-staging):
#   1. FIRESTORE  — gcloud export (reads prod) -> gcloud import (writes staging)
#   2. STORAGE    — gsutil rsync  (prod SOURCE) -> (staging DEST), additive
#   3. AUTH USERS — firebase auth:export (prod) -> auth:import (staging) with
#                   prod's SCRYPT hash params so real passwords keep working
#
# ============================  IRONCLAD GUARDRAILS  ===========================
# This pipeline is ONE-WAY, prod -> staging, ONLY. It NEVER runs an import /
# write / rsync whose TARGET is ayma-ai or gs://ayma-ai*. The only prod
# operations are read-only: `firestore export`, `gsutil rsync` with prod as
# SOURCE, and `auth:export`. Every run echoes the resolved SOURCE and DEST and
# aborts if DEST is anything other than ayma-staging. See docs/STAGING.md.
#
# PRIVACY: this intentionally replicates real-user PII + biometric data into
# staging, per founder decision 2026-11-01. See docs/STAGING.md.
# =============================================================================
#
# Usage:
#   scripts/sync-prod-to-staging.sh                 # DRY-RUN (default; no writes)
#   scripts/sync-prod-to-staging.sh --dry-run       # explicit dry-run
#   scripts/sync-prod-to-staging.sh --execute       # perform the real sync
#   scripts/sync-prod-to-staging.sh --execute --skip-storage   # skip one plane
#       (also: --skip-firestore, --skip-auth)
#
# Idempotent and safe to re-run (nightly cron). Firestore import is
# overwrite-by-document-path (additive); storage rsync is additive (no -d, so
# staging-only objects such as demo assets are preserved); auth import upserts
# by uid. Run results are appended to ~/workspace/ayma-inbox/prod-sync.log.

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants — the ONLY source/target projects & buckets this script may touch.
# ----------------------------------------------------------------------------
readonly SRC_PROJECT="ayma-ai"            # PROD  — READ-ONLY here
readonly DEST_PROJECT="ayma-staging"      # STAGING — the ONLY write target
readonly SRC_BUCKET="gs://ayma-ai.firebasestorage.app"
readonly DEST_BUCKET="gs://ayma-staging.firebasestorage.app"
# Dedicated, staging-OWNED export bucket so prod's Firestore export lands in a
# staging location (never a prod bucket).
readonly EXPORT_BUCKET="gs://ayma-staging-prod-sync"
readonly EXPORT_BUCKET_NAME="ayma-staging-prod-sync"
readonly REGION="us-central1"
readonly SRC_PROJECT_NUM="235381544962"
readonly DEST_PROJECT_NUM="187469876115"
# Firestore managed export/import service agents.
readonly SRC_FS_SA="service-${SRC_PROJECT_NUM}@gcp-sa-firestore.iam.gserviceaccount.com"
readonly DEST_FS_SA="service-${DEST_PROJECT_NUM}@gcp-sa-firestore.iam.gserviceaccount.com"

readonly LOG_FILE="${HOME}/workspace/ayma-inbox/prod-sync.log"
readonly TS="$(date -u +%Y%m%dT%H%M%SZ)"
readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prod-sync.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

MODE="dry-run"
DO_FIRESTORE=true
DO_STORAGE=true
DO_AUTH=true

for arg in "$@"; do
  case "$arg" in
    --dry-run)        MODE="dry-run" ;;
    --execute)        MODE="execute" ;;
    --skip-firestore) DO_FIRESTORE=false ;;
    --skip-storage)   DO_STORAGE=false ;;
    --skip-auth)      DO_AUTH=false ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "usage: $0 [--dry-run|--execute] [--skip-firestore] [--skip-storage] [--skip-auth]" >&2
      exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Logging helpers — everything is tee'd to the run log.
# ----------------------------------------------------------------------------
log() { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }
die() { echo "[$(date -u +%H:%M:%SZ)] FATAL: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ----------------------------------------------------------------------------
# GUARD — refuse to run if any write/import/dest target resolves to prod.
# Called at startup AND immediately before every destructive gcloud/gsutil/
# firebase invocation, with the actual target string it is about to use.
# ----------------------------------------------------------------------------
assert_dest_is_staging() {
  local label="$1" target="$2"
  case "$target" in
    *ayma-ai*)
      die "GUARDRAIL TRIPPED — write target for '${label}' resolves to PROD: '${target}'. ABORTING. This pipeline writes ONLY to ayma-staging." ;;
  esac
  case "$target" in
    *ayma-staging*) : ;;  # ok
    *)
      die "GUARDRAIL — write target for '${label}' ('${target}') does not resolve to ayma-staging. ABORTING." ;;
  esac
}

guard_startup() {
  [[ "$DEST_PROJECT" == "ayma-staging" ]] || die "DEST_PROJECT is '${DEST_PROJECT}', not ayma-staging. ABORTING."
  [[ "$SRC_PROJECT"  == "ayma-ai" ]]      || die "SRC_PROJECT is '${SRC_PROJECT}', not ayma-ai. ABORTING."
  # Confirm no dest/export target points at prod.
  assert_dest_is_staging "DEST_BUCKET"   "$DEST_BUCKET"
  assert_dest_is_staging "EXPORT_BUCKET" "$EXPORT_BUCKET"
  assert_dest_is_staging "DEST_PROJECT"  "$DEST_PROJECT"
}

# ----------------------------------------------------------------------------
# Ensure the staging-owned export bucket exists and both Firestore service
# agents can use it. Idempotent. (Writes are to the STAGING bucket's IAM only.)
# ----------------------------------------------------------------------------
ensure_export_bucket() {
  if gsutil ls -b -p "$DEST_PROJECT" "$EXPORT_BUCKET" >/dev/null 2>&1; then
    log "  export bucket ${EXPORT_BUCKET} exists"
  else
    if [[ "$MODE" == "dry-run" ]]; then
      log "  [dry-run] would create: gsutil mb -p ${DEST_PROJECT} -l ${REGION} -b on ${EXPORT_BUCKET}"
    else
      assert_dest_is_staging "create export bucket" "$EXPORT_BUCKET"
      log "  creating export bucket ${EXPORT_BUCKET} in ${DEST_PROJECT}/${REGION}"
      gsutil mb -p "$DEST_PROJECT" -l "$REGION" -b on "$EXPORT_BUCKET"
      # 14-day lifecycle so stale export snapshots self-clean.
      printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":14}}]}' > "${WORK_DIR}/lifecycle.json"
      gsutil lifecycle set "${WORK_DIR}/lifecycle.json" "$EXPORT_BUCKET"
    fi
  fi
  # Grant both Firestore service agents access to the staging export bucket.
  # prod's agent WRITES the export here; staging's agent READS it to import.
  local sa
  for sa in "$SRC_FS_SA" "$DEST_FS_SA"; do
    if [[ "$MODE" == "dry-run" ]]; then
      log "  [dry-run] would grant roles/storage.admin on ${EXPORT_BUCKET} to ${sa}"
    else
      assert_dest_is_staging "grant IAM on export bucket" "$EXPORT_BUCKET"
      gsutil iam ch "serviceAccount:${sa}:roles/storage.admin" "$EXPORT_BUCKET" >/dev/null 2>&1 \
        && log "  granted storage.admin on export bucket to ${sa}" \
        || log "  WARN: could not grant storage.admin to ${sa} (may already be set / insufficient perms)"
    fi
  done
}

# ============================================================================
# PLANE 1 — FIRESTORE
# ============================================================================
sync_firestore() {
  log "--- FIRESTORE: ${SRC_PROJECT} (export, read) -> ${DEST_PROJECT} (import, write) ---"
  ensure_export_bucket
  local export_path="${EXPORT_BUCKET}/firestore/${TS}"

  # READ-ONLY on prod: managed export. Writes snapshot into staging-owned bucket.
  local export_cmd="gcloud firestore export ${export_path} --project=${SRC_PROJECT}"
  # WRITE on staging: import. Overwrite-by-document-path (additive) — staging-only
  # docs (e.g. any path absent in prod) are untouched.
  local import_cmd="gcloud firestore import ${export_path} --project=${DEST_PROJECT}"

  log "  SOURCE export : ${export_cmd}"
  log "  DEST   import : ${import_cmd}"

  if [[ "$MODE" == "dry-run" ]]; then
    log "  [dry-run] would run the two commands above (export reads prod, import writes staging)"
    return 0
  fi

  assert_dest_is_staging "firestore export path (staging-owned bucket)" "$export_path"
  log "  exporting prod Firestore -> ${export_path} (read-only on prod) ..."
  $export_cmd 2>&1 | tee -a "$LOG_FILE"

  assert_dest_is_staging "firestore import project" "$DEST_PROJECT"
  log "  importing -> ${DEST_PROJECT} Firestore ..."
  $import_cmd 2>&1 | tee -a "$LOG_FILE"
  log "  FIRESTORE sync complete."
}

# ============================================================================
# PLANE 2 — STORAGE
# ============================================================================
sync_storage() {
  log "--- STORAGE: ${SRC_BUCKET} (SOURCE) -> ${DEST_BUCKET} (DEST) ---"
  assert_dest_is_staging "storage rsync DEST" "$DEST_BUCKET"
  # Additive rsync (NO -d): copies new/changed objects, never deletes staging
  # objects, so staging-only/demo assets survive.
  local rsync_flags="-m rsync -r"
  if [[ "$MODE" == "dry-run" ]]; then
    log "  DRY-RUN: gsutil -m rsync -r -n ${SRC_BUCKET} ${DEST_BUCKET}"
    gsutil -m rsync -r -n "$SRC_BUCKET" "$DEST_BUCKET" 2>&1 | tee -a "$LOG_FILE" || true
    return 0
  fi
  log "  gsutil ${rsync_flags} ${SRC_BUCKET} ${DEST_BUCKET}"
  gsutil $rsync_flags "$SRC_BUCKET" "$DEST_BUCKET" 2>&1 | tee -a "$LOG_FILE"
  log "  STORAGE sync complete."
}

# ============================================================================
# PLANE 3 — AUTH USERS
# ============================================================================
sync_auth() {
  log "--- AUTH: ${SRC_PROJECT} (auth:export, read) -> ${DEST_PROJECT} (auth:import, write) ---"
  local users_file="${WORK_DIR}/users.json"

  # Fetch prod's SCRYPT hash parameters AT RUNTIME (never hardcoded). Without
  # these the imported password hashes would not validate and every migrated
  # user would be locked out.
  local token cfg
  token="$(gcloud auth print-access-token 2>/dev/null)" || die "could not mint access token for hash-config lookup"
  cfg="$(curl -s -H "Authorization: Bearer ${token}" -H "x-goog-user-project: ${SRC_PROJECT}" \
        "https://identitytoolkit.googleapis.com/admin/v2/projects/${SRC_PROJECT}/config")" \
        || die "could not read prod Identity Platform config"

  local algo hkey saltsep rounds memcost
  read -r algo hkey saltsep rounds memcost < <(echo "$cfg" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d.get("signIn", {}).get("hashConfig")
if not h:
    sys.stderr.write("NO_HASH_CONFIG: " + json.dumps(d.get("error", d))[:400] + "\n")
    sys.exit(3)
print(h.get("algorithm",""), h.get("signerKey",""), h.get("saltSeparator",""),
      h.get("rounds",""), h.get("memoryCost",""))
') || die "prod hash params NOT retrievable non-interactively — STOP. Needed for auth:import: algorithm, signerKey, saltSeparator, rounds, memoryCost from ayma-ai Identity Platform config. Fix auth/quota, then re-run. Users NOT imported (would break passwords)."

  [[ "$algo" == "SCRYPT" ]] || die "unexpected prod hash algorithm '${algo}' (expected SCRYPT); STOP — adjust import flags before importing."

  log "  prod hash params: algo=${algo} rounds=${rounds} memCost=${memcost} saltSep=${saltsep} signerKey=<redacted ${#hkey} chars>"

  # READ-ONLY on prod.
  local export_cmd="firebase auth:export ${users_file} --format=json --project ${SRC_PROJECT}"
  # WRITE on staging, with the prod hash params.
  local import_cmd_display="firebase auth:import ${users_file} --project ${DEST_PROJECT} --hash-algo=SCRYPT --hash-key=<redacted> --salt-separator=${saltsep} --rounds=${rounds} --mem-cost=${memcost}"

  log "  SOURCE export : ${export_cmd}"
  log "  DEST   import : ${import_cmd_display}"

  if [[ "$MODE" == "dry-run" ]]; then
    log "  [dry-run] would export prod users (read-only) then import into staging with the prod hash params above"
    return 0
  fi

  log "  exporting prod auth users (read-only on prod) ..."
  GOOGLE_CLOUD_QUOTA_PROJECT="${SRC_PROJECT}" $export_cmd 2>&1 | tee -a "$LOG_FILE"

  assert_dest_is_staging "auth:import project" "$DEST_PROJECT"
  log "  importing auth users -> ${DEST_PROJECT} (upsert by uid) ..."
  GOOGLE_CLOUD_QUOTA_PROJECT="${DEST_PROJECT}" firebase auth:import "$users_file" \
    --project "$DEST_PROJECT" \
    --hash-algo=SCRYPT \
    --hash-key="$hkey" \
    --salt-separator="$saltsep" \
    --rounds="$rounds" \
    --mem-cost="$memcost" 2>&1 | tee -a "$LOG_FILE"
  log "  AUTH sync complete."
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  {
    echo ""
    echo "============================================================"
    echo "prod->staging sync  mode=${MODE}  run=${TS}  by=$(whoami)@$(hostname)"
  } | tee -a "$LOG_FILE"

  guard_startup

  log "RESOLVED SOURCE (read-only): project=${SRC_PROJECT} bucket=${SRC_BUCKET}"
  log "RESOLVED DEST   (writes):    project=${DEST_PROJECT} bucket=${DEST_BUCKET} export=${EXPORT_BUCKET}"
  log "MODE=${MODE}  firestore=${DO_FIRESTORE} storage=${DO_STORAGE} auth=${DO_AUTH}"
  if [[ "$MODE" == "dry-run" ]]; then
    log "*** DRY-RUN — no writes to staging will be performed ***"
  fi

  if $DO_FIRESTORE; then sync_firestore; else log "--- FIRESTORE skipped ---"; fi
  if $DO_STORAGE;   then sync_storage;   else log "--- STORAGE skipped ---";   fi
  if $DO_AUTH;      then sync_auth;      else log "--- AUTH skipped ---";      fi

  log "DONE (mode=${MODE})."
}

main "$@"
