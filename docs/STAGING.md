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

## Prod → staging 1:1 data sync

`scripts/sync-prod-to-staging.sh` copies a **full 1:1 snapshot of production
(`ayma-ai`) into the staging data project (`ayma-staging`)** so staging holds
real accounts, profiles, conversations, photos and biometric data. Founder
decision 2026-11-01: a Full 1:1 copy.

> **⚠️ PRIVACY — read before touching this.** This pipeline **intentionally
> replicates real-user PII and biometric data** (profiles, conversations,
> uploaded photos, and the `verification/` face-biometric objects) into staging.
> That is the founder's explicit decision (2026-11-01), not an accident. Treat
> `ayma-staging` as holding production PII: same access discipline as prod, no
> wider sharing, no exports off these two projects.

### What it copies (three planes)

| Plane | Source (read-only) | Dest (writes) | Mechanism |
|---|---|---|---|
| **Firestore** | `ayma-ai` (default db) | `ayma-staging` (default db) | `gcloud firestore export` → staging-owned bucket → `gcloud firestore import`. Import is **overwrite-by-document-path (additive)** — any path present only in staging (e.g. staging-only `demo-*` / `demo-edge-*` docs absent from prod) is **left untouched**. |
| **Storage** | `gs://ayma-ai.firebasestorage.app` | `gs://ayma-staging.firebasestorage.app` | `gsutil -m rsync -r` (SOURCE → DEST). **No `-d`**, so the rsync is additive and never deletes staging-only objects. |
| **Auth users** | `ayma-ai` | `ayma-staging` | `firebase auth:export` → `firebase auth:import` with prod's **SCRYPT** hash params (algo/signer-key/salt-separator/rounds/mem-cost) read live from prod's Identity Platform config, so real passwords keep working. Import **upserts by uid**. |

The Firestore export lands in a dedicated **staging-owned** bucket
`gs://ayma-staging-prod-sync` (project `ayma-staging`, `us-central1`, 14-day
lifecycle) — prod's export data never lands in a prod bucket. The script
creates that bucket on first run and grants both projects' Firestore service
agents (`service-235381544962@…` prod, `service-187469876115@…` staging)
`roles/storage.admin` on it (IAM writes are on the staging bucket only).

### One-way guardrails (ironclad)

This pipeline is **one-way, prod → staging, ONLY.** It never runs an
import/write/rsync whose target is `ayma-ai` or `gs://ayma-ai*`. The only prod
operations are read-only: `firestore export`, `gsutil rsync` with prod as
SOURCE, and `auth:export`. The script:

- hardcodes `SRC_PROJECT=ayma-ai` (read-only) and `DEST_PROJECT=ayma-staging`
  (the only write target) as `readonly` constants;
- runs `assert_dest_is_staging` at startup **and** immediately before every
  destructive gcloud/gsutil/firebase call — it aborts (`FATAL`) if any
  write/import/dest/export target resolves to `*ayma-ai*`, or to anything that
  is not `*ayma-staging*`;
- echoes the resolved SOURCE and DEST at the top of every run.

The password **signer key is never hardcoded** (AGENTS.md rule) — it is fetched
at runtime from prod's Identity Platform config and redacted in all logs.

### Cadence

Runs **nightly at 02:00 local** via cron on this machine, serialized with
`flock` so a long run never overlaps the next, with output appended to
`~/workspace/ayma-inbox/prod-sync.log`. The installed `crontab -l` entry is:

    # Ayma prod->staging 1:1 data sync — nightly 02:00, one-way, flock-guarded (docs/STAGING.md)
    0 2 * * * /usr/bin/flock -n /tmp/ayma-prod-sync.lock /bin/bash -c '[ -x /home/suhailps/workspace/ayma/scripts/sync-prod-to-staging.sh ] && /home/suhailps/workspace/ayma/scripts/sync-prod-to-staging.sh --execute || echo "[$(date -u +\%Y-\%m-\%dT\%H:\%M:\%SZ)] prod-sync skipped: script not yet merged to canonical path"' >> /home/suhailps/workspace/ayma-inbox/prod-sync.log 2>&1

The `[ -x … ]` guard makes the job a **clean no-op until this branch is merged**
and the script reaches the canonical `scripts/` path — so the nightly cron does
not run the unreviewed script against real PII before the lead engineer merges
it. It auto-activates the first night after merge; no cron edit is needed then.

Do **not** raise the frequency above nightly without asking the founder.
(A Cloud Scheduler job is an alternative, but cron-on-this-machine is simpler
and keeps the one-way logic in one audited script.)

### How to run manually

    # DRY-RUN first (no writes; shows resolved SOURCE/DEST + what would copy):
    scripts/sync-prod-to-staging.sh --dry-run

    # Execute the real sync (idempotent, safe to re-run):
    scripts/sync-prod-to-staging.sh --execute

    # Limit to one plane while debugging:
    scripts/sync-prod-to-staging.sh --execute --skip-storage --skip-auth

Prerequisites: `gcloud`/`gsutil`/`firebase` authenticated as a principal with
read on `ayma-ai` and write on `ayma-staging`, and ADC quota project set (the
script sets `GOOGLE_CLOUD_QUOTA_PROJECT` per firebase call automatically).
