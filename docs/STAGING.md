# Staging backend config

Staging mirrors prod (`docs/deploy.md`, `scripts/deploy-api.sh`,
`scripts/deploy-agent.sh`): same GCP project (`ayma-ai`) and region
(`us-central1`), two Cloud Run services, `min-instances 0` on both.

| Staging service | Mirrors prod | Build |
|---|---|---|
| `ayma-api-staging` | `ayma-api` | `--source functions/bootstrap` (same) |
| `ayma-agent-staging` | `ayma-agent` | `Dockerfile.agent`, tagged `:staging` (prod uses `:latest`) |

Deploy: `scripts/deploy-staging.sh --check`, then
`scripts/deploy-staging.sh --full` (first time) or bare for code-only.
Execution commands + pre-flight: `docs/agents/handoffs/staging-deploy-prep.md`.

## Secrets (all mounted from Secret Manager, never plaintext)

| Env name | Secret mounted | Staging-specific or shared? | Notes |
|---|---|---|---|
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | same prod secrets | **Shared** | Same LiveKit Cloud project; staging rooms are namespaced by `LIVEKIT_ROOM_PREFIX=ayma-staging-` instead |
| `CRON_SECRET` | `CRON_SECRET_STAGING` | **Staging-only** | Must differ from prod so a leaked staging value can't hit prod `/cron/*` |
| `ADMIN_PASSWORD` | `ADMIN_PASSWORD_STAGING` | **Staging-only** | |
| `DEV_PANEL_PASSWORD` | `DEV_PANEL_PASSWORD_STAGING` | **Staging-only** | |
| `REVENUECAT_WEBHOOK_SECRET` | `REVENUECAT_WEBHOOK_SECRET_STAGING` | **Staging-only** | Point a separate RevenueCat webhook (test store) at staging |
| `GOOGLE_IMPORT_CLIENT_SECRET` | same prod secret | **Shared** | Same Google OAuth client; staging's redirect URI must be registered on it (the deploy script prints it) |
| `INSTAGRAM_APP_SECRET` | same prod secret | **Shared** | Placeholder (V2), same as prod |
| `GOOGLE_API_KEY` (agent) | same prod secret | **Shared** | Same Gemini Developer API key; voice usage bills the same key |
| `SENTRY_DSN` | *(not mounted)* | **n/a — Sentry OFF** | Unset = Sentry fully off (same rule as prod). To enable: create `SENTRY_DSN_API_STAGING` / `SENTRY_DSN_AGENT_STAGING` secrets and add mounts; `SENTRY_ENVIRONMENT=staging` is already set |

Each new `*_STAGING` secret needs the same `secretAccessor` IAM grant for the
Cloud Run runtime service account as prod (`docs/deploy.md` §Secrets), or the
revision fails to start.

## Plain env vars (non-secret, set by `--full`)

| Var | Staging value | Staging-specific or shared? |
|---|---|---|
| `GOOGLE_CLOUD_PROJECT` | `ayma-ai`, or `--firebase-project` value | **Configurable** (default = shared/prod) |
| `STORAGE_BUCKET` | `<data-project>.firebasestorage.app` | **Follows data project** |
| `AYMA_AGENT_URL` (both services) | `ayma-agent-staging` Cloud Run URL | **Staging-only** (resolved pass 2) |
| `GOOGLE_IMPORT_REDIRECT_URI` | `<staging-api-URL>/google/oauth-complete` | **Staging-only** (resolved pass 2) |
| `LIVEKIT_ROOM_PREFIX` | `ayma-staging-` | **Staging-only** (prod default `ayma-`) |
| `SENTRY_ENVIRONMENT` | `staging` | **Staging-only** (prod default `production`) |
| `USE_VERTEX`, `VERTEX_LOCATION` | `true`, `us-central1` | Shared (same as prod) |
| `LIVEKIT_URL`, `LIVEKIT_PROJECT_ID` | same LiveKit Cloud project | Shared |
| `GOOGLE_IMPORT_CLIENT_ID` | same OAuth client id | Shared (public value, same as prod) |
| `CONTEXT_OPT_LEVEL`, `CONTEXT_OPT_MEASURE` | `3`, `true` | Shared (same as prod) |
| `GEMINI_LIVE_USE_DEV_API` (agent) | `true` | Shared (same as prod) |
| `IMAGE_VARIANTS_ENABLED` (api) | `true` | **Staging-only** — cloud profile-photo variants (Perf Phase 2 PREP chunk A); set only when the data plane is `ayma-staging` (see `docs/perf/image-variants.md`); unset everywhere else (fail closed) |
| `IMAGE_VARIANTS_PUSH_SA` (api) | `pubsub-push-invoker@ayma-staging.iam.gserviceaccount.com` | **Staging-only** — Pub/Sub push OIDC identity pinned by the variant endpoint |
| `OPEN_WEIGHTS_BASE_URL` (api) | Modal `…/v1` endpoint | **Staging-only** — wires the open-weights cheap path (hackathon); routes **nothing** on its own (a surface reaches it only when its `LLM_PROVIDER_*` flag is `open-weights`; default stays `gemini`). Credit-guarded — see `scripts/modal_open_weights.py` |

