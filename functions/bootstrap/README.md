# Ayma Main API (`functions/bootstrap`)

FastAPI service deployed to Cloud Run (`docs/ARCHITECTURE.md` §10.1). Step 1 is
scaffolding only — one health-check route.

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
