# Read-Only Review: Claude's GW-SCROLL-B Re-fix (Staging 80806b9)

**Reviewer:** Antigravity (Engineer)  
**Date:** 2026-11-02 13:15 PT  
**Target Commit:** `80806b9` (`fix/gw-scroll-hang` merged into `staging`)  
**Base Commit:** `df73422`  
**Specimen under test:** Daniel → Explore via chat sheet → orb → "scroll to the bottom" (GW-SCROLL variant B)  
**Review Type:** Strictly read-only; zero app-code edits.

---

## Executive Summary

| Requirement / Component | Verdict | Summary |
|---|---|---|
| **Part 1: Persist user message at turn-start** | **COVERED** | `_persist_user_turn` commits user message to Firestore at turn start (idempotent per `client_msg_id` via `chat_history.user_turn_exists`). |
| **Part 2: Server honest completion on Explore op & disconnect shielding** | **COVERED** | `chat_stream` and `chat` catch generation/tool exceptions, persist `_CHAT_INCOMPLETE_REPLY`, and ride disconnection-proof `_spawn_turn`. |
| **Part 3: Growth-cap Explore scroll-to-end** | **COVERED** | `_scrollToEnd` stops after `kScrollToEndMaxGrowths` (3) page expansions (~1.5–3s), returning `"Stopped after N scrolls — more content may remain."` well within the 30s ack window. |
| **Part 4: Client fix if sheet-dismiss aborts in-flight turn** | **COVERED** | **Architectural proof:** sheet dismissal does *not* abort the server turn (`_spawn_turn` shields it) nor app control (`AppCommandService.shared` is app-scoped). No client bug existed; no client code changes needed. |
| **Variant A Regression Risk** | **NONE** | Finite profile list extent is stable (`mx` does not grow >200px); still runs to completion (`"Reached the bottom."`). Verified by tests. |
| **Honest-Completion Audit** | **CRITICAL NOTE** | **Edge case discovered:** `TokenCapExceeded` in `main.py` catches credit caps and returns early *after* `_persist_user_turn` has already written the user turn, stranding an unreplied user bubble in Firestore (contradicting docs/commit notes and triggering voice opener suppression). |

---

## 1. Per-Part Detailed Verdict & Evidence

### Part 1: Persist the USER message at turn-start, so a turn can never evaporate
- **Verdict:** **COVERED**
- **File & Line Evidence:**
  - `functions/bootstrap/main.py:1675–1695`: Defines `_persist_user_turn(ctx: _ChatCtx, req: ChatRequest)`. Reads `req.client_msg_id` and writes the `user` turn to Firestore `chat_messages` subcollection if it does not already exist. Best-effort; exceptions are caught and logged so a Firestore glitch never blocks `/chat`.
  - `functions/bootstrap/main.py:1816`: Invoked at the very beginning of `chat()._turn()`.
  - `functions/bootstrap/main.py:2014`: Invoked at the very beginning of `chat_stream()._turn()`.
  - `functions/bootstrap/chat_history.py:143–160`: Implements `user_turn_exists(db, uid: str, client_msg_id: str) -> bool`. Queries `chat_messages` collection where `client_msg_id == str(client_msg_id)` and verifies `role == 'user'`.
  - `functions/bootstrap/main.py:1722–1729`: In `_finalize_chat()`, only appends the `user` turn if `not (client_msg_id and chat_history.user_turn_exists(...))`, guaranteeing zero double-append of user turns.
  - `functions/bootstrap/tests/test_chat.py:566–620`: Unit tests `test_chat_stream_errored_turn_persists_user_and_an_honest_reply`, `test_chat_errored_turn_persists_user_and_an_honest_reply`, and `test_chat_stream_normal_turn_persists_one_user_and_one_ayma` verify persistence and de-duplication.
- **Specimen Analysis (Daniel on Explore):** When Daniel sends "scroll to the bottom", `ChatScreen` (`chat_screen.dart:1933`) passes a fresh `client_msg_id`. `_persist_user_turn` commits the user message to Firestore within the first few milliseconds. Even if network drops, server crashes, or model execution aborts downstream, the user message is permanently preserved in history.

---

