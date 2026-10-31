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
if [[ "${1:-}" == "--release" || "${1:-}" == "--debug" ]]; then
  MODE="$1"
  shift
fi

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
  "$@"
