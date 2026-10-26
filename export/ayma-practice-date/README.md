# ayma-practice-date

**The hackathon-built subset of Ayma.** This repository contains **only** the
components Ayma built during the **Meta Global AI Developer Hackathon**
(Oct–Nov 2026, Startup track) — nothing from Ayma's pre-existing private product.
Per the official rule confirmed by the organizers, *"a public repo containing
just the new components fits the rules; the demo must clearly identify only what
was newly built."* This repo is that public subset; Ayma's core product (auth,
matching, Firestore data layer, the Gemini client, the voice-agent worker, the
Flutter app shell) is private and **not included here**.

Two things were built, both of which "meaningfully use the Meta AI tooling":

1. **A Meta Model API provider** (Deliverable A) — Ayma's LLM work can run on
   **Meta Muse Spark** (and, for voice, **Meta Muse Voice Transcribe**) behind a
   per-surface flag, with Gemini kept as the default and the automatic fallback.
2. **Practice Date** (Deliverable B) — a dating-app feature where you *rehearse*
   talking to a match against an AI persona of that person, with a live coach
   and an end-of-session debrief. It runs on the Meta provider above (text today;
   a full Meta voice **cascade** — Muse Voice Transcribe → Muse Spark → partner
   TTS — is built behind a flag).

> Nobody in this repo is a real person. The demo seed profiles are fabricated,
> and deliberately carry fake "private" data (addresses, phones, etc.) purely so
> the privacy test can prove none of it ever leaks.

---

## What's here

```
backend/
  config.py                 Meta + per-surface-provider config (model ids live ONLY here)
  llm_provider.py           Provider abstraction: GeminiProvider | MetaProvider, get_llm_provider(surface)
  practice_core.py          Practice Date domain core (the privacy boundary, prompts, model calls, store)
  practice_date.py          Practice Date HTTP API (FastAPI router; re-exports practice_core)
  practice_llm.py           Practice Date's provider seam (-> get_llm_provider("practice"))
  practice_seed.py          Four fabricated demo profiles with planted never-load needles
  agent_meta_cascade.py     Excerpt: the Meta voice-cascade additions to Ayma's private voice worker
  prompts/                  practice_persona.md, practice_coach.md, practice_debrief.md (never inline)
  scripts/                  meta_vs_gemini_eval.py, seed_practice_profiles.py
  tests/                    self-contained tests (see "What runs standalone")
  _stubs/                   test-only stand-ins for Ayma's private core (see _stubs/README.md)
flutter/
  lib/features/practice_date/   The Practice Date UI (text, voice, debrief, models)
docs/
  META_PROVIDER.md          Design of the Meta provider + the voice cascade
  PRACTICE_DATE.md          Design of Practice Date + the privacy guarantee
EXTRACTION_INVENTORY.md     Every file, its origin, why it's "new", and every stubbed/external dependency
LICENSE / NOTICE            Apache-2.0
```

## How it uses Meta

