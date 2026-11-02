#!/usr/bin/env bash
# Boot the Lane 2 bench AVD (Lane2b_API_36 on emulator-5556) alongside Lane 1
# (emulator-5554, Scout's live bench — never touched) with EVERY adb call the
# emulator itself makes scoped to the Lane 2 serial.
#
# Root cause: the emulator binary spawns its own guest-setup commands as
# `adb -e ...`. With two emulators attached those fail with
# `adb: more than one emulator` (65-70 WARNINGs per boot in
# ~/.fleet-logs/lane2*.log), and the Lane2b QEMU process then SIGSEGVs
# (exit 139). Agent-side `-s` cannot fix calls the emulator itself makes,
# ANDROID_ADB_SERIAL does not override `-e`, and unprivileged user/mount
# namespaces are disabled on this host — so the emulator is launched with an
# LD_PRELOAD shim (lane2-adb-scope.c, built on demand into the cache dir)
# that rewrites `-e` to `-s emulator-5556` in any adb argv in its process
# tree only. No root, no mounts, no system modification; Lane 1 unaffected.
#
# Usage:
#   boot-lane2b.sh boot [logfile]     boot + wait for boot_completed (default)
#   boot-lane2b.sh install <apk>       install APK on Lane 2 (scoped)
#   boot-lane2b.sh launch              launch com.ayma.ayma_flutter/.MainActivity
#   boot-lane2b.sh alive <minutes>     poll: emulator + app process alive
#   boot-lane2b.sh collisions [log]    count 'more than one emulator' in a log
#
# Env overrides: LANE2_AVD (Lane2b_API_36), ADB_SERIAL/LANE2_ADB_SERIAL (emulator-5556),
# LANE2_PORT (5556), LANE2_LOGDIR (~/.fleet-logs), ANDROID_SDK_ROOT.
set -euo pipefail

AVD="${LANE2_AVD:-Lane2b_API_36}"
SERIAL="${ADB_SERIAL:-${LANE2_ADB_SERIAL:-emulator-5556}}"
PORT="${LANE2_PORT:-5556}"
SDK="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
EMU="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
PKG="com.ayma.ayma_flutter"
ACTIVITY="$PKG/.MainActivity"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SRC="$SCRIPT_DIR/lane2-adb-scope.c"
SHIM_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/lane2bench"
SHIM="$SHIM_DIR/lane2-adb-scope.so"
LOGDIR="${LANE2_LOGDIR:-$HOME/.fleet-logs}"
mkdir -p "$SHIM_DIR" "$LOGDIR"

log() { echo "[lane2b] $*"; }
die() { echo "[lane2b] ERROR: $*" >&2; exit 1; }

serial_up() { "$ADB" devices 2>/dev/null | awk -v s="$1" 'NR>1 && $1==s && $2=="device" {f=1} END{exit !f}'; }

build_shim() {
  if [[ ! -f "$SHIM" || "$SHIM_SRC" -nt "$SHIM" ]]; then
    command -v gcc >/dev/null || die "gcc not found (needed to build the adb-scope shim)"
    log "building adb-scope shim -> $SHIM"
    gcc -shared -fPIC -O2 -o "$SHIM" "$SHIM_SRC" -ldl || die "shim build failed"
  fi
}

# Safe self-test: with a NONEXISTENT serial, a rewritten `adb -e` must fail
# with 'device <serial> not found' (proving -e became -s <serial>) without
# touching any attached device. An unrewritten -e would succeed against the
# only emulator — that means the shim is inert and booting would be unscoped.
# NOTE: the shim interposes exec, so it must be loaded in the PARENT that
# execs adb (the inner bash), not in adb itself.
self_test_shim() {
  local probe="emulator-5599" out
  out="$(LD_PRELOAD="$SHIM" ADB_SERIAL="$probe" LANE2_ADB_SERIAL="$probe" \
    bash -c 'exec "$0" -e shell echo SCOPE_PROBE' "$ADB" 2>&1)" || true
  if [[ "$out" == *"device '$probe' not found"* ]]; then
    log "shim self-test PASS (-e rewritten to -s $probe; no device touched)"
  else
    die "shim self-test FAIL (-e output: $out) — refusing to boot unscoped"
  fi
  # Safe self-test 2: bare unscoped adb calls must also be rewritten to -s $probe
  out="$(LD_PRELOAD="$SHIM" ADB_SERIAL="$probe" LANE2_ADB_SERIAL="$probe" \
    bash -c 'exec "$0" shell echo SCOPE_PROBE' "$ADB" 2>&1)" || true
  if [[ "$out" == *"device '$probe' not found"* ]]; then
    log "shim self-test PASS (unscoped adb rewritten to -s $probe; no device touched)"
  else
    die "shim self-test FAIL (unscoped output: $out) — refusing to boot unscoped"
  fi
  # Passthrough sanity: plain `adb devices` must still work under the shim.
  LD_PRELOAD="$SHIM" ADB_SERIAL="$probe" LANE2_ADB_SERIAL="$probe" \
    bash -c 'exec "$0" devices' "$ADB" >/dev/null 2>&1 \
    || die "shim breaks adb passthrough — refusing to boot"
}

