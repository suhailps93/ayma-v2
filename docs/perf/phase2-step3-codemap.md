# Perf Phase 2 Step 3 Prep — Startup Code-Map

**Status**: READY FOR STEP-3 IMPLEMENTATION · **Staging tip mapped**: `c9b0b39` ·
**Author**: Muse (Engineer) · **Date**: 2026-11-02 ·
**Spec under test**: `docs/perf/phase2-startup-implementation-spec.md` (Antigravity, founder-locked Nov 1)
plus reference `docs/perf/phase2-startup-design.md`.

Read-only analysis — no code changed. Every dependency claim cites the file/function it came from
(all paths `ayma_flutter/lib/…` unless noted). Line numbers are staging @ `c9b0b39`.

## 0. TL;DR for the implementer

- The spec's pre-`runApp` trace (§2.1, 19 steps) is **accurate** — `main.dart:40-208` still matches it
  step for step. Two cost cells are wrong (accent fallback and Crashlytics-enable are **unbounded**,
  not 8 s / throws-fast — M9, M8).
- The post-`runApp` trace is accurate too: `SplashScreen._resolve` (blocking bootstrap 12 s token +
  15 s POST, 4 attempts, 1/3/6 s backoff, 20 s watchdog) plus the optimistic `boot_route:` fast path
  the design doc already knew about.
- **19 spec↔code mismatches** below (§5). The three that change the DAG shape:
  - **M1**: `AuthService` is not a singleton and has no `instance` — N9's `ensureAuthReady` home
    does not exist; startup/splash/router all use raw `FirebaseAuth.instance`.
  - **M2**: N6 (`launch_intent`) cannot depend on N1 alone — `getInitialMessage()` needs an
    initialized Firebase app, so N6 ← N7 is a real edge the spec omits.
  - **M3**: paywall deep links (`plan`/`trial`) do not exist anywhere in the client — N11 promotion
    has no producer; confirm a backend sender exists before building it.
- Touch list: 5 new files + 14 modified, in dependency order with sizes, in §6.

## 1. Startup inventory (as executed today)

### Phase A — pre-`runApp`, `main()` (`lib/main.dart:40-208`, strictly serial)

| # | Init | Evidence | Awaited? | Budget | On failure |
|---|---|---|---|---|---|
| A1 | `WidgetsFlutterBinding.ensureInitialized()` | `main.dart:41` | n/a (sync) | ~10 ms | fatal |
| A2 | `SystemChrome.setPreferredOrientations(portrait×2)` | `main.dart:46-49` | yes, platform ch. | 10–50 ms | throws (fatal today) |
| A3 | debug root-logger listener | `main.dart:56-61` | no (sync, `kDebugMode` only) | ~0 | — |
| A4 | `Firebase.initializeApp` | `main.dart:66-69` via `guardStartupStep` (`main.dart:218-231`) | yes | **8 s cap**, then proceed | swallowed, runApp anyway |
| A5 | `setCrashlyticsCollectionEnabled(!kDebugMode)` | `main.dart:75-77` | **yes, unbounded** | 10–30 ms typical | throws (fatal today) |
| A6 | fatal hooks: `FlutterError.onError`, `PlatformDispatcher.onError`, `ErrorWidget.builder` | `main.dart:78-90` | no (sync assigns) | ~0 | — |
| A7 | `RevenueCatService.instance.init()` (`Purchases.configure`) | `main.dart:100-103` via guard; `revenuecat_service.dart:206-215` | yes | **8 s cap**, then proceed | swallowed; release w/o prod key throws `StateError` inside guard (`revenuecat_service.dart:190-197`) → purchases disabled |
| A8 | `listenForEntitlementChanges(ApiClient())` | `main.dart:108`; `revenuecat_service.dart:457-463` | no (sync; **no-op if `!_configured`**) | ~0 | — |
| A9 | `PushService()` construct + `authStateChanges().listen` | `main.dart:109-137` | no (sync registration) | ~0 | listener body is all `unawaited`: `ReportCache.clearForSignOut` on sign-out (`:122`), `RC.logOut` (`:125`), `RC.logIn(uid)` (`:128`), `push.syncToken()` (`:135`) |
| A10 | `DevPanelSession.instance` lifecycle observer | `main.dart:139` | no (sync) | ~0 | — |
| A11 | `AppCommandHost(AppCommandService.shared).attach()` | `main.dart:140`; `app_command_host.dart:21-29` | no (sync + unawaited `setForeground`) | ~0 | `_listen` no-ops until a voice session starts (`app_command_service.dart:210-211`) — zero startup network |
| A12 | `ScreenCapture.instance.attach(appRouter, …)` | `main.dart:144-149`; `screen_capture.dart:575-583` | no (sync; `ensureSemantics` + router listener) | ~0 | — |
| A13 | `themeControllerGlobal.load()` | `main.dart:150`; `theme_controller.dart:20-28` | **yes**, prefs disk read | 10–40 ms | keeps default |
| A14 | `accentColorControllerGlobal.load()` | `main.dart:151`; `accent_color_controller.dart:40-65` | **yes**: prefs read, else **unbounded** Firestore `_profiles.getAccentColor()` (`profile_service.dart:241-247`, `_profileDoc.get()` with no timeout) | 10–30 ms local; ∞ remote | keeps default. Narrow trigger: `getAccentColor` returns null fast when `currentUser == null` (`:242-243`), which is the usual pre-frame state (auth restores async) |
| A15 | `orbAnimationSettingsGlobal.load()` | `main.dart:152`; `orb_animation_settings.dart:55-64` | **yes**, prefs disk read | 5–20 ms | keeps defaults |
| A16 | `push.listenForTaps(…)` | `main.dart:159-166` | **no** (`unawaited`) | bg | swallowed (`push_service.dart:179-184`). `resolveRoute` closure reads `FirebaseAuth.instance.currentUser?.uid ?? ''` **at tap time** (`main.dart:161-164`) — the empty-uid race |
| A17 | `MetaIntegrations.loadCached()` | `main.dart:169`; `meta_integrations.dart:30-38` | **yes**, prefs disk read | 5–20 ms | `enabled=false` |
| A18 | `MetaIntegrations.refresh(Firestore)` | `main.dart:170`; `meta_integrations.dart:42-48` | **no** (`unawaited`) | bg, 10 s self-timeout | swallowed; cached value untouched |
| A19 | Sentry gate: `SentryFlag.loadCached()` (5 s cap) → `SentryFlag.refresh` (unawaited) → `SentryFlutter.init` (8 s cap, `appRunner: launchApp` + `launchApp()` fallback) | `main.dart:175-208`; `sentry_config.dart:68-90` | yes (bounded) | 5 s + 8 s caps | launches without Sentry. Early-out: empty DSN or `!sentryCompiledIn` → plain `runApp` (`main.dart:175-178`) |
| A20 | `runApp(const AymaApp())` | `main.dart:176,183,195,208` | — | — | — |

