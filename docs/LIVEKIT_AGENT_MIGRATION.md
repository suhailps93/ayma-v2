# LiveKit Cloud Agents migration (ayma-agent → LiveKit Cloud)

> Status: **flagged, opt-in, default OFF.** Production voice is unchanged — it
> still runs on the Cloud Run `ayma-agent`. This runbook covers the dual-cloud
> design, how to deploy the LiveKit-hosted twin, the secrets/SA it needs, the
> dev toggle, and how to flip the default later. Branch: `meta-hackathon`.

## Why

`ayma-agent` is a `livekit-agents` worker. Hosting it on **LiveKit Cloud Agents**
(covered by our $10k LiveKit Cloud startup credit — agent session minutes, Scale
plan, 50k min/mo included) removes the Cloud Run wake-ping / keep-alive / cold-start
machinery (LiveKit manages dispatch and warm capacity). We migrate behind a flag so
we can A/B it per user before moving the default.

## The flag + dispatch design

A per-user preference `voice_agent_cloud` on `users/{uid}/profile/main`:

- `cloudrun` (**default**) — the room is created with NO explicit agent dispatch, so
  LiveKit's **automatic** dispatch hands it to the Cloud Run worker, exactly as today.
- `livekit` — `POST /bootstrap` creates the room with **explicit** dispatch to the
  agent name `ayma-lk` (`RoomConfiguration` / `RoomAgentDispatch`, via
  `seed_room_context(..., agent_name=CONFIG.agent_name_livekit)`), so the
  LiveKit-Cloud-hosted worker serves it.

### The contention guard (why the Cloud Run agent also changed)

LiveKit still offers **every** new room to an automatic-dispatch worker — including a
room explicitly routed to `ayma-lk`. Without a guard, both deployments would join a
`livekit` room and contend. So:

- Each room's seed metadata carries a `voice_agent_cloud` marker
  (`livekit_token.build_room_seed`).
- `agent.py` installs a `request_fnc` (`_request_fnc` → `_room_target_cloud`): a worker
  **accepts only** rooms whose marker matches its own runtime (`AGENT_RUNTIME`), and
  **declines** the rest. A room with no marker is treated as `cloudrun` (production
  unchanged). The guard **fails open** on the Cloud Run worker (any read error →
  accept) so a guard bug can never take production voice down.
- The Cloud Run worker keeps **automatic** dispatch (no `agent_name`); the LiveKit
  worker runs the **same** `agent.py` with `AGENT_RUNTIME=livekit`, which sets
  `agent_name = CONFIG.agent_name_livekit` ("ayma-lk") for explicit dispatch.

Net: default path is byte-for-byte unchanged; the opt-in path routes cleanly to one
deployment.

## Firestore credential for the LiveKit-hosted agent

LiveKit Cloud has **no GCP workload identity**, so the hosted worker can't use ADC.
A least-privilege service account provides Firestore access:

