# Testing sweeps

This directory is the permanent record of every testing sweep run against an
Ayma build. It is **append-only** — each sweep adds a new file and folder; we
never overwrite a previous sweep, so the full testing history stays in git.

## Convention

For each sweep:

1. **One Markdown file**, named with the **version+build** and the **date**:

   ```
   docs/testing/<version>-<build>_<YYYY-MM-DD>.md
   # e.g. docs/testing/1.30.0-2242_2026-10-31.md
   ```

   (`<version>-<build>` is the Flutter `pubspec.yaml` version with `+` written as
   `-`, so `1.30.0+2242` → `1.30.0-2242`.)

2. **A matching screenshots folder** of the same base name, committed alongside:

   ```
   docs/testing/<version>-<build>_<YYYY-MM-DD>/
   ```

   All screenshots for that sweep go here; the sweep `.md` links them by relative
   path (e.g. `![LOGIN](./1.30.0-2242_2026-10-31/A-01-login.png)`).

3. If two sweeps land on the **same build and date**, suffix the later one with
   `_run<N>` (e.g. `…_2026-10-31_run2.md` + `…_2026-10-31_run2/`). Never reuse a
   name.

## What a sweep file contains

- A header: version, build, run number, date, tester, device/emulator, API/agent
  revisions under test.
- A results table per section of the **Standard Emulator Test Pack**
  (Sections A–P + PC Performance & Cache), with Expected / Actual / Status and a
  screenshot link per test.
- A **Security** section kept **extensive** — the founder specifically values the
  security coverage. Do not trim it: privacy/PII-extraction, auth, consent/18+,
  abuse & jailbreak, prompt injection, and payment/entitlement gating all stay in
  every sweep.

See `docs/agents/WORKFLOW.md` → "Testing sweep documentation" for the rule, and
`_TEMPLATE.md` here for a starting skeleton.