### Part 2: Server completes honestly on the Explore op path too; no discard on client disconnect
- **Verdict:** **COVERED**
- **File & Line Evidence:**
  - `functions/bootstrap/main.py:1936–1938`: Introduces fallback constant:
    ```python
    _CHAT_INCOMPLETE_REPLY = "Sorry — I couldn't finish that just now. Please try again."
    ```
  - `functions/bootstrap/main.py:2104–2130`: In `chat_stream()._turn()`, both `TimeoutError` and general `Exception` (e.g. `RuntimeError("Gemini returned an empty response.")` from `gemini.py:327`) are caught. The handler queues an SSE error event to notify any live client, sets `reply_text = _CHAT_INCOMPLETE_REPLY`, and unconditionally calls `_finalize_chat(finalize_bg, ctx, req, reply_text, tools_used)`.
  - `functions/bootstrap/main.py:1824–1835`: In `chat()._turn()`, `Exception` is caught, sets `reply_text = _CHAT_INCOMPLETE_REPLY`, calls `_finalize_chat`, and returns HTTP 200 with the honest reply instead of raising HTTP 502.
  - `functions/bootstrap/main.py:1633–1650` & `1976–1982`: `_spawn_turn(coro, key=key)` executes `_turn()` in a detached, strongly-referenced `asyncio.Task`. Starlette cancelling the SSE `StreamingResponse` on client socket drop only cancels the `_relay()` generator; `_turn()` continues running to completion in the background and commits both turns to Firestore.
  - `functions/bootstrap/tests/test_chat.py:566–609, 623–638`: Verifies errored turns in `/chat` and `/chat/stream` always persist `_CHAT_INCOMPLETE_REPLY` and `/chat` returns 200.
- **Specimen Analysis (Daniel on Explore):** If the Explore scroll op times out or returns `_NOT_APPLIED` and Gemini produces an empty response, the server no longer skips `_finalize_chat`. It writes `_CHAT_INCOMPLETE_REPLY` to Firestore. Client disconnection during sheet dismissal does not cancel the turn.

---

### Part 3: Cap Explore scroll-to-end well under the window ("stopped after N — more may remain") instead of grinding 50 steps × pagination
- **Verdict:** **COVERED**
- **File & Line Evidence:**
  - `ayma_flutter/lib/services/screen_capture.dart:471`: `const int kScrollToEndMaxGrowths = 3;`
  - `ayma_flutter/lib/services/screen_capture.dart:475`: `const double _kScrollGrowthThreshold = 200;`
  - `ayma_flutter/lib/services/screen_capture.dart:793–794, 816–825`: In `ScreenCapture._scrollToEnd()`:
    ```dart
    final mx = after.scrollExtentMax;
    if (mx != null) {
      if (lastMax != null && mx > lastMax + _kScrollGrowthThreshold) {
        growths++;
        if (growths >= kScrollToEndMaxGrowths) {
          return (reachedEnd: false, steps: steps);
        }
      }
      lastMax = mx;
    }
    ```
  - `ayma_flutter/lib/services/screen_capture.dart:718–721`: Formats the honest result header:
    ```dart
    final head = end.reachedEnd
        ? 'Reached $where.'
        : 'Stopped after ${end.steps} scrolls — more content may remain.';
    ```
  - `ayma_flutter/test/screen_capture_test.dart:429–452`: Test `scroll_to_bottom on a growing list stops EARLY (growth-capped), honestly — not the full step cap (GW-SCROLL variant B: Explore)` asserts parsed steps `n < kScrollToEndMaxSteps` and result contains `'more content may remain'`.
- **Timing & Specimen Check:** Explore's paginated feed (`explore_screen.dart:210`, `_loadNextPage`) loads batches of cards, each extending `scrollExtentMax` by >200px. After 3 expansions, `_scrollToEnd` stops after ~3–6 steps. With a 450ms settle delay per step (`screen_capture.dart:801`), client execution takes ~1.5–3.0 seconds, easily completing within the server's 30s `_SCROLL_ACK_TIMEOUT_SECONDS` bound and the ~42s POST window.

---

### Part 4: Client fix if sheet-dismiss aborts the in-flight turn
- **Verdict:** **COVERED (Architecturally Verified: Non-Issue / No Client Bug)**
- **File & Line Evidence:**
  - `ayma_flutter/lib/services/app_command_service.dart:61–140`: `AppCommandService.shared` is an app-level singleton instantiated at boot (`startup_nodes.dart:358`), not scoped to the `ChatScreen` or `AymaChatModal` widget tree.
  - `ayma_flutter/lib/core/dag/startup_nodes.dart:360–365` & `ayma_flutter/lib/services/screen_capture.dart:678–679`: When `ui_action` executes, `_beforeAct()` invokes `screenPopupTracker.navigator?.pop()`, intentionally dismissing the chat sheet to reveal the underlying screen before capturing semantics and performing the scroll.
  - `functions/bootstrap/main.py:1633–1650`: While popping the sheet unmounts `ChatScreen` and cancels the client's SSE `StreamSubscription`, the server-side turn runs in `_spawn_turn()`. It does *not* abort; it completes and writes to Firestore.
  - `ayma_flutter/lib/screens/chat_screen.dart:385, 1093–1185`: When the user reopens the chat sheet or navigates to `/ayma`, `_loadHistory()` queries `GET /chat/history` and calls `TranscriptStore.seed()`, restoring the full completed turn.
- **Specimen Analysis:** The original hypothesis that sheet dismissal was aborting the turn client-side was disproven during Claude's root-cause analysis: the turn was evaporating solely because the 50-step scroll overrun triggered server-side empty-response failure which skipped `_finalize_chat`. Because the client architecture was already safe, no client-side abortion fix was necessary.

