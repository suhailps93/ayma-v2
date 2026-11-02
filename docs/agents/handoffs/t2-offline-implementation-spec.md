# T2 Consolidated Offline Implementation Spec
## Durable Outbox + Cached History + Honest Connection State

- **Author**: Antigravity (Engineer)
- **Target Reader**: Claude (Lead Engineer for T2 Build)
- **Reviewers**: Astro (PM), Scout (QA Lead)
- **Date**: 2026-11-02
- **Baseline**: `origin/staging` @ `55f8782` (incorporating `d939b17` LiveKit invariant and `55f8782` B9-PUSH fix)
- **Worktree**: `~/workspace/ayma/.fleet-worktrees/t2-offline-spec` (branch: `antigravity/t2-offline-spec`)
- **Status**: IMPLEMENTATION-READY SPECIFICATION (Analysis & Spec writing only; zero app code edits in this worktree)

---

## 1. Executive Summary & Purpose

During Scout's QA sweep on staging (`3a1541d`/2245 through `c06ba66`/2246), five interconnected offline, throttling, and connection defects were uncovered and scheduled for Claude's **Tier 2 (T2) coordinated build**:
1. **PC4 [S2]**: A chat message sent while offline sits in `"Waiting for a connection…"`. When radios restore, the message never delivers; upon tab navigation or orb tap, it **silently vanishes** from the client without reaching the server (`GET /chat/history` has no trace), leaving zero error, confirmation, or retry affordance.
2. **PC5 [S2]**: A chat message sent mid-flight as radios drop enters `"Reconnecting…"`, then permanently wedges on `"Waiting for a connection…"`. Leaving/re-entering chat does not unwedge it, restoring radios in the foreground never resumes sending, and the message evaporates upon app relaunch or tab re-entry.
3. **PC3 [S2]**: An offline cold launch serves zero cached conversation history. The Ayma chat tab renders a blank screen with `"Couldn't load your conversation history."` and a `"Retry"` button. No saved messages are shown, and no stale/offline indicator is displayed.
4. **PC6 [S2]**: Under UMTS (3G throttling), Explore spins for 8s and aborts with raw exception text `Could not load Explore (ApiException(Request timed out — please try again., status 408))`, offering no retry button, no pull-to-refresh, and no local feed cache fallback.
5. **obs-1 [S3]**: When an auth token expires or is revoked mid-session (HTTP 401 on REST or LiveKit auth failure), the client experiences a silent disconnect or stuck loading states without explaining the issue or routing the user to re-authenticate.

Rather than patching these defects with piecemeal workarounds, this specification consolidates Antigravity's previous root-cause analyses (`antigravity/pc5pc6-offline-analysis` @ `bd88fa2` and `antigravity/pc3pc4-offline-analysis` @ `d7c8e3e`) into **ONE unified, production-ready architecture**:
- **Durable Disk-Backed ChatOutbox** (resolving PC4 and PC5).
- **Cached History with Frame-1 Hydration and SWR** (resolving PC3).
- **Polite Explore Error View, Feed Cache & Adaptive Timeout** (resolving PC6).
- **Centralized Forced Re-Auth Path** (resolving obs-1).

```
                      ┌──────────────────────────────────────────────┐
                      │             Ayma Shell UI                    │
                      └───────┬──────────────────────────────┬───────┘
                              │                              │
                    [Frame 1 Hydration]            [Optimistic Send Turn]
                              ▼                              ▼
                 ┌─────────────────────────┐    ┌─────────────────────────┐
                 │       ReportCache       │    │       ChatOutbox        │
                 │  (chat_history:$uid)    │    │   (chat_outbox:v1:$uid) │
                 │  (explore_feed:$uid)    │    │                         │
                 └────────────┬────────────┘    └────────────┬────────────┘
                              │                              │
                      [SWR Revalidate]           [Auto-Drain on Connectivity]
                              │                              │
                              ▼                              ▼
                 ┌────────────────────────────────────────────────────────┐
                 │                      ApiClient                         │
                 │  - X-Request-Timeout Budget                            │
                 │  - onAuthExpired (401 / Revocation Interceptor)       │
                 └────────────────────────────┬───────────────────────────┘
                                              │
                              ┌───────────────┴───────────────┐
                              ▼                               ▼
                      Cloud Run REST API              LiveKit Gateway
                      (/chat, /explore)              (Voice Realtime)
```

---

## 2. Superseded Baseline & Recent Staging Changes (`55f8782`)

Before Claude begins building T2, note the following updates on the `origin/staging` tip (`55f8782`) relative to the older analysis baselines (`c06ba66`):

1. **B9-PUSH Token 403 Gate Fixed (`55f8782`)**:
   - `functions/bootstrap/main.py` was updated in commit `55f8782` to allow fresh authenticated users without a profile document to register their initial FCM token (`POST /notifications/token`), resolving the B9 fresh-install push 403 issue while preserving the own-uid claim check.
