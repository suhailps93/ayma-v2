# Deepgram DIRECT voice experiment (branch `fleet/deepgram-voice`)

> **Branch-only. Never merged to staging/prod.** This routes voice STT/TTS to
> Deepgram's **DIRECT API** — a deliberate, founder-approved deviation from the
> standing "all inference through LiveKit" rule, for THIS experiment only
> (2026-11-18). The **default** voice path (LiveKit Gemini Live / the LiveKit
> Inference cascade) is **unchanged**; Deepgram is reached only behind a dev
> toggle. Nothing else is rerouted.

## What it does

The Ayma **Brain** and the LiveKit **room** flow are untouched. On this branch,
only **speech-in and speech-out** can be swapped to Deepgram's direct API:

- **STT** — Deepgram **Nova-3** streaming (`deepgram.STT`) with interim results,
  smart formatting, punctuation, low endpointing + `utterance_end_ms` tuned for
  natural turn-taking and barge-in. **Flux** is configurable
  (`DEEPGRAM_STT_USE_FLUX=true` → `deepgram.STTv2`, model `flux-general-en`);
  default is Nova-3.
- **TTS** — Deepgram **Aura-2** (`deepgram.TTS`). For Aura the *voice is the
  model string*, so each selectable voice is a concrete `aura-2-*-en` id (the
  dev toggle's picker lists them from the catalog).
- **Emotion / vibe-matching** — unchanged and provider-agnostic. Ayma's emotion
  read rides the voice-actions skill's structured pass (`emotion.py`), driving
  tone (a flat/low user → grounded, calm reply). Deepgram's on-stream
  "intelligence" (sentiment) is a **pre-recorded / text** feature, **not**
  available on the live streaming STT socket, so there is nothing to feed from
  the stream; the existing transcript-based read is the fallback and already
  satisfies the requirement. No change was needed here.

### Architecture choice: separate STT/TTS, **not** the Deepgram Voice Agent API

The Deepgram Voice Agent API would replace the **brain** too. We keep Ayma's
brain and LiveKit room, so the branch uses **separate `deepgram.STT` +
`deepgram.TTS` legs inside our existing cascade** (`build_cascade_session`),
mirroring the Cartesia direct-plugin pattern. This reuses the whole cascade
machinery (brain, VAD, metering, runtime fallback).

## The KEY dependency (empty until provisioned)

The agent reads the Deepgram key from env var **`DEEPGRAM_API_KEY`**. **No such
secret exists yet** in Secret Manager (ayma-ai or ayma-staging) — a QUESTION is
filed at the top of `astro.md`. Everything key-independent is built and tested.

- **Key absent → honest error, never silent.** Selecting the Deepgram path with
  no key makes the agent publish `voice_status: deepgram_key_missing`; the app
  shows *"Deepgram voice isn't set up yet…"* and ends the call. It does **not**
  silently fall back to Gemini Live (which would hide that the experiment isn't
  running) or hang on "Listening…".
- To light it up: create Secret Manager secret **`DEEPGRAM_API_KEY`** in project
  **ayma-ai** (the $1000 direct credits live on Deepgram Console
  `founder@justabot.info`, project `e79aa18b-48f4-4531-8d45-b6831f6d1f43` — this
  is **separate** from the LiveKit Inference Deepgram pool). No code change
  needed: the deploy script already maps it and skips it (with a warning) while
  absent.

## How the founder enables it in the app

1. Open **User settings → tap the version row seven times** → enter the dev
   password → **Developer panel**.
2. Scroll to **"Deepgram voice (experimental)"**.
3. Flip **"Use Deepgram voice"** ON. Pick an **Aura-2 voice** from the dropdown
   (Thalia, Andromeda, Helena, Athena, Asteria, Apollo, Arcas, Aries, Mars,
   Zeus, Draco). Takes effect on the **next** voice call.
4. OFF restores the default **Gemini Live** voice. The Ayma Brain is never
   changed by this toggle.

The same stack is also selectable on **Ayma's models** screen (Mode = Cascade,
STT = `deepgram-direct/nova-3`, TTS = `deepgram-direct/aura-2`, then the Voice
dropdown of Aura-2 voices).

## How the branch agent runs on staging (NOT `ayma-lk`)

The prod agent is `ayma-lk` — **do not touch it**. The repo already has a
staging agent target, `ayma-lk-stg`, which writes to the ayma-staging Firestore.
Deploy the branch agent to it (needs `lk` CLI ≥ 2.19 — the local `lk` is 2.5.5,
too old, so this runs from an env with a current CLI):

```bash
# From the branch worktree. First time:
AGENT_TARGET_ENV=staging scripts/deploy-agent-livekit.sh create
# Later versions / to pick up the DEEPGRAM_API_KEY once created:
AGENT_TARGET_ENV=staging scripts/deploy-agent-livekit.sh deploy
AGENT_TARGET_ENV=staging scripts/deploy-agent-livekit.sh update-secrets
```

`scripts/deploy-agent-livekit.sh` now includes `DEEPGRAM_API_KEY` in its secret
map; while the Secret Manager secret is absent the collector skips it with a
warning and the agent runs without it (honest-error path above). The deploy
script's plain `deploy`/`create` mode targets **prod** (`ayma-lk`) — use
`AGENT_TARGET_ENV=staging` so it targets `ayma-lk-stg`. **Nothing here deploys
prod or touches `ayma-lk`.**

## Verified vs. "needs key"

| Thing | Status |
| --- | --- |
| `deepgram.STT` Nova-3 is the plugin default; `interim_results`/`utterance_end_ms` etc. | Verified from docs.livekit.io/agents/integrations/stt/deepgram (2026-11-18). A version-tolerant kwargs filter drops any param the installed `livekit-plugins-deepgram==1.8.9` ctor doesn't accept, so it can't crash the leg. |
| Flux = `deepgram.STTv2`, model `flux-general-en` | Documented (same source). **Account availability UNVERIFIED — needs key.** Falls to an honest error if `STTv2` is absent from the installed plugin. |
| Aura-2 voice model strings (`aura-2-thalia-en`, …) | Verified from developers.deepgram.com/docs/tts-models (2026-11-18). **That these specific voices are served on this account UNVERIFIED — needs key.** |
| On-stream sentiment feeding tone | **Not available on live Deepgram STT** (pre-recorded/text feature). Existing transcript-based emotion read is the provider-agnostic fallback. |
| Actual Deepgram voice (end-to-end audio) | **UNVERIFIED — needs `DEEPGRAM_API_KEY` mounted into `ayma-lk-stg`.** |

## Config knobs (all in `functions/bootstrap/config.py`, env-overridable)

`DEEPGRAM_DIRECT_ENABLED` (default true on branch), `DEEPGRAM_STT_MODEL`
(`nova-3`), `DEEPGRAM_STT_USE_FLUX` (false), `DEEPGRAM_FLUX_MODEL`
(`flux-general-en`), `DEEPGRAM_UTTERANCE_END_MS` (1000), `DEEPGRAM_ENDPOINTING_MS`
(25), `DEEPGRAM_TTS_MODEL` (`aura-2-thalia-en`). No model strings are hardcoded
outside `config.py`.