cmd_boot() {
  local logfile="${1:-$LOGDIR/lane2b-emu-$(date +%Y%m%d-%H%M%S).log}"
  [[ -x "$EMU" ]] || die "emulator not found at $EMU"
  [[ -x "$ADB" ]] || die "adb not found at $ADB"
  [[ -d "$HOME/.android/avd/$AVD.avd" ]] || die "AVD $AVD not found"
  if serial_up "$SERIAL"; then die "$SERIAL already up — refusing double-boot"; fi
  if serial_up "emulator-5554"; then
    log "Lane 1 (emulator-5554) is up — it will not be touched"
  else
    log "NOTE: emulator-5554 is not up (expected while Scout's bench runs)"
  fi
  build_shim
  self_test_shim

  local flags=(-avd "$AVD" -port "$PORT" -gpu swiftshader_indirect
    -no-snapshot-load -no-audio -no-boot-anim)
  [[ -z "${DISPLAY:-}" ]] && flags+=(-no-window)
  log "booting $AVD as $SERIAL (log: $logfile)"
  # shellcheck disable=SC2086
  ADB_SERIAL="$SERIAL" ANDROID_SERIAL="$SERIAL" LANE2_ADB_SERIAL="$SERIAL" ANDROID_ADB_SERIAL="$SERIAL" LD_PRELOAD="$SHIM" \
    setsid -f "$EMU" "${flags[@]}" >>"$logfile" 2>&1 </dev/null

  log "waiting for device..."
  local deadline=$((SECONDS + 180))
  until serial_up "$SERIAL"; do
    ((SECONDS < deadline)) || die "timed out waiting for $SERIAL (log: $logfile)"
    sleep 5
  done
  log "waiting for sys.boot_completed..."
  deadline=$((SECONDS + 300))
  while [[ "$(timeout 20 "$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; do
    serial_up "$SERIAL" || die "$SERIAL vanished during boot (log: $logfile)"
    ((SECONDS < deadline)) || die "timed out waiting for boot_completed (log: $logfile)"
    sleep 5
  done
  log "booted. emulator log: $logfile"
  cmd_collisions "$logfile"
  # Prove a setup call actually APPLIED (previously all failed): the emulator
  # sets screen_off_timeout to 2147483647 via one of its internal adb calls.
  local timeout_val
  timeout_val="$(timeout 20 "$ADB" -s "$SERIAL" shell settings get system screen_off_timeout 2>/dev/null | tr -d '\r')" || timeout_val="?"
  log "screen_off_timeout on $SERIAL = $timeout_val (2147483647 = shim active)"
}

cmd_install() {
  local apk="${1:?usage: boot-lane2b.sh install <apk>}"
  [[ -f "$apk" ]] || die "apk not found: $apk"
  serial_up "$SERIAL" || die "$SERIAL is not up"
  "$ADB" -s "$SERIAL" install -r -d "$apk"
}

cmd_launch() {
  serial_up "$SERIAL" || die "$SERIAL is not up"
  "$ADB" -s "$SERIAL" shell am start -n "$ACTIVITY"
  sleep 3
  local pid
  pid="$(timeout 20 "$ADB" -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  [[ -n "$pid" ]] && log "app pid: $pid" || die "app process not found after launch"
}

cmd_alive() {
  local minutes="${1:?usage: boot-lane2b.sh alive <minutes>}"
  local end=$((SECONDS + minutes * 60)) i=0 pid
  while ((SECONDS < end)); do
    i=$((i + 1))
    serial_up "$SERIAL" || die "poll $i: $SERIAL is OFFLINE (emulator died)"
    pid="$(timeout 20 "$ADB" -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
    [[ -n "$pid" ]] || die "poll $i: app process $PKG is GONE (emulator up)"
    log "poll $i: emulator up, $PKG pid $pid"
    sleep 30
  done
  log "alive $minutes min: PASS"
}

cmd_collisions() {
  local logfile="${1:?usage: boot-lane2b.sh collisions <logfile>}"
  local n=0
  [[ -f "$logfile" ]] && n=$(grep -c "more than one emulator" "$logfile" || true)
  log "device-ambiguous adb collisions in $logfile: $n"
}

case "${1:-boot}" in
  boot) shift; cmd_boot "$@" ;;
  install) shift; cmd_install "$@" ;;
  launch) shift; cmd_launch "$@" ;;
  alive) shift; cmd_alive "$@" ;;
  collisions) shift; cmd_collisions "$@" ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \?//' ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
