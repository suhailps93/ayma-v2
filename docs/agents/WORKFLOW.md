# Fleet agent workflow

Rules every Ayma agent inherits, regardless of which tool or model is driving.
Read alongside `AGENTS.md` (engineering rules) and `docs/AGENT_HANDOFF.md`
(runbooks, orchestration, current state).

## VERIFY-BEFORE-FIX (founder standing rule, 2026-10-31)

**No agent fixes a reported issue blind.** Before writing any fix for a reported
bug:

1. **Read the code and confirm the issue exists as reported.** Trace the actual
   code path for the reported behaviour — the screen/flow, the widget/handler,
   the backend call — not just the symptom. Confirm, from the code, that the
   thing is really missing or really broken.
2. **If the code contradicts the report, STOP — do not fix.** Report back that
   the code does not match the report, with the evidence (file + lines + what
   the code actually does), and **correct the report instead.** A "fix" for a
   bug that does not exist is pure regression risk and wasted work.
3. **Only when the code confirms something is actually missing or broken** do you
   proceed to fix — and then under the usual standing rules: reproduce the
   founder's exact path in a regression test (every bug gets a regression test),
   update docs + the architecture diagram, delete stale code, keep the Flutter
   layout matrix green, add/refresh the feature-tour entry, and review the diff
   before merge.
4. This applies to **every** tester/bug report, including the ones relayed
   through the Astro testing loop below.

**Why:** tester reports can be wrong — a feature exists but wasn't found, the
tester was on the wrong build, or the path was mis-remembered. Blind fixes to
phantom bugs introduce real regressions and churn. Confirming against the code
first keeps both the code and the report honest.

## The tester-bug loop

Astro (Muse) owns app testing on the emulator; the fleet builds and fixes.
Astro files each code bug as:

```
BUG <run>-<test-id> [S1/S2/S3] · Build · Test · Expected · Actual · Repro + account · Evidence
```

The fixing agent **VERIFIES first** (above), then either (a) corrects the report
when the code contradicts it, or (b) ships the fix commit referencing the bug
id. Astro retests on the fix build → CLOSED or reopen with fresh evidence.
Ops-side problems (test/seed data, emulator, build conversion, installs, config)
Astro fixes itself.

## Testing sweep documentation lives in the repo (founder standing rule, 2026-10-31)

Every testing sweep is documented in the repo under **`docs/testing/`**, one new
file per sweep — never overwrite a previous sweep.

- **One `.md` per sweep**, named with the **version+build** and the **date**:
  `<version>-<build>_<YYYY-MM-DD>.md` — e.g. `1.30.0-2242_2026-10-31.md`.
- **Screenshots** for that sweep are committed **alongside it, in a matching
  folder** of the same base name: `docs/testing/<version>-<build>_<YYYY-MM-DD>/`.
  The sweep `.md` references its screenshots by relative path into that folder.
- If two sweeps share a build **and** date, suffix the second with `_run<N>`
  (e.g. `…_2026-10-31_run2.md`) so nothing is ever overwritten.
- **Security coverage stays extensive** — the founder specifically values it.
  Keep the Security section of every sweep as thorough as the pack allows
  (privacy/PII extraction, auth, consent/18+, abuse/jailbreak, injection,
  payment/entitlement gating); never trim it to save space.

`docs/testing/PROGRESS.md` is a living build-over-build matrix (one row per test,
one column per build, cells 🟢/🔴/🟡/⚪). Each new build adds a right-hand column;
the tester owns the dots, and `PROGRESS.md` is committed alongside the per-sweep
files whenever a sweep lands.

This mirrors the **Standard Emulator Test Pack** (Astro's pack): the pack carries
the same convention so each run it produces maps to exactly one repo sweep file +
folder. See `docs/testing/README.md`.
