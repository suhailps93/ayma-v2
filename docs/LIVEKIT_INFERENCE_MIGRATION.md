# Moving Gemini traffic to LiveKit Inference

Branch `livekit-inference` (not merged, nothing deployed). Researched and tested 2026-10-25.
Every claim below is either linked to a source or marked **[verified live]** (a real call
through the gateway with this project's `LIVEKIT_API_KEY`/`SECRET`) or **[unknown]**.

## 0. Read this first: the credits probably do not pay for Gemini

The goal was "run Gemini through LiveKit Inference so the $17k credits pay for it". The
program terms say otherwise, and this must be confirmed with LiveKit in writing **before** any
production traffic moves.

| What the founder received | What the terms say it covers |
|---|---|
| $10,000 LiveKit **Cloud** credits + 1 year of the Scale plan | "agent session minutes, media/data transfer, telephony, and observability" ([livekit.com/startups](https://livekit.com/startups)) |
| $7,000 **Inference** credits | Not one pool. "$1,000 with each of seven participating inference partners" ([PR correcting the split](https://github.com/sourcey/startup-credits/pull/1746)): AssemblyAI, Deepgram, Fish Audio, Gradium, Inworld, Rime and Gemma 4 31B. **Gemini is not on the list.** |
| Credit rules | "non-interchangeable"; "each pool of credits draws down on its own"; "Credits expire 12 months from the date they are issued"; "LLM pricing, Gemma included, is the same on every plan" ([startups page](https://livekit.com/startups), [launch post](https://livekit.com/blog/introducing-livekit-startups)). |

So: Gemini calls through Inference are billed at LiveKit's list price (identical to Google's, see
section 3). Whether the Cloud pool, the partner pool, or the Scale plan's "$50/month inference
credits" ([pricing](https://livekit.com/pricing)) is debited for a Gemini token is **[unknown]**.
Ask LiveKit (startups contact) the exact question: *"Do Startup Program credits (Cloud or
Inference) apply to google/gemini-3.8-flash and google/gemini-3.8-live on LiveKit Inference?"*
The test calls made for this research (about 30 requests, a few cents) will show up in the Cloud
dashboard billing page; check which balance moved. If the answer is no, this branch still gives a
safe provider switch, but there is no cost reason to flip it.

Also observed **[verified live]**: this project's gateway returns `x-livekit-inference-rpm-limit: 100`
and `tpm-limit: 600000`, which are the **Build-plan** limits ([quotas](https://docs.livekit.io/deploy/admin/quotas-and-limits/)),
and no `credits-limit` header. Either the Scale plan is not attached to project `aimma-wt34nu3l` yet
or Scale uses the same LLM limits. 100 requests/minute is below what a matching cron plus chat can
burst, so the Vertex fallback (section 5) matters.

## 1. How Inference works (source-verified)

Sources: [Inference overview](https://docs.livekit.io/agents/models/), [LLM models](https://docs.livekit.io/agents/models/llm/),
[Realtime models](https://docs.livekit.io/agents/models/realtime/), [pricing](https://livekit.com/pricing/inference),
and the installed `livekit-agents` 1.7.1 / 1.8.9 source (`livekit/agents/inference/`).

* **It is an OpenAI-compatible gateway** at `https://agent-gateway.livekit.cloud/v1` (default in
  `inference/_utils.py`, override `LIVEKIT_INFERENCE_URL`). `inference.LLM` is just `openai.AsyncClient`
  pointed there.
* **Auth**: a bearer JWT signed with `LIVEKIT_API_KEY`/`SECRET`, with an `InferenceGrants(perform=True)`
  grant, 10-minute TTL. `livekit-api` 1.2.1 (already in `requirements.txt`) can mint it.
* **It works standalone**, outside any `AgentSession`, from the FastAPI backend **[verified live]**.
  The docs only describe the `AgentSession` path; the gateway does not need one.
* Deployment behind it for Gemini is **Google AI Studio (Developer API)**, not Vertex
  (`x-livekit-inference-llm-deployment: google/standard_aistudio`) **[verified live]**. Data
  residency/DPA therefore differs from our current Vertex path; LiveKit states zero data retention
  by default.
* Not on the gateway **[verified live]**: embeddings (404), image generation/edit models
  (`google/gemini-2.5-flash-image` not found), Gemini TTS. LiveKit's TTS list is Cartesia/Rime/Inworld/etc.

### What passes through for text (`/chat/completions`) **[verified live, google/gemini-3.8-flash]**

| Capability | Result |
|---|---|
| System prompt, temperature, `max_tokens` | Works. |
| JSON schema (`response_format: json_schema`) | Works; output followed the schema, including `enum` and nested arrays (matching + wiki runs in section 4). |
| Function calling incl. parallel calls | Works. Gemini thought signatures come back in `tool_calls[].extra_content.google.thought_signature`; we replay the assistant message verbatim. |
| Image input (data URL) | Works (a red 8x8 PNG was read as "Red"). Quality on real photos **not tested**. |
| `reasoning_effort` (low/medium/high) | Accepted. `extra_body.google.thinking_config` also accepted (effect unverified). |
| Google Search grounding | **Does not work.** `tools:[{google_search:{}}]` and `web_search_options` are silently ignored; the model answered a "most recent Super Bowl" question from stale training data. |
| URL context, Maps grounding | Not available (same reason). |
| Usage object | `prompt_tokens`, `completion_tokens` (**includes reasoning tokens**), `prompt_tokens_details.cached_tokens` (always 0 in my probes, so cache hits are **[unknown]**). |
| Models accepted | `google/gemini-3.8-flash`, `google/gemini-3.7-flash` (works but is **not listed/priced**), `google/gemini-3.5-flash-lite`. |

### Realtime (voice)

`inference.RealtimeModel("google/gemini-3.8-live")` exists only from **livekit-agents 1.8**
(`livekit/agents/inference/realtime/openai.py`; absent in our pinned 1.7.1). It is an adapter that
speaks the **OpenAI Realtime protocol** to the gateway, which translates to Gemini Live. I opened a
raw session **[verified live]**: `session.update` with instructions + voice `Aoede` was accepted
(echoed back), a text turn returned streamed audio plus `response.output_audio_transcript.delta`
and a `response.done` with a token usage object (`input_token_details.audio_tokens/text_tokens`,
`output_token_details`). Output transcription arrives, so captions and `raw_turns` keep working.

What the protocol cannot carry (our `agent.py:237-372` tuning):

| Our setting | Via Inference |
|---|---|
| temperature 0.9 | Ignored (`temperature` is "deprecated, unused in v1" in the adapter; `session.updated` did not echo it). |
| Start/end-of-speech sensitivity (`low`) | Not expressible. Only OpenAI `server_vad` fields `threshold`, `prefix_padding_ms`, `silence_duration_ms`; whether the gateway maps them onto Gemini's detector is **[unknown]**. |
| Sliding-window context compression (the main voice-cost lever, see `context_opt.py`) | Not expressible. If the gateway does not compress, a long call re-bills a growing context. **[unknown]**, must be measured. |
| Affective dialog, proactivity, language hint (`ml-IN` etc.) | Not expressible. |
| Native Gemini transcription | Output side works; input transcription model is OpenAI-style (`whisper-1` accepted); accuracy for romanised Indian languages **[unknown]**. |
| Function tools | Supported by the adapter; not exercised end to end. |
| Mute-by-`speech_created` interrupt, `maybe_open_conversation`, relay of metrics | Written against the Google plugin's capabilities; **[unknown]** on the OpenAI-protocol session. Needs a real call. |

Concurrency: Build plan allows 5 realtime connections, Scale 50 ([pricing](https://livekit.com/pricing)).

### 1b. Live probes, 2026-10-25 (branch re-test; about 35 tiny gateway calls, well under $0.10)

Method: raw websocket to `wss://agent-gateway.livekit.cloud/v1/realtime?model=google/gemini-3.8-live` (same
as `inference.RealtimeModel` in livekit-agents 1.8.9). `session.updated` echoes **only** `voice`,
`instructions`, `output_modalities`, `model`; it echoes nothing else, not even `turn_detection`, so an echo proves
nothing and every setting was tested by behaviour. Unknown fields (`zz_bogus_field`) are silently accepted,
so "accepted" is also not evidence. The 1.8.9 source has no `extra_body`/provider-options passthrough on
`inference.RealtimeModel` (its constructor takes only voice, modalities, transcription, noise reduction,
turn_detection, tool_choice, speed, tracing, truncation, reasoning); the session payload is the plain
OpenAI `RealtimeSessionCreateRequest`.

| Setting | Sent as | Result |
|---|---|---|
| End-of-speech silence | `turn_detection.silence_duration_ms` | **Honoured.** Audio: speech, 1.2 s gap, speech. 300 ms gave two committed turns (at 1.4 s and 2.6 s); 2500 ms gave one merged turn with the transcript of both clips. Already passed by `build_inference_realtime_model`. |
| `prefix_padding_ms` | `turn_detection.prefix_padding_ms` | Accepted; no observable effect available in the events. **Unproven**, still passed (harmless). |
| VAD `threshold` 0.99 | `turn_detection.threshold` | **Not honoured** (same two turns as the default). |
| Semantic VAD `eagerness: low` | `turn_detection.type=semantic_vad` | **Not honoured** (split at the gap like the default). |
| Gemini start/end sensitivity and `silence_duration_ms` | top-level `realtime_input_config.automatic_activity_detection` | **Not honoured** (with `server_vad` 300 ms also set, the turn still split at the 1.2 s gap despite a 2500 ms value here). |
| Context compression | top-level `context_window_compression` (trigger 1500 / target 700) | **Not honoured.** 7 text turns of about 750 tokens: input tokens 1233, 1975, 2717, 3462, 4209, 4955, 5701, identical growth to the no-config run (1233 ... 5723). |
| OpenAI-native truncation | `truncation: retention_ratio 0.5, post_instructions 1500` | **Not honoured** (3478 input tokens at turn 4 against a 1500 limit). |
| Client-side trimming | `conversation.item.delete` of 3 old items | Acked (`conversation.item.deleted`) but **no effect**: next turn input tokens 4212 = continued growth. So a "simple" client-side trim through the realtime item API cannot work. The only real lever is a mid-call session restart with a trimmed seed, which is not simple and is not built. |
| Temperature | top-level `temperature` 0.0 vs 2.0 | **Inconclusive.** 4 samples of "invent a city name": temp 0 gave Vaeloria, Valthorion, Vaeloria, Thalorix; temp 2 gave four distinct names. Suggestive but within Gemini's own nondeterminism; the adapter itself marks temperature unused. Not wired. |
| Language hint | `audio.input.transcription.language="ml"` | **No visible effect** (English clip transcribed in English; a weak test). Not wired. |
| Affective dialog, proactivity | `enable_affective_dialog`, `proactivity` | Accepted silently, no observable behaviour change possible to test. Not wired. |
| Input transcription | gateway-side | **Works**: `conversation.item.input_audio_transcription.completed` with correct text for both clips; output transcript deltas also arrive. |
| `response.done` usage | | Present with audio/text token split (used by the ledger). |

Conclusion for voice: the gateway exposes the OpenAI Realtime surface, mapped onto Gemini Live. Of our direct-path
tuning only the end-of-speech silence duration survives. Cost control (compression) and false-trigger tuning
(start/end sensitivity) are lost, which keeps `VOICE_PROVIDER=inference` at "not recommended".

Chat-completions media (same session): JPEG, WebP and PNG images read correctly with a JSON schema;
`input_audio` with `format: "wav"` transcribed a real speech clip verbatim ("Hello, my name is Maya and I live in
Seattle."); `mp3`/`ogg`/`aac`/`flac` are decoder-validated (malformed-file error on junk); `m4a`/`webm`/`opus` are
accepted without validation, so correct decoding is unproven; an audio blob sent as `image_url` is rejected
("must be jpeg, png, webp, or gif"). Only wav and mp3 are therefore routed; the rest stay on Vertex.

Re-probe of items marked "keep on Vertex" (all confirmed still unsupported, 2026-10-25): `/embeddings` for
`google/gemini-embedding-2` and `-001` 404; `/audio/speech` (Gemini TTS) 404; `/images/generations` 404;
`google/gemini-2.5-flash-image` via chat "Error getting model definition"; `/batches` 404; `GET /models` returns `{}`
(no discovery); `tools:[{google_search:{}}]` and `web_search_options` accepted but ignored (model says it has no
real-time data).

### 1c. Voice context and transcript probes, 2026-10-25 (10 gateway sessions, 11 responses)

Run through livekit-agents 1.8.9's own `inference.RealtimeSession`, in the same order `AgentActivity` uses
(connect, `session.update` instructions, `conversation.item.create` chain, tools), then a user text turn asking
for a planted fact. **[verified live]**

| Seeding method | Result |
|---|---|
| Fact in `instructions` (175 chars; and 17k chars with the fact at the very end) | Recalled ("Biscuit"). |
| Fact only in seeded history items (short and 17k-char instructions) | Recalled. |
| History items + instructions + 3 function tools | Both facts recalled. |
| Opener: `generate_reply(instructions=...)` on top of a 17k-char session prompt | Used the session fact ("how are you and Biscuit doing?"). |

The agent warning `placed a chat history item after an unknown item; appended it instead` is benign: the gateway
echoes the literal `previous_item_id: "root"` for the first seeded item, the 1.8.9 adapter only treats `None` as
the root, so it appends at the tail, which on an empty context is the root. Later items chain to real ids.

Audio turns (speech generated by the gateway, streamed back in at real-time pace): `speech_started` and
`speech_stopped` arrive together at the end of the utterance, then `input_audio_transcription.completed`
(about 40 ms later, before `response.created`), so user captions are final-only and precede the reply. The
transcription `language` field is ignored (`ja` on English speech still gave English), so the transcript is the
gateway's own Gemini transcription and cannot be steered to the user's language.

Re-probe 2026-10-26 (founder call drifted into Spanish after "el número" / "murió" were transcribed): gateway-spoken
clips streamed into fresh `inference.RealtimeModel` sessions with `input_audio_transcription` set. A Spanish clip gave
`¿Cuándo? ¿A qué hora?` with the default, with `language="en"`, and with `language="en"` plus an English-only
`prompt`; an English clip gave the same English text with `language="es"` plus a Spanish `prompt`. Both `language`
and `prompt` are ignored, so neither is wired. The levers we do control: `prompts/voice_language.md` in the session
instructions (default language, never switch over a short misheard fragment) and the agent's misheard-fragment
tool guard (`agent.misheard_fragment_guard`).

## 2. Call-site verdicts

"Flag" = the switch in section 5. Effort is for this branch (done unless stated).

| # | Call site | Verdict | Risk | Effort | Why |
|---|---|---|---|---|---|
| 1 | JSON jobs via `gemini.generate_json`: matching_skill, icebreakers, explore, wiki_ingest, story, ai_assessment, reengagement, completeness, career_timeline, profile_manual, dm_moderation, persona_evolution, context_opt, dm_ingest (text) | **Move to Inference** (`LLM_ROUTE_JSON`) | Low-Med | Done | Schema + temperature + max tokens all pass through. Same price, newer model, side-by-side parity (section 4). Free-form quirks: `max_tokens` includes thinking on both paths. |
| 2 | Vision JSON: body_report, face_report, appearance, physical_attributes, photo_attrs, photo_pipeline (caption), photo_moderation, deep_dive_images, dm_ingest (photo caption **and** wav/mp3 voice-note transcription) | **Routable** (`LLM_ROUTE_VISION`, default Vertex) | Med-High | Done, tested (parametrised over all 8 features) | Image (jpeg/png/webp/gif) and `input_audio` (wav, mp3) work **[verified live]**, section 1b. Quality on real faces/bodies/moderation is still unevaluated and photos leave the Vertex project, so keep it off until reviewed. Inference failure/empty/filtered output falls back to Vertex; moderation still fails closed if both fail. Media the gateway cannot take (HEIC, m4a, webm, ogg, aac) skips Inference and goes straight to Vertex, untagged as a fallback. |
| 3 | Text chat `generate_reply_events` incl. function calling, thinking level, image | **Move, with a work-around** (`LLM_ROUTE_CHAT`) | Med | Done | Tools, thought signatures, images, thinking effort pass through. Grounding does not, so see row 4. First-call failure falls back to Vertex before any tool has run. |
| 4 | Chat grounding (Google Search, url_context, Maps) | **Work-around**: a `web_search` function tool answered by a small grounded **Vertex** `research()` call | Med | Done | Same search quality (it is the same Google grounding) and source URLs; costs an extra round trip (about +2-6 s on turns that search) and one extra Vertex call per search. Chat turns that do not search never touch Vertex. Maps grounding is dormant today (no key) and is dropped on this path. |
| 5 | `gemini.research` (deep_dive, skills) | **Keep on Vertex** | n/a | 0 | Pure Google Search grounding + `grounding_metadata` URLs; no Inference equivalent. |
| 6 | Voice agent (Live) | **Behind a flag, not recommended yet** (`VOICE_PROVIDER=inference`) | **High** | Done (builder); needs a real-call test | Only `silence_duration_ms` is honoured; sensitivity, compression, temperature, affective dialog, proactivity and language hint are silently ignored (section 1b). Cost effect unknown. Needs livekit-agents 1.8.9 (now the only agent image, `requirements-agent.txt`). |
| 7 | `voice_preview` TTS (`gemini-2.5-flash-preview-tts`) | **Keep on Vertex** | n/a | 0 | No Gemini TTS on the gateway; previews must match the Live voice presets. |
| 8 | Image generate/edit (`gemini-2.5-flash-image`) | **Keep on Vertex** | n/a | 0 | Model not on gateway. |
| 9 | Embeddings `media_embed.py` (`gemini-embedding-2`, 2048-d stored index) | **Keep on Vertex** | n/a | 0 | Embeddings endpoint 404; changing model would invalidate the stored vector index anyway. |
| 10 | `gemini_batch.py` / wiki_lint (Batch API) | **Keep on Vertex** | n/a | 0 | Batch is half price; Inference has no batch tier, so moving would double the cost of those tokens. |
| 11 | `token_ledger` metering | **Adapted** | Low | Done | New models priced; `inference_llm` returns `usage_metadata`-shaped objects so `record()` is unchanged; `live_model_id()` follows `VOICE_PROVIDER`. |

## 3. Models and prices (per 1M tokens)

From [livekit.com/pricing/inference](https://livekit.com/pricing/inference) (input / cached input / output):

| Model | In | Cached | Out | Note |
|---|---|---|---|---|
| **Gemini 3.8 Flash** `google/gemini-3.8-flash` | 0.75 | 0.075 | 3.75 | Same price as our `gemini-3.7-flash` ($0.75/$3.75); published benchmarks improve over 3.7 on every listed test ([review](https://felloai.com/gemini-3-8-flash/)). **Recommended.** |
| Gemini 3.5 Flash | 1.50 | 0.15 | 9.00 | 2x price, no reason. |
| Gemini 3.5 Flash Lite | 0.30 | 0.03 | 2.50 | Cheaper; candidate for moderation-type JSON after its own eval. |
| Gemini 3.1 Flash Lite | 0.25 | 0.025 | 1.50 | Cheapest; quality not evaluated. |
| Gemini 3 Flash (preview) | 0.50 | 0.05 | 3.00 | Older generation. |
| Gemini 3.1 Pro (preview) | 4.00 | 0.40 | 18.00 | Not needed. |
| Gemini 4 Argon | 4.00 / 2.00 | 0.20 / 0.10 | 20.00 / 10.00 | Priced in two tiers; not evaluated. |
| Gemini 3.8 Live (and extended-thinking variant) | audio 3.00 in / 12.00 out; text 0.75 in / 4.50 out; image 1.00 in | | | Token-billed, **same rates as Google direct**. |
| Current: `gemini-3.7-flash` on Vertex | 0.75 | | 3.75 | Introductory; Google lists a rise to $1.50/$7.50 on 2027-01-01 ([source](https://felloai.com/gemini-3-8-flash/)). Whether LiveKit's 3.8 Flash price follows is **[unknown]**. |

Others on the gateway (not evaluated): OpenAI gpt-5.x, Kimi k2.5/k2.6, DeepSeek v3/v3.2, GLM 5.1, Grok 4.x, Gemma 4.

**Recommendation: `google/gemini-3.8-flash` for both chat and JSON jobs** (`INFERENCE_JSON_MODEL` /
`INFERENCE_CHAT_MODEL`; **needs founder approval, not applied**). It is not a downgrade (newer, same price) and the
side-by-side in section 4 agreed.

`LiveKit Inference "per minute" $0.0182/min` for Live (quoted in the brief): the pricing page I
could read lists only token rates. I found no per-minute billing; usage came back as tokens. Treat
$0.0182/min as an estimate of a typical call, not a rate.

## 4. Side-by-side quality evaluation

`functions/bootstrap/scripts/llm_side_by_side.py` runs identical prompts through production code on
both routes (`gemini-3.7-flash` on Vertex vs `google/gemini-3.8-flash` on Inference), then a judge
(always Vertex, order randomised) picks a winner. Cases: the 11 persona regression scenarios
already in `persona_eval_scenarios.json` (chat), the real `prompts/matching_skill.md` over 3
synthetic pairs (also run twice on Vertex to measure its own noise), and the real
`prompts/wiki_ingest.md` over 2 synthetic transcripts. Synthetic data only; no user data.

Results (candidate `google/gemini-3.8-flash` on Inference vs locked `gemini-3.7-flash` on Vertex):

| Suite | Result |
|---|---|
| Matching (3 pairs, JSON schema, temp 0) | Judge: Inference won 2, Vertex 1 (mean judge score 9.2 vs 8.7). Both returned all 7 dimensions. Mean absolute dimension-score difference Vertex-vs-Inference 3.6 / 3.3 / 7.0 points (0-100 scale); Vertex-vs-Vertex run-to-run noise 1.7 / 5.0 / 0.0, so the model gap is within about 2x of the existing noise (the 7-point case is the thin-profile pair). Per call: Vertex about 3.2k in / 0.8k out tokens, 14.5 s; Inference about 2.8k in / 0.9k out, 9.4 s. Cost per call identical at list price ($0.0055 vs $0.0054). |
| Chat (11 persona scenarios, no tools) | 8 scenarios completed: Inference 4 wins, Vertex 3, tie 1. **Vertex `gemini-3.7-flash` chat timed out (75 s) on 2 of 11 first-try calls** (onboarding_tone, flirty_casual_banter) and one case never finished; the Inference side never timed out. The eval host is a laptop, so this is a hint about Vertex chat latency, not proof. Fallback-on-failure in prod is the same mechanism that already exists as the 75 s timeout. |
| Wiki ingest (2 transcripts) | **Not completed**: first attempt hit a bug in the eval script (fixed), the rerun stalled for 15+ minutes without output and was killed. Treat wiki quality as untested; run `--only wiki` before moving that feature. |
| Tool calling, grounding, images, parallel tools | Verified mechanically (section 1) and by unit tests; not quality-compared. |

The scripts print per-case winners and write a JSON report with `--out`.

Limits of this evidence: 16 cases, an LLM judge, one run. It shows "no obvious regression", not
statistical equivalence. Vision, tool-calling quality in real conversations and non-English were
not covered; the test plan in section 6 closes those gaps on a real revision.

## 5. What was built (branch `livekit-inference`)

**Model lock respected.** No production model id was changed or added as a default. Every route
defaults to Google (Vertex / Developer API), and the Inference model defaults are the *same* locked
models (`google/gemini-3.7-flash`, `google/gemini-3.8-live` = our `gemini-3.8-live`). The
recommended candidate (`google/gemini-3.8-flash`) is only ever selected by setting
`INFERENCE_JSON_MODEL` / `INFERENCE_CHAT_MODEL`, which needs the founder's explicit approval.
Nothing was flipped, deployed or purchased.

### Four feature groups, one switch each

| Group | Covers |
|---|---|
| `json` | all text `generate_json` jobs (matching, wiki, icebreakers, explore, ...) |
| `vision` | `generate_json` calls with images |
| `chat` | `generate_reply_events` (text chat, tools, search) |
| `voice` | agent worker Live session (decided once per call) |

### Where the setting comes from (highest priority first)

0. **Since `all-features-on`: the feature flags** (`config/feature_flags`, `FLAG_<NAME>` env pins; see
   `docs/FEATURE_FLAGS.md`) take precedence. `config/llm_routing` below is still read as a legacy layer under them.
1. **Firestore doc `config/llm_routing`** (runtime, no redeploy, cached 60 s per instance). Unreadable or
   malformed doc: logged, last good value (or env) used.
   ```
   {"json":   {"provider": "inference", "percent": 25},
    "chat":   "vertex",
    "voice":  {"provider": "inference", "percent": 10},
    "vision": "vertex",
    "fallback": true}
   ```
   `provider` is `vertex` or `inference`; `percent` (0-100, default 100) is the share of calls
   (voice: of new calls) sent to Inference when the provider is `inference`, the rest stay on
   Google. A bare string means percent 100. Missing groups fall through to env.
2. **Env vars** (`config.py`, defaults = today's behaviour):

| Env var | Default | Effect |
|---|---|---|
| `LLM_ROUTE_JSON`, `LLM_ROUTE_VISION`, `LLM_ROUTE_CHAT` | `vertex` (`inference` on `all-features-on`) | `vertex` or `inference`; a typo fails at boot |
| `VOICE_PROVIDER` | `google` (`inference` on `all-features-on`) | `google` or `inference` |
| `LLM_PERCENT_JSON`, `_VISION`, `_CHAT`, `_VOICE` | `100` | rollout share when routed to Inference |
| `LLM_INFERENCE_FALLBACK` | `true` (`false` on `all-features-on`) | Inference failure/timeout -> one retry on Google |
| `INFERENCE_JSON_MODEL`, `INFERENCE_CHAT_MODEL` | `google/gemini-3.7-flash` | model ids (same locked model) |
| `INFERENCE_LIVE_MODEL` | `google/gemini-3.8-live` | |
| `LIVEKIT_INFERENCE_URL` | `https://agent-gateway.livekit.cloud/v1` | non-secret |
| `INFERENCE_TIMEOUT_SECONDS` | `75` | |

### How to flip (both directions, no code change)

* Firebase console > Firestore > `config` > `llm_routing` (create the doc if absent), or
  `gcloud firestore documents` / Admin SDK. Examples:
  * all JSON jobs to Inference: `json = {"provider":"inference","percent":100}`
  * 20 % of chat as an A/B: `chat = {"provider":"inference","percent":20}`
  * emergency back to Google: set the group to `"vertex"` (or delete the field); effective within
    about 60 s per instance. Voice applies to the next call.
  * disable automatic fallback: `"fallback": false`.
* The doc overrides env, so after an experiment delete the field to return to the env default.

### Fallback (non-voice only)

On any Inference error or timeout the call is retried once on Google. JSON: any failure. Chat: only
the first model call (before any tool has run, so no side effect repeats). Voice never falls back
mid-call. Fallback calls are logged (`falling back to Vertex`) and recorded in the ledger
(next section).

### Spend tracking fields (stable contract for the dashboard)

Every ledger write now carries a provider.

`users/{uid}/spend_events/{id}`: existing fields plus
* `provider`: `"google_vertex"` | `"google_dev_api"` | `"livekit_inference"`. **Absent on rows written
  before this change; readers must treat absent as `"google"`.**
* `model`: model id (Inference ids are `google/...`), `feature`: feature bucket (unchanged).
* `fallback_from`: `"livekit_inference"` only when the call ran on Google because Inference failed.
* `cost_usd`: computed from `_MODEL_PRICING` in `token_ledger.py` (LiveKit per-model prices added
  there, none hardcoded elsewhere).

`users/{uid}.token_usage.providers.<provider>` (running buckets, absent until first write):
`tokens`, `cost_usd`, `features.<feature>` (tokens) and `fallbacks` (count of calls that ran on
this provider because the other failed).

Provider is inferred by `token_ledger.provider_for(feature, model)`: a `google/...` model id is
`livekit_inference`; voice with `GEMINI_LIVE_USE_DEV_API` is `google_dev_api`; everything else
`google_vertex`.

Voice via Inference is priced **per token** from the realtime `response.done` usage object
(verified live: `input_tokens`, `output_tokens` with audio/text split) at the Gemini 3.8 Live rates
($3 / $12 per M, same as direct). The $0.0182/min figure is a listed estimate, not a metering unit,
so no per-minute pricing path was added; if LiveKit later bills per minute, add it to
`_MODEL_PRICING` and the ledger. The existing voice ledger prices all tokens at the audio rate
(conservative: the gateway reports text tokens at $0.75 in).

### Files

`llm_routing.py` (runtime switch), `inference_llm.py` (gateway client, JWT from env, retries,
usage adapter), `gemini.py` (route switches, Inference chat loop, `web_search` tool, fallback
tagging), `config.py`, `token_ledger.py` (pricing, `provider_for`, provider fields,
`live_model_id(inference=)`), `agent.py` (`build_inference_realtime_model`, session-accurate
model for metering), `requirements.txt` (`openai`), `requirements-agent.txt` (livekit-agents 1.8.9; the former `requirements-agent-inference.txt` variant was folded into it),
`Dockerfile.agent` / `cloudbuild.agent.yaml` (optional `REQUIREMENTS` build arg, default
unchanged), `tests/test_inference_routing.py`, `scripts/llm_side_by_side.py`.

Credentials: `LIVEKIT_API_KEY`/`SECRET` are already mounted on both Cloud Run services; nothing
new to provision.

## 6. Test plan (on a test Cloud Run revision, nothing on main)

Do not deploy from this branch to the live traffic split. Create tagged, zero-traffic revisions.

1. **Gate on the credit question** (section 0). Do not proceed if Gemini is not covered.
2. **Offline**: `cd functions/bootstrap && python -m pytest -q` (only known failure:
   `tests/test_monitoring.py::test_capture_is_noop_when_uninitialised`).
3. **Side-by-side with real prompts** (needs ADC for Vertex and the two LiveKit secrets in env):
   ```
   export LIVEKIT_API_KEY=$(gcloud secrets versions access latest --secret LIVEKIT_API_KEY --project ayma-ai)
   export LIVEKIT_API_SECRET=$(gcloud secrets versions access latest --secret LIVEKIT_API_SECRET --project ayma-ai)
   cd functions/bootstrap && INFERENCE_JSON_MODEL=google/gemini-3.8-flash INFERENCE_CHAT_MODEL=google/gemini-3.8-flash \
     python scripts/llm_side_by_side.py --out /tmp/ab.json
   ```
   Then add 5-10 of your real, anonymised wiki pairs to `scripts/llm_ab_fixtures.json`.
4. **API test revision** (JSON + chat):
   `gcloud run deploy ayma-api --image <branch image> --no-traffic --tag lk-inf`, then set the
   `config/llm_routing` doc (section 5) to flip groups. Using the 3.8 candidate additionally needs
   `--update-env-vars INFERENCE_JSON_MODEL=...,INFERENCE_CHAT_MODEL=...` and founder approval
   (deploy via the normal `deploy-api.sh` flow adapted for `--no-traffic --tag`; the build installs
   the new `openai` dependency). Point a debug build of the app at the tagged URL, or hit it with
   the founder account. Check: chat with a tool call (e.g. ask Ayma to remember something), chat
   with "what is the weather in X today?" (must show "Searched the web"), a pasted URL, a photo in
   chat, the matching and icebreaker screens, Credits screen real-money rows (model shown as
   `google/gemini-3.8-flash`, cost matches tokens x rate).
5. **Watch**: Cloud Logging for `LiveKit Inference failed ... falling back to Vertex` (should be
   rare), the response headers `x-livekit-inference-rpm-used` during a matching cron, the LiveKit
   Cloud dashboard billing page (which balance moved), and `spend_events` per-feature cost vs the
   same feature on Vertex.
6. **Voice (only if 1-5 look good)**: build the agent image with
   `--substitutions _IMAGE=<test tag>` (the default `requirements-agent.txt` already pins 1.8.9), deploy to a
   tagged zero-traffic `ayma-agent` revision with `VOICE_PROVIDER=inference`. Make 3 real calls of
   5+ minutes each, including: interrupting her, a long silence mid-sentence, a tool call, saying
   "shut up", Malayalam/English mixed speech, and a 10-minute call to see whether input tokens per
   turn grow without bound. Compare `voice-usage` log lines (in/out tokens per turn) and
   $/minute with a Vertex-direct call of the same length. Pass criteria: no more false turn
   triggers than today, no cut-offs, $/min not above today.

## 7. Rollback

Fastest: set the group(s) to `"vertex"` in the Firestore doc `config/llm_routing` (about 60 s; no
redeploy). Also possible: env `LLM_ROUTE_*=vertex`, `VOICE_PROVIDER=google`, or route traffic back
to the previous revision. No data migration. With fallback enabled (default) (default) an outage or exhausted credits
degrades to Vertex automatically. Ledger rows written during the test keep their
`google/...` model id and stay correctly priced.

## 8. Estimated monthly cost per path

Unit costs, measured from `users/*/spend_events` in prod (a small, test-heavy sample: 263 text
calls, 120 voice turns, so treat as order-of-magnitude):

| Path | Measured per unit on `gemini-3.7-flash` | Same on Inference 3.8 Flash |
|---|---|---|
| Chat turn | about 5.9k in / 54 out tokens = $0.0047 | same list price: $0.0047 (A/B run: token usage within a few percent) |
| Wiki ingest | about 6.9k in / 160 out = $0.0057 | same |
| Matching score | about 8k in / 640 out = $0.0084 | same (A/B: 2.8k in / 0.9k out per call, $0.0054) |
| Voice, active call | $0.12 to $0.26 per minute (3 short sessions; context re-billing dominates). Whole-sample average $0.0095/min because one 268-minute session was mostly idle. | If billed per token at the same $3/$12: same or worse (no compression knob). If billed at LiveKit's quoted $0.0182/min: about 85% cheaper. **[unknown]**, decided by test step 6. |

Illustrative month for 1,000 monthly users, each doing 40 chat turns, 10 wiki ingests, 3 matches,
20 voice minutes:

| Path | Vertex today | Inference | Difference |
|---|---|---|---|
| Text (chat + JSON) | about $0.32/user = **$320** | about **$320** (list price parity) | $0; saving exists only if credits cover it |
| Voice | 20 x $0.12 = **$2,400** | $2,400 if token-billed; $364 if the $0.0182/min figure is real | unknown |
| Infra not moved (embeddings, images, TTS, batch lint, grounded search) | unchanged | unchanged, plus a small Vertex bill for `web_search` tool calls | |

Text is about 12% of spend and voice about 80% (measured: voice $3.16 of $4.0 in the sample). So
even a perfect text migration cannot move the bill much; the money is in voice, which is also the
riskiest part to move.

On 2027-01-01 Google's introductory Flash price doubles; if LiveKit passes that through, no route
is cheaper than the other.

## 9. Open risks

1. Credits may not apply to Gemini (section 0). Biggest risk to the business case.
2. Rate limit 100 RPM / 600k TPM on this project today; crons that fan out will hit 429 and rely on the fallback.
3. Gemini via the gateway runs on AI Studio (Developer API), not Vertex: different data-handling terms for user conversations. Needs a privacy/ToS check (see `docs/PRIVACY.md`).
4. Voice parity is unproven: tuning lost, cost behaviour unknown, mute/opener logic untested on the OpenAI-protocol session, needs a livekit-agents minor-version jump (1.7.1 to 1.8.9) which itself needs regression testing.
5. Chat with search gains one hop of latency and keeps a Vertex dependency; the model decides when to search (today Google decides inside one call), so recall of "should have searched" may differ.
6. `google/gemini-3.7-flash` also works on the gateway but is unlisted and unpriced; do not rely on it.
7. Vision (faces/bodies/moderation) is routable but quality is unevaluated on real photos; default stays Vertex.
8. Single-run, small, LLM-judged evaluation.

## 10. Voice A/B test runbook (same model `gemini-3.8-live`, route only)

Voice provider is chosen **once per call** at session start in `agent._run_session`:
`llm_routing.route_for("voice", uid=...)`, from the Firestore doc `config/llm_routing` (cached 60 s per
instance), falling back to env `VOICE_PROVIDER` (default `google`). Doc shape:

```
{"voice": {"provider": "inference", "percent": 100, "allowlist": ["<founder uid>"]}}
```

* `allowlist` non-empty: only those uids can get Inference, everyone else stays on Google. `percent` applies
  inside the allowlist. Empty/absent: no restriction (then `percent` is a plain share of all new calls).
* Tagging: the agent logs `voice-provider uid=... provider=...` at call start; `users/{uid}/raw_turns/{session}`
  gets `voice_provider`; each `spend_events` row has `provider` (`google_dev_api` vs `livekit_inference`)
  and `token_usage.providers.<provider>` buckets accumulate separately. Metering uses the realtime
  `response.done` usage that livekit-agents turns into `RealtimeModelMetrics` (same handler for both paths).
* The agent image (`requirements-agent.txt`, livekit-agents 1.8.9) serves both the Google and the Inference path.
  `openai` comes transitively (>=3.19); the agent image does not install the API's `openai==2.46.0` pin.

**Known 1.7.1 -> 1.8.9 difference on the Google path** (diffed `livekit-plugins-google` `realtime_api.py`):
for `gemini-3.8-live`, 1.8.9 defaults `tool_behavior` to `NON_BLOCKING` (1.7.1: server default, blocking), no
reply placeholder for 3.8, new chat-ctx sync code, and `thinking_level` raises on the Dev API for 3.8 (we do not
set it). Our constructor kwargs are unchanged and `tests/test_agent.py` passes on both versions, but live tool
timing (the model can keep talking while a tool runs) must be eyeballed in step 4 even with the flag on `google`.

### Isolation: what is and is not possible

Dispatch is automatic (no `agent_name`): LiveKit hands each new room to any registered worker, so a second
worker (a tagged revision with `--min-instances 1`, or `python agent.py dev` locally) would also receive
**production** calls. True isolation needs an explicit agent name plus a `RoomAgentDispatch` in the token for
allowlisted users, which is a code change not made here. **Recommendation:** use the allowlist on the single
`ayma-agent` service, deployed in a quiet window. Only the founder's calls can touch Inference, and the Google
path is a one-field rollback. The only exposure for everyone else is the 1.8.9 plugin on the Google path
(above); to bound it, do step 4a first with the flag still `google`.

### Steps

1. **Deploy the agent from the branch** (does not change any flag):
   ```
   git checkout livekit-inference && cd functions/bootstrap
   gcloud builds submit --project ayma-ai --config cloudbuild.agent.yaml .
   cd ../.. && gcloud run services describe ayma-agent --project ayma-ai --region us-central1 \
     --format='value(status.latestReadyRevisionName)'     # note PREV for rollback
   gcloud run deploy ayma-agent --project ayma-ai --region us-central1 \
     --image us-central1-docker.pkg.dev/ayma-ai/cloud-run-source-deploy/ayma-agent:latest
   ```
   (`scripts/deploy-agent.sh` builds with the default 1.7.1 requirements, so use the commands above.
   Env vars and secrets are kept; `LIVEKIT_API_KEY/SECRET` are already mounted.)
2. **Find the founder uid and set the allowlist** (needs ADC for project `ayma-ai`):
   ```
   python - <<'EOF'
   import firebase_admin
   from firebase_admin import auth, firestore
   firebase_admin.initialize_app(options={"projectId": "ayma-ai"})
   uid = auth.get_user_by_email("suhailps@gmail.com").uid
   firestore.client().collection("config").document("llm_routing").set(
       {"voice": {"provider": "inference", "percent": 100, "allowlist": [uid]}}, merge=True)
   print(uid)
   EOF
   ```
   Takes effect on the next call after about 60 s. Leave the other groups untouched.
3. **Order**: after step 1, make the Google control call (4a) BEFORE running step 2, so the allowlist is not
   set until the new image is shown to behave as today on Google.
4. **Test calls** from the founder account in the app: (a) one on Google (new image), then (b) three on
   Inference, 5+ minutes each. Per call do: interrupt her mid-sentence; stay silent 5 s mid-sentence; ask
   something that needs a tool (e.g. "remember I like hiking"); say "shut up" then "Ayma, you can talk";
   say your name and a Malayalam/English mixed sentence; one 10-minute call.
5. **Read results**
   * Which path ran: `gcloud logging read 'resource.labels.service_name="ayma-agent" AND textPayload:"voice-provider"' --project ayma-ai --limit 20 --freshness 1h`
   * Tokens per turn and growth (context compression is lost on Inference, so input tokens grow every turn):
     same filter with `textPayload:"voice-usage"`; compare `in=` across turns and the `voice-usage session` total.
   * Dollars: `users/{uid}/spend_events` where `feature=="voice"`, group by `provider`; $/min = sum(cost_usd) / minutes.
   * Session record: `users/{uid}/raw_turns/{session_id}.voice_provider`.
   * Latency: LiveKit Cloud dashboard > Sessions/Agents insights for the room (first-audio latency); also judge by ear.
   * Checklist (pass = no worse than the Google control): false turn triggers / cut-offs, interruption works,
     mute ("shut up") holds and un-mutes on her name, opener fires, captions and `raw_turns` text present,
     tool call completes and she speaks the result, name recognised, no growth runaway in `in=`, $/min <= Google.
6. **Roll back (one edit)**: set `config/llm_routing` `voice.provider` to `"google"` (or delete the `voice`
   field); the next call after about 60 s is on Google. Calls in progress finish on Inference (no mid-call switch).
   To undo the image too: `gcloud run services update-traffic ayma-agent --project ayma-ai --region us-central1 --to-revisions <PREV>=100`.

## 9. Routing coverage audit (2026-10-25)

Every LLM feature (matching, icebreakers, explore, wiki, ai_notes, summary, story, reengagement, completeness,
career timeline, profile manual, moderation, persona evolution, deep-dive digests, photo/face/body/appearance reports,
chat) goes through `gemini.generate_json` / `generate_reply_events`, which consult `llm_routing.route_for` (now with
the caller uid, so per-user allowlists apply). Documented Vertex-only exceptions: `gemini.research` (Google Search /
URL-context grounding: deep dive, public-profile search, chat `web_search` tool), embeddings (`media_embed`), image
generation/edit, Gemini TTS (`voice_preview`), Batch API (`gemini_batch`, wiki lint sweep), media the gateway cannot
decode (HEIC, m4a, webm, ogg, aac), Cloud Vision reverse image search, and the unmetered client warm-up ping.
`tests/test_llm_call_site_coverage.py` fails on any new unlisted direct Google call. The agent worker image
previously lacked `openai`, so post-turn wiki/summary work run inside the worker could not use the gateway.
