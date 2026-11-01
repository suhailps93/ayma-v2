# Cloud image variants (Perf Phase 2 PREP chunk A) — STAGING ONLY

Founder directive (binding): all image compression / variant generation
happens **in the cloud, asynchronously after upload**. The client upload path
gains no compression step and no latency — users upload the original exactly
as today. This chunk changes **no user-visible behavior** and touches **no
client code**.

## How it works

1. Client uploads a profile photo to the staging bucket exactly as today.
2. A GCS `OBJECT_FINALIZE` notification (prefix `uploads/`, bucket
   `ayma-staging.firebasestorage.app` only) publishes to Pub/Sub topic
   `storage-image-finalized` (project `ayma-staging`).
3. A push subscription POSTs the envelope to
   `POST /internal/storage/image-finalized` on `ayma-api-staging` with a
   Pub/Sub-minted OIDC token.
4. `functions/bootstrap/image_variants.py` renders `thumb` + `medium`
   variants alongside the original. The original object is never modified.

Why this route (endpoint on the existing staging API + bucket
notification, rather than a new Cloud Function): the staging data project
(`ayma-staging`) has no Cloud Run / Functions / Eventarc APIs — it is a
data-plane project — while the staging API service already ships Pillow,
cron-auth conventions, and a staging deploy pipeline. No new service, no new
APIs, no new dependencies.

## Naming convention (contract for future client work)

Original: `uploads/{uid}/photo_169999_0.jpg`
Variants: `uploads/{uid}/photo_169999_0__thumb_400.jpg`
          `uploads/{uid}/photo_169999_0__medium_1080.jpg`

- `{stem}__{spec}_{width}px{ext}` in the **same directory** as the original.
- `thumb` = 400px wide (JPEG q82), `medium` = 1080px wide (JPEG q85).
- `ext` follows the output encoding: JPEG/PNG/WebP sources keep their
  format; anything else normalises to `.jpg` (transparency flattened on
  white). Variants are orientation-normalised (EXIF transposed) and
  EXIF-stripped. Never upscaled.
- In scope: single-level `uploads/{uid}/` basenames starting with
  `profile_`, `photo_` or `ig_*` (`ig_` = IG imports, which land on the
  profile grid). Out of scope: `chat_*`, `dm/...`, `verification/...`.
- Variant blobs carry metadata `variant_of=<source md5>` +
  `variant_spec=<spec>_<width>` for idempotent re-runs. Variants inherit the
  `uploads/{uid}/` storage rules (owner-only read) automatically.

## Fallback contract

Variants are **optional**. Surfaces use the original URL until the variant
exists; a missing variant is never an error. Generation is skipped (original
kept) for: non-images, undecodable bytes, originals narrower than the target
width, objects > 25MB, non-profile paths, and variant objects themselves
(loop guard — variant writes emit `OBJECT_FINALIZE` too).

## Endpoints (code: `image_variants.py`, routes in `main.py`)

- `POST /internal/storage/image-finalized` — Pub/Sub push target. Staging
  gating (all fail closed): `IMAGE_VARIANTS_ENABLED=true`, OIDC token whose
  `email` == `IMAGE_VARIANTS_PUSH_SA`, envelope bucket ==
  `CONFIG.storage_bucket`. Skips → 200 (ack); transient GCS failures → 500
  (redeliver; idempotent).
- `POST /cron/image-variants-backfill?prefix=uploads/&limit=200` —
  `X-Cron-Secret` authed manual backfill (no staging cron jobs per
  `docs/STAGING.md`). Prefix must stay under `uploads/`; limit 1..1000.

## Staging-only env (set on `ayma-api-staging`, never prod)

- `IMAGE_VARIANTS_ENABLED=true`
- `IMAGE_VARIANTS_PUSH_SA=pubsub-push-invoker@ayma-staging.iam.gserviceaccount.com`

Both are baked into `scripts/deploy-staging.sh` (`API_ENV_BASE`) so `--full`
preserves them. With the flag unset (prod, local dev) both routes refuse and
the code is inert.

## Cloud wiring (all staging-scoped; project `ayma-staging` unless noted)

Recreate with (names are the live ones):

```bash
PROJECT=ayma-staging
TOPIC=storage-image-finalized
BUCKET=ayma-staging.firebasestorage.app
PUSH_SA=pubsub-push-invoker@ayma-staging.iam.gserviceaccount.com
PUSH_URL=https://ayma-api-staging-235381544962.us-central1.run.app/internal/storage/image-finalized

gcloud pubsub topics create $TOPIC --project=$PROJECT
# Let GCS publish object notifications to the topic:
gcloud pubsub topics add-iam-policy-binding $TOPIC --project=$PROJECT \
  --member=serviceAccount:service-187469876115@gs-project-accounts.iam.gserviceaccount.com \
  --role=roles/pubsub.publisher
gcloud storage buckets notifications create gs://$BUCKET \
  --project=$PROJECT --topic=$TOPIC \
  --event-types=OBJECT_FINALIZE --object-name-prefix=uploads/ \
  --payload-format=json
gcloud pubsub subscriptions create storage-image-finalized-push --project=$PROJECT \
  --topic=$TOPIC --push-endpoint=$PUSH_URL \
  --push-auth-service-account=$PUSH_SA --ack-deadline=60
```

Teardown (end of staging experiment, if ever): delete the subscription,
notification config, and topic; unset the two env vars on
`ayma-api-staging`. Variant objects are inert data (same-tree, owner-read)
and surfaces fall back to originals, so no cleanup is strictly required.

## Verify

```bash
# Upload a test photo, wait ~30s, confirm thumb+medium, original untouched:
gcloud storage cp photo.jpg gs://ayma-staging.firebasestorage.app/uploads/<uid>/profile_verify_<ts>.jpg --project=ayma-staging
gcloud storage ls gs://ayma-staging.firebasestorage.app/uploads/<uid>/ --project=ayma-staging
# Manual backfill path:
curl -XPOST 'https://ayma-api-staging-235381544962.us-central1.run.app/cron/image-variants-backfill?prefix=uploads/<uid>/&limit=10' \
  -H "X-Cron-Secret: $(gcloud secrets versions access latest --secret=CRON_SECRET_STAGING --project=ayma-ai)"
```

`*` `ig_` detail: `functions/bootstrap/instagram.py` writes
`uploads/{uid}/ig_{mid}.jpg` through the same §8.5 profile pipeline.
