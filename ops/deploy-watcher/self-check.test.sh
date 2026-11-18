#!/usr/bin/env bash
# Regression tests for the watcher: APK self-check + cycle-lock lifecycle.
# Run: bash ops/deploy-watcher/self-check.test.sh
# Fails if apk_verifies_staging() misses a present staging project number
# (the strings|grep -q + pipefail SIGPIPE bug) or matches an absent one,
# or if with_cycle_lock() lets two holders run concurrently or leaks the
# lock fd to a daemonizing child (the adb fork-server wedge).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/staging-autodeploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Match near the start + a large tail so a grep -q pipeline SIGPIPEs (the bug).
printf 'pkg 1:187469876115:android end\n' > "$TMP/staging.apk"
head -c 2000000 /dev/urandom >> "$TMP/staging.apk"
printf 'pkg 1:235381544962:android end\n' > "$TMP/prod.apk"
head -c 2000000 /dev/urandom >> "$TMP/prod.apk"
# An APK contaminated with both staging and prod must be rejected.
printf 'pkg 1:187469876115:android and 1:235381544962:android end\n' > "$TMP/hybrid.apk"
head -c 2000000 /dev/urandom >> "$TMP/hybrid.apk"

fail=0
if apk_verifies_staging "$TMP/staging.apk"; then
  echo "PASS: staging APK verifies"
else
  echo "FAIL: staging APK did not verify"; fail=1
fi
if apk_verifies_staging "$TMP/prod.apk"; then
  echo "FAIL: prod APK verified (should not)"; fail=1
else
  echo "PASS: prod APK rejected"
fi
if apk_verifies_staging "$TMP/hybrid.apk"; then
  echo "FAIL: hybrid APK verified (should not)"; fail=1
else
  echo "PASS: hybrid APK rejected"
fi

# --- cycle-lock lifecycle (with_cycle_lock uses $STATE; point it at TMP) --- #
STATE="$TMP/lockstate"
mkdir -p "$STATE"
LOCK="$STATE/cycle.lock"

# 1. Serialization: a second holder must fail with 99 while one runs.
with_cycle_lock sleep 3 &
holder_pid=$!
sleep 0.5
if with_cycle_lock true; then
  echo "FAIL: concurrent lock holder acquired (want blocked)"; fail=1
else
  rc=$?
  if (( rc == 99 )); then
    echo "PASS: concurrent cycle blocked (rc=99)"
  else
    echo "FAIL: concurrent lock failed with rc=$rc (want 99)"; fail=1
  fi
fi
wait "$holder_pid"
if with_cycle_lock true; then
  echo "PASS: lock free after holder exits"
else
  echo "FAIL: lock still held after holder exits (rc=$?)"; fail=1
fi

# 2. The locked command itself must not inherit the lock fd.
if with_cycle_lock bash -c 'ls -l /proc/$$/fd 2>/dev/null | grep -q cycle.lock'; then
  echo "FAIL: locked command inherited cycle.lock fd"; fail=1
else
  echo "PASS: locked command has no cycle.lock fd"
fi

# 3. A daemonizing child (setsid, like adb fork-server) must not hold the
# lock after the cycle ends: the daemon survives, but the lock is free.
cat > "$TMP/daemon-body.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$TMP/daemon.pid"
exec sleep 30
EOF
chmod +x "$TMP/daemon-body.sh"
cat > "$TMP/spawn-daemon.sh" <<EOF
#!/usr/bin/env bash
setsid bash "$TMP/daemon-body.sh" < /dev/null > /dev/null 2>&1 &
sleep 0.5
EOF
chmod +x "$TMP/spawn-daemon.sh"
rm -f "$TMP/daemon.pid"
with_cycle_lock bash "$TMP/spawn-daemon.sh"
daemon_pid="$(cat "$TMP/daemon.pid" 2>/dev/null || true)"
if [[ -z "${daemon_pid:-}" ]] || ! kill -0 "$daemon_pid" 2>/dev/null; then
  echo "FAIL: daemon did not survive test setup (pid='${daemon_pid:-empty}')"; fail=1
else
  if ls -l "/proc/$daemon_pid/fd" 2>/dev/null | grep -q cycle.lock; then
    echo "FAIL: surviving daemon holds cycle.lock fd (pid=$daemon_pid)"; fail=1
  else
    echo "PASS: surviving daemon (pid=$daemon_pid) has no cycle.lock fd"
  fi
  if fuser "$LOCK" >/dev/null 2>&1; then
    echo "FAIL: fuser still shows a holder on cycle.lock: $(fuser "$LOCK" 2>&1)"; fail=1
  else
    echo "PASS: fuser shows cycle.lock free after cycle exit"
  fi
  if with_cycle_lock true; then
    echo "PASS: next cycle starts instead of skipping"
  else
    echo "FAIL: next cycle blocked after daemonized child (rc=$?)"; fail=1
  fi
  kill "$daemon_pid" 2>/dev/null || true
