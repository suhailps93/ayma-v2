# Performance Phase 2 — Startup-Implementation Audit

**Auditor**: Antigravity (Engineer/Analyst — reassigned from Gemini, whose API keys are quota-dead until the midnight reset)
**Audit date**: 2026-11-19 PT
**Audited tip**: staging `a8535710` (batch 2527, vC 2527) — one batch past the brief's `4a9a0393`; the audit is against current staging, as instructed
**Sources**: `docs/perf/phase2-startup-design.md` (PROPOSED) and `docs/perf/phase2-startup-implementation-spec.md` (Founder Locked Nov 1, 2026)
**Method**: static audit of the merged code at the audited tip, plus test execution. No code changes. No device timing was captured in this audit — the cold-start budgets below are judged from the code, not from a stopwatch.

**Headline**: the DAG architecture, the readiness futures, the BootConfig cache, and the deep-link hard invariant are all implemented and tested. The headline spec budget — 2.5s foreground bootstrap, ≤3s cold start to interactive on cache miss — was **not implemented**; it was deliberately abandoned in favor of a 45s absolute watchdog against a scale-to-zero backend. Everything else is implemented, partially implemented with a documented reason, or moot. Three follow-ups remain (see §4).

**Tests run on the audited tip** (ThinkPad, Flutter 3.47.7): `startup_dag_test`, `launch_intent_resolver_test`, `deep_link_queue_test`, `subsystem_readiness_test`, `splash_optimistic_boot_test`, `splash_timeout_test`, `startup_guard_test` — **37/37 green**; layout matrix shard 0 — **29/29 green**; layout shards 1+2 — **56/56 green**. Total **122/122 green**, zero RenderFlex overflows.

---

## 1. Checklist verdicts — design doc §7.1 and spec §7–§9

### Design Step 1 — Single SharedPreferences preloader + `loadFromPrefs` — IMPLEMENTED (with two notes)
- One preload: `N4:prefs_preload` (`lib/core/dag/startup_nodes.dart`, 3s timeout) puts the singleton in the DAG context; `N5:ui_controllers` hydrates Theme (`lib/services/theme_controller.dart:15`), Accent (`lib/services/accent_color_controller.dart:47`), Meta (`lib/services/meta_integrations.dart:43`), and `ReportCache.hydrateFromPrefs` from it — all local, zero network, before `runApp`.
- **Note 1 — Orb is N/A.** There is no `OrbAnimationSettings` controller anywhere in `lib/` and no git history for `lib/services/orb_animation_settings.dart` (the design doc cites it from the design worktree only). Nothing to hydrate; the checklist item is moot, not missing.
- **Note 2 — Accent `load()` still contains the network call, but it is dead code.** `AccentColorController.load()` (`lib/services/accent_color_controller.dart:119-123`) still awaits `syncRemoteIfMissing()` after the local read. It has **zero callers** in `lib/` or `test/` — `N5` uses `loadFromPrefs` and `N19`/splash call `syncRemoteIfMissing()` in the background. The design's strip is effectively implemented; deleting the Firestore call from the dead `load()` is cleanup, not a fix.

### Design Step 2 — Structured `BootConfig` cache in `ReportCache` — IMPLEMENTED
- `lib/models/boot_config.dart` (46 lines): JSON serialization, `isStale` at 7 days, gate fields reframed as advisory hints (`biometricConsentRequiredHint`, `ageBlockedHint`, `recoveryRequiredHint`).
- `ReportCache.readBootConfig` / `writeBootConfig` (`lib/services/report_cache.dart:117`, `:148`): uid-scoped `boot_config:$uid` keys, legacy `boot_route:$uid` fallback bridge on read, mirror on write, `clearForSignOut` wipes all three prefixes. `ensureReady()` / `hydrateFromPrefs` present.

### Design Step 3 — RevenueCat readiness hook — IMPLEMENTED
- `_readyCompleter` (`lib/services/revenuecat_service.dart:245`), `ensureReady()` with a 4s timeout (`:255`), `initDeferred()` completing it (`:275`). Guarded: `plans()` (`:337`), `proTrialOffer()` (`:427`), `activeSubscription()` (`:503`), `purchase()` (`:536`), `restore()` (`:609`) all await `ensureReady()` first. `PlanScreen` (`lib/screens/plan_screen.dart:287`) and `TrialPaywallScreen` (`:277`, `:302`) await it before loading offerings.

### Design Step 4 — Push deep-link buffering — IMPLEMENTED
- `DeepLinkQueue` (`lib/services/deep_link_queue.dart`, 115 lines): `handleIntent` awaits `AuthService.ensureAuthReady()` with **no timeout fallback**, stashes the intent and routes to `/signin` when unauthenticated, drains post-auth with the confirmed uid. `PushService.listenForTaps` routes cold-start and running taps through the queue (`lib/services/push_service.dart:196+`); `main.dart` passes queue + router + authService. `deepLinkToRoute` asserts non-empty uid (`lib/services/notification_service.dart:267`).

