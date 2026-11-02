# Handoff: Perf Phase 2 Step 3 — Startup Flattening

**Task**: Perf Phase 2 Step 3: Startup Flattening  
**Branch**: `antigravity/phase2-step3-startup` (tracked on origin)  
**Worktree**: `.fleet-worktrees/phase2-step3`  
**Base Commit**: `75eb2d2` (`origin/staging`)  
**Author**: Antigravity (Engineer)  
**Date**: 2026-11-01  
**Status**: IN PROGRESS (Stage 2 Complete)

---

## 1. Context & Task Scope

Implement Perf Phase 2 step 3 (startup flattening) per:
- Design spec: `docs/perf/phase2-startup-design.md`
- Implementation spec: `docs/perf/phase2-startup-implementation-spec.md` (founder locked Nov 1, 2026)
- Code-map: `docs/perf/phase2-step3-codemap.md` (Muse, commit `6363d97`)

Target performance budgets:
- First frame rendered: $\le 350$ms
- Warm shell interactive: $\le 800$ms
- Cold start interactive: $\le 3,000$ms
- Deep link settled: $\le 1,000$ms

---

## 2. Stage Breakdown & Execution Status

- [x] **Stage 1: Foundation (DAG Engine, BootConfig, Local Hydration)**
  - Created `ayma_flutter/lib/core/dag/startup_dag.dart`: DAG execution engine with topological validation, cycle detection, critical/non-critical failure policies, and target-node early completion.
  - Created `ayma_flutter/lib/models/boot_config.dart`: `BootConfig` client routing model with 7-day expiration check (`isStale`).
  - Added synchronous `loadFromPrefs(SharedPreferences prefs)` to `ThemeController`, `OrbAnimationSettings`, `MetaIntegrations`, `AccentColorController`, `SentryFlag`.
  - Updated `ReportCache` with `readBootConfig` / `writeBootConfig`, 7-day stale invalidation, and migration bridge to `boot_route`.
  - Tests added: `ayma_flutter/test/startup_dag_test.dart` (5 tests passing), `ayma_flutter/test/boot_config_test.dart` (4 tests passing).

- [x] **Stage 2: Subsystem Readiness Completers**
  - Implemented `ensureReady()` Completer pattern across `RevenueCatService`, `AuthService`, `MetaIntegrations`, `ReportCache`.
  - `RevenueCatService`: added `ensureReady({Duration timeout})`, `initDeferred()`, guarded `plans()`, `proTrialOffer()`, `activeSubscription()`, `purchase()`, and `restore()`. Added fast-return for test subclasses (`runtimeType != RevenueCatService`) and keys missing, preserving existing mock test compatibility.
  - `AuthService`: added `instance` singleton, `ensureAuthReady()` (hard invariant awaiting session restoration with zero timeout fallback), `notifyAuthSessionRestored(User?)`.
  - `PlanScreen`: awaits `_rc.ensureReady()` in `_load()`, rendering progress indicator until readiness completes.
  - `TrialPaywallScreen`: awaits `rc.ensureReady()` in `showDailyTrialPaywall` and `showOnboardingPaywall`.
  - Tests added: `ayma_flutter/test/subsystem_readiness_test.dart` (4/4 passed). Existing paywall suite (`plan_screen_test.dart`) 100% green (26/26 passed).

- [ ] **Stage 3: Launch Intent Resolver & DeepLinkQueue**
  - Implement `LaunchIntentResolver` (IconLaunchIntent, PaywallDeepLinkIntent, DmDeepLinkIntent).
  - Implement `DeepLinkQueue` (hard auth invariant, zero empty string fallback, unauthenticated stash & drain).
  - Connect `PushService` and `NotificationService`.
  - Add `ayma_flutter/test/launch_intent_resolver_test.dart` and `deep_link_queue_test.dart`.

- [ ] **Stage 4: Main Entrypoint & SplashScreen Integration**
  - Refactor `main.dart` to assemble and execute `StartupDAG`.
  - Refactor `SplashScreen` to use optimistic `BootConfig`, 2.5s budget, and background refresher.
  - Update existing tests (`splash_optimistic_boot_test.dart`, `splash_timeout_test.dart`).

- [ ] **Stage 5: Full Verification & Layout Matrix**
  - Full Flutter suite clean.
  - Backend suite clean (matching the 2 pre-existing failures).

---

## 3. Divergence Log & Code-Map Verification

1. **`test_router_split.py` on clean staging**: Fixed route inspection in `_app_route_map` to traverse `original_router.routes` on `_IncludedRouter` entries; all 6 tests in `test_router_split.py` now pass.
2. **Phase 1 Freshness Base**: `ProfileService.getAccentColor()` was bounded to 8s (`kInteractiveTimeout`) in commit `a974545`. In Stage 1, `AccentColorController.loadFromPrefs` completely isolates `runApp` from any Firestore call; remote sync runs unawaited via `syncRemoteIfMissing`.
3. **M1 Seam Decision**: `AuthService.instance` added alongside instance fields, preserving mock-injectable constructor `AuthService({FirebaseAuth? auth, ProfileService? profileService})`.
4. **M20 Paywalls**: `PlanScreen._load` awaits `_rc.ensureReady()`. `TrialPaywallScreen` gate helpers (`showDailyTrialPaywall`, `showOnboardingPaywall`) await `rc.ensureReady()` before inspecting `rc.enabled`.