2. **Internal Chat Context Leak Resolved (`364e9a2`)**:
   - `functions/bootstrap/chat_history.py` was updated in commit `364e9a2` (fixing R2-D3). `_collect()` now explicitly filters out internal annotation turns:
     ```python
     if doc.id.startswith("dm-") or doc.id.startswith("photo-"):
         continue
     ```
   - Server-side history projection (`GET /chat/history`) no longer leaks `photo-{mediaId}` internal annotations into user-facing chat. Claude's outbox and history caching can rely on clean server payloads without local workarounds for ghost photo annotations.

2. **CRITICAL Rule — All Inference on LiveKit (`d939b17` / `AGENTS.md`)**:
   - `AGENTS.md` and commit `d939b17` mandate: **ALL model inference (chat, voice, matching, vision) MUST run through LiveKit**. Direct provider fallbacks (`FLAG_LLM_ROUTE_*=vertex`, direct Vertex/OpenAI) are strictly forbidden.
   - When LiveKit hits a quota error (429) or is unreachable, the client must display an **honest error banner** — never a silent "Listening…", never a silent hang. Claude's error transitions in `ChatScreen` and `VoiceSessionController` must follow this rule.

3. **PC8 Explore Photo Stall Resolved (`c06ba66`)**:
   - Staging already landed Claude's 3-part fix for `AymaPhoto`: thumbnail disk resizing for `<= 400px` images is bypassed, `AymaPhoto` has a 10s stall guard falling back to the F1 initial avatar, and `prefetchCardPhotos` uses identical cache keys. Explore card rendering is verified green.

4. **UI Action `scroll_to_end` Added (`30a098a`)**:
   - App control navigation and scroll synchronization now use real repeated scrolls (`scroll_to_bottom` / `scroll_to_top`). Any history hydration must cooperate cleanly with `_scrollToBottom()`.

---

## 3. Component 1: Durable Disk-Backed `ChatOutbox` (PC4 + PC5)

### 3.1 Problem Statement & Failure Trace
- **PC4 Drop**: In `ChatScreen._send()` ([`chat_screen.dart:1720-1727`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L1720-L1727)), `PendingChatQueue` is only used if `!_queue.isEmpty` (`PendingChatQueue` was exclusively built for credit caps `usage_capped: true`). Normal user sends while funded bypass the queue and live only in volatile memory (`_store.addTurn()` and `_ChatScreenState._reconcile`).
- **PC5 Foreground Wedge**: When `_reconcilePendingSend()` ([`chat_screen.dart:849-937`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L849-L937)) fails, it updates the bubble to `"Waiting for a connection…"` and terminates. It relies solely on `didChangeAppLifecycleState(AppLifecycleState.resumed)` ([`chat_screen.dart:406-411`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L406-L411)) to try again. If the user leaves the app open when network returns, `resumed` **never fires**, wedging the bubble forever.
- **The Eradication**: When the user navigates away and re-enters chat (e.g. tapping the Ayma bottom orb, which calls `showPageContextAymaPopup`), a fresh `ChatScreen` mounts and executes `_loadHistory()` -> `_store.seed(loaded)` ([`chat_screen.dart:1180`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L1180)). In [`transcript_store.dart:320-328`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/transcript_store.dart#L320-L328):
  ```dart
  final live = _turns.where((t) =>
      t.source == TurnSource.voice &&
      !loadedKeys.contains((t.role, t.text.trim()))).toList();
  _turns..clear()..addAll(loaded)..addAll(live);
  ```
  `seed()` clears `_turns` and strictly keeps only `TurnSource.voice`! Unsent text messages and pending `"Waiting for a connection…"` bubbles are wiped from RAM. Because they never landed in Firestore, the message permanently vanishes.

---

### 3.2 Solution Architecture

#### A. Storage Model: Evolve `PendingChatQueue` into `ChatOutbox`
Target file: [`ayma_flutter/lib/services/pending_chat_queue.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/pending_chat_queue.dart) (or create [`chat_outbox.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/chat_outbox.dart) aliasing `PendingChatQueue`):
- **Class `OutboxItem` / `QueuedChatMessage`**:
  ```dart
  enum OutboxReason { outOfCredits, offline, sendError }
  enum OutboxStatus { pending, inFlight, failed }

  @immutable
  class QueuedChatMessage {
    const QueuedChatMessage({
      required this.clientMsgId,
      required this.message,
      this.imagePath = '',
      this.imageUrl = '',
      this.reason = OutboxReason.outOfCredits,
      this.status = OutboxStatus.pending,
      this.createdAt,
      this.attempts = 0,
    });

    final String clientMsgId;
    final String message;
    final String imagePath;
    final String imageUrl;
    final OutboxReason reason;
    final OutboxStatus status;
    final DateTime? createdAt;
    final int attempts;

    Map<String, dynamic> toJson() => {
      'id': clientMsgId,
      'message': message,
      'image_path': imagePath,
      'image_url': imageUrl,
      'reason': reason.name,
      'status': status.name,
      'created_at': createdAt?.toIso8601String(),
      'attempts': attempts,
    };

    static QueuedChatMessage? fromJson(Object? raw) {
      if (raw is! Map) return null;
      final id = raw['id'];
      final message = raw['message'];
      if (id is! String || id.isEmpty || message is! String) return null;
      return QueuedChatMessage(
        clientMsgId: id,
        message: message,
        imagePath: raw['image_path'] as String? ?? '',
        imageUrl: raw['image_url'] as String? ?? '',
        reason: OutboxReason.values.firstWhere(
          (r) => r.name == raw['reason'],
          orElse: () => OutboxReason.outOfCredits,
        ),
        status: OutboxStatus.values.firstWhere(
          (s) => s.name == raw['status'],
          orElse: () => OutboxStatus.pending,
        ),
        createdAt: raw['created_at'] != null ? DateTime.tryParse(raw['created_at'] as String) : null,
        attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
      );
    }
  }
  ```
