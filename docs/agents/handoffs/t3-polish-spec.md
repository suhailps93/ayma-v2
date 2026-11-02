# T3 Polish Batch Implementation Spec
## UI Polish, Edge-Case Resilience, and Deep-Link Routing

- **Author**: Antigravity (Engineer)
- **Target Reader**: Claude (Lead Engineer for T3 Polish Build)
- **Reviewers**: Astro (PM), Scout (QA Lead)
- **Date**: 2026-11-02
- **Baseline**: `origin/staging` @ `e6d3cdc` (fast-forwarded from `9769a16`; incorporating `d939b17` LiveKit invariant, `55f8782` B9-PUSH fix, `696ac04` R2-C8a appearance photo filtering, `94ed9ec` honest voice error states, `0b3fe8c` B9 recovery, and `e6d3cdc` LiveKit routing pins)
- **Worktree**: `~/workspace/ayma/.fleet-worktrees/t3-polish-spec` (branch: `antigravity/t3-polish-spec`)
- **Status**: IMPLEMENTATION-READY SPECIFICATION (Analysis & Spec writing only; zero app code edits in this worktree)

---

## 1. Executive Summary & Verification Summary

The Tier 3 (T3) polish batch addresses 8 long-standing polish, presentation, and deep-link routing defects identified in Scout's staging sweeps (`3a1541d`/2245 through `c06ba66`/2246) and Run #2 carry-overs:
1. **P1 [S3]**: Bottom tab bar overflow on small / high-density screens (`wm size 720x1280`).
2. **P5 [S3]**: Incomplete version string in Settings footer (missing build number and staging environment tag).
3. **obs-2 [S3]**: False error toast surfaced when cancelling Google Sign-In (`Google sign-in failed (unknownError)`).
4. **R2-C8b [S3]**: Agent Date simulation conversation bubbles render unparsed raw markdown asterisks and formatting characters.
5. **R2-D6 [S3]**: Message thumbs-down feedback state is ephemeral and fails to persist across app relaunches or tab switches.
6. **R2-C1 [S3]**: Profile completion screen displays inert "dead" section tiles under progressive disclosure without explanatory feedback.
7. **G2 [S3]**: Cross-surface compatibility score staleness between chat announcements, Explore cards, and the regenerated Match report.
8. **G4 [S2]**: Shared report deep links (`https://justabot.info/s/<token>`) fall through to the marketing homepage due to missing Firebase Hosting rewrites.

### Sweep Verification Summary Matrix

Every item was inspected against the current staging tip (`9769a16`). All 8 items are **CONFIRMED** as reported with concrete code and architectural evidence.

| Item ID | Area | Sweep Report | Code Baseline Status (@ `9769a16`) | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| **P1** | Flutter Navigation UI | `wm size 720x1280` overflows by 5.7 px over You tab | `ayma_tab_bar.dart:294`: 5 fixed tabs require 280.0 px; 720 px at 420 dpi yields 274.29 px width (`280.0 - 274.29 = 5.71 px`) | **CONFIRMED** |
| **P5** | Flutter Settings UI | Settings footer reads "Version 1.30.0" without build number or staging tag | `settings_screen.dart:104`: loads `info.version` only; discards `info.buildNumber` and has no staging indicator | **CONFIRMED** |
| **obs-2** | Flutter Auth UX | Cancelling Google sign-in sheet surfaces error toast `Google sign-in failed (unknownError)` | `sign_in_screen.dart:237`: only checks `e.code != canceled`; Android Credential Manager maps cancellation to `unknownError` ("No credential available") | **CONFIRMED** |
| **R2-C8b** | Flutter Date Sim UI | Agent Date bubbles display raw markdown asterisks | `date_sim_screen.dart:537`: renders `Text(m.text)` rather than `MarkdownText(m.text)` | **CONFIRMED** |
| **R2-D6** | Flutter / Backend Chat | Thumbs-down feedback icon resets to grey outline after force-stop/relaunch | `chat_screen.dart:2866`: `_flagged` is ephemeral local state in `_TranscriptLineState`; not persisted in `TranscriptTurn` or `chat_history.py` | **CONFIRMED** |
| **R2-C1** | Flutter / Backend Profile | 8 of 9 completion section chips dead at 12% | `completeness.py:634`: progressive disclosure locks all non-promoted sections; `complete_profile_screen.dart:521`: `_LockedSectionTile` has no `onTap` or feedback | **CONFIRMED** |
| **G2** | Backend / Flutter Reports | Surfaces disagree on match score (Chat/Explore 25% vs Report 17%) | `main.py:6124`: chat event writes static immutable text; silent background recalculation updates `matches/{id}` without updating chat card or report timestamp | **CONFIRMED** |
| **G4** | Hosting / Cloud Run | Public share link `https://justabot.info/s/<token>` serves homepage | `firebase.json:16`: hosting rewrites include `/r/**` but omit `/s/**` and `/.well-known/**`, falling back to `public/index.html` | **CONFIRMED** |

