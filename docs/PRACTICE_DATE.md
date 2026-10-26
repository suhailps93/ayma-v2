# Practice Date (hackathon deliverable B)

**What it is.** On a match's or Explore profile, a **Practice** button opens a
clearly-labelled *simulator* conversation where Ayma plays a persona built from
THAT person, so the user can rehearse talking to them before messaging for real.
Ayma coaches live (a short nudge after each of the user's messages) and gives a
**debrief** when the session ends: what worked, what to say next, and what to
avoid. It is a feature of the dating product — "practice with a simulated version
of this match" — not a generic coach app.

All of it is NEW code (Oct 2026), isolated in clearly-named files so it can be
lifted into the public hackathon repo:

| Layer | Files |
|---|---|
| Persona + session + API | `functions/bootstrap/practice_date.py` |
| Provider seam | `functions/bootstrap/practice_llm.py` (uses the shared `llm_provider.get_llm_provider("practice")`) |
| Prompts (never inline) | `functions/bootstrap/prompts/practice_persona.md`, `practice_coach.md`, `practice_debrief.md` |
| Demo seed | `functions/bootstrap/practice_seed.py`, `scripts/seed_practice_profiles.py` |
| Tests | `functions/bootstrap/tests/test_practice_date.py`, `test_practice_extraction.py` |
| Flutter | `ayma_flutter/lib/features/practice_date/` (screen, debrief, models), a Practice button in `screens/public_profile_screen.dart`, routes in `routing/app_router.dart`, client methods in `services/api_client.dart` |
| Flutter tests | `ayma_flutter/test/practice_date_test.dart` |

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
Result: **all green** (13 tests). The full backend suite stays green (1867
passed).

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

Text practice runs end-to-end tonight on the current model. Voice practice
reuses the existing LiveKit pipeline seeded with `compose_persona_prompt(ctx)`
(see the seam note below).

## Provider seam — what flips to Meta later

Every Practice Date model call goes through `practice_llm`, which calls the
shared per-surface provider `llm_provider.get_llm_provider("practice")`
(Deliverable A). Today that resolves to **Gemini** (so it runs tonight). Set
`LLM_PROVIDER_PRACTICE=meta` to route Practice Date to **Meta Muse Spark** (with
Gemini fallback via `LLM_META_FALLBACK`), with no change to Practice Date code.
Model ids live only in `config.py`; no model name appears in the feature code.

**Voice:** the text path is wired now. Voice practice reuses the existing
LiveKit voice pipeline — seed a practice room's system prompt with
`practice_date.compose_persona_prompt(ctx)` and run the same session as a normal
voice call. Wiring that into `agent.py`/`bootstrap` is the remaining voice step
(TODO), kept out of tonight's runnable text path deliberately.

## API

- `POST /practice/start {other_uid}` → `{session_id, persona{name,age,location,photo_count}, banner, simulation:true}`
- `POST /practice/chat {session_id, message}` → `{reply, coach_hint, simulation:true}` (402 when out of credits)
- `POST /practice/debrief {session_id}` → `{what_worked[], suggested_next_lines[], avoid[], simulation:true}`

All three are 18+-gated (`require_not_underage_uid`) and authed
(`require_caller`), metered under `token_ledger.FEATURE_PRACTICE`. Sessions live
at `users/{uid}/practice_sessions/{session_id}` (Firestore only).
