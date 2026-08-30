# Agent worker (`ayma-agent`)

The LiveKit voice worker — a **separate** Cloud Run service from the Main API
(§10.1). Same source tree (`functions/bootstrap/`), different image: it pulls
`livekit-agents` + `livekit-plugins-google`, which need `google-genai >= 2.13`,
while the Main API pins `google-genai == 1.14`. Hence `Dockerfile.agent` /
`requirements-agent.txt` / `cloudbuild.agent.yaml` and a local `.venv-agent/`.

## What it does

- Registers as a LiveKit worker against `wss://aimma-wt34nu3l.livekit.cloud`.
- On a room dispatch (auto-dispatched when a client joins `ayma-<uid>`) it reads
  the room metadata `/bootstrap` left — system prompt, recent-turns window,
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
scripts/deploy-agent.sh --release  # --full + min-instances 1 (Step 72)
```

Config (§12.2): `--no-cpu-throttling --memory 2Gi`, `min-instances 0` until the
release flip. `--no-cpu-throttling` is mandatory now — a request-CPU-only
instance never completes worker registration (confirmed in logs, Step 13).

Secrets: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` (Secret Manager, mounted at
deploy). Gemini uses Vertex AI with the Cloud Run runtime identity — no key.

## Tests

`.venv-agent` + `pytest tests/test_agent.py` (14 tests) — model config, room
seed parsing (incl. `voice_name`), transcript relay, shutdown persistence. All
offline; a live audio round-trip needs a real client on a device.

## Verifying a deploy

```
gcloud run services logs read ayma-agent --region us-central1 --project ayma-ai --limit 50
```

Look for `registered worker` against the LiveKit URL. With `min-instances 0`
the container only runs when started, so tail logs during an on-device voice
test, or deploy with `--release` first.
