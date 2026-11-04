# LiveKit Cloud Agents migration (ayma-agent → LiveKit Cloud)

> Status: **LiveKit Cloud is now the DEFAULT** (flipped 2026-10-28, founder
> decision, branch `meta-hackathon`). A user with no `voice_agent_cloud` pref
> routes their voice room to the LiveKit-hosted `ayma-lk` worker (explicit
> dispatch); a user who explicitly set `cloudrun` still routes to the Cloud Run
> `ayma-agent`, which stays deployed as the opt-out / fallback. This runbook
> covers the dual-cloud design, how to deploy the LiveKit-hosted twin, the
> secrets/SA it needs, the dev toggle, and how to roll the default back.
>
> **ROLLBACK (do this to revert the default):**
> - *Instant, per user, no deploy:* set that user's `voice_agent_cloud=cloudrun`
>   (`POST /voice/agent-cloud {"cloud":"cloudrun"}`, or the Developer screen).
> - *Global, one line + deploy:* set `schema.VOICE_AGENT_CLOUD_DEFAULT` back to
>   `"cloudrun"` and redeploy ayma-api. The Cloud Run agent is always available.

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

### Cost: the Cloud Run wake ping is gated to cloudrun users

`ayma-agent` (Cloud Run) scales to zero, so a scaled-down instance has to be
woken by an HTTP ping (`agent_wake.wake_agent`, main.py) before a `cloudrun`
call can reach it. With the default now `livekit`, firing that wake on **every**
`/bootstrap` would cold-start a 2 GB Cloud Run instance on every voice call just
for it to decline the room (request_fnc guard) — pure wasted spend. So
`/bootstrap` now wakes Cloud Run **only when `_voice_agent_cloud(uid) ==
"cloudrun"`**.

### 2026-11-03: welcome + Practice Date moved; failure-only fallback added

Founder directive: everything voice runs on LiveKit Cloud; GCP serves only
when LiveKit Cloud itself is failing. Three changes closed the remaining
non-failure routes to Cloud Run:

- `/welcome/token` (the last always-on Cloud Run consumer) now creates its
  room with explicit `ayma-lk` dispatch and a `livekit` seed marker — the
  hosted worker's `request_fnc` guard accepts it, and the greeting is
  seed-driven, so the same `agent.py` serves it unchanged. No wake ping.
- Practice Date voice (`/practice/voice/start`) originally bypassed the
  resolution entirely (no dispatch, default `cloudrun` marker, unconditional
  wake), so every practice call landed on GCP. It now resolves the caller's
  cloud via the shared `livekit_token.resolve_voice_agent_cloud` — the same
  helper `/bootstrap` uses — and routes/wakes exactly like `/bootstrap`.
- **Failure-only fallback:** there was previously NO automatic failover — if
  the hosted worker never joined, a livekit-routed call got no agent at all.
  `livekit_token.watch_hosted_dispatch` now watches each livekit-routed room
  for ~15 s after creation; if no agent participant joins, it flips the
  room's marker to `cloudrun`, wakes Cloud Run and creates an automatic
  dispatch for that room (the marker flip also makes the hosted worker
  decline the room if it resurfaces, so the two never both join). A flipped
  seed gains `cloud_fallback_reason: hosted_agent_missing`, and the flip is
  logged at WARNING in ayma-api.

Net: Cloud Run now serves voice only for (a) an explicit per-user `cloudrun`
opt-out (the dev rollback toggle — as of 2026-11-03, zero prod users carry
any `voice_agent_cloud` pref), or (b) a room whose hosted dispatch
demonstrably failed. The Cloud Run service stays deployed, scale-to-zero,
as that fallback.

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

## The default (flipped 2026-10-28) and how to roll back

The default now lives in **one authoritative place**: `schema.VOICE_AGENT_CLOUD_DEFAULT`
(`functions/bootstrap/schema.py`), set to `"livekit"`. `main._voice_agent_cloud(uid)`
returns it whenever a user's `profile/main.voice_agent_cloud` is absent, empty, or an
unknown value — so a no-pref user routes to the hosted `ayma-lk` worker via explicit
dispatch (`/bootstrap` sets `agent_name=CONFIG.agent_name_livekit`). A user who
explicitly set `cloudrun` still routes to Cloud Run (automatic dispatch).

This was flipped from `cloudrun` only after confirming `ayma-lk`
(`CA_bJMNunTLpVqk`, us-east) was **Running / registered** on LiveKit Cloud, and with
the build-failure + runtime fallback to Gemini Live on the cascade path intact (a
LiveKit-side failure can't fully kill voice).

**Roll back the default:**

1. **Instant, per user, no deploy:** set that user's `voice_agent_cloud=cloudrun`
   (`POST /voice/agent-cloud {"cloud":"cloudrun"}`, or Developer screen → "Voice agent
   cloud" → Cloud Run). Takes effect on their next voice call.
2. **Global, one line + deploy:** set `schema.VOICE_AGENT_CLOUD_DEFAULT` back to
   `"cloudrun"` and redeploy ayma-api. Every no-pref read falls back to Cloud Run again.
3. **Full cutover (future):** after a soak, retire the Cloud Run agent in a later release.

The Cloud Run `ayma-agent` stays deployed as the opt-out / fallback and is always
available — rolling back needs no LiveKit change.

## Safety / review notes

- Default is now `livekit` (the hosted `ayma-lk` worker). The Cloud Run `ayma-agent`
  stays deployed with the `request_fnc` guard present, serving explicit-`cloudrun`
  users and as the instant rollback target. Its guard fails open (accepts on any read
  error) so it can never take voice down on the opt-out path.
- SA is least-privilege (`datastore.user`). No secret is committed; the key lives only
  in Secret Manager and LiveKit's secret store.
- No hardcoded model/voice ids outside `config.py`.
