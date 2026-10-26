# Meta Model API provider (hackathon Deliverable A)

NEW hackathon work (Meta Global AI Developer Hackathon, Startup Track). Ports
Ayma's LLM work onto Meta's Muse Spark behind a per-surface flag, with Gemini
kept as the default and the fallback. Nothing in production changes until a
surface is explicitly flipped.

## What was built

* **`functions/bootstrap/llm_provider.py`** — an `LLMProvider` abstraction with
  two implementations:
  * `GeminiProvider` — a thin wrapper over the existing `gemini.py` calls
    (Vertex / Gemini Developer API). The production default.
  * `MetaProvider` — Meta Muse Spark via the **OpenAI-compatible** Meta Model
    API (`openai.AsyncOpenAI` pointed at `config.meta_api_base_url`, authed with
    the `META_API_KEY` environment secret). Supports **generate text**,
    **event-streamed chat** (status events + tool round-trip) and
    **structured / JSON output** (maps Ayma's JSON schemas to the OpenAI
    `response_format`). On any failure it **falls back to Gemini** when
    `LLM_META_FALLBACK` is on (default), so a flip can never take a surface down.
* **`get_llm_provider(surface)`** — returns the provider a surface is configured
  for. Surfaces: `chat`, `matching`, `reports`, `practice`, `voice`.
* **Per-surface flag `LLM_PROVIDER_<SURFACE>`** (`gemini` | `meta`), with
  `LLM_PROVIDER` as the default for any surface whose own var is unset. **All
  default to `gemini`.**
* Model ids live only in `config.py` (per `AGENTS.md`): `META_CHAT_MODEL`
  (`muse-spark-1.3`), `META_OPEN_WEIGHTS_MODEL`
  (`meta-models/muse-spark-open-1026`, the $10k open-weights target),
  `META_TRANSCRIBE_MODEL` (`muse-voice-transcribe-1.0`, voice cascade). Model
  ids confirmed live via `GET https://api.meta.ai/v1/models` (2026-10-26).
* **Reasoning effort `META_REASONING_EFFORT` (default `minimal`)** — every Muse
  Spark variant is a reasoning model and there is no non-reasoning Meta chat
  model (the API rejects `reasoning_effort: none`; floor is `minimal`). At the
  default effort a trivial reply burns ~450 reasoning tokens and ~2s+; pinned to
  `minimal` it drops to ~20 reasoning tokens and ~0.6s, which is what Ayma's
  conversational surfaces need. Passed as `extra_body` so it works regardless of
  the installed OpenAI SDK version.
* **Eval harness** — `functions/bootstrap/scripts/meta_vs_gemini_eval.py` runs
  fixed matching pairs + report prompts through both providers and prints a
  comparison. Dry-run (no key) shows the exact request each side would send;
  live mode runs both once the key exists.

## Wired surfaces

| Surface | Call site routed through `get_llm_provider(...)` |
|---|---|
| chat | `main.py` `_generate_chat_reply` (non-streaming) and the streaming `generate_reply_events` turn |
| matching | `matching_skill._run_llm` |
| reports | `body_report.py`, `face_report.py` |
| practice | not a call site yet — the Practice Date agent consumes `get_llm_provider("practice")` directly |

## How to flip a surface to Meta

Set the surface's env var on the Cloud Run service (or `.env.local` for local
dev) and restart / redeploy. Examples:

```
# route only matching to Meta, leave everything else on Gemini
LLM_PROVIDER_MATCHING=meta

# route chat + reports to Meta
LLM_PROVIDER_CHAT=meta
LLM_PROVIDER_REPORTS=meta

# everything to Meta at once
LLM_PROVIDER=meta
```

Roll back by removing the var (or setting it to `gemini`) and restarting. With
`LLM_META_FALLBACK=true` (default) a Meta outage or a missing key degrades that
surface to Gemini automatically; set `LLM_META_FALLBACK=false` only when you
need to measure Meta on its own (e.g. in the eval).

## Credentials & status

- **`META_API_KEY`** is a secret: in deployment it lives in a secrets manager
  and is mounted into the service; locally it comes from a gitignored
  `.env.local`. It is **never committed and never a plaintext env var in a
  deploy config**. The code reads it from the environment at the call site
  (`llm_provider.py` / the voice cascade), never from config.
- **`META_API_BASE_URL`** is non-secret config (default `https://api.meta.ai/v1`,
  OpenAI-compatible), overridable per environment.
- Running a live Meta call requires a payment card on the Meta account; until
  hackathon credits post, calls bill the card — so the live surfaces stay gated
  until billing is in place. (Account/billing identifiers are intentionally
  omitted from this public repo.)

### Eval (`scripts/meta_vs_gemini_eval.py --live`)

Both providers passed all four fixtures; **Muse Spark was faster on every case**
(e.g. match 1.5s vs Gemini 7.1s; report 1.8s vs 4.2s). Known quirk: on the
**reports** JSON schema Muse Spark sometimes emits a key with a trailing space
(`"strengths "`) — harmless for `practice`/`chat` (conversational, no strict
schema) but a parser risk, so **reports stays on Gemini** until this is handled.

### Flipped surface

`practice` (text) → Meta (`LLM_PROVIDER_PRACTICE=meta` in `deploy-api.sh`), with
`LLM_META_FALLBACK=true` so any Meta hiccup degrades to Gemini.
`chat`, `matching`, `reports`, `voice` remain on Gemini. The **Practice Date
voice cascade** below is wired but gated OFF (`LLM_PROVIDER_VOICE` default
`gemini`).

