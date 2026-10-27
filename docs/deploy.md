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
| `SENTRY_DSN_API` / `SENTRY_DSN_AGENT` | ayma-api / ayma-agent | Sentry project DSNs, mounted as `SENTRY_DSN` (`monitoring.py`). Provisioned 2026-10-23 and mounted on both services (`SENTRY_DSN_FLUTTER` holds the app's DSN, read by `scripts/build-apk.sh`); a missing secret fails the revision. Unset `SENTRY_DSN` = Sentry fully off. Optional env: `SENTRY_TRACES_SAMPLE_RATE` (0.05), `SENTRY_ERROR_SAMPLE_RATE` (1.0), `SENTRY_ENVIRONMENT` (production); the kill switch is the `sentry` feature flag (`docs/FEATURE_FLAGS.md`; `SENTRY_ENABLED` is only its code default) |
| `DEV_PANEL_PASSWORD` | ayma-api | Password for `POST /dev/verify` (unlock the app's Developer panel contents) and `POST /dev/flags` (switch the `dev_panel` AI-notes flag). Compared server-side in constant time, never logged; unset = both refused (503) |
| `REVENUECAT_WEBHOOK_SECRET` | ayma-api | Shared secret RevenueCat sends in the `Authorization` header of `POST /webhooks/revenuecat` (mounted by `scripts/deploy-api.sh --full`; the endpoint returns 403 to everything without it). Put the same value in the RevenueCat webhook config. Plans: free ($5 one-time start grant = 500 credits, then 100 credits/day UTC, no rollover), `ayma_plus_monthly` (700 credits), `ayma_pro_monthly` (1400), `ayma_max_monthly` (8000); 1 credit = $0.01 of token cost (`CREDITS_PER_USD`) |
| `INSTAGRAM_APP_SECRET` | ayma-api | Meta app secret (§8.6). Placeholder until an Instagram app is registered (V2). `instagram/*` returns 404 while the `meta_integrations` flag is off, and 503 while `INSTAGRAM_APP_ID` is unset |
| `GOOGLE_API_KEY` | ayma-agent | Gemini Developer API key. Voice runs `gemini-3.8-live`, which is Developer-API-only (Vertex has no Live 3.x) and only authenticates with a key. Gated by `GEMINI_LIVE_USE_DEV_API=true`; set it `false` to fall back to Vertex `gemini-live-2.5-flash-native-audio` and this secret is unused. |

All Vertex calls (both services) use the Cloud Run runtime service identity
(`USE_VERTEX=true`) — **no key**. On `all-features-on`, JSON/vision/chat/voice
default to LiveKit Inference instead (`docs/ARCHITECTURE.md` section 0), which
authenticates with a short-lived JWT minted from `LIVEKIT_API_KEY`/`_SECRET`. The
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

### Shareable report links (`justabot.info`)

Users share web-research / Match reports as
`https://justabot.info/s/<token>` (`SHARE_BASE_URL`). **`justabot.info` must be
mapped to the `ayma-api` Cloud Run service** (Cloud Run domain mapping, or a
load balancer / proxy that forwards at least `/s/*` and `/.well-known/assetlinks.json`
to `ayma-api`), otherwise the links 404. Public routes (no auth, rate-limited by
`RATE_SHARE_PUBLIC`): `GET /s/{token}` (HTML + Open Graph tags),
`/s/{token}/card.png?format=link|story`, `/s/{token}/data` (app deep-link view).
Appearance is shared as an on-device image card (rendered locally, 1080x1920 PNG),
with a caption that carries the free **smart link** `https://justabot.info/get`
(static Firebase Hosting page, not Cloud Run — see `docs/SMART_LINK.md` and
`public/get.html`). See also `docs/ARCHITECTURE.md` section 0.

Config (env on `ayma-api`, none secret): `SHARE_BASE_URL` (default
`https://justabot.info`), `SHARE_ANDROID_STORE_URL`, `SHARE_IOS_STORE_URL`
(empty hides the button), `SHARE_ANDROID_PACKAGE`, and
`SHARE_ASSETLINKS_SHA256` (comma-separated signing-cert SHA-256 fingerprints,
including the Play App Signing cert) which drives
`/.well-known/assetlinks.json` so Android opens `/s/*` links in the app. iOS
universal links additionally need the `applinks:justabot.info` associated
domain on the App ID and an `apple-app-site-association` file served from
`justabot.info` (not yet implemented).

### Referral landing page (`/r/<CODE>`)

Invite links are `https://ayma-ai.web.app/r/<CODE>`. `firebase.json` rewrites
`/r/**` to the `ayma-api` Cloud Run service (`referral_page.py`), so deploy
hosting (`firebase deploy --only hosting`, part of `deploy-all.sh`) after
`ayma-api`. It serves the download page plus `/r/<CODE>/card.png` (the
og:image). Store buttons use `SHARE_ANDROID_STORE_URL` / `SHARE_IOS_STORE_URL`
(unset -> "coming soon"); the Play link carries
`&referrer=ayma_ref%3D<CODE>` for the install referrer.

## Agent Worker — `ayma-agent`

Split image (google-genai 2.x vs the API's 1.14 pin). Build then deploy:

```
cd functions/bootstrap
gcloud builds submit --project ayma-ai --config cloudbuild.agent.yaml .
gcloud run deploy ayma-agent --project ayma-ai --region us-central1 \
  --image us-central1-docker.pkg.dev/ayma-ai/cloud-run-source-deploy/ayma-agent:latest \
  --no-allow-unauthenticated --min-instances 0 --no-cpu-throttling --cpu-boost --memory 2Gi --timeout 3600 \
  --set-env-vars "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud,AYMA_AGENT_URL=https://ayma-agent-4qy2nxz2aa-uc.a.run.app,USE_VERTEX=true,VERTEX_LOCATION=us-central1,GOOGLE_CLOUD_PROJECT=ayma-ai,GEMINI_LIVE_USE_DEV_API=true" \
  --set-secrets "LIVEKIT_API_KEY=LIVEKIT_API_KEY:latest,LIVEKIT_API_SECRET=LIVEKIT_API_SECRET:latest,GOOGLE_API_KEY=GOOGLE_API_KEY:latest"
```

Model ids + Vertex locations are LOCKED in `functions/bootstrap/config.py`
(the "LOCKED MODELS" block) and are no longer set as env vars — `config.py` is
the single source of truth. `scripts/deploy-agent.sh` is the maintained form of
the command above.

`--no-cpu-throttling` is required regardless of scale — a request-CPU-only
instance never finishes LiveKit worker registration, because that
registration happens in a background asyncio task outside any HTTP
request/response cycle (the thing CPU throttling gates). `--cpu-boost` speeds
up the cold-start path itself (extra CPU during container startup/import).
`min-instances 0` is the **permanent intended config** (2026-09-19 founder
decision, below) — not a pre-release stopgap.

## Cloud Run scale config (§12.2)

| Service | min-instances | CPU | memory | max | Verified |
|---|---|---|---|---|---|
| `ayma-api` | 0 (scales to zero) | default (request-time throttling) | 512Mi | 4 | Step 70 — `minScale` annotation absent ⇒ 0 |
| `ayma-agent` | **0** (permanent, 2026-09-19) | `--no-cpu-throttling --cpu-boost`, `--timeout 3600` | 2Gi | 20 | 2026-09-19 — see below; 2026-10-25 live: timeout still 300 s, concurrency 80, no `AYMA_AGENT_URL` until the next `--full` deploy |

**Mid-call scale-down (2026-10-26):** a LiveKit call is not HTTP traffic,
so Cloud Run could SIGTERM a scale-to-zero instance in the middle of a call
(it did, 15 s into a founder call). Each active call now holds a
`/keepalive` request against the service's own URL for its whole length
(`agent_keepalive.py`, `docs/agent.md`), which needs `--timeout 3600` and
`AYMA_AGENT_URL` on the service: deploy once with `scripts/deploy-agent.sh
--full`. No fixed cost: still `min-instances 0`. Cloud Run's 10 s
SIGTERM-to-SIGKILL grace is fixed, so draining cannot save a call; the
keep-alive prevents the SIGTERM instead.

**History, so a future session doesn't re-litigate this:** the agent ran
`min-instances: 0` through Steps 13–71. Step 72 (2026-08-30) flipped it to
`min-instances: 1`, always-warm, to eliminate voice cold starts before
launch. On 2026-09-13 a plain redeploy silently dropped that flip back to 0
and voice broke completely — not because a cold start was too slow, but
because **nothing ever woke the container**: `/bootstrap` and
`/welcome/token` talk directly to LiveKit Cloud (mint a token, create the
room); they never sent ayma-agent's own Cloud Run URL any HTTP traffic, and
Cloud Run only starts an instance in response to traffic hitting its own
URL. LiveKit's automatic dispatch is a push to whichever workers are
*already* registered — with none registered, the room's agent job had
nothing to go to. The fix at the time was to stay always-warm
(`--release`) and never let `min-instances` drop again (see the
`ayma-agent-needs-release-flag` memory note from that incident).

**2026-09-19: the founder deliberately reversed this tradeoff** — always-warm
costs ~$75/mo in idle 1 vCPU + 2GB compute, the dominant line item in GCP
spend, to save a cold-start delay on a low-traffic pre-launch app. `ayma-agent`
is now `min-instances: 0` **permanently** — this is the *correct*, intended
state, not a regression to watch for. What changed so scale-to-zero actually
works this time: `/bootstrap` and `/welcome/token` now fire an authenticated
"wake" ping at ayma-agent's own URL the instant a voice call starts
(`functions/bootstrap/agent_wake.py`, `AYMA_AGENT_URL` env var on `ayma-api`)
— that HTTP request is what makes Cloud Run cold-start the container, running
in parallel with the LiveKit token mint + room creation rather than after it.
The Flutter client already expected this (`VoiceSessionController`'s
`waking` phase / `_wakingTimeout`, ~25s, and a "Waking Ayma…" status label)
even before this deploy config caught up to it.

**Deploying `ayma-agent`:** just run `scripts/deploy-agent.sh` (or
`--full`/`--release` to also refresh env vars/secrets) — no flag is needed to
get scale-to-zero, it's the default now. `--release` is kept only as an alias
for `--full`; it no longer flips `min-instances`. If you ever need to force it
warm temporarily (e.g. a live demo), that's a manual, deliberate
`gcloud run services update ayma-agent --min-instances 1`, not a deploy-script
flag — don't add one back without updating this doc, `agent_wake.py`, and the
client timeout accordingly.

## Firestore rules & indexes

```
firebase deploy --only firestore:rules --project ayma-ai
firebase deploy --only firestore:indexes --project ayma-ai
```

Deploy rules whenever the client-writable `profile/main` field list changes;
until then those writes are denied (e.g. the AI Avatar toggle flipping back).
Rules tests (Firestore emulator): `cd scripts/rules_tests && npm install && npm test`.

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

## Sentry in the Flutter app

Sentry runs alongside Firebase Crashlytics (both stay on). It is enabled only
when the build is given the DSN (`scripts/build-apk.sh` reads `SENTRY_DSN_FLUTTER`
from Secret Manager) and the cached `app_config/sentry` flag is not a literal
`false`; without the DSN the app behaves as before:

```
flutter build appbundle --dart-define=SENTRY_DSN=<flutter project DSN>
```

Release is auto-set to `<package>@<version>+<build>` from `pubspec.yaml`.
No PII, screenshots or request bodies are sent.

## Testing subscriptions with the RevenueCat Test Store

Simulated purchases, no real money. In the RevenueCat dashboard create a Test
Store app, add products `ayma_plus_monthly`, `ayma_pro_monthly`,
`ayma_max_monthly`, attach them as packages to the `default` offering, and
copy the Test Store **public SDK key**. Build a **debug** APK with it: the
app honours the test key only in debug builds (the RevenueCat SDK closes the app
when a Test Store key runs in a release/profile build), and a release/profile
build given only the test key throws at startup. Store builds take
`REVENUECAT_ANDROID_KEY` / `REVENUECAT_IOS_KEY` (Codemagic fails the build if unset):

```
flutter build apk --debug --dart-define=REVENUECAT_TEST_KEY=<test store public key> \
  --dart-define=AYMA_API_BASE_URL=...
```

Test Store purchases send webhooks with `environment: SANDBOX`; the backend
handles them like production events (idempotent on `event.id`, `app_user_id`
= Firebase uid). Point the RevenueCat webhook at
`https://<ayma-api>/webhooks/revenuecat` with the `REVENUECAT_WEBHOOK_SECRET`
value as the Authorization header (see the secrets table; without it the
endpoint returns 403). The app maps `default` packages by product id
(`ayma_*_monthly`, any `:base-plan` suffix ignored) and falls back to the
static plan list if one is missing.
