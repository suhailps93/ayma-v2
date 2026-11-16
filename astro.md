# Astro ledger — agent inbox (append-only)

Entry format (per `docs/agents/TEAM.md`): `## <YYYY-MM-DD HH:MM PT> — From <Name> (<Title>) — <DONE | BLOCKED | QUESTION | OOO>`, then 1–5 lines.

## 2026-11-16 08:10 PT — From Antigravity (Engineer) — DONE: Structured-writer swap (record_answer, set_profile_field, set_relationship_intent)

Branch `fleet/structured-writer-swap` rebased onto origin staging tip b20c5438. Pushed to shared and GitHub origin; NOT merged (the hourly sweep owns merges). Worktree: /home/suhailps/workspace/ayma-structured-writer-swap.
- Reader-trace result: unblocked. Every live reader of `profile/main`, `qstore` (`users/{uid}/questionnaire`), and the Taste wiki page is graph-backed with `PERSON_GRAPH_READS` ON (completeness, questionnaire_ingest, taste_backfill, fact_source, match mtime, matching_skill, session_mode, public_profile). No live reader requires old stores flag-on.
- Per-tool dispositions (flag-on -> graph overlay via `store.set_answer` / `store.upsert_fact_node`, leaving `profile/main`, `qstore`, and `wiki_pages/taste` untouched; flag-off untouched):
  - `record_answer`: writes graph overlay via `store.set_answer`. Preserves gender-identity inference refusal. Taste writes compose `emergent.taste.qloo` in the graph `taste` section (`visibility: public`).
  - `set_relationship_intent`: writes `relationship_intent` to graph overlay (`visibility: public` per `_PUBLIC_ALLOWLIST`).
  - `set_profile_field`: writes seed profile fields (`name`/`first_name` -> `legal_first_name`, `birthdate` -> `date_of_birth`, `gender` -> `gender_identity`, `interested_in` -> `target_match_genders`, `location` -> `primary_location`) and emergent facts (`last_name`, `phone`) to graph. Preserves 18+ adult birthdate validation and normalizations.
- Test results: `test_structured_writer_swap.py` (9/9 passed); full touched/adjacent suite (187 passed, 1 skipped) across reader migration, switch, skills, completeness, taste, session-mode, and matching; `flutter analyze` clean (0 issues).
- Scout retest note: Retest on next build with graph flags ON. Model calls to `set_profile_field`, `record_answer`, and `set_relationship_intent` update the person graph (`users/{uid}/graph/main`), verify in `GET /completeness`, active session mode derivation, and match reports without writing `profile/main`, `users/{uid}/questionnaire`, or `wiki_pages/taste`.

## 2026-11-08 10:45 PT — From Claude (Engineer) — DONE: ghost-header SYSTEMIC nav/auth teardown (R2-C6 / R2-C7)

Branch `fleet/ghost-header-systemic` off `origin/staging` (d68905e0). Staging-lineage, NOT merged; MAIN untouched/frozen. versionCode 2374 → 2375.

What: implemented ghost-header spec §6 Files 1–5 — the privacy-critical navigation-stack + in-memory-singleton root fix so Account A's story/DMs/reports/credits/transcript/prefetch/voice/dev-unlock can't linger into Account B on sign-out or account-switch.
- New `lib/services/auth_session_state.dart` (pure `ChangeNotifier`, no firebase_auth) → merged into `appRouter.refreshListenable`; `redirect` reads it first with FirebaseAuth fallback.
- New `lib/core/session_teardown.dart` `teardownSession({isSwitch})`: stop voice + dismiss Ayma popup → purge every cross-account singleton → route SignIn (sign-out)/Splash (switch) + bump `appRecoveryEpoch` (rebuilds whole router/navigator subtree) → clear AuthSessionState. Cold-boot safe (fires only when `lastKnownUid != null`). Theme/accent/localization/nav keys deliberately survive.
- `main.dart` auth listener wires sign-out + real account-switch teardown; preserves `notifyAuthSessionRestored`, RevenueCat logIn, push.syncToken, DeepLinkQueue.drainPostAuth.
- StoryEditor surface fix (`_userChanged`/`_loadedForUid`) KEPT as defense-in-depth (untouched).

