# Handoff: Perf Phase 2 Step 3 — Startup Flattening

**Task**: Perf Phase 2 Step 3: Startup Flattening  
**Branch**: `antigravity/phase2-step3-startup` (tracked on origin)  
**Worktree**: `.fleet-worktrees/phase2-step3`  
**Base Commit**: `75eb2d2` (`origin/staging`)  
**Author**: Antigravity (Engineer)  
**Date**: 2026-11-01  
**Status**: IN PROGRESS (Stage 3 Complete)

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

- [x] **Stage 3: Launch Intent Resolver & DeepLinkQueue**
  - Created `ayma_flutter/lib/core/dag/launch_intent_resolver.dart`: Implemented `LaunchIntent` taxonomy (`IconLaunchIntent`, `PaywallDeepLinkIntent`, `DmDeepLinkIntent`, `GenericDeepLinkIntent`), native extraction pipeline (FCM initial message + native chat method channel), and dynamic critical path promotion (`configureDAGForIntent` promoting N11 to critical path on paywall intent).
  - Created `ayma_flutter/lib/services/deep_link_queue.dart`: Implemented queue enforcing hard auth invariant (awaits `authService.ensureAuthReady()` with zero timeout fallback), unauthenticated intent stashing to `_pendingPostAuthIntent` with `/signin` navigation, and post-auth replay via `drainPostAuth(uid)`.
  - Updated `ayma_flutter/lib/services/notification_service.dart`: Added `assert(myUid.isNotEmpty)` in `deepLinkToRoute` and mapped `plan` and `trial` deep links.
  - Updated `ayma_flutter/lib/services/push_service.dart`: Added `ensureReady()` / `initDeferred()` and delegated cold/warm taps to `DeepLinkQueue.instance.handleIntent` while retaining backwards-compatible `resolveRoute` fallback.
  - Tests added: `ayma_flutter/test/launch_intent_resolver_test.dart` (4/4 passed), `ayma_flutter/test/deep_link_queue_test.dart` (3/3 passed), `ayma_flutter/test/push_service_test.dart` (13/13 passed).

- [ ] **Stage 4: Main Entrypoint & SplashScreen Integration**
  - Create `ayma_flutter/lib/core/dag/startup_nodes.dart` defining node catalog factories (N1 through N19).
  - Refactor `main.dart` to assemble and execute `StartupDAG` up to N8, dynamic promotion, and trigger post-frame background DAG unawaited.
  - Refactor `SplashScreen` to use optimistic `BootConfig`, 2.5s budget, and background refresher.
  - Update existing tests (`splash_optimistic_boot_test.dart`, `splash_timeout_test.dart`).

- [ ] **Stage 5: Full Verification & Layout Matrix**
  - Full Flutter suite clean (1320+ tests).
  - Backend suite clean (matching the 2 pre-existing failures).

---

## 3. Divergence Log & Code-Map Verification

1. **`test_router_split.py` on clean staging**: Fixed route inspection in `_app_route_map` to traverse `original_router.routes` on `_IncludedRouter` entries; all 6 tests in `test_router_split.py` now pass.
2. **Phase 1 Freshness Base**: `ProfileService.getAccentColor()` was bounded to 8s (`kInteractiveTimeout`) in commit `a974545`. In Stage 1, `AccentColorController.loadFromPrefs` completely isolates `runApp` from any Firestore call; remote sync runs unawaited via `syncRemoteIfMissing`.
3. **M1 Seam Decision**: `AuthService.instance` added alongside instance fields, preserving mock-injectable constructor `AuthService({FirebaseAuth? auth, ProfileService? profileService})`.
4. **M20 Paywalls**: `PlanScreen._load` awaits `_rc.ensureReady()`. `TrialPaywallScreen` gate helpers (`showDailyTrialPaywall`, `showOnboardingPaywall`) await `rc.ensureReady()` before inspecting `rc.enabled`.
