# Handoff: Performance Phase 0 Telemetry (Baseline Measurement)

**Task**: `perf-phase0-telemetry`  
**Branch**: `perf/phase0-telemetry`  
**Date**: 2026-10-31  
**Author**: Claude Code (Bedrock)  
**Coordination**: Astro (Muse) / Suhail (Founder)

---

## 1. Summary of Changes

Implemented Phase 0 (measurement baseline ONLY) of Ayma's loading-performance work in the Flutter mobile application without any behavior, UI, timeout, or retry changes:

1. **Lightweight Debug-Only `PerfLog` Utility (`lib/util/perf_log.dart`)**:
   - Initialized at the start of app startup (`PerfLog.start()`).
   - Tracks app-start milestones with elapsed milliseconds:
     - `Firebase init complete` (`main.dart` after `Firebase.initializeApp`).
     - `First frame rendered` (`main.dart` via `WidgetsBinding.instance.addPostFrameCallback` after `runApp`).
     - `Backend bootstrap complete` (`splash_screen.dart` after `/bootstrap` call resolves).
   - All logging is strictly guarded by `if (!kDebugMode) return;` — zero execution and zero overhead in release builds.

2. **API Client Request Timing (`lib/services/api_client.dart`)**:
   - Created `_TimingHttpClient` (an `http.BaseClient` wrapper) hooked into `ApiClient` in debug builds only (`kDebugMode`).
   - Measures duration via `Stopwatch` across every API call.
   - Logs method, path (with query params if present), HTTP status code / error, success/failure (`SUCCESS` / `FAILED`), and duration in milliseconds.
   - Rethrows all network exceptions unchanged to preserve exact failure semantics.

3. **Firestore Listener Cache vs. Server Tracking**:
   - Added `PerfLog.firestoreSnapshot` calls across all 10 existing Firestore listener/stream locations in the app:
     - `AppCommandService`: `users/$uid/app_commands/pending`
     - `DmService`: `dm_threads` (threads list)
     - `DmService`: `dm_threads/$threadId/messages` (messages stream)
     - `NotificationService`: `users/$uid/notifications` (recent notifications)
     - `NotificationService`: `users/$uid/notifications [read=false]` (unread count)
     - `ProfileService`: `users/$uid/profile/main` (profile stream)
     - `ProfileService`: `users/$uid/profile/main [paused]` (paused matching flag)
     - `DevPanelFlag`: `app_config/dev_panel` (developer panel flag)
     - `MatchService`: `matches [status=scored]` (new match proposals)
     - `MatchService`: `matches [status=mutual_interest]` (mutual matches)
   - Reads `SnapshotMetadata.isFromCache` and `hasPendingWrites` to log whether each snapshot arrived from `CACHE` or `SERVER`, along with doc counts when applicable.

---

## 2. Sample Log Output Format

### App Start Milestones
```text
[PerfLog] [app_start] timer initialized
[PerfLog] [milestone] Firebase init complete (+142ms)
[PerfLog] [milestone] First frame rendered (+315ms)
[PerfLog] [api] POST /bootstrap -> 200 (SUCCESS) in 210ms
[PerfLog] [milestone] Backend bootstrap complete (+530ms)
```

### API Client Timing
```text
[PerfLog] [api] POST /bootstrap -> 200 (SUCCESS) in 198ms
[PerfLog] [api] GET /usage?period=all -> 200 (SUCCESS) in 112ms
[PerfLog] [api] POST /chat/stream -> 200 (SUCCESS) in 345ms
[PerfLog] [api] POST /billing/sync -> 200 (SUCCESS) in 165ms
[PerfLog] [api] POST /bootstrap -> ERROR (FAILED) in 48ms (ClientException: Network error: Connection refused)
```

### Firestore Snapshots (Cache vs. Server)
```text
[PerfLog] [firestore] users/u123/profile/main snapshot from CACHE [pending writes]
[PerfLog] [firestore] users/u123/profile/main snapshot from SERVER
[PerfLog] [firestore] dm_threads snapshot from SERVER (3 docs)
[PerfLog] [firestore] dm_threads/u123__u456/messages snapshot from SERVER (18 docs)
[PerfLog] [firestore] users/u123/notifications snapshot from SERVER (1 docs)
[PerfLog] [firestore] users/u123/notifications [read=false] snapshot from SERVER (1 docs)
[PerfLog] [firestore] matches [status=scored] snapshot from SERVER (2 docs)
[PerfLog] [firestore] matches [status=mutual_interest] snapshot from SERVER (1 docs)
[PerfLog] [firestore] app_config/dev_panel snapshot from SERVER
[PerfLog] [firestore] users/u123/app_commands/pending snapshot from SERVER
```

---

## 3. Files Changed

- `ayma_flutter/lib/util/perf_log.dart` (new): Debug-only performance logger utility with milestone, API, and Firestore snapshot logging.
- `ayma_flutter/lib/main.dart`: Timer start, `Firebase init complete` milestone, and `trackFirstFrame` hook.
- `ayma_flutter/lib/screens/splash_screen.dart`: `Backend bootstrap complete` milestone after `/bootstrap` completes.
- `ayma_flutter/lib/services/api_client.dart`: `_TimingHttpClient` wrapper added for debug builds to log request timing.
- `ayma_flutter/lib/services/app_command_service.dart`: Snapshot origin logging for pending app commands.
- `ayma_flutter/lib/services/dm_service.dart`: Snapshot origin logging for DM threads and thread messages.
- `ayma_flutter/lib/services/notification_service.dart`: Snapshot origin logging for notification list and unread count.
- `ayma_flutter/lib/services/profile_service.dart`: Snapshot origin logging for profile and paused matching flag.
- `ayma_flutter/lib/services/dev_panel_flag.dart`: Snapshot origin logging for dev panel flag.
- `ayma_flutter/lib/services/match_service.dart`: Snapshot origin logging for scored and mutual matches.
- `ayma_flutter/test/perf_log_test.dart` (new): 10 unit and widget tests covering all milestones, API timings, and Firestore snapshot logs.
- `docs/agents/handoffs/perf-phase0-telemetry.md` (new): This handoff document.

---

## 4. Tests Run and Results

1. **`flutter analyze`**:
   - Result: `No issues found! (ran in 3.6s)` (0 errors, 0 warnings, 0 lints).
2. **`flutter test test/perf_log_test.dart`**:
   - Result: 10 passed, 0 failed.
3. **`flutter test test/splash_routing_test.dart test/app_command_service_test.dart test/dm_unread_test.dart test/notification_unread_count_test.dart`**:
   - Result: 44 passed, 0 failed.
4. **Full Test Suite Baseline**:
   - Result: 1040 passed, 1 known pre-existing failure (`chat_scroll_to_bottom_test.dart: a message that arrives mid-drag still lands scrolled to the bottom once the drag ends`, documented in `docs/AGENT_HANDOFF.md` §3 as known test noise).

---

## 5. What Remains

- Phase 0 deliverable is complete and verified.
- Next in Astro's Performance & Cache Plan:
  - **Phase 1: Freshness correctness** (`isFromCache`/`hasPendingWrites` states in UI, eliminate "looks loaded but dead" states, ≤8s interactive timeouts).
  - **Phase 2: Speed optimizations** (startup waterfall flattening, image variants with `CachedNetworkImage`/`cacheWidth`, pagination, prefetching).
  - **Phase 3: Skeletons & perceived performance**.