fi

# 4. Real adb fork-server (isolated port; skipped when adb is absent).
if command -v adb >/dev/null 2>&1; then
  TEST_ADB_PORT=5599
  adb -P "$TEST_ADB_PORT" kill-server >/dev/null 2>&1 || true
  sleep 0.5
  with_cycle_lock adb -P "$TEST_ADB_PORT" start-server >/dev/null 2>&1 || true
  sleep 0.5
  if fuser "$LOCK" >/dev/null 2>&1; then
    echo "FAIL: adb fork-server holds cycle.lock: $(fuser "$LOCK" 2>&1)"; fail=1
  else
    echo "PASS: cycle.lock free while adb fork-server survives"
  fi
  if with_cycle_lock true; then
    echo "PASS: next cycle starts despite running adb server"
  else
    echo "FAIL: next cycle blocked by adb server (rc=$?)"; fail=1
  fi
  adb -P "$TEST_ADB_PORT" kill-server >/dev/null 2>&1 || true
else
  echo "SKIP: adb not installed (setsid test above covers the leak)"
fi

# --- whats_different(): a founder-ordered merged branch is NAMED, never "internal" --- #
# Regression for the 2507/2508/2509 mislabelling: a branch whose own commit
# subject lacks a feat:/fix: prefix must still be named by its merged branch,
# not counted as "internal fixes / housekeeping".
WREPO="$TMP/wrepo"
mkdir -p "$WREPO"
git -C "$WREPO" init -q
git -C "$WREPO" config user.email t@example.com
git -C "$WREPO" config user.name tester
git -C "$WREPO" commit -q --allow-empty -m base
STAGE="$(git -C "$WREPO" branch --show-current)"
BASE="$(git -C "$WREPO" rev-parse HEAD)"
# a founder-ordered feature whose commit subject has NO conventional prefix
git -C "$WREPO" branch fleet/looking-for-icons
git -C "$WREPO" checkout -q fleet/looking-for-icons
git -C "$WREPO" commit -q --allow-empty -m "What-I-am-Looking-For standard fields render fixed icon + label:value"
git -C "$WREPO" checkout -q "$STAGE"
git -C "$WREPO" merge -q --no-ff -m "Merge fleet/looking-for-icons into staging (batch 2508)" fleet/looking-for-icons
git -C "$WREPO" commit -q --allow-empty -m "Bump versionCode 2507 to 2508 for batch 2508"
NEW="$(git -C "$WREPO" rev-parse HEAD)"
WT="$WREPO"
wd_out="$(whats_different "$BASE..$NEW")"
if echo "$wd_out" | grep -qiE 'Internal fixes'; then
  echo "FAIL: founder-ordered merge rendered as 'Internal fixes': $wd_out"; fail=1
elif echo "$wd_out" | grep -qi 'Looking For Icons'; then
  echo "PASS: founder-ordered merge named as its feature (not internal)"
else
  echo "FAIL: founder feature not named at all: $wd_out"; fail=1
fi
if echo "$wd_out" | grep -qE 'versionCode 2508'; then
  echo "PASS: versionCode bump bullet still present"
else
  echo "FAIL: versionCode bump bullet missing: $wd_out"; fail=1
fi
# a git-default merge subject (manual merge, no ": summary") is still named by branch
git -C "$WREPO" branch fleet/mid-session-signout
git -C "$WREPO" checkout -q fleet/mid-session-signout
git -C "$WREPO" commit -q --allow-empty -m "persist session through transient 401"
git -C "$WREPO" checkout -q "$STAGE"
MB="$(git -C "$WREPO" rev-parse HEAD)"
git -C "$WREPO" merge -q --no-ff -m "Merge remote-tracking branch 'origin/fleet/mid-session-signout' into staging" fleet/mid-session-signout
MN="$(git -C "$WREPO" rev-parse HEAD)"
wd_out2="$(whats_different "$MB..$MN")"
if echo "$wd_out2" | grep -qiE 'Internal fixes'; then
  echo "FAIL: manual-merge (git-default subject) rendered as internal: $wd_out2"; fail=1
elif echo "$wd_out2" | grep -qi 'Mid Session Signout'; then
  echo "PASS: manual-merge named by its branch (not internal)"
else
  echo "FAIL: manual-merge branch not named: $wd_out2"; fail=1
fi
# a bump-only range with NO merge still falls back cleanly (no spurious feature)
git -C "$WREPO" commit -q --allow-empty -m "Bump versionCode 2508 to 2509 for batch 2509"
BO="$(git -C "$WREPO" rev-parse HEAD)"
wd_out3="$(whats_different "$MN..$BO")"
if echo "$wd_out3" | grep -qE 'versionCode 2509'; then
  echo "PASS: bump-only range (no merge) still emits the build bullet"
else
  echo "FAIL: bump-only range lost its build bullet: $wd_out3"; fail=1
fi

exit "$fail"