---

## 2. Detailed Item Analyses & Specifications

### 2.1 Item P1: Tab-Bar Overflow

#### A. Scout Sweep Report
- **Item**: `BUG SWEEP-P1 [S3]`
- **Reported in**: Build `1.30.0 (2243)` @ `bdf223a`
- **Symptom**: On device configured with `wm size 720x1280`, the bottom tab bar overflows horizontally: Flutter banner `"RIGHT OVERFLOWED BY 5.7 PIXELS"` across the You tab. Normal at `1080x2400`.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Location**: `ayma_flutter/lib/widgets/ayma_tab_bar.dart` lines 195–221, 246–252, and 294–320.
- **Mathematical & Structural Proof**:
  1. `AymaTabBar` renders a `Row(mainAxisAlignment: MainAxisAlignment.spaceAround)` containing 5 fixed-width tab widgets:
     - Tab 1 (Explore): `boxSize` 24.0 + `horizontal` padding 12.0 * 2 = 48.0 px.
     - Tab 2 (Messages): `boxSize` 24.0 + `horizontal` padding 12.0 * 2 = 48.0 px.
     - Tab 0 (Ayma Orb): `orbBox` 64.0 + `horizontal` padding 12.0 * 2 = 88.0 px.
     - Sentinel (Notification Bell): `boxSize` 24.0 + `horizontal` padding 12.0 * 2 = 48.0 px.
     - Tab 3 (Profile / You): `boxSize` 24.0 + `horizontal` padding 12.0 * 2 = 48.0 px.
  2. Sum of minimum intrinsic child widths:
     $$\text{Total Width} = 48.0 + 48.0 + 88.0 + 48.0 + 48.0 = 280.0\text{ logical pixels}$$
  3. Physical density of `emulator-5554` is 420 dpi (`Physical density: 420`), giving a device pixel ratio of:
     $$\text{DPR} = \frac{420}{160} = 2.625$$
  4. At `wm size 720x1280`, available screen width in logical pixels is:
     $$\text{Width}_{\text{logical}} = \frac{720}{2.625} \approx 274.2857\text{ px}$$
  5. The unyielding Row exceeds available space by:
     $$\text{Overflow} = 280.0 - 274.2857 = 5.7143\text{ px}$$
     This reproduces Flutter's exact message: `"RIGHT OVERFLOWED BY 5.7 PIXELS"`.

#### C. Root Cause
`AymaTabBar` lays out 5 children inside an unconstrained `Row` where every child has hardcoded horizontal padding (`EdgeInsets.symmetric(horizontal: 12)`). When the available viewport is narrower than 280 logical pixels, the fixed children cannot flex down, causing an immediate RenderFlex overflow exception.

#### D. File-Level Change List
- **File**: `ayma_flutter/lib/widgets/ayma_tab_bar.dart`
- **Function/Class**: `AymaTabBar.build` and `_AymaTab`
- **Changes**:
  1. Measure available width via `LayoutBuilder` (or calculate responsive horizontal padding based on `MediaQuery.sizeOf(context).width`).
  2. When available width $< 320$ logical pixels (e.g., $W \le 300$), adapt horizontal padding on the 4 icon tabs from `12.0` down to `6.0` (saving $4 \times 12 = 48\text{ px}$), and on the orb tab from `12.0` to `8.0` (saving $8\text{ px}$). Total width reduces from $280\text{ px}$ to $224\text{ px}$, safely below $274.28\text{ px}$ with $>50\text{ px}$ of headroom.
  3. Alternatively, wrap each tab in `Flexible(flex: i == 0 ? 2 : 1, child: Center(child: ...))` so the row absorbs constraint changes dynamically without fixed overflow barriers.

#### E. Risks & Interactions
- **Layout Matrix Invariant**: `ayma_flutter/test/layout_matrix_test.dart` and `support/layout_matrix.dart` test windows down to 320px width (`LayoutCase(320, 568)`). The fix ensures 270px–300px narrow windows also remain 100% overflow-free.
- **Coach-Mark Tour Anchors**: Ensure `anchorKeys` placed on tabs via `KeyedSubtree` remain correctly mounted and aligned so `TourAnchors` spotlight coordinates are unaffected.

#### F. Test Notes for Claude & Scout
- **Setup**: Android emulator (`emulator-5554`) or physical device.
- **Steps**:
  1. Run `adb shell wm size 720x1280`.
  2. Launch Ayma and navigate through Explore, Messages, Ayma chat, and You tabs.
  3. Reset display size using `adb shell wm size reset`.
