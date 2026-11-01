# Voice preview verification — handoff note

Date: 2026-11-01 · Branch: `chore/voice-preview-verify` · Method: static code read only, no changes, no runs

## Verdict: EXISTS

A user CAN preview a voice (hear a spoken sample) before choosing it. The capability exists on **both** sides and is wired end to end. Nothing is backend-only; no client piece is missing.

## Flow (screen → endpoint → audio)

Profile tab → "Ayma" group → **Ayma's settings** (`/settings/ayma`) → **"Ayma's voice"** row → **voice picker** (`/settings/voice`). On the picker, every preset row has a speaker-icon play button, and tapping a row selects it *and* plays its sample. Playback streams a cached WAV URL from the backend over `just_audio`.

## Backend (`functions/bootstrap`) — preview capability exists and is routed

- `voice_preview.py:150` — `preview_url(voice_name)`: validates the preset via `voices.is_valid_voice`, returns the cached Storage URL, else synthesizes one short sample via Gemini TTS (`CONFIG.gemini_tts_model`) and caches it forever at `voice_previews/{voice_name}.wav`.
- `prompts/voice_preview.txt` — the fixed sample script ("Hi, I'm Ayma — your matchmaker…").
- `voices.py:17` — the preset catalog (`VOICE_PRESETS`, 8 presets). Note: **`voice_catalog.py` does not exist** — `voices.py` is the catalog; nothing is missing because of that.
- `main.py:4994` — `GET /voice/preview/{voice_name}` (auth required; 404 unknown preset, 502 TTS/storage failure) → `{"url": …}`. Sibling `GET /voice/presets` at `main.py:4972` feeds the picker list.
- Rate limit wired: `ratelimit.py:67` (`/voice/preview/` → `rate_voice_preview`, `config.py:562,852`).
- `agent.py`: correctly NOT involved — it is the LiveKit call worker, not HTTP. It consumes `voices.py` only for session voice selection and the mid-call `VoiceSwapper`. Preview serving belongs on the `main.py` gateway, where it is.
- Tests: `tests/test_voice_preview.py` (cache/generate behaviour plus endpoint happy-path, 404, 502, auth).

## Client (`ayma_flutter/lib`) — preview control exists on the only voice-selection surface

- `screens/voice_preference_screen.dart` — the picker (`static const path = '/settings/voice'`, line 25):
  - Per-preset play button: `IconButton(Icons.volume_up_outlined, tooltip: 'Hear {name}')` at lines 266–275 → `_preview(name)`.
  - Tap-to-preview on select: `onChanged` calls `_choose(v)` + `_preview(v)` (lines 248–251).
  - `_preview` (lines 132–157) stops current audio (and ends a live call if one is running), fetches the URL via `ApiClient.voicePreviewUrl`, plays via `VoicePreviewPlayer`; failures show a "Couldn't play a preview." toast, never silent.
  - Previews prewarmed for all presets on load (lines 92–96); speaking-orb indicator while a preview resolves/plays (lines 262–265).
- `services/api_client.dart:1334` — `voicePreviewUrl()` → `GET /voice/preview/{name}`; `:1300` — `voicePresets()` → `GET /voice/presets`.
- `services/voice_preview_player.dart` — `VoicePreviewPlayer` interface + `JustAudioPreviewPlayer` (latest-tap-wins tokens); `just_audio: ^0.10.6` in `pubspec.yaml:62`.
- Reachability: routed in `routing/app_router.dart:290-294`; entry row "Ayma's voice → Pick the voice she speaks with" in `screens/ayma_settings_screen.dart:84-92`.
- Test: `ayma_flutter/test/voice_preference_screen_test.dart`.

## Every voice-selection surface audited

| Surface | Voice picking? | Preview control? |
|---|---|---|
| Voice picker `/settings/voice` | Yes (only one) | **Yes** (play button + tap-to-preview) |
| Ayma's settings `/settings/ayma` | No (nav row only) | N/A — one tap above the picker |
| Onboarding / preboarding / sign-in | No (`setVoicePreference` has exactly one call site: `voice_preference_screen.dart:105`; preboarding notes voice does not run there) | N/A |
| "Models" screen (test E8 wording) | **No such screen exists** — no model-picker screen in `ayma_flutter/lib`; "model" matches are data models and AI-provider mentions only | N/A |

## Reconciling test E8 ("no preview control exists")

The code contradicts the report on the voice picker itself. If the tester saw no preview control, the plausible causes are outside this code (all need a live check, not a code fix): a stale build predating the feature, standing on `/settings/ayma` (which has no preview — it is one tap above the picker) instead of opening "Ayma's voice", a backend/network failure (which surfaces only as a toast), or device-audio issues. Recommend re-running E8 against a current build on `/settings/voice` before opening any fix task.

## Verify-before-fix outcome

No fix task needed. No code changed in this worktree for this verification (this note is the only file added).
