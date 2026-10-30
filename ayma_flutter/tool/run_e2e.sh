#!/usr/bin/env bash
# One-command E2E harness: runs the suite on a real device against the live
# backend, streams `E2E_RESULT` markers, captures a real-pixel screenshot per
# behaviour via host-side `adb screencap` (triggered by `E2E_SHOT` markers),
# and assembles build/e2e/REPORT.md. Usage: tool/run_e2e.sh [device]
set -uo pipefail
DEVICE="${1:-emulator-5554}"
cd "$(dirname "$0")/.."   # -> ayma_flutter

rm -rf build/e2e
mkdir -p build/e2e/screenshots
LOG=build/e2e/run.log
: > "$LOG"

# Pre-grant notification permission so Android 13+'s system permission dialog
# never pops over the app mid-run (it obscures screenshots and can absorb taps).
# No-op on the very first install where the package isn't present yet.
adb -s "$DEVICE" shell pm grant com.ayma.ayma_flutter \
  android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# Background: watch the log; on each `E2E_SHOT <name>` grab the current screen.
(
  tail -n +1 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    name=$(printf '%s\n' "$line" | sed -n 's/.*E2E_SHOT \([A-Za-z0-9_]\{1,\}\).*/\1/p')
    if [ -n "$name" ]; then
      adb -s "$DEVICE" exec-out screencap -p > "build/e2e/screenshots/$name.png" 2>/dev/null
    fi
  done
) &
MON=$!

echo "== E2E harness on $DEVICE =="
flutter test integration_test/e2e_behaviors_test.dart \
  -d "$DEVICE" --dart-define=E2E_SHOTS=true 2>&1 | tee -a "$LOG"

sleep 2
kill "$MON" 2>/dev/null

python3 tool/e2e_report.py "$LOG" build/e2e/screenshots build/e2e/REPORT.md
echo "== Report: build/e2e/REPORT.md =="