- **Pass Condition**: Tab bar renders cleanly across all tabs at `720x1280` without any yellow/black stripes, RenderFlex assertions, or visual truncation of the You tab.

---

### 2.2 Item P5: Version String

#### A. Scout Sweep Report
- **Item**: `BUG SWEEP-P5 [S3]`
- **Reported in**: Build `1.30.0 (2243)` @ `bdf223a`
- **Symptom**: Settings footer displays `"Version 1.30.0"` only: missing build number (e.g. `+2243`) and missing environment tag (e.g. ` · staging`). The running build code is discoverable only via `adb shell dumpsys`.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Location**: `ayma_flutter/lib/screens/settings_screen.dart` lines 101–109 and line 418.
- **Evidence**:
  ```dart
  // settings_screen.dart:101-105
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  // settings_screen.dart:418
  _version.isEmpty ? 'Version' : 'Version $_version',
  ```
  `PackageInfo.fromPlatform()` populates `info.version` (`1.30.0`) and `info.buildNumber` (`2249`). Line 104 discards `info.buildNumber` and has no logic to detect staging builds (`scripts/build-apk.sh --staging` passes `--dart-define=AYMA_API_BASE_URL=https://ayma-api-staging-...` and `SENTRY_ENVIRONMENT=staging`).

#### C. Root Cause
`SettingsScreen._loadVersion()` assigned only `info.version` to `_version`. It omitted string interpolation of `info.buildNumber` and environment inspection.

#### D. File-Level Change List
- **File**: `ayma_flutter/lib/screens/settings_screen.dart`
- **Function/Class**: `_SettingsScreenState._loadVersion`
- **Changes**:
  1. Read both `info.version` and `info.buildNumber`.
  2. Inspect environment: check `Env.apiBaseUrl.contains('staging')` or `const String.fromEnvironment('SENTRY_ENVIRONMENT') == 'staging'`.
  3. Format `_version` string as:
     ```dart
     final buildSuffix = info.buildNumber.isNotEmpty ? '+${info.buildNumber}' : '';
     final isStaging = Env.apiBaseUrl.contains('staging') ||
         const String.fromEnvironment('SENTRY_ENVIRONMENT') == 'staging';
     final envSuffix = isStaging ? ' · staging' : '';
     setState(() => _version = '${info.version}$buildSuffix$envSuffix');
     ```

#### E. Risks & Interactions
- **Developer Screen Unlock Gesture**: `_onBuildTap` on line 412 triggers developer screen unlock after 7 taps on `ValueKey('build-stamp')`. The gesture detector wraps the `Text` widget; changing the string length does not impact hit testing or tap counting.

#### F. Test Notes for Claude & Scout
- **Setup**: Build app with `--staging` flag using `scripts/build-apk.sh --debug --staging`.
- **Steps**:
  1. Open app and navigate to `You` tab $\to$ `Settings` (gear icon).
  2. Scroll to the bottom footer.
- **Pass Condition**: Footer reads `"Version 1.30.0+<build_number> · staging"` on staging builds, and `"Version 1.30.0+<build_number>"` on production builds.

---

### 2.3 Item obs-2: Google-Cancel False Toast

#### A. Scout Sweep Report
- **Item**: `S3 OBSERVATIONS #2` (obs-2)
- **Reported in**: Staging sweep B4 pass (`c9b0b39`)
- **Symptom**: Backing out or cancelling the Google sign-in sheet produces an aggressive error toast: `"ERROR — Google sign-in failed (unknownError)"`. A user cancellation should be completely silent.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Location**: `ayma_flutter/lib/screens/sign_in_screen.dart` lines 236–240.
- **Evidence**:
  ```dart
  // sign_in_screen.dart:236-240
  } on GoogleSignInException catch (e) {
    if (e.code != GoogleSignInExceptionCode.canceled) {
      _snack('Google sign-in failed (${e.code.name}).',
          kind: AymaToastKind.error);
    }
  }
  ```
  In `google_sign_in: ^7.2.0` (using `google_sign_in_android: 7.x` Credential Manager integration), when a user dismisses the Google account sheet or cancels out without selecting credentials, Android's Credential Manager returns `GetCredentialFailureType.noCredential`. The platform interface in `google_sign_in_android.dart` line 155 explicitly handles this as:
  ```dart
  case GetCredentialFailureType.noCredential:
    if (throwForNoAuth) {
      code = GoogleSignInExceptionCode.unknownError;
      message = 'No credential available: $message';
    }
  ```
  Because `e.code` is `GoogleSignInExceptionCode.unknownError` (rather than `canceled`), `sign_in_screen.dart` line 237 evaluates to `true` and pops the error toast.

#### C. Root Cause
The exception handler in `sign_in_screen.dart` assumes Android's Credential Manager exclusively uses `GoogleSignInExceptionCode.canceled` for user dismissals, failing to account for `unknownError` when the description indicates `noCredential` or user cancellation.