### Design Step 5 — Flatten `main()` — IMPLEMENTED (and exceeded by the DAG)
- `main()` builds the 19-node DAG and awaits only to `N8:first_frame_mount` (`lib/main.dart:80`). Pre-`runApp` is bindings → orientation → crash hooks → prefs preload → local hydration → bounded Firebase (3s) → `runApp`. RevenueCat, Sentry, flags, push sync, dev observers all run post-frame as DAG nodes. The design doc's flattened `main()` sketch was superseded by the spec's DAG (see §2.1).

### Design Step 6 — Splash budget & fallbacks — PARTIALLY IMPLEMENTED (deliberate deviation)
- Optimistic routing: IMPLEMENTED — splash reads `readBootConfig` with legacy fallback and navigates after an 800ms dwell (`lib/screens/splash_screen.dart:357-389`); `N12` does the same from the DAG side.
- Firestore cache heuristic: IMPLEMENTED exactly per spec §5.4 — cache-only read of `users/$uid/profile/main`, 300ms timeout, `name`+`birthdate` or `onboarding_completed` routes to the shell (`lib/screens/splash_screen.dart:480-498`).
- Background bootstrap refresher: IMPLEMENTED — splash `_backgroundBootstrap` with route-divergence correction (`:551-595`) and DAG `N14` (8s timeout).
- **Foreground budget 2.5s: NOT IMPLEMENTED.** `ApiClient` still uses the pre-flattening timeouts — 12s ID-token refresh, 15s POST (`lib/services/api_client.dart:643-644`) — up to 4 attempts with 1/2/4/8s backoff, under a 45s absolute watchdog (`lib/screens/splash_screen.dart:73`). The splash header documents why: Cloud Run scales to zero (~18s+ cold start), and the 2.5s budget hard-failed nearly every cold open (founder-reported). This is a reasoned reversal, not an oversight — but it means the ≤3s cold-start budget is not met on cache miss, by design (see §3.1).

### Spec directive 1 — Parallel DAG init — IMPLEMENTED
- `lib/core/dag/startup_dag.dart` (195 lines): `validate()` (cycle + missing-dependency detection), concurrent scheduling as dependencies resolve, critical-node failure propagation, `run(targetNodes:)` for staged waits. `lib/core/dag/startup_nodes.dart` (513 lines): all 19 nodes N1–N19 with spec-matching dependencies and budgets (N7 Firebase 3s, N6 intent 1s, N11 RevenueCat 4s, N14 refresher 8s, N18 Sentry 5s). Two documented dependency corrections: N5 also depends on N7 (lazy controller construction binds `FirebaseAuth` — running it first threw `[core/no-app]`), and N6 also depends on N7 (FCM `getInitialMessage` safety).

### Spec directive 2 — LaunchIntentResolver + route-scoped promotion — IMPLEMENTED (one dead step)
- `lib/core/dag/launch_intent_resolver.dart` (231 lines) — **note the path**: the spec §7.1 says `lib/services/launch_intent_resolver.dart`; the code lives under `lib/core/dag/`. Same content, different location. Taxonomy matches the spec plus extra branches (match_request, match, deep_dive, date_sim, matches, profile_suggestions). `resolveForStartup` carries the 1s bound the spec's N6 requires, so the pre-frame intent resolve can never gate the first frame.
- Promotion: the paywall edge N11→N12 is added, and DM/generic add N9→N12. **But the "mark N11 critical" step is a no-op**: `configureDAGForIntent` contains an empty `if (dag.nodes.containsKey('N11:revenuecat_init')) { // ensure node is marked critical }` block — the node is never actually marked critical. If N11 fails or times out, N12 routes to the paywall anyway and `PlanScreen`'s `ensureReady()` (4s) falls back to fallback plans. User-visible behavior is preserved by the guard, so impact is minor — but the spec step is unexecuted (see §4.2).

### Spec directive 3 — Readiness futures as the ONLY access path — PARTIALLY IMPLEMENTED
- `ensureReady()` exists on RevenueCat, AuthService, ReportCache, MetaIntegrations, and PushService, and every guarded method awaits it. But the absolute invariant ("no screen/service reads naked synchronous state") is not enforced as written: the router redirect reads `FirebaseAuth.instance.currentUser` synchronously, `MetaIntegrations.enabled.value` is read synchronously by widgets (by design — hydrated pre-frame in N5), and the splash reads `auth.currentUser` directly with only a 2s `ensureAuthReady` wait. These are pragmatic, documented exceptions. The implemented rule is "readiness-gated where the subsystem can be uninitialized at first use," not the spec's absolute rule.

