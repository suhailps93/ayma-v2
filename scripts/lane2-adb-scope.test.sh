#!/usr/bin/env bash
# Focused regression test for lane2-adb-scope.c (the Lane 2 adb-scope shim).
#
# Verifies, without touching any attached device:
#   1. `adb -e` exec'd from a shim-loaded parent is rewritten to
#      `-s $LANE2_ADB_SERIAL` (fake serial -> 'device not found', exit != 0).
#   2. Non -e invocations pass through byte-identical (devices, version).
#   3. An explicit -s is never rewritten, even with -e also present.
#
# Safe to run while Lane 1 (emulator-5554) is up: every adb call either
# targets a nonexistent serial or is a read-only local query.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}/platform-tools/adb"
FAKE="emulator-5599"   # nonexistent by construction (even + in scan range)
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

command -v gcc >/dev/null || { echo "SKIP: gcc not available"; exit 2; }
[[ -x "$ADB" ]] || { echo "SKIP: adb not found at $ADB"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gcc -shared -fPIC -O2 -Wall -Wextra -o "$TMP/scope.so" "$SCRIPT_DIR/lane2-adb-scope.c" -ldl \
  || { fail "shim does not compile"; exit 1; }
pass "shim compiles clean"

# 1. -e rewritten to the fake serial: must fail 'not found', touching nothing.
out="$(LD_PRELOAD="$TMP/scope.so" LANE2_ADB_SERIAL="$FAKE" \
  bash -c 'exec "$0" -e shell echo SCOPE_PROBE' "$ADB" 2>&1)"
[[ "$out" == *"device '$FAKE' not found"* ]] \
  && pass "-e rewritten to -s $FAKE (no device touched)" \
  || fail "-e not rewritten (got: $out)"

# 2a. `adb devices` passes through under the shim.
LD_PRELOAD="$TMP/scope.so" bash -c 'exec "$0" devices' "$ADB" >/dev/null 2>&1 \
  && pass "adb devices passes through" \
  || fail "adb devices broken under shim"

# 2b. `adb version` passes through under the shim.
out="$(LD_PRELOAD="$TMP/scope.so" bash -c 'exec "$0" version' "$ADB" 2>&1)"
[[ "$out" == *"Android Debug Bridge"* ]] \
  && pass "adb version passes through" \
  || fail "adb version broken under shim (got: $out)"

# 3. Explicit -s is preserved even when -e is also present (stock adb gives
# -s precedence; we must not alter that call at all).
out="$(LD_PRELOAD="$TMP/scope.so" LANE2_ADB_SERIAL="$FAKE" \
  bash -c 'exec "$0" -s '"$FAKE"' -e shell echo MIXED' "$ADB" 2>&1)"
[[ "$out" == *"device '$FAKE' not found"* ]] \
  && pass "explicit -s preserved alongside -e" \
  || fail "explicit -s call altered (got: $out)"

# 4. The launcher at least parses and answers --help.
bash -n "$SCRIPT_DIR/boot-lane2b.sh" \
  && pass "boot-lane2b.sh parses" \
  || fail "boot-lane2b.sh has a syntax error"
"$SCRIPT_DIR/boot-lane2b.sh" --help >/dev/null 2>&1 \
  && pass "boot-lane2b.sh --help works" \
  || fail "boot-lane2b.sh --help fails"

exit $FAIL
