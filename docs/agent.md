# Agent worker (`ayma-agent`)

The LiveKit voice worker — a **separate** Cloud Run service from the Main API
(§10.1). Same source tree (`functions/bootstrap/`), different image: it pulls
`livekit-agents` + `livekit-plugins-google`, which need `google-genai >= 2.13`,
while the Main API pins `google-genai == 1.14`. Hence `Dockerfile.agent` /
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
- On shutdown, writes the full interleaved turn window to
  `users/{uid}/raw_turns/{session_id}` via the Admin SDK.

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

Secrets: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `GOOGLE_API_KEY` (Secret
Manager, mounted at deploy).

## Tests

`.venv-agent` + `pytest tests/test_agent.py` (15 tests) — model config (Vertex
+ Dev-API branches), room seed parsing (incl. `voice_name`), transcript relay,
shutdown persistence. All offline.

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
