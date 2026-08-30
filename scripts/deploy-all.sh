#!/usr/bin/env bash
# Full deploy from a clean checkout: rules, indexes, both Cloud Run services.
# See docs/deploy.md. Pass --full to (re)set env vars + secret mounts too.
set -euo pipefail

PROJECT=ayma-ai
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== firestore rules + indexes =="
firebase deploy --only firestore:rules,firestore:indexes --project "$PROJECT"

echo "== ayma-api =="
"$ROOT/scripts/deploy-api.sh" "${1:-}"

echo "== ayma-agent =="
"$ROOT/scripts/deploy-agent.sh" "${1:-}"

echo "== done =="