- **Storage Location**: `SharedPreferences` key: `chat_outbox:v1:$uid`.
- **Public API**:
  - `bool has(String clientMsgId)`: returns true if the message is in outbox.
  - `Future<void> enqueue(QueuedChatMessage item)`: persists to disk, adds to in-memory list, notifies listeners.
  - `Future<void> flush({bool force = false})`: flushes deliverable items.
  - `Future<void> remove(String clientMsgId)`: removes upon confirmed delivery.
  - `Future<void> markFailed(String clientMsgId)`: transitions status to `OutboxStatus.failed`.

#### B. Active Drain Triggers
The outbox must not depend solely on `AppLifecycleState.resumed`:
1. **Connectivity Listener (`connectivity_plus`)**:
   - In `_ChatScreenState.initState()` and `ChatOutbox.activate()`:
     ```dart
     _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
       final online = results.any((r) => r != ConnectivityResult.none);
       if (online) {
         if (_reconcile != null && !_reconciling) {
           _reconcilePendingSend();
         }
         ChatOutbox.instance.flush();
       }
     });
     ```
2. **App Lifecycle**:
   - In `_ChatScreenState.didChangeAppLifecycleState(AppLifecycleState.resumed)`:
     - If `_reconcile != null`, invoke `_reconcilePendingSend()`.
     - Always call `ChatOutbox.instance.flush()`.
3. **Send-Time & On-Mount Activation**:
   - On `ChatScreen.initState()`: call `ChatOutbox.instance.activate()` and `flush()`.
   - On user send while offline: enqueue to `ChatOutbox`, render optimistic bubble, attempt immediate send; if network throws, mark as `OutboxReason.offline` and keep in outbox.
4. **Bounded Backoff Timer During Active Reconciliation**:
   - In `_ChatScreenState`: while `_reconcile != null`, schedule an exponential backoff timer (e.g. 3s, 8s, 15s) capped at 3 retries, so connection recovery does not rely solely on OS broadcast events.

