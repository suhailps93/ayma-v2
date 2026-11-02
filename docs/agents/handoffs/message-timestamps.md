# Task Handoff: WhatsApp-style Date + Time on Messages (Display-Only)

**Task Name:** message-timestamps  
**Date:** 2026-10-31  
**Branch:** `feat/message-timestamps`  
**Author:** Antigravity (Pair Programming with Suhail)  
**Reviewer/PM:** Astro (Muse) / Founder: Suhail  

---

## 1. Code Verification (Verify-Before-Fix)

Before making changes, the message rendering mechanisms and timestamps were analyzed across both requested surfaces:

### Surface (a): DM Thread Screen (`ayma_flutter/lib/screens/dm_thread_screen.dart`)
- **Rendering mechanism:** `StreamBuilder<List<DmMessage>>` listens to `_dm.watchMessages(threadId)` which streams Firestore collection `dm_threads/$threadId/messages` ordered by `created_at`. Rendered via `ListView.builder` with `reverse: true`.
- **Message model:** `DmMessage` in `ayma_flutter/lib/services/dm_service.dart`.
- **Timestamp availability:** Confirmed. `DmMessage` carries `final DateTime? createdAt;`, parsed directly from Firestore `(m['created_at'] as Timestamp?)?.toDate()`. All messages saved to Firestore contain `created_at`, so `createdAt` is usable client-side.

### Surface (b): Ayma Assistant Chat Screen (`ayma_flutter/lib/screens/chat_screen.dart`)
- **Rendering mechanism:** `ListenableBuilder` listens to `TranscriptStore _store` containing `List<TranscriptTurn> turns`. Rendered via `ListView.builder` (forward scroll).
- **Message model:** `TranscriptTurn` in `ayma_flutter/lib/services/transcript_store.dart`.
- **Timestamp availability:**
  - For messages loaded from server history (`GET /chat/history`): `ChatMessage.fromMap` parses `m['created_at']` (ISO 8601 string) into `DateTime`. `_loadHistory()` passes this into `TranscriptTurn.createdAt`.
  - For turns appended via background skill completions (`_pullBackgroundResults()`): `TranscriptTurn.createdAt` is populated.
  - For live turns created during the active session: `_send()` creates optimistic user turns via `_store.addTurn()`, and live Ayma stream responses resolve via `_store.resolvePending()`. Neither method populates `createdAt` (it defaults to `null`).
- **Gap Found & Recorded:**
  - In the Ayma Assistant Chat screen, live turns created within the active session do not possess a server timestamp until the transcript is fetched from `/chat/history`.
  - Per the strict task instructions ("*If a surface lacks a usable timestamp, do NOT invent data — implement for the surface that has it and record the gap in the handoff note*"), no artificial timestamp (such as a local `DateTime.now()` placeholder) was invented. When `createdAt` is `null`, time labels and date chips are omitted, and they appear seamlessly once the durable history is loaded.

---

## 2. What Changed Per Surface

### Shared Component: `ayma_flutter/lib/widgets/message_timestamp.dart`
Created a dedicated, dependency-free utility and widget library:
- `formatMessageTime(DateTime dt)`: Formats into 12-hour WhatsApp-style time `h:mm AM/PM` (e.g. `9:41 AM`, `1:15 PM`).
- `formatDateDivider(DateTime dt, {DateTime? now})`: Returns:
  - `"Today"` for today's calendar date.
  - `"Yesterday"` for yesterday's calendar date.
  - Weekday name (e.g. `"Monday"`, `"Friday"`) for dates within the last 7 days (2–6 days ago).
  - Full date string (e.g. `"Oct 17, 2026"`) for older dates or dates 7+ days ago.
- `shouldShowDateDivider(DateTime? prevDate, DateTime? currentDate)`: Compares calendar days between consecutive chronological messages to determine if a divider chip should head a new day. Returns `false` if `currentDate` is null (no invented data).
- `DateDividerChip`: Centered pill chip with `ac.bgElev` fill, `ac.lineSoft` border, and `ac.fgMute` bold typography.

### Surface (a): DM Thread Screen (`ayma_flutter/lib/screens/dm_thread_screen.dart`)
1. **Per-Message Time Label:**
   - Placed with the bubble in `_Bubble._wrap` aligned to the bottom-right corner.
   - Text color: `ac.onAccent.withValues(alpha: 0.72)` on sent accent bubbles; `ac.fgMute` on received card bubbles.
   - Preserves long-press copy functionality (`CopyOnLongPress` continues to copy message text cleanly).
2. **Date Divider Chips:**
   - In `ListView.builder` (reverse order), consecutive messages are evaluated chronologically.
   - The first message of each day displays a `DateDividerChip` above it.

### Surface (b): Ayma Assistant Chat Screen (`ayma_flutter/lib/screens/chat_screen.dart`)
1. **Per-Message Time Label:**
   - User messages: Rendered in the bottom-right corner inside the accent bubble with muted on-accent ink.
   - Ayma assistant turns: Rendered below the response markdown text in a subtle row alongside the thumbs-down feedback icon with `ac.fgMute` ink.
2. **Date Divider Chips:**
   - Evaluated between turns in the transcript list; `DateDividerChip` renders above the first turn of each day.
   - Highlighted turns (`_highlightedTurn` target provenance jump) preserve their animation container.

---

## 3. How the Tester Can Verify

### Automated Verification
Run the Flutter test suite:
```bash
cd ayma_flutter
flutter analyze
flutter test test/message_timestamp_test.dart
flutter test test/dm_thread_screen_test.dart
flutter test test/chat_timestamps_test.dart
flutter test test/layout_matrix_test.dart
```

### Manual Verification Steps

#### DM Threads (`/dm/:threadId`):
1. Navigate to the **Messages** tab and open any direct message conversation.
2. **Time label check:** Confirm that each message bubble displays its send time in `h:mm AM/PM` format (e.g. `9:41 AM`) at the bottom right.
   - Sent messages (green/accent): time label is subtly muted on-accent text.
   - Received messages (grey): time label is muted secondary text.
3. **Date divider chip check:** Scroll through a thread with messages spanning multiple days.
   - Today's messages are headed by a `"Today"` pill chip.
   - Yesterday's messages are headed by `"Yesterday"`.
   - Messages within the past 7 days show their weekday (e.g. `"Thursday"`).
   - Messages older than 7 days show the full date (e.g. `"Oct 17, 2026"`).

#### Ayma Assistant Chat (`/chat` or Ayma Tab):
1. Open the **Ayma** tab or a chat modal with existing message history.
2. **Time label check:**
   - Confirm user bubbles show the time label at the bottom right.
   - Confirm Ayma responses show the time label beneath the markdown text.
3. **Date divider chip check:**
   - Confirm centered date chips appear between message turns on different calendar days.
