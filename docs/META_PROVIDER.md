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
  for. Surfaces: `chat`, `matching`, `reports`, `practice`, `voice`, `dm_coach`,
  `translate`.
* **Per-surface flag `LLM_PROVIDER_<SURFACE>`** (`gemini` | `meta`), with
  `LLM_PROVIDER` as the default for any surface whose own var is unset. **All
  default to `gemini` EXCEPT `dm_coach` and `translate`, which default to
  `meta`** — the "Ayma in your DMs" assistant (§6.9: opener chips + live
  coaching) and cross-language DM translation (§6.12: `POST /dm/translate` —
  translate incoming/outgoing DM text) both run on the Muse/Meta brain by
  founder hackathon directive. Each still inherits a global `LLM_PROVIDER`
  override and the Gemini fallback.
* Model ids live only in `config.py` (per `AGENTS.md`): `META_CHAT_MODEL`
  (`muse-spark-1.3`), `META_OPEN_WEIGHTS_MODEL`
  (`meta-models/muse-spark-open-1026`, the $10k open-weights target),
  `META_TRANSCRIBE_MODEL` (`muse-voice-transcribe-1.0`, the Meta STT id — listed
  but **not usable over REST**, see "Voice cascade"), and `META_CASCADE_STT_MODEL`
  (`deepgram/nova-3`, the LiveKit Inference STT the cascade actually runs). Model
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

## Unified Brain (§13.10) — one per-user LLM for all text surfaces

The per-surface flags below are now the **deploy-time default**; the **user-facing** choice is a single per-user **Brain** (`ayma_brain_model`, `gemini` | `meta`) that drives every text surface. The text call sites resolve through `llm_provider.get_user_brain_provider(uid, surface, needs=<capability>)` instead of `get_llm_provider(surface)` directly: the user's brain when it has the needed capability, else Gemini. Capabilities per brain are the single source of truth in `llm_provider.BRAIN_CAPABILITIES` — **Gemini**: text/json/vision/web/tools; **Meta/Muse Spark**: text/json/tools (no vision, no web). So `web` and `vision` always resolve to Gemini (consistent with `get_vision_provider` and the Gemini-only deep-dive). API: `GET`/`POST /brain/preference`; default `AYMA_BRAIN_DEFAULT=meta`. Full detail: `docs/ARCHITECTURE.md` §13.10, `docs/FEATURE_FLAGS.md`.

## Wired surfaces

| Surface | Call site (unified-Brain resolver `get_user_brain_provider`, capability shown) |
|---|---|
| chat | `main.py` `_generate_chat_reply` (non-streaming) and the streaming `generate_reply_events` turn — `needs="vision"` with an image else `needs="tools"` |
| matching | `matching_skill._run_llm` — `needs="json"` |
| reports | `body_report.py`, `face_report.py` — vision, so routed via `get_vision_provider("reports")` (always Gemini) |
| dm_coach | `dm_assist.assist` (`POST /dm/assist`) — `needs="json"`; opener chips + live DM coaching (§6.9). Deploy default `meta`. |
| translate | `dm_translate.translate` (`POST /dm/translate`) — `needs="json"`; deploy default `meta`. |
| deep-dive / web research | `deep_dive.py` — web (`url_context`), stays Gemini-only |
| practice | not a text call site here — the Practice Date agent consumes `get_llm_provider("practice")` directly (voice/roleplay) |

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

## Status (2026-10-26) — live

1. **`META_API_KEY`** — ✅ in **Google Secret Manager** (`META_API_KEY`), the
   Cloud Run SA (`235381544962-compute@…`) granted `secretAccessor`, mounted in
   `deploy-api.sh` / `deploy-agent.sh`. Never committed, never a plaintext env
   var.
2. **Account Team ID `1115399524571844`** (Project `1115393394567311`); $150
   credit claim **submitted**. ⚠️ Until the credit posts to Billing → free
   credits, **every Meta call bills the card** — monitor usage.
3. **`META_API_BASE_URL`** — ✅ confirmed `https://api.meta.ai/v1` (authenticated
   `GET /models` returns 200 with our key).

### Eval (live, 2026-10-26, `scripts/meta_vs_gemini_eval.py --live`)

