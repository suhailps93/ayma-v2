# PC5 & PC6 Offline/Throttling Failure Analysis & Fix Design

- **Author**: Antigravity (Engineer)
- **Recipients**: Astro (PM), Scout (QA Lead), Claude (Lead Engineer)
- **Date**: 2026-11-02
- **Baseline**: Staging `c06ba66` (versionCode 2246 / 2245 suite)
- **Branch**: `antigravity/pc5pc6-offline-analysis` (worktree: `~/workspace/ayma/.fleet-worktrees/pc5pc6-analysis`)
- **Status**: ANALYSIS ONLY (Code-read + Trace + Fix Design; zero app code edits)

---

## Executive Summary

During Scout's QA sweep on staging (`3a1541d`/2245), two `[S2]` offline/throttling defects were uncovered and queued for Claude's wrap-up batch:
1. **PC5**: After radios restore, a chat message sent while/right before offline wedges permanently into a `"Waiting for a connection…"` phantom bubble, offers no retry action, never reaches the server, and silently vanishes upon tab navigation or relaunch.
2. **PC6**: Under UMTS (3G throttling), Explore shows an 8s full-screen spinner, then aborts with raw exception text `Could not load Explore (ApiException(Request timed out — please try again., status 408)).`, providing zero retry affordance, no pull-to-refresh, and no cached feed fallback.

Both issues have been verified against the codebase. **Zero contradictions** exist between Scout's empirical bench reports and the source code. Below is the comprehensive trace, file:line evidence, root causes, and engineer-sized fix designs.

---

## 1. PC5 Analysis — Chat Send Offline Wedging & Phantom Bubble

### 1.1 Scout's Empirical Finding
> **PC5 FAIL [S2]** (`ayma-inbox/scout.md:186`): Chat send at 05:22:50 with radios killed ~1s later mid-flight. Client showed `"Reconnecting…"` by +6s, then `"Waiting for a connection…"` at +30s, and was STILL waiting ~100s after radios were restored; leaving/re-entering chat did not clear it. Server truth (`GET /chat/history`): message never arrived — it existed only as a local phantom bubble, gone after force-stop relaunch. No failure state, no retry offered; recovery required an app relaunch.
>
> **PC4 FAIL [S2]** (`ayma-inbox/scout.md:172`): Message composed while offline entered `"Waiting for a connection…"`. After radios restored, the message sat in `"Waiting"` for 3+ min, and after tab navigation it **vanished** — `GET /chat/history` confirms it never reached the server.

### 1.2 Code-Level Trace & Root Cause (File:Line Evidence)

