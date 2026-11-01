# Handoff: perf-phase1-freshness (Chunk 1 & Chunk 2 Complete)

**Branch**: `perf/phase1-freshness`  
**Worktree**: `/home/suhailps/workspace/ayma/.fleet-worktrees/perf-phase1`  
**Author**: Claude-Bedrock (Pairing with Astro / Suhail)  
**Date**: 2026-10-31  

---

## 1. What was done & verified

### Chunk 1 Completion (Fixes & Migrations)
- **Commit `ed4a9ab`**: Fixed `MessagesScreen` where `FreshData.mergeMeta<void>(data: null)` set `hasData: false`, which left `FreshnessIndicator` showing an infinite spinning `CircularProgressIndicator` and broke `test/back_affordance_test.dart`.
- Migrated data consumption to `FreshData` across:
  - `ExploreScreen`
  - `MessagesScreen`
  - `PlanScreen`
  - `MatchService` (`watchMatchesFresh`, `watchMutualMatchesFresh`)
  - `DmService` (`watchThreadsFresh`, `watchMessagesFresh`)
- Added missing test mock overrides (`watchMutualMatchesFresh` in `test/dm_unread_test.dart`).

### Chunk 2: Interactive Timeouts, Deduplication & Retries
- **API Client Budget & Timeouts (`api_client.dart`)**:
  - Enforced interactive timeout budget `kInteractiveTimeout = Duration(seconds: 8)` (down from 25s) across interactive endpoints.
  - Retained `kLongTimeout = Duration(seconds: 55)` for heavy asynchronous/multimodal operations (e.g. `/wiki/photo-publish`).
  - Added support for explicit timeouts via `X-Request-Timeout` header.
  - Wrapped client pipeline with `BudgetHttpClient` that:
    - Automatically translates timeout expirations to `ApiException('Request timed out — please try again.', statusCode: 408)` instead of hanging or bubbling unformatted `TimeoutException`.
    - Collapses concurrent identical `GET` requests (`url` + `Authorization` key) into a single in-flight `Future<http.Response>`.
    - Provides bounded retry (max 2 attempts, 300ms backoff) for idempotent `GET` calls encountering transient 502/503/504 errors, socket `ClientException`, or timeouts within the budget window.
- **Firestore Interactive Reads (`.timeout(kInteractiveTimeout)`)**:
  - `MatchService`: profile fetch and `fetchMatch`.
  - `ProfileService`: `readProfile()` and `getAccentColor()`.
  - `WikiService`: `_read()` public/private pages.
  - `PhotoService`: `_downloadUrl()`.
  - `NotificationService`: `readPrefs()`.
  - `InstagramService`: `status()`.
  - `MetaIntegrations`: flags and status checks.
  - `SentryFlag`: `refresh()`.
- **DM Thread Screen Freshness Wiring (`dm_thread_screen.dart`)**:
  - Switched message listener to `_dm.watchMessagesFresh(widget.threadId)`.
  - Added `FreshnessIndicator.fromFresh(fresh)` under the header so stale/offline/syncing states are clearly visible rather than looking "loaded but dead".
  - Preserved reversed scroll, composer padding, and context truncation.
- **Test Coverage**:
  - Added unit tests in `test/api_client_test.dart` for:
    - 408 status timeout translation.
    - Concurrent GET deduplication.
    - Idempotent GET retry on 503.
    - Extended budget on `photoPublish`.
  - Added test in `test/dm_thread_screen_test.dart` verifying `FreshnessIndicator` display for cached/stale message streams.
  - Verified green suite: `api_client_test.dart`, `fresh_data_test.dart`, `freshness_indicator_test.dart`, `dm_thread_screen_test.dart`, `dm_unread_test.dart`, `back_affordance_test.dart`, and the full `layout_matrix_test.dart`.
  - Clean `flutter analyze` with 0 issues.

---

## 2. Pending Work (CHUNK 3: Server-Ack Writes & Reconcile)

Chunk 2 is complete. The next session should tackle **Chunk 3 of Phase 1** (Do NOT start Phase 2 yet):

1. **Server-Ack Confirmation for Writes**:
   - Per `docs/agents/PERF_PLAN.md` § Phase 1:
     - Bind "saved" or "sent" UI confirmation to server ack (`hasPendingWrites == false` in Firestore snapshot, or successful 200 HTTP response).
     - Never fake-succeed optimistic actions before server confirmation.
     - Surface server refusals honestly with retry built from the original user input.
2. **Optimistic Mutations with Reconciliation**:
   - Wire actions that mutate product data (chat messages via `pending_chat_queue.dart`, likes, profile updates) to show a pending indicator until acknowledged by server.
   - If server rejects, transition to `FreshnessState.refused` or display actionable error toast/banner with retry.

---

## 3. Gotchas & Lessons Learned

1. **`StreamedResponse` vs `Response` in `http.BaseClient`**:
   - `http.StreamedResponse` can only be listened to once. Attempting to share an in-flight `StreamedResponse` between callers throws `StateError: Stream has already been listened to.`. Deduplication must happen at the `Response` level where response bytes are buffered.
2. **Asynchronous Zone Errors with Futures**:
   - When attaching `.whenComplete(() => _inFlightGets.remove(key))` to an in-flight future that might reject with `TimeoutException` or `ApiException`, you must append `.ignore()`. Without `.ignore()`, Dart zones register the `.whenComplete(...)` return future as an unhandled asynchronous error.
3. **Empty Data and `FreshData.mergeMeta`**:
   - In screens with multiple streams (like `MessagesScreen` merging threads and matches), passing `data: null` to `FreshData.mergeMeta` sets `hasData: false`. This causes `FreshData.state` to report `FreshnessState.syncing`, triggering a non-settling spinner. Always pass `data: (a.hasData || b.hasData) ? true : null`.
