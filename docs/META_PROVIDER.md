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
  (`muse-spark`), `META_OPEN_WEIGHTS_MODEL`
  (`meta-models/muse-spark-open-1026`, the $10k open-weights target),
  `META_TRANSCRIBE_MODEL` (`muse-voice-transcribe`, voice cascade).
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

## REQUIRED before any live Meta call

1. **`META_API_KEY`** — the Meta Model API key, NOT yet available (the Meta
   account + $150 credit claim are being set up). Add it to **Google Secret
   Manager** and mount it on the Cloud Run services; never a plaintext env var
   in a deploy config, never committed. Until it is set, any surface flipped to
   `meta` falls back to Gemini (or raises a clear `META_API_KEY is not set`
   error if fallback is off).
2. **Account Team ID + a payment card** on the Meta account (card is required
   to use credits; overspend bills the card — monitor usage).
3. **Confirm `META_API_BASE_URL`** against <https://dev.meta.ai/docs/quickstart>.
   The committed default (`https://api.meta.ai/v1`) is a placeholder; set the
   real base path via the `META_API_BASE_URL` env var.

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
