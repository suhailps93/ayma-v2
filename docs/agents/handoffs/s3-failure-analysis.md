# Sweep [S3] Failure Analysis & Fix Design (K3, N7/N8/N11, I5, E8)

- **Author**: Antigravity (Engineer)
- **Recipients**: Astro (PM), Scout (QA Lead), Claude (Lead Engineer)
- **Date**: 2026-11-02
- **Baseline**: Staging `c06ba66` (versionCode 2246 / 2245 suite)
- **Branch**: `antigravity/s3-failure-analysis` (worktree: `~/workspace/ayma/.fleet-worktrees/s3-analysis`)
- **Status**: ANALYSIS ONLY (Code-read + Trace + Fix Design; zero app code edits)

---

## Executive Summary

During Scout's QA sweep on staging (`3a1541d`/2245), six `[S3]` defects/observations were filed across four operational functional areas and queued for Claude's wrap-up filing batch:
1. **K3 (GIF leg only)**: Sending a GIF fails end-to-end (attachment sheet lacks a GIF path; keyboard rich-content insertion is misconfigured and drops bytes), and received `type: "gif"` messages render as inert, untappable `"📷 GIF"` text chips because the renderer requires a non-empty `attachment_url` which REST/fixture writes omit.
2. **N7 (Connect Google)**: Screen is completely absent from all user navigation; it is fully implemented and routed at `/settings/google`, but was deliberately deferred out of the visible UI for v1 per code comments and Android OAuth keystore constraints.
3. **N8 (Connect Instagram)**: Screen is completely absent from the UI; the entry point in `ProfileTabScreen` is strictly gated behind the `meta_integrations` feature flag, which defaults to `false` in Firestore `app_config/meta_integrations`.
4. **N11 (What's new / Release notes)**: The changelog screen is fully implemented and routed at `/whats-new`, but is buried inside the hidden `DeveloperScreen` behind 7 secret taps and a server-side developer password (`POST /dev/verify`), despite specs and docs stating it should be directly reachable from Settings.
5. **I5 (Practice Date history)**: No past-sessions list or debrief archive exists; every entry to Practice opens a brand-new session. This is an absent feature / missing specification (neither backend listing endpoints nor Flutter UI were ever specced or implemented for historical review).
6. **E8 (Voice preview)**: Voice selection works and saves, but no voice preview affordance exists in the client. The feature was dropped during the stack-picker rewrite (`VoiceEngineControl`), and while fully re-implemented in branch `feat/voice-preview-wiring` (`b00eb84`), that branch was never merged into `staging`.

All issues have been verified against the codebase. Below is the detailed trace, file:line evidence, root causes, Scout symptom reconciliations, and engineer-sized fix designs.

---

## 1. K3 Analysis — Direct Messaging GIF Leg Failure

### 1.1 Scout's Empirical Finding
> **K3 FAIL [S3] — scoped to the GIF leg** (`ayma-inbox/scout.md:191`):
> Text leg: long-proven (K2/K4). Photo leg PASSES on the real client path both directions: Daniel sent a photo from the client (+ sheet → picker → scaled_110.jpg staged → sent) and it renders as a full inline image in his thread; a correctly-typed received image (type "image" + attachment_url) renders inline full-size on the receiving side too (Sofia's seed_face.png at 5:37 AM).
> GIF leg FAILS end-to-end: the client's attachment sheet offers only Photo / Camera / File (no GIF send path), and a received type-"gif" message renders as an inert "📷 GIF" chip — tapping it (and the photo-type chip) does nothing; the GIF itself is never displayed.
> API footnote for the filing: the REST DM endpoint accepts type "photo" (validates body as an uploads/ path) and type "gif", but the client renderer only inlines type "image" — photo/gif-typed records land as dead chips for recipients; any backend flow emitting those types inherits this.

---

### 1.2 Code-Level Trace & Root Cause (File:Line Evidence)

The failure spans both the **sender creation path** and the **receiver rendering path**.

#### A. Sender Path 1: Attachment Sheet (`+`) Lacks a GIF Option
- File: [`ayma_flutter/lib/screens/dm_thread_screen.dart:512-555`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/dm_thread_screen.dart#L512-L555)
- Lines 514–536:
  ```dart
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: const Text('File'),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
        ],
      ),
    ),
  );
  ```
- **Consequences**:
  1. The attachment sheet exposes only `Photo`, `Camera`, and `File`.
  2. If the user picks **Photo** (`_pickImage(ImageSource.gallery)`), `_picker.pickImage(...)` runs with `imageQuality: 85` (recompressing to static JPEG, discarding animated GIF frames) and sets `_pendingType = 'image'`.
  3. If the user picks **File** (`_pickFile()`) and selects a `.gif` file from the disk, line 577 sets `_pendingType = 'file'`. When sent (lines 376–380), it is posted as `type: "file"`, which renders as an attachment card (`📎 File`), not an animated inline image.

#### B. Sender Path 2: Keyboard Rich-Content Insertion Defect
- File: [`ayma_flutter/lib/screens/dm_thread_screen.dart:973-976`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/dm_thread_screen.dart#L973-L976)
- The composer's `TextField` sets:
  ```dart
  contentInsertionConfiguration: ContentInsertionConfiguration(
    onContentInserted: _onContentInserted,
  ),
  ```
- **Root Cause**:
  1. `allowedMimeTypes` is omitted. In the Flutter framework, `ContentInsertionConfiguration` defaults `allowedMimeTypes` to `const <String>['image/png']`. Gboard/IME queries the input connection and is informed that the app accepts **only PNGs** (`image/png`), not `image/gif`.
  2. Even when Gboard attempts insertion, Android delivers media via `content://` URI (`KeyboardInsertedContent.uri`), leaving `KeyboardInsertedContent.data` (bytes) `null`.
  3. Lines 589–598 check:
     ```dart
     final Uint8List? bytes = content.data;
     if (bytes == null || bytes.isEmpty) {
       if (mounted) {
         AymaToast.show(
           context,
           "Couldn't read that — tap + to attach it instead.",
           kind: AymaToastKind.error,
         );
       }
       return;
     }
     ```
     Because `bytes == null`, the operation fails with a toast directing the user to `"tap + to attach it instead"`. But as shown in (A), the `+` menu has no GIF option.

#### C. Receiver Path: Inert "📷 GIF" Text Chip Fallback
- File: [`ayma_flutter/lib/services/dm_service.dart:64-67`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/dm_service.dart#L64-L67)
  ```dart
  bool get hasImage => type == 'image' && attachmentUrl.isNotEmpty;
  bool get hasGif => type == 'gif' && attachmentUrl.isNotEmpty;
  bool get hasFile => type == 'file' && attachmentUrl.isNotEmpty;
  ```
- File: [`ayma_flutter/lib/screens/dm_thread_screen.dart:1385-1424`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/dm_thread_screen.dart#L1385-L1424)
  ```dart
  } else if (message.hasImage || message.hasGif) {
    tight = true;
    content = _image(context, ac);
  } else if (message.hasFile) {
    tight = false;
    content = _file(context, ac);
  } else {
    tight = false;
    final label = switch (message.type) {
      'photo' || 'image' => '📷 Photo',
      'gif' => '📷 GIF',
      'voice' => '🎙 Voice message',
      'file' => '📎 File',
      'shared_profile' => '👤 Shared a profile',
      'shared_report' => '📄 Shared a report',
      _ => message.body,
    };
    content = Text(
      label,
      style: AymaType.message(color: _ink(ac)),
    );
  }
  ```
- **Root Cause & Code Reconciliation**:
  - Scout observed: *"the client renderer only inlines type 'image'"*.
  - **Code Truth**: The client renderer *does* include `message.hasGif` at line 1385. However, `hasGif` strictly requires `attachmentUrl.isNotEmpty` ([`dm_service.dart:65`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/dm_service.dart#L65)).
  - When test fixtures or API callers post messages using legacy or REST patterns (e.g. passing the storage path in `body` or `attachment_path` without an `attachment_url`):
    - `doc['attachment_url']` is empty.
    - `message.hasGif` evaluates to `false`.
    - The bubble falls through to line 1413: `'gif' => '📷 GIF'`.
    - It renders as an unstyled, un-tappable `Text('📷 GIF')` with no `GestureDetector`, displaying zero media.
  - Sibling bug on `type: "photo"`: In `functions/bootstrap/main.py:3608-3614`, the endpoint accepts `type: "photo"` with path in `body`. `DmMessage` has no `hasPhoto` getter, and `hasImage` explicitly checks `type == 'image'`. Thus, all `photo`-type messages fall into line 1412 (`'photo' || 'image' => '📷 Photo'`) and wedge as inert chips.

---

### 1.3 Classification & Sizing

- **Classification**: **Real Bug** (missing `allowedMimeTypes` and missing bytes-resolution in Flutter composer; missing GIF picker in `+` sheet; missing URL resolution/fallback for `gif` and `photo` types in message renderer).
- **Proposed Fix**:
  1. In [`dm_thread_screen.dart:974`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/dm_thread_screen.dart#L974), add `allowedMimeTypes: const ['image/gif', 'image/png', 'image/jpeg', 'image/webp']` to `ContentInsertionConfiguration`.
  2. In [`dm_thread_screen.dart:514-555`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/dm_thread_screen.dart#L514-L555), add a `"GIF"` action to `_openAttachSheet`, or if a `.gif` file is selected from the file picker, route its type to `_pendingType = 'gif'`.
  3. In [`dm_service.dart:64-67`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/dm_service.dart#L64-L67), allow `hasImage` and `hasGif` to resolve via `attachmentPath` or `body` if `attachmentUrl` is not yet populated, or treat `photo` interchangeably with `image`.
  4. Make the fallback chip in line 1420 tappable if a path/URL exists.
- **Sizing**: Small engineer chunk (~1.5 hours).
- **Batch Decision**: **Wrap-up batch** (self-contained client fix).

---

## 2. N7 / N8 / N11 Analysis — Missing Google, Instagram, and What's-New Sections

### 2.1 Scout's Empirical Finding
> **N7 FAIL [S3] + N8 FAIL [S3] + N11 FAIL [S3] (absent surfaces)** (`ayma-inbox/scout.md:197`):
> Full inventory taken — You tab (all rows) and complete Settings (Plan, Appearance, Match system, Matching, Notifications, Privacy/AI Avatar, Verification, Help, Delete account, "Version 1.30.0" footer) and Ayma's settings (Models, Connect an agent (MCP), Animation, Wipe). There is NO Google-account connect, NO Instagram connect, and NO release-notes/What's-new surface anywhere. (MCP agent connect exists but is a different feature.) All three join the wrap-up batch.

---

### 2.2 Code-Level Trace & Root Cause (File:Line Evidence)

#### A. N7: Connect Google Account
- **Code Path**:
  - Screen: [`ayma_flutter/lib/screens/google_account_screen.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/google_account_screen.dart) (`GoogleAccountScreen`, 199 lines, fully functional connect/disconnect/status UI).
  - Route: [`ayma_flutter/lib/routing/app_router.dart:337`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/routing/app_router.dart#L337) (`path: GoogleAccountScreen.path`, `/settings/google`).
  - Backend: `functions/bootstrap/google_account.py` (`/google/auth-url`, `/google/connect`, `/google/disconnect`, `/google/status`).
- **Where it Breaks / Root Cause**:
  - File: [`ayma_flutter/lib/screens/profile_tab_screen.dart:116-117`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/profile_tab_screen.dart#L116-L117)
    ```dart
    // Connect Google: built and working, deferred out of the visible UI
    // for v1. Connect Instagram: V2, shown only when the
    ```
  - The entry point was deliberately left out of `ProfileTabScreen`, `SettingsScreen`, and `AymaSettingsScreen`.
  - In addition, as Scout logged in `ayma-inbox/scout.md:72`:
    > *"Google leg on the watchers build: flow launched GMS and reached Google's credential screen again — but that is only the pre-account launch stage; per the Android OAuth client gap (no client_type 1 for staging under the shared debug SHA-1; completion fails GoogleSignatureVerifier) the leg is HELD until the dedicated-staging-keystore build lands."*
- **Classification**: **Missing Feature / Intentional UI Deferral for v1**. Not a bug.
- **Sizing & Batch Decision**:
  - Sizing: ~15 minutes to add the list tile into `profile_tab_screen.dart`.
  - Batch Decision: **Separate feature/release decision**. Staging keystore OAuth credentials must be aligned before exposing to users; should NOT be quietly un-deferred in a bugfix wrap-up batch without founder approval.

#### B. N8: Connect Instagram Account
- **Code Path**:
  - Screen: [`ayma_flutter/lib/screens/instagram_screen.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/instagram_screen.dart) (`InstagramScreen`, 183 lines, OAuth launch, auth code exchange, photo import).
  - Route: [`ayma_flutter/lib/routing/app_router.dart:347`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/routing/app_router.dart#L347) (`path: InstagramScreen.path`, `/settings/instagram`).
  - Backend: `functions/bootstrap/instagram.py` (`/instagram/auth-url`, `/instagram/connect`, etc.).
- **Where it Breaks / Root Cause**:
  - File: [`ayma_flutter/lib/screens/profile_tab_screen.dart:119-125`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/profile_tab_screen.dart#L119-L125)
    ```dart
    if (MetaIntegrations.enabled.value)
      _Item(
        icon: Icons.camera_alt_outlined,
        label: 'Connect Instagram',
        hint: 'Import photos from your Instagram account',
        onTap: () => context.push(InstagramScreen.path),
      ),
    ```
  - File: [`ayma_flutter/lib/services/meta_integrations.dart:14-26`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/meta_integrations.dart#L14-L26)
    `MetaIntegrations.enabled` defaults to `false`. It listens to Firestore doc `app_config/meta_integrations`. Per doc comment: *"Instagram / Facebook connect, sign-in and photo import are deferred to V2: while this is off every entry point is hidden."*
- **Classification**: **Feature Flag Gated** (`meta_integrations` remote flag is off).
- **Sizing & Batch Decision**:
  - Sizing: Zero code changes. Toggled via `scripts/flags.py`.
  - Batch Decision: **Separate feature/release decision** (depends on Meta app production review status and secrets).

#### C. N11: What's New / Release Notes
- **Code Path**:
  - Screen: [`ayma_flutter/lib/screens/release_notes_screen.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/release_notes_screen.dart) (`ReleaseNotesScreen`, renders `kReleaseNotes`).
  - Route: [`ayma_flutter/lib/routing/app_router.dart:285`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/routing/app_router.dart) (`path: ReleaseNotesScreen.path`, `/whats-new`).
  - Content: [`ayma_flutter/lib/release_notes.dart:1-235`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/release_notes.dart#L1-L235).
- **Where it Breaks / Root Cause**:
  - Contradiction in documentation vs implementation:
    1. Line 232 of `release_notes.dart` asserts:
       *"- This 'What's new' screen — reach it by tapping the build tag at the bottom of Settings."*
    2. Registry [`functions/bootstrap/app_registry.json:33`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/functions/bootstrap/app_registry.json#L33) registers:
       `{"key": "release_notes", "path": "/whats-new", "label": "What's new", "found_on": "settings"}`.
    3. BUT in [`ayma_flutter/lib/screens/settings_screen.dart:406-424`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/settings_screen.dart#L406-L424):
       Tapping the `build-stamp` ("Version 1.30.0") does NOT navigate to `/whats-new`. Instead, it counts towards 7 taps (`_onBuildTap`) to unlock `DeveloperScreen`. Single tap is a no-op!
    4. AND inside [`ayma_flutter/lib/screens/developer_screen.dart:426-437`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/screens/developer_screen.dart#L426-L437):
       "What's new" is placed inside the **Developer Panel**, which requires `devModeEnabled` (`kDebugMode`) AND passing a developer password (`POST /dev/verify`).
    5. Test [`ayma_flutter/test/settings_screen_test.dart:173`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/test/settings_screen_test.dart#L173) explicitly enforces that "What's new" does NOT appear on `SettingsScreen`:
       `expect(find.text("What's new"), findsNothing);`
- **Classification**: **UI Placement Defect / Spec Misalignment**. The user-facing changelog was inadvertently buried inside a password-locked developer tool.
- **Proposed Fix**:
  - Add a dedicated "What's new" `ListTile` under Settings (e.g. above Help or below Delete account), or make a single tap on the version row navigate to `ReleaseNotesScreen.path`.
  - Update `test/settings_screen_test.dart`.
- **Sizing**: ~30 minutes.
- **Batch Decision**: **Wrap-up batch** (restores documented spec behavior).

---

## 3. I5 Analysis — Absence of Practice Date History

### 3.1 Scout's Empirical Finding
> **I5 FAIL [S3] (practice history absent)** (`ayma-inbox/scout.md:198`):
> Practice with Sofia opens a FRESH session ("Say hi to Sofia Marino to break the ice"); its overflow menu holds only "Restart simulation". No past-sessions list or debrief archive exists in Practice, You, Settings, or Messages — the Nov 1 API-run practice sessions (Maya/Leo/Aisha, with debriefs) are unreachable in-app.
>
> **Prior Scout observation** (`ayma-inbox/scout.md:75`):
> *"I5 OBSERVATION (not filed as FAIL, H5 treatment): no practice-history surface exists in this build — no endpoint or UI in the client (practice menu = Restart only; re-entry starts fresh); docs/PRACTICE_DATE.md names no history feature, so no spec backs the pack expectation. PM/founder call if history is wanted."*

---

### 3.2 Code-Level Trace & Root Cause (File:Line Evidence)

1. **Specification Trace**:
   - File: [`docs/PRACTICE_DATE.md:251-265`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/docs/PRACTICE_DATE.md#L251-L265)
   - The spec outlines four endpoints:
     - `POST /practice/start {other_uid}`
     - `POST /practice/chat {session_id, message}`
     - `POST /practice/voice/start {other_uid}`
     - `POST /practice/debrief {session_id}`
   - At line 264: *"Sessions live at `users/{uid}/practice_sessions/{session_id}` (Firestore only)."*
   - There is **no listing endpoint**, **no query contract**, and **no history review UI** defined anywhere in `PRACTICE_DATE.md`.
2. **Backend API Trace**:
   - File: [`functions/bootstrap/practice_date.py:133-248`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/functions/bootstrap/practice_date.py#L133-L248)
   - Router exports only `POST /start`, `POST /chat`, `POST /debrief`, and `POST /voice/start`. Zero `GET` endpoints exist on the router.
3. **Flutter Client Trace**:
   - File: [`ayma_flutter/lib/features/practice_date/practice_screen.dart:60-95`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/features/practice_date/practice_screen.dart#L60-L95)
   - `initState()` unconditionally calls `_begin()` -> `_api.practiceStart(widget.uid)`.
   - Lines 251–262: The overflow menu has exactly one entry: `PopupMenuItem(value: 'restart', child: Text('Restart simulation'))`.
   - File: [`ayma_flutter/lib/features/practice_date/practice_debrief_screen.dart:42-56`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/features/practice_date/practice_debrief_screen.dart#L42-L56)
   - `PracticeDebriefScreen` operates exclusively on a single `widget.sessionId` passed during navigation from an active session. Once popped, it cannot be reopened from anywhere in the app.

---

### 3.3 Classification & Sizing

- **Classification**: **Absent Feature / Missing Specification** (Scout's line 75 assessment is 100% verified by the codebase). The simulator was designed as an ephemeral rehearsal sandbox, not an archival transcript feed.
- **Proposed Fix (if desired)**:
  1. Add backend `GET /practice/sessions` in `functions/bootstrap/practice_date.py` (querying `users/{uid}/practice_sessions` ordered by `created_at desc`, limit 20).
  2. Add `ApiClient.practiceSessions()`.
  3. Create `PracticeHistoryScreen` in Flutter (or an archive sheet) listing sessions, targets, and debrief status.
  4. Add route `/practice/history` and layout matrix test entries.
- **Sizing**: Medium engineering chunk (~4–6 hours).
- **Batch Decision**: **Separate Feature Decision for Founder/PM**. Does NOT belong in Scout's quick wrap-up bugfix batch.

---

## 4. E8 Analysis — Voice Change Works, but No Preview

### 4.1 Scout's Empirical Finding
> **E8 FAIL [S3] (preview leg only)** (`ayma-inbox/scout.md:199`):
> Voice change WORKS — Ayma's models -> VOICE Aoede -> Kore, "Save voice", persisted across exit/re-entry (verified by content-desc on re-open; also restores Daniel's fixture voice to Kore). But there is NO voice preview anywhere in the client: the picker is a plain text list with no play affordance, even though the backend serves previews (GET /voice/preview/Kore -> 200 {"url": .../voice_previews/Kore.wav}; GET /voice/presets -> 200, 8 voices). Same gap as Run #2's 2242 note, still open.
> Observation: Daniel's voice was found on Aoede, not the Kore I restored Nov 1 — the Models screen may read a different default; current saved state is now Kore again.

---

### 4.2 Code-Level Trace & Root Cause (File:Line Evidence)

#### A. Active Codebase on Staging (`c06ba66`)
1. **The Missing Preview Control in VoiceEngineControl**:
   - File: [`ayma_flutter/lib/widgets/voice_engine_control.dart:322-350`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/widgets/voice_engine_control.dart#L322-L350)
   - Lines 329–349 render `VOICE` as a plain `_dropdown<String>` (`DropdownButtonFormField`).
   - There is **no play button**, **no speaker icon**, **no audio player**, and **no preview state**.
2. **Dead Support Classes**:
   - File: [`ayma_flutter/lib/services/voice_preview_player.dart`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/voice_preview_player.dart): `VoicePreviewPlayer` and `JustAudioPreviewPlayer` exist in the repository, but are imported by **zero** production widgets on staging.
   - File: [`ayma_flutter/lib/services/api_client.dart:1950-1960`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/services/api_client.dart#L1950-L1960): `voicePreviewUrl(voiceName)` is implemented, but has **zero** callers.
3. **Backend Preview Endpoint is Live**:
   - File: [`functions/bootstrap/main.py:5324`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/functions/bootstrap/main.py#L5324) exposes `GET /voice/preview/{voice_name}`. It synthesizes and serves cached preview WAVs from Google Cloud Storage.

#### B. The Unmerged Branch (`origin/feat/voice-preview-wiring`)
- A git search reveals that this exact defect was already solved in branch [`origin/feat/voice-preview-wiring`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis) under commit `b00eb8434be342664fcb8ccbdcd76f2301b6e3a3` (Oct 31):
  ```text
  commit b00eb8434be342664fcb8ccbdcd76f2301b6e3a3
  Author: suhailps <suhailps@gmail.com>
  Date:   Sat Oct 31 23:34:10 2026 -0700

      feat(voice): hear-before-save voice preview in the "Ayma's models" stack picker
      
      Re-wire the dropped voice-preview control into the stack picker and make the
      backend serve the CURRENT catalog, not just the old Gemini presets.
      
      Client (voice_engine_control.dart): a speaker button beside the VOICE dropdown
      plays a short sample of the selected voice via the existing VoicePreviewPlayer
      + api.voicePreviewUrl(); spinner while resolving, inline "couldn't load a
      sample" note on failure, stop/replace on re-tap or any selection change...
  ```
- **Root Cause**: `feat/voice-preview-wiring` was **never merged into `staging` or `main`**. Staging `c06ba66` is missing commit `b00eb84`.

#### C. Reconciliation with Erroneous Handoff Note in `chore/voice-preview-verify`
- Commit `d9b1373` (`docs/agents/handoffs/voice-preview-verification.md`) claimed:
  *"Verdict: EXISTS ... The code contradicts the report on the voice picker itself."*
- **Investigation**: That previous verification note was mistaken. It based its verdict on an obsolete version of `VoicePreferenceScreen` that existed prior to commit `fbefbfe` (which replaced the legacy list with `VoiceEngineControl`). On the actual staging APK 2245 / `c06ba66`, `VoiceEngineControl` lacks preview controls. Scout's observation is 100% correct.

#### D. Explanation of Scout's Observation (Daniel Defaulting to Aoede)
- File: [`functions/bootstrap/voice_catalog.py:654-656`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/functions/bootstrap/voice_catalog.py#L654-L656) returns `"voice_id": ""` when returning catalog defaults for realtime Gemini.
- File: [`ayma_flutter/lib/widgets/voice_engine_control.dart:142-147`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/s3-analysis/ayma_flutter/lib/widgets/voice_engine_control.dart#L142-L147):
  ```dart
  void _reconcileVoice() {
    final voices = _activeVoices();
    if (!voices.any((v) => v.id == _sel!.voiceId)) {
      _sel = _sel!.copyWith(voiceId: voices.isNotEmpty ? voices.first.id : '');
    }
  }
  ```
- When a user has no stored preference or opens the screen before `voice_engines` finishes hydrating, `voiceId` is empty. `_reconcileVoice()` immediately picks `voices.first.id`, which is `"Aoede"` (the first Gemini preset alphabetically). When Scout reopened after saving Kore, the server returned Kore, which was preserved.

---

### 4.3 Classification & Sizing

- **Classification**: **Real Bug / Unmerged Branch Regression**.
- **Proposed Fix**:
  - Merge or cherry-pick `feat/voice-preview-wiring` (commit `b00eb84`) into `staging`.
  - Re-run `flutter test test/voice_engine_control_test.dart` and `test/layout_matrix_test.dart`.
- **Sizing**: Very small (~20 minutes, code already written and tested).
- **Batch Decision**: **Wrap-up batch** (ready to land).

---

## 5. Triage Summary & Recommendations

| Failure | Category | Root Cause | Proposed Fix | Scope / Batch | Sizing |
|---|---|---|---|---|---|
| **K3 (GIF Leg)** | Bug | Missing `allowedMimeTypes` in composer; missing GIF in `+` sheet; inert chip on empty `attachment_url` | Add MIME types to composer; add GIF attach path; handle path-in-body fallback | **Wrap-up batch** | 1.5 hrs |
| **N7 (Connect Google)** | Missing Feature | Intentionally deferred out of v1 UI (`profile_tab_screen.dart:116`); staging OAuth keystore pending | Un-defer `_Item` in `profile_tab_screen.dart` when keystore is verified | **Founder Decision** (Separate) | 15 mins (code) |
| **N8 (Connect Instagram)** | Feature Flag | Gated behind `MetaIntegrations.enabled` (default `false`) | Enable `app_config/meta_integrations` via `scripts/flags.py` | **Founder Decision** (Config only) | 5 mins |
| **N11 (What's New)** | UI Placement Bug | What's new was placed in secret `DeveloperScreen` behind password rather than in `SettingsScreen` | Add "What's new" `ListTile` to `SettingsScreen` (or 1-tap on version string) | **Wrap-up batch** | 30 mins |
| **I5 (Practice History)** | Absent Spec | Rehearsal simulator was specced as ephemeral; no history endpoint or UI was ever created | Full feature: `GET /practice/sessions` + `PracticeHistoryScreen` | **Separate Feature** | 4–6 hrs |
| **E8 (Voice Preview)** | Unmerged Branch | `feat/voice-preview-wiring` (`b00eb84`) built the speaker preview button but was never merged to `staging` | Cherry-pick / merge `b00eb84` into `staging` | **Wrap-up batch** | 20 mins |

### Wrap-Up Batch Action Items for Claude
1. **E8**: Merge `origin/feat/voice-preview-wiring` (`b00eb84`) into staging.
2. **K3**: Fix `dm_thread_screen.dart` composer `ContentInsertionConfiguration.allowedMimeTypes`, add GIF attach option, and fall back to inline render on path-bearing records.
3. **N11**: Expose "What's new" in `SettingsScreen` as a first-class user row.
4. **Hold N7, N8, and I5**: Escalate to Astro/Founder for product and credential clearance (N7 needs staging keystore OAuth SHA-1 verification; N8 needs Meta app production approval; I5 needs feature specification).