### Spec directive 4 — BootConfig routing-only — IMPLEMENTED (one inconsistency)
- Hints are advisory-only in the model; gates are enforced server-side per API call (401/403 → sign-in; recovery/age/biometric routing via `_resolveRoute`); the background bootstrap is a refresher, not a gatekeeper.
- **Inconsistency**: `N14` builds its refreshed `BootConfig` without the hint fields (`lib/core/dag/startup_nodes.dart:360-368`), while the splash's `_cacheEntryRoute` includes them. A config refreshed by N14 erases gate hints. Advisory-only, so no correctness impact — but the hints are unreliable after an N14 refresh.

### Spec directive 5 — Deep-link queue hard invariant — IMPLEMENTED
- No timeout fallback in `DeepLinkQueue.handleIntent`; stash + `/signin` on unauthenticated; `drainPostAuth` with the confirmed uid; `assert(myUid.isNotEmpty)` in both `_resolvePathForIntent` and `deepLinkToRoute`. Bonus beyond the spec: `clearPendingIntent()` drops a stashed intent on account switch so a link queued by a signed-out account never drains into the next account (ghost-header R2-C6/R2-C7).

### Spec §7.3 deletions — PARTIALLY DONE
- Blocking `SentryFlutter.init` with the appRunner zone wrapper: GONE from `main()`; Sentry is now N18, background, 5s timeout, flag-gated. Done.
- `guardStartupStep`: NOT deleted — kept in `main.dart` as `@visibleForTesting` for `startup_guard_test.dart`. The spec said delete; the code kept it as a test-compat shim. Harmless, but the spec step is unexecuted.
- Splash retry loops: NOT removed — replaced by 4 attempts, 1/2/4/8s backoff under the 45s absolute watchdog. Deliberate (see Step 6).

### Spec §7.2 telemetry acceptance hooks — REPLACED IN FORM, EQUIVALENT IN FUNCTION
- `PerfLog` (`lib/util/perf_log.dart`) does **not** exist. The design doc's `[PerfLog] [milestone]` format was never implemented. Its role is filled by `BootTrace` (`lib/core/dag/boot_trace.dart`), emitting `[boot+NNNNms] label` marks in debug/profile builds at main entry, intent resolve, every DAG node start/done/fail, auth ticks, and splash resolve/navigation. Same diagnostic purpose, different format.

---

## 2. Deviations between the spec and the code as merged

### 2.1 The 37f3759 flattening and its follow-up boot fixes
The flattening landed as merge `37f3759` (DAG engine `f8cab4c7`, design `a93480d7`, spec `d05aaf12`). The follow-up boot fixes since then, all on the startup path:
- `3da30723` P0 boot crash: listeners (`PushService()`, auth) registered before N7 threw `[core/no-app]` and aborted `main()` on the splash. Fixed by registering them only after `dag.run(N8)` returns (`lib/main.dart` documents the ordering).
- `c47067d3` bound the pre-`runApp` launch-intent resolve to 1s and added the `BootTrace` timeline (restore-splash-slow).
- `2c8512b8` restore-splash cold-launch optimization + bounded presentation gates (NOTE 250 Item 5).
- `184e0f6b` test pinning the splash never gates on auth restore (NOTE 246).
- `2f3c345a` hydrate the saved profile accent on sign-in before first paint (NOTE 236).
- `15e28081` / `30690ba4` / `7de64117` deferred the startup location-permission ask out of the cold-start window and serialized its retry (NOTE 239/242/244 — the ask used to compound the input-dispatch ANR and get the process reaped).
- `b98982fd` systemic nav/auth teardown on sign-out/switch (ghost-header R2-C6/R2-C7), including `DeepLinkQueue.clearPendingIntent`.
- `b3d90f70` `FirebaseConfigGuard` honest error on wrong-project (mixed-build) APK instead of a silent 401 loop (NOTE 263).
- `ef257478` NOTE 273: cold-start retries on story photos/Plan, the splash watchdog made an **absolute** wall-clock deadline (the old watchdog re-armed from zero on every connectivity event, so "Waking up Ayma" hung 8+ min), seeded-header tap prefetch, profile signing guard.
- `de4cfacc` remote flag refresh budget expanded to 25s with auto-retry (NOTE 140); N19 uses `kStartupFlagRefreshTimeout` = 25s (`lib/services/api_client.dart:24`).

