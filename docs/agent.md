# Agent worker (`ayma-agent`)

The LiveKit voice worker — a **separate** Cloud Run service from the Main API
(§10.1). Same source tree (`functions/bootstrap/`), different image: it pulls
the whole `livekit-agents` 1.8.9 runtime (+ `livekit-plugins-google`, `openai>=3.19,<4`
for the Inference path) that the Main API has no use for. Hence `Dockerfile.agent` /
`requirements-agent.txt` / `cloudbuild.agent.yaml` and a local `.venv-agent/`.

## What it does

- Registers as a LiveKit worker against `wss://aimma-wt34nu3l.livekit.cloud`.
- On a room dispatch (auto-dispatched when the backend creates the room in
  `/bootstrap`/`/welcome/token`, *not* when a client joins — see below) it
  reads the room metadata left there — system prompt, recent-turns window,
  `uid`/`session_id`, and the user's `ayma_voice_name` (§13.3) — and runs one
  Gemini Live `RealtimeModel` session (`agent.build_realtime_model`).
- Relays Gemini Live's native transcription to the room data channel as
  `user_transcript` / `agent_transcript` / `agent_state` events (§1.6, §1.3).
- Quiet mode: publishes `agent_mute` `{"muted": bool}` (on every change and
  every participant (re)join) and accepts `agent_mute_control`
  `{"muted": false}` from the app's Unmute controls (ARCHITECTURE.md §1.6a).
- Each call gets a fresh room (`livekit_token.room_name_for`: `<prefix><uid>-<nonce>`),
  so every call creates a new room and therefore a new agent job; a reused
  per-user room left callers in an empty room after a quick redial.
- The Live model comes from the `voice_provider` flag (`docs/FEATURE_FLAGS.md`):
  `inference` = `inference.RealtimeModel` through the LiveKit Inference gateway
  (`build_inference_realtime_model`, `google/gemini-3.8-live`; only
  `silence_duration_ms` is honoured), `google` = the plugin below. The decision
  is made once per call and tagged on `raw_turns.voice_provider`.
- A mid-call `set_voice_preference` hot-swaps the Live model (`VoiceSwapper`:
  heads-up line, `update_agent` to a `SwappedVoiceAgent` on a new model with the
  spoken history carried over, then a confirmation in the new voice). The
  confirmation is requested only after a 1 s settle (`_SWAP_SETTLE_SECONDS`): on
  the Inference gateway a reply asked for the instant the new session is set up
  is acknowledged and then never produced, which blocked the turn queue and left
  the call on "Listening" (founder test 2026-10-26). Each new session must start
  speaking within 6 s (`_SWAP_VERIFY_SECONDS`) or it is interrupted and rebuilt
  once; if that one is silent too, the previous voice is restored and Ayma says
  she couldn't switch (`prompts/voice_swap_failed.md`). Every step logs
  `voice-swap ...` with the session id and provider; failures go to Sentry
  (`VoiceSwapError`, tags `session_id`, `voice_provider`). Muted ("shut up")
  silence is not counted as a failure. The tool maps a preset named anywhere
  (`request="Puck"`, any case) and a gender word put in `accent_language`
  ("male" -> Charon, "female" -> Kore); the `en-US` hint for "American English"
  is passed on the Google route only (Inference ignores hints).
- The app-control tools (`current_screen`, `open_screen`, `app_action`,
  `account_action`) read `users/{uid}/voice_context/current` and queue commands
  at `users/{uid}/app_commands/pending` (`functions/bootstrap/app_registry.json`).
  Ayma never buys or subscribes for the user.