Both providers passed all four fixtures; **Muse Spark was faster on every case**
(e.g. match 1.5s vs Gemini 7.1s; report 1.8s vs 4.2s). Known quirk: on the
**reports** JSON schema Muse Spark sometimes emits a key with a trailing space
(`"strengths "`). `MetaProvider.generate_json` now strips whitespace from every
JSON key recursively, so the quirk can no longer drop a schema field.

### JSON reliability check for matching + reports (2026-10-27, live)

`MetaProvider` with the Gemini fallback **off** (raw failures visible), real
`META_API_KEY`: 5 match-scoring calls (`matching_skill` schema, temp 0) and 10
face + 10 body report calls all returned parseable, schema-valid JSON — every
required key present, no whitespace-padded keys, 0 failures. Match dimension
scores were stable across runs (e.g. 40-42 / 58-68). The report images were a
synthetic non-photo, so the `usable=false` shape was exercised; the earlier
four-fixture eval covers a real report. Because JSON failures raise inside
`generate_json`, `LLM_META_FALLBACK=true` re-runs the call on Gemini; only a
well-formed but semantically wrong answer is not caught by the fallback.

### Flipped surface

`practice`, `chat`, `matching` and `reports` → Meta (`LLM_PROVIDER_PRACTICE=meta`,
`LLM_PROVIDER_CHAT=meta`, `LLM_PROVIDER_MATCHING=meta`, `LLM_PROVIDER_REPORTS=meta`
in `deploy-api.sh`), with `LLM_META_FALLBACK=true` so any Meta hiccup degrades to
Gemini.
`dm_coach` (the DM assist opener/coach, §6.9) → Meta **by default** (founder
hackathon directive — no env var needed; the config default is `meta`), same
Gemini fallback. `voice` remains on Gemini. The
**Practice Date voice cascade** below is wired but gated OFF
(`LLM_PROVIDER_VOICE` default `gemini`).

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
| STT | Deepgram Nova-3 (`config.meta_cascade_stt_model`, default `deepgram/nova-3`) | `livekit.agents.inference.STT` via the LiveKit **Inference gateway** (LiveKit-credit covered, authed with the worker's `LIVEKIT_API_KEY`/`SECRET`) |
| LLM | Meta Muse Spark `muse-spark-1.3` (`config.meta_chat_model`) | `livekit-plugins-openai` `openai.LLM`, pointed at `config.meta_api_base_url` + the `META_API_KEY` secret, `reasoning_effort=config.meta_reasoning_effort` (`minimal` — Muse Spark is reasoning-only; omit it and replies come back empty) |
| TTS | Inworld (`config.meta_cascade_tts_model`, default `inworld/inworld-tts-1`; base `config.meta_cascade_tts_voice` optional, gender-matched `config.meta_cascade_tts_voice_female`/`_male` default to Inworld `Ashley`/`Alex`) | `livekit.agents.inference.TTS` via the LiveKit **Inference gateway** |
| VAD | Silero (`config.meta_cascade_vad_model`, default `silero`) | `livekit.agents.inference.VAD` — bundled, runs locally in the worker (the cascade has no server-side turn detection) |

**Why the STT leg is NOT Meta.** Meta's `muse-voice-transcribe-1.0` is listed in
`GET /v1/models` but Meta serves **no working OpenAI-compatible REST STT**: every
probed transcription path (`/v1/audio/transcriptions`, `/audio/translations`,
`/audio/transcribe`, `/transcriptions`, `/audio/speech`) returns 404, and only a
WebSocket `/v1/realtime` exists (400 on a plain POST). Pointing `openai.STT` at it
made the cascade die with a 404 on every utterance (`AgentSession is closing due
to unrecoverable error: 404`). The STT leg therefore runs on LiveKit Inference
while the **LLM leg stays Meta Muse Spark** — the "runs on Meta" story holds
(reasoning/conversation is Meta; STT/TTS are LiveKit-gateway infra either way).
`config.meta_transcribe_model` is kept only as the record of the Meta STT id.

The TTS vendor is **config, not hardcoded** — Rime (`rime/…`) and Fish
(`fishaudio/…`) are documented A/B alternatives reachable by setting
`META_CASCADE_TTS_MODEL`/`_VOICE`; the STT model is likewise `META_CASCADE_STT_MODEL`.

**Gender-matched TTS voice.** `agent._cascade_tts_voice_for_gender(persona_gender)`
picks the Inworld voice for the persona's gender and passes it as the session's
`tts_voice`: feminine personas get `config.meta_cascade_tts_voice_female` (env
`META_CASCADE_TTS_VOICE_FEMALE`, default **`Ashley`**), masculine personas get
`config.meta_cascade_tts_voice_male` (env `META_CASCADE_TTS_VOICE_MALE`, default
**`Alex`**). Non-binary / unknown gender — or a gender voice explicitly blanked —
falls back to the base `META_CASCADE_TTS_VOICE` (empty → the vendor default
voice). The voice ids live only in `config.py` (AGENTS.md: never in `agent.py`).
These defaults were previously empty, so every persona fell back to the single
vendor-default voice and gender was effectively ignored on the cascade; they now
default to `Ashley`/`Alex` so female personas sound female and male personas
sound male without any env override.

**Fallbacks — a flip can never take voice down.**
- *Build* — if the cascade can't be built (no `META_API_KEY`,
  `livekit-plugins-openai` missing), `_run_practice_session` logs it, reports to
  Sentry, and starts the session on the existing Gemini Live path instead.
