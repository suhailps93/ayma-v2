# Deploy runbook

Manual `gcloud` deploys, one Firebase/GCP project (`ayma-ai`, `us-central1`).
No CI/CD (§12.4). Two Cloud Run services: `ayma-api` (Main API) and
`ayma-agent` (LiveKit voice worker).

## Secrets (§12.3, Step 69)

Every credential lives in Google Secret Manager and is mounted into Cloud Run
at deploy time — never a plaintext env var. Non-secret config (model names,
region, project id, bucket, `LIVEKIT_URL`) stays as plain env vars per §12.3.

| Secret | Used by | Notes |
|---|---|---|
| `LIVEKIT_API_KEY` | ayma-api, ayma-agent | LiveKit Cloud project `aimma-wt34nu3l` |
| `LIVEKIT_API_SECRET` | ayma-api, ayma-agent | — |
| `CRON_SECRET` | ayma-api | `X-Cron-Secret` header for `/cron/*` (§10.5); also set on every Cloud Scheduler job |
| `ADMIN_PASSWORD` | ayma-api | `X-Admin-Password` for `/admin/*` (§14.3) |
| `INSTAGRAM_APP_SECRET` | ayma-api | Meta app secret (§8.6). Placeholder until an Instagram app is registered — `instagram/*` returns 503 while `INSTAGRAM_APP_ID` is unset |
| `GOOGLE_API_KEY` | ayma-agent | Gemini Developer API key. Voice runs `gemini-3.1-flash-live-preview`, which is Developer-API-only (Vertex has no Live 3.x) and only authenticates with a key. Gated by `GEMINI_LIVE_USE_DEV_API=true`; set it `false` to fall back to Vertex `gemini-live-2.5-flash-native-audio` and this secret is unused. |

All text, matchmaking and embedding calls (both services) use Vertex AI with
the Cloud Run runtime service identity (`USE_VERTEX=true`) — **no key**. The
only keyed path is the voice agent's Live 3.1 model above. Firebase Admin SDK
likewise uses the runtime identity, no key file.

Grant once per secret:

```
gcloud secrets add-iam-policy-binding <SECRET> --project ayma-ai \
  --member="serviceAccount:235381544962-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

Rotate a value:

```
printf '%s' "<new-value>" | gcloud secrets versions add <SECRET> \
  --project ayma-ai --data-file=-
# then redeploy the service(s) that mount it (":latest" picks up the new version)
```

## Main API — `ayma-api`

```
gcloud run deploy ayma-api \
  --source functions/bootstrap --region us-central1 --project ayma-ai \
  --allow-unauthenticated --min-instances 0 \
  --set-env-vars "USE_VERTEX=true,VERTEX_LOCATION=us-central1,GEMINI_MODEL=gemini-2.5-flash,GOOGLE_CLOUD_PROJECT=ayma-ai,LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,STORAGE_BUCKET=ayma-ai.firebasestorage.app" \
  --set-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,CRON_SECRET=CRON_SECRET:latest,ADMIN_PASSWORD=ADMIN_PASSWORD:latest,INSTAGRAM_APP_SECRET=INSTAGRAM_APP_SECRET:latest"
```

Day-to-day iteration keeps the existing env/secrets and just ships code:
`gcloud run deploy ayma-api --source functions/bootstrap --region us-central1 --project ayma-ai --allow-unauthenticated`.

## Agent Worker — `ayma-agent`

Split image (google-genai 2.x vs the API's 1.14 pin). Build then deploy:

```
cd functions/bootstrap
gcloud builds submit --project ayma-ai --config cloudbuild.agent.yaml .
gcloud run deploy ayma-agent --project ayma-ai --region us-central1 \
  --image us-central1-docker.pkg.dev/ayma-ai/cloud-run-source-deploy/ayma-agent:latest \
  --no-allow-unauthenticated --min-instances 0 --no-cpu-throttling --memory 2Gi \
  --set-env-vars "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=ayma-ai,GEMINI_LIVE_USE_DEV_API=true" \
  --set-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,GOOGLE_API_KEY=GOOGLE_API_KEY:latest"
```

Model ids + Vertex locations are LOCKED in `functions/bootstrap/config.py`
(the "LOCKED MODELS" block) and are no longer set as env vars — `config.py` is
the single source of truth. `scripts/deploy-agent.sh` is the maintained form of
the command above.

`--no-cpu-throttling` is required now — a request-CPU-only instance never
finishes LiveKit worker registration. `min-instances 0` holds until the
pre-release flip (Step 72).

## Cloud Run scale config (§12.2)

| Service | min-instances | CPU | memory | max | Verified |
|---|---|---|---|---|---|
| `ayma-api` | 0 (scales to zero) | default (request-time throttling) | 512Mi | 4 | Step 70 — `minScale` annotation absent ⇒ 0 |
| `ayma-agent` | **1** (pre-release flip, Step 72) | `--no-cpu-throttling` | 2Gi | 20 | Step 72 — logs show `registered worker`, always warm |

The agent ran `min-instances: 0` through Steps 13–71 (LiveKit worker only
connected while an instance was otherwise up). **Step 72** flipped it to
`min-instances: 1` (`scripts/deploy-agent.sh --release`, or
`gcloud run services update ayma-agent --min-instances 1 --no-cpu-throttling`)
so a worker is permanently registered with LiveKit and the first voice
connection has no cold start. To pause billing before real launch, set it back
to `--min-instances 0`.

## Firestore rules & indexes

```
firebase deploy --only firestore:rules --project ayma-ai
firebase deploy --only firestore:indexes --project ayma-ai
```

## Cloud Scheduler jobs

`ayma-cron-lint`, `ayma-cron-purge`, `ayma-cron-match`, `ayma-cron-reengage`,
`ayma-cron-persona-evolution` — each an HTTP POST to the matching `/cron/*`
route with the `X-Cron-Secret: <CRON_SECRET value>` header.

`ayma-cron-persona-evolution` (§15 Part B, daily crowd-feedback aggregation →
persona evolution) was created the same way as the others:

```
gcloud scheduler jobs create http ayma-cron-persona-evolution \
  --project ayma-ai --location us-central1 \
  --schedule "35 5 * * *" --time-zone "Etc/UTC" \
  --uri "https://ayma-api-235381544962.us-central1.run.app/cron/persona-evolution" \
  --http-method POST \
  --headers "X-Cron-Secret=<CRON_SECRET value>" \
  --attempt-deadline 900s
```

(schedule picked to land a few minutes after `ayma-cron-reengage`, so the
day's cron jobs don't all fire at once).