## Voice cascade (Practice Date "runs on Meta")

The Practice Date **voice** session can run end-to-end on Meta as a LiveKit
pipeline (cascade) agent instead of Gemini Live's speech-to-speech
`RealtimeModel`. Gated by the existing **`voice` surface flag**
`LLM_PROVIDER_VOICE` (`config.llm_provider_voice`); default `gemini` keeps the
current Gemini Live path **unchanged**. This is the hackathon "runs on Meta"
demo story, applied to practice voice first.

**The cascade (`agent.build_meta_cascade_session`):**

| Leg | Vendor / model | Transport |
|---|---|---|
| STT | Meta `muse-voice-transcribe-1.0` (`config.meta_transcribe_model`) | `livekit-plugins-openai` `openai.STT`, pointed at `config.meta_api_base_url` + the `META_API_KEY` secret (OpenAI-compatible) |
| LLM | Meta Muse Spark `muse-spark-1.3` (`config.meta_chat_model`) | `openai.LLM`, same base URL + key, `reasoning_effort=config.meta_reasoning_effort` (`minimal` — Muse Spark is reasoning-only; omit it and replies come back empty) |
| TTS | Inworld (`config.meta_cascade_tts_model`, default `inworld/inworld-tts-1`; `config.meta_cascade_tts_voice` optional) | `livekit.agents.inference.TTS` via the LiveKit **Inference gateway** (LiveKit-credit covered, authed with the worker's `LIVEKIT_API_KEY`/`SECRET`) |
| VAD | Silero (`config.meta_cascade_vad_model`, default `silero`) | `livekit.agents.inference.VAD` — bundled, runs locally in the worker (the cascade has no server-side turn detection) |

The TTS vendor is **config, not hardcoded** — Rime (`rime/…`) and Fish
(`fishaudio/…`) are documented A/B alternatives reachable by setting
`META_CASCADE_TTS_MODEL`/`_VOICE`, so the flag can reach them.

**Fallback — a flip can never take voice down.** If the cascade can't be built
(no `META_API_KEY`, `livekit-plugins-openai` missing), `_run_practice_session`
logs it, reports to Sentry, and falls back to the existing Gemini Live path.
Only the Practice Date voice session reads this flag; normal Ayma voice calls
(`_run_session`) are untouched.

**Metering.** A cascade emits per-component `LLMMetrics` (not the single
`RealtimeModelMetrics` a Gemini Live session emits), so `relay_cascade_usage`
records the Muse Spark LLM tokens under `FEATURE_VOICE` to keep the lifetime
credit cap honest. (Real-dollar pricing for Meta models is a separate
Deliverable-A gap — `token_ledger._MODEL_PRICING` has no Meta rate yet — so
`cost_usd` is 0 for cascade turns; the token cap still applies. Meta's own bill
is on the card until the $150 credit posts.)

**Dependencies / credentials.** `requirements-agent.txt` adds
`livekit-plugins-openai==1.8.9`; TTS and VAD ride livekit-agents' built-in
`inference` module (no extra TTS/VAD plugin). `META_API_KEY` is already mounted
on `ayma-agent` (`scripts/deploy-agent.sh`), as are the LiveKit creds.

**How to flip (practice voice to Meta):**

```
# on the ayma-agent Cloud Run service (or .env.local for local dev)
LLM_PROVIDER_VOICE=meta
```

Roll back by removing the var (or `LLM_PROVIDER_VOICE=gemini`) and restarting.
Applies to the next practice voice call. A live Meta voice call bills the card
until the credit posts, so this is **gated on billing** — not flipped yet.

## Embeddings stay on Gemini (deliberate hybrid)

Meta has **no embedding model**, and Ayma's matching uses a 3072-d Gemini
embedding index (`media_embed.py`, `IMAGE_EMBEDDING_MODEL=gemini-embedding-2`).
Matching therefore runs as a hybrid: **candidate retrieval / similarity stays on
Gemini embeddings**, while the **LLM scoring pass** (`matching_skill`) can run on
Muse Spark. Flipping `LLM_PROVIDER_MATCHING=meta` only moves the scoring call;
it does not touch embeddings and does not break matching. Web-search / URL
grounding in chat also stays Gemini-only (Meta has no Google grounding) — a chat
surface on Meta simply answers without live web grounding.

## Relationship to the LiveKit-Inference routing

`docs/LIVEKIT_INFERENCE_MIGRATION.md` describes a **lower-level transport**
choice for Gemini traffic: Vertex direct vs the LiveKit Inference gateway
(both still Gemini models, chosen via `config/llm_routing` / `LLM_ROUTE_*`).
That is orthogonal to this provider choice:

* **This module picks the vendor** — Gemini vs Meta Muse Spark.
* **When the vendor is Gemini**, whatever transport `gemini.py` is configured
  for (Vertex or LiveKit Inference) still applies underneath, unchanged.
* **When the vendor is Meta**, the call goes direct to the Meta Model API and
  the LiveKit-Inference routing does not apply.

The two layers compose cleanly and are flagged independently. (Note: the
LiveKit-Inference branch is not merged into `meta-hackathon`; this provider
layer sits above `gemini.py` and keeps working whether or not that lands.)
