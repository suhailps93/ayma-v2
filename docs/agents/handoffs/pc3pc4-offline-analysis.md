# PC3 & PC4 Offline-Failure Analysis & Fix Design

- **Author**: Antigravity (Engineer)
- **Recipients**: Astro (PM), Scout (QA Lead), Claude (Lead Engineer)
- **Date**: 2026-11-02
- **Baseline**: Staging `c06ba66` (versionCode 2246 / 2245 suite)
- **Branch**: `antigravity/pc3pc4-offline-analysis` (worktree: `~/workspace/ayma/.fleet-worktrees/pc3pc4-analysis`)
- **Status**: ANALYSIS ONLY (Code-read + Trace + Fix Design; zero app code edits)

---

## Executive Summary

During Scout's full staging sweep (`3a1541d` / 2245, continued on `bdf223a` and `c06ba66`), two critical `[S2]` offline defects were filed for Claude's coordinated T2 offline build:
1. **PC3 [S2]**: Offline cold launch serves no cached conversation history. When the app launches without network connectivity, the Ayma chat tab renders an empty view displaying `"Couldn't load your conversation history."` and a `"Retry"` button. No cached messages are displayed, and no stale/offline indicator is provided.
2. **PC4 [S2]**: A chat message composed and sent while offline sits indefinitely in `"Waiting for a connection…"`. When radios are restored, the message does not deliver; upon switching tabs or navigating, the message **vanishes completely** without reaching the server (`GET /chat/history` contains no trace) and without surfacing any error or retry affordance.

Both issues have been comprehensively traced through the client and backend codebases. **Zero contradictions** exist between Scout's empirical observations and the code implementation. Furthermore, the code reveals the exact mechanisms behind both failures:
- **PC3 Root Mechanism**: Chat history is fetched solely via REST (`GET /chat/history`), completely bypassing local Firestore persistence. Neither `TranscriptStore` nor `ApiClient` has any disk-backed cache for chat history (`TranscriptStore` is an ephemeral in-memory `ChangeNotifier` initialized with `_turns = []`). When `_api.chatHistory(limit: 40)` fails on cold launch, `_ChatScreenState` directly sets `_historyError = "Couldn't load your conversation history."`, displaying a blank error view instead of cached history.
- **PC4 Root Mechanism**: Contrary to the assumption of a "queued offline message", **no offline queue exists in the app**. `PendingChatQueue` is exclusively an "out of credits" hold (`usage_capped: true`). Offline sends are held only in a volatile in-memory `_reconcile` field on `_ChatScreenState`. When radios restore in the foreground, `_reconcilePendingSend` is never re-triggered because `_ChatScreenState` registers no `Connectivity` listener and has no polling timer (it relies solely on `AppLifecycleState.resumed`, which never fires for an app already in the foreground). When the user navigates away and re-enters chat (e.g. via the bottom-bar orb, which opens `showPageContextAymaPopup`), a fresh `ChatScreen` mounts and calls `_store.seed()` with server history. `TranscriptStore.seed()` explicitly clears all turns and preserves **only** `TurnSource.voice` turns; because the offline message was `TurnSource.text` and never reached the server, `_store.seed()` purges it from memory. The message is silently erased.

This document presents the detailed trace, file:line evidence, root causes, and an engineer-sized fix design that seamlessly composes with the PC5 (send-wedge) and PC6 (Explore 3G timeout) designs into a unified offline architecture: **Durable Outbox + Cached History + Honest Connection State**.

---

## 1. PC3 Analysis — Offline Cold Launch Serves No Cached History

### 1.1 Scout's Empirical Finding
> **PC3 FAIL [S2]** (`ayma-inbox/scout.md:172`):
> *"offline cold launch: chat shows 'Couldn't load your conversation history.' + Retry; NO cached history is served offline, no offline/stale marking. Graceful (no crash/spinner) but the pack expects cached content marked stale."*

### 1.2 Code-Level Trace & File:Line Evidence

