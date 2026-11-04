# Ayma

**Matchmaking in the age of AI. Your AI will find you your soulmate — or your soulmate for the night.**

Ayma is a voice-first dating app. No swiping, no checkbox filters. You talk to Ayma in natural language and tell her who you are and who you are looking for.

Every user has a personal avatar: an AI agent built from everything its person shares with Ayma. It carries their whole context and talks like them. Your story builds up as you share, and the more context Ayma and your avatar have, the better they represent you.

## Two avatar modes

- **Agent Dates.** Your avatar takes a simulated first date with a match's avatar and returns a compatibility score and a summary. It informs you, never decides for you. A first step towards Hang the DJ from Black Mirror.
- **Practice Date.** Message or call a match's avatar and have the first conversation before you face the real person. Ayma coaches you live and debriefs you after. It is completely private: the other person never sees it, only you do.

When you talk to real people yourself, Ayma stays with you, suggesting icebreakers and guidance while you text. She also writes reports: a match report (how you match with someone, and the chances of success), an appearance report (a mirror: your photos and how you present yourself, and what to improve), and a web search report (what is public about the person you are considering).

Ayma runs the whole app by voice. Ask her to open any page, start a date, or change a setting, and she does it. You can switch her brain in the Models screen, and find people just by describing who you are looking for.

## How Meta is used

- **Muse Spark via the Meta Model API.** All model access goes through one provider layer (`functions/bootstrap/llm_provider.py`) with a per-surface flag (`LLM_PROVIDER`, `LLM_PROVIDER_<SURFACE>`). Each surface (chat, matching, reports, practice, voice, coaching, translation) can run on Gemini or on Muse Spark. Gemini is the production default. Muse Spark is selectable per surface, and as the user's chosen brain. When a surface runs on Meta, Muse Spark talks as your avatar, runs the avatar-to-avatar simulations, writes match reports and research, and powers practice coaching and debriefs.
- **Voice.** You can talk to Ayma two ways: a Realtime model, or a Cascade (LiveKit Inference STT, then the chosen LLM, then LiveKit Inference TTS). The voice agent runs on LiveKit Cloud. In the cascade, the LLM leg can be Muse Spark.
- **Open weights, self-hosted.** The open-weights voice tier is Llama-3.1-8B-Instruct, served with vLLM on Modal from `scripts/modal_open_weights.py` and exposed under the served-model name `meta-models/muse-spark-open-1026`. It is a selectable brain in the app, behind the same provider layer.

Ayma has already had hundreds of real conversations, simulations, and report generations, and Meta's models handled their share of that work.

## Voice actions

Voice commands are interpreted by a dedicated skill, not pattern matching. One fast model pass over the finalized transcript plus the session context, guided by `functions/bootstrap/prompts/voice_actions.md`, returns a structured intent: navigate, open a profile, launch a practice date or a simulation, change a model or a setting, end the call, ask a clarifying question, or do nothing. Deterministic tools (`functions/bootstrap/skills/app_control*.py`) execute the intent, and the app confirms execution before Ayma says it happened.

## Privacy by design

An avatar only knows what its person made visible. The persona behind a simulation or a practice date is built only from the viewer-visible profile, using the same serializer the profile screen uses. Stored-only details (exact location, phone, workplace, private notes, other matches) are excluded at the data layer: they are never loaded into the model's context at all, not merely filtered at the prompt. Demo profiles carry planted private data, and an adversarial extraction test battery (`functions/bootstrap/tests/test_practice_extraction.py`) tries to pull it out. It does not leak. Practice conversations are private to the person having them.

## Where things live

| Piece | Path |
|---|---|
| Provider layer (Gemini / Meta / open weights) | `functions/bootstrap/llm_provider.py` |
| Meta provider notes | `docs/META_PROVIDER.md` |
| Practice Date (core, API, prompts) | `functions/bootstrap/practice_core.py`, `functions/bootstrap/practice_date.py`, `docs/PRACTICE_DATE.md` |
| Voice agent worker | `functions/bootstrap/agent.py` |
| Voice-actions guidance | `functions/bootstrap/prompts/voice_actions.md` |
| App-control tools | `functions/bootstrap/skills/app_control*.py` |
| Brain catalog (Gemini / Muse Spark / open weights) | `functions/bootstrap/voice_catalog.py` |
| Open-weights serving (vLLM on Modal) | `scripts/modal_open_weights.py` |
| Flutter app | `ayma_flutter/` |
| Judge one-pager | `docs/SUBMISSION_ONE_PAGER.md` |

Ayma is built by Justabot LLC.
