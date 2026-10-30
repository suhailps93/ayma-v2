# End-to-end integration harness

A repeatable, autonomous regression harness that drives the **real app on a
real device/emulator against the live backend** — no AI vision, no paid APIs.
It exists to catch regressions in the 8 behaviours shipped in build **2237**
(bugs B/C/D/E/F/G/H/P).

Suite lives in `ayma_flutter/integration_test/`:

| File | What it does |
|------|--------------|
| `helpers.dart` | Shared login + navigation + screenshot + error-draining helpers (no tests). |
| `smoke_login_test.dart` | Boots the app, signs in as Daniel, confirms the main shell + Explore feed load. Run this first to confirm the device/backend are healthy. |
| `e2e_behaviors_test.dart` | The 8-behaviour regression run (signed in as Sofia). Streams a result marker per behaviour and prints a PASS/FAIL table; fails the run if any behaviour regressed. |
| `e2e_edge_test.dart` | Corner cases against the seeded `demo-edge-*` fixtures (signed in as Daniel): matching gate exclusions, 0-photo profile, 0% hard-dealbreaker report, mutual "Match" title. |
| `e2e_auth_test.dart` | Signed-out boot lands on the sign-in / welcome screen. |
| `e2e_net_test.dart` | Offline splash + recovery, driven host-side via `adb svc wifi/data` (only meaningful under `run_e2e.sh`; self-skips standalone). |

Plus the runner `ayma_flutter/tool/run_e2e.sh` and report generator
`ayma_flutter/tool/e2e_report.py`, and the fixture seed
`scripts/seed_demo_edge_accounts.py`.

## Prerequisites

- An emulator or device running and visible to `flutter devices` (the CI target
  is `emulator-5554`).
- Network access to the live prod `ayma-api`
  (`https://ayma-api-235381544962.us-central1.run.app`, the default in
  `lib/env.dart`).
- The demo accounts seeded (see `docs/DEMO_ACCOUNTS.md`): `test1@gmail.com`
  (Daniel), `test2@gmail.com` (Sofia), `test3@gmail.com` (Priya), password
  `Test123` for all three. Email verification is bypassed for these.
- The corner-case fixtures seeded (for `e2e_edge_test.dart`), idempotent and
  reversible, against live Firestore with ADC (`gcloud auth
  application-default login`):

  ```bash
  python3 scripts/seed_demo_edge_accounts.py          # create / update
  python3 scripts/seed_demo_edge_accounts.py --reset  # wipe demo-edge-* + rebuild
  ```

  These are six `demo-edge-*` profiles Daniel views: a 0-photo valid account, an
  age-at-floor pass, and four hard-dealbreaker fails (age-over-max, one-sided
  orientation, out-of-radius location) plus a mutual-like pair.

## Test-fixture hiding + the E2E bypass (contract for the GATES test)

**Background (founder, 2026-10-29).** The `demo-edge-*` fixtures were leaking
into *real users'* Explore once the dealbreaker fix made Explore show (not hide)
dealbreaker profiles. The backend now hides every seeded test fixture from real
users' Explore: `seed_demo_edge_accounts.py` flags each account with
`exclude_from_explore: true` on its `users/{uid}` doc, and
`functions/bootstrap/explore.py` (`_is_test_fixture`) drops any user carrying
that flag — with the `demo-edge-` uid prefix as a secondary safety net. The
curated demo set `demo-test1/2/3` (Daniel/Sofia/Priya) carries **no** flag and
stays visible. Already-seeded live fixtures were tagged by
`scripts/backfill_fixture_exclude_flag.py` (idempotent; `--revert` untags).

**Why the E2E suite still works — the viewer bypass.** Fixture-hiding is
disabled when the **viewer's own uid** is in `config.explore_fixture_bypass_uids`
(env `EXPLORE_FIXTURE_BYPASS_UIDS`, default `demo-test1,demo-test2,demo-test3`).
`e2e_edge_test.dart` signs in as **Daniel (`demo-test1`)**, who is in that set,
so **all six `demo-edge-*` fixtures remain visible to that viewer** — GATES,
NOPHOTO, ZERO and MATCH are unaffected by the real-user hiding. A real user is
never in the set, so they never see fixtures.

**What the GATES test must assert.** Because the viewer (Daniel) bypasses
fixture-hiding, GATES tests the *matching gate*, not the fixture filter: against
Daniel's Explore it asserts the **valid** edges appear (`demo-edge-nophoto`,
`demo-edge-agemin`, `demo-edge-mutual`) and, per the current dealbreaker product
rule (§5.4 / §6.1 — dealbreaker profiles are shown with a 0% report, not
hidden), the **hard-dealbreaker** edges (`demo-edge-ageover`,
`demo-edge-orient`, `demo-edge-locout`) **also appear** (their gate surfaces as a
0% report, verified by ZERO — not as absence from Explore). The e2e agent owns
this assertion; the real-user hiding is covered separately by the backend
regression test `functions/bootstrap/tests/test_explore_hides_fixtures.py`.

**Deploy requirement.** The deployed `ayma-api` must keep `demo-test1` in
`EXPLORE_FIXTURE_BYPASS_UIDS` (it is the default, so no env override is needed
unless the var is set explicitly).

## Running

One command — runs the suite, captures a screenshot per behaviour and writes
the report:

```bash
cd ayma_flutter
tool/run_e2e.sh                 # defaults to emulator-5554
tool/run_e2e.sh emulator-5554   # or name the device
```

This produces, under `ayma_flutter/build/e2e/`:

- `REPORT.md` — a PASS/FAIL table plus one section per behaviour with its
  detail string and the embedded screenshot (the end-of-run artifact).
- `screenshots/<bug>.png` — a real-pixel screenshot at each behaviour's key
  moment.
- `run.log` — the full console output.

Or run the raw tests directly (no screenshots/report):

```bash
# Health check (login + Explore load).
flutter test integration_test/smoke_login_test.dart -d emulator-5554

# Full regression.
flutter test integration_test/e2e_behaviors_test.dart -d emulator-5554
```

### Live streaming + the report

Results **stream as they resolve**: the instant a behaviour's assertion
settles, the harness flushes one line to stdout —
`E2E_RESULT <bug> PASS|FAIL <detail>` — so a `tail -f build/e2e/run.log | grep
E2E_RESULT` watches verdicts live instead of waiting for the end. A failing
behaviour's line carries the expected-vs-actual so the real bug can be routed
to a fix immediately. An end-of-run PASS/FAIL table is also printed, bracketed
by `===== 2237 E2E PASS/FAIL =====`.

Screenshots use a host-side trigger, not Flutter's `convertFlutterSurfaceToImage`
(which froze interaction and hung the run): the test prints `E2E_SHOT <name>`
and holds the frame ~1.5s; `run_e2e.sh` tails the log and runs
`adb exec-out screencap` on each marker (gated by `--dart-define=E2E_SHOTS=true`,
which the runner sets — plain `flutter test` leaves `shot()` a no-op).

The first run builds a debug APK (several minutes); later runs are faster.

## How it works (and its constraints)

- The app is booted **once** per file via `app.main()` — calling it twice
  re-initialises Firebase and throws, so all behaviours in
  `e2e_behaviors_test.dart` run in a single `testWidgets` body in sequence.
- Many screens host the always-animating `AymaOrb`, so `pumpAndSettle()` never
  settles. Every wait is a bounded `pumpUntil` / `pumpFor` loop instead.
- `app.main()` installs its own `FlutterError.onError` (Crashlytics/Sentry),
  which the integration-test binding must own. `bootApp()` restores the
  binding's handler after boot, and `drainBenignErrors()` clears known-benign
  async noise (e.g. the pre-sign-in welcome `VoiceSessionController` notifying
  after dispose) at checkpoints — any **unexpected** exception is rethrown and
  still fails the run.
- Login is driven through the real sign-in UI (two consent checkboxes → "Email"
  → credentials → "Sign in").

## What is / isn't covered end-to-end

Signed in as **Sofia (test2)**, the demo data lets one session exercise:

- **B** (orientation gating) — Explore includes Daniel (valid man) and excludes
  Priya (same-gender, orientation-gated).
- **E** — practice persona ("Maya") absent from Explore.
- **H** — opening Daniel's report shows the full dimension breakdown.
- **D** — that non-mutual report's AppBar reads "Compatibility" (not "Match").
- **P** — the report's "Send to a user" picker shows a search field, per-row
  Send buttons, photo avatars and matched-users-first.
- **G** — the taste card shows a "You both listed" section grounded in
  both-stated entities.
- **F** — re-opening the report paints from cache; Recalculate forces a
  recompute.
- **C** — routing to a never-researched subject shows "No web research yet" +
  "Run report" (not the error state).

The corner cases the three complete demo accounts can't express are driven
against the seeded `demo-edge-*` fixtures (signed in as Daniel), in
`e2e_edge_test.dart`:

- **GATES** — against Daniel's Explore (Daniel bypasses fixture-hiding; see
  "Test-fixture hiding + the E2E bypass"), the valid edges appear
  (`demo-edge-nophoto`, `demo-edge-agemin`, `demo-edge-mutual`) and, per the
  current dealbreaker rule (§5.4/§6.1), the hard-dealbreaker edges
  (`demo-edge-ageover`, `demo-edge-orient`, `demo-edge-locout`) **also** appear
  (their gate surfaces as a 0% report, see ZERO — not as absence from Explore).
- **NOPHOTO** — a 0-photo but valid profile appears in Explore and its report
  opens (distinct from the practice-persona exclusion).
- **ZERO** — a hard-dealbreaker pair's report scores 0% (bug B's 0% path).
- **MATCH** — a mutual-like pair's report AppBar reads "Match" (bug D's mutual
  path, which `status: scored` demo data can't show).

And signed-out / offline:

- **AUTH** — signed-out boot lands on the sign-in / welcome screen
  (`e2e_auth_test.dart`).
- **OFFLINE / RECOVER** — the splash's "Couldn't connect" + Retry state and its
  connectivity-return recovery, driven host-side by toggling the device radios
  with `adb svc wifi/data` (`e2e_net_test.dart`, only under `run_e2e.sh`).

### Known boundaries

- **Preboarding / onboarding step-through** — reaching the interview flow needs a
  not-yet-onboarded account; the welcome/auth entry is covered (AUTH), but
  driving the multi-step preboarding itself is a follow-up (it would create and
  mutate throwaway accounts on every run).
- **Generic backend 5xx error banner** — the clean 404 "never run" path is
  covered (C); a forced 5xx would need an app seam or a dead base URL, so it is
  left to `test/deep_dive_report_screen_test.dart`.