#### A. The Send Path & Lack of Persistent Queueing
- File: [`ayma_flutter/lib/screens/chat_screen.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1714-L1772)
- Lines 1720–1727:
  ```dart
  if (retry == null && image == null && _canQueue && !_queue.isEmpty) {
    setState(_composerController.clear);
    unawaited(_queue.enqueue(
      QueuedChatMessage(clientMsgId: newClientMsgId(), message: message),
    ));
    unawaited(_queue.flushIfFunded());
    return;
  }
  ```
  `_queue` (`PendingChatQueue`) is **only** used if `!_queue.isEmpty`. By design ([`pending_chat_queue.dart:13-64`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/services/pending_chat_queue.dart#L13-L64)), `PendingChatQueue` is exclusively an "out of credits" hold (`usage_capped: true`), persisted to `SharedPreferences`. Normal user sends while funded **completely bypass** persistent queuing.
- Lines 1766–1772:
  ```dart
  optimisticTurn = _store.addTurn(
    TurnRole.user,
    message,
    TurnSource.text,
    imageFile: image,
  );
  ```
  The user turn is added **in-memory only** to `_store` (`TranscriptStore`).
- Line 1825:
  ```dart
  _store.addPending('Thinking…');
  ```
  A non-final placeholder bubble is appended to `_store`.

#### B. The Mid-Flight Drop & Initial Reconcile Transition
- Lines 1939–1970: `_api.chatStream(...)` is called. When radios are cut, the streaming HTTP connection aborts with a socket/transport exception.
- Lines 1971–1976:
  ```dart
  } on ApiException {
    result = await resend();
  }
  ```
  The stream failure falls back to `resend()` (`_api.chat(...)`, line 1910).
- Because radios are offline, `resend()` immediately fails and throws an `ApiException` wrapping a `SocketException` or `ClientException` (`Network error: ...`).
- Lines 2018–2036:
  ```dart
  } on ApiException catch (e) {
    if (!mounted) return;
    if (_shouldReconcile(e)) {
      _beginReconcile(_PendingSendReconcile(
        msgId: msgId,
        message: message,
        knownAyma: knownAymaBeforeSend,
        resend: resend,
        imagePath: imagePath,
        queueable: !skipUserTurn,
      ));
      return;
    }
  ```
- Lines 813–821: `_shouldReconcile(e)` checks:
  ```dart
  bool _shouldReconcile(Object error) {
    if (_backgroundedDuringSend) return true;
    if (error is SocketException || error is TimeoutException) return true;
    if (error is ApiException) {
      return error.statusCode == null &&
          error.message.startsWith('Network error');
    }
    return false;
  }
  ```
  Network drop errors have `statusCode == null` and start with `'Network error'`, so `_shouldReconcile` returns `true`.
- Lines 826–830:
  ```dart
  void _beginReconcile(_PendingSendReconcile rec) {
    _reconcile = rec;
    _store.updatePendingText('Reconnecting…');
    unawaited(_reconcilePendingSend());
  }
  ```
  The pending bubble changes text to `"Reconnecting…"`. This matches Scout's symptom (`client showed "Reconnecting..." by +6s`).

#### C. The Wedged State: Why It Sits Indefinitely in "Waiting for a connection…"
- Lines 849–885: `_reconcilePendingSend()` runs:
  ```dart
  for (var i = 0; i < 3 && mounted; i++) {
    if (i > 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!mounted || !identical(_reconcile, rec)) return;
    try {
      final page = await _api.chatHistory(limit: 10);
      ...
    } catch (_) {
      /* still cut off — keep trying briefly */
    }
  }
  ```
  It attempts 3 history reads (separated by 2-second sleeps). Because radios are off, all 3 throw and are caught.
- Lines 886–887:
  ```dart
  final result = await rec.resend();
  ```
  It attempts one HTTP POST `resend()`. Radios are still off, so `rec.resend()` throws `ApiException`.
- Lines 910–936:
  ```dart
  } catch (e) {
    if (!mounted || !identical(_reconcile, rec)) return;
    if (_shouldReconcile(e)) {
      // Still no connection: keep waiting — the next resume tries again.
      _store.updatePendingText('Waiting for a connection…');
    } else {
      ...
    }
  } finally {
    _reconciling = false;
  }
  ```
- **THE CRITICAL BUG (The Infinite Wedge)**:
  1. At ~30s into the flow, line 914 sets the pending text to `"Waiting for a connection…"`.
  2. The function reaches `finally` and **terminates**.
  3. **No connectivity listener exists**: There is zero subscription to network status changes (e.g. `connectivity_plus` or network streams). When radios restore, nothing wakes up.
  4. **No timer / polling loop exists**: There is no periodic retry or exponential backoff timer.
  5. **No user action exists**: The pending bubble has no "Tap to retry" chip, and no toast/button is shown.
  6. **Flawed lifecycle assumption**: The comment at line 913 explicitly admits:
     `// Still no connection: keep waiting — the next resume tries again.`
     The code assumes the *only* way network restores is if the user backgrounds the app and returns:
     ```dart
     // chat_screen.dart:409-411
     if (state == AppLifecycleState.resumed && _reconcile != null) {
       _reconcilePendingSend();
     }
     ```
     If the user keeps the app open, `didChangeAppLifecycleState` **never fires**. The bubble stays wedged on `"Waiting for a connection…"` forever.

