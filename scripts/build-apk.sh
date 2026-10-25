#!/usr/bin/env bash
# Build the phone APK with Sentry wired in. See docs/AGENT_HANDOFF.md §3.
#
#   REVENUECAT_TEST_KEY=... scripts/build-apk.sh [--release|--debug] [extra flutter args]
#
# The Flutter Sentry DSN is read from Secret Manager (SENTRY_DSN_FLUTTER) at
# build time and passed as --dart-define, so it is never written to the repo
# or to disk. Without it (no gcloud access) the build still runs, Sentry off.
# REVENUECAT_TEST_KEY is the RevenueCat Test Store key (founder / RevenueCat
# dashboard); it must never ship in a store build.
set -euo pipefail

PROJECT=ayma-ai
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="--release"
if [[ "${1:-}" == "--release" || "${1:-}" == "--debug" ]]; then
  MODE="$1"
  shift
fi

if [[ -z "${REVENUECAT_TEST_KEY:-}" ]]; then
  echo "REVENUECAT_TEST_KEY is not set (RevenueCat Test Store key)." >&2
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
flutter build apk "$MODE" \
  --dart-define=REVENUECAT_TEST_KEY="$REVENUECAT_TEST_KEY" \
  --dart-define=SENTRY_DSN="$SENTRY_DSN" \
  --dart-define=SENTRY_ENVIRONMENT="$ENVIRONMENT" \
  --dart-define=SENTRY_RELEASE="ayma@$VERSION" \
  --dart-define=SENTRY_DIST="${VERSION##*+}" \
  "$@"
