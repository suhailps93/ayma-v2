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

Gemini needs **no** key secret — both services use Vertex AI with the Cloud Run
runtime service identity (`USE_VERTEX=true`). Firebase Admin SDK likewise uses
the runtime identity, no key file.

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
  --set-env-vars "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=ayma-ai,GEMINI_LIVE_MODEL=gemini-live-2.5-flash,GEMINI_LIVE_VOICE=Aoede" \
  --set-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest"
```

`--no-cpu-throttling` is required now — a request-CPU-only instance never
finishes LiveKit worker registration. `min-instances 0` holds until the
pre-release flip (Step 72).

## Cloud Run scale config (§12.2)

| Service | min-instances | CPU | memory | max | Verified |
|---|---|---|---|---|---|
| `ayma-api` | 0 (scales to zero) | default (request-time throttling) | 512Mi | 4 | Step 70 — `minScale` annotation absent ⇒ 0 |
| `ayma-agent` | 0 | `--no-cpu-throttling` (deviation, Step 13 — a request-CPU-only instance never finishes LiveKit worker registration) | 2Gi | 20 | Step 70 |

At release (Step 72) the agent flips to `min-instances: 1` so a worker is always
connected to LiveKit and there is no cold-start on the first voice connection.
Until then the agent only runs when an instance is otherwise started, so live
voice sessions are exercised on-device with the Step 72 config.

## Firestore rules & indexes

```
firebase deploy --only firestore:rules --project ayma-ai
firebase deploy --only firestore:indexes --project ayma-ai
```

## Cloud Scheduler jobs

`ayma-cron-lint`, `ayma-cron-purge`, `ayma-cron-match`, `ayma-cron-reengage` —
each an HTTP POST to the matching `/cron/*` route with the
`X-Cron-Secret: <CRON_SECRET value>` header.
