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
  --allow-unauthenticated
```

`--allow-unauthenticated` is temporary for Step 1; the ID-token middleware
(§10.4) and a locked-down deploy come in a later step.
