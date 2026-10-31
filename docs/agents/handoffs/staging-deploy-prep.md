# Handoff: staging-deploy-prep (from Muse)

## What was done

Prepared (did NOT execute) the staging backend deployment. Surveyed how prod
deploys today — `scripts/deploy-api.sh`, `scripts/deploy-agent.sh`,
`scripts/deploy-all.sh`, `functions/bootstrap/cloudbuild.agent.yaml`,
`Dockerfile` / `Dockerfile.agent`, `docs/deploy.md`, and every `os.getenv`
in `functions/bootstrap/*.py` — and mirrored it. The repo HAS deploy tooling,
so the staging script follows the prod scripts' conventions (`--full` for
env/secrets, code-only default, secrets from Secret Manager, models locked in
`config.py`).

## Files changed

- `scripts/deploy-staging.sh` (new, executable) — creates/updates
  `ayma-api-staging` (`--source`, like prod) and `ayma-agent-staging`
  (`Dockerfile.agent` image tagged `:staging`). Same project/region as prod
  (`ayma-ai` / `us-central1`), `min-instances 0` both. Flags: `--full`,
  `--check` (pre-flight only), `--api-only` / `--agent-only`,
  `--firebase-project ID` (default unset = shares prod data project).
- `docs/STAGING.md` (new) — full env var / secret matrix: staging-specific
  vs shared, data-isolation notes, what's deliberately not staged.
- `docs/agents/handoffs/staging-deploy-prep.md` (this file).

No prod files touched. No `LLM_PROVIDER` changes (Gemini default untouched).
No `gcloud` commands run; nothing deployed.

## Tests run and results

- `bash -n scripts/deploy-staging.sh` — passes (syntax).
- `scripts/deploy-staging.sh --help` — prints usage correctly.
- Flag-parse self-test (`--api-only --agent-only` → error; `--firebase-project`
  without value → error; unknown flag → error) — all behave.
- Verified secret/env lists against prod scripts + `docs/deploy.md` + a full
  `os.getenv` sweep of `functions/bootstrap/*.py` — every prod-set var is
  accounted for in `docs/STAGING.md`; code-defaulted tunables (`RATE_*`, etc.)
  intentionally unset, same as prod.
- NOT run (forbidden by task): `--check` and any deploy — both invoke `gcloud`.

## What remains (Astro executes)

### 0. One-time setup (before first deploy)

```bash
# Staging-only secrets (values MUST differ from prod):
printf '%s' "<new-random-value>" | gcloud secrets create CRON_SECRET_STAGING --project ayma-ai --data-file=-
printf '%s' "<new-random-value>" | gcloud secrets create ADMIN_PASSWORD_STAGING --project ayma-ai --data-file=-
printf '%s' "<new-random-value>" | gcloud secrets create DEV_PANEL_PASSWORD_STAGING --project ayma-ai --data-file=-
printf '%s' "<new-random-value>" | gcloud secrets create REVENUECAT_WEBHOOK_SECRET_STAGING --project ayma-ai --data-file=-

# secretAccessor grants (one per NEW secret; shared secrets already granted):
for s in CRON_SECRET_STAGING ADMIN_PASSWORD_STAGING DEV_PANEL_PASSWORD_STAGING REVENUECAT_WEBHOOK_SECRET_STAGING; do
  gcloud secrets add-iam-policy-binding "$s" --project ayma-ai \
    --member="serviceAccount:235381544962-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
done
```

Preferred: create a separate staging Firebase project first, then also run
`firebase deploy --only firestore:rules,firestore:indexes --project <staging-id>`
and grant the runtime service account datastore + storage access in it.

### 1. Pre-flight

```bash
scripts/deploy-staging.sh --check [--firebase-project <staging-id>]
```

Checks: all 4 staging-only + 5 shared secrets exist; prints the manual
checklist (IAM grants, OAuth redirect registration, no scheduler jobs).

### 2. Deploy

```bash
# First time (sets env + secrets, two-pass URL wiring):
scripts/deploy-staging.sh --full [--firebase-project <staging-id>]

# Later code-only redeploys (keeps env + secrets, like prod):
scripts/deploy-staging.sh
```

### 3. Post-deploy verification

1. Script prints `ACTION REQUIRED: register this redirect URI` — add
   `https://<ayma-api-staging-URL>/google/oauth-complete` as an authorized
   redirect URI on the Google OAuth client (same client as prod), or Google
   import on staging fails.
2. Smoke test: `curl https://<ayma-api-staging-URL>/` (or `/health` if
   present) → 200; confirm `min-instances 0` in console (`gcloud run
   services describe ayma-api-staging/ayma-agent-staging --region
   us-central1 --project ayma-ai`).
3. If `--firebase-project` was used: write/read probe record in staging
   Firestore via a staging API call, and confirm prod data untouched.
4. Optional voice check: start a call against staging; expect the "Waking
   Ayma…" cold start then join (wake ping uses staging `AYMA_AGENT_URL`).

### Known limitations / follow-ups

- Staging API is `--source`-built like prod, so only the agent image carries a
  `:staging` tag (Cloud Run controls the API build tags).
- Sentry is OFF on staging by default (no `SENTRY_DSN` mount). To enable:
  create `SENTRY_DSN_API_STAGING` / `SENTRY_DSN_AGENT_STAGING` and add mounts
  (`SENTRY_ENVIRONMENT=staging` is already set).
- No staging Cloud Scheduler jobs, hosting rewrites, or domain mappings —
  trigger staging `/cron/*` manually with the staging secret.
- LiveKit is shared with prod (one Cloud project); isolation is by room-name
  prefix (`ayma-staging-`). A separate LiveKit project is a future option.
