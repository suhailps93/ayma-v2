# Direct-provider routing audit (enforcement map for the LiveKit-only rule)

- **Date:** 2026-11-02 (PT morning, after the ~06:53–07:34 gateway flip + revert)
- **Branch:** `muse/vertex-routing-audit` (off `origin/staging` @ `d939b17`)
- **Scope:** `functions/bootstrap/` — every path that can send model inference to a
  direct provider (Vertex AI, Gemini Developer API, Meta Model API, OpenAI-direct,
  Modal/self-hosted open weights) instead of the LiveKit Inference gateway.
- **Method:** read-only code sweep + live read-only cross-check of staging
  (`gcloud run services describe`, staging Firestore `config/feature_flags` and
  legacy `config/llm_routing`). Zero code/config edits.
- **Headline: 17 direct-capable paths found, 11 of them holes**
  (2 default-direct, 1 silent-ish fallback, 8 not env-governable).
  One hole is **live on staging right now** (H2: DM translation on Meta-direct).
  Counting: one "path" = one distinct mechanism (T1–T5 + D1–D6 = 11
  Google-direct; Meta text vendor, Meta voice brain, user Brain pref, OpenAI
  Realtime, open-weights text, open-weights voice brain = 6 vendor-direct).
  T6/T7 are sub-choices within "direct Google", recorded in-table; D7 is
  retrieval (not LLM inference) and excluded from the LLM count.

## The two routing layers (don't conflate them)

1. **Transport** (`llm_routing.py` + `feature_flags.py` + `gemini.py` + `agent.py`):
   *Gemini* traffic goes either through the LiveKit Inference gateway
   (`"inference"`) or direct to Google (`"vertex"` = Vertex AI w/ ADC, or the
   Gemini Developer API w/ `GOOGLE_API_KEY` when `USE_VERTEX=false` /
   `GEMINI_LIVE_USE_DEV_API=true`). Four groups: `json`, `vision`, `chat`,
   `voice`. Resolution order per flag (`feature_flags.py:218-246`):
   `FLAG_<NAME>` env → Firestore `config/feature_flags` → legacy
   `config/llm_routing` → `config.py` default (fed by `LLM_ROUTE_*` /
   `VOICE_PROVIDER` / `LLM_PERCENT_*` / `LLM_INFERENCE_FALLBACK`).
2. **Vendor** (`llm_provider.py`, hackathon Deliverable A): picks the *vendor*
   per text surface — `gemini` | `meta` (Meta Model API direct) |
   `open-weights` (Modal/self-hosted direct). Env-only
   (`LLM_PROVIDER_<SURFACE>` + global `LLM_PROVIDER`, `config.py:1254-1284`) —
   **no Firestore layer** — plus per-user overrides (Brain pref, voice-engine
   pref) that bypass env entirely. When the vendor is Gemini, the transport
   layer above still decides gateway-vs-direct.

## Layer 1 — Transport paths (Gemini: gateway vs direct Google)

| # | Surface / call site | LiveKit when | Governing env (code default) | Staging must carry |
|---|---|---|---|---|
| T1 | chat turn — `gemini.py:349` via `generate_reply_events` | `llm_route_chat=inference` + percent roll | `FLAG_LLM_ROUTE_CHAT` / Firestore / `LLM_ROUTE_CHAT` (**`inference**`, `config.py:1148`); `…_PERCENT_CHAT` (**100**); `…_ALLOWLIST_CHAT` (**empty**) | absent (default) or `inference`/`100`/empty — **verified absent** |
| T2 | text JSON jobs (matching, wiki, icebreakers, dm, explore…) — `gemini.py:651` (`json` group) | same shape as T1 | `FLAG_LLM_ROUTE_JSON` / `LLM_ROUTE_JSON` (**`inference**`, `:1146`) + percent/allowlist | absent — **verified absent** |
| T3 | vision JSON (photo attrs, face/body/appearance reports, moderation, DM captions) — `gemini.py:651` (`vision` group) | same shape as T1 | `FLAG_LLM_ROUTE_VISION` / `LLM_ROUTE_VISION` (**`inference**`, `:1147`) + percent/allowlist | absent — **verified absent** |
| T4 | voice realtime (main + practice Gemini Live) — decided per call `agent.py:2154` / `:2860`, threaded to `build_realtime_model` (`agent.py:343`) and the hot-swapper (`agent.py:1722+`, "same builder, same provider route") | `voice_provider=inference` + percent roll | `FLAG_VOICE_PROVIDER` / Firestore / `VOICE_PROVIDER` (**`inference**`, `config.py:1165`); `LLM_PERCENT_VOICE` (**100**) | absent — **verified absent** |
| T5 | Inference→Google fallback (chat `gemini.py:264,357-362`, json `gemini.py:671-682`) | fallback **off** (error surfaces honestly) | `FLAG_LLM_FALLBACK_TO_GOOGLE` / Firestore / `LLM_INFERENCE_FALLBACK` (**`false`**, `config.py:1159-1161`) | absent — **verified absent** |
| T6 | direct-Google sub-choice for text: Vertex vs Dev API — `gemini.py:128-137` | n/a (both are direct; only matters when T1–T3 = vertex) | `USE_VERTEX` (**`true`** → Vertex+ADC; `false` → Dev API + `GOOGLE_API_KEY`) | `true` — **verified `true`** both services |
| T7 | direct-Google sub-choice for voice: Vertex vs Dev API — `agent.py:437-461` | n/a (only matters when T4 = google) | `GEMINI_LIVE_USE_DEV_API` (**`false`**; pinned **`true`** in `scripts/deploy-agent.sh:44`) + `GOOGLE_API_KEY` secret | agent carries `true` + key (**verified**) — dormant while T4=inference |

