# Ayma Keyboard — V1 (Android)

Founder-approved Nov 6, 2026. The keyboard is the insertion mechanism:
the user is in any app with a text field open, switches to the Ayma
Keyboard, and taps once to insert the text Ayma drafted for them. Ayma
never types on her own — the user enables the keyboard, switches to it,
and taps Insert, every time. That explicit enable + switch + tap is what
keeps this store-legal on both stores.

## User flow (plain language)

1. **Enable once.** In Ayma: Settings → Ayma Keyboard. Read the privacy
   explainer, tap **Enable Ayma Keyboard**, and turn Ayma Keyboard on in
   the Android keyboard settings that open.
2. **Draft in Ayma.** Chat with Ayma until she drafts the message/reply
   you want (or write it in the Ayma chat composer). Tap
   **Send to Ayma Keyboard** — the draft is saved on the phone, inside
   Ayma, with a timestamp.
3. **Switch apps.** Open the app you want to write in (Messages,
   WhatsApp, a dating app, anything) and tap its text field.
4. **Switch keyboards.** Tap the globe/keyboard icon and pick
   **Ayma Keyboard**.
5. **Insert.** The strip on top of the keyboard shows the draft. Check
   it, tap **Insert**, and the text lands in the field exactly as
   written. Send it in that app yourself when ready.
6. The letter keys below the strip are a normal (minimal) keyboard, so
   you can fix a word or keep typing without switching back. **✕** in
   the strip clears the draft; the 🌐 key switches back to your usual
   keyboard.

Drafts expire after **one hour** — the strip then says so and Insert is
off, so a stale draft can never be inserted by accident.

## How it is built

- `AymaKeyboardService` (Kotlin, `InputMethodService`) in the Ayma app:
  a minimal QWERTY letter keyboard (numbers row, shift, delete, space,
  enter/editor-action, keyboard switcher) plus the Ayma strip.
  Insert uses `InputConnection.commitText`.
- Draft plumbing: a single app-internal file,
  `ayma_keyboard_draft.json`, in the app files directory, written/read
  by a small shared Kotlin store (`KeyboardDraftStore.kt`) and by the
  Flutter side through the `ayma/keyboard_draft` MethodChannel
  (MainActivity). **Why a file, not a ContentProvider:** app and IME are
  the same application under the same UID/sandbox, so the internal file
  is already private to Ayma and needs no IPC. A provider would have to
  be exported or use URI grants to be useful to anything, adding a
  queryable surface for zero benefit inside one app. Writes are
  write-then-rename so the IME never reads a half-written draft.
- In-app entry points: Settings → **Ayma Keyboard** (explainer +
  enable/switch actions), and **Send to Ayma Keyboard** in the Ayma chat
  composer whenever the composer holds text (which is exactly where an
  Ayma draft lands).

## Privacy posture (hard requirements)

- **No keystroke logging or transmission.** Key presses go straight to
  the host app's `InputConnection` and nowhere else. The IME contains
  no logging calls and stores nothing about typing.
- **No network calls from the IME in V1.** The IME and draft store
  reference no networking APIs. The only data the strip can show is the
  on-device draft file the user created from inside Ayma.
- **Password / secure fields get nothing.** Verified two ways:
  (1) platform — Android does not expose password-field contents to
  IMEs, password fields report a password input variation, and secure
  surfaces (`FLAG_SECURE` windows, many banking/lock screens) force the
  system keyboard or block third-party IMEs entirely;
  (2) our own guard — `AymaKeyboardService.isSecureField` detects text
  password, visible-password, web-password, and numeric-password
  variations; in those fields the strip shows no draft text, Insert and
  Clear are disabled, and `insertDraft()` returns immediately.
- The in-app explainer (`AymaKeyboardScreen`) states all of the above
  before the user enables the keyboard, including Android's standard
  warning that any keyboard could in principle read typing.

## Stretch not built: "Draft with Ayma" inside the keyboard

Skipped deliberately. The IME has no signed-in session; giving it one
means handing auth tokens to the IME and making network calls from it,
which breaks the V1 privacy posture above. Drafting stays in the app,
where the session already lives. This can be revisited in V2 with an
app-mediated handoff (keyboard asks the app, app fetches, keyboard only
ever reads the draft file).

## iOS — phase 2 design note (not built)

- A **Custom Keyboard Extension** target in the Ayma app, sharing the
  draft through an **App Group** container: the app writes the same
  draft JSON (text + timestamp) into the shared group directory /
  `UserDefaults(suiteName:)`; the extension reads it. Same 1-hour TTL
  and expiry display.
- The extension needs **Full Access** (`RequestsOpenAccess` in its
  Info.plist) to read the app-group payload reliably and for any future
  app handoff; the privacy explainer must disclose this, and the no
  keystroke logging / no network posture carries over. Without Full
  Access the extension can still insert a draft passed via the shared
  container in most cases, but behaviour varies — Full Access is the
  honest V2 choice, disclosed up front.
- iOS specifics: the user enables it in Settings → General → Keyboard →
  Keyboards → Add New Keyboard, and switches with the globe key — the
  same enable/switch/tap-Insert model. iOS itself replaces third-party
  keyboards with the system keyboard for secure text fields, which is
  the same platform guarantee as Android's. `UIInputViewController`
  inserts via its `textDocumentProxy.insertText`.
- Store review: App Store guideline 4.4 / extension rules require the
  keyboard to work as a keyboard (the letter keys), no marketing-only
  content, and clear disclosure of Full Access data use — our posture
  (no collection at all) is the strongest position.

## Tests

- Dart: `test/keyboard_draft_store_test.dart` (fresh/stale/expiry at
  exactly 1h, blank drafts, insert formatting, JSON round-trip, channel
  set/get/clear, in-memory fallback) and
  `test/ayma_keyboard_screen_test.dart` (explainer carries the privacy
  posture; the button stores the draft).
- Kotlin JVM: `KeyboardDraftStoreTest` (same freshness/formatting/file
  behaviour against the real store) and `AymaKeyboardSecureFieldTest`
  (password variations are secure, normal fields are not).
- Full Flutter suite + `flutter analyze` run on the branch before DONE.

## Verification (Nov 6, 2026, on the branch)

- Base: staging tip `576cf98e` (build 2326), verified before branching.
- `flutter analyze` (whole project): **no issues**.
- New Dart tests: 10/10 pass. New Kotlin JVM tests: 8/8 pass
  (`:app:testDebugUnitTest`, BUILD SUCCESSFUL — this also compiles the
  IME and the MainActivity channel).
- Full Flutter suite: 1695 passed, 3 failed — all three were the repo's
  route-registry guards (app_registry / layout_matrix completeness /
  screen_capture) failing on the new route. Fixed by registering the
  destination in `functions/bootstrap/app_registry.json` (key
  `ayma_keyboard`, found_on settings — Ayma can navigate to it, per
  action parity) and adding the layout-matrix target; all three test
  files then pass, and the keyboard screen passes its layout-matrix leg
  (shard 2, `screen /settings/ayma-keyboard`).
- Backend registry pytest: 50 passed, 1 failed
  (`test_notification_settings_cover_every_category`, a missing
  `report_ready` notification category) — verified identical on the
  clean staging tip, pre-existing and unrelated to this branch.
