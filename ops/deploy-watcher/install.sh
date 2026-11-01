#!/usr/bin/env bash
# Install (or refresh) the ayma-staging-watcher systemd user service.
# Run AFTER the staging branch contains ops/deploy-watcher/ AND the dedicated
# build worktree (~/workspace/ayma-autodeploy) has been advanced to that tip:
#   bash ~/workspace/ayma-autodeploy/ops/deploy-watcher/install.sh
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="$SRC/ayma-staging-watcher.service"
UNIT_DST="$HOME/.config/systemd/user/ayma-staging-watcher.service"
if [[ "$SRC" != *"ayma-autodeploy"* ]]; then
  echo "WARNING: installing from $SRC (expected the ayma-autodeploy worktree)." >&2
  echo "The unit symlinks this copy; a branch worktree will break on cleanup." >&2
fi
mkdir -p "$HOME/.config/systemd/user"
ln -sf "$UNIT_SRC" "$UNIT_DST"
systemctl --user daemon-reload
systemctl --user enable --now ayma-staging-watcher.service
systemctl --user status ayma-staging-watcher.service --no-pager | head -n 12