## Layer 2 — Vendor paths (Meta / OpenAI / Modal direct)

All of these bypass the LiveKit gateway by construction (direct vendor APIs).
`get_llm_provider()` (`llm_provider.py:912-940`) reads `LLM_PROVIDER_<SURFACE>`
with global-`LLM_PROVIDER` inheritance (except `voice_main`).

| # | Surface / call site | LiveKit when | Governing env (code default) | Staging must carry |
|---|---|---|---|---|
| V1 | chat text/tools — `main.py:1796,1948` via `get_user_brain_provider("chat")` | vendor=gemini (→ transport T1) **and** user Brain pref unset/non-meta | `LLM_PROVIDER_CHAT` (**`gemini**`) | `gemini` — **verified pinned** (Brain pref still overrides per user → H3) |
| V2 | matching JSON — `matching_skill.py:367` | vendor=gemini and Brain pref unset/non-meta | `LLM_PROVIDER_MATCHING` (**`gemini**`) | `gemini` — **verified pinned** (→ H3) |
| V3 | reports — `photo_report.py:168` via `get_vision_provider("reports")` (vision forced to Gemini, `llm_provider.py:943-963`; no text-only production caller) | always Gemini in practice | `LLM_PROVIDER_REPORTS` (**`gemini**`) | `gemini` — **verified pinned** |
| V4 | practice text (persona/coach/debrief) — `practice_llm.py:57,79` (env-only, ignores Brain pref) | `LLM_PROVIDER_PRACTICE=gemini` | (**`gemini**`, `config.py:1263`) | `gemini` — **verified pinned** (note: `scripts/deploy-api.sh:44-47` flips this to `meta` on `--hackathon` deploys) |
| V5 | practice VOICE — `agent.py:2819` (`llm_provider_voice==meta` → Meta cascade: Meta-direct LLM + gateway STT/TTS/VAD) | `LLM_PROVIDER_VOICE=gemini` | (**`gemini**`, `config.py:1271`) | `gemini` — **verified pinned on agent** |
| V6 | dm_coach (`dm_assist.py:260`) | `LLM_PROVIDER_DM_COACH=gemini` | **DEFAULTS `meta`** (`config.py:1277-1279`) → **H1** | `gemini` — **verified pinned** (manual; not in deploy scripts) |
| V7 | translate (`dm_translate.py:233`) | `LLM_PROVIDER_TRANSLATE=gemini` | **DEFAULTS `meta`** (`config.py:1282-1284`) → **H2** | `gemini` — **NOT PINNED, LIVE ON META-DIRECT NOW** |
| V8 | main voice stack — `agent.py:2188-2194` (`voice_main==meta` → Meta cascade) | `LLM_PROVIDER_VOICE_MAIN=gemini` (explicit-only, no global inheritance) | (**`gemini** (QLOO-phase), `config.py:1270`; deliberately unpinned in `scripts/deploy-agent.sh:37-41`) | absent (default) — **verified absent** |
| V9 | GLOBAL knob `LLM_PROVIDER` — flips V1–V7 at once (never V8) | unset/`gemini` | (**`gemini**`) | unset — **verified absent** |
| V10 | Meta→Gemini safety fallback — `llm_provider.py:458-470,520-531` (lands on *routed* Gemini transport, i.e. the gateway on staging — falls TOWARD LiveKit, not away) | on (default) | `LLM_META_FALLBACK` (**`true**`, `config.py:1285`) | absent (default) — **verified absent** |
| V11 | OpenAI Realtime voice — `agent.py:624-649`, user-selectable realtime model | flag off (inert) | `VOICE_OPENAI_REALTIME` (**`false**`) + `OPENAI_API_KEY` secret (both required) | absent/absent — **verified inert** |
| V12 | Open-weights TEXT (Modal vLLM) — `OpenWeightsProvider`, `llm_provider.py:649-700` (no paid fallback, raises when unconfigured) | no surface set to `open-weights` | `LLM_PROVIDER_*=open-weights` + `OPEN_WEIGHTS_BASE_URL` (**empty**=hidden) + `OPEN_WEIGHTS_API_KEY` + `META_OPEN_WEIGHTS_MODEL` | base URL **is set** on staging api (`deploy-staging.sh:94,104`) but dormant (no surface selects it) |
| V13 | Open-weights VOICE brain ("Llama 3.1 8B") — `agent.py:524-552`, offered iff base URL set (`voice_catalog.py:502,532`) | base URL unset, or no user picks it | `OPEN_WEIGHTS_BASE_URL` + `OPEN_WEIGHTS_MODEL` (both **empty** by default) | **both set on staging agent → offered in the staging cascade picker** (user-choice only, dormant until picked) |
| V14 | Per-user Brain pref (`ayma_brain_model`, `main.py:5271-5319` → `get_user_brain_provider`, `llm_provider.py:1002-1044`) routes that user's chat/matching/dm_coach/translate to Meta-direct | user picks Gemini (or nothing) | **NONE — not env-governable** → **H3** | n/a (per-user data; `AYMA_BRAIN_DEFAULT=gemini` is only the unset-user default) |
| V15 | Per-user voice-engine pref (`main.py:253-280` → room seed → `agent.py:2196-2223`): cascade+Meta brain (always offered, `voice_catalog.py:521`), cascade+open-weights brain (staging: offered), realtime model | user keeps deploy default | **NONE for the Meta brain** → **H4** (open-weights brain env-gated via V13; OpenAI via V11) | n/a (per-user data) |

## Always-direct paths (no gateway leg at all — class-c holes or accepted exceptions)

These call direct Google on every invocation, with no `route_for` check.
Whether each is an accepted architectural exception (no gateway alternative
exists) or must be closed is a **founder ruling**; the code fix for each is
small either way (a fail-closed guard flag, not a reroute).

| # | Surface / call site | Why direct | Smallest close |
|---|---|---|---|
| D1 | grounded research — `gemini.py:529-576` (`research()`), used by deep-dive (`deep_dive.py:1041`, `deep_dive_public_profiles.py:259`) **and** by the Inference-chat `web_search` tool (`gemini.py:206-214`, so even a gateway chat turn makes small direct calls) | gateway has no Search/URL grounding | → **H5**: gate on explicit `RESEARCH_ALLOW_DIRECT_GOOGLE` (default off); when off, `research()` raises and the chat tool reports "web lookup unavailable" |
| D2 | unsupported media (HEIC, m4a, …) — `gemini.py:652-661` goes straight to Vertex, deliberately untagged | gateway decodes only jpeg/png/webp/gif + wav/mp3 (`inference_llm.py:119-126`) | → **H10**: same guard flag as H5; when off, return an honest "format not supported via gateway" error |
| D3 | image generate/edit — `gemini.py:730-777` | no image path on the gateway | → **H6**: guard flag (default off → honest error); the tools already degrade to text on `RuntimeError` (`gemini.py:747-749`) |
| D4 | voice-preview TTS (voice picker clips) — `voice_preview.py:118-147` | direct Gemini TTS `generate_content` | → **H7**: guard flag; when off, serve cached clips only / honest error |
| D5 | photo/face embeddings — `media_embed.py:44+` (`:embedContent` REST) | no embedding path on the gateway | → **H8**: guard flag; when off, skip same-person vectors (features already treat missing embeddings as best-effort) |
| D6 | batch JSON (wiki-lint cron) — `gemini_batch.py:146,162`, caller `wiki_lint.py:213` | Batch API is Vertex-only | → **H9**: guard flag; when off, skip the cron batch (lint is advisory) |
| D7 | Vertex AI Search retrieval — `vertex_search.py`, governed by `vertex_ai_search` flag (`FLAG_VERTEX_AI_SEARCH` / `VERTEX_AI_SEARCH`, default true) + daily cap | discovery index, **not LLM inference** — adjacent, flaggable, keep | no change (kill via `FLAG_VERTEX_AI_SEARCH=false` if ever needed) |

Not paths: `meta_transcribe_model` (`config.py:787-800,1222`) is **dead
config** — zero references outside `config.py` (cascade STT runs through
`inference.STT`). Qloo Taste API is not LLM inference — out of scope.

## The holes (rule enforcement list)

- **H1 (a) `dm_coach` defaults to Meta-direct** — `config.py:1277-1279`
  (`LLM_PROVIDER_DM_COACH` falls back to `LLM_PROVIDER` falls back to
  `"meta"`). Smallest close: default `"gemini"` (one word), matching every
  other surface.
- **H2 (a) `translate` defaults to Meta-direct** — `config.py:1282-1284`.
  **Live on staging now** (only surface without a manual gemini pin).
  Smallest close: same one-word default change + `LLM_PROVIDER_TRANSLATE=gemini`
  on staging until the code lands.
- **H3 (c) user Brain pref → Meta-direct has no env kill switch** —
  `main.py:5271-5319` accepts `meta`; `llm_provider.py:1030-1035` honors it
  over env. Smallest close: in `get_user_brain_provider`, treat a saved
  `meta` brain as Gemini unless `LLM_ALLOW_META_BRAIN=true` (new flag,
  default false).
- **H4 (c) user voice-engine pref → Meta cascade brain always offered** —
  `voice_catalog.py:494-524` (no env gate, unlike open-weights `:502` and
  OpenAI `:100`). Smallest close: offer `BRAIN_META` only when
  `LLM_ALLOW_META_BRAIN=true`, same flag as H3.
- **H5–H10 (c) D1–D6 above** — always-direct, no env governance. Smallest
  close per row: one shared `ALLOW_DIRECT_GOOGLE` guard (default off) checked
  at the six call sites; off = honest error / best-effort skip, never silent.
- **H11 (b) demo/judge uids force the Google fallback ON** —
  `feature_flags.py:227-232` (`all_flags_on_uids` flips every *bool* flag,
  including `llm_fallback_to_google`). A gateway 429 for those users silently
  retries on direct Google. Smallest close: exclude
  `llm_fallback_to_google` from the `all_flags_on` override (one-line
  denylist).

## Staging cross-check (verified live, read-only, 2026-11-02 PT morning)

- Revisions: `ayma-api-staging-00094-fqp`, `ayma-agent-staging-00077-4fc`
  (each one rev newer than the revert revs in the brief — still clean).
- `FLAG_*`: **absent on both services** — the morning flip vector is closed.
- `LLM_ROUTE_*` / `VOICE_PROVIDER` / `LLM_PERCENT_*` /
  `LLM_INFERENCE_FALLBACK`: absent → code defaults govern (all `inference`,
  100%, fallback off).
- Staging Firestore: `config/feature_flags` carries only `dev_panel:false`;
  legacy `config/llm_routing` carries only `voice:{provider:inference,
  percent:100}`. No route overrides.
- `USE_VERTEX=true` both services; agent also `GEMINI_LIVE_USE_DEV_API=true`
  + `GOOGLE_API_KEY` (dormant while voice route = inference).
- `LLM_PROVIDER_*` pinned `gemini` on api for CHAT/DM_COACH/MATCHING/PRACTICE/
  REPORTS; agent pins VOICE=gemini; no global `LLM_PROVIDER`; no
  `LLM_PROVIDER_VOICE_MAIN` (→ gemini default). **Gap: TRANSLATE unpinned →
  Meta-direct (H2 live).**
- `OPEN_WEIGHTS_BASE_URL` (+`OPEN_WEIGHTS_MODEL`) set on both (staging-only,
  `deploy-staging.sh:94,104`): text side dormant; voice brain offered in the
  staging picker (V13, user-choice only). `META_API_KEY` mounted on both.
  OpenAI fully inert (no flag, no key).

## Required staging state for 100% LiveKit (transport + vendor)

Keep everything above, plus: (1) set `LLM_PROVIDER_TRANSLATE=gemini` on
`ayma-api-staging` now (closes live H2); (2) founder ruling on H3/H4 (user
prefs to Meta) and H5–H10 (accepted exceptions vs guard flags); (3) add the
missing `LLM_PROVIDER_*=gemini` pins to `scripts/deploy-staging.sh`
(`API_ENV_BASE`/`AGENT_ENV_BASE`) — see W1.

## Watch items (vectors, not holes — the control plane itself)

- **W1 — staging pins are manual and will be wiped.** `deploy-staging.sh`
  applies env with full-replacement `--set-env-vars` (`:187,212`) from bases
  with **zero** `LLM_PROVIDER_*` pins (`:104,113`). Next full staging deploy
  silently reverts dm_coach AND translate to Meta-direct. Fix: pin all seven
  surfaces + global in the script (deploy change, founder-approved).
- **W2 — `FLAG_*` env is the highest-priority layer and the morning's flip
  vector.** Nothing in code prevents a future `FLAG_LLM_ROUTE_*=vertex`;
  prevention is deploy discipline + this audit. Consider a staging/prod
  env-parity check (`scripts/env-parity-check.sh`) that fails on any
  `FLAG_LLM_*`/`FLAG_VOICE*` pin.
- **W3 — Firestore `config/feature_flags` + legacy `config/llm_routing` can
  re-flip transport without a redeploy** (by design, via `scripts/flags.py`).
  Treat flags-write access as production-inference access.
- **W4 — prod `deploy-agent.sh:44` pins `GEMINI_LIVE_USE_DEV_API=true`** and
  `deploy-api.sh:44-47` flips practice→meta on `--hackathon`. Both are
  intentional; both are direct-provider arming — keep them in the
  founder-decision category.
- **W5 — stale docstring:** `config.py:380-383` says
  `llm_inference_fallback` defaults true; the code default is **false**
  (`config.py:1159-1161`). Doc fix only.
- **W6 — local scripts pin Vertex deliberately:** `scripts/seed_demo_accounts.py:60-62`,
  `scripts/verify_demo_accounts.py:21-23` set `FLAG_LLM_ROUTE_*=vertex` for
  local runs. Out of scope (never deployed); noted so nobody "fixes" them.

## Appendix — every routing env var read in `functions/bootstrap/`

Transport: `FLAG_LLM_ROUTE_{JSON,VISION,CHAT}`, `FLAG_VOICE_PROVIDER`,
`FLAG_LLM_PERCENT_{JSON,VISION,CHAT,VOICE}`, `FLAG_LLM_ALLOWLIST_*`,
`FLAG_LLM_FALLBACK_TO_GOOGLE`, `LLM_ROUTE_{JSON,VISION,CHAT}`,
`VOICE_PROVIDER`, `LLM_PERCENT_{JSON,VISION,CHAT,VOICE}`,
`LLM_INFERENCE_FALLBACK`, `USE_VERTEX`, `VERTEX_LOCATION`,
`GEMINI_LIVE_USE_DEV_API`, `GOOGLE_API_KEY`, `LIVEKIT_INFERENCE_URL`,
`INFERENCE_{JSON,CHAT,LIVE}_MODEL`, `INFERENCE_TIMEOUT_SECONDS`.
Vendor/voice: `LLM_PROVIDER`, `LLM_PROVIDER_{CHAT,MATCHING,REPORTS,PRACTICE,
VOICE,VOICE_MAIN,DM_COACH,TRANSLATE}`, `LLM_META_FALLBACK`,
`AYMA_BRAIN_DEFAULT`, `META_API_KEY`, `META_API_BASE_URL`, `META_CHAT_MODEL`,
`META_REASONING_EFFORT`, `META_CASCADE_{STT,TTS,TTS_VOICE,TTS_VOICE_FEMALE,
TTS_VOICE_MALE,VAD}_MODEL`, `VOICE_OPENAI_REALTIME`, `OPENAI_REALTIME_MODEL`,
`OPENAI_API_KEY`, `OPEN_WEIGHTS_BASE_URL`, `OPEN_WEIGHTS_MODEL`,
`OPEN_WEIGHTS_API_KEY`, `META_OPEN_WEIGHTS_MODEL`,
`VOICE_CASCADE_{STT,TTS,LLM}_MODELS`, `VOICE_CASCADE_EXTRA_BRAINS`,
`VOICE_CREDITED_PROVIDERS`. Retrieval (non-LLM): `FLAG_VERTEX_AI_SEARCH`,
`VERTEX_AI_SEARCH`, `VERTEX_AI_SEARCH_DAILY_CAP`. Dead: `META_TRANSCRIBE_MODEL`.
