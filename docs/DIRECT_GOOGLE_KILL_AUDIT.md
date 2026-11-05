# Direct-Google inference audit — kill the off-LiveKit path (2026-11-04)

Founder order: "Why are Gemini calls going straight to Google? Kill this path."
Billing evidence (detailed export, Nov 1–4): Vertex AI **Gemini 3.7 Flash**
charges in `ayma-ai` (~$5.72) and `ayma-staging` (~$1.71) — direct Google billing
while the funded LiveKit gateway carries ~$17,000 in credits.

Standing rule (permanent): ALL Ayma inference goes through LiveKit in every
environment. When LiveKit is down the app shows an honest error, never a silent
fallback to a direct provider. The Gemini MODEL defaults never change — only the
serving path and billing move (e.g. `gemini-3.7-flash` is served as the
gateway model `google/gemini-3.7-flash`).

Scope: `functions/bootstrap` (the Main API + the voice-agent worker, prod and
staging variants — both run the same code). The Flutter client does no
inference. Dev/offline tooling under `scripts/` and `tools/` is not served and
is left untouched.

## Paths that already run through LiveKit (kept as-is)

- `inference_llm.py` — chat completions via the LiveKit Inference gateway
  (OpenAI-compatible `/v1`), JWT-minted from `LIVEKIT_API_KEY`/`SECRET`.
- `gemini.py` `_reply_events_inference` / `_generate_json_inference` — chat and
  JSON/vision jobs on the gateway (`INFERENCE_CHAT_MODEL` /
  `INFERENCE_JSON_MODEL`, both `google/gemini-3.7-flash`).
- `agent.py` `build_inference_realtime_model` — main voice as gateway realtime
  (`INFERENCE_LIVE_MODEL`, `google/gemini-3.8-live`).
- `agent.py` `build_cascade_session` — cascade STT/LLM/TTS/VAD via
  `livekit.agents.inference` (gateway, LiveKit-credit covered).
- Meta / Open-weights / OpenAI / Qloo legs — not Google; untouched by this kill.

## Direct-Google paths found (all killed in this change)

| # | Code | Service | Feature | Direct transport | What selected it |
|---|---|---|---|---|---|
| 1 | `gemini.generate_reply_events` Vertex branch | ayma-api, ayma-api-staging | text chat | `genai.Client(vertexai=True)` on Vertex `global` (`USE_VERTEX=true`), else Dev API via `GOOGLE_API_KEY` | `llm_route_chat`/`llm_percent_chat`/`llm_allowlist_chat`, or `llm_fallback_to_google` after a gateway failure |
| 2 | `gemini.generate_json` Vertex tail | ayma-api, ayma-api-staging | matching, reports, vision reads, moderation, DM ingest, practice JSON, wiki | same client as #1 | `llm_route_json`/`llm_route_vision` + percents/allowlists, or the Google fallback; HEIC/m4a/webm/ogg/aac media skipped the gateway unconditionally |
| 3 | `gemini.research` | ayma-api, ayma-api-staging | deep-dive research, public-profile discovery, chat `web_search` tool | Vertex `google_search` + `url_context` grounding on `gemini-3.7-flash` | always direct, no routing |
| 4 | `gemini.generate_image` / `edit_image` | ayma-api, ayma-api-staging | `generate_image` / `edit_photo` chat skills | Vertex `gemini-2.5-flash-image` | always direct, no routing |
| 5 | `voice_preview._synthesize` | ayma-api, ayma-api-staging | voice-preset picker samples | Vertex `gemini-2.5-flash-preview-tts` | always direct on a cache miss (hits stay cached in Storage) |
| 6 | `media_embed.embed_image_bytes` | ayma-api, ayma-api-staging | same-person face signals (shared-photo verify, appearance own-photo check, gallery lazy match, dive scoring, web-candidate match) | raw Vertex aiplatform `:embedContent` REST (`gemini-embedding-2`) | always direct, no routing |
| 7 | `gemini_batch.submit_json_batch` / `poll_json_batch` | ayma-api via `POST /cron/lint` | wiki lint sweep | Vertex Batch API on `gemini-3.7-flash` | always direct, no routing |
| 8 | `agent.build_realtime_model` Google branch | ayma-agent, ayma-agent-staging | main voice | `livekit.plugins.google` realtime: Vertex `us-central1` native-audio, or Dev API `gemini-3.8-live` + `GOOGLE_API_KEY` (the deployed config sets `GEMINI_LIVE_USE_DEV_API=true`) | `voice_provider`/`llm_percent_voice`/`llm_allowlist_voice` |
| 9 | `gemini.warmup` | ayma-api startup | cold-start ping | same client as #1 | always direct |