- *Runtime* — if a built cascade dies mid-call (an STT/LLM/TTS error closes the
  `AgentSession` with `CloseReason.ERROR`), `_arm_practice_cascade_fallback`
  logs a `practice-voice fallback` line, reports to Sentry, and starts a fresh
  Gemini Live practice session on the **same room** so the caller is not left in
  dead air. Fires at most once.

Only the Practice Date voice session reads **this** flag (`LLM_PROVIDER_VOICE`);
the MAIN Ayma voice call reads a separate flag, `LLM_PROVIDER_VOICE_MAIN` (see
"MAIN Ayma voice on the Meta cascade" below), so the two flip independently.

**Greeting.** On both paths the simulated match "picks up the phone" and opens
in character (an initial `session.generate_reply` from
`prompts/practice_greeting.md`) instead of waiting for the user.

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

### MAIN Ayma voice on the Meta cascade (`LLM_PROVIDER_VOICE_MAIN`)

The **normal, non-practice** Ayma voice call (`agent._run_session`) can also run
on the Meta cascade, behind its **own** flag `LLM_PROVIDER_VOICE_MAIN`
(`config.llm_provider_voice_main`) — SEPARATE from the Practice `LLM_PROVIDER_VOICE`
flag so each voice flips and rolls back on its own. Default `gemini`: the main
call runs the **LOCKED Gemini Live `RealtimeModel` exactly as today**, zero
behaviour change until the one env var is flipped. It deliberately does **not**
inherit the global `LLM_PROVIDER` default — the main voice is the locked Gemini
Live model, so a blanket `LLM_PROVIDER=meta` can never sweep it; only
`LLM_PROVIDER_VOICE_MAIN=meta` selects the cascade.

When `=meta`, the main call reuses the same `agent.build_meta_cascade_session`
(STT/LLM/TTS/VAD table above) and **intentionally bypasses the locked Gemini Live
voice** for Muse Spark (the lock in `config.py` is unchanged — the flag only
selects which stack builds). The main-call behaviours are preserved on the
cascade (`agent._start_main_cascade_session`):

- Greeting/opener (welcome-room greeting, else `maybe_open_conversation` — Ayma
  opens if the caller stays silent), barge-in/interruptions (`allow_interruptions`),
  the per-call keepalive, the idle watchdog, "shut up"/mute control, the
  raw_turns memory flush on shutdown/close, Sentry, and the app-driving session
  tools all carry over unchanged (all are event-based, not Gemini-Live-specific).
- **Metering** uses `relay_cascade_usage` (the cascade emits `LLMMetrics`, not
  `RealtimeModelMetrics`) under `FEATURE_VOICE`, and — unlike the Practice path —
  passes the same §F3 **mid-call credit-cap stop** as Gemini Live
  (`on_credits_exhausted` → `end_call_out_of_credits`), so a cascade main call
  can no longer run unbounded past zero.
