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

Model ids / voices / Vertex locations stay locked in
`functions/bootstrap/config.py` — never env vars, same as prod. `LLM_PROVIDER`
is untouched: Gemini remains the default everywhere.

Everything else the code reads (`RATE_*`, credit/economy tunables,
`SHARE_*`, `REENGAGE_*`, voice timeouts, `IMAGE_SEARCH_*`,
`REVENUECAT_SECRET_API_KEY`, …) keeps its code default on staging exactly as
on prod — the prod scripts don't set them either.

## Data isolation

- **Default (no `--firebase-project`): staging shares prod Firestore/Auth/Storage.**
  Good enough for a deploy smoke test; do not run destructive tests this way.
- **Preferred: separate staging Firebase project** (pass `--firebase-project`).
  Then also: deploy firestore rules/indexes to it, and grant the Cloud Run
  runtime service account datastore + storage access in that project.
  `firebase_admin` picks the project up from `GOOGLE_CLOUD_PROJECT` via ADC —
  verify with a write/read probe on first deploy (see handoff note).
- **Not staged (deliberately):** Cloud Scheduler jobs (no staging cron jobs —
  trigger `/cron/*` manually with the staging secret), Firebase Hosting
  rewrites, `justabot.info` domain mapping, RevenueCat production webhook.
