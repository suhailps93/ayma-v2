# Ayma as the Android default digital assistant

Founder order (2026-11-06): "Ayma should be able to use this" — the
Android **Default digital assistant app** setting with its **"Use
screen and app data"** toggle. This is the sanctioned, Play-policy
clean route to Ayma helping in other apps: the Assist API. No
Accessibility service, no background screen scraping, no overlays
reading other apps.

## How it works

1. **Registration.** `AymaAssistantService` (a
   `VoiceInteractionService`) is declared in the manifest with
   `res/xml/ayma_voice_interaction_service.xml`
   (`supportsAssist="true"`, session service + recognition stub).
   That declaration is what lists Ayma under
   **Settings → Apps → Default apps → Digital assistant app**.
   Until a user selects Ayma there, nothing is bound and the feature
   is fully dormant.
2. **Summon.** The user long-presses Home (or uses the assistant
   gesture) in any app. Android creates an
   `AymaAssistantSession`.
3. **Assist payload.** If — and only if — the user also enabled
   **"Use screen and app data"** for Ayma, the system hands the
   session the foreground app's `AssistContent` (web URI, structured
   data), its `AssistStructure` view hierarchy, and a screenshot.
   With the toggle off, the summon still opens Ayma; she simply
   receives nothing and says so, with the steps to enable it.
4. **Hand-off.** The session flattens the hierarchy to visible text
   (capped, de-duplicated), downscales the screenshot to a JPEG held
   **in memory only** (`AssistBridge`: one-shot, 5-minute expiry,
   never written to disk, never logged). It does **not** launch
   `MainActivity` — the summon stays in-session (step 5). The orb's
   Dart consumes the snapshot once over the `ayma/assistant` channel.
5. **Floating orb (voice, no full app).** A summon raises a **floating
   Ayma orb over the current app** and starts voice mode in the
   **background** — the full Ayma Activity does NOT open (founder order,
   Nov 2026). The session hosts a `FlutterView` on a dedicated
   `FlutterEngine` running the `assistantOrbMain` Dart entrypoint
   (`lib/assistant_orb_main.dart`) inside the
   `VoiceInteractionSession`'s **own window** — the only surface, with
   **no `SYSTEM_ALERT_WINDOW`/draw-over-other-apps overlay** and no
   always-on bubble. That entrypoint runs the real `AymaOrb` bound to
   the real LiveKit voice stack (`AymaSession.instance.voice`): the orb
   reflects voice state (idle / listening / speaking / connecting), and
   the captured foreground screen is folded into `AppContext`
   (`screen = "external_app"`) so the call opens knowing what the user
   was looking at. **Tapping the orb expands** to the full voice panel
   (large orb, honest status line, mute, end) in the same session;
   **dismissing** (tap outside the orb, or End) finishes the session via
   the `ayma/assistant_orb` channel and returns the user to the app they
   summoned from. If LiveKit is down or the user is signed out, the orb
   shows an **honest error** — never a silent "Listening…" (AGENTS.md).
   The in-app assistant **settings** screen (`AssistantScreen`,
   `/assistant`) is unrelated and reachable only from
   Settings → Ayma Assistant. The screenshot bytes never leave the
   device in V1.
   - *Fallback:* a launcher that routes the gesture to the activity with
     a bare `ACTION_ASSIST` (bypassing the voice-interaction session)
     has no session to host an orb; `MainActivity` then seeds an empty
     snapshot and `main._activateAymaFromSummon` starts voice in-app —
     the honest degraded path, not the normal one.
6. **Guidance continues.** "Guide me on this screen" stores the
   screen as the live `AppContext` and returns to the main chat /
   voice surface, so a voice call or chat turn there starts from this
   screen. **Co-pilot wiring (merge-time):** the screen-share
   co-pilot lives on branch `fleet/copilot-highlight`
   (`CopilotScreen`, `/copilot`). When both branches are on staging,
   point the Guide button at `CopilotScreen.path` and seed
   `CopilotService` with the capture's screenshot as its first frame;
   the code marks the spot with a `COPILOT-HANDOFF` comment.
7. **Enabling from the app.** Ayma's settings carries a single
   **Ayma Assistant** row that opens the surface above; that surface
   shows live status and the "Open assistant settings" button, which
   is the one entry point for making Ayma the default (the separate
   "Default assistant app" shortcut row was removed, row 2r). The
   button deep-links straight to the system Assist & voice-input
   settings page (then the default-apps list, then top-level
   Settings), resolving each surface before opening it. It does **not**
   use `RoleManager.createRequestRoleIntent(ROLE_ASSISTANT)`:
   `ROLE_ASSISTANT` is not a user-requestable role, so that intent
   finishes immediately with `RESULT_CANCELED` and shows nothing — the
   original "button does nothing" defect. The native side returns
   whether a surface actually opened, and the screen shows a visible
   message when none can be. (`RoleManager.isRoleHeld(ROLE_ASSISTANT)`
   is still used to *detect* the current default.)