- **Fallbacks** mirror Practice, so a flip can never take the main voice down: a
  *build* failure (no `META_API_KEY`, missing plugin) falls through to Gemini
  Live at start; a *runtime* cascade error (`CloseReason.ERROR`) switches to a
  fresh Gemini Live main session on the **same room** via
  `_arm_main_cascade_fallback` (fires once). Both the cascade and its Gemini
  fallback share the one `SessionFlush`/window, so the memory write is never
  doubled (the cascade does not start the flush on an ERROR close — the fallback
  session flushes at its own close; the job's shutdown callback is the backstop).

**Caveat — mid-call voice hot-swap.** `set_voice_preference` mid-call voice/accent
switching is Gemini-Live-specific (`VoiceSwapper` reconnects a Gemini Live model),
so on the cascade the main call does **not** hot-swap: the tool saves the
preference for the **next** call instead of reconnecting (the active
`ayma_tts_voice`, else `META_CASCADE_TTS_VOICE`, governs the current call). Whether
Muse Spark honours the app-driving function tools over the OpenAI-compatible API is
unverified live and is the other open caveat; tools are wired either way and
degrade to no-ops if the model does not call them.

**Stack-aware voice vocabulary (fixed 2026-10-27).** The agent's *knowledge* of
its voices used to be hardcoded to the Gemini Live presets: on a fishaudio
cascade (brain = Muse Spark, TTS = `fishaudio/s2.1-pro`, voice = Hannah) asking
"what voices do you have" wrongly listed the Gemini presets (Aoede/Kore/Puck…)
and claimed "I'm on Puck". Now `agent._start_main_cascade_session` (and the
realtime path) computes `voice_catalog.runtime_voices(...)` for the stack it is
**actually** running and injects a stack-aware instruction block
(`prompt.voice_vocab_directive`, `prompts/voice_vocab.md`): the real current
voice (Hannah on that cascade) and the voices the active TTS provider offers.
`set_voice_preference` on the cascade binds through
`skills.set_voice_preference.bind_stack`, which resolves the request **within the
active provider's voice set** (`voice_catalog.resolve_voice`), saves it to
`ayma_tts_voice` for the next call, and whose tool description names those voices
— never the Gemini presets. On a fallback to Gemini Live (build/runtime) the
Gemini path recomputes the vocabulary, so it then correctly reflects Gemini. Voice
ids stay in `config.py`/`voice_catalog._TTS_FALLBACK_VOICES` (AGENTS.md: none in
`agent.py`). The text `/chat` `set_voice_preference` has no live session and keeps
its preset-default resolution.

**Free-text accent (`ayma_voice_accent`, founder 2026-10-27).** A dedicated
free-text Accent field on "Ayma's models" (separate from the language selector)
saves *how* Ayma sounds ("southern American accent", "California accent") to
`ayma_voice_accent`. At session boot the agent routes it only to an
**accent-capable** provider — `voice_catalog.provider_supports_accent`, the ONE
source of truth, driven by `CONFIG.voice_accent_capable_providers` (`gemini,openai`
by default: the instruction-driven native-audio realtime models). On those,
`agent._accent_block` appends `prompt.voice_accent_directive`
(`prompts/voice_accent.md`) to the session instructions so Gemini Live / OpenAI
Realtime speak the accent from the first word and never revert; it is folded into
the base prompt the Gemini hot-swapper reuses, so a mid-call voice swap keeps it.
The Meta cascade's fixed-voice TTS providers report `supports_accent:false`, so the
accent is **not** passed to them (ignored gracefully — no crash, no effect). When
a user asks to change accent on such a model, `set_voice_preference` (new `accent`
param) says this voice can't change its accent and to switch to an accent-capable
model in "Ayma's models", and saves nothing; on an accent-capable model it persists
the accent for the next session boot. `RuntimeVoices.supports_accent` carries the
flag for `bind_stack`; the text `/chat` path gates on the saved stack
(`voice_catalog.accent_supported`).

**Cascade cold-start (fixed in two parts, 2026-10-27 + 2026-10-28).** A fresh
Meta-cascade call used to speak a reply to the caller's last message from the
*previous* call the moment it connected, before the caller spoke (Gemini Live does
not). Two separate causes:

1. **session.start answered a trailing user turn (2026-10-27).** If the prior
   conversation's persisted history ended with an unanswered *user* turn, it was
   seeded into the model and answered on connect. `agent._cascade_seed_chat_ctx`
   drops any trailing run of user turns from the cascade's seeded `chat_ctx` at
   start (the whole seed is prior-session history; new turns arrive live via STT).
   Correct but incomplete — only covers the trailing-user case.

2. **The silent-caller opener continued the previous conversation (2026-10-28 —
   the bug that persisted, now fixed for real).** When the prior conversation
   ended with Ayma's reply (Part 1 strips nothing, the opener fires), the
   cold-start opener continued the previous topic the instant the call opened.
   **Real root cause:** the rolling summary + recent turns ride in the **system
   prompt** (`compose_system_prompt`), *not* `chat_ctx`, and the old
   `prompts/voice_opener.md` told the model to "pick the thread back up." So an
   earlier attempt that scoped the opener's `generate_reply` to an **empty**
   `chat_ctx` changed the wrong layer — the summary was still in the system
   prompt and the opener instruction still *asked* for a continuation, so Ayma
   continued.

   **Desired behaviour (founder, 2026-10-28 — supersedes "greet fresh"):** on a
   new call *with* prior context, Ayma **greets and offers a choice** — e.g.
   "Hey [name], want to pick up where we left off about [topic], or is there
   something else on your mind?" — and does **not** resume the old topic herself;
   she keeps the context, so "yeah, continue" works on the caller's next turn.
   With *no* prior context, a plain fresh warm opener.

   **Fix:** `maybe_open_conversation` derives `has_prior_conversation` + a short
   **one-line last-topic hint** from `seed.seed_turns` (`agent._opener_prior_context`
   — truncated, never the full transcript) and passes them into
   `load_voice_opener(has_prior, hint)`. `prompts/voice_opener.md` was rewritten
   into a **prior-context** block (greet + continue-or-switch choice, explicit
   "do NOT answer/resume/summarise the previous topic yourself") and a **fresh**
   block. The history-free `chat_ctx` the cascade passes to the opener's
   `generate_reply` stays only as a **secondary guard**; the greet+choice is now
   driven by the instruction, independent of which layer carries the summary.

This is a **general behaviour**, not cascade-only: driven by the opener
instruction + the has-prior/last-topic signal (both path-agnostic), Gemini Live
gets the same greet+choice. Only the opener's `opener_chat_ctx` secondary guard
stays cascade-scoped (Gemini Live / OpenAI Realtime leave it `NOT_GIVEN`). All
prior context is kept and the full window is still persisted, so continuing on
the caller's next turn works on every stack.

**Voice tool-use reliability (2026-10-28).** On the cascade, Muse Spark sometimes
*narrated* an app action as done without calling the tool ("rerunning that now"
with no tool fired; "open my appearance report" → opened Settings and said "opened
settings"). This is probabilistic tool-calling. Mitigation: `prompts/voice_tool_use.md`
(`prompt.load_voice_tool_use`) is appended to the **cascade** session instructions
in `_start_main_cascade_session` via `_compose_instructions`'s `tool_use` part. It
requires that every app action go through the matching tool, that the agent confirm
only from the tool's actual returned result, and that it NEVER claim an action is
done/in-progress unless the tool was invoked and returned — call first, then speak
from the result, and pick the tool matching the specific request. Gemini Live leaves
`tool_use` empty, so its instructions are unchanged. **Model-reliability mitigation,
not a guarantee:** Muse Spark tool-calling is probabilistic, so it cuts but may not
fully remove false "done" claims and mis-routes; if cascade tool reliability stays
poor, Gemini Live (reliable tool-calling) is the voice fallback.

**How to flip (MAIN voice to Meta):**

```
# on the ayma-agent Cloud Run service (or .env.local for local dev)
LLM_PROVIDER_VOICE_MAIN=meta
```

Roll back by removing the var (or `LLM_PROVIDER_VOICE_MAIN=gemini`) and restarting.
Applies to the next main voice call. Same billing gate as Practice — a live Meta
voice call bills the card until the credit posts.

### Per-user voice ENGINE switcher (§13.9)

`LLM_PROVIDER_VOICE_MAIN` is the deploy-time default. On top of it, each user can
switch their own voice **stack** from the "Ayma's models" settings screen via `GET /voice/engines`
+ `POST /voice/preference` (`voice_catalog.py`, ARCHITECTURE §13.9):

* **Mode** `realtime` (Gemini Live, or OpenAI Realtime behind `VOICE_OPENAI_REALTIME`
  + `OPENAI_API_KEY`) or `cascade` (brain + STT + TTS, mixable).
* The cascade generalizes `build_meta_cascade_session` into
  `agent.build_cascade_session(brain, stt, tts, voice, language)`: the **brain** is
  either Meta Muse Spark (`route=meta`, direct Meta API) or any LiveKit-Inference
  LLM (`route=inference`, no key); **STT** and **TTS** are any LiveKit Inference
  models. `build_meta_cascade_session` is kept as a thin wrapper for the Practice
  path.
* **Catalog source.** The cascade dropdowns are fetched **live** from the LiveKit
  Inference catalog — the gateway's OpenAI-compatible `GET /v1/models`, each model
  TYPE-tagged (STT/TTS/LLM/realtime/TD/INT) — when that catalog is populated. **It
  is not for this project:** `GET /v1/models` returns an empty `{}` (verified
  2026-10-27 with an InferenceGrants JWT — HTTP 200, body `{}`, every `?task=`
  filter identical), so the live path yields nothing and the config FALLBACK
  (`VOICE_CASCADE_*_MODELS`, `source:"fallback"`) is the **active** path today. The
  fallback lists enumerate the providers the project has LiveKit startup credits
  for — Inworld, Deepgram, Fish Audio (`fishaudio/s2.1-pro`), AssemblyAI, Rime
  (`rime/coda`), Gradium (`gradium/default`), Google — with canonical model ids
  from the LiveKit docs (`docs.livekit.io/agents/models`). Availability is honest
  (`voice_catalog._availability`): a provider in `VOICE_CREDITED_PROVIDERS` shows
  enabled; any other fallback entry (e.g. `cartesia`) shows **disabled** ("needs
  LiveKit credits") rather than a silently-failing pick. Per-TTS **voice** lists
  are not in `/v1/models`, so they come from the documented fallback
  `voice_catalog._TTS_FALLBACK_VOICES` — the LiveKit docs' per-provider sample
  voices (overridable by `VOICE_TTS_VOICES_<PROVIDER>`); a wrong id only triggers a
  mid-call fallback to Gemini Live.
* **Meta is never a realtime option** (no realtime audio API) — only a cascade
  brain. OpenAI Realtime needs its own `OPENAI_API_KEY` secret (founder-added);
  until then it is listed but inert and falls back to Gemini Live.

The LOCKED Gemini model ids are never edited — the selection only chooses
provider/model/voice/language. Every non-default path falls back to Gemini Live on
a build/runtime error, so a per-user switch can never take the main voice down.

## Embeddings stay on Gemini (deliberate hybrid)

Meta has **no embedding model**, and Ayma's matching uses a 3072-d Gemini
embedding index (`media_embed.py`, `IMAGE_EMBEDDING_MODEL=gemini-embedding-2`).
Matching therefore runs as a hybrid: **candidate retrieval / similarity stays on
Gemini embeddings**, while the **LLM scoring pass** (`matching_skill`) can run on
Muse Spark. Flipping `LLM_PROVIDER_MATCHING=meta` only moves the scoring call;
it does not touch embeddings and does not break matching. Web-search / URL
grounding in chat also stays Gemini-only (Meta has no Google grounding) — a chat
surface on Meta simply answers without live web grounding.

## Cost note: chat leaves LiveKit coverage

Text chat on Gemini ran through LiveKit Inference (`llm_route_chat=inference`,
`google/gemini-3.7-flash`), covered by the LiveKit plan. With
`LLM_PROVIDER_CHAT=meta`, `get_llm_provider("chat")` returns `MetaProvider`,
which never enters `gemini.py`, so `llm_route_chat` is not consulted and chat
bills the **Meta $150 credit** directly. Setting `LLM_PROVIDER_CHAT=gemini`
restores the Inference route. Matching and reports on Gemini were Inference/
Vertex JSON jobs; they now bill Meta too.

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
