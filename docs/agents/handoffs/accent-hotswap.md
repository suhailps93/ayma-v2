# Handoff: accent-hotswap (mid-call voice accent change)

From Muse (Engineer). Branch: `muse/accent-hot-swap` off `origin/staging`
(75eb2d2). Worktree: `.fleet-worktrees/accent-hotswap`. NEVER work in the
main checkout. Do NOT merge — Astro merges.

Status: IN PROGRESS (backend implemented + focused tests green; Flutter +
full suite + docs still to do — see Checklist).

## Goal

A voice accent change applies to the CURRENT call, not just the next one.
User changes accent mid-call (settings screen, or "speak with an X accent")
→ Ayma speaks with the new accent within the same call, no drop.

## Verification result (do not re-do)

Astro's premise CONFIRMED on origin/staging tip 75eb2d2:

- Since 07a848c, `agent._start_main_gemini_session` derives
  `effective_language = seed.voice_language or
  voices.bcp47_hint(seed.voice_accent)` ("indian" → "en-IN") and passes it as
  the BCP-47 `language` to `build_realtime_model` ONCE at session boot.
- `skills/set_voice_preference.bind_live` handles the dedicated `accent` param
  via `_accent_clause`, which only persists `ayma_voice_accent` and replies
  "takes effect from your next voice call" — it never touches `VoiceSwapper`.
- `POST /voice/preference` docstring + inline comment say "next voice session"
  / "next call"; the agent reads the seed once from room metadata and has no
  profile watcher, so a settings save mid-call is invisible to the live agent.
- Gemini Live cannot update accent in-session: the installed
  `livekit-plugins-google` bakes `language_code` into the setup message
  (`speech_config`, realtime_api.py) and `RealtimeModel.update_options`
  accepts only voice/temperature/tool knobs. So the mechanism is the
  task's option B: seamless `AgentSession.update_agent` restart inside the
  same room via the existing `VoiceSwapper` machinery.

## Design (all in this branch unless noted)

1. `VoiceSwapper` learns the dedicated accent: new `voice_accent` state +
   `accent_block` builder (boot passes raw `seed.system_prompt` +
   `lambda a: _accent_block(rv, a)`), effective-language derivation mirroring
   boot (`language or bcp47_hint(accent)`), reconnect when voice, effective
   hint, OR accent text changes; new sessions carry the fresh accent block.
2. `bind_live` routes the `accent` param through the hot-swap hook
   (`on_change(preset, lang, voice_accent=...)`, kwarg passed only when an
   accent was requested, so old 2-arg hooks keep working); result text goes
   live ("switching now") instead of "next call". Text-chat `_bind` and
   cascade `bind_stack` keep next-call wording (correct there — no hot-swap).
3. Settings path: new room data topic `voice_accent_control`
   (`{"accent", "language"}`), mirroring the `agent_mute_control` pattern.
   Agent registers a listener in `_start_main_gemini_session` (Gemini path
   only — cascade/fixed-voice keeps next-call behavior) that sanitizes and
   calls `swapper.request`. Flutter `VoiceEngineControl._save` publishes via
   `VoiceSessionController.active?.notifyVoiceAccentChanged(...)` (best
   effort, only when accent/language actually changed) and the toast reads
   "accent applied to your current call" when delivered live.
4. Cascade / non-Gemini-realtime / inference route: unchanged behavior
   (accent applies from next call; on inference there is no BCP-47 lever so
   a settings/voice accent change still rebuilds instructions only —
   actually: accent text change DOES reconnect to refresh instructions; the
   hint stays None. Same rule as the voice path's reconnect-on-change).

## Files (planned)

- `functions/bootstrap/agent.py` — swapper accent support, topic + listener.
- `functions/bootstrap/skills/set_voice_preference.py` — live accent routing.
- `functions/bootstrap/tests/test_voice_hot_swap.py` — focused regression tests.
- `functions/bootstrap/tests/test_set_voice_preference.py` — maybe 1 test.
- `ayma_flutter/lib/services/voice_transport.dart` + `test/support/fake_voice_transport.dart`
- `ayma_flutter/lib/services/voice_session_controller.dart`
- `ayma_flutter/lib/widgets/voice_engine_control.dart`
- `ayma_flutter/test/voice_session_controller_test.dart`,
  `ayma_flutter/test/voice_engine_control_test.dart`
- `docs/ARCHITECTURE.md` (§13.9), `docs/TODO_QUEUE.md` (follow-up → done).

## Checklist

- [x] Verify premise on origin/staging (confirmed, see above)
- [x] Worktree + branch
- [ ] Backend: swapper accent + skill wiring + listener
- [ ] Backend focused tests green (`test_voice_hot_swap.py`,
      `test_set_voice_preference.py`, `test_agent.py`)
- [ ] Flutter: transport + controller + widget + tests green
- [ ] Full backend suite: only the 2 known pre-existing failures
      (`test_notification_settings_cover_every_category`,
      `test_stale_list_flags_stale_and_unavailable_only`)
- [ ] Docs (ARCHITECTURE §13.9, TODO_QUEUE) + this handoff current
- [ ] Small commits, push branch, report to `~/workspace/ayma-inbox/muse.md`

## How to run tests

Backend (from `functions/bootstrap`, using the MAIN checkout's venv as a
read-only interpreter — do not install or write there):
`PYTHONDONTWRITEBYTECODE=1 ~/workspace/ayma/functions/bootstrap/.venv/bin/python -m pytest tests/test_voice_hot_swap.py -q`
Flutter: `cd ayma_flutter && flutter test test/voice_session_controller_test.dart test/voice_engine_control_test.dart`

## Hard rules (from Astro)

No production default changes (Gemini stays default), no purchases, no token
top-ups; on a usage limit, write the handoff and stop. Do NOT merge.