Drift adaptations vs the 6-day-old spec (verified against current staging):
- No `rootNavigatorKey` exists → popup dismissed via `screenPopupTracker.navigator?.maybePop()`, gated on the real flag `isAymaSheetOpen` (spec's `isPageContextAymaPopupOpen` does not exist).
- `DeepLinkQueue` had no public clear → added `clearPendingIntent()` (spec's `clearPendingIntent()` name adopted; the getter is `pendingPostAuthIntent`).
- `TabPrefetchCoordinator.clear()` and `MatchReportCache.clearAll()` added as public prod methods — the existing `debugReset()`/`reset()` are `@visibleForTesting` and illegal to call from prod under the analyze gate.
- `PushService()` eagerly builds an `ApiClient` (→FirebaseAuth), so the three external-transport calls (ReportCache/RevenueCat/PushService) are each try/catch-wrapped so one failure can't abort the nav reset.

Green: `flutter analyze` = **0 issues**. `flutter test` = **2002 passed, 0 failed**, incl. all three layout_matrix shards (81 route/overlay cases, zero RenderFlex overflow) and the new `test/session_teardown_test.dart`. No routes added (route-matrix guard still passes). (One timing-budget test in `api_client_test.dart` flaked under concurrent CPU load in an earlier run; passes 75/75 in isolation and clean on the serialized re-run — not touched by this change.)

Next: Scout to run spec §7 QA cases 1–5 on the installed staging APK (story ghost, public-profile clean state, pushed-route backstack teardown, singleton+voice teardown, 401 forced sign-out).


## 2026-11-14 22:54 PT — From Antigravity (Engineer) — DONE: Questionnaire cold re-ask — Scout NOTE 214 Defect C

ROOT CAUSE (why the 2437 fix missed recorded qz_* state):
1. Data Layer: `completeness._evaluate()`, `_profile_answered()`, and `questionnaire_ingest._open_candidates()` only inspected `users/{uid}/questionnaire` collection and the static 5 preboarding fields in `_PROFILE_DERIVABLE`. They ignored `qz_{node_id}` on `profile/main` (where questionnaire answers are stored/mirrored for matching and demo profiles like Daniel Reyes). As a result, when an answer existed as `qz_*` on `profile/main` without a questionnaire subcollection doc, `completeness._evaluate()` evaluated it as `coverage = 0.0, status = "missing", known = ""` rather than covered.
2. Gating & Context Layer: Even when answers were recorded/covered, the 2437 check-before-asking gate (`next_questions` and `main._questionnaire_note`) only populated `already_known` from `supplemental` (off-tree volunteered topics). Tree answers were never included in `already_known` or the questionnaire note. Because covered items are excluded from `questions` (`coverage < 1.0`), Ayma had zero access to recorded questionnaire answers in tools or context. When steered to ask about money or spending, Ayma had no recorded state and asked the questions cold from scratch.
3. Prompt Guidance: `prompts/questionnaire.md` described `already_known` as only volunteered topics and lacked guidance to reference and build on known answers when steered on a topic.

BRANCH: fleet/questionnaire-cold-reask @ c8f131e2, off origin/staging 8df28496. Pushed to origin (GitHub) and shared. NOT merged (hourly sweep owns merges). Worktree: /home/suhailps/workspace/ayma-antigravity-qz.

WHAT WAS BUILT:
1. `functions/bootstrap/completeness.py`:
   - `_profile_answered()` and `_evaluate()` now inspect `profile.get(f"qz_{nid}")`. When present and non-blank, the node is evaluated as covered (`coverage: 1.0`, `status: "covered"`, `source: "profile"`, `known: value`).
   - `_resolve_intent()` checks `qz_relationship_intent` alongside `relationship_intent`.
   - `compute()` extracts all answered/known tree nodes into `result["recorded"]`.
2. `functions/bootstrap/skills/questionnaire.py`:
   - `next_questions()` returns `already_known` populated with both recorded tree answers (`result["recorded"]`) and volunteered topics (`result["supplemental"]`).
   - `_NEXT_DESCRIPTION` updated so the tool contract makes clear `already_known` holds all recorded and volunteered answers and must never be asked cold.
3. `functions/bootstrap/questionnaire_ingest.py`:
   - `_open_candidates()` excludes nodes already answered in `profile/main` via `qz_*`.
4. `functions/bootstrap/main.py`:
   - `_questionnaire_note()` injects already-recorded profile answers (from `c.get("recorded")` with fallback to `qz_*` on profile) with explicit instruction never to ask them cold and to reference known state if steered to that topic.
5. `functions/bootstrap/prompts/questionnaire.md`:
   - Updated "No repeats — check before asking" to require referencing and building on known answers whenever steered on a topic rather than asking cold.

TESTS:
- `pytest functions/bootstrap/tests/test_completeness.py functions/bootstrap/tests/test_questionnaire_skill.py functions/bootstrap/tests/test_questionnaire_ingest.py functions/bootstrap/tests/test_supplemental.py functions/bootstrap/tests/test_context_parity.py`: 87/87 passed (100% green, 1 skipped baseline).
  - New test `test_qz_mirror_on_profile_counts_as_covered`: verifies `qz_*` on profile counts as covered and populates `recorded`.
  - New test `test_next_questions_already_known_includes_recorded_tree_answers`: verifies `next_questions` returns Daniel's recorded money/spending answers in `already_known` and drops them from open questions.
  - New test `test_questionnaire_note_surfaces_recorded_profile_answers`: verifies `_questionnaire_note` injects recorded answers and directs Ayma never to ask cold.
  - New test `test_qz_mirror_on_profile_skips_extraction`: verifies `questionnaire_ingest` skips already-recorded `qz_*` nodes.
- Full prompt, skills, and matching suites: `test_prompt.py`, `test_skills.py`, `test_match_deterministic.py`: 113/113 passed.
- `flutter analyze` in `ayma_flutter`: clean — 0 issues found ("No issues found!").


## 2026-11-15 03:48 PT — From Antigravity (Engineer) — DONE: Privacy toggles remainder (Scout NOTE 218) — marker PRIVACY-DATEMOMENTS-218

BRANCH: fleet/privacy-datemoments-pending @ 17f7daf2, off staging tip 9b2b43bf. NOT merged (hourly sweep owns merges). Staging only. Worktree: /home/suhailps/workspace/ayma-antigravity-privacy-dm.

ITEM 1 ROOT CAUSE & FIX:
- Root cause: `_setDateMoments` called `_requestLocationPermission` without `trackSettingsReturn: true`, and `_reconcileLocationPermission` only tracked Location log via `_awaitingSettingsGrant`. A pending Date moments ON was dropped on return from Settings. Furthermore, the toast copy previously instructed "then turn it on again", contradicting auto-apply.
- Fix:
  - Replaced single `_awaitingSettingsGrant` with separate `_awaitingLocationLogGrant` and `_awaitingDateMomentsGrant`.
  - In `_setDateMoments`, armed `trackSettingsReturn: true` on tap ON and cleared pending state on tap OFF. Turning OFF never touches permission.
  - In `_reconcileLocationPermission`, when `_awaitingDateMomentsGrant` is armed, checks whether location permission was granted (`perm == always || perm == whileInUse || hasBackgroundPermission()`) and auto-applies Date moments ON on resume. If not granted, stays OFF. If no pending tap, resume reconcile leaves Date moments untouched.
  - Updated toast copy from "allow location there, then turn it on again" to "allow location there to turn it on" for both Location log and Date moments.

ITEM 2 INVESTIGATION & FIX:
- Investigation: In the existing implementation, `AymaToast.show()` was called immediately before `_location.openAppSettings()`. Because `openAppSettings()` immediately invokes the platform channel intent to launch Android Settings Activity synchronously/in the same frame, the app was backgrounded before the toast could render/fade-in (240ms anim), meaning the user could not read why the redirect was happening before leaving Ayma.
- Fix: In `_requestLocationPermission`, on the denied-forever path (`deniedForever` or `whileInUse` when `needsBackground` is true), an informative `AlertDialog` is presented with title `"$feature needs location permission"`, content explaining how to allow location in Settings, and actions ("Cancel" and "Open Settings"). The tell is visible and readable before any redirect; `openAppSettings()` is only invoked when the user confirms with "Open Settings". Dismissing/canceling leaves the toggle OFF and stays in the app without opening Settings.

TESTS:
- `cd ayma_flutter && flutter test test/privacy_location_test.dart`: 20/20 passed (5 new tests + existing 15 updated):
  - `enabling Location log when permanently denied shows tell dialog before opening settings`
  - `enabling Date moments when permanently denied shows tell dialog before opening settings`
  - `denied-forever tell dialog Cancel button dismisses dialog and stays off without opening settings`
  - `Date moments: denied-forever, tap ON, grant in Settings, return auto-applies Date moments ON without second tap`
  - `Date moments: denied-forever, tap ON, do NOT grant in Settings, return stays OFF`
  - `Date moments: no pending tap -> resume reconcile changes nothing for Date moments`
  - `turning off Date moments does not touch permission or settings`
- Adjacent settings suites: `test/settings_cleanup_test.dart` and `test/settings_verify_face_test.dart` both 100% green (16/16 passed; total 36/36 passed).
- `cd ayma_flutter && flutter analyze`: 0 issues found ("No issues found!").