## Privacy (behavior matches this copy)

- Screen content arrives **only** on a user-initiated summon. There
  is no background capture of any kind.
- Snapshots live in memory only, are consumed once, and expire
  (5 minutes natively; 15 minutes for the in-app session copy that
  survives a sign-in detour). Nothing is written to disk or to
  shared preferences, and screenshots are never uploaded in V1.
- Screen **text** is sent to Ayma's backend only when the user asks
  a question about the screen — the same disclosure as the in-app
  screen context Ayma already receives during voice calls.
- User-facing copy lives in `AssistPrivacy`
  (`lib/services/assist_context.dart`), is pinned by
  `test/assist_context_test.dart`, and is mirrored in
  `docs/PRIVACY.md` (and `public/privacy.html`).

## Files

Native (Kotlin, `android/app/src/main/kotlin/com/ayma/ayma_flutter/`):
`AymaAssistantService.kt`, `AymaAssistantSessionService.kt`,
`AymaAssistantSession.kt` (hosts the in-session floating-orb
`FlutterEngine` + `FlutterView`; registers the `ayma/assistant` snapshot
read and `ayma/assistant_orb` dismiss channels on it),
`AymaRecognitionService.kt` (stub the XML requires), `AssistBridge.kt`
(snapshot + flattening, JVM-tested), plus the `MainActivity.kt`
`ayma/assistant` channel (default-status check, settings deep link,
one-shot snapshot hand-off for the `ACTION_ASSIST` activity fallback) and
the manifest service declarations. **All three services must be declared
in `AndroidManifest.xml`** — `AymaAssistantService` (the
`VoiceInteractionService`), `AymaAssistantSessionService`
(`BIND_VOICE_INTERACTION`) and `AymaRecognitionService`
(`android.speech.RecognitionService`). The session + recognition
services are the ones the voice-interaction XML names; if either is
missing, the system's `VoiceInteractionServiceInfo` parser rejects the
whole service and Ayma never appears in the Digital assistant picker
(this was the row-2r "not selectable" half of the defect).

Dart: `lib/services/assist_context.dart` (snapshot model, describe /
context builders, session store, privacy copy),
`lib/services/assistant_service.dart` (channel wrapper + summon
binding from `main()`, used by the `ACTION_ASSIST` activity fallback),
`lib/assistant_orb_main.dart` (the `assistantOrbMain` entrypoint +
`AssistantOrbApp`/`AssistantOrbSurface` floating orb, the voice-backed
`VoiceOrbModel`, and the `ayma/assistant_orb` dismiss channel),
`lib/screens/assistant_screen.dart` (the separate settings surface).

Tests: `test/assist_context_test.dart`,
`test/assistant_service_test.dart`, `test/assistant_screen_test.dart`,
`test/assistant_orb_test.dart` (orb reflects idle/listening/speaking,
expands on tap, dismiss returns, honest error — never a fake Listening),
Kotlin JVM tests under `android/app/src/test/` (`AssistBridgeTest`,
`AssistTextFlattenerTest`, `AymaAssistantSessionSummonTest` — asserts the
summon builds no `MainActivity` launch intent and adds no overlay
permission), the app-registry (`assistant_summon_orb` behavior entry) +
layout-matrix entries for `/assistant`.

## Platform notes

- Android only. iOS has no equivalent default-assistant Assist API;
  the Dart service degrades to "not default, no summon" there.
- The legacy `onHandleAssist(Bundle, AssistStructure, AssistContent)`
  + `onHandleScreenshot` callbacks are the single code path: on
  Android 11+ the framework's default `AssistState` handling unpacks
  into exactly those callbacks.
- Password and other secure content: the Assist API itself withholds
  password text from the hierarchy, and `FLAG_SECURE` screens deliver
  no screenshot.
- The floating orb runs in a **second FlutterEngine** (the summoned app
  is not foregrounded, so there is no shared engine to reuse): it inits
  Firebase and restores the signed-in session from disk, then starts the
  real LiveKit voice session. First-summon warm-up (Firebase + auth
  restore + LiveKit connect) costs a few seconds; the orb shows
  `Connecting…` honestly during it. `RECORD_AUDIO` must already be
  granted (the session has no Activity to request a runtime permission);
  if it is not, voice surfaces the honest error. This is Android-only;
  iOS is unchanged.