Disposition:

- #1, #2, #8 — REMOVED. The Vertex/Google branches are deleted; the functions
  are inference-only. `llm_routing.route_for` always returns `"inference"` and
  `fallback_enabled()` always returns `False`, so no env / Firestore /
  `config/llm_routing` override can re-arm the direct path. A gateway failure
  now fails the call honestly. Unsupported media (HEIC etc.) raises an honest
  error instead of silently going to Vertex.
- #3, #4, #5, #6, #7 — DISABLED behind their existing call shape (they raise
  `llm_routing.DirectGoogleDisabledError`; no new flags). The LiveKit gateway
  provably has no equivalent (probed live 2026-10-25, see
  `docs/LIVEKIT_INFERENCE_MIGRATION.md`: `/embeddings`, `/images/generations`,
  `/audio/speech`, `/batches` all 404; grounding silently ignored), so per the
  founder's order these are disabled — not rerouted, not left live. Each is a
  **founder-decision item**: re-enable only with an explicit LiveKit-served
  equivalent or an explicit founder exception.
  - #3: deep dives fail honestly (`failed` run status); the chat `web_search`
    tool returns an "unavailable" error the model relays; public-profile
    discovery skips that source and keeps the others.
  - #4: both skills catch it and reply in chat that image generation isn't
    available (message kept user-safe — the skills interpolate it).
  - #5: cached clips keep serving; uncached presets get an honest 502.
  - #6: all 7 call sites already `try/except` → `unknown`/skip; face signals
    degrade to "unknown", never a crash.
  - #7: `POST /cron/lint` returns `{"status": "disabled", ...}` and clears any
    stale pending batch state; no new Vertex batch is ever submitted.
- #9 — REPOINTED at a minimal gateway ping (still best-effort at startup).

## Reviewed and deliberately KEPT (not Gemini inference)

These call Google, but they are not Gemini model inference, have distinct SKUs
(not the billed Gemini 3.7 Flash SKU), have no LiveKit equivalent, and are
flag/key-gated. Left live; flag the founder if the ban should extend to them.

- `vertex_search.py` — Vertex AI Search (Discovery Engine) website retrieval
  for deep-dive discovery. Retrieval API, not model inference. Flag:
  `vertex_ai_search` + `vertex_ai_search_daily_cap`.
- `reverse_image_search._web_detect` — Cloud Vision Web Detection for
  user-confirmed web-photo candidates. Vision API, not Gemini. Fails closed
  when `google-cloud-vision` is absent.
- `deep_dive_images` web image step — Programmable Search (Custom Search JSON
  API). Key-gated (`IMAGE_SEARCH_API_KEY`/`CSE_ID`); skipped when unset.

Also untouched: `GOOGLE_CLOUD_PROJECT` (still selects the Firestore/Storage
data plane — required, and pinned by `test_deploy_staging_pins.py`);
`USE_VERTEX=true` stays in the deploy envs but is now inert for inference;
`GOOGLE_API_KEY` stays mounted on the agent but is no longer read on any
served path.

## Proof

- `tests/test_llm_call_site_coverage.py` — rewritten: the justified-direct
  lists are gone; a static scan asserts no served module imports `google.genai`
  or touches `genai.Client` / `vertexai=` / `:embedContent` / batch / direct
  `generate_content` markers.
- `tests/test_inference_routing.py` — rewritten: routing always resolves to
  Inference under every override combination; gateway failures raise (no
  fallback); every disabled sub-path raises `DirectGoogleDisabledError`.
- Full suite run in both venvs; results in the DONE entry.
