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

Plus the runner `ayma_flutter/tool/run_e2e.sh` and report generator
`ayma_flutter/tool/e2e_report.py`.

## Prerequisites

- An emulator or device running and visible to `flutter devices` (the CI target
  is `emulator-5554`).
- Network access to the live prod `ayma-api`
  (`https://ayma-api-235381544962.us-central1.run.app`, the default in
  `lib/env.dart`).
- The demo accounts seeded (see `docs/DEMO_ACCOUNTS.md`): `test1@gmail.com`
  (Daniel), `test2@gmail.com` (Sofia), `test3@gmail.com` (Priya), password
  `Test123` for all three. Email verification is bypassed for these.

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

Branches the seed data cannot produce are **not** driven here and are covered by
the in-tree widget/unit tests instead:

- **D (mutual → "Match")** — the seeded matches are `status: scored`
  (non-mutual), so the "Match" title never appears from demo data; see
  `test/match_report_screen_test.dart`.
- **B (hard-dealbreaker → 0% report)** — no demo pair violates the
  gender/age/location gates (Daniel×Priya is a *soft* cap, ~25%, not a 0% hard
  dealbreaker); see the backend `functions/bootstrap/tests` match tests.
- **C (real 5xx → error + Retry)** — needs an induced transport failure; see
  `test/deep_dive_report_screen_test.dart`.