#### D. Why Leaving & Re-entering Chat Did Not Unwedge It
- File: [`ayma_flutter/lib/screens/main_shell_screen.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/main_shell_screen.dart#L416-L421)
  ```dart
  child: Scaffold(
    body: IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < 4; i++) _built[i] ?? const SizedBox.shrink(),
      ],
    ),
  ```
- The shell keeps tabs alive in an `IndexedStack`. Switching from Tab 0 (Ayma) to Tab 1 (Explore) and back to Tab 0 does **not** dispose or rebuild `ChatScreen`. `initState` does not run, and `didChangeAppLifecycleState` is not triggered. The in-memory `_reconcile` and `"Waiting for a connection…"` bubble remain untouched.

#### E. Why the Message Vanished in PC4 (The Eradication Path)
- File: [`ayma_flutter/lib/screens/main_shell_screen.dart:144-146`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/main_shell_screen.dart#L144-L146)
  ```dart
  if (i == 0 && _index != 0) {
    showPageContextAymaPopup(context, navBarBuilder: _navBar);
  }
  ```
  When the user is on Explore (_index = 1) and taps the Ayma tab icon (i = 0), the shell opens `showPageContextAymaPopup` ([`ask_ayma_overlay.dart:105-115`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/widgets/ask_ayma_overlay.dart#L105-L115)), which mounts a **new** `ChatScreen` instance pointing to the shared `AymaSession.instance.store`.
- In `ChatScreen.initState` ([`chat_screen.dart:385`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/chat_screen.dart#L385)), `_loadHistory()` is triggered.
- `_loadHistory()` fetches `/chat/history` from the server (which succeeds now that radios are back).
- Line 1180: `_store.seed(windowed);`.
- File: [`ayma_flutter/lib/services/transcript_store.dart:317-331`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/services/transcript_store.dart#L317-L331):
  ```dart
  void seed(Iterable<TranscriptTurn> turns) {
    final loaded = turns.toList();
    final loadedKeys = {for (final t in loaded) (t.role, t.text.trim())};
    final live = _turns
        .where((t) =>
            t.source == TurnSource.voice &&
            !loadedKeys.contains((t.role, t.text.trim())))
        .toList();
    _turns
      ..clear()
      ..addAll(loaded)
      ..addAll(live);
    _trim();
    notifyListeners();
  }
  ```
- **THE ERADICATION**: `seed()` clears `_turns` and **only** preserves unlanded `TurnSource.voice` turns!
- The optimistic user text turn (`TurnSource.text`) and the non-final Ayma turn are **wiped**.
- Because the message never made it across the wire to Firestore, server history does not contain it.
- **Result**: The user's text message and the pending bubble vanish without a trace or error.

#### F. Why Force-Stop Relaunch Clears It (PC5)
- Neither the optimistic turn in `TranscriptStore` nor `_reconcile` in `_ChatScreenState` is persisted to disk. Killing the app process clears RAM.
- On relaunch, `_loadHistory()` seeds clean history from the backend. The phantom bubble is gone, and the message never existed on the server.

---

### 1.3 PC5 Proposed Fix Design (Engineer-Sized Chunk)

1. **Active Reconnection Listener & Auto-Drain**:
   - In `_ChatScreenState`, subscribe to a connectivity change stream (via `Connectivity().onConnectivityChanged` or an app-level network monitor).
   - When network connectivity returns (transition from none -> wifi/mobile) and `_reconcile != null`, automatically invoke `_reconcilePendingSend()`.
   - Also introduce a fallback backoff timer while `_reconcile != null` (e.g. 5s, 15s, 30s) capped at 3 attempts, so it does not rely solely on OS broadcast events.

2. **Honest User-Visible State & Retry Action**:
   - If repeated reconciliation fails or network remains unreachable after a bounded duration (e.g. 30 seconds), transition the pending bubble from `"Waiting for a connection…"` to a failure state:
     - Show an inline chip on the pending bubble: `"Connection lost · Tap to retry"`.
     - Tapping the bubble re-invokes `_reconcilePendingSend()`.
     - Simultaneously show an `AymaToast` with an explicit `Retry` action calling `_send(retry: rec.message, clientMsgId: rec.msgId)`.

3. **TranscriptStore Seed Preservation & Offline Queue**:
   - In `transcript_store.dart` (`seed()`):
     - Preserve turns that are pending reconciliation (e.g., non-final turns or user turns where `t.isFinal && !loadedKeys.contains(...)`).
   - In `pending_chat_queue.dart`:
     - Generalize `PendingChatQueue` so that offline sends are queued to disk alongside out-of-credits sends. If the app is killed while offline, queued messages drain automatically upon the next launch when online.

### 1.4 Tests to Catch PC5 Regressions
- **Widget test (`test/chat_screen_test.dart`)**:
  - `testWidgets('send during network disconnect transitions to reconnecting then waiting, and auto-resends on connectivity restore')`:
    - Mock `_api.chatStream` to throw `SocketException`.
    - Verify bubble shows `'Reconnecting…'`, then `'Waiting for a connection…'`.
    - Simulate network connectivity restore event.
    - Verify `_reconcilePendingSend` is triggered and resolves when `chatHistory` returns the message.
- **Widget test (`test/chat_screen_test.dart`)**:
  - `testWidgets('failed send displays retry action allowing manual resend')`:
    - Verify that when resend fails, tapping the retry button / toast triggers `_send` with the same `clientMsgId`.
- **Unit test (`test/transcript_store_test.dart`)**:
  - `test('seed() does not erase pending unconfirmed text turns')`:
    - Seed history while a pending text turn is in `_turns`.
    - Verify pending turn is retained.

---

## 2. PC6 Analysis — Explore Under 3G Throttling & Raw ApiException

### 2.1 Scout's Empirical Finding
> **PC6 FAIL [S2]** (`ayma-inbox/scout.md:187`): Emulator throttled to UMTS (3G). Explore: full-screen spinner (no skeleton), then `"Could not load Explore (ApiException(Request timed out — please try again., status 408))"` — raw exception text, no retry button, no cached fallback; identical on re-visit. Messages: honest `"Offline — showing saved data"` banner but cached rows are degraded shells — every thread titled `"Conversation"` with a `"C"` initial, no names/photos/previews, 5 rows vs 7 live — and never filled.

### 2.2 Code-Level Trace & Root Cause (File:Line Evidence)

#### A. Throttling, Interactive Timeout, and ApiException(408)
- File: [`ayma_flutter/lib/services/api_client.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/services/api_client.dart#L17-L187)
- Line 17:
  ```dart
  const kInteractiveTimeout = Duration(seconds: 8);
  ```