### 2.2 Design decisions that superseded the spec (all documented in-code)
1. **The 2.5s foreground budget was abandoned** (see Step 6): 12s + 15s ApiClient timeouts, 4 attempts, 45s absolute watchdog. The spec's headline number is unachievable against a scale-to-zero backend without a backend change.
2. **The splash must be visible ≥800ms.** `minSplashDwell` (800ms) plus the `SplashFirstPaint` presentation gate (loader fix round 3, Scout 2295: the wake line displayed only 1/3 cold starts without it) mean optimistic navigation waits for a *presented* frame plus a real-time dwell. Warm-cache interactive is therefore ~800ms+, not instant — right at the spec's ≤800ms warm budget boundary.
3. **Dual ownership of optimistic routing.** Both the splash's `_resolve` and DAG `N12` navigate on a cached route, and both start a background bootstrap (splash `_backgroundBootstrap` and `N14`). Same destination, so harmless — but on an optimistic launch where the splash wins the race, **two concurrent `POST /bootstrap` calls fire**. Cleanup, not a defect.
4. **The splash's own auth wait has a 2s timeout** (`lib/screens/splash_screen.dart:336-346`): if `currentUser` is null it awaits `ensureAuthReady()` for at most 2s, then proceeds with whatever `currentUser` is. The design doc's Tier 2 allows a 1.5s budget, so this is consistent with the design — but it is a timeout fallback on the *splash* path, while the spec's hard invariant (no timeout) governs the *DeepLinkQueue* path. A KeyStore restore slower than 2s can still route a signed-in user to `/signin` (see §3.3).
5. **`main()`'s comment is stale in one line**: it calls the pre-frame intent resolve "the ONLY unbounded await on the pre-first-frame path" and then bounds it to 1s in the same comment block. The code is bounded (`resolveForStartup`, 1s); only the wording contradicts itself.

### 2.3 Small unexecuted spec steps (collected)
- N11 never marked critical on paywall promotion (§1, directive 2).
- `guardStartupStep` kept as a test shim instead of deleted (§1, §7.3).
- `PerfLog` format never implemented; `BootTrace` substituted (§1, §7.2).
- `LaunchIntentResolver` lives at `lib/core/dag/` instead of the spec's `lib/services/` (§1, directive 2).
- `N14` drops BootConfig hint fields (§1, directive 4).

---

## 3. Risks that remain

1. **Cold-start budget ≤3s is not met on cache miss, by design.** First-install / post-sign-out users wait on 12s+15s bootstrap timeouts with retries under a 45s watchdog. Any future "≤3s" claim needs a backend keep-warm or a different bootstrap contract — no client-side change can meet it while Cloud Run scales to zero.
2. **Paywall deep link with a dead/slow RevenueCat init.** N11 is not critical, so N12 routes to the paywall anyway; `PlanScreen` then waits out its 4s `ensureReady()` and falls back to fallback plans. Contained, but the promotion's critical half is unexecuted — a paywall deep link in the first ~4s can still show a degraded paywall.
3. **Splash auth wait can still bounce a signed-in user.** A KeyStore/Keychain restore slower than the splash's 2s `ensureAuthReady` timeout routes to `/signin` (the user must sign in again to recover a valid session). Narrow window, but it is the exact failure the hard invariant was written to prevent — on the one path the invariant does not cover.
4. **Flag-dependent UI can shift up to ~25s after launch.** N19 refreshes Meta/Sentry/debug flags in the background with a 25s budget and auto-retry; the cached value is used meanwhile, so a first launch after a flag flip shows the stale value until the refresh lands.
5. **`AuthService.ensureAuthReady` is single-use.** After the first completion it returns the *first* user forever, even after sign-out/sign-in as a different account in the same process. No current caller hits it post-switch (callers are N9, DeepLinkQueue cold-start, splash), but any future caller would get a stale user. The completer should be re-armable on auth change.
6. **Legacy `boot_route` never expires.** `readBootConfig` synthesizes a fresh `BootConfig` from a legacy key with `cachedAtEpochMs: now`, so a stale legacy route is trusted indefinitely until a real `boot_config` is written. Harmless once any successful bootstrap writes a config; a user who never completes a bootstrap keeps the legacy route forever.
7. **First-frame ≤350ms / warm ≤800ms / cold ≤3000ms were not verified on-device in this audit.** `BootTrace` marks exist to measure them, but no device timing was captured here. The 800ms dwell alone puts warm interactive at the budget boundary. Device verification is Scout's job.

---

## 4. Top 3 recommended next implementation steps

1. Decide the cold-start budget honestly: fund a backend keep-warm / faster bootstrap, or formally restate the cache-miss budget (e.g. ≤10s with the 45s watchdog as the failure ceiling) — the 2.5s spec number is unachievable against a scale-to-zero backend.
2. Finish the paywall promotion: mark N11 critical in `configureDAGForIntent` (execute the dead code block) and add a test that a failed N11 blocks N12 on a paywall intent.
3. Collapse the dual optimistic-routing ownership: make N12 the single owner of cached-route navigation and background refresh, and have the splash's `_resolve` handle only the cache-miss foreground path — ending the double-bootstrap race.