---

## 2. Regression Risk Analysis for Variant A (Profile Scroll Op)

**Verdict:** **NO REGRESSION RISK (PASSED & PRESERVED)**

- **Finite List Semantics:** `PublicProfileScreen` (`public_profile_screen.dart:870–930`) renders member details, photos, and living reports inside a static `ListView(children: [...])`. It is a finite list, not a paginated infinite scroll.
- **Extent Stability:** Because all profile sections are loaded upfront, `after.scrollExtentMax` is constant. The condition `mx > lastMax + _kScrollGrowthThreshold` (200px) does not trigger across scroll iterations (`growths` remains 0).
- **Execution to Real End:** `_scrollToEnd` continues until `(a - b).abs() < 0.5` or `!hasAction(action)`, returning `reachedEnd: true` and formatting `'Reached the bottom.'`.
- **Automated Verification:** `ayma_flutter/test/screen_capture_test.dart:486–540` explicitly tests `scroll_to_bottom` with sheet dismissal on `/profile/user/u1`. It asserts:
  ```dart
  expect(r.ok, isTrue);
  expect(r.result, contains('Reached the bottom.'));
  ```
  The test passes completely.

---

## 3. Honest-Completion Guarantee Audit

### Finding 1: `TokenCapExceeded` Leaves Stranded User Turn in Firestore (Critical Discrepancy)

> [!WARNING]
> **Code vs Documentation & Contract Discrepancy:**
> In `functions/bootstrap/main.py`, `_persist_user_turn(ctx, req)` is invoked at the start of both `chat()` (line 1816) and `chat_stream()` (line 2014).
>
> 1. When a client sends a message with `client_msg_id` (standard in `ChatScreen`), the user turn is immediately written to Firestore `chat_messages`.
> 2. If the user's credits are exhausted, `_generate_chat_reply` or `generate_reply_events` raises `token_ledger.TokenCapExceeded`.
> 3. The exception handlers:
>    - `chat()` (`main.py:1820–1823`): returns early with `_USAGE_CAPPED_REPLY`.
>    - `chat_stream()` (`main.py:2095–2103`): queues `_USAGE_CAPPED_REPLY` and returns early.
>    Neither handler calls `_finalize_chat()`.
>
> **Impact:**
> - The user message *remains written in Firestore*, but Ayma's reply is *never persisted*.
> - This directly contradicts commit `80806b9`, `docs/ARCHITECTURE.md` §1.6b, and `docs/TODO_QUEUE.md`, which all claim: *"TokenCapExceeded still intentionally persists nothing."*
> - **Cross-system impact on Voice:** In `functions/bootstrap/agent.py:3047`, `maybe_open_conversation` checks:
>   `if seed.seed_turns and seed.seed_turns[-1].role == ROLE_USER: return False`
>   Leaving an unreplied user bubble at the end of history causes the voice agent to silently suppress its call opener and hang in `listening` mode!
>
> **Recommended Resolution for Claude:**
> Update the `TokenCapExceeded` handlers to call `_finalize_chat(finalize_bg, ctx, req, _USAGE_CAPPED_REPLY, [])`, ensuring every turn ends with a paired, honest reply.

### Finding 2: Stream Error Triggers Client Reconciliation Round-Trip
- In `functions/bootstrap/main.py:2104–2111`, when generation raises, `chat_stream` emits `{"type": "error", "detail": ...}` and closes the stream, rather than emitting a `{"type": "reply", "text": _CHAT_INCOMPLETE_REPLY}` frame.
- On the client (`api_client.dart:2580–2584`), this raises `ApiException(502)`, prompting `ChatScreen._send` (`chat_screen.dart:1971–1976`) to call `resend()`.
- `resend()` hits `POST /chat`, which fetches the persisted `_CHAT_INCOMPLETE_REPLY` from `_persisted_turn_reply` and displays it.
- **Verdict:** Honest completion is preserved in the end-state, though it relies on client fallback reconciliation rather than a live SSE reply frame.

---

## 4. Conclusion & Test Recommendation

1. **Staging Tip `80806b9` (APK 2254) is sound to test variant B.**
2. **Scout Test Matrix:**
   - Execute exact specimen: Daniel → Explore via chat sheet → orb → "scroll to the bottom".
   - Expected behavior:
     - Chat sheet dismisses cleanly.
     - Explore scrolls ~3–5 steps and stops honestly (~2–3 seconds).
     - Ayma replies with honest status (e.g. "Stopped after 4 scrolls — more content may remain").
     - Reopening the chat sheet or viewing `GET /chat/history` displays both Daniel's message and Ayma's reply. Zero turn evaporation.
3. **Follow-up for Claude:** Address the `TokenCapExceeded` orphan turn write so credit-capped turns do not leave stranded user messages in Firestore.