- Lines 86–94:
  ```dart
  Duration _timeoutFor(Uri url, Map<String, String>? headers) {
    ...
    if (_isLongBudgetPath(url.path)) return longTimeout;
    return interactiveTimeout;
  }
  ```
  `/explore` is **not** in `_isLongBudgetPath` (`_isLongBudgetPath` is for `/check-compatibility`, `/deep-dive`, `/appearance/report`). Thus, `/explore` gets a rigid **8-second timeout**.
- Lines 142–187 (`BudgetHttpClient._executeGet`):
  ```dart
  final deadline = DateTime.now().add(timeout);
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw ApiException('Request timed out — please try again.', statusCode: 408);
    }
    try {
      final r = await _inner.get(url, headers: headers).timeout(remaining);
      ...
    } on TimeoutException {
      if (attempt < maxAttempts) {
        final after = deadline.difference(DateTime.now());
        if (after > const Duration(milliseconds: 400)) {
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }
      }
      throw ApiException('Request timed out — please try again.', statusCode: 408);
    }
  ```
  Under UMTS (3G throttling), latency is high and HTTP connection + payload download for `/explore` (even 7 cards) takes longer than 8 seconds.
  On attempt 1, `_inner.get(...).timeout(remaining)` hits the 8-second limit and throws `TimeoutException`.
  Because the total 8s budget has elapsed, `deadline.difference(DateTime.now())` is `< 0`. The retry condition (`after > 400ms`) is false.
  Line 174 throws:
  `ApiException('Request timed out — please try again.', statusCode: 408);`.