Singletons constructed (all sync, in-memory, no I/O): `PushService()` (`:109`), `ApiClient()`
(`:108`; ctor only builds an `http.Client` + grabs `FirebaseAuth.instance`, `api_client.dart:19-25`),
`AppCommandHost`, `AppCommandService.shared`, `DevPanelSession/ScreenCapture/ReportCache` instances,
`appRouter` (top-level `GoRouter`, `app_router.dart:99`), theme/accent/orb globals.

### Phase B — first frame (`AymaApp.build`, `main.dart:287-330`)

Synchronous reads that MUST be hydrated before `runApp` (the real N8←N5 edge):
`themeControllerGlobal.mode` (`:298`), `accentColorControllerGlobal.color` (`:296-297`).
Router builds the initial route during `runApp`: `GoRouter(initialLocation: '/splash')`
(`app_router.dart:99-100`) → `SplashScreen(apiClient: ApiClient())` (`:136`) — whose ctor grabs
`FirebaseAuth.instance` (`api_client.dart:25`), and `redirect` reads `FirebaseAuth.instance.currentUser`
(`app_router.dart:105-107`). Both throw `[core/no-app]` if Firebase init failed-and-was-swallowed (A4) —
see fragility note in §5/M12.

### Phase C — splash resolve (post-frame, `splash_screen.dart`)

`initState` (`:74-85`): `AppContext.set(screen:'splash')`, connectivity watcher, 20 s watchdog
(`startupDeadline`, `:46`), post-frame `_resolve()`. `_resolve` (`:139-230`):

