#!/usr/bin/env bash
# Apply the Artifact Registry cleanup policy to every Docker repo. Idempotent.
#
#   scripts/apply-artifact-cleanup.sh              # dry-run (default): logs what WOULD be deleted
#   scripts/apply-artifact-cleanup.sh --no-dry-run # enforce deletions
#
# Policy: scripts/artifact-registry-cleanup-policy.json (keep latest 10 per package,
# keep <14d, delete >30d). Uses the active gcloud auth; no credentials here.
set -euo pipefail

PROJECT=ayma-ai
POLICY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/artifact-registry-cleanup-policy.json"
MODE="--dry-run"
case "${1:-}" in
  "") ;;
  --no-dry-run) MODE="--no-dry-run" ;;
  --dry-run) ;;
  *) echo "usage: $0 [--dry-run|--no-dry-run]" >&2; exit 2 ;;
esac

gcloud artifacts repositories list --project "$PROJECT" \
  --filter="format=DOCKER" --format=json 2>/dev/null |
  sed -n 's/^ *"name": "\(.*\)",$/\1/p' |
while read -r name; do
  location="${name#*/locations/}"; location="${location%%/*}"
  repo="${name##*/}"
  echo "Applying cleanup policy to $repo ($location) $MODE"
  gcloud artifacts repositories set-cleanup-policies "$repo" \
    --project "$PROJECT" --location "$location" \
    --policy "$POLICY" "$MODE"
done
