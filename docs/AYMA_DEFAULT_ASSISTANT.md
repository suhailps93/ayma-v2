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
   never written to disk, never logged), launches `MainActivity`,
   and finishes. Dart consumes the snapshot once over the
   `ayma/assistant` channel.
5. **Ayma's surface.** `AssistantScreen` (`/assistant`) opens already
   knowing the screen: it names the foreground app, shows the
   screenshot thumbnail, describes the screen locally, and answers
   questions through `POST /chat` using the same screen-context
   params as in-app screens (`screen = "external_app"`,
   `screen_visible` = the hierarchy text). The screenshot bytes
   themselves never leave the device in V1.
6. **Guidance continues.** "Guide me on this screen" stores the
   screen as the live `AppContext` and returns to the main chat /
   voice surface, so a voice call or chat turn there starts from this
   screen. **Co-pilot wiring (merge-time):** the screen-share
   co-pilot lives on branch `fleet/copilot-highlight`
   (`CopilotScreen`, `/copilot`). When both branches are on staging,
   point the Guide button at `CopilotScreen.path` and seed
   `CopilotService` with the capture's screenshot as its first frame;
   the code marks the spot with a `COPILOT-HANDOFF` comment.
7. **Enabling from the app.** Ayma's settings carries an
   **Assistant** section: "Ayma Assistant" opens the surface above,
   and "Default assistant app" deep-links to the system UI
   (`RoleManager` role request for `ROLE_ASSISTANT` on Android 10+,
   the default-apps settings page below that). The assistant surface
   itself shows live status and the same deep link.

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
`AymaAssistantSession.kt`, `AymaRecognitionService.kt` (stub the XML
requires), `AssistBridge.kt` (snapshot + flattening, JVM-tested),
plus the `MainActivity.kt` `ayma/assistant` channel (default-status
check, settings deep link, one-shot snapshot hand-off) and the
manifest service declaration.

Dart: `lib/services/assist_context.dart` (snapshot model, describe /
context builders, session store, privacy copy),
`lib/services/assistant_service.dart` (channel wrapper + summon
binding from `main()`), `lib/screens/assistant_screen.dart`.

Tests: `test/assist_context_test.dart`,
`test/assistant_service_test.dart`, `test/assistant_screen_test.dart`,
Kotlin JVM tests under `android/app/src/test/` (`AssistBridgeTest`,
`AssistTextFlattenerTest`), the app-registry + layout-matrix entries
for `/assistant`.

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