1. `auth.currentUser` null/anonymous → `go('/signin')` immediately (`:150-157`). No waiting for
   auth restoration — a still-restoring session misroutes to sign-in today (the DAG's N9 fixes this).
2. `ReportCache.readBootRoute(uid)` (`:171`; `report_cache.dart:66-75`, key `boot_route:$uid`,
   plain string, no staleness, per-call `SharedPreferences.getInstance()`). Hit → `go(cached)` +
   `unawaited(_backgroundBootstrap(…))` (`:177-180`).
3. Miss → blocking `apiClient.bootstrap(sessionId:'')` (`:185`; token refresh **12 s cap** +
   POST **15 s cap**, `api_client.dart:41-42,74,113`), up to `maxStartupAttempts = 4` (`:39`) with
   backoff sleeps 1/3/6 s (`:58-62`), connectivity-change instant retry (`:118-137`), 20 s watchdog
   (`:100-111`). `AuthSessionException` (broken keystore session) → sign out + `/signin` (`:191-205`);
   401/403 → `/signin` (`:208-213`); anything else → transient retry, never sign-out (`:215-229`).
4. `_resolveRoute` (`:237-255`): `ageBlocked` → `/underage`, `recoveryRequired` → `/recover`,
   consent still required → `/biometric-consent` (after `_recordPendingConsent` → network
   `acceptBiometricConsent`, `:361-374`), else `entryRouteFor(sessionMode)` (`entry.dart:7-23`:
   `active`→`/`, `interview`→`/preboarding`, `marketing`→`/chat`, `''`→`/`).
5. `_cacheEntryRoute` (`:261-265`): caches ONLY plain entry routes, never gates.
6. `_backgroundBootstrap` (`:274-311`): same bootstrap with the same 4× retry/backoff but
   **unbounded per-attempt** (12+15 s each, no watchdog); corrects via `router.go(route)` on
   divergence (`:281`); 401/403 or broken session → clear cache + `/signin`.

### Phase D — destination screens' own init (post-routing, pre-interactive)

- `/` (`MainShellScreen.initState`, `main_shell_screen.dart:232-283`): `AymaSession.instance.store/
  voice` first touch (`:81-84`; pure in-memory construction — `newSessionId()`, `TranscriptStore()`,
  `VoiceSessionController(…)` — `ayma_session.dart:22-27`, no I/O), `CallBackgroundService.acquire`
  (`:271`, sync ref-count), `ChatInbox`/`TabRequest`/`TourRequest` listeners (sync), post-frame
  `_maybeShowFeatureTour` (Firestore `seen_tour_features` read via `profile_service.dart:266-270`,
  best-effort), `TabPrefetchCoordinator.scheduleIdleWarmup()` (`:282` — post-frame + 400 ms delay,
  prefetches Explore page 1 + conversation minis, 2-min stale cutoff, best-effort;
  `tab_prefetch_coordinator.dart:32-49`). Tabs are lazy: unvisited tabs are empty boxes (`:93-94`).
- `/signin` (`SignInScreen.initState`, `sign_in_screen.dart:129-148`): constructs `AuthService()`,
  `TranscriptStore()`, `VoiceSessionController(welcome: true)` (`:68-73`, all sync); post-frame
  `_voice.start()` (`:145-147`, skipped in tests) → `POST /welcome/token` (no account) + LiveKit
  connect + mic publish (`voice_session_controller.dart:60-62,284-324`), best-effort. Success → splash.
- `/dm/:threadId` (`DmThreadScreen.initState`, `dm_thread_screen.dart:134-142`): fires (not awaited)
  `_loadOther` (network `miniProfiles`, `:258-270`), `_loadPreferredLang`, `_dm.markThreadRead`.
  Shell paints immediately; content fills in. Route requires auth via redirect (not in the open set,
  `app_router.dart:109-120`).
- `/profile/plan` (`PlanScreen`, `plan_screen.dart:120`): `_load()` (`:176-188`) fans out
  `SubscriptionStatus.load` + `plans()` + `usage()` concurrently; `_unavailable` (`:311-317`) shows
  "Subscriptions are not available in this build." when `!_rc.enabled`; restore button disabled on
  `!_rc.enabled` (`:443`). Shimmer/loader exists for the pending state (spec §4.2.1's "show shimmer"
  maps to the existing `_data` future-builder path).
- `/profile/usage/trial` (`TrialPaywallScreen`, `trial_paywall_screen.dart:33`): takes `TrialOffer`
  via ctor/`extra`; route builder falls back to `PlanScreen` when `extra` isn't a `TrialOffer`
  (`app_router.dart:357-365`). No `_load` — reads `_rc.enabled` in gate helpers (`:277,301`) and calls
  `_rc.purchase` + `_rc.syncEntitlement` on user action (`:62-67`).
- Gates (`/underage`, `/recover`, `/biometric-consent`, `/preboarding`, `/chat` marketing): no
  startup-significant init found; routing targets only.

### Phase E — background listeners & refreshers (never gate first frame)

- Auth-state listener (`main.dart:115-137`): sign-out → clear boot/report cache + `RC.logOut`;
  sign-in → `RC.logIn(uid)` + `push.syncToken()` (permission prompt + token register + refresh
  subscription, `push_service.dart:102-110`; the `main.dart:129-135` comment documents why it must
  wait for auth — the N16←N9 evidence).
- Push taps (`push_service.dart:152-186`): cold initial tap via `initialTapData()`
  (`getInitialMessage` → else `ayma/push` channel `initialDeepLink`, `:60-65`) then
  `tapsWhileRunning` stream. Every tap also runs mark-read (`main.dart:244-256`: waits for first
  non-null auth emission with a **10 s cap**, then `NotificationService.markReadForTap`).
- Cold-tap navigation gate `_pushWhenPastSplash` (`main.dart:258-277`): polls the router off `/splash`
  with a **20 s cap**, then `push(path)`. No stash: if the push lands while `currentUser` is still
  null, the router redirect bounces it to `/signin` and the intent is lost (the exact hole
  `DeepLinkQueue` closes).
- Flag refreshes for next launch: `MetaIntegrations.refresh` (A18), `SentryFlag.refresh`
  (`main.dart:181`; 10 s self-timeout, `sentry_config.dart:84-90`).
- Deep-link vocabulary → routes (`notification_service.dart:250-282`): `dm_thread/:id`→`/dm/:id`,
  `profile/:uid`→`/dm/${sortedPairKey(myUid, uid)}` (**no empty check** — `__<uid>` corruption),
  `match_request/:id`, `match/:id`, `deep_dive/:id`, `appearance/:id`, `date_sim/:uid/:sim`,
  `matches`→`/matches`, `profile_suggestions`→`/profile/me/updates`, `chat`/unknown→`/`.
  **No `plan`/`trial` links exist.**

## 2. Dependency edges (code evidence, not guesses)

"X ← Y" = X cannot correctly run until Y resolves. Ordering-only edges marked (ord).

| Target | Needs | Evidence |
|---|---|---|
| A2 orientation ← A1 binding | platform channel requires binding | Flutter framework contract; `main.dart:41` runs first |
| A4 Firebase ← A1 | `initializeApp` requires binding | same |
| A5/A6 crash hooks ← A1 | `PlatformDispatcher`/`FlutterError` wiring post-binding | `main.dart:78-90` placement; GATE-RED comment `:86-90` |
| A7 RevenueCat ← A1 | `Purchases.configure` is a platform-channel call | `revenuecat_service.dart:210` |
| A8 entitlement listener ← A7 | no-ops entirely when `!_configured` | `revenuecat_service.dart:457-458` — **trap**: under deferred init the attach must move after N11 completes |
| A9 auth listener ← A4 | `FirebaseAuth.instance` throws with no default app | `main.dart:115` |
| A11 AppCommandHost ← A4 | "Call once, after Firebase init" + touches `FirebaseAuth` | `app_command_host.dart:20-28` |
| A13/A15 theme/orb ← prefs | read keys from `SharedPreferences` | `theme_controller.dart:22`, `orb_animation_settings.dart:57` |
| A14 accent ← prefs, then ← auth+Firestore | local key first; else `_profiles.getAccentColor()` → `_profileDoc.get()` needs a signed-in uid + Firestore | `accent_color_controller.dart:42-53`, `profile_service.dart:241-247` |
| A17 meta flag ← prefs | `prefs.getBool` | `meta_integrations.dart:32-33` |
| A18/A19-refresh flag refreshes ← A4 only | Firestore `.get()`; called pre-auth in `main` — **no auth edge** (spec's N19←N9 is wrong for these; see M7) | `main.dart:170,181` unconditional calls |
| A19 Sentry init ← prefs (flag) | `SentryFlag.loadCached` gates `sentryShouldRun` | `main.dart:179-185`; compile gates `sentryDsn`/`sentryCompiledIn` (`:175`) |
| B first frame ← A2 | portrait lock; layouts assume tall viewport | `main.dart:43-49` comment |
| B ← A6 | build-phase exceptions must hit graceful fallback, never red screen | `main.dart:86-90` |
| B ← A13/A14/A15/A17 | theme/accent read in `AymaApp.build`; meta flag read in `/instagram-connect` redirect | `main.dart:296-298`; `app_router.dart:334-335` |
| B ← A4 | route build constructs `ApiClient()` → `FirebaseAuth.instance`; `redirect` reads `currentUser` | `app_router.dart:136,105-107`; `api_client.dart:25` |
| C splash routing ← auth state | null/anon → `/signin`; uid scopes cache reads | `splash_screen.dart:150-157,171` |
| C optimistic path ← prefs + uid | `boot_route:$uid` string; empty uid never caches | `report_cache.dart:66-75,42` |
| C blocking bootstrap ← auth (ID token) | `_headers()` → `getIdToken()` | `api_client.dart:74` |
| C consent record ← bootstrap result | `_recordPendingConsent` only when server says required | `splash_screen.dart:237-243,361-374` |
| D shell ← auth (soft) | tour gate + warm-up no-op without a user; `AymaSession` itself needs nothing | `main_shell_screen.dart:292-296`; `tab_prefetch_coordinator.dart:40`; `ayma_session.dart:22-27` |
| D DM screen ← auth (token for API) + threadId | `miniProfiles`/mark-read are authed calls; pair-key links need uid at resolve time | `dm_thread_screen.dart:258-270`; `notification_service.dart:253-256` |
| D plan/trial ← A7 configured | `plans()` returns static fallbacks, purchase throws, when `!_configured` | `revenuecat_service.dart:247-249,400-403` |
| E `syncToken` ← A4 + auth | token register is an authed backend call; eager call 401s and never retries | `push_service.dart:102-120`; `main.dart:129-135` comment |
| E cold-tap resolve ← intent data + (profile-links) auth | `profile/:uid` needs `myUid` for `sortedPairKey`; `dm_thread/` needs none to route (but authed screen after) | `notification_service.dart:251-256` |
| E cold-tap push ← splash settled | splash `go()` would wipe an early push | `main.dart:233-236` comment + `:258-277` |
| E tap mark-read ← auth | owner-scoped `notifications` write; waits 10 s for first user | `main.dart:237-256` |

## 3. Critical path per entry route

### R1 — cold start → sign-in (signed-out user)

Pre-frame serial chain (A1→A20; worst-case bounded sum today: 8 Firebase + 8 RC + 5+8 Sentry +
unbounded A5/A14 tails) → splash frame → post-frame tick → `currentUser == null` → `go('/signin')`
(`splash_screen.dart:150-157`) → sign-in builds (sync) → post-frame `_voice.start()` begins the
greeting (network, best-effort, NOT a gate: `sign_in_screen.dart:143-147`). **Critical inits**: A1,
A2, A4, A5, A7, A13–A15, A17, A19 + splash tick. A9/A10–A12/A16/A18 are sync-register or background.

### R2 — icon launch → shell, warm (signed-in, `boot_route` cached)

R1's pre-frame chain → splash tick → `readBootRoute` (one prefs read, ms) → `go(cached)`
(`splash_screen.dart:171-180`) → shell build (`AymaSession` in-mem, `CallBackgroundService.acquire`
sync, Ayma-tab `ChatScreen` build) → interactive. Post-interactive, non-blocking: `_backgroundBootstrap`
(corrects on divergence), tour gate (Firestore read), idle warm-up (+400 ms prefetch). **Critical** =
pre-frame + prefs read + shell build. Note: with no `BootConfig` staleness today, a 6-month-old cache
routes optimistically and the background bootstrap corrects — spec's 7-day bound (M17) tightens this.

### R3 — icon launch → shell, cold (no cache)

R2 + blocking bootstrap: 12 s token + 15 s POST per attempt × up to 4 with 1/3/6 s sleeps, 20 s
watchdog → `_resolveRoute` (+ `acceptBiometricConsent` POST on first consent) →
`go(entryRouteFor(mode))`. Worst case 20 s to `SplashErrorView`, never signed out.

### R4 — deep link / notification tap, cold (signed-in, session restoring)

Two racers today: (a) `initialTapData` → `route()` resolves with `currentUser?.uid ?? ''`
(`main.dart:161-164`, `push_service.dart:180-181`) — `profile/` links corrupt to `__<uid>` when auth
hasn't restored; (b) `_pushWhenPastSplash` holds the push until the router leaves `/splash` (20 s cap),
but if auth still isn't restored the router `redirect` bounces the push to `/signin`
(`app_router.dart:118-120`) and the intent is **lost** — no stash exists. Mark-read independently waits
10 s for auth. **Critical inits**: pre-frame + N9-equivalent (auth restore) + splash routing + intent
resolve with confirmed uid. `dm_thread/` links need no uid to *route* but the screen's authed fetches
need a token promptly after.

### R5 — notification tap, warm (app alive)

`onMessageOpenedApp` / native `onDeepLink` → `route()` → immediate `push` (auth present; splash gate
already passed). Critical path is empty beyond the existing listeners — the DAG must preserve this
zero-gate behavior for warm taps (DeepLinkQueue fast path when `ensureAuthReady` already completed).

## 4. Spec DAG nodes → code mapping

| Node | Maps to | Status |
|---|---|---|
| N1 engine_binding | `main.dart:41` | exists ✓ |
| N2 orientation_lock | `main.dart:46-49` | exists ✓ |
| N3 crashlytics_fatal | `main.dart:78-90` incl. `ErrorWidget.builder` | exists ✓ (spec sketch omits `ErrorWidget.builder` — M11) |
| N4 prefs_preload | scattered `SharedPreferences.getInstance()` (theme:22, accent:42, orb:57, meta:32, sentry:70, report_cache per-call) | **to build** |
| N5 ui_controllers | `load()`s exist but async + scattered; accent has network | **to build** (`loadFromPrefs` ×4) |
| N6 launch_intent | extraction exists (`FirebaseFcmTokens.initialTapData`, `push_service.dart:60-65`); classification + pre-frame hoist missing | **to build**; needs N7 edge (M2) |
| N7 firebase_core | `main.dart:66-69` (8 s → spec 3 s) | exists, retune |
| N8 first_frame_mount | `runApp` sites `main.dart:176,183,195,208` | exists ✓ |
| N9 auth_session_restore | restore = Firebase SDK internal; no completer, no `AuthService.instance` | **to build** (M1); notify-point wiring is new work |
| N10 boot_config_read | `readBootRoute` string-only predecessor (`report_cache.dart:66-75`) | **to build** on new `boot_config:$uid` key (M17: migrate/expire `boot_route:`) |
| N11 revenuecat_init | `RevenueCatService.init` (`revenuecat_service.dart:206-215`) | exists; needs `initDeferred` + completer. N7 edge unjustified (M6) |
| N12 destination_routing | scattered: splash `_resolve`/`_resolveRoute`/`_backgroundBootstrap` + router `redirect` | **to build**; must reuse `entryRouteFor` (M13) and preserve gate order (M14) |
| N13 revenuecat_auth_bind | `main.dart:125,128` in auth listener | exists; move under N9∧N11 |
| N14 background_refresher | `_backgroundBootstrap` (`splash_screen.dart:274-311`) | exists; needs 8 s budget (today unbounded ×4 — M15) |
| N15 crashlytics_enable | `main.dart:75-77` (awaited!) | exists; move post-frame |
| N16 push_token_sync | `push.syncToken` via auth listener (`main.dart:135`; `push_service.dart:102-110`) | exists; edge N7∧N9 confirmed |
| N17 dev_observers | `main.dart:139-149` | exists ✓ (all sync; zero startup network per §1/A11) |
| N18 sentry_init | `main.dart:175-208` | exists; move to background, preserve DSN/compile gates (M10); N7 edge unjustified |
| N19 remote_sync | `main.dart:170,181` + accent split (new) | partial; split edges (M7) |

Absent everywhere in `lib/` and `test/` (verified by repo-wide grep): `BootConfig`,
`DeepLinkQueue`, `LaunchIntent`, `ensureReady`, `initDeferred`, `startup_dag`, `loadFromPrefs`,
`syncRemoteIfMissing`, `lib/util/perf_log.dart` (M19).

## 5. Spec↔code mismatches (flagged, not fixed)

Shape-changing (DAG edges/size affected):

- **M1 — N9's home doesn't exist.** Spec §4.2.2 assumes `AuthService.instance.ensureAuthReady()`,
  but `AuthService` (`auth_service.dart:11-192`) has no singleton/`instance` — it's constructed
  per-screen with injectable deps (`sign_in_screen.dart:68`). Startup, splash, and the router all use
  raw `FirebaseAuth.instance` (`main.dart:115,151,163,246`; `splash_screen.dart:150`;
  `app_router.dart:106`). Implementation must add the singleton + completer AND choose the
  `notifyAuthSessionRestored` wiring point (new auth listener vs. extending `main.dart:115`'s),
  without churning the existing test seams.
- **M2 — N6 needs N7.** Spec §2.2 gives N6 deps `{N1}` running parallel with N7, but N6's FCM half
  (`getInitialMessage`, `push_service.dart:61`) requires an initialized Firebase app — calling it
  pre-N7 throws. Real edges: FCM extraction ← N7; only the `ayma/push`-channel half is N1-only
  (`:63`). N6 must split or move after N7.
- **M3 — paywall intents have no producer.** Spec §3.2 classifies `deep_link == 'plan'/'trial'`,
  but no such values exist in `deepLinkToRoute` (`notification_service.dart:250-282`) or anywhere
  client-side, and no paywall push is documented. N11 promotion (§3.3) is dead code until a backend
  sender exists — confirm before building, else build the edge but leave the classifier arm untested.
- **M4 — spec taxonomy undercovers the link vocabulary.** `match_request/`, `match/`, `deep_dive/`,
  `date_sim/`, `matches`, `profile_suggestions` (`notification_service.dart:257-281`) have no intent
  class — presumably `GenericDeepLinkIntent`, but §3.2 never says. `appearance/` is claimed by
  Generic (§3.2) ✓ matches code (`:267-270`).
- **M5 — trial deep-link target can't render from a path alone.** `TrialPaywallScreen` requires a
  `TrialOffer` object; the route builder substitutes `PlanScreen` when `extra` isn't one
  (`app_router.dart:357-365`). A paywall intent to `/profile/usage/trial` must fetch
  `proTrialOffer()` first (needs N11 + eligibility round-trip, `revenuecat_service.dart:313-360`),
  else it lands on Plan.
- **M6 — N7→N11 edge is unjustified.** `Purchases.configure` touches no Firebase
  (`revenuecat_service.dart:206-215`); N11's real dep is N1 (platform channel). Keep the ordering if
  harmless, but N11 could parallel N7.
- **M7 — N19←N9 edge is half-wrong.** Flag refreshes run pre-auth today (`main.dart:170,181`) —
  only the (new) accent `syncRemoteIfMissing` needs a uid (`profile_service.dart:242-243`). Split:
  flags ← N7; accent sync ← N7∧N9.
- **M8 — Crashlytics-enable is unbounded, not "10–30 ms, throws".** `main.dart:75-77` awaits with
  no guard; a hung platform channel hangs `runApp` forever. (Design §2.1 step 5 understates it.)
- **M9 — accent fallback is unbounded with a narrow trigger, not "up to 8 s".** Bare await
  (`main.dart:151`) + timeout-less `_profileDoc.get()` (`profile_service.dart:244`). Usually a fast
  null (`currentUser` still null pre-frame, `:242-243`), but infinite in the worst case. Design §2.1
  step 14's "8,000 ms" has no code basis.
- **M10 — N18 sketch drops the compile gates.** `main.dart:175-178` early-outs on empty DSN /
  `!sentryCompiledIn` before touching flags; spec §2.2/N18 must preserve this or Sentry-less builds
  pay for init and refresh.

Routing/gate behavior the spec is silent on:

- **M11 — N3 sketch omits `ErrorWidget.builder`.** `main.dart:90` is load-bearing (GATE-RED durable
  guard); N3 must carry it.
- **M12 — N7-failure fragility.** Guard-swallow lets `runApp` proceed with no Firebase app, but the
  first route build + `redirect` touch `FirebaseAuth.instance` (`app_router.dart:106,136`) which
  throws `[core/no-app]` — graceful-error fallback or a loud crash depending on path. Spec's "degraded
  offline UI" (N7 failure policy) needs explicit Firebase-absent guards at these two touch points.
- **M13 — N12 must reuse `entryRouteFor`.** The sessionMode→route map exists (`entry.dart:7-23`,
  incl. the `''`→`/` and `marketing`→`/chat` subtleties) but the spec never cites it — reimplementing
  risks diverging.
- **M14 — gate order + consent side-effect need a home.** `_resolveRoute`'s age→recovery→consent→entry
  order plus `_recordPendingConsent`'s `acceptBiometricConsent` POST (`splash_screen.dart:237-255,
  361-374`) and the router's `BiometricConsentState.required` gate (`app_router.dart:125-129`,
  default false, `biometric_consent.dart:18-25`) must survive the "hints + server enforcement"
  reframe — the spec names no carrier for the record-consent POST or the client gate.
- **M15 — N14's 8 s budget is new work, not a move.** Today's `_backgroundBootstrap` runs 4 attempts
  of (12 s + 15 s) with backoff (`splash_screen.dart:274-311`) — the 8 s cap (§5.3) plus the §5.1
  800/1,700 ms foreground split require parameterized bootstrap timeouts in `ApiClient` (consts at
  `api_client.dart:41-42`), a file the spec's §7 list omits.
- **M16 — redirect-vs-N9 race.** Router `redirect` reads `currentUser` synchronously
  (`app_router.dart:105-107`) from the first frame; under the DAG it can fire before N9 completes and
  bounce a deep link to `/signin` pre-restore (today's R4 intent-loss, §3). Spec §7.2.10 adds a drain
  listener but no hold-routing-until-N12 mechanism — splash must remain the routing holder.
- **M17 — BootConfig staleness + key migration.** New `boot_config:$uid` key supersedes never-stale
  `boot_route:$uid`; 7-day bound is a behavior change (stale cache → miss path → 2.5 s budget). Old
  keys need a delete/ignore rule or they linger forever.
- **M18 — `_markTappedNotificationRead` has no migration target.** The 10 s auth wait + mark-read
  (`main.dart:244-256`) dies under the no-timeout invariant, but the bell/badge resync it performs
  must move into the post-auth drain — spec §7.2.6 doesn't mention it.
- **M19 — `lib/util/perf_log.dart` doesn't exist.** Design §7.2 / spec chunk 5 acceptance hooks bind
  to Phase-0 telemetry that isn't on staging (`perf/phase0-telemetry` unmerged; `lib/util/` holds only
  `text_diff.dart`). Chunk 5 needs Phase 0 merged first or file-scoped milestone logging.
- **M20 — trial paywall has no `_load` to guard.** Spec §7.2.9 says "await `_rc.ensureReady()` during
  `initState()`/`_load()`" for both paywalls, but `TrialPaywallScreen` has no `_load` — its RC touch
  points are the gate helpers (`:277,301`) and the purchase path (`:62-67`). PlanScreen's `_load`
  (`plan_screen.dart:176`) matches the spec.
- **M21 — two spec-sketch bugs (minor).** §2.5 `run({entryNodes})` never uses `entryNodes`; the
  non-critical-failure path `_completer.complete(null as T)` throws for non-nullable `T` — needs
  nullable results or a fallback parameter.

Verified-accurate spec citations (spot-checked, no action): `notification_service.dart:250-256`
buggy pattern (§6.2 ✓ byte-exact); `PlanScreen:312` "not available" gate (§6.1 ✓);
`report_cache.dart` route-string cache (§5.2 ✓); bootstrap 12 s/15 s consts (§2.2 ✓);
`users/$uid/profile/main` heuristic path (§5.4 path ✓) — but its `onboarding_completed` predicate
**exists nowhere** in `ayma_flutter/lib` or `functions/` (repo-wide grep, zero hits); use the design
doc's alternative (§5.3: profile exists with name+birthdate) or define the field.

## 6. Implementation touch list (dependency order, rough sizes)

New files (build first, spec §7.1 — all greenfield, verified absent):

| # | File | Contents | Size |
|---|---|---|---|
| N-a | `lib/core/dag/startup_dag.dart` | `StartupDAG`/`StartupNode`/`DAGContext` per §2.5, minus M21 bugs | ~150 new |
| N-b | `lib/models/boot_config.dart` | `BootConfig` per §5.1 + `boot_config:$uid` key + 7-day `isStale` | ~60 new |
| N-c | `lib/services/launch_intent_resolver.dart` | intent taxonomy (§3.1 + M4 classes), `extractIntent` reusing `FcmTokens`, `configureDAGForIntent` | ~120 new |
| N-d | `lib/services/deep_link_queue.dart` | queue per §6.3 + mark-read migration (M18) + warm-tap fast path (R5) | ~150 new |
| N-e | `lib/core/dag/startup_nodes.dart` | 19 node factories with M2/M6/M7 edge corrections | ~220 new |

Modified files (in the order they unblock each other):

| # | File (current lines) | Change | Size |
|---|---|---|---|
| 1 | `services/report_cache.dart` (105) | `hydrateFromPrefs` + `ensureReady` + `read/writeBootConfig`; keep `boot_route` readers during migration, then delete (M17) | +60 / −10 |
| 2 | `services/theme_controller.dart`, `orb_animation_settings.dart`, `meta_integrations.dart` | `+loadFromPrefs(prefs)` each (pure in-mem parse); meta also `+ensureReady` | +15 each |
| 3 | `services/accent_color_controller.dart` | `+loadFromPrefs` (local only) + `+syncRemoteIfMissing(db)`; strip Firestore from `load()` | +25 / −10 |
| 4 | `services/sentry_config.dart` | prefs-injected `loadCached` variant for N18 (keep disk fallback for tests) | +15 |
| 5 | `services/auth_service.dart` (199) | `+instance` singleton, `+_authReadyCompleter`, `+ensureAuthReady`, `+notifyAuthSessionRestored` (M1 seam decision) | +40 |
| 6 | `services/revenuecat_service.dart` (484) | `+_readyCompleter`, `init`→`initDeferred`, `+ensureReady`, guard `plans/activeSubscription/proTrialOffer/purchase/restore` | +60 / −5 |
| 7 | `services/push_service.dart` (194) | delegate cold/warm taps to `DeepLinkQueue`; delete `?? ''` fallback path; keep `syncToken`/`markRead` APIs for N16/drain | ~40 churn |
| 8 | `services/notification_service.dart` (282) | `assert(myUid.isNotEmpty)` in `deepLinkToRoute`; add `plan`/`trial` links only if M3 confirms a sender | +5 (+10 if M3) |
| 9 | `services/api_client.dart` (bootstrap §41-120) | parameterized bootstrap budgets: foreground 800/1,700 ms vs background 8 s (M15; spec omits this file) | +25 |
| 10 | `routing/app_router.dart` (461) | `drainPostAuth` hook on auth change; hold-until-N12 handling for M16; no route-table changes | +25 |
| 11 | `routing/entry.dart` (23) | no change — N12 imports `entryRouteFor` (M13) | +0 |
| 12 | `screens/splash_screen.dart` (484) | optimistic `BootConfig` read on tick 0; 2.5 s foreground budget; `_backgroundBootstrap`→N14 refresher call-out; Firestore-cache heuristic (name+birthdate predicate per §5 note); keep watchdog/retry semantics for the miss path; preserve `_resolveRoute` order + consent POST (M14) | −150 / +90 |
| 13 | `lib/main.dart` (331) | replace serial chain with DAG assembly + intent pre-pass + deferred runner; delete `guardStartupStep`, `_pushWhenPastSplash`, `_markTappedNotificationRead` (superseded by N-d/M18); move entitlement-listener attach after N11 (A8 trap) | −130 / +70 |
| 14 | `screens/plan_screen.dart` | await `_rc.ensureReady()` in `_load`, shimmer while pending | +20 |
| 15 | `screens/trial_paywall_screen.dart` | guard gate helpers + purchase path (no `_load` exists — M20); trial-intent offer prefetch (M5) | +20 |

Tests: 4 new files per spec §7.4 (`startup_dag_test`, `launch_intent_resolver_test`,
`deep_link_queue_test`, `subsystem_readiness_test`, ~120–180 lines each); update
`splash_optimistic_boot_test`, `splash_timeout_test` (all exist — verified); `startup_guard_test`
must be deleted/rewired with `guardStartupStep`; layout matrix stays green (no route changes).

Untouched by design: `MainShellScreen` (warm-up/tour already post-frame), `SignInScreen` (greeting
already post-frame best-effort), `DmThreadScreen` (async fill-in), `AymaSession`, `entry.dart`,
`biometric_consent.dart` (unless M14 moves the gate), `AppCommand*/ScreenCapture/DevPanelSession`
(sync attaches slide into N17 as-is).

## 7. Bugs spotted (noted, not fixed — read-only chunk)

- **B1** (new): accent network fallback unbounded — `main.dart:151` bare-awaits `load()`, whose
  Firestore leg has no timeout (`profile_service.dart:244`). Infinite-hang tail, narrow trigger.
- **B2** (new): `setCrashlyticsCollectionEnabled` awaited unbounded pre-frame — `main.dart:75-77`.
- **B3** (known, spec §6.2): `sortedPairKey('', uid)` → `__<uid>` thread corruption —
  `main.dart:161-164` + `notification_service.dart:253-256`; plus R4 intent-loss via redirect bounce
  (`app_router.dart:118-120`) with no stash.

## 8. Questions for the step-3 implementer / founder (in priority order)

1. M3: does any backend sender emit `plan`/`trial` pushes (or will one)? If no, defer N11 promotion.
2. M1: singleton on `AuthService` vs. a separate readiness holder — which seam?
3. M19: does Phase-0 telemetry merge before Chunk 5, or does step 3 log milestones file-locally?
4. Q4: `drainPostAuth` hook point — splash `_resolve`, router auth listener, or sign-in success?
   (Sign-in success routes to splash via `app_router.dart:121`, so splash is the natural drain site.)
5. M17: 7-day staleness + `boot_route:` legacy-key deletion — approved as specced?
6. M14: confirm the consent-record POST + client consent gate survive as-is under the "hints" reframe.

