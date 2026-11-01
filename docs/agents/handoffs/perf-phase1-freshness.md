# Handoff: perf-phase1-freshness (Chunks 1–3 Complete — Phase 1 Done)

**Branch**: `perf/phase1-freshness`  
**Worktree**: `/home/suhailps/workspace/ayma/.fleet-worktrees/perf-phase1`  
**Author**: Claude-Bedrock (Pairing with Astro / Suhail)  
**Date**: 2026-10-31  
**Chunk 3 author**: Muse Code, 2026-11-01  

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

## 2. Chunk 3 Completion (Server-Ack Writes & Reconcile) — LANDED

### Commit `a974545` (chunk 3a): Firestore writes bound to server ack
- **New `services/write_ack.dart`**: `awaitServerAck(write)` — awaiting a
  Firestore `set()`/`commit()` *is* the server ack, but offline it hangs
  forever; the helper bounds the wait at `kInteractiveTimeout` (8s) and throws
  a friendly `WriteAckException` ("the server did not confirm the write — check
  your connection and retry", renders as a plain sentence for `'… ($e)'` toasts).
  The write stays queued locally and still lands on reconnect; `set`-with-merge
  retries are idempotent so a post-reconnect retry is harmless.
- **Wrapped all 16 direct Firestore writes**: `ProfileService` (7:
  markOnboardingStarted, updateStructuredFields, savePreboarding, setPaused,
  setVoicePreference, setVoiceLanguage, setAccentColor), `NotificationService`
  (6: markRead, markReadMany, markAllRead, dismiss, dismissAll, setPref),
  `WikiService` (3: setUserEdit, resetPage, setVisibility — no UI callers yet,
  bounded so the next caller can't hang).
- **Paused toggle was fire-and-forget** (`settings_screen.dart`:
  `onChanged: (v) => _profiles.setPaused(v)`) — the one true silent-divergence
  bug. Now awaited with an in-flight disable + error toast with Retry; the
  switch is stream-driven so a refusal reconciles itself (flips back).
- **Guarded floating call sites** against the newly-throwing timeout:
  `app_command_service` pause/resume (`.catchError`, dev commands stay
  best-effort); `notification_center_screen` mark-read-all / clear-all /
  swipe-dismiss now await with error toasts + Retry (list is stream-driven,
  rows reconcile on refusal); `_open`'s mark-read stays silent best-effort
  (user asked to open, not to mark read; badge heals on next open).
- **Already-correct, verified not touched**: chat send reconciliation
  (`_reconcilePendingSend` + pending bubble + Retry), voice-pref and notif-pref
  optimistic-rollback, `pending_chat_queue` flush — all confirm on ack already.

### Commit `6227fbc` (chunk 3b): Retry-from-original-input on API writes
- Failure toasts gained a Retry action re-running the exact original input on:
  DM send (composer text + picked attachment retained), like/unlike, match
  accept/reject, profile-settings save (form retained), voice choice + language,
  preboarding save (form retained; retry re-uploads like a manual re-tap does).
- Every Retry target catches internally (house pattern, same as `_verifyFace`),
  so a floating `onPressed` can never produce an unhandled async error.
- **Tests**: `test/write_ack_test.dart` (new: pass-through, timeout→friendly
  exception, refusal propagation) + 5 widget tests (DM / profile-save / paused
  / like / match-respond: refuse → toast + Retry → tap Retry → lands).
- **Verified green**: analyze clean; `write_ack`, `dm_thread_screen`,
  `profile_settings_screen`, `settings_screen`, `public_profile_screen`,
  `matches_screen`, `voice_preference_screen`, `notification_center`,
  `app_command_service`, `api_client`, `fresh_data`, `freshness_indicator`,
  `back_affordance`, `preboarding_voice_autofill`, full `layout_matrix` suites.

## 3. Pending Work (Phase 1 done — do NOT start Phase 2 without founder go-ahead)

Phase 1 per `docs/agents/PERF_PLAN.md` is complete on this branch. Left open:
1. **Astro's Section PC run** (PC3/PC4/PC5 + Section A smoke) on a fix build —
   offline open labelling, offline actions pend/reconcile incl. a forced server
   refusal, mid-session drop failing visibly within budget. Needs a device/emulator.
2. **Phase 2 (Real speed)** per PERF_PLAN — startup flattening, image variants,
   pagination, prefetch. Separate branch/step; not started.

---

## 4. Gotchas & Lessons Learned

1. **`StreamedResponse` vs `Response` in `http.BaseClient`**:
   - `http.StreamedResponse` can only be listened to once. Attempting to share an in-flight `StreamedResponse` between callers throws `StateError: Stream has already been listened to.`. Deduplication must happen at the `Response` level where response bytes are buffered.
2. **Asynchronous Zone Errors with Futures**:
   - When attaching `.whenComplete(() => _inFlightGets.remove(key))` to an in-flight future that might reject with `TimeoutException` or `ApiException`, you must append `.ignore()`. Without `.ignore()`, Dart zones register the `.whenComplete(...)` return future as an unhandled asynchronous error.
3. **Empty Data and `FreshData.mergeMeta`**:
   - In screens with multiple streams (like `MessagesScreen` merging threads and matches), passing `data: null` to `FreshData.mergeMeta` sets `hasData: false`. This causes `FreshData.state` to report `FreshnessState.syncing`, triggering a non-settling spinner. Always pass `data: (a.hasData || b.hasData) ? true : null`.
4. **Firestore write futures complete on server ack — offline they hang, not fail.**
   - `await doc.set(...)` with no connection never resolves; that is why every
     client write needs `awaitServerAck` (or equivalent timeout) — otherwise an
     offline save shows "Saving…" forever instead of failing visibly in budget.
5. **Toast Retry actions are floating futures — the target must catch internally.**
   - `AymaToastAction.onPressed` is a `VoidCallback`; a retry that re-throws
     becomes an unhandled async error. Follow the `_verifyFace` pattern: every
     retry target is an async method with its own try/catch that re-toasts.
6. **Bounding a write changes every floating call site into a potential throw.**
   - After wrapping services with `awaitServerAck`, grep every caller: any
     un-awaited call (`onChanged: (v) => svc.set(v)`, `onTap: () => _open(e)`,
     sync command handlers) needs awaiting or an explicit `.catchError`.