#### D. File-Level Change List
- **File**: `ayma_flutter/lib/screens/sign_in_screen.dart`
- **Function/Class**: `_SignInScreenState._run`
- **Changes**:
  1. Update `on GoogleSignInException catch (e)` to check both `e.code` and `e.description`:
     ```dart
     } on GoogleSignInException catch (e) {
       final isCancel = e.code == GoogleSignInExceptionCode.canceled ||
           (e.code == GoogleSignInExceptionCode.unknownError &&
               (e.description?.contains('No credential available') ?? false)) ||
           (e.description?.toLowerCase().contains('cancel') ?? false);
       if (!isCancel) {
         _snack('Google sign-in failed (${e.code.name}).',
             kind: AymaToastKind.error);
       }
     }
     ```

#### E. Risks & Interactions
- **Real Sign-In Failures**: Genuine authentication failures (e.g. invalid server client ID, network failure, or misconfigured SHA-1) produce `clientConfigurationError`, `providerConfigurationError`, or `interrupted`, which remain unaffected and continue displaying explicit error messages.

#### F. Test Notes for Claude & Scout
- **Setup**: Staging build on `emulator-5554` or test device.
- **Steps**:
  1. Open the sign-in screen.
  2. Tap "Continue with Google".
  3. When Google Play Services presents the account chooser / sign-in prompt, tap outside the sheet, press the back button, or tap "Skip".
- **Pass Condition**: The sheet dismisses cleanly back to the Welcome/Sign-in screen. No toast or snackbar is shown.

---

### 2.4 Item R2-C8b: Raw-Markdown Sim Transcripts