- **Meta Muse Spark** (`muse-spark-1.3`) is reached through the **OpenAI-compatible
  Meta Model API** (`openai.AsyncOpenAI` pointed at `config.meta_api_base_url`,
  authed with the `META_API_KEY` secret). `MetaProvider` supports text,
  event-streamed chat (status events + a tool round-trip) and structured/JSON
  output (mapping Ayma's JSON schemas to the OpenAI `response_format`). Muse Spark
  is reasoning-only, so `reasoning_effort` is pinned to `minimal`.
- **Per-surface flags** `LLM_PROVIDER_<SURFACE>` (`chat`, `matching`, `reports`,
  `practice`, `voice`) each flip `gemini`↔`meta` independently; all default to
  `gemini`, so nothing changes until a surface is explicitly flipped. With
  `LLM_META_FALLBACK=true` (default) a Meta failure degrades that surface to
  Gemini automatically.
- **Meta Muse Voice Transcribe** (`muse-voice-transcribe-1.0`) is the STT leg of
  the Practice Date **voice cascade** (`agent_meta_cascade.build_meta_cascade_session`):
  STT (Muse Voice Transcribe) → LLM (Muse Spark) → TTS (Inworld via LiveKit
  Inference) → VAD (Silero), behind `LLM_PROVIDER_VOICE=meta`.
- **Open weights**: `config.meta_open_weights_model`
  (`meta-models/muse-spark-open-1026`) is exposed for a Baseten/self-hosted
  deployment (the "Best Build on Meta Open Weight Models" target).

All model ids live **only** in `config.py`; no model name is hardcoded in feature
code. `META_API_KEY` is read from the environment at the call site — never stored
in config, never committed.

## The privacy design (the headline)

Practice Date builds the simulated persona **only from the viewer-visible
profile**, and the never-load exclusion is enforced **at query level** — the
forbidden data is never *fetched* into the persona context, not merely omitted
from the prompt:

- The public-profile serializer reads wiki pages filtered to
  `visibility == "public"` and strips `{{private}}` / `{{ai_only}}` spans.
- `practice_core.build_persona_context` then **whitelists** only name, a computed
  age (never the birthdate), a coarse city (never coordinates), public wiki
  pages, and a photo count. It reads nothing else — no raw profile doc, no
  matches/likes, no contact fields, no other users.
- The persona prompt additionally instructs the simulated person to **deflect**
  extraction attempts in character.

Because the secret is never in the model's context, **the defence does not depend
on the model behaving** — it survives the flip from Gemini to Meta Muse Spark
unchanged. The extraction test proves this even against a deliberately
*maximally leaky* stand-in model (see below).

## What runs standalone (and what needs Ayma's private core)

This repo is a **subset**, so some files bind to Ayma's private core
(FastAPI app, auth, the Firestore `db` module, the Gemini client, the voice
worker, the Flutter app shell). Those are **documented as external** and are
**not** included. To let the genuinely-new logic be verified in isolation,
`tests/conftest.py` puts a small set of **clearly-labelled stand-ins**
(`_stubs/`, see `_stubs/README.md`) on the path — used only by the tests, never
by production code.

**Self-contained test run (no private core, no network, no Meta calls):**

```bash
cd backend
python3 -m pip install -r requirements-test.txt
python3 -m pytest -q
# 38 passed, 1 skipped
```

| Test file | Runs standalone? | Covers |
|---|---|---|
| `tests/test_llm_provider.py` (17) | ✅ yes | provider selection + gemini default, OpenAI `response_format` schema mapping, the Meta chat tool round-trip, Meta→Gemini fallback, missing-key error |
| `tests/test_practice_date.py` (12) | ✅ yes | persona context whitelist, query-level privacy exclusion, prompt composition, full session flow, the name-only voice coach context |
| `tests/test_practice_extraction.py` (4) | ✅ yes | **the headline privacy test** — a scripted extraction battery (incl. jailbreaks) against every demo persona, text + voice-room-seed, even against a maximally-leaky model |
| `tests/test_config.py` (5) | ✅ yes | the Meta/provider config defaults (every surface defaults to `gemini`; cascade TTS/VAD vendors are config, not hardcoded) |
| `tests/test_agent_cascade_reference.py` (4) | ⏭ needs voice deps | the Meta voice-cascade builder + usage meter — **skipped** unless `livekit-agents` + `livekit-plugins-openai` are installed |

**Not runnable standalone (bind to Ayma's private core — documented as external):**
`practice_date.py` (FastAPI app / auth / age-gate / `db`), `agent_meta_cascade.py`
(the private voice worker + `livekit-agents`), `scripts/seed_practice_profiles.py`
(needs the `db` Firestore client), the full `scripts/meta_vs_gemini_eval.py` live
run (needs the Gemini client and/or a `META_API_KEY`; its `--dry-run` prints the
requests each side would send without a network call), and the `flutter/` UI
(binds to Ayma's app shell: `api_client`, `theme`, shared widgets/services).

> The tests make **no live Meta calls** — `META_API_KEY` is cleared for the test
> session and the Meta client is always a fake. (Live Meta calls bill a card.)

See **`EXTRACTION_INVENTORY.md`** for a file-by-file origin + rationale, and for
every private-core dependency that was stubbed or documented-as-external.