Model ids / voices / Vertex locations stay locked in
`functions/bootstrap/config.py` — never env vars, same as prod. `LLM_PROVIDER`
is untouched: Gemini remains the default everywhere.

Everything else the code reads (`RATE_*`, credit/economy tunables,
`SHARE_*`, `REENGAGE_*`, voice timeouts, `IMAGE_SEARCH_*`,
`REVENUECAT_SECRET_API_KEY`, …) keeps its code default on staging exactly as
on prod — the prod scripts don't set them either.

## Staging phone build (both axes)

A phone build must match the staging backend on **two** axes or auth breaks: the
app signs into Firebase with the Dart config in `firebase_options.dart`
(`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`), and
it calls the API at `AYMA_API_BASE_URL` (`env.dart`). If Firebase stays prod
(`ayma-ai`) while the API points at staging, the app mints a **prod** ID token
that the staging backend rejects → history load fails, long cold start, error
block. (Root cause of the 4264706 build failure, 2026-11-01.)

Build a correct staging phone APK with:

    scripts/build-apk.sh --debug --staging

`--staging` (dev builds only) does both axes from one committed source of truth,
`ayma_flutter/android/app/google-services.staging.json` (the ayma-staging
Android app, package `com.ayma.ayma_flutter`, public client config — not a
secret):
- swaps that file in as the native `google-services.json` for the build
  (restored afterwards via an EXIT trap), and
- injects the matching `--dart-define`s: `AYMA_API_BASE_URL=<staging api>` plus
  `FB_PROJECT_ID`, `FB_MESSAGING_SENDER_ID`, `FB_STORAGE_BUCKET`,
  `FB_ANDROID_APP_ID`, `FB_ANDROID_API_KEY` (read from that JSON), which
  `firebase_options.dart` reads with prod defaults so prod/store builds are
  unchanged.

Verify the artifact before delivery: `strings`/`aapt dump` the APK must show
`ayma-staging` for the Firebase project **and** the staging API host, never
`ayma-ai`. **Standing rule (from the 4264706 failure): Scout bench-verifies the
exact staging artifact on the emulator — sign in, cold start, chat history, no
error block — before it is offered to the founder. No exceptions.**

## Data isolation

- **Default (no `--firebase-project`): staging shares prod Firestore/Auth/Storage.**
  Good enough for a deploy smoke test; do not run destructive tests this way.
- **Preferred: separate staging Firebase project** (pass `--firebase-project`).
  Then also: deploy firestore rules/indexes to it, and grant the Cloud Run
  runtime service account (`235381544962-compute@developer.gserviceaccount.com`,
  the same prod default compute SA) access in that project — it has **none** by
  default, so cross-project grants are required or every call is
  `PERMISSION_DENIED`. Roles granted for `ayma-staging`: `roles/datastore.user`
  (Firestore), `roles/storage.admin` (uploads bucket) and `roles/aiplatform.user`
  (Vertex Gemini runs under `GOOGLE_CLOUD_PROJECT`, so inference bills + auths in
  the data project). `firebase_admin` picks the project up from
  `GOOGLE_CLOUD_PROJECT` via ADC — verified 2026-11-01 with a service-mediated
  write probe (`POST /brain/preference` as demo-test1): the write landed in
  `ayma-staging` and prod `ayma-ai` was untouched.
- **Not staged (deliberately):** Cloud Scheduler jobs (no staging cron jobs —
  trigger `/cron/*` manually with the staging secret), Firebase Hosting
  rewrites, `justabot.info` domain mapping, RevenueCat production webhook.
