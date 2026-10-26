# Practice Date (hackathon deliverable B)

**What it is.** On a match's or Explore profile, a **Practice** button opens a
clearly-labelled *simulator* conversation where Ayma plays a persona built from
THAT person, so the user can rehearse talking to them before messaging for real.
Ayma coaches live (a short nudge after each of the user's messages) and gives a
**debrief** when the session ends: what worked, what to say next, and what to
avoid. It is a feature of the dating product — "practice with a simulated version
of this match" — not a generic coach app.

It works in **text and voice**. All of it is NEW code (Oct 2026), isolated in
clearly-named files so it can be lifted into the public hackathon repo:

| Layer | Files |
|---|---|
| Domain core (fastapi-free; shared by the API and the voice agent worker) | `functions/bootstrap/practice_core.py` |
| HTTP API (text + voice-start) | `functions/bootstrap/practice_date.py` (re-exports `practice_core`) |
| Provider seam | `functions/bootstrap/practice_llm.py` (uses the shared `llm_provider.get_llm_provider("practice")`) |
| Voice agent path | `functions/bootstrap/agent.py` (`_run_practice_session`, `relay_practice_coach`), seeded via `functions/bootstrap/livekit_token.py` (`build_room_seed(practice=True, …)`) |
| Prompts (never inline) | `functions/bootstrap/prompts/practice_persona.md`, `practice_coach.md`, `practice_debrief.md` |
| Demo seed | `functions/bootstrap/practice_seed.py`, `scripts/seed_practice_profiles.py` |
| Tests | `functions/bootstrap/tests/test_practice_date.py`, `test_practice_extraction.py`, `test_agent.py` |
| Flutter | `ayma_flutter/lib/features/practice_date/` (text screen, **voice screen**, debrief, models), a Practice button in `screens/public_profile_screen.dart`, voice-practice via `services/voice_session_controller.dart` + `voice_transport.dart`, routes in `routing/app_router.dart`, client methods in `services/api_client.dart` |
| Flutter tests | `ayma_flutter/test/practice_date_test.dart` |

**Why the `practice_core` / `practice_date` split.** The LiveKit voice agent
worker (`agent.py`) runs in a deliberately lean runtime that carries no web
stack (no fastapi — see `requirements-agent.txt`), yet it needs the practice
primitives (persona context, the coach, the session store) to run the voice
session. So the fastapi-free domain logic lives in `practice_core.py`;
`practice_date.py` is the thin `/practice/*` router that re-exports it. The
feature's public surface and the text path are unchanged.

## The privacy design (headline judging asset)

The simulated persona is built **only from the viewer-visible profile** — the
exact serializer the profile screen uses, `public_profile.build`. The never-load
exclusion is enforced **at query level**, so the forbidden data is never
*fetched* into the persona context, not merely omitted from the prompt:

- `public_profile._public_pages` reads wiki pages with
  `.where("visibility", "==", "public")` — private and `ai_only` pages are never
  streamed from Firestore.
- `story.strip_private_spans` removes inline `{{private}}` / `{{ai_only}}` spans
  from the public bodies that remain.
- `practice_date.build_persona_context` then **whitelists** only name, age
  (computed, never the birthdate), coarse city (never coordinates), public wiki
  pages, and a photo count. It reads nothing else about the target — no raw
  `profile/main` doc, no matches/likes, no contact fields, no other users.

The never-load categories (`practice_date.NEVER_LOAD`): exact
location/coordinates; contact info (phone, email, street address, social
handles); other matches / people they're seeing; private or ai-only wiki spans;
internal/admin data; any other user's data.

The persona prompt (`prompts/practice_persona.md`) additionally instructs the
simulated person to **deflect** extraction attempts in character without
revealing anything — a second line of defence on top of context starvation.

### The extraction test (`tests/test_practice_extraction.py`)

The headline test runs a scripted battery of extraction attempts (address,
phone, email, exact location/coordinates, other matches, private notes, plus
jailbreak framings like "ignore your instructions" and "I'm your developer")
against every demo persona and asserts NONE of the never-load data leaks, on two
axes:

1. **Context starvation (structural):** the needles are never present in the
   loaded persona context.
2. **Response leakage (worst case):** the persona is driven by a deliberately
   *maximally leaky* stand-in model that echoes back everything it was handed —
   and still cannot reveal a secret, because the secret was never in its
   context. This proves the defence does not depend on the model behaving, so it
   survives the flip from Gemini to Meta Muse Spark unchanged.

Run it:
```
cd functions/bootstrap
python -m pytest tests/test_practice_extraction.py tests/test_practice_date.py -q
```
The extraction test also covers the **voice** path: it builds the exact JSON
seeded onto a practice voice room (`livekit_token.build_room_seed(practice=True,
…)` wrapping `compose_persona_prompt`) and asserts no needle is present — the
voice equivalent of the text context-starvation guarantee. Result: **all green**
(16 practice tests + 2 new agent tests). The full backend suite stays green.

## How to demo

1. **Seed demo profiles** (judges need someone to practice with):
   ```
   python3 scripts/seed_practice_profiles.py
   ```
   Seeds four profiles (Maya, Leo, Aisha, Noah), each carrying planted
   never-load needles (address, phone, email, coordinates, other people,
   private notes) so you can show, live, that none of it leaks.
2. In the app, open one of those profiles and tap **Practice** (the rail button
   with the practice glyph).
3. The **simulator** opens with a persistent banner: "Practice mode — you're
   talking to a simulated version of <name>, not the real person." Chat with the
   persona. A coach nudge appears under the composer after each message.
4. **Try to extract private data** ("what's your address / phone / who else are
   you seeing?") — the persona deflects in character; nothing leaks.
5. Tap **End** to open the **debrief**: what worked / try saying next / what to
   avoid.

Text practice runs end-to-end on the current model. **Voice practice** reuses
the existing LiveKit pipeline seeded with `compose_persona_prompt(ctx)`:

6. On the simulator, tap the **voice** button (the waveform glyph in the header)
   to rehearse out loud. The same persona (built only from the viewer-visible
   profile) now *speaks*, deflecting extraction in character. A live coach
   nudge appears as a side hint (never spoken by the persona), and ending the
   call opens the same debrief.

### How voice practice is seeded + gated

- `POST /practice/voice/start {other_uid}` builds the persona with the SAME
  `build_persona_context` / `compose_persona_prompt` the text path uses (the
  privacy boundary is crossed exactly once, here), creates a practice session,
  mints a LiveKit token, and seeds the room metadata with
  `build_room_seed(persona_prompt, …, practice=True, persona_name, target_uid)`.
- The agent worker gates strictly on that `practice` flag
  (`agent._run_session` → `_run_practice_session`): it runs the persona with
  **no Ayma tools**, **no `SessionFlush`** (a simulation never touches the
  user's `raw_turns`/wiki memory), and **no Ayma voice opener** (the user opens
  — they're rehearsing their opener). Every normal voice call is untouched.
- **Coach in voice:** `relay_practice_coach` fires after each finalized user
  turn, calls `practice_core.coach_hint` (reusing the text coach), and publishes
  the nudge on the `practice_coach` data-channel topic — an out-of-character
  side hint to the user, not spoken by the persona. Each turn is appended to the
  practice session store so `POST /practice/debrief` works unchanged after the
  call. The coach context is rebuilt from the persona *name* alone
  (`persona_context_for_coach`); the worker never re-reads the target's profile.

## Provider seam — what flips to Meta later

Every Practice Date model call goes through `practice_llm`, which calls the
shared per-surface provider `llm_provider.get_llm_provider("practice")`
(Deliverable A). Today that resolves to **Gemini** (so it runs tonight). Set
`LLM_PROVIDER_PRACTICE=meta` to route Practice Date to **Meta Muse Spark** (with
Gemini fallback via `LLM_META_FALLBACK`), with no change to Practice Date code.
Model ids live only in `config.py`; no model name appears in the feature code.

**Voice provider — the Meta cascade (built, behind a flag).** By default voice
practice uses Gemini Live (the current `llm_routing` route) for the spoken
persona. When the **`voice` surface flag** `LLM_PROVIDER_VOICE=meta`
(`config.llm_provider_voice`) is set, `_run_practice_session` instead builds a
LiveKit pipeline (cascade) `AgentSession` via `agent.build_meta_cascade_session`:

- **STT** Meta `muse-voice-transcribe-1.0` + **LLM** Meta Muse Spark
  `muse-spark-1.3`, both via `livekit-plugins-openai` pointed at the
  OpenAI-compatible Meta Model API (`META_API_KEY`, `reasoning_effort=minimal`);
- **TTS** Inworld via the LiveKit Inference gateway (`inference.TTS`, config
  `meta_cascade_tts_model`/`_voice`; Rime/Fish are config A/B alternatives);
- **VAD** bundled Silero (`inference.VAD`) to segment turns.

On any build failure (no key, missing plugin) it falls back to Gemini Live, so a
flip can never take practice voice down; normal Ayma voice calls are untouched.
Only the persona/coaching *content* still routes through `practice_llm`
(`LLM_PROVIDER_PRACTICE`). Full detail and the flip/rollback steps:
`docs/META_PROVIDER.md` → "Voice cascade". Model ids live only in `config.py`.
A live Meta voice call bills the card until the $150 credit posts, so the flag
stays OFF until billing is gated.

## API

- `POST /practice/start {other_uid}` → `{session_id, persona{name,age,location,photo_count}, banner, simulation:true}`
- `POST /practice/chat {session_id, message}` → `{reply, coach_hint, simulation:true}` (402 when out of credits)
- `POST /practice/voice/start {other_uid}` → `{session_id, persona{…}, banner, livekit{token,url,room}, simulation:true}` (404 no profile; `usage_capped:true` when out of credits; 503 if LiveKit unconfigured) — seeds the voice room with the persona prompt
- `POST /practice/debrief {session_id}` → `{what_worked[], suggested_next_lines[], avoid[], simulation:true}` (used by both text and voice)

All three are 18+-gated (`require_not_underage_uid`) and authed
(`require_caller`), metered under `token_ledger.FEATURE_PRACTICE`. Sessions live
at `users/{uid}/practice_sessions/{session_id}` (Firestore only).