#### A. Scout Sweep Report
- **Item**: `BUG R2-C8b [S3]` (Run #2 carry-over)
- **Reported in**: Build `1.30.0 (2242)` and re-observed in H5 sims on `3a1541d`
- **Symptom**: Simulated date (Agent Date) conversation bubbles render raw markdown syntax (literal asterisks `*`, `**`, and formatting characters) instead of styled text.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Location**: `ayma_flutter/lib/features/date_sim/date_sim_screen.dart` lines 532–541.
- **Evidence**:
  ```dart
  // date_sim_screen.dart:532-541
  for (final m in _messages)
    ChatBubble(
      mine: m.fromYou,
      copyText: m.text,
      flagged: sim?.moderationFlagged ?? false,
      child: Text(
        m.text,
        style: AymaType.message(color: m.fromYou ? ac.onAccent : ac.fg),
      ),
    ),
  ```
  `ChatScreen` (`chat_screen.dart:3116`) correctly uses `MarkdownText(displayText, style: AymaType.message(...))` to parse italics, bolding, and links. In contrast, `date_sim_screen.dart` uses Flutter's primitive `Text(m.text)`, rendering all LLM-generated markdown characters literally.

#### C. Root Cause
`date_sim_screen.dart` instantiated `Text` instead of `MarkdownText` inside `ChatBubble.child`.

#### D. File-Level Change List
- **File**: `ayma_flutter/lib/features/date_sim/date_sim_screen.dart`
- **Function/Class**: `_DateSimScreenState._live`
- **Changes**:
  1. Import `../../widgets/markdown_text.dart`.
  2. Replace `Text(m.text, ...)` in the transcript `ListView` with:
     ```dart
     MarkdownText(
       m.text,
       style: AymaType.message(color: m.fromYou ? ac.onAccent : ac.fg),
       linkColor: m.fromYou ? ac.onAccent : ac.accent,
     )
     ```

#### E. Risks & Interactions
- **ChatBubble Layout**: `MarkdownText` wraps text in `RichText` with standard paragraph wrapping. It preserves constraint propagation inside `ChatBubble` without triggering RenderFlex overflows.

#### F. Test Notes for Claude & Scout
- **Setup**: Open Explore, tap any user profile (e.g. Sofia Marino), tap the sparkle icon ✨ to run or reopen an Agent Date sim.
- **Steps**:
  1. Observe the simulation transcript messages containing asterisks or markdown styling (e.g., `*smiles*` or `**really?**`).
- **Pass Condition**: Asterisks and formatting characters render as italicized / bolded styled text; zero literal asterisks visible in the conversation bubbles.

---

### 2.5 Item R2-D6: Feedback State Not Persisted

#### A. Scout Sweep Report
- **Item**: `BUG R2-D6 [S3]` (Run #2 carry-over)
- **Reported in**: Build `1.30.0 (2242)`
- **Symptom**: Tapping thumbs-down on an Ayma reply highlights the icon in solid pink and displays `"noted"`. However, after force-stopping and relaunching the app (or switching tabs), the same message reverts to the plain grey outline icon with no label; feedback state is not persisted or restored.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Locations**:
  1. Frontend: `ayma_flutter/lib/screens/chat_screen.dart` lines 2866, 2872–2880, and 3173–3203.
  2. Frontend Model: `ayma_flutter/lib/services/transcript_store.dart` lines 12–35 (`TranscriptTurn`).
  3. Backend: `functions/bootstrap/main.py` lines 4941–4950 (`submit_feedback`), `functions/bootstrap/feedback_ops.py` lines 111–169 (`record`), and `functions/bootstrap/chat_history.py` (`recent`).
- **Evidence**:
  1. In `chat_screen.dart:2866`, `bool _flagged = false;` is declared inside `_TranscriptLineState`. It is purely ephemeral state on the Flutter widget state object.
  2. `TranscriptTurn` has no `flagged` or `feedback` property.
  3. `POST /feedback` (`feedback_ops.py`) creates a separate document in the root `feedback/{id}` collection and appends a rule to `steering_ops`, but **never records feedback on the chat turn document** in `chat_messages` or `raw_turns`.
  4. `GET /chat/history` returns turns without any feedback metadata. When `_loadHistory()` executes on cold launch or tab switch, all turns re-instantiate with `_flagged = false`.

#### C. Root Cause
Feedback registration is treated as an external telemetry event rather than an update to the chat turn entity. The client lacks persistence for message-level feedback, and the backend chat history serializer does not project feedback status.

#### D. File-Level Change List
- **File 1**: `ayma_flutter/lib/services/transcript_store.dart`
  - Add `final bool flagged;` to `TranscriptTurn` constructor (default `false`).
  - Add `flagged` serialization/deserialization to `TranscriptTurn.fromMap` / `toMap`.
  - Add `markTurnFlagged(TranscriptTurn turn)` method to `TranscriptStore` that updates the in-memory turn and triggers local store notification.
- **File 2**: `ayma_flutter/lib/screens/chat_screen.dart`
  - In `_TranscriptLineState.initState`, initialize `_flagged = widget.turn.flagged;`.
  - In `_thumbsDown`, call `TranscriptStore.instance.markTurnFlagged(widget.turn)`.
  - Pass `flagged` when constructing `_TranscriptLine`.
- **File 3**: `ayma_flutter/lib/services/report_cache.dart` (or `SharedPreferences` cache)
  - Cache set of thumbed-down turn IDs / text hashes locally under key `chat_flagged_turns:$uid`, restoring flags during Frame-1 offline hydration (aligning with T2 outbox/cache architecture).
- **File 4**: `functions/bootstrap/feedback_ops.py` & `functions/bootstrap/chat_history.py`
  - When `feedback_ops.record` receives a `session_id` or matching message quote, mark `feedback: "thumbs_down"` on the corresponding `chat_messages` document in Firestore.
  - In `chat_history.py` (`recent`), project `feedback: doc.get("feedback")` into the message dictionary.

#### E. Risks & Interactions
- **T2 Offline Spec Alignment**: T2 introduces durable `ChatOutbox` and cached `chat_history:$uid` in `ReportCache`. Storing the `flagged` boolean on `TranscriptTurn` ensures feedback state survives offline relaunches without breaking SWR revalidation.

#### F. Test Notes for Claude & Scout
- **Setup**: Signed-in user in Ayma chat.
- **Steps**:
  1. Send a message to Ayma and wait for her reply.
  2. Tap the thumbs-down icon on the reply. Verify it turns solid pink and displays `"noted"`.
  3. Force-stop the app via `adb shell am force-stop com.justabot.ayma` or navigate to Explore and back to Chat.
  4. Reopen Ayma chat.
- **Pass Condition**: The thumbed-down message still displays the solid pink thumbs-down icon and the `"noted"` label.

---

### 2.6 Item R2-C1: Dead Start Chips (Profile Completion)

#### A. Scout Sweep Report
- **Item**: `NOTE on R2-C1 (partial progress)`
- **Reported in**: Build `1.30.0 (2242)` under C4 pass notes
- **Symptom**: On a fresh account with profile completion at 12%, 8 of 9 section tiles were completely dead (no dialog, no navigation when tapped). Only the Qloo taste section responded.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported** (progressive disclosure locking leaves tiles inert without explanatory affordance / tap feedback, which Scout reported as "dead chips").
- **Code Locations**:
  1. Backend: `functions/bootstrap/completeness.py` lines 573–584 (`_EARLY_PAGE_TYPES`) and lines 595–644 (`_section_gating`).
  2. Frontend: `ayma_flutter/lib/screens/complete_profile_screen.dart` lines 202–217 and lines 521–555 (`_LockedSectionTile`).
- **Evidence**:
  1. In `completeness.py:583`, `_EARLY_PAGE_TYPES = frozenset({"taste"})` promotes Qloo taste so it is always unlocked.
  2. In `completeness.py:634`, for all other sections:
     ```python
     meta[pt] = {
         "unlocked": early or i == 0 or earlier_core_ok,
         ...
     }
     ```
     On a fresh account where `identity` core nodes are incomplete, `earlier_core_ok` is `False`. Consequently, all sections except `identity` and `taste` have `unlocked: False`.
  3. In `complete_profile_screen.dart:216`, all locked sections render via `_LockedSectionTile`:
     ```dart
     // complete_profile_screen.dart:521-555
     class _LockedSectionTile extends StatelessWidget {
       const _LockedSectionTile({required this.section});
       final CompletenessSection section;

       @override
       Widget build(BuildContext context) {
         final ac = context.ac;
         return Opacity(
           opacity: 0.55,
           child: Container(
             ...
             child: Row(
               children: [
                 Icon(Icons.lock_outline, size: 16, color: ac.fgMute),
                 const SizedBox(width: 10),
                 Expanded(child: Text(section.label, ...)),
                 Text('Locked', style: ...),
               ],
             ),
           ),
         );
       }
     }
     ```
  4. `_LockedSectionTile` has **zero tap affordance**: no `InkWell`, no `GestureDetector`, and no `onTap` callback. When the user taps a locked section to find out how to unlock it or start it, nothing happens. Scout reported this unresponsive behavior as "dead chips".

#### C. Root Cause
The UI implements progressive disclosure gating by rendering locked sections as completely inert widgets with no explanatory feedback, leaving the user with no guidance on why the sections are locked or how to progress.

#### D. File-Level Change List
- **File**: `ayma_flutter/lib/screens/complete_profile_screen.dart`
- **Function/Class**: `_LockedSectionTile` and `_Body`
- **Changes**:
  1. Pass an `onTapLocked` callback to `_LockedSectionTile`.
  2. Wrap `_LockedSectionTile` in an `InkWell` (with `BorderRadius.circular(14)`).
  3. When tapped, show an informative `AymaToast` or bottom sheet:
     ```dart
     AymaToast.show(
       context,
       'Answer questions in the unlocked sections first to unlock ${section.label}.',
       kind: AymaToastKind.info,
     );
     ```
  4. Alternatively, provide a CTA steering the user directly into the active unlocked section or kicking off an Ayma chat session on the first pending core node.

#### E. Risks & Interactions
- **Ayma Registration**: `CompleteProfileScreen.path` (`/complete-profile`) is already registered in `app_registry.json`. Tapping locked tiles remains within the screen or routes to the registered chat tab (`MainShellScreen.path`).

#### F. Test Notes for Claude & Scout
- **Setup**: Sign in as a fresh account (e.g. `ayma.b9.tester@example.com` or new sign-up at ~12% completeness).
- **Steps**:
  1. Navigate to `You` tab $\to$ tap the completeness card ("Your profile is 12% complete").
  2. On the "Complete your profile" screen, scroll down to "UNLOCKS AS YOU GO".
  3. Tap any of the locked section tiles (e.g. "Personality & temperament" or "Values & beliefs").
- **Pass Condition**: Tapping is responsive and displays a polite explanation of what must be completed to unlock the section, with zero silent dead taps.

---

### 2.7 Item G2: Score Staleness

#### A. Scout Sweep Report
- **Item**: `BUG R2-G2 [S3]` (Run #2 carry-over)
- **Reported in**: Build `1.30.0 (2242)`
- **Symptom**: Cross-surface score inconsistency. The Ayma chat announcement said `"compatibility report with Priya Nair is ready: 25%"` and Explore showed Priya `"25% match"`, but the opened Match report headline (and its share text) displayed `17%`. The finding is score staleness resulting from silent background recalculation without updating chat announcements or displaying evaluation timestamps.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Locations**:
  1. Backend Scorer: `functions/bootstrap/main.py` lines 6039–6050, 6124–6136, and 6227–6233.
  2. Backend Adapter: `functions/bootstrap/report_adapters.py` lines 300–350 (`match_blocks`).
  3. Frontend: `ayma_flutter/lib/screens/chat_screen.dart` lines 2833–2836 and `ayma_flutter/lib/screens/match_report_screen.dart`.
- **Evidence**:
  1. In `main.py:6047`, `_match_chat_text` formats an immutable text string containing the literal percentage:
     ```python
     f"Your compatibility report with {name} is ready: {pct}%.\n\n[match:{match_id}]"
     ```
  2. When `GET /match/{match_id}` is called (`main.py:6227`), if `_match_doc_is_stale(db, d, a, b)` is true, the backend schedules a silent background re-score:
     ```python
     background.add_task(_match_job, uid, other, notify=False)
     ```
  3. `_match_job` with `notify=False` updates `matches/{matchId}` with the new score (e.g., `0.17` / `17%`), but skips notifications and does not update the previously appended chat turn.
  4. In `match_report_screen.dart` and `report_adapters.py`, the match report displays the new score (`17%`) but **carries no `scored_at` timestamp or version label**, leaving the user bewildered as to why the chat card reads `25%` while the report reads `17%`.

#### C. Root Cause
The chat announcement bakes the score into a static string literal at generation time, while the backend recalculates scores asynchronously in the background without updating the corresponding chat card or providing a timestamp/staleness indicator in the report.

#### D. File-Level Change List
- **File 1**: `functions/bootstrap/report_adapters.py`
  - In `match_blocks`, include a timestamp stat or subtitle block in the header (e.g. `"Evaluated on <date>"`, using `doc.get("updated_at")` or `doc.get("scored_at")`).
- **File 2**: `functions/bootstrap/main.py`
  - In `_match_chat_text`: simplify the chat announcement to reference the report dynamically or omit the static percentage:
    `f"Your compatibility report with {name} is ready.\n\n[match:{match_id}]"`
  - Alternatively, in `_match_job`, update the existing chat turn in `chat_messages` if a previous `[match:{match_id}]` message exists for this pair.
- **File 3**: `ayma_flutter/lib/screens/chat_screen.dart`
  - When rendering the `[match:<id>]` inline card, fetch the live score from `MatchService` / `matches` collection rather than relying on the static prefix string in `turn.text`.

#### E. Risks & Interactions
- **Living Report Consistency**: `MatchReportScreen` delegates its body to `LivingReportView(reportType: 'match')`. Adding `updated_at` / `scored_at` in `report_adapters.py` seamlessly renders across all platforms without altering bespoke screen layout.

#### F. Test Notes for Claude & Scout
- **Setup**: Two test accounts (e.g. Daniel and Priya).
- **Steps**:
  1. Trigger compatibility check via `POST /check-compatibility`. Note score in chat card.
  2. Mutate a preference or trigger `_recalculate` with `force: true`.
  3. Revisit chat and open the Match report.
- **Pass Condition**: Chat announcement card and Match report headline display consistent scores, and the report displays an explicit evaluation timestamp.

---

### 2.8 Item G4: Share /s/ Link Serves Homepage

#### A. Scout Sweep Report
- **Item**: `BUG R2-G4 [S2]` (Run #2 carry-over)
- **Reported in**: Build `1.30.0 (2242)`
- **Symptom**: Sharing a report generates a valid link (`https://justabot.info/s/<token>`), but opening the link in a browser renders the Ayma marketing homepage (`"Private beta / The dating companion you can actually talk to"`), rather than the shared public report snapshot.

#### B. Verification Against Tip `9769a16`
- **Verdict**: **CONFIRMED as reported**.
- **Code Locations**:
  1. Hosting Config: `firebase.json` lines 16–32 (`hosting.rewrites`).
  2. Backend Routes: `functions/bootstrap/main.py` lines 3875–3900 (`/s/{token}`, `/s/{token}/data`, `/s/{token}/card.png`).
  3. Flutter Client: `ayma_flutter/lib/screens/shared_report_screen.dart` (`/s/:token`).
- **Evidence**:
  Look at `firebase.json` lines 16–32:
  ```json
  "rewrites": [
    {
      "source": "/privacy-policy",
      "destination": "/privacy.html"
    },
    {
      "source": "/get",
      "destination": "/get.html"
    },
    {
      "source": "/r/**",
      "run": {
        "serviceId": "ayma-api",
        "region": "us-central1"
      }
    }
  ]
  ```
  Notice that `/r/**` (the referral code endpoint) has a Cloud Run rewrite to `ayma-api`.
  **`/s/**` is completely absent from `firebase.json`!**
  Likewise, `/.well-known/**` (Android app-link `assetlinks.json`) is absent.
  When an external user or browser requests `https://justabot.info/s/<token>`, Firebase Hosting evaluates its rewrites. Finding no match for `/s/**`, it serves the default static fallback `public/index.html` (the marketing landing page).

#### C. Root Cause
`firebase.json` lacks rewrite rules for `/s/**` and `/.well-known/**` to proxy requests to the Cloud Run service `ayma-api`.

#### D. File-Level Change List
- **File**: `firebase.json`
- **Section**: `hosting.rewrites`
- **Changes**:
  Add rewrites for `/s/**` and `/.well-known/**` to `ayma-api`:
  ```json
  "rewrites": [
    {
      "source": "/privacy-policy",
      "destination": "/privacy.html"
    },
    {
      "source": "/get",
      "destination": "/get.html"
    },
    {
      "source": "/s/**",
      "run": {
        "serviceId": "ayma-api",
        "region": "us-central1"
      }
    },
    {
      "source": "/.well-known/**",
      "run": {
        "serviceId": "ayma-api",
        "region": "us-central1"
      }
    },
    {
      "source": "/r/**",
      "run": {
        "serviceId": "ayma-api",
        "region": "us-central1"
      }
    }
  ]
  ```

#### E. Risks & Interactions
- **Privacy & PII Leakage**: `functions/bootstrap/share_page.py` and `share.py` already sanitize shared snapshots to public-safe fields only (no last names, no contact details, no private preferences).
- **Rate Limiting**: Public `/s/*` routes are already guarded by `ratelimit.py` (`rate_share_public`).
- **Android App Links**: Android's `AndroidManifest.xml` already registers `android:pathPrefix="/s/"`. Adding the rewrite for `/.well-known/assetlinks.json` allows Android to verify digital asset links, directly launching the app to `SharedReportScreen.path` (`/s/:token`).

#### F. Test Notes for Claude & Scout
- **Setup**: Deployed Firebase Hosting or local Firebase emulator (`firebase emulators:start`).
- **Steps**:
  1. Open a Match report or Web Research report in Ayma $\to$ tap Share $\to$ copy the link `https://justabot.info/s/<token>`.
  2. Open the URL in a desktop or mobile browser (incognito mode).
- **Pass Condition**: Browser renders the public HTML report snapshot (`share_page.html`) with score, summary, and Open Graph meta tags, rather than the marketing homepage. On a device with Ayma installed, clicking the link deep-links into `SharedReportScreen`.

---

## 3. Cross-Item Interactions & Implementation Ordering

```
┌────────────────────────────────────────────────────────────────────────┐
│                        T3 Polish Batch Order                           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 1: Zero-Risk Config & Formatting Fixes                           │
│  • G4: firebase.json hosting rewrites (/s/** and /.well-known/**)      │
│  • P5: SettingsScreen version string (+buildNumber and · staging)      │
│  • R2-C8b: DateSimScreen MarkdownText bubble rendering                 │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 2: Interaction & Exception Guardrails                            │
│  • obs-2: SignInScreen Google cancel exception suppression             │
│  • P1: AymaTabBar narrow viewport responsive padding (720x1280)        │
│  • R2-C1: CompleteProfileScreen interactive locked section tiles       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Stage 3: Persistence & Freshness Alignment                             │
│  • R2-D6: TranscriptTurn & feedback_ops message-level thumbs persistence│
│  • G2: Match report timestamping & chat announcement score alignment   │
└────────────────────────────────────────────────────────────────────────┘
```

1. **Stage 1 (Pure Configuration & Widget Upgrades)**:
   - G4 (`firebase.json`), P5 (`settings_screen.dart`), and R2-C8b (`date_sim_screen.dart`) have zero side-effects on other app systems and can be merged and validated immediately.
2. **Stage 2 (UI Constraints & Flow Hardening)**:
   - obs-2 (`sign_in_screen.dart`), P1 (`ayma_tab_bar.dart`), and R2-C1 (`complete_profile_screen.dart`) harden user input flows and responsive layouts without altering backend data models.
3. **Stage 3 (State Persistence & Multi-Surface Sync)**:
   - R2-D6 (feedback persistence) and G2 (match score staleness) coordinate frontend cache models with backend persistence. They build cleanly on top of T2's offline cache (`ReportCache`) foundations.

---

## 4. Definition of Done & Verification Checklist for Claude

Before closing the T3 implementation branch, ensure:
- [ ] **Docs Updated**: `docs/deploy.md`, `docs/ARCHITECTURE.md`, `docs/TODO_QUEUE.md` updated with the `/s/**` rewrite and feedback persistence contract.
- [ ] **Zero Hardcoded Model Names**: All Gemini models flow exclusively through `functions/bootstrap/config.py`.
- [ ] **LiveKit Inference Invariant**: All LLM and voice operations remain 100% on LiveKit; zero direct provider fallbacks.
- [ ] **Layout Matrix Green**: `ayma_flutter/test/layout_matrix_test.dart` passes across all 3 shards with zero RenderFlex overflows.
- [ ] **App Registry Compliance**: All routes (`/complete-profile`, `/s/:token`, etc.) remain fully registered in `functions/bootstrap/app_registry.json`.
- [ ] **Unit & Widget Tests**:
  - `test/ayma_tab_bar_test.dart`: asserts no overflow at 274px logical width.
  - `test/settings_screen_test.dart`: asserts version footer contains `+<build>` and `· staging`.
  - `test/sign_in_screen_test.dart`: asserts Google cancellation throws no error toast.
  - `test/date_sim_screen_test.dart`: asserts MarkdownText renders styled formatting.
  - `test/feedback_persistence_test.dart`: asserts thumbs-down state persists across re-instantiation.
  - `test/complete_profile_screen_test.dart`: asserts locked tiles display explanation on tap.