- **SA:** `lk-agent-firestore@ayma-ai.iam.gserviceaccount.com`
  (role `roles/datastore.user` only — add `roles/secretmanager.secretAccessor` only
  if the agent ever reads Secret Manager directly; today all secrets arrive as env
  vars from LiveKit's secret store, so it does not need it).
- **Key:** minted once and stored in GCP Secret Manager as **`LK_AGENT_FIRESTORE_SA`**
  (the key JSON itself). This is a **durable credential** — rotate by minting a new
  key, adding a new secret version, and deleting the old key.
- `db.py` detects `LK_AGENT_FIRESTORE_SA` (JSON or a path) and initializes
  firebase-admin with it; absent (Cloud Run / local) it falls back to ADC unchanged.
- **Never commit the key or any secret.**

## Deploy artifacts

- `functions/bootstrap/Dockerfile.livekit` — glibc (`python:3.12-slim`), installs
  `requirements-agent.txt`, `ENV AGENT_RUNTIME=livekit`, `ENTRYPOINT python agent.py start`.
- `functions/bootstrap/livekit.toml` — the LiveKit Cloud Agents config (project
  subdomain `aimma-wt34nu3l`, agent id). Dispatch name `ayma-lk` is set in code, not here.
- `scripts/deploy-agent-livekit.sh` — stages a build context (so LiveKit's required
  `Dockerfile` name doesn't collide with the Main API `Dockerfile`), pulls secrets
  from Secret Manager into a 600-perm tempfile, and runs `lk agent create|deploy|update-secrets`.

## How to deploy to LiveKit Cloud

Prerequisites:

- `lk` CLI **>= 2.19** (older CLIs are rejected with "version header is required").
  If the system `lk` is older, download the latest release and point `LK_BIN` at it.
- `gcloud` authed with Secret Manager read on `ayma-ai`.
- Auth is by the project `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` (read from Secret
  Manager by the script) — **no** interactive `lk cloud auth` browser session needed.

```bash
# First time (creates the agent, assigns an id, writes it to livekit.toml):
LK_BIN=/path/to/lk LK_REGION=us-east scripts/deploy-agent-livekit.sh create

# Subsequent versions:
LK_BIN=/path/to/lk scripts/deploy-agent-livekit.sh deploy

# Rotate secrets only (restarts the agent):
LK_BIN=/path/to/lk scripts/deploy-agent-livekit.sh update-secrets
```

Secrets provisioned into LiveKit's secret store (as env vars):
`GOOGLE_API_KEY`, `META_API_KEY`, `SENTRY_DSN` (from `SENTRY_DSN_AGENT`),
`LK_AGENT_FIRESTORE_SA` (the SA key JSON, compacted to one line) — plus the non-secret
runtime env mirrored from `scripts/deploy-agent.sh` (`USE_VERTEX`, `VERTEX_LOCATION`,
`GOOGLE_CLOUD_PROJECT`, `GEMINI_LIVE_USE_DEV_API`, `CONTEXT_OPT_*`, `LLM_PROVIDER_VOICE*`,
`META_CASCADE_TTS_VOICE_*`). `LIVEKIT_URL` / `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`
are injected by LiveKit automatically; `AGENT_RUNTIME=livekit` is baked into the image.

Check it:

```bash
lk agent list   --url wss://aimma-wt34nu3l.livekit.cloud --api-key … --api-secret …
lk agent status --url … --api-key … --api-secret … --id <CA_…>
lk agent logs   --url … --api-key … --api-secret … --id <CA_…>
```

The worker's **Dispatch Name** becomes `ayma-lk` once the container boots and the
worker registers; before that it shows `<Pending>`.

### Current deployment

- Agent id: **`CA_bJMNunTLpVqk`**, region **us-east**, project `aimma-wt34nu3l`
  (created 2026-10-28). Dispatch name `ayma-lk`.

## The dev toggle

Developer screen (`ayma_flutter/lib/screens/developer_screen.dart`), under the
password unlock → **"Voice agent cloud"** chips (Cloud Run / LiveKit Cloud). Reads/writes
`GET/POST /voice/agent-cloud`. Takes effect on the next voice call.

## How to flip the default later

Today the default is `cloudrun` and is read per user from `profile/main`. To make
LiveKit the default for everyone later, options (in order of blast radius):

1. **Cohort / allowlist:** keep the per-user flag and flip it for a growing set of uids.
2. **New-account default:** change `schema.VOICE_AGENT_CLOUD_DEFAULT` to `livekit` and
   deploy ayma-api — new reads fall back to LiveKit. **Only do this once the LiveKit
   worker has soaked**; it diverts every account that never set the pref.
3. **Full cutover:** after a soak, keep the Cloud Run agent deployed as the fallback
   for one release, then retire it.

To **roll back** instantly: no deploy needed — set a user's `voice_agent_cloud` back to
`cloudrun` (or lower `VOICE_AGENT_CLOUD_DEFAULT`). The Cloud Run agent stays the default
and is always available.

## Safety / review notes

- Default OFF = Cloud Run; production voice unchanged, no Cloud Run redeploy *required*
  for the default path (the `request_fnc` guard is additive and accepts default rooms
  identically — redeploy the Cloud Run agent so the guard is present before anyone
  opts in to `livekit`).
- SA is least-privilege (`datastore.user`). No secret is committed; the key lives only
  in Secret Manager and LiveKit's secret store.
- No hardcoded model/voice ids outside `config.py`.