#### C. `TranscriptStore.seed()` Preservation Rule
Target file: [`ayma_flutter/lib/services/transcript_store.dart:317-331`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/transcript_store.dart#L317-L331).
Update `seed()` to preserve:
1. `TurnSource.voice` turns not in server history.
2. Non-final turns (`!t.isFinal`: "Thinking…", "Reconnecting…", "Waiting for a connection…").
3. User turns whose `clientMsgId` is currently tracked in `ChatOutbox` or `_reconcile`.

```dart
void seed(Iterable<TranscriptTurn> turns) {
  final loaded = turns.toList();
  final loadedKeys = {for (final t in loaded) (t.role, t.text.trim())};
  final live = _turns.where((t) {
    if (loadedKeys.contains((t.role, t.text.trim()))) return false;
    // 1. Live voice turns
    if (t.source == TurnSource.voice) return true;
    // 2. Pending placeholder bubbles
    if (!t.isFinal) return true;
    // 3. Unconfirmed user turns waiting in outbox
    if (t.role == TurnRole.user && ChatOutbox.instance.has(t.clientMsgId)) {
      return true;
    }
    return false;
  }).toList();

  _turns
    ..clear()
    ..addAll(loaded)
    ..addAll(live);
  _trim();
  notifyListeners();
}
```

#### D. Honest Connection State & Bubble Retry Transition
- In `_reconcilePendingSend()`:
  - Phase 1: 0–6s: `"Reconnecting…"`
  - Phase 2: 6–30s: `"Waiting for a connection…"`
  - Phase 3: >30s or after 3 failed reconciliation loops:
    - Transition pending bubble text to: `"Couldn't send. Tap to retry"` (with error styling / chip).
    - `_reconcile = null;`
    - Tapping the failed turn invokes `_send(retry: rec.message, clientMsgId: rec.msgId)`.
    - Surface an `AymaToast` with action `Retry`.
    - The message is NEVER dropped. It remains in `ChatOutbox` until explicitly cancelled by the user or delivered.

---

### 3.3 Exact Files & Functions to Change
| File | Function / Location | Lines (Tip Baseline `d939b17`) | Proposed Change |
| :--- | :--- | :--- | :--- |
| `lib/services/pending_chat_queue.dart` | `QueuedChatMessage`, `PendingChatQueue` | Lines 15–53, 126–250 | Extend model with `OutboxReason`, `OutboxStatus`, `createdAt`, `attempts`. Persist under `chat_outbox:v1:$uid`. Provide `has(msgId)` and auto-flush on connectivity. |
| `lib/services/transcript_store.dart` | `TranscriptTurn`, `seed()` | Lines 25–45, 317–331 | Add optional `clientMsgId` to `TranscriptTurn`. In `seed()`, preserve non-final turns and outbox turns. |
| `lib/screens/chat_screen.dart` | `_send()` | Lines 1714–1772 | Enqueue user sends to `ChatOutbox` before wire call; remove bypass when funded. |
| `lib/screens/chat_screen.dart` | `_reconcilePendingSend()` | Lines 849–937 | Add timeout/retry limit; transition to "Tap to retry" chip on failure; clear reentrancy cleanly. |
| `lib/screens/chat_screen.dart` | `initState()`, `dispose()` | Lines 367–415 | Subscribe to `Connectivity().onConnectivityChanged`; cancel on `dispose()`. |
| `lib/widgets/chat_turn_bubble.dart` | `build()` | Lines 120–220 | Add tap handler on pending/failed bubble to trigger resend. |

---

## 4. Component 2: Cached Conversation History & SWR (PC3)

### 4.1 Problem Statement & Failure Trace
- In `ChatScreen.initState()` ([`chat_screen.dart:385`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L385)), `_loadHistory()` is called unconditionally.
- In `_loadHistory()` ([`chat_screen.dart:1093-1123`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L1093-L1123)), the client immediately awaits `_api.chatHistory(limit: 40)` over REST without checking any local disk cache.
- `TranscriptStore` is an ephemeral in-memory singleton initialized with `_turns = []` ([`transcript_store.dart:127`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/transcript_store.dart#L127)).
- When offline, `_api.chatHistory` immediately throws an `ApiException("Network error")`.
- The catch block sets `_historyError = "Couldn't load your conversation history."` ([`chat_screen.dart:1191`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L1191)).
- The UI renders lines 2373–2396: a blank screen with error text and a "Retry" button. No cached messages are visible.

---

### 4.2 Solution Architecture

#### A. Storage Model in `ReportCache`
Target file: [`ayma_flutter/lib/services/report_cache.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/report_cache.dart):
- `ReportCache` is already pre-hydrated during Startup DAG node `N2:shared_preferences` ([`startup_nodes.dart:131`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/core/dag/startup_nodes.dart#L131)), meaning `readChatHistory()` is **instantaneous (synchronous memory read from `_preloadedPrefs`)** on Frame 1.
- Key prefix: `chat_history:$uid`.
- Storage Payload: JSON object containing:
  ```json
  {
    "cached_at": "2026-11-02T07:30:00Z",
    "next_before": "2026-11-01T12:00:00Z",
    "messages": [
      {
        "role": "user",
        "text": "Good morning",
        "created_at": "2026-11-02T07:29:00Z",
        "client_msg_id": "cmsg_123"
      },
      {
        "role": "ayma",
        "text": "Good morning Daniel! How can I help today?",
        "created_at": "2026-11-02T07:29:05Z",
        "tools": []
      }
    ]
  }
  ```
- Methods on `ReportCache`:
  - `Future<void> writeChatHistory(String uid, List<ChatMessage> messages, String? nextBefore)`
  - `Future<({List<ChatMessage> messages, String? nextBefore, DateTime cachedAt})?> readChatHistory(String uid)`
  - Included in `clearForSignOut()` so account switching wipes cached chat history.

#### B. Frame-1 Hydration & Stale-While-Revalidate (SWR) in `_loadHistory()`
Target file: [`ayma_flutter/lib/screens/chat_screen.dart:1093-1200`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/chat_screen.dart#L1093-L1200):
```dart
Future<void> _loadHistory() async {
  final uid = _auth.currentUser?.uid ?? '';
  // 1. Frame-1 Instant Local Hydration
  if (_store.isEmpty && uid.isNotEmpty) {
    final cached = await ReportCache.instance.readChatHistory(uid);
    if (cached != null && cached.messages.isNotEmpty) {
      final cachedTurns = _messagesToTurns(cached.messages);
      _store.seed(cachedTurns);
      _isHistoryStale = true;
      if (mounted) setState(() {});
    }
  }

  // 2. Background Network Revalidation
  try {
    final target = widget.targetTimestamp.isEmpty
        ? null
        : DateTime.tryParse(widget.targetTimestamp);
    final page = await _api.chatHistory(limit: 40);
    final turns = _messagesToTurns(page.messages);
    _store.seed(turns);
    _isHistoryStale = false;
    _historyError = null;

    if (uid.isNotEmpty) {
      unawaited(ReportCache.instance.writeChatHistory(
        uid,
        page.messages,
        page.nextBefore,
      ));
    }
  } catch (e) {
    debugPrint('chat history network load failed: $e');
    if (_store.isEmpty) {
      // Truly cold with zero local cache -> show retry state
      if (mounted) _historyError = "Couldn't load your conversation history.";
    } else {
      // Cached data is visible on screen -> keep it! Do not blank the view.
      _isHistoryStale = true;
      _historyError = null;
    }
  } finally {
    if (mounted) setState(() => _loadingHistory = false);
  }
}
```

#### C. Honest Connection State Banner
When `_isHistoryStale == true`:
- Mount a non-intrusive status banner directly above the transcript (or within the `AppBar` / top padding):
  ```dart
  if (_isHistoryStale)
    Container(
      color: ac.bgElevated,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: ac.fgMute),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — showing saved messages',
              style: AymaType.sans(size: 12, color: ac.fgMute),
            ),
          ),
          TextButton(
            onPressed: _loadHistory,
            child: const Text('Refresh'),
          ),
        ],
      ),
    ),
  ```
- The conversation history remains 100% interactive, readable, and scrollable.

---

### 4.3 Exact Files & Functions to Change
| File | Function / Location | Lines (Tip Baseline `d939b17`) | Proposed Change |
| :--- | :--- | :--- | :--- |
| `lib/services/report_cache.dart` | `ReportCache` | Lines 33–45, 180–195 | Add `_chatHistoryPrefix = 'chat_history:'`. Add `writeChatHistory()` and `readChatHistory()`. Clear on `clearForSignOut()`. |
| `lib/screens/chat_screen.dart` | `_loadHistory()` | Lines 1093–1200 | Hydrate frame 1 from `ReportCache.instance.readChatHistory()`. On network error, retain cached turns. |
| `lib/screens/chat_screen.dart` | `build()` / transcript builder | Lines 2370–2410 | Render `"Offline — showing saved messages"` banner when `_isHistoryStale`. Only show full-screen `_historyError` if `_store.isEmpty`. |

---

## 5. Component 3: Explore Under Throttling & Network Timeout (PC6)

### 5.1 Problem Statement & Failure Trace
- In `BudgetHttpClient._executeGet` ([`api_client.dart:17, 86, 174`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/api_client.dart#L17-L187)), `/explore` is assigned `kInteractiveTimeout = Duration(seconds: 8)`.
- Under UMTS (3G throttling), latency is high and downloading Explore cards exceeds 8 seconds.
- `BudgetHttpClient` throws `ApiException('Request timed out — please try again.', statusCode: 408)`.
- In `ExploreScreen._loadInitial()` ([`explore_screen.dart:199-204`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/explore_screen.dart#L199-L204)), `_feed.error` is populated directly with the thrown `ApiException`.
- In `ExploreScreen.build()` ([`explore_screen.dart:347-353`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/explore_screen.dart#L347-L353)):
  ```dart
  if (_feed.error != null && !_feed.hasData) {
    return CenteredScroll(
      padding: const EdgeInsets.all(24),
      child: Text('Could not load Explore (${_feed.error}).',
          style: AymaType.sans(size: 14, color: AymaColors.error)),
    );
  }
  ```
  This renders raw exception text `Could not load Explore (ApiException(Request timed out — please try again., status 408)).`.
- **The Deficiencies**:
  1. Raw exception text exposed to user.
  2. No retry button or action.
  3. No pull-to-refresh (`RefreshIndicator` is only mounted when cards are present).
  4. No persistent feed cache fallback.

---

### 5.2 Solution Architecture

#### A. Friendly, Polished Error Card with "Try again"
Target file: [`ayma_flutter/lib/screens/explore_screen.dart:347-354`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/screens/explore_screen.dart#L347-L354):
- Replace the raw exception text with:
  ```dart
  if (_feed.error != null && !_feed.hasData) {
    return RefreshIndicator(
      onRefresh: reload,
      child: CenteredScroll(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
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
              _friendlyExploreError(_feed.error),
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.fgMute),
            ),
            const SizedBox(height: 24),
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
- Helper function `_friendlyExploreError(Object? error)`:
  - If error is `ApiException` with `statusCode == 408` or contains `'timed out'`: return `"Connection timed out. Check your connection and try again."`
  - If error contains `'Network error'`: return `"Check your internet connection and try again."`
  - Never interpolate raw `ApiException` or status codes into user-facing copy.

#### B. Pull-to-Refresh Availability on Error State
- Wrap the error view in `RefreshIndicator(onRefresh: reload, child: CenteredScroll(...))` so users can pull down to retry at any time.

#### C. Explore Feed Persistence & Fallback
- In `ReportCache`, add `writeExploreFeed(String uid, ExplorePage page)` and `readExploreFeed(String uid)`.
- Key: `explore_feed:$uid` in `SharedPreferences`.
- On `ExploreScreen._loadInitial()`:
  - If `_feed.items.isEmpty`, hydrate from cached page-1 cards marked `isFromCache: true`.
  - If `/explore` times out or fails over 3G throttling:
    - Retain the cached cards on screen.
    - Surface a `FreshnessIndicator(state: FreshnessState.refused, onRetry: _loadInitial)` or offline banner.
    - The user can still view profile cards and initiate actions.

#### D. Adaptive Timeout Budget for Explore
- In `ApiClient` ([`api_client.dart:86-94`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/api_client.dart#L86-L94)):
  - Include `/explore` in `_isExplorePath` giving it a **15-second budget** (or 1 bounded retry if >2s remain on deadline), rather than aggressively killing the request at 8 seconds under 3G throttling.

---

### 5.3 Exact Files & Functions to Change
| File | Function / Location | Lines (Tip Baseline `d939b17`) | Proposed Change |
| :--- | :--- | :--- | :--- |
| `lib/screens/explore_screen.dart` | `body: Builder` | Lines 347–354 | Replace raw error text with polite error card, `AymaButton('Try again')`, and `RefreshIndicator`. |
| `lib/screens/explore_screen.dart` | `_loadInitial()` | Lines 160–205 | Hydrate frame 1 from `ReportCache.instance.readExploreFeed()`. Cache successful page 1. |
| `lib/services/api_client.dart` | `_timeoutFor()` | Lines 86–94 | Expand `/explore` timeout budget from 8s to 15s. |
| `lib/services/report_cache.dart` | `ReportCache` | Lines 33–45 | Add `writeExploreFeed` / `readExploreFeed`. |

---

## 6. Component 4: Expired Token -> Forced Re-Auth Path (obs-1)

### 6.1 Problem Statement & Failure Trace
- In Scout's staging sweep doc (`docs/testing/staging-15e5a54_2026-11-01.md:11` / `scout.md:218`), an S3 observation was filed: `expired-token→disconnect`.
- When a user's Firebase auth token expires, is revoked, or is rejected with HTTP 401:
  - In `ApiClient._headers()` ([`api_client.dart:354`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/api_client.dart#L354)): `throw ApiException('Not signed in.', statusCode: 401);`.
  - In individual API endpoints: responses with status code 401 throw `ApiException(..., statusCode: 401)`.
  - In `VoiceSessionController._closedSub` ([`voice_session_controller.dart:512-522`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/voice_session_controller.dart#L512-L522)): when LiveKit disconnects due to token expiration, it logs `RoomDisconnected: ...`, teardowns silently, and sets voice state to idle or reports `"voice connection dropped"`.
- The user is left in a **zombie state**: buttons fail silently or show generic network errors, voice silently dies, and the user is never prompted to log in again.

---

### 6.2 Solution Architecture

#### A. Centralized Auth Expiry Listener on `ApiClient`
Target file: [`ayma_flutter/lib/services/api_client.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/api_client.dart):
- Add a singleton or callback `void Function()? onAuthExpired`:
  ```dart
  class ApiClient {
    ...
    static void Function()? onAuthExpired;

    void _handleAuthRejection(int statusCode) {
      if (statusCode == 401) {
        onAuthExpired?.call();
      }
    }
  }
  ```
- In `_get`, `_post`, `_put`, `_delete`, and `_streamJson`: if `response.statusCode == 401`, trigger `_handleAuthRejection(401)`.

#### B. Voice Session Explicit Auth Rejection
Target file: [`ayma_flutter/lib/services/voice_session_controller.dart:512-525`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/services/voice_session_controller.dart#L512-L525):
- When `_closedSub` receives a disconnect event:
  - If the reason contains `'token expired'`, `'unauthorized'`, or `'auth'`, set state to `VoiceStatus.error` with explicit user-facing banner:
    `"Your session expired. Please sign in again."`
  - Trigger `ApiClient.onAuthExpired?.call();`
  - Never allow a silent disconnect back to idle.

#### C. Forced Re-Auth Flow
Target file: [`ayma_flutter/lib/main.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/main.dart) or [`app_router.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/routing/app_router.dart):
- Wire `ApiClient.onAuthExpired`:
  ```dart
  ApiClient.onAuthExpired = () async {
    debugPrint('[Auth] Session expired or revoked (401). Triggering forced re-auth.');
    try {
      await ReportCache.instance.clearForSignOut();
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    appRouter.go(SignInScreen.path);
    AymaToast.show(
      appRouter.routerDelegate.navigatorKey.currentContext!,
      'Your session expired. Please sign in again.',
      kind: AymaToastKind.error,
    );
  };
  ```
- Because `appRouter.redirect` ([`app_router.dart:119-135`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/t2-offline-spec/ayma_flutter/lib/routing/app_router.dart#L119-L135)) already enforces that unauthenticated users bounce to `SignInScreen.path`, `FirebaseAuth.instance.signOut()` immediately flushes all route stacks and lands cleanly on Sign In.

---

### 6.3 Exact Files & Functions to Change
| File | Function / Location | Lines (Tip Baseline `d939b17`) | Proposed Change |
| :--- | :--- | :--- | :--- |
| `lib/services/api_client.dart` | `_headers()`, `_postJsonOk()`, response checkers | Lines 351–360, 2311–2324 | Add `onAuthExpired` callback; invoke when `statusCode == 401`. |
| `lib/services/voice_session_controller.dart` | `_closedSub` listener | Lines 512–522 | Check for auth disconnect reasons; surface explicit error; invoke `onAuthExpired`. |
| `lib/main.dart` | Startup listeners | Lines 60–80 | Bind `ApiClient.onAuthExpired` to clear cache, `signOut()`, and route to `SignInScreen.path`. |

---

## 7. Component Interfaces & Interactions

```
+-----------------------------------------------------------------------------------+
|                                 ChatScreen                                        |
|                                                                                   |
|  - _loadHistory()                                                                 |
|      1. reads ReportCache.instance.readChatHistory(uid)  --> frame-1 instant       |
|      2. fetches _api.chatHistory(limit: 40)             --> SWR revalidate        |
|      3. writes ReportCache.instance.writeChatHistory()  --> persists page-1       |
|                                                                                   |
|  - _send()                                                                        |
|      1. ChatOutbox.instance.enqueue(QueuedChatMessage)  --> disk-backed outbox    |
|      2. _store.addTurn(userTurn)                        --> with clientMsgId      |
|      3. unawaited(ChatOutbox.instance.flush())          --> triggers delivery     |
|                                                                                   |
|  - _reconcilePendingSend()                                                        |
|      1. polls _api.chatHistory() for landed reply                                |
|      2. if fails after budget --> transitions bubble to "Tap to retry" chip       |
+-----------------------------------------------------------------------------------+
                                         │
                                         ▼
+-----------------------------------------------------------------------------------+
|                              TranscriptStore                                      |
|                                                                                   |
|  - seed(Iterable<TranscriptTurn> turns)                                           |
|      * Loaded keys from server/cache                                              |
|      * Preserves:                                                                 |
|          1. TurnSource.voice turns                                                |
|          2. Pending non-final bubbles (!t.isFinal)                                |
|          3. Outbox user turns (ChatOutbox.instance.has(t.clientMsgId))             |
+-----------------------------------------------------------------------------------+
                                         │
                                         ▼
+-----------------------------------------------------------------------------------+
|                                 ChatOutbox                                        |
|                                                                                   |
|  - SharedPreferences key: chat_outbox:v1:$uid                                     |
|  - Connectivity().onConnectivityChanged --> auto-flush                            |
|  - AppLifecycleState.resumed           --> auto-flush                            |
|  - _deliver(item): checks landed reply via _api.chatHistory(noRetry: true)        |
+-----------------------------------------------------------------------------------+
```

---

## 8. Claude's Step-by-Step Build Order & Implementation Checklist

Execute in this strict sequence to ensure each step is testable and non-regressive:

- [ ] **Step 1: Outbox Model & Persistence (`chat_outbox.dart`)**
  - Define `OutboxReason`, `OutboxStatus`, and updated `QueuedChatMessage`.
  - Wire SharedPreferences disk persistence under `chat_outbox:v1:$uid`.
  - Add `has(clientMsgId)`, `enqueue()`, `remove()`, and `markFailed()`.
  - Unit test in `test/chat_outbox_test.dart`.

- [ ] **Step 2: TranscriptStore Seed Protection (`transcript_store.dart`)**
  - Add `clientMsgId` to `TranscriptTurn`.
  - Update `TranscriptStore.seed()` to preserve non-final turns and outbox turns.
  - Unit test in `test/transcript_store_test.dart`.

- [ ] **Step 3: History Caching in `ReportCache` (`report_cache.dart`)**
  - Add `writeChatHistory` and `readChatHistory` with JSON serialization.
  - Include `chat_history:` prefix in `clearForSignOut()`.
  - Unit test in `test/report_cache_test.dart`.

- [ ] **Step 4: ChatScreen SWR History Hydration & Banner (`chat_screen.dart`)**
  - In `_loadHistory()`: read cache frame-1, set `_isHistoryStale = true`, seed store.
  - Fetch network in background; update cache and set `_isHistoryStale = false`.
  - Render `"Offline — showing saved messages"` banner if stale.
  - Widget test in `test/chat_offline_cache_test.dart`.

- [ ] **Step 5: ChatScreen Outbox Wiring & Active Connectivity Drain (`chat_screen.dart`)**
  - Enqueue all sends to `ChatOutbox`.
  - Subscribe to `Connectivity().onConnectivityChanged` and flush on reconnect.
  - Add 30s timeout on `_reconcilePendingSend` transitioning to "Tap to retry" chip.
  - Widget test in `test/chat_outbox_drain_test.dart`.

- [ ] **Step 6: ExploreScreen Resilience & Feed Cache (`explore_screen.dart`, `report_cache.dart`)**
  - Add `writeExploreFeed` / `readExploreFeed` in `ReportCache`.
  - Hydrate frame 1 from cache.
  - Replace raw exception text with polite error card, `AymaButton('Try again')`, and `RefreshIndicator`.
  - Expand `/explore` budget to 15s in `api_client.dart`.
  - Widget test in `test/explore_offline_test.dart`.

- [ ] **Step 7: Centralized Forced Re-Auth (obs-1) (`api_client.dart`, `voice_session_controller.dart`, `main.dart`)**
  - Add `ApiClient.onAuthExpired`.
  - Hook 401 responses in `_get`, `_post`, etc.
  - Handle LiveKit auth disconnect in `voice_session_controller.dart`.
  - Bind in `main.dart` to clear cache, `signOut()`, and route to `SignInScreen.path`.
  - Unit test in `test/auth_expired_test.dart`.

- [ ] **Step 8: Full Regression Suite Verification**
  - Run `flutter test test/layout_matrix_test.dart` (ensure zero RenderFlex overflows).
  - Run `flutter test test/app_registry_test.dart` and `pytest functions/bootstrap/tests/test_app_registry.py`.

---

## 9. Scout's Acceptance Test Cases (QA Runbook)

Scout will execute these test cases on emulator-5554 (ThinkPad bench):

### Test Case 1: PC4 — Offline Send & Reconnect Delivery
- **Setup**: Device signed in as Daniel (demo-test1), positioned on Chat tab. Radios killed (`adb shell svc wifi disable && adb shell svc data disable`).
- **Steps**:
  1. Type message `"Good morning offline"` and tap send.
  2. Verify bubble renders optimistically with status `"Waiting for a connection…"`.
  3. Re-enable radios (`adb shell svc wifi enable && adb shell svc data enable`).
  4. Navigate away to Explore tab; verify Explore loads fresh.
  5. Tap bottom Ayma orb to re-enter Chat.
- **Pass Condition**:
  - The message `"Good morning offline"` does **NOT** vanish.
  - The outbox automatically drains upon reconnect.
  - Server history (`GET /chat/history`) contains the user message and an Ayma reply.
  - Transcript updates to confirmed Ayma response bubble.

### Test Case 2: PC5 — Mid-Flight Radio Cut & Foreground Recovery
- **Setup**: Device on Chat tab with active internet.
- **Steps**:
  1. Send message `"Testing mid-flight cut"`.
  2. Kill radios ~1s later mid-flight.
  3. Observe bubble transitions to `"Reconnecting…"`, then `"Waiting for a connection…"`.
  4. Wait 10s. Restore radios while keeping the app in the foreground (do NOT background the app).
- **Pass Condition**:
  - Within 5s of radio restoration, client auto-reconciles/resends without requiring app backgrounding or relaunch.
  - If network is left off for >30s, bubble transitions to `"Couldn't send. Tap to retry"`. Tapping the bubble initiates resend.
  - Zero wedge, zero phantom bubble.

### Test Case 3: PC3 — Offline Cold Launch & Cached History Hydration
- **Setup**: App launched previously so conversation history exists. Kill radios. Force-stop app (`adb shell am force-stop com.ayma.ai`).
- **Steps**:
  1. Launch app offline (`adb shell am start -n com.ayma.ai/.MainActivity`).
  2. Observe splash screen and transition to Chat tab.
- **Pass Condition**:
  - Chat tab paints on Frame 1 with page 1 of saved conversation history (up to 40 messages).
  - Honest status banner is displayed: `"Offline — showing saved messages"`.
  - Zero blank screen, zero `"Couldn't load your conversation history."` blocking error.
  - Restoring radios silently revalidates history and clears the stale banner.

### Test Case 4: PC6 — Explore Under 3G Throttling & Network Timeout
- **Setup**: Emulator network throttled to UMTS / 3G (`adb emu network speed umts delay umts`).
- **Steps**:
  1. Navigate to Explore tab.
  2. Wait for request timeout (>8s).
- **Pass Condition**:
  - If cached feed exists: saved cards render immediately with `"Offline — showing saved data"` banner.
  - If cold without cache: polite error card displays `"Couldn't load Explore"` + `"Connection timed out. Check your connection and try again."` with an explicit `"Try again"` button.
  - Zero raw `ApiException(Request timed out — please try again., status 408)` text visible.
  - Swipe down triggers `RefreshIndicator` and retries `/explore`.

### Test Case 5: obs-1 — Expired Token Forced Re-Auth
- **Setup**: Active session as Daniel. Force token revocation on backend or simulate 401 on next REST / LiveKit interaction.
- **Steps**:
  1. Trigger an in-app action (send message, load profile, or start voice call).
- **Pass Condition**:
  - If in voice call: call ends immediately with an honest on-screen message `"Your session expired. Please sign in again."` (never silent drop to idle).
  - App clears local cache, signs out, and navigates directly to `SignInScreen`.
  - Toast displays: `"Your session expired. Please sign in again."`.
  - App never enters a zombie state or infinite loading loop.

---

## 10. Summary Table for Claude

| Component | Target Files | Key Invariant |
| :--- | :--- | :--- |
| **Durable ChatOutbox** (PC4, PC5) | `pending_chat_queue.dart`<br>`chat_screen.dart`<br>`transcript_store.dart` | Normal sends persist to disk; `Connectivity` listener auto-flushes on reconnect; `seed()` never purges unconfirmed text turns; 30s timeout to retry chip. |
| **Cached History & SWR** (PC3) | `report_cache.dart`<br>`chat_screen.dart` | Page 1 hydrates synchronously on frame 1 from `ReportCache`; SWR background revalidation; failure keeps cached turns and shows stale banner. |
| **Explore Resilience** (PC6) | `explore_screen.dart`<br>`api_client.dart`<br>`report_cache.dart` | Friendly error card + `AymaButton('Try again')` + `RefreshIndicator`; feed cache fallback; 15s adaptive timeout for `/explore`. |
| **Forced Re-Auth** (obs-1) | `api_client.dart`<br>`voice_session_controller.dart`<br>`main.dart` | HTTP 401 triggers `ApiClient.onAuthExpired`; voice tears down with explicit banner; forced clean route to `SignInScreen`. |
