# End-to-end integration harness

A repeatable, autonomous regression harness that drives the **real app on a
real device/emulator against the live backend** — no AI vision, no paid APIs.
It exists to catch regressions in the 8 behaviours shipped in build **2237**
(bugs B/C/D/E/F/G/H).

Suite lives in `ayma_flutter/integration_test/`:

| File | What it does |
|------|--------------|
| `helpers.dart` | Shared login + navigation + error-draining helpers (no tests). |
| `smoke_login_test.dart` | Boots the app, signs in as Daniel, confirms the main shell + Explore feed load. Run this first to confirm the device/backend are healthy. |
| `e2e_behaviors_test.dart` | The 8-behaviour regression run (signed in as Sofia). Records a PASS/FAIL line per behaviour, prints a table, and fails if any behaviour regressed. |

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

```bash
cd ayma_flutter

# 1. Health check (login + Explore load).
flutter test integration_test/smoke_login_test.dart -d emulator-5554

# 2. Full 8-behaviour regression.
flutter test integration_test/e2e_behaviors_test.dart -d emulator-5554
```

The PASS/FAIL table is printed to the test console, bracketed by
`===== 2237 E2E PASS/FAIL =====`. A failing behaviour prints `FAIL — <detail>`
with the expected-vs-actual so a regression can be routed to a fix immediately.

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
