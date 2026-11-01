# Handoff: Perf Phase 2 Chunk B — Startup Flattening Design

**Task**: Perf Phase 2 PREP chunk B: startup-flattening DESIGN ONLY  
**Branch**: `perf2-startup-design`  
**Date**: 2026-11-01  
**Author**: Antigravity (Engineer)  
**Deliverable**: `docs/perf/phase2-startup-design.md`  

---

## 1. Summary of Deliverable

Completed the full architectural design for Phase 2 startup flattening in `docs/perf/phase2-startup-design.md`.

The document covers:
1. **Trace of Current Startup Waterfall**: Detailed code trace with exact file:line evidence across `main.dart`, `splash_screen.dart`, `api_client.dart`, `theme_controller.dart`, `accent_color_controller.dart`, `orb_animation_settings.dart`, `meta_integrations.dart`, and `revenuecat_service.dart`.
2. **Three-Tier Classification**: Strict classification of every init operation into Tier 1 (Must Block First Frame), Tier 2 (Must Precede Auth Routing), and Tier 3 (Deferrable Post-`runApp` in unawaited background futures).
3. **Proposed Flattened Architecture**: Sequence diagram, timing budgets, and refactored `main()` skeleton. Targets first frame in ≤350ms.
4. **`bootstrap()` Redesign**:
   - Short foreground timeout budget: **2.5s** total (down from 27s max).
   - Structured `BootConfig` model stored in `SharedPreferences` scoped by `uid`.
   - 7-day staleness bound for optimistic cold starts.
   - Cache-miss + backend-down fallback strategy utilizing local Firestore cache heuristic.
5. **Failure Mode Mitigations**:
   - RevenueCat paywall readiness: `_readyCompleter` + `ensureReady()` future to prevent disabled purchase buttons.
   - Push deep links: Queued dispatch until auth and initial routing settle, preventing corrupt `__<uid>` thread IDs.
   - Flag-dependent UI: Synchronous cache hydration from preloaded `SharedPreferences` to eliminate route redirects and UI flicker.
6. **Implementation Checklist & Acceptance Hooks**:
   - Explicit telemetry milestones hooked into `PerfLog` (cold start, first frame, interactive).
   - Cold start target budget: **≤ 3.0s** to interactive.

---

## 2. Top 3 Architectural Findings

1. **Hidden Network Round-Trip in Pre-`runApp()` Chain**:
   `accentColorControllerGlobal.load()` was making an unbudgeted Firestore read (`_profiles.getAccentColor()`) whenever local storage lacked an accent color, stalling `main()` before `runApp()` could run.
2. **Multi-Layered Cascading Timeouts on Splash**:
   `_bootstrapTokenTimeout` (12s) plus `_bootstrapPostTimeout` (15s), combined with 4 auto-retries and exponential backoff sleeps (10s total), created an interactive worst-case delay of 20 seconds for cold or flaky launches.
3. **RevenueCat and Deep Link Race Vulnerability**:
   Moving RevenueCat and push listeners after `runApp` creates critical edge-case races (e.g. paywall screens reporting "subscriptions disabled" or cold push taps resolving with empty user IDs) unless guarded by explicit readiness futures and deferred intent queues.