#### A. The Cold-Start Routing Path
1. **Application Bootstrap (`main.dart`)**:
   - [`ayma_flutter/lib/main.dart:36-58`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/main.dart#L36-L58):
     `main()` initializes the Startup DAG via `StartupNodes.buildDefaultDAG()` and executes target nodes up to `N8:first_frame_mount`.
   - Router starts with initial location `SplashScreen.path` (`/splash`), defined in [`ayma_flutter/lib/routing/app_router.dart:114`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/routing/app_router.dart#L114).

2. **Splash Resolution (`splash_screen.dart`)**:
   - [`ayma_flutter/lib/screens/splash_screen.dart:154-178`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/splash_screen.dart#L154-L178):
     `SplashScreenState._resolve()` verifies that `FirebaseAuth.instance.currentUser` is non-anonymous.
   - Lines 168–177:
     ```dart
     final cachedConfig = await ReportCache.instance.readBootConfig(user.uid);
     final cachedRoute = cachedConfig?.entryRoute ??
         await ReportCache.instance.readBootRoute(user.uid);
     if (cachedRoute != null && cachedRoute.isNotEmpty && mounted) {
       _inFlight = false;
       final router = GoRouter.of(context);
       DeepLinkQueue.instance.notifyNavigationSettled();
       router.go(cachedRoute);
       unawaited(_backgroundBootstrap(user.uid, auth, cachedRoute, router));
       return;
     }
     ```
     For a returning signed-in user, `cachedRoute` is `/` (`MainShellScreen.path`). The app immediately routes to `/`.
   - If `cachedRoute` was absent, `apiClient.bootstrap()` times out (2.5s budget) and falls back to `_tryFirestoreCacheFallback(user.uid)` ([`splash_screen.dart:235-250`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/splash_screen.dart#L235-L250)), which reads cached user profile documents from the local Firestore SDK cache and also routes to `MainShellScreen.path`.

3. **Shell Tab Initialization (`main_shell_screen.dart`)**:
   - [`ayma_flutter/lib/screens/main_shell_screen.dart:101-107`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/main_shell_screen.dart#L101-L107):
     `MainShellScreen` mounts an `IndexedStack` where tab 0 is initialized as:
     ```dart
     _built[0] = ChatScreen(
       transcriptStore: _store,
       voiceController: _voice,
       composerAnchorKey: TourAnchors.keyFor(TourAnchors.homeComposer),
     );
     ```
     Here, `_store` is `AymaSession.instance.store` ([`ayma_session.dart:23`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/ayma_session.dart#L23)), an app-wide in-memory singleton.

#### B. The ChatScreen History Fetch Attempt
1. **ChatScreen Init (`chat_screen.dart`)**:
   - [`ayma_flutter/lib/screens/chat_screen.dart:367-390`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L367-L390):
     ```dart
     @override
     void initState() {
       super.initState();
       ...
       if (widget.askAymaContext == null) {
         AppContext.instance.set(screen: 'ayma');
         _loadHistory();
         ...
       }
     }
     ```
     `ChatScreen` unconditionally calls `_loadHistory()` on mount.

2. **The Direct REST Request (`chat_screen.dart:1093-1123`)**:
   - Lines 1093–1100:
     ```dart
     Future<void> _loadHistory() async {
       try {
         final target = widget.targetTimestamp.isEmpty
             ? null
             : DateTime.tryParse(widget.targetTimestamp);

         var page = await _api.chatHistory(limit: 40);
     ```
   - `_api.chatHistory(limit: 40)` invokes `BudgetHttpClient` to send `GET /chat/history?limit=40` to Cloud Run ([`api_client.dart:2594-2605`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/api_client.dart#L2594-L2605)).
   - **No local cache check precedes this call.**
   - Under offline conditions (no Wi-Fi/cellular), the HTTP request immediately fails with a `SocketException` or `ClientException`, wrapped as an `ApiException` (`Network error: ...`, `statusCode: null`).

3. **Exception Handling & Error State**:
   - [`ayma_flutter/lib/screens/chat_screen.dart:1191-1199`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1191-L1199):
     ```dart
     } catch (e) {
       // A load failure must not render the same as an empty history — record it
       // so the view can offer a retry (see `_historyError`).
       debugPrint('chat history load failed: $e');
       if (mounted) _historyError = "Couldn't load your conversation history.";
       _pendingTargetScroll = false;
     } finally {
       if (mounted) setState(() => _loadingHistory = false);
     }
     ```
   - Because `_api.chatHistory` threw, `_store.seed()` is never reached.

#### C. Storage & Cache Audit — Why Nothing is Cached
- **`TranscriptStore` (`transcript_store.dart`)**:
  - [`ayma_flutter/lib/services/transcript_store.dart:101-107`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/transcript_store.dart#L101-L107):
    ```dart
    class TranscriptStore extends ChangeNotifier {
      TranscriptStore({this._maxTurns = 100});

      int _maxTurns;
      final List<TranscriptTurn> _turns = [];
    ```
    `TranscriptStore` is an **in-memory only** list. It has zero interaction with SQLite, Hive, SharedPreferences, or local disk files. On a cold start, `_turns` is empty (`[]`).
- **`pubspec.yaml` Storage Packages**:
  - [`ayma_flutter/pubspec.yaml:73-74`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/pubspec.yaml#L73-L74):
    The app dependencies include only `shared_preferences: ^2.5.3` and `firebase_storage: ^13.5.0`.
    There is **no SQLite (`sqflite`), no Hive, no Drift, and no ObjectBox** in the project.
- **`ReportCache` (`report_cache.dart`)**:
  - [`ayma_flutter/lib/services/report_cache.dart:35-43`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/report_cache.dart#L35-L43):
    `ReportCache` only stores `report_cache:` (appearance, body, deep-dive), `boot_route:`, and `boot_config:`. It has no methods or storage keys for chat messages.
- **Why Firestore Offline Persistence Does Not Help**:
  - The Firebase SDK supports offline persistence, but the client app **does not query Firestore directly for chat history**.
  - Chat history is handled through Cloud Run REST endpoints (`functions/bootstrap/main.py:2162` `@app.get("/chat/history")`). The server reads Firestore `users/{uid}/chat_messages`. The Flutter client communicates strictly over HTTP with Cloud Run. Therefore, Firestore's client SDK disk cache never contains any chat history.

#### D. The Resulting UI State
- [`ayma_flutter/lib/screens/chat_screen.dart:2373-2396`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L2373-L2396):
  ```dart
  if (_historyError != null) {
    return CenteredScroll(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _historyError!,
            textAlign: TextAlign.center,
            style: AymaType.sans(
              size: 15,
              soft: true,
              color: ac.fgMute,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _retryHistory,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
  ```
  With `_historyError` set to `"Couldn't load your conversation history."` and zero cached turns in memory, the screen renders a blank scroll view with the error string and a "Retry" button.

### 1.3 Root Cause Summary
1. **Total Absence of Local History Caching**: Chat history is treated as transient in-memory state hydrated over REST on each app launch. No persistence mechanism (`SharedPreferences` or file snapshot) exists for `TranscriptStore` or `/chat/history`.
2. **Strict Network Dependency on Init**: `_loadHistory()` immediately blocks on a remote HTTP GET without any Stale-While-Revalidate (SWR) fallback.
3. **Binary UI Error Presentation**: `ChatScreen` does not support displaying cached content with an offline/stale banner; any initial load failure unconditionally transitions the view into a blank error state.

---

## 2. PC4 Analysis — Queued Offline Message Silently Dropped After Reconnect

### 2.1 Scout's Empirical Finding
> **PC4 FAIL [S2]** (`ayma-inbox/scout.md:172`):
> *"split verdict: the offline send itself is honest ('Waiting for a connection...' pending state, no fake send — that leg passes). But after radios restored (shell ping to the staging API 0% loss; Explore fetched fresh in-app), the message sat in 'Waiting' 3+ min, and after tab navigation it VANISHED — GET /chat/history as Daniel confirms it never reached the server (no 'good morning'/'slow morning' anywhere). A queued offline message is silently dropped: no delivery, no error, no trace. This supersedes the old 'item 10 PARTIAL (bench-limited)' framing — the discriminator (Explore loading fresh in the same session) rules out the bench-DNS explanation for the drop."*

### 2.2 Code-Level Trace & File:Line Evidence

#### A. Misconception vs Code Reality: The Offline "Queue" Does Not Exist
Scout's report mentions: *"A queued offline message is silently dropped"*.
Code verification reveals an essential fact: **The message was never queued.**
- [`ayma_flutter/lib/screens/chat_screen.dart:1720-1727`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1720-L1727):
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
  `_queue` is an instance of `PendingChatQueue`.
- [`ayma_flutter/lib/services/pending_chat_queue.dart:13-64`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/pending_chat_queue.dart#L13-L64):
  `PendingChatQueue` is strictly an **"out of credits" queue** (`usage_capped: true`), written to `SharedPreferences` under `pending_chat_queue:v1:$uid`. It is enqueued **only** when `_holdForCredits()` is called (`chat_screen.dart:2081-2100`).
- When a user sends a normal message while offline (and with credits funded), `!_queue.isEmpty` evaluates to `false`. The message **completely bypasses** `PendingChatQueue` and enters the standard send path.

#### B. The Offline Send & Initial Reconciliation
1. **Adding Turns to In-Memory Store**:
   - `_store.addTurn(TurnRole.user, message, TurnSource.text)` ([`chat_screen.dart:1767`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1767)): An optimistic bubble is created in `_store` (memory only).
   - `_store.addPending('Thinking…')` ([`chat_screen.dart:1825`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1825)): A non-final placeholder bubble is added (memory only).

2. **Network Failures**:
   - `_api.chatStream(...)` ([`chat_screen.dart:1939`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1939)) immediately fails due to offline socket error.
   - Stream catch falls back to `resend()` (`_api.chat(...)`, [`chat_screen.dart:1975`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1975)), which also immediately throws `ApiException("Network error: ...", statusCode: null)`.
   - Outer catch block ([`chat_screen.dart:2018-2036`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L2018-L2036)):
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
   - `_shouldReconcile(e)` returns `true` because `e.statusCode == null && e.message.startsWith('Network error')` ([`chat_screen.dart:813-820`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L813-L820)).

3. **Transition to `_PendingSendReconcile`**:
   - `_beginReconcile()` ([`chat_screen.dart:826-830`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L826-L830)):
     ```dart
     void _beginReconcile(_PendingSendReconcile rec) {
       _reconcile = rec;
       _store.updatePendingText('Reconnecting…');
       unawaited(_reconcilePendingSend());
     }
     ```
   - `_reconcile` is a single private instance field on `_ChatScreenState` ([`chat_screen.dart:800`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L800)). **It is never written to disk.**

4. **Execution of `_reconcilePendingSend()` Under Offline Conditions**:
   - [`ayma_flutter/lib/screens/chat_screen.dart:849-937`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L849-L937):
     - The for-loop attempts 3 polls of `_api.chatHistory(limit: 10)` spaced 2s apart (lines 854–885). Because the device is offline, each poll throws `ApiException("Network error")` and is swallowed by `catch (_)`.
     - Next, line 887 attempts `final result = await rec.resend();`. This also throws `ApiException("Network error")`.
     - Control drops into the catch block at line 910:
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
     - The pending bubble text is updated to `'Waiting for a connection…'`.
     - `_reconciling` is reset to `false`.
     - **The function terminates.**

#### C. Why the Message Sits Dormant After Radios Restore (The Foreground Wedge)
- Notice the developer comment at line 913: `the next resume tries again`.
- Where is `_reconcilePendingSend()` triggered again?
- Inspect [`ayma_flutter/lib/screens/chat_screen.dart:406-411`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L406-L411):
  ```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ...
    if (state == AppLifecycleState.resumed && _reconcile != null) {
      _reconcilePendingSend();
    }
  }
  ```
- **There is NO other invocation of `_reconcilePendingSend` in `ChatScreen`!**
- `_ChatScreenState` registers:
  - **Zero** `Connectivity().onConnectivityChanged` listeners.
  - **Zero** periodic retry timers.
  - **Zero** socket/network observers.
- When radios are restored while the app is in the foreground, `AppLifecycleState.resumed` **never fires** because the app never left the foreground (`resumed` only fires when returning from background/paused).
- Consequently, even though the device is fully online, `_reconcilePendingSend()` is never called. The message sits in `"Waiting for a connection…"` indefinitely (matching Scout's "sat in 'Waiting' 3+ min").

#### D. The Tab Navigation Purge: Why the Message Vanished
Why did the message vanish when Scout switched tabs?
1. **The Navigation Path**:
   - In `MainShellScreen` ([`ayma_flutter/lib/screens/main_shell_screen.dart:136-149`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/main_shell_screen.dart#L136-L149)):
     ```dart
     void _onTabTap(int i) {
       if (isPageContextAymaPopupOpen) {
         ...
       }
       if (i == 0 && _index != 0) {
         showPageContextAymaPopup(context, navBarBuilder: _navBar);
       } else {
         _selectTab(i);
       }
     }
     ```
   - When Scout navigated from Chat (`_index == 0`) to Explore (`_index == 1`), `ExploreScreen` mounted and successfully loaded over the restored network.
   - When Scout tapped the Ayma orb (slot 0) to return to chat:
     Because `_index == 1` (`_index != 0`), `_onTabTap` opened `showPageContextAymaPopup(context, ...)`!

2. **Mounting of Fresh ChatScreen in Popup**:
   - [`ayma_flutter/lib/widgets/ask_ayma_overlay.dart:105-115`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/widgets/ask_ayma_overlay.dart#L105-L115):
     ```dart
     final future = showAymaChatModal(
       ...
       builder: (_) => ChatScreen(
         transcriptStore: AymaSession.instance.store,
         voiceController: AymaSession.instance.voice,
         pageContext: prior,
       ),
     );
     ```
     This instantiates a brand new `ChatScreen` bound to the shared singleton `AymaSession.instance.store`.

3. **`_loadHistory()` Fetches Fresh Server History**:
   - The new `ChatScreen` executes `initState()` -> `_loadHistory()` ([`chat_screen.dart:1093-1180`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1093-L1180)).
   - Radios are restored, so `_api.chatHistory(limit: 40)` **succeeds**.
   - It fetches the true server history (which does NOT contain the offline message).
   - Line 1180 calls:
     ```dart
     _store.seed(windowed);
     ```

4. **The Destructive Purge in `TranscriptStore.seed()`**:
   - Inspect [`ayma_flutter/lib/services/transcript_store.dart:317-331`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/transcript_store.dart#L317-L331):
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
   - **`live` strictly retains ONLY `t.source == TurnSource.voice`.**
   - The offline turn was added as `TurnSource.text` ([`chat_screen.dart:1770`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1770)).
   - The pending turn was added with `isFinal: false` ([`transcript_store.dart:236`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/transcript_store.dart#L236)).
   - Neither turn matches any turn in `loaded` (server never got them).
   - Neither turn has `source == TurnSource.voice`.
   - **`_store.seed()` unconditionally purges both the optimistic user turn and the pending "Waiting for a connection…" turn!**
   - In addition, the ephemeral `_reconcile` instance on the base tab's `_ChatScreenState` was either orphaned or wiped out on subsequent navigation.
   - Result: The message completely vanished from UI and memory, never reached the server, and gave the user zero confirmation or retry action.

### 2.3 Root Cause Summary
1. **No Durable Outbox**: Text messages sent while offline are not persisted to disk. They live entirely as ephemeral state in `TranscriptStore._turns` and `_ChatScreenState._reconcile`.
2. **Missing Active Reconnection Trigger**: `_reconcilePendingSend` relies exclusively on `AppLifecycleState.resumed`, which never fires when the app remains foregrounded while network returns.
3. **Destructive Purging in `TranscriptStore.seed()`**: `seed()` discards all non-voice unconfirmed turns, wiping out unsent and pending messages upon any history reload or chat sheet modal open.
4. **No Failure Fallback or Manual Retry**: The pending bubble stays frozen in `"Waiting for a connection…"` indefinitely instead of timing out to a retryable error chip.

---

## 3. Unified Fix Design (Composing PC3, PC4, PC5, and PC6)

The table below demonstrates how the four offline/network defects compose into a single, cohesive offline architecture for Claude's T2 build:

| Defect | Core Symptom | Root Cause Mechanism | Unified Fix Leg |
| :--- | :--- | :--- | :--- |
| **PC3** `[S2]` | Offline cold launch serves no cached history; renders blank `"Couldn't load..."` + Retry. | No local chat cache; `_loadHistory()` directly awaits REST without SWR or cached fallback; `TranscriptStore` is in-memory only. | **Cached History (SWR)**: Persist last `/chat/history` page in `ReportCache`/`SharedPreferences`. Hydrate frame 1, mark stale if offline. |
| **PC4** `[S2]` | Offline composed message wedges in "Waiting...", vanishes after reconnect + tab nav; 0% delivery. | No durable offline outbox; no `Connectivity` watcher in foreground; `_store.seed()` purges unconfirmed text turns. | **Durable Outbox & Active Drain**: Persist offline sends to disk; auto-flush on `Connectivity` restoration; protect pending turns in `seed()`. |
| **PC5** `[S2]` | Send dropped mid-flight wedges in "Waiting..."; vanishes on relaunch/tab re-entry. | Send drops to ephemeral `_reconcile`; no foreground reconnect trigger; `_store.seed()` purges pending non-voice turns. | **Honest Connection State & Protected Seed**: Auto-reconcile on `Connectivity`; timeout to "Tap to retry" chip; preserve in `seed()`. |
| **PC6** `[S2]` | Explore fails on 3G throttling (8s timeout); shows raw `ApiException(408)` with no retry. | Hard 8s interactive timeout; Explore renders raw error string; lacks pull-to-refresh and cached feed fallback. | **Polite Error & Feed Cache**: Friendly error card + Retry button + `RefreshIndicator` + persist page 1 feed cache. |

### 3.1 Leg 1: Cached History & Stale-While-Revalidate (Fixing PC3)
1. **Chat History Local Storage**:
   - Extend `ReportCache` ([`ayma_flutter/lib/services/report_cache.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/report_cache.dart)) or create `ChatHistoryCache`:
     - Keys: `chat_history:$uid`
     - Storage: JSON-encoded list of `ChatMessage` objects (last 40 messages) plus `next_before` cursor.
     - `Future<void> writeHistory(String uid, List<ChatMessage> messages, String? nextBefore)`
     - `Future<({List<ChatMessage> messages, String? nextBefore})?> readHistory(String uid)`
     - Cleared on sign out in `ReportCache.instance.clearForSignOut()`.

2. **Hydration in `ChatScreen._loadHistory()`**:
   - Modify [`ayma_flutter/lib/screens/chat_screen.dart:1093-1200`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/screens/chat_screen.dart#L1093-L1200):
     ```dart
     Future<void> _loadHistory() async {
       // 1. Instant local cache hydration
       final cached = await ReportCache.instance.readHistory(_auth.currentUser?.uid ?? '');
       if (cached != null && cached.messages.isNotEmpty && _store.isEmpty) {
         final cachedTurns = _messagesToTurns(cached.messages);
         _store.seed(cachedTurns);
         _isHistoryStale = true;
         if (mounted) setState(() {});
       }

       // 2. Network fetch
       try {
         final page = await _api.chatHistory(limit: 40);
         final turns = _messagesToTurns(page.messages);
         _store.seed(turns);
         _isHistoryStale = false;
         _historyError = null;
         unawaited(ReportCache.instance.writeHistory(
           _auth.currentUser?.uid ?? '',
           page.messages,
           page.nextBefore,
         ));
       } catch (e) {
         if (_store.isEmpty) {
           // Truly empty and offline -> show retry state
           _historyError = "Couldn't load your conversation history.";
         } else {
           // We have cached history on screen -> do not hide it!
           _isHistoryStale = true;
         }
       } finally {
         if (mounted) setState(() => _loadingHistory = false);
       }
     }
     ```

3. **UI Stale / Offline Indicator**:
   - If `_isHistoryStale` is true, render a non-intrusive offline status banner at the top of the chat view:
     - Widget: `FreshnessIndicator(state: FreshnessState.refused, onRetry: _retryHistory)` or a subtle `AymaCard` stating: `"Offline — Showing cached messages"`.
     - The conversation remains readable and browsable offline.

### 3.2 Leg 2: Durable Chat Outbox & Active Reconnection (Fixing PC4 & PC5)
1. **Durable Outbox Persistence (`DurableChatOutbox`)**:
   - Generalize `PendingChatQueue` ([`ayma_flutter/lib/services/pending_chat_queue.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/pending_chat_queue.dart)) from credit-capped hold to a general **Durable Outbox**:
     - Status: `QueuedMessageStatus { pendingFunding, pendingConnection, sending, failed }`
     - Fields: `clientMsgId`, `message`, `imagePath`, `imageUrl`, `status`, `enqueuedAt`.
     - Saved to `SharedPreferences` under `chat_outbox:v1:$uid`.
   - When a send fails with a connection error or occurs while offline:
     - Persist the message to `DurableChatOutbox`.
     - In `TranscriptStore`, tag the user turn with `clientMsgId` and `status`.

2. **Active Network Observer (`Connectivity` Watcher)**:
   - In `_ChatScreenState.initState()`:
     ```dart
     _connSub = Connectivity().onConnectivityChanged.listen((results) {
       final online = results.any((r) => r != ConnectivityResult.none);
       if (online) {
         if (_reconcile != null && !_reconciling) {
           _reconcilePendingSend();
         }
         DurableChatOutbox.instance.flushAll();
       }
     });
     ```
   - Add a bounded retry backoff timer while `_reconcile != null` (e.g. retry after 2s, 6s, 15s).

3. **Protection in `TranscriptStore.seed()`**:
   - Modify [`ayma_flutter/lib/services/transcript_store.dart:317-331`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/pc3pc4-analysis/ayma_flutter/lib/services/transcript_store.dart#L317-L331):
     ```dart
     void seed(Iterable<TranscriptTurn> turns) {
       final loaded = turns.toList();
       final loadedKeys = {for (final t in loaded) (t.role, t.text.trim())};

       // Preserve:
       // 1. Live voice turns
       // 2. Pending non-final turns (Thinking / Reconnecting bubbles)
       // 3. Outbox / unconfirmed user turns
       final preserved = _turns.where((t) {
         if (loadedKeys.contains((t.role, t.text.trim()))) return false;
         if (t.source == TurnSource.voice) return true;
         if (!t.isFinal) return true;
         if (t.role == TurnRole.user && DurableChatOutbox.instance.has(t.clientMsgId)) {
           return true;
         }
         return false;
       }).toList();

       _turns
         ..clear()
         ..addAll(loaded)
         ..addAll(preserved);
       _trim();
       notifyListeners();
     }
     ```
   - Navigating tabs or opening chat popups will **never again purge pending or outbox turns**.

4. **Honest Bubble Failure & Manual Retry**:
   - If reconciliation exhausts its retry budget (e.g. 30s deadline or 4 attempts):
     - Transition the pending bubble to an error state:
       `_store.resolvePending("Couldn't send. Check connection and tap to retry.")` or render an inline retry chip.
     - Tapping the retry chip triggers `_send(retry: rec.message, clientMsgId: rec.msgId)`.
     - The user is always in control; messages never silently evaporate.

---

## 4. Verification & Test Plan

### 4.1 Unit & Widget Tests to Add
1. **PC3 Test (`test/chat_offline_cache_test.dart`)**:
   - `testWidgets('cold launch without network hydrates history from cache with stale indicator')`:
     - Seed `ReportCache.instance` with 10 cached `ChatMessage` objects.
     - Mock `apiClient.chatHistory` to throw `ApiException("Network error")`.
     - Pump `ChatScreen(apiClient: api)`.
     - Assert that all 10 messages render in the transcript.
     - Assert that no centered error `"Couldn't load your conversation history."` is shown.
     - Assert that the offline/stale status indicator is visible.
2. **PC4 Test (`test/chat_offline_queue_drain_test.dart`)**:
   - `testWidgets('offline send enqueues to outbox and flushes automatically on connectivity restore')`:
     - Pump `ChatScreen` with network offline.
     - Send message `"Hello offline"`.
     - Assert message is in outbox and rendered with pending state.
     - Simulate tab navigation (`showPageContextAymaPopup`).
     - Assert message turn is preserved in `TranscriptStore` after `seed()`.
     - Emit online event on `Connectivity().onConnectivityChanged`.
     - Assert outbox message drains, hits `POST /chat`, and resolves into confirmed turn.

---

## 5. Summary & Claude Wrap-up Handoff Batch

| Item | Status | Root Cause | Proposed Fix Chunk |
| :--- | :--- | :--- | :--- |
| **PC3 [S2]** | Analyzed & Traced | Chat history has no disk cache; `_loadHistory()` directly awaits REST without SWR or local fallback; fails to blank error view. | 1. Add `chat_history:$uid` cache to `ReportCache`.<br>2. Hydrate `_store` on frame 1 from cache.<br>3. Render `FreshnessIndicator` / offline banner when stale. |
| **PC4 [S2]** | Analyzed & Traced | No offline queue exists (held only in memory); `_reconcile` lacks foreground `Connectivity` listener; `_store.seed()` purges all unconfirmed text turns. | 1. Implement `DurableChatOutbox` backed by `SharedPreferences`.<br>2. Hook `Connectivity().onConnectivityChanged` for auto-drain.<br>3. Protect pending/outbox turns in `TranscriptStore.seed()`.<br>4. Timeout to "Tap to retry" bubble. |

Both failures are strictly client-side state machine, caching, and transport orchestration deficiencies. They require zero backend API or schema changes.
