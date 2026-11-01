#!/usr/bin/env bash
# Ayma staging auto-deploy watcher (ThinkPad standing pipeline).
#
# Founder directive (2026-11-01): whenever the `staging` branch tip changes,
#   (1) deploy staging cloud via deploy-staging.sh (code-only; keeps env),
#   (2) build a DEV apk from that same staging commit (points at the staging
#       API) and install it to the founder's Pixel over adb — dev install only,
#       store builds (TestFlight/Play) are NEVER touched,
#   (3) append an entry to ~/workspace/ayma-inbox/deploys.md: timestamp, commit
#       range, staging deploy result, phone install result, and plain-language
#       "What's different" bullets (one per user-visible change; internal
#       commits grouped into a single bullet).
#
# Pixel unreachable: staging still deploys, the entry notes it, install retries
# next cycle. Failures are never silent: a failed deploy/build gets a deploys.md
# entry plus a BLOCKED entry in ~/workspace/ayma-inbox/muse.md (once per
# commit+stage). A failed cycle heals on the next tip change (the next deploy
# is from the new tip, which includes the failed commit's code).
#
# Usage:
#   staging-autodeploy.sh --once     # single cycle (cron/manual; skips if a
#                                    # cycle is already running)
#   staging-autodeploy.sh --daemon   # loop --once every $WATCH_INTERVAL Inser(180)s
#   staging-autodeploy.sh --status   # print watcher state, no changes
#
# Production runs under the systemd user service ayma-staging-watcher (see
# ayma-staging-watcher.service + install.sh), which executes THIS file from the
# dedicated build worktree (~/workspace/ayma-autodeploy). The script re-execs
# itself after advancing the worktree, so a cycle always runs the code at the
# commit it is deploying. All logging goes to stdout/stderr (journal + the
# service's watcher.log); per-cycle deploy/build/adb logs go to $LOGDIR.
set -uo pipefail

# --- environment (systemd/cron have a minimal PATH) ------------------------ #
export PATH="/snap/bin:/usr/local/bin:/usr/bin:/bin:/home/suhailps/Android/Sdk/platform-tools:$PATH"
export ANDROID_SDK_ROOT="/home/suhailps/Android/Sdk"
export ANDROID_HOME="/home/suhailps/Android/Sdk"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/default-java}"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

STAGING_API="https://ayma-api-staging-4qy2nxz2aa-uc.a.run.app"
REPO_MAIN="/home/suhailps/workspace/ayma"
WT="/home/suhailps/workspace/ayma-autodeploy"      # dedicated build worktree
INBOX="/home/suhailps/workspace/ayma-inbox"
STATE="$INBOX/.autodeploy"
DEPLOYS_MD="$INBOX/deploys.md"
MUSE_MD="$INBOX/muse.md"
LOGDIR="$STATE/logs"
INTERVAL="${WATCH_INTERVAL:-180}"
mkdir -p "$STATE" "$LOGDIR"

