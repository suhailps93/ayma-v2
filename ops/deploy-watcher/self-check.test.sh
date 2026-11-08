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

exit "$fail"
