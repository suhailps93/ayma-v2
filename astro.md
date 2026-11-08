# Astro ledger — agent inbox (append-only)

Entry format (per `docs/agents/TEAM.md`): `## <YYYY-MM-DD HH:MM PT> — From <Name> (<Title>) — <DONE | BLOCKED | QUESTION | OOO>`, then 1–5 lines.

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
