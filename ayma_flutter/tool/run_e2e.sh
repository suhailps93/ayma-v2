#!/usr/bin/env bash
# One-command E2E harness. Runs every suite on a real device against the live
# backend, streams `E2E_RESULT` markers, captures a real-pixel screenshot per
# scenario (host-side `adb screencap` on `E2E_SHOT` markers), drives offline
# states (host-side `adb svc wifi/data` on `E2E_NET` markers), and assembles
# build/e2e/REPORT.md. Usage: tool/run_e2e.sh [device]
#
# Prerequisite: the demo accounts (scripts/seed_demo_accounts.py) and the
# corner-case fixtures (scripts/seed_demo_edge_accounts.py) must be seeded.
set -uo pipefail
DEVICE="${1:-emulator-5554}"
cd "$(dirname "$0")/.."   # -> ayma_flutter

rm -rf build/e2e
mkdir -p build/e2e/screenshots
LOG=build/e2e/run.log
: > "$LOG"

adb() { command adb -s "$DEVICE" "$@"; }

# Make sure the device ends up back online whatever happens.
restore_net() { adb shell svc wifi enable >/dev/null 2>&1 || true
                adb shell svc data enable >/dev/null 2>&1 || true; }
trap restore_net EXIT

# Pre-grant notifications (so Android 13's system dialog never covers a shot)
# and revoke mic (so the sign-in welcome-voice/LiveKit session can't connect).
adb shell pm grant com.ayma.ayma_flutter android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell pm revoke com.ayma.ayma_flutter android.permission.RECORD_AUDIO 2>/dev/null || true
restore_net

# Background watcher: screenshots on E2E_SHOT, radio toggles on E2E_NET.
(
  tail -n +1 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    shot=$(printf '%s\n' "$line" | sed -n 's/.*E2E_SHOT \([A-Za-z0-9_]\{1,\}\).*/\1/p')
    if [ -n "$shot" ]; then
      adb exec-out screencap -p > "build/e2e/screenshots/$shot.png" 2>/dev/null
    fi
    net=$(printf '%s\n' "$line" | sed -n 's/.*E2E_NET \(on\|off\).*/\1/p')
    if [ "$net" = "off" ]; then
      adb shell svc wifi disable >/dev/null 2>&1 || true
      adb shell svc data disable >/dev/null 2>&1 || true
    elif [ "$net" = "on" ]; then
      adb shell svc wifi enable >/dev/null 2>&1 || true
      adb shell svc data enable >/dev/null 2>&1 || true
    fi
  done
) &
MON=$!

DEFINES="--dart-define=E2E_SHOTS=true --dart-define=E2E_NET=true"
for f in e2e_behaviors_test e2e_edge_test e2e_auth_test e2e_net_test; do
  echo "== E2E: $f on $DEVICE =="
  flutter test "integration_test/$f.dart" -d "$DEVICE" $DEFINES 2>&1 | tee -a "$LOG"
done

sleep 2
kill "$MON" 2>/dev/null
restore_net

python3 tool/e2e_report.py "$LOG" build/e2e/screenshots build/e2e/REPORT.md
echo "== Report: build/e2e/REPORT.md =="