now_pt()  { TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M %Z'; }
now_log() { date '+%Y-%m-%d %H:%M %Z'; }
log()     { echo "[$(now_log)] $*"; }

read_state()  { cat "$STATE/$1" 2>/dev/null || true; }
write_state() { printf '%s' "$2" > "$STATE/$1"; }
short()       { git -C "$WT" rev-parse --short "$1" 2>/dev/null || echo "$1"; }

ensure_deploys_header() {
  if [[ ! -f "$DEPLOYS_MD" ]]; then
    cat > "$DEPLOYS_MD" <<'EOF'
# Ayma staging deploys

Standing pipeline (founder directive 2026-11-01): every `staging` tip change is
deployed to the staging cloud + built as a staging-pointed dev APK and
installed to the founder's Pixel. Watcher: `ayma-staging-watcher.service`.
Store builds (TestFlight / Play) are gated by the founder — never touched here.
EOF
  fi
}

# --- BLOCKED report to Astro (deduped: once per commit+stage) --------------- #
muse_blocked() { # $1=commit $2=stage $3=short-blocker $4=detail-line
  local key="$1:$2"
  [[ "$(read_state last_reported_failure)" == "$key" ]] && return 0
  {
    echo ""
    echo "## $(now_pt) — From Muse (Engineer) — BLOCKED: $3"
    echo "$4"
    echo "Deploys log: ~/workspace/ayma-inbox/deploys.md. Next staging tip change retries automatically."
  } >> "$MUSE_MD"
  write_state last_reported_failure "$key"
}

# --- adb device discovery: the Pixel = first non-emulator 'device' --------- #
# Optional: put "IP:port" in $STATE/pixel_addr to enable a wireless reconnect.
pixel_serial() {
  local addr
  addr="$(read_state pixel_addr)"
  [[ -n "$addr" ]] && adb connect "$addr" >/dev/null 2>&1 || true
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/ {print $1; exit}'
}

# --- "What's different" bullets from git log PREV..NEW ---------------------- #
# feat/fix/ui/perf/feature -> one founder-language bullet each; everything else
# -> one grouped "internal fixes" bullet. Merge commits skipped (their branch
# commits carry the real change).
CONVENTIONAL_RE='^(feat|feature|fix|ui|perf)(\(([^)]+)\))?!?: *(.*)$'
whats_different() {
  local range="$1" internal=0 subj scope rest
  while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    if [[ "$subj" =~ $CONVENTIONAL_RE ]]; then
      scope="${BASH_REMATCH[3]}"; rest="${BASH_REMATCH[4]}"
      if [[ -n "$scope" ]]; then
        printf -- '- **%s:** %s\n' "$(echo "$scope" | sed 's/[-_]/ /g; s/\b\(.\)/\u\1/')" "$rest"
      else
        printf -- '- %s\n' "$(echo "$rest" | sed 's/\b\(.\)/\u\1/')"
      fi
    else
      internal=$((internal + 1))
    fi
  done < <(git -C "$WT" log --no-merges --pretty=%s "$range")
  if (( internal > 0 )); then
    printf -- '- Internal fixes and housekeeping (%d commit%s, no user-visible change)\n' \
      "$internal" "$([[ $internal -eq 1 ]] && echo '' || echo 's')"
  fi
}

# --- ensure the build worktree exists --------------------------------------- #
ensure_worktree() {
  if [[ ! -e "$WT/.git" ]]; then
    log "creating build worktree $WT from origin/staging"
    git -C "$REPO_MAIN" fetch origin staging -q
    git -C "$REPO_MAIN" worktree add -f "$WT" origin/staging >/dev/null 2>&1 \
      || { log "ERROR: could not create worktree"; return 1; }
  fi
}

# --- post-build self-check: the APK must carry the staging number ------- #
# Single grep, never a strings|grep -q pipeline: with pipefail set, grep -q's
# early exit SIGPIPEs strings and the pipeline fails even when it matches.
apk_verifies_staging() { # $1=apk path
  grep -a -q "187469876115" "$1" 2>/dev/null
}

# --- install the last-built apk to the Pixel; echoes a result string ------- #
install_to_pixel() {
  local apk="$1" serial
  if [[ ! -f "$apk" ]]; then echo "not installed - apk missing ($apk)"; return 1; fi
  serial="$(pixel_serial)"
  if [[ -z "$serial" ]]; then echo "not installed - Pixel not reachable via adb"; return 1; fi
  if adb -s "$serial" install -r -d "$apk" >"$LOGDIR/adb-install.log" 2>&1; then
    echo "installed to $serial (dev apk)"
    return 0
  fi
  echo "not installed - adb install failed on $serial (see $LOGDIR/adb-install.log)"
  return 1
}

status() {
  echo "watcher state ($STATE):"
  echo "  last_staging: $(read_state last_staging || true) ($(short "$(read_state last_staging)" 2>/dev/null || true))"
  echo "  last_phone:   $(read_state last_phone || true)"
  echo "  last_apk:     $(read_state last_apk || true)"
  if [[ -e "$WT/.git" ]]; then
    echo "  worktree HEAD: $(git -C "$WT" rev-parse --short HEAD 2>/dev/null)"
  else
    echo "  worktree: MISSING ($WT)"
  fi
  echo "  pixel_serial: $(pixel_serial || true) (empty = unreachable)"
}

cycle_once() {
  exec 9>"$STATE/cycle.lock"
  if ! flock -n 9; then
    log "previous cycle still running; skipping this poll"
    exit 0
  fi
  ensure_deploys_header
  ensure_worktree || exit 1
  git -C "$WT" fetch origin staging -q || { log "fetch failed (transient; will retry next poll)"; exit 1; }
  local NEW LAST_STAGING LAST_PHONE
  NEW="$(git -C "$WT" rev-parse origin/staging)"
  LAST_STAGING="$(read_state last_staging)"
  LAST_PHONE="$(read_state last_phone)"

  if [[ "$NEW" == "$LAST_STAGING" ]]; then
    # Staging cloud is current. If the phone is behind, retry the install only.
    if [[ -n "$LAST_STAGING" && "$LAST_PHONE" != "$LAST_STAGING" ]]; then
      local APK RES
      APK="$(read_state last_apk)"
      log "phone install retry for $(short "$LAST_STAGING")"
      if RES="$(install_to_pixel "$APK")"; then
        write_state last_phone "$LAST_STAGING"
        {
          echo ""
          echo "### $(now_pt) — phone catch-up install"
          echo "- Commit: \`$(short "$LAST_STAGING")\` (staging already live)"
          echo "- phone: $RES"
        } >> "$DEPLOYS_MD"
        log "phone catch-up install succeeded"
      else
        log "phone still unreachable: $RES (will retry next poll)"
      fi
    fi
    exit 0
  fi

  # ---- staging tip advanced: full cycle ----------------------------------- #
  local PREV DEPLOY_RES BUILD_RES PHONE_RES PHONE_OK APK STAGING_APK
  PREV="${LAST_STAGING:-$NEW}"
  log "staging advanced: $(short "$PREV") -> $(short "$NEW"); starting cycle"
  git -C "$WT" reset --hard origin/staging -q
  git -C "$WT" clean -fdq -e build 2>/dev/null || true
  # Run the rest of the cycle with the code AT the commit being deployed.
  if [[ "${WATCHER_REEXEC:-0}" != "1" ]]; then
    export WATCHER_REEXEC=1
    exec bash "$WT/ops/deploy-watcher/staging-autodeploy.sh" --once
  fi

  # (1) deploy staging cloud (code-only; keeps env + secrets)
  if bash "$WT/scripts/deploy-staging.sh" > "$LOGDIR/deploy-$(short "$NEW").log" 2>&1; then
    DEPLOY_RES="success (both services redeployed)"
  else
    DEPLOY_RES="FAILED (see $LOGDIR/deploy-$(short "$NEW").log)"
    log "staging deploy FAILED"
  fi

  # (2) build the dev apk from this commit, pointed at staging (Firebase +
  # API). build-apk.sh --staging swaps in google-services.staging.json and
  # injects AYMA_API_BASE_URL + FB_* defines, so the APK verifies as
  # ayma-staging on both the Dart and native axes.
  APK=""
  if bash "$WT/scripts/build-apk.sh" --debug --staging \
        > "$LOGDIR/build-$(short "$NEW").log" 2>&1; then
    STAGING_APK="$WT/ayma_flutter/build/app/outputs/flutter-apk/app-debug.apk"
    if apk_verifies_staging "$STAGING_APK"; then
      APK="$STAGING_APK"
      BUILD_RES="success (dev apk -> staging API)"
      write_state last_apk "$APK"
    else
      BUILD_RES="FAILED (APK did not verify as staging: project number 187469876115 not found)"
      log "apk staging self-check FAILED (project number 187469876115 missing from APK)"
    fi
  else
    BUILD_RES="FAILED (see $LOGDIR/build-$(short "$NEW").log)"
    log "apk build FAILED"
  fi

  # (3) install to the Pixel (never the emulator)
  if [[ -n "$APK" ]]; then
    if PHONE_RES="$(install_to_pixel "$APK")"; then PHONE_OK=1; else PHONE_OK=0; fi
  elif [[ "$BUILD_RES" == *"did not verify as staging"* ]]; then
    PHONE_RES="not installed - skipped (APK did not verify as staging)"; PHONE_OK=0
  else
    PHONE_RES="not installed - no apk (build failed)"; PHONE_OK=0
  fi

  # record the entry
  {
    echo ""
    echo "### $(now_pt) — staging deploy $(short "$PREV")..$(short "$NEW")"
    echo "- Commit range: \`$(short "$PREV")\` → \`$(short "$NEW")\`"
    echo "- Staging deploy: $DEPLOY_RES"
    echo "- Phone build: $BUILD_RES"
    echo "- Phone install: $PHONE_RES"
    echo ""
    echo "**What's different:**"
    local WD
    WD="$(whats_different "$PREV..$NEW")"
    if [[ -n "$WD" ]]; then echo "$WD"; else echo "- (no commits in range)"; fi
  } >> "$DEPLOYS_MD"

  # report non-self-recovering failures (once per commit+stage)
  [[ "$DEPLOY_RES" == FAILED* ]] && muse_blocked "$NEW" "deploy" \
    "staging deploy failed at $(short "$NEW")" \
    "scripts/deploy-staging.sh failed (log: $LOGDIR/deploy-$(short "$NEW").log). Phone build/install for this commit ran anyway where possible."
  if [[ "$BUILD_RES" == *"did not verify as staging"* ]]; then
    muse_blocked "$NEW" "build" \
      "staging APK did not verify as staging at $(short "$NEW")" \
      "Staging self-check failed: project number 187469876115 not found in the built APK (log: $LOGDIR/build-$(short "$NEW").log). Phone install skipped."
  elif [[ "$BUILD_RES" == FAILED* ]]; then
    muse_blocked "$NEW" "build" \
      "staging APK build failed at $(short "$NEW")" \
      "scripts/build-apk.sh --debug --staging failed (log: $LOGDIR/build-$(short "$NEW").log). No APK for this commit; phone install skipped."
  fi

  # advance state: staging always advances once we've deployed+recorded (a
  # failed cycle heals on the next tip change); phone advances only on a
  # successful install (else the retry path picks it up).
  write_state last_staging "$NEW"
  (( PHONE_OK == 1 )) && write_state last_phone "$NEW"
  log "cycle done: deploy=[$DEPLOY_RES] build=[$BUILD_RES] phone=[$PHONE_RES]"
}

daemon() {
  log "watcher daemon starting (poll every ${INTERVAL}s)"
  while true; do
    bash "$0" --once || true
    sleep "$INTERVAL"
  done
}

# Only dispatch when executed; self-check.test.sh sources this file.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:---once}" in
  --once)   cycle_once ;;
  --daemon) daemon ;;
  --status) status ;;
  -h|--help)
    sed -n '2,24p' "$0" | sed 's/^# \?//'
    echo "State: $STATE/{last_staging,last_phone,last_apk}, logs in $LOGDIR" ;;
  *) echo "error: unknown flag: $1 (see --help)" >&2; exit 2 ;;
esac
fi
