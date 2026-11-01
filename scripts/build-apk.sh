#!/usr/bin/env bash
# Build the phone APK with Sentry wired in. See docs/AGENT_HANDOFF.md §3.
#
#   [REVENUECAT_TEST_KEY=...] scripts/build-apk.sh [--release|--debug] [extra flutter args]
#
# The Flutter Sentry DSN is read from Secret Manager (SENTRY_DSN_FLUTTER) at
# build time and passed as --dart-define, so it is never written to the repo
# or to disk. Without it (no gcloud access) the build still runs, Sentry off.
# REVENUECAT_TEST_KEY is the RevenueCat Test Store key; unset, it is read from
# Secret Manager (REVENUECAT_TEST_KEY), and the build stops unless RevenueCat
# accepts it. It must never ship in a store build.
set -euo pipefail

PROJECT=ayma-ai
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="--release"
STAGING=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|--debug) MODE="$1"; shift ;;
    # --staging points the build at the ayma-staging Firebase project AND the
    # staging API base, so the installed app authenticates against staging and
    # talks to the staging backend (prod tokens are rejected by staging). It
    # swaps in the staging google-services.json and sets the FB_*/AYMA_API_BASE_URL
    # dart-defines, both sourced from the committed staging config. Dev builds only.
    --staging) STAGING=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "${REVENUECAT_TEST_KEY:-}" ]]; then
  if ! REVENUECAT_TEST_KEY="$(gcloud secrets versions access latest \
      --secret REVENUECAT_TEST_KEY --project "$PROJECT" 2>/dev/null)"; then
    echo "REVENUECAT_TEST_KEY is not set and could not be read from Secret Manager." >&2
    exit 1
  fi
fi

# A pasted key with anything glued on (build 2208 shipped "<key>https") makes
# RevenueCat reject every call, leaving the Plan page with no packages. Check
# the exact value against RevenueCat before building.
if [[ ! "$REVENUECAT_TEST_KEY" =~ ^test_[A-Za-z0-9]+$ ]]; then
  echo "REVENUECAT_TEST_KEY is malformed (expected test_ followed by letters/digits)." >&2
  exit 1
fi
RC_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $REVENUECAT_TEST_KEY" -H 'X-Platform: android' \
  'https://api.revenuecat.com/v1/subscribers/build-key-check/offerings' || true)"
if [[ "$RC_STATUS" != "200" ]]; then
  echo "RevenueCat rejected REVENUECAT_TEST_KEY (HTTP $RC_STATUS); not building." >&2
  exit 1
fi

if ! SENTRY_DSN="$(gcloud secrets versions access latest \
    --secret SENTRY_DSN_FLUTTER --project "$PROJECT" 2>/dev/null)"; then
  echo "warning: could not read SENTRY_DSN_FLUTTER; building with Sentry off." >&2
  SENTRY_DSN=""
fi

VERSION="$(grep -E '^version:' "$ROOT/ayma_flutter/pubspec.yaml" | awk '{print $2}')"
ENVIRONMENT=development
[[ "$MODE" == "--release" ]] && ENVIRONMENT=phone-release

# --- staging: swap native Firebase config + inject staging dart-defines ---- #
STAGING_DEFINES=()
if (( STAGING == 1 )); then
  GS="$ROOT/ayma_flutter/android/app/google-services.json"
  GS_STAGING="$ROOT/ayma_flutter/android/app/google-services.staging.json"
  [[ -f "$GS_STAGING" ]] || { echo "staging build needs $GS_STAGING (missing)." >&2; exit 1; }
  # Pull the public client config from the committed staging file (single
  # source of truth) so firebase_options.dart (Dart, authoritative for
  # Firebase.initializeApp) and the native google-services.json agree — the
  # APK then verifies as staging on BOTH axes.
  read -r FB_PROJECT_ID FB_PROJECT_NUMBER FB_STORAGE_BUCKET FB_APP_ID FB_API_KEY FB_WEB_CLIENT < <(
    python3 - "$GS_STAGING" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pi = d["project_info"]; c = d["client"][0]
# The web (client_type 3) oauth client is the Google Sign-In server client id;
# "-" if Google isn't enabled yet (sign-in will then fall back to prod default).
web = next((o["client_id"] for o in c.get("oauth_client", [])
            if o.get("client_type") == 3), "-")
print(pi["project_id"], pi["project_number"], pi["storage_bucket"],
      c["client_info"]["mobilesdk_app_id"], c["api_key"][0]["current_key"], web)
PY
  )
  ENVIRONMENT=staging
  STAGING_DEFINES=(
    --dart-define=AYMA_API_BASE_URL=https://ayma-api-staging-4qy2nxz2aa-uc.a.run.app
    --dart-define=FB_PROJECT_ID="$FB_PROJECT_ID"
    --dart-define=FB_MESSAGING_SENDER_ID="$FB_PROJECT_NUMBER"
    --dart-define=FB_STORAGE_BUCKET="$FB_STORAGE_BUCKET"
    --dart-define=FB_ANDROID_APP_ID="$FB_APP_ID"
    --dart-define=FB_ANDROID_API_KEY="$FB_API_KEY"
  )
  # Google Sign-In server client id must be the STAGING web client, or Google
  # sign-in mints a token for the wrong project and staging rejects it (401).
  if [[ -n "$FB_WEB_CLIENT" && "$FB_WEB_CLIENT" != "-" ]]; then
    STAGING_DEFINES+=(--dart-define=GOOGLE_SERVER_CLIENT_ID="$FB_WEB_CLIENT")
    echo ">> staging Google server client: $FB_WEB_CLIENT"
  else
    echo ">> WARNING: no web oauth_client in $GS_STAGING — Google sign-in will use the prod default and fail on staging. Enable Google on ayma-staging + regen the config." >&2
  fi
  # Swap the native config in for this build, always restoring it afterwards.
  cp "$GS" "$GS.prod.bak"
  cp "$GS_STAGING" "$GS"
  trap 'mv -f "$GS.prod.bak" "$GS" 2>/dev/null || true' EXIT
  echo ">> staging build: Firebase=$FB_PROJECT_ID, API=staging"
fi

cd "$ROOT/ayma_flutter"
# ENABLE_DEV_MODE=true: this is our INTERNAL / development build path, so dev
# mode (seven-tap unlock → Developer panel) stays available. Customer / store
# releases (codemagic.yaml, Play) OMIT this define, so dev mode compiles out
# (kDevModeEnabled defaults to false → completely unreachable). See
# docs/ARCHITECTURE.md and lib/dev_mode.dart.
flutter build apk "$MODE" \
  --dart-define=ENABLE_DEV_MODE=true \
  --dart-define=REVENUECAT_TEST_KEY="$REVENUECAT_TEST_KEY" \
  --dart-define=SENTRY_DSN="$SENTRY_DSN" \
  --dart-define=SENTRY_ENVIRONMENT="$ENVIRONMENT" \
  --dart-define=SENTRY_RELEASE="ayma@$VERSION" \
  --dart-define=SENTRY_DIST="${VERSION##*+}" \
  "${STAGING_DEFINES[@]}" \
  "${ARGS[@]}"
