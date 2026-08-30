# Ayma Main API (`functions/bootstrap`)

FastAPI service deployed to Cloud Run (`docs/ARCHITECTURE.md` §10.1). This
directory also holds the **LiveKit voice agent worker** (`agent.py`) — a second,
separate Cloud Run deployable (§10.1) built from the same source tree so it can
share `config.py` / `persona.md` / `prompt.py`. The two ship as two images:
`livekit-plugins-google` needs `google-genai>=2.13`, which conflicts with the
Main API's pinned `google-genai==1.14.0`.

## Local

```bash
cd functions/bootstrap
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn main:app --reload --port 8080
curl localhost:8080/health          # {"status":"ok","service":"ayma-api",...}
pytest
```

`main.py` loads `../../.env.local` on startup (skipped under pytest). Deployed,
config comes from Cloud Run env vars / mounted secrets — there is no `.env` file
in the image.

## Deploy

```bash
gcloud run deploy ayma-api \
  --source functions/bootstrap \
  --region us-central1 \
  --project ayma-ai \
  --allow-unauthenticated \
  --update-env-vars "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud" \
  --update-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest"
```

`--allow-unauthenticated` is temporary for Step 1; the ID-token middleware
(§10.4) and a locked-down deploy come in a later step.

`LIVEKIT_URL` is non-secret config (a public `wss://` endpoint) so it rides as a
plain env var per §12.3. `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` are Secret
Manager secrets (created during Step 12), mounted at deploy time — never plain
env vars. The full Secret Manager migration for every remaining credential is
Step 69. Locally these three come from the gitignored `../../.env.local`.

## Voice agent worker (`agent.py`)

```bash
cd functions/bootstrap
python -m venv .venv-agent && source .venv-agent/bin/activate
pip install -r requirements-agent.txt pytest
python agent.py start          # connects to LiveKit Cloud, waits for dispatch
pytest tests/test_agent.py     # skipped automatically under the Main API venv
```

Deploy (own Cloud Run service, `Dockerfile.agent` via Cloud Build):

```bash
gcloud builds submit --project ayma-ai --config cloudbuild.agent.yaml .

gcloud run deploy ayma-agent --project ayma-ai --region us-central1 \
  --image us-central1-docker.pkg.dev/ayma-ai/cloud-run-source-deploy/ayma-agent:latest \
  --no-allow-unauthenticated --min-instances 0 --no-cpu-throttling \
  --memory 2Gi --cpu 1 \
  --update-env-vars "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=ayma-ai,GEMINI_LIVE_MODEL=gemini-live-2.5-flash,GEMINI_LIVE_VOICE=Aoede" \
  --update-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest"
```

`--no-cpu-throttling` is **required** for the worker to keep its outbound
LiveKit connection alive between jobs (§10.1) — with default (request-only) CPU
the worker never finishes registering. §12.2's pre-release row lists "default
CPU"; that entry can't run a worker, so always-on CPU is applied now while
`min-instances` stays `0` per the cost posture there. Step 72 still owns the
`min-instances: 1` production flip. `2Gi` memory: the plugin stack + one forked
job process OOMs the 512Mi default.