#### B. Error Propagation & State Setting in ExploreScreen
- File: [`ayma_flutter/lib/screens/explore_screen.dart:168-205`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/explore_screen.dart#L168-L205):
  ```dart
  setState(() {
    _feed = _feed.copyWith(refreshing: true, clearError: true);
  });
  try {
    final page = await _api.explore(q: _searchController.text.trim());
    ...
  } catch (e) {
    if (!mounted) return;
    setState(() {
      _feed = _feed.copyWith(refreshing: false, error: e);
    });
  }
  ```
  `_feed.error` is populated directly with the thrown `ApiException`.

#### C. Raw Exception Dump & Absence of Retry in UI
- File: [`ayma_flutter/lib/screens/explore_screen.dart:344-354`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/explore_screen.dart#L344-L354):
  ```dart
  body: Builder(builder: (context) {
    if (_feed.refreshing && !_feed.hasData) {
      return const AppLoadingIndicator();
    }
    if (_feed.error != null && !_feed.hasData) {
      return CenteredScroll(
        padding: const EdgeInsets.all(24),
        child: Text('Could not load Explore (${_feed.error}).',
            style: AymaType.sans(
                size: 14, color: AymaColors.error)),
      );
    }
  ```
- **THE GAPS**:
  1. **Raw Exception Leakage**: `_feed.error` is interpolated directly into `Text('Could not load Explore (${_feed.error}).')`. In `api_client.dart:5798-5800`:
     ```dart
     @override
     String toString() =>
         'ApiException($message${statusCode != null ? ', status $statusCode' : ''})';
     ```
     This produces verbatim:
     `Could not load Explore (ApiException(Request timed out — please try again., status 408)).`
  2. **No Retry Button**: The widget returned is a bare `CenteredScroll` containing only that single `Text` widget. There is **no `AymaButton`**, **no `TextButton`**, and **no refresh control**.
  3. **No Pull-to-Refresh on Error**: `CustomScrollView` and pull-to-refresh are only rendered when `cards.isNotEmpty`. The error screen cannot be refreshed by pulling down.
  4. **No Offline Cache Fallback**:
     - Unlike `MessagesScreen` (which uses `fresh_data` backed by Firestore cache) and `PlanScreen`, `ExploreScreen` relies solely on `TabPrefetchCoordinator.instance.takeExplorePage()` ([`tab_prefetch_coordinator.dart:78-86`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/services/tab_prefetch_coordinator.dart#L78-L86)).
     - `takeExplorePage()` is in-memory only and cleared after 20 seconds or upon first consumption.
     - Explore has **no persistent local disk cache**. When `/explore` fails or times out on initial load, `_feed.hasData` is false, and there are zero cards to display.
  5. **Identical on Revisit**: When switching tabs and returning, `_exploreKey.currentState?.reload()` ([`main_shell_screen.dart:188`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/main_shell_screen.dart#L188)) triggers `_loadInitial()`. Under 3G throttling, it spins for another 8 seconds, times out again, and lands on the exact same raw error screen.

#### D. Note on Messages Screen Behavior Under 3G
- Scout noted: `Messages: honest "Offline — showing saved data" banner but cached rows are degraded shells — every thread titled "Conversation" with a "C" initial, no names/photos/previews, 5 rows vs 7 live — and never filled.`
- Code explanation:
  - `MessagesScreen` uses `_matches.watchMutualMatchesFresh()` and `_dm.watchThreadsFresh()`, both of which have local Firestore persistence, allowing it to render cached thread rows and show `FreshnessIndicator` (`"Offline — showing saved data"`).
  - However, user display names and avatars come from `_api.miniProfiles(missing)` ([`messages_screen.dart:125-139`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/messages_screen.dart#L125-L139)). Under 3G throttling, `miniProfiles` times out, leaving `_mini` empty.
  - Thread rows fall back to `fallbackName: 'Conversation'` and avatar initial `'C'` ([`messages_screen.dart:281`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc5pc6-analysis/ayma_flutter/lib/screens/messages_screen.dart#L281)). This is a graceful degradation, but highlights that `miniProfiles` also lacks local caching.

---

### 2.3 PC6 Proposed Fix Design (Engineer-Sized Chunk)

1. **Polite, Production-Ready Error View with Retry Button**:
   - In `explore_screen.dart` (lines 347–354):
     - Replace the raw exception dump with a standard error component:
       ```dart
       if (_feed.error != null && !_feed.hasData) {
         return RefreshIndicator(
           onRefresh: reload,
           child: CenteredScroll(
             padding: const EdgeInsets.all(24),
             child: Column(
               mainAxisSize: MainAxisSize.min,
               children: [
                 Icon(Icons.wifi_off_outlined, size: 48, color: ac.fgMute),
                 const SizedBox(height: 16),
                 Text(
                   "Couldn't load Explore",
                   style: AymaType.serif(size: 20, bold: true, color: ac.fg),
                 ),
                 const SizedBox(height: 8),
                 Text(
                   _friendlyErrorMessage(_feed.error),
                   textAlign: TextAlign.center,
                   style: AymaType.sans(size: 14, color: ac.fgMute),
                 ),
                 const SizedBox(height: 20),
                 AymaButton(
                   label: 'Try again',
                   onPressed: _loadInitial,
                 ),
               ],
             ),
           ),
         );
       }
       ```
     - `_friendlyErrorMessage(Object? error)`: If error is an `ApiException` with 408 or network error, return `"Connection timed out. Check your connection and try again."` rather than exposing raw exception classes or HTTP status codes.

2. **Pull-to-Refresh Availability on Error**:
   - Wrap the error view in `RefreshIndicator` so users can pull down to refresh in addition to tapping the "Try again" button.

3. **Explore Persistent Cache & FreshnessIndicator**:
   - Persist the last successful `ExplorePage` JSON (page 1) to `SharedPreferences` or disk.
   - On launch, hydrate `_feed` from this cached snapshot marked `isFromCache: true`.
   - If network times out under 3G throttling:
     - Keep displaying the cached cards.
     - Surface `FreshnessIndicator(state: FreshnessState.refused, onRetry: _loadInitial)` or `FreshnessState.stale`.
     - The user sees real profiles rather than a dead-end blank error page.

4. **Adaptive Timeout / Throttling Resilience**:
   - In `api_client.dart`, give `GET /explore` an adaptive timeout or allow a longer budget (e.g. 15s instead of 8s) when under throttled/cellular conditions, or permit 1 bounded retry if the deadline allows.

### 2.4 Tests to Catch PC6 Regressions
- **Widget test (`test/explore_screen_test.dart`)**:
  - `testWidgets('explore initial load failure renders friendly error and retry button, not raw ApiException')`:
    - Mock `api.explore` to throw `ApiException('Request timed out — please try again.', statusCode: 408)`.
    - Pump `ExploreScreen`.
    - Assert that find.textContaining('ApiException') finds 0 widgets.
    - Assert that find.text("Couldn't load Explore") and find.text('Try again') find 1 widget.
    - Tap 'Try again' and verify `api.explore` is invoked again.
- **Widget test (`test/explore_screen_test.dart`)**:
  - `testWidgets('explore initial load failure with cached data shows cards and FreshnessIndicator')`:
    - Pre-seed cached explore feed.
    - Mock network failure.
    - Assert explore cards remain visible and `FreshnessIndicator` shows `"Couldn't refresh"`.

---

## 3. Summary & Claude Wrap-up Handoff Batch

| Bug ID | Severity | File:Line Evidence | Failure Mechanism | Proposed Fix Chunk |
| :--- | :--- | :--- | :--- | :--- |
| **PC5** | `[S2]` | `chat_screen.dart:1720, 2026, 828, 914`<br>`transcript_store.dart:325` | Sent message on network drop transitions to `"Waiting for a connection…"`. `_reconcilePendingSend` exits with no connectivity listener or retry timer, relying only on `AppLifecycleState.resumed` (never fires if app stays open). Re-entering chat via orb popup calls `_store.seed()` which purges all non-voice turns, silently erasing the unsent message. | 1. Add connectivity listener + retry backoff timer to `_ChatScreenState`.<br>2. Transition stuck pending bubble to failure state with "Tap to retry" chip + toast.<br>3. Preserve pending turns in `TranscriptStore.seed` and persist offline messages. |
| **PC6** | `[S2]` | `api_client.dart:17, 86, 174`<br>`explore_screen.dart:199, 347–353` | 3G throttling causes `_api.explore()` to exceed the 8s `kInteractiveTimeout`, throwing `ApiException(408)`. `ExploreScreen` catches it and directly renders `Could not load Explore (${_feed.error}).` with no retry button, no pull-to-refresh, and no local cache fallback. | 1. Replace raw `${_feed.error}` with a polite error component (`"Couldn't load Explore"`) + "Try again" button.<br>2. Add `RefreshIndicator` on error view.<br>3. Persist page-1 cache to disk and wire `FreshnessIndicator`.<br>4. Expand `/explore` timeout budget to 15s. |

Both failures are client-side UX and transport state machine deficiencies. They do not require backend schema or API changes. Each fix is cleanly bounded and ready for implementation.