- Language: the instructions `/bootstrap` composes end with
  `prompts/voice_language.md` (the saved `ayma_voice_language`, English when
  unset; a short foreign-language fragment is a mishearing, not a switch). The
  Inference gateway ignores transcription `language`/`prompt`, so every tool is
  also wrapped by `misheard_fragment_guard`: when the newest line of the call is
  the caller's and `voices.is_misheard_fragment` says it is a garbled fragment,
  the tool does not run and Ayma is told to ask them to repeat. Short English
  confirmations ("Yeah, send it.", "yes", "do it") are plain ASCII and always
  pass. `send_dm_message` is bound with the call's `session_id` and live turn
  window so it can check the caller's own yes before sending (one confirmation;
  see `docs/ARCHITECTURE.md` section 0). The `tool_used` end event carries the
  outcome label for tools whose chip depends on the result.
- When the session closes, the end-of-call flush (full interleaved turn window
  to `users/{uid}/raw_turns/{session_id}` plus wiki ingest) starts immediately
  in the background; the shutdown callback awaits the same task, so the
  shutdown deadline no longer kills it mid-write.

## Deploy

```
scripts/deploy-agent.sh            # build image + deploy code-only
scripts/deploy-agent.sh --full     # also (re)set env vars + secret mounts
scripts/deploy-agent.sh --release  # alias for --full (no min-instances effect)
```

Config (§12.2, full history in `docs/deploy.md`): `--no-cpu-throttling
--cpu-boost --memory 2Gi`, `min-instances 0` — **permanently**, as of
2026-09-19. `--no-cpu-throttling` is mandatory regardless of scale — a
request-CPU-only instance never completes worker registration (confirmed in
logs, Step 13), because that registration runs in a background task outside
any HTTP request. `--cpu-boost` speeds up the cold start itself.

Scale-to-zero only works because `ayma-api`'s `/bootstrap` and
`/welcome/token` now send this service's own URL an authenticated "wake" GET
the instant a voice call starts (`functions/bootstrap/agent_wake.py`) — Cloud
Run has no other way to know a call is coming, since LiveKit's automatic
dispatch only pushes jobs to workers already registered and the room-creation
call never touches this service. Don't flip `min-instances` back to 1 to
"fix" a cold-start issue — that just reintroduces the ~$75/mo idle cost this
was built to remove; fix the wake ping or the client's wake-timeout instead.

Voice model (LOCKED in `config.py`): with `GEMINI_LIVE_USE_DEV_API=true` the
worker runs **`gemini-3.8-live`** via the Gemini Developer API (rollback:
`GEMINI_LIVE_DEV_MODEL=gemini-3.1-flash-live-preview`, the legacy preview) —
Vertex has no Live 3.x, and that API only authenticates with a key, so
`GOOGLE_API_KEY` is mounted from Secret Manager. Set the flag `false` to fall
back to Vertex **`gemini-live-2.5-flash-native-audio`** (`us-central1`), which
needs no key. Either way, all text / matchmaking / embedding calls stay keyless
on Vertex — only this one model is on the keyed path.

Secrets: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` (also mint the Inference
gateway JWT), `GOOGLE_API_KEY`, `SENTRY_DSN_AGENT` (Secret Manager, mounted at
deploy).

## Tests

`.venv-agent` + `pytest tests/test_agent.py tests/test_voice_hot_swap.py
tests/test_inference_routing.py` — model config (Vertex, Dev-API and Inference
branches), room seed parsing (incl. `voice_name`), transcript relay, hot voice
swap, end-of-call flush. All offline.

**On-device round-trip verified** (2026-08-30, Pixel 10 Pro Fold, debug build,
`ayma-agent-00018-wdr` on Live 3.1): mic → Gemini Live → Ayma replies in audio,
`user_transcript` / `agent_transcript` both flowing, seeded chat context
carried into the call. The headless `scripts/voice_pipeline_e2e.py` covers the
same path without a device.

## Verifying a deploy

```
gcloud run services logs read ayma-agent --region us-central1 --project ayma-ai --limit 50
```

Look for `registered worker` against the LiveKit URL. With `min-instances 0`
the container only runs when woken (a real voice-call attempt, or manually via
`curl` with an ID token — see `agent_wake.py`), so tail logs during/right
after an on-device voice test rather than expecting a steady-state worker.
