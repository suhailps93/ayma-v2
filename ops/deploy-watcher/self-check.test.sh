#!/usr/bin/env bash
# Regression test for the watcher's post-build APK self-check.
# Run: bash ops/deploy-watcher/self-check.test.sh
# Fails if apk_verifies_staging() misses a present staging project number
# (the strings|grep -q + pipefail SIGPIPE bug) or matches an absent one.
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
exit "$fail"
