# Handoff: sentry-triage (Nov 2 Sentry census — verify + fix-prep)

**Branch**: `muse/sentry-triage` (base: `origin/staging`; never touched `main`; no deploys)
**Worktree**: `/home/suhailps/workspace/ayma/.fleet-worktrees/sentry-triage`
**Author**: Muse (Engineer — Deployment), 2026-11-02
**Assignment**: Astro PM chunk per founder directive 2026-11-02 08:37 PT
(Sentry issues get assigned and FIXED, not just reported)

## Step 1 — Sentry read access: BLOCKED

Checked GCP Secret Manager (`ayma-ai` project): the only Sentry-related
secrets are `SENTRY_DSN_AGENT`, `SENTRY_DSN_API`, `SENTRY_DSN_FLUTTER`
(DSNs send events; they cannot read the issue API). **No
`SENTRY_AUTH_TOKEN` (or equivalent read token) exists.** Names only were
listed; no secret value was printed or committed.

Gap for the founder/PM: create a Sentry internal-integration (or user
auth) token with `project:read` on org `ayma` and store it as
`SENTRY_AUTH_TOKEN` in Secret Manager, or hand triage agents the raw
issue JSON. All verdicts below marked "needs stack" are blocked on this.

Without the API, verification was done code-side against Astro's Nov 2
email census (~201 alert emails since Oct 25).

## Verdicts at a glance

| Sentry ID | Verdict | Disposition |
|---|---|---|
| AYMA-FLUTTER-31 | real | FIXED on branch (`8505095`) |
| AYMA-API-B | already-fixed | no action (`01dc39d` on staging) |
| AYMA-FLUTTER 2W/2X/2Y/2C/28/29 | likely already-fixed | confirm in Sentry once readable (`bdf223a` on staging) |
| AYMA-FLUTTER-30, -2V | real, needs stack | filed below for Claude |
| AYMA-FLUTTER-2Z | real, needs stack | filed below for Claude |
| AYMA-FLUTTER-2B | real, needs stack | filed below for Claude (auth/session — excluded from fix) |
| AYMA-FLUTTER-2Q | real | FIXED on branch (`2125b03`) |
| AYMA-AGENT-V | real, needs stack | filed below for Claude (agent/LiveKit — excluded from fix) |

Gateway-429 family (AYMA-AGENT-18, AYMA-API-E, AYMA-API-F, AYMA-AGENT-14):
excluded per brief — drained free-tier LiveKit gateway on staging,
expected state, not app bugs. Not fixed, not filed.

Oct 29 triage dedupe (by error string — no stacks available): none of the
8 candidates matches the Oct 29 clusters (agent Inference 400
"messages must contain at least one message with role user or tool", STT
inference errors, `!semantics.parentDataDirty`, viewport null-check, api
`TokenCapExceeded` on `/dm/assist`). Possible exception: the Nov 1
assertion cluster *could* overlap the Oct 29 semantics/viewport asserts —
confirm by stack once Sentry is readable.

## Fixed on this branch

### AYMA-FLUTTER-31 — FIXED (`8505095`)

"A VoiceSessionController was used after being disposed" (Nov 2 06:15 PT).
Two real gaps, both verified:

1. `dispose()`'s synchronous pre-cancel list missed `_callEndingSub` and
   `_agentMuteSub` — both listeners reach `notifyListeners()`
   (`_onCallEnding` → `_fail`; the agent-mute closure). A queued event in
   the gap before `_teardown()`'s async cancels ran threw.
2. Async `_attempt()` continuations (e.g. the token fetch resolving after
   the owning screen disposed the controller) called `_fail` →
   `notifyListeners()` post-dispose.

Fix (`ayma_flutter/lib/services/voice_session_controller.dart`): added
the two missing cancels, plus a `_disposed` flag with a `notifyListeners`
override that no-ops after disposal (matches release behaviour, where the
disposed check is a stripped assert, on every build). No LiveKit-behaviour
change — pure ChangeNotifier lifecycle.

Tests (`ayma_flutter/test/voice_session_controller_test.dart`, using the
existing `FakeVoiceTransport`): "late transport events after dispose()
never throw" and "disposing mid-bootstrap never throws when the token
lands". Both failed pre-fix with the exact Sentry error; full file green
post-fix (53/53). `flutter analyze` clean.

### AYMA-FLUTTER-2Q — FIXED (`2125b03`)

FlutterError "setState() callback argument returned a Future". Root cause:
`setState(() => _future = <load Future>)` — the arrow closure returns the
assigned Future from the callback, and Flutter's setState asserts on that
in debug builds (all staging APKs are debug builds, so Sentry captures
it). 8 sites in 6 files, all converted to block closures:

- `lib/screens/admin_feedback_screen.dart` (`_refresh`)
- `lib/screens/complete_profile_screen.dart` (manual Retry + `_reload`;
  `_reload` assigned a pre-fetched `next` Future — same defect)
- `lib/screens/match_report_screen.dart` (manual Retry + recalc refresh)
- `lib/screens/matches_screen.dart` (Retry button)
- `lib/screens/physical_attributes_report_screen.dart` (`_reload`)
- `lib/screens/public_profile_screen.dart` (manual Retry + post-recalc
  refresh in `_onRecalcChanged`)

Sweep-verified: every remaining `setState(() => _x = ...)` in `lib/` has a
non-Future RHS (`File(...)`, `trim()`, `copyWith`, `withHidden`,
`withHue`, `fromColor`) and cannot throw this. No `setState(() async`
anywhere.

Tests: new regression test in
`test/physical_attributes_report_screen_test.dart` (failed load → tap
Retry → success; asserts `takeException()` is null and the report
renders). Failed pre-fix with the exact Sentry error; passes post-fix.
All 5 affected screen test files green (61/61). `flutter analyze` clean.

### AYMA-API-B — already-fixed, no commit

"'hidden_photos' is not contained in the data" (Nov 2 00:08 PT) is the
exact SWEEP59-J3R incident: the appearance-split `_grid_photos` dropped
`.to_dict()`, handing a raw `DocumentSnapshot` to
`schema.analysis_photo_entries`, whose `.get("hidden_photos")` raises on a
snapshot when the field is absent. Fix `01dc39d` ("fix(appearance):
hidden_photos strict-read 502 (SWEEP59-J3R)") landed Nov 2 00:25 PT —
17 minutes AFTER the alert — and is on `origin/staging` (verified via
merge-base). Current code: `_grid_photos` has `.to_dict() or {}` plus a
try/except, and all three production callers of `analysis_photo_entries`
(`appearance_engine._grid_photos`, `physical_attributes`, `photo_attrs`
via dict) pass dicts. Regression test
`test_grid_photos_tolerates_profile_without_hidden_photos` exists. Action:
resolve in Sentry once readable; no code change.

### Assertion cluster 2W / 2X / 2Y / 2C / 28 / 29 — likely already-fixed

Framework.dart + rendering assertions, Nov 1 evening. Matches the J1 root
cause fixed by `bdf223a` (Nov 2 01:52 PT, on staging): warm notification
re-nav `push('/')` stacked a second `MainShellScreen`, duplicating shared
feature-tour anchor GlobalKeys → "Duplicate GlobalKey" (framework.dart) +
"RenderFlex mutated in performLayout" (rendering). Timing fits (alerts
pre-fix, fix after). Action: confirm each of the 6 IDs is resolved in
Sentry once readable; if any ID's stack shows a different assert (e.g. the
Oct 29 `!semantics.parentDataDirty` or viewport null-check), file it as a
new item.

## Filed for Claude (write-ups, not fixed)

### AYMA-FLUTTER-30 and AYMA-FLUTTER-2V — ApiException 408 "Request timed out"

- **Sentry ID**: AYMA-FLUTTER-30, AYMA-FLUTTER-2V
- **Error**: `ApiException: Request timed out — please try again (statusCode 408)`
- **Evidence**: `ApiException(408)` is the *designed* client-side timeout
  signal: `BudgetHttpClient` (`ayma_flutter/lib/services/api_client.dart`,
  `_executeGet`/`post`/`put`/`delete`) converts `TimeoutException` into it
  when an endpoint misses its budget (8s interactive, 55s long). Prior
  art: three separate fixes added slow endpoints to the long-budget list
  (practice, match-report, appearance — see
  `docs/agents/handoffs/perf-phase1-freshness.md` §Chunk 2). So a 408 in
  Sentry means one of: (a) a slow endpoint not yet in `_isLongBudgetPath`
  (new instance of the known defect class — most likely); (b) a genuinely
  down/hung backend or dead network; (c) handled-timeout noise reported via
  `ErrorReporter.report` (e.g. voice `_attempt`'s `on ApiException` →
  `_report(..., 'token_fetch')` in `voice_session_controller.dart:449`),
  i.e. working-as-designed errors that arguably shouldn't be Sentry errors.
- **Expected vs actual**: expected — user sees "try again" and retries, no
  Sentry issue unless the timeout signals a real defect; actual — two
  Sentry issues firing, endpoint unknown.
- **Code pointer**: `ayma_flutter/lib/services/api_client.dart`
  (`_timeoutFor`, `_isLongBudgetPath`, 408 throw sites); possible reporter:
  `voice_session_controller.dart:449-454`.
