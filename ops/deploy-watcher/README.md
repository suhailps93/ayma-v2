# Staging auto-deploy watcher

Standing pipeline (founder directive 2026-11-01). Polls the `staging` tip
every ~3 minutes; on change it (1) runs `scripts/deploy-staging.sh`
(code-only), (2) builds a staging-pointed dev APK and adb-installs it to the
founder's Pixel, (3) appends a plain-language entry to
`~/workspace/ayma-inbox/deploys.md`. Store builds (TestFlight / Play) are
gated by the founder and never touched here.

## Files

- `staging-autodeploy.sh` — the watcher (`--once`, `--daemon`, `--status`).
- `ayma-staging-watcher.service` — systemd user unit (runs the script from the
  dedicated build worktree `~/workspace/ayma-autodeploy`).
- `install.sh` — symlinks the unit into `~/.config/systemd/user` and starts it.

## Operate

- Status: `systemctl --user status ayma-staging-watcher` and
  `bash ~/workspace/ayma-autodeploy/ops/deploy-watcher/staging-autodeploy.sh --status`
- Logs: `journalctl --user -u ayma-staging-watcher` plus per-cycle logs in
  `~/workspace/ayma-inbox/.autodeploy/logs/` (`watcher.log`, `deploy-<sha>.log`,
  `build-<sha>.log`, `adb-install.log`).
- State: `~/workspace/ayma-inbox/.autodeploy/`
  (`last_staging`, `last_phone`, `last_apk`). Optional `pixel_addr` file with
  `IP:port` enables a wireless adb reconnect each poll.

## Behavior notes

- A cycle takes a lock: polls that land mid-cycle are skipped, never stacked.
- Pixel unreachable: staging still deploys; the install retries every poll
  until it lands (noted in `deploys.md`, no inbox spam).
- Failed deploy/build: recorded in `deploys.md` plus one `BLOCKED` entry in
  `~/workspace/ayma-inbox/muse.md` per commit+stage. Heals on the next tip
  change (the next deploy builds from the new tip).
- After advancing the worktree the script re-execs itself, so each cycle runs
  the watcher code at the commit it is deploying. If this script is ever
  renamed, rerun `install.sh` from the build worktree.