- **Needs**: the issues' stacks + tags/URL to name the endpoint. If it's a
  slow endpoint missing from the long-budget list, the fix is the
  established pattern (add path + regression in `test/api_client_test.dart`).
  If the stacks show voice `token_fetch`, decide whether handled 408s
  should stay Sentry-level (shared error-reporting policy — founder call).

### AYMA-FLUTTER-2Z — RenderFlex overflowed by 5.7 pixels on the right

- **Sentry ID**: AYMA-FLUTTER-2Z
- **Error**: `RenderFlex overflowed by 5.7 pixels on the right`
- **Evidence**: a debug-only framework assert (release builds paint no
  stripes and don't throw), captured because staging APKs are debug
  builds. Repo convention (`error_reporting.dart:logLayoutErrorLoudly`):
  reproduce in `test/layout_matrix_test.dart` and fix the layout with
  guards from `lib/widgets/overflow_guards.dart`.
- **Expected vs actual**: expected — no overflow at any matrix size;
  actual — 5.7px right overflow somewhere, screen unknown.
- **Code pointer**: unlocalizable without the stack (no widget path, no
  route). The layout matrix test is the localization tool.
- **Needs**: the issue's stack trace (widget + route). Then add the failing
  configuration to the matrix test and fix with overflow guards.

### AYMA-FLUTTER-2B — StateError: Bad state: No signed-in user

- **Sentry ID**: AYMA-FLUTTER-2B
- **Error**: `StateError: Bad state: No signed-in user` (message varies `.`
  suffix). **Not fixed: touches auth/session — excluded by brief.**
- **Evidence**: 8 identical throw sites guard service entry points when
  `FirebaseAuth.currentUser`/`uid` is null: `chat_service.dart:31`,
  `photo_service.dart:49`, `dm_service.dart:151`,
  `notification_service.dart:106`, `profile_service.dart:38`,
  `match_service.dart:45`, `instagram_service.dart:35`,
  `date_sim_service.dart:21`. The defect is whichever caller reaches one
  of these with no signed-in user (signed-out race, pre-auth deep link,
  background callback after sign-out) — the throw itself is the guard
  working.
- **Expected vs actual**: expected — callers never invoke signed-in-only
  services without a user (or catch and route to sign-in); actual — at
  least one path does.
- **Code pointer**: the 8 sites above; the culprit caller is named only by
  the stack.
- **Needs**: the issue's stack trace to identify the caller, then either
  guard the caller or add a sign-in redirect. Auth/session area — Claude
  to own.

### AYMA-AGENT-V — APIConnectionError: failed to generate LLM completion after 4 attempts

- **Sentry ID**: AYMA-AGENT-V (Nov 1 22:48 PT)
- **Error**: `APIConnectionError: failed to generate LLM completion after 4 attempts`
- **Evidence**: the message string exists nowhere in this repo — it is
  raised inside a dependency (OpenAI SDK / `livekit-plugins-openai`
  retry wrapper: connection-level failure retried to exhaustion). Agent
  LLM construction lives in `functions/bootstrap/agent.py`
  (`build_openai_realtime_model`, the Meta/open-weights cascade via
  `lk_openai.LLM`). Nov 1 22:48 PT overlaps the drained-staging-gateway
  window, but a *connection* error (not a 429) points at the
  OpenAI-compatible endpoint being unreachable rather than the
  gateway-429 family — cannot confirm without the stack. **Not fixed:
  agent/LiveKit area — excluded by brief.**
- **Expected vs actual**: expected — brain completes or surfaces a typed,
  actionable error; actual — 4 connection attempts fail and the session
  errors opaquely.
- **Code pointer**: `functions/bootstrap/agent.py:483-548` (cascade LLM
  builders), `:625-650` (realtime model); the retry loop is in the
  dependency.
- **Needs**: the issue's stack (which LLM path + target base URL) and the
  staging gateway state at 22:48 PT. Possible directions: typed error
  surfacing, endpoint health check, or (if it was the drained gateway)
  close as expected-state. LiveKit-adjacent — Claude/founder to own; per
  AGENTS.md, any LiveKit plan/credit/routing change is a founder decision.

## Branch contents

- `8505095` fix(voice): AYMA-FLUTTER-31 — VoiceSessionController used after dispose
- `2125b03` fix(flutter): AYMA-FLUTTER-2Q — setState callback returned a Future
- (this doc)

Verification: `voice_session_controller_test` 53/53 green;
`physical_attributes` + `public_profile` + `match_report` +
`complete_profile` + `matches` screen tests 61/61 green; `flutter analyze`
on all 9 touched files clean. New tests were observed failing pre-fix
with the exact Sentry errors. Full `flutter test` (1399) not re-run —
touched-area suites only; Claude/CI should run the full suite (incl. the
layout matrix) before merge.
