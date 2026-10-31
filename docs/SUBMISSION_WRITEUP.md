# Ayma — Meta Global AI Developer Hackathon write-up (Startup Track)

**Title:** Ayma — practice the date before the date (on Meta's Muse Spark)

**One-liner:** A voice-first AI dating companion, ported to Meta's models, with
Practice Date: rehearse your first conversation with an AI simulation of your
match — built only from their public profile — and get coached on what to say
and what to avoid.

This write-up grounds every claim in what is actually built on the
`meta-hackathon` branch. Where a number is not independently verifiable from the
code or the recorded status, it is marked `TODO(verify)` rather than invented.

---

## 1. What we submit

Two deliverables, both live on `meta-hackathon`:

- **Deliverable A — The Port.** Ayma's LLM work runs behind a provider
  abstraction with Meta's **Muse Spark** as a first-class vendor and Gemini kept
  as the default and the fallback. Each surface flips independently.
- **Deliverable B — Practice Date.** A new feature: on any profile, a
  **Practice** button opens a clearly labelled *simulator* where Ayma plays a
  persona of that match — built **only from their viewer-visible profile** — so
  the user can rehearse the first conversation (text or voice), with Ayma
  coaching live and giving an end-of-session debrief. Practice Date's text
  surface already runs on Muse Spark in the deployed build.
- **New surface — AI-to-AI date simulation (Agent Dates).** Each user's Ayma
  agent — built from what that user shares with Ayma — can go on a simulated
  first date with another user's agent and return a **compatibility score**
  plus a short **how-it-went summary**. It is the optimistic version of
  *Black Mirror*'s "Hang the DJ": the simulation finds your person before you
  ever meet. Built during the hackathon window on the same provider
  abstraction (Muse Spark), under the same privacy contract as Practice Date:
  an agent's context holds only its own user's shared data, and the summary
  reports only what happened inside the simulation.

---

## 2. Meta Model API / Muse Spark usage

All Meta access goes through the **OpenAI-compatible Meta Model API** at
`https://api.meta.ai/v1` (base confirmed by an authenticated `GET /v1/models`,
2026-10-26), authed with the `META_API_KEY` secret. Model ids live **only** in
`functions/bootstrap/config.py` (repo rule: no model name anywhere else):

| Role | Model id (`config.py`) | Where |
|---|---|---|
| Chat / reasoning | `muse-spark-1.3` (`META_CHAT_MODEL`) | text generation, event-streamed chat, structured JSON, Practice Date voice cascade LLM leg |
| Voice STT (id only) | `muse-voice-transcribe-1.0` (`META_TRANSCRIBE_MODEL`) | listed in Meta's catalog but no usable REST STT endpoint — cascade STT runs on LiveKit Inference (`META_CASCADE_STT_MODEL`, `deepgram/nova-3`) instead |
| Open-weights target | `meta-models/muse-spark-open-1026` (`META_OPEN_WEIGHTS_MODEL`) | configured, **not wired to a surface yet** (see §6) |

**Reasoning effort.** Every Muse Spark variant is a reasoning model and the API
rejects `reasoning_effort: none` (floor is `minimal`). Left at the API default,
a trivial reply burns ~450 reasoning tokens and 2s+; pinned to
`reasoning_effort=minimal` (`META_REASONING_EFFORT`, sent via `extra_body` so it
works across OpenAI SDK versions) it drops to ~20 reasoning tokens and ~0.6s —
the latency Ayma's conversational surfaces need. (Token/latency figures are the
recorded eval observations in `docs/META_PROVIDER.md`; exact per-call numbers
are `TODO(verify)` against a fresh run.)

`MetaProvider` (`functions/bootstrap/llm_provider.py`) supports **generate
text**, **event-streamed chat** (status events + tool round-trip), and
**structured / JSON output** (Ayma's JSON schemas mapped to the OpenAI
`response_format`).

## 3. Provider abstraction, per-surface flags, Gemini fallback

`functions/bootstrap/llm_provider.py` defines an `LLMProvider` interface with two
implementations — `GeminiProvider` (the production default, a thin wrapper over
the existing `gemini.py` calls) and `MetaProvider` (Muse Spark via the Meta Model
API). `get_llm_provider(surface)` returns the provider a surface is configured
for.

- **Surfaces:** `chat`, `matching`, `reports`, `practice`, `voice`.
- **Per-surface flag `LLM_PROVIDER_<SURFACE>`** (`gemini` | `meta`), with
  `LLM_PROVIDER` as the default for any surface whose own var is unset. **All
  default to `gemini`.** A surface flips by setting one env var on Cloud Run and
  redeploying; it rolls back by removing the var.
- **Fallback:** with `LLM_META_FALLBACK=true` (default), any Meta failure — no
  key, outage, transport error — degrades that surface to Gemini automatically,
  so a flip can never take a surface down.

**Wired surfaces:** chat (`main.py`), matching (`matching_skill.py`), reports
(`body_report.py`, `face_report.py`); Practice Date consumes
`get_llm_provider("practice")` through `practice_llm.py`.

**Currently flipped (deploy script):** `practice`, `chat`, `matching` and
`reports` → Meta (`LLM_PROVIDER_*=meta`, `LLM_META_FALLBACK=true`). `voice`
remains on Gemini.

**Deliberate hybrids (documented, not gaps):**
- Meta has no embedding model, so matching's candidate retrieval stays on the
  Gemini 3072-d embedding index; only the LLM scoring pass can run on Muse Spark.
- Muse Spark occasionally emits a JSON key with a trailing space
  (`"strengths "`); `MetaProvider.generate_json` strips key whitespace, and a
  live check (5 match + 20 report calls) returned schema-valid JSON every time.
- Chat web-search / URL grounding stays Gemini-only (Meta has no Google
  grounding); a chat surface on Meta simply answers without live grounding.

## 4. Live eval result

`functions/bootstrap/scripts/meta_vs_gemini_eval.py --live` (2026-10-26) ran the
fixed matching pairs + report prompts through both providers:

- **Both providers passed all four fixtures.**
- **Muse Spark was faster on every case** — e.g. match **1.5s vs Gemini 7.1s**;
  report **1.8s vs 4.2s**.
- The one quirk (trailing-space JSON key on the reports schema) is now handled
  by key normalisation in `MetaProvider`.

(These are the figures recorded in `docs/META_PROVIDER.md` from that run. A fresh
`--live` run to reconfirm exact seconds is `TODO(verify)`.)

## 5. Privacy design — visible-profile-only (headline judging asset)

The founder rule: **the simulation must never share the other person's personal
details.** Enforced in two layers.

**Layer 1 — never loaded (enforced at query level, not in prompts).** The persona
context is built **only** from `public_profile.build` — the exact serializer the
Explore profile screen renders:

- `public_profile._public_pages` reads wiki pages with
  `.where("visibility", "==", "public")`, so private and `ai_only` pages are
  **never streamed** from Firestore.
- `story.strip_private_spans` removes inline `{{private}}` / `{{ai_only}}` spans
  from the public bodies that remain.
- `practice_core.build_persona_context` then **whitelists** only: first name, age
  (computed, never the birthdate), coarse city (never coordinates), the public
  wiki pages, and a photo count. It reads nothing else about the target — no raw
  `profile/main` doc, no matches/likes, no contact fields, no other users.

The `NEVER_LOAD` categories (`practice_core.NEVER_LOAD`): exact
location/coordinates; contact info (phone, email, street address, social
handles); other matches / people they're seeing; private or ai-only wiki spans;
internal/admin data; any other user's data.

**Layer 2 — prompt boundaries.** The persona prompt
(`prompts/practice_persona.md`) instructs the simulated person to **deflect**
extraction attempts in character without revealing anything — a second line of
defence on top of context starvation.

**The extraction test (`tests/test_practice_extraction.py`).** A scripted battery
of extraction attempts (address, phone, email, exact location/coordinates, other
matches, private notes, plus jailbreak framings like "ignore your instructions"
and "I'm your developer") runs against every demo persona on two independent
axes:

1. **Context starvation (structural):** the never-load needles are never present
   in the loaded persona context.
2. **Response leakage (worst case):** the persona is driven by a deliberately
   *maximally leaky* stand-in model that echoes back everything it was handed —
   and still cannot reveal a secret, because the secret was never in its context.
   This proves the defence does not depend on the model behaving, so it survives
   the flip from Gemini to Meta Muse Spark unchanged.

The test also covers the **voice** path: it builds the exact JSON seeded onto a
practice voice room (`livekit_token.build_room_seed(practice=True, …)`) and
asserts no needle is present. Result: **all green** (16 practice tests +
the new agent tests; full backend suite green aside from 2 known order-dependent
`test_backfill_ops` cases that pass in isolation).

**Operational privacy.** Practice content is stored only under the practicing
user's own data (`users/{uid}/practice_sessions`); the real person is never
notified and their record is never written to. The simulator cannot send to, or
appear in, the real conversation. 18+-gated and metered like the rest of Ayma.

## 6. Open-weights path — status

The plan's low-cost open-weights path (a Meta open-weights model via Baseten /
Modal for cheap batch/summary work) was the first cut line and is **not shipped**.
What exists: the target model id `meta-models/muse-spark-open-1026` is configured
in `config.py` (`META_OPEN_WEIGHTS_MODEL`) and documented as "not wired into a
surface yet." No call site routes to it today. Stated plainly so judges aren't
misled.

## 7. Voice cascade — Practice Date "runs on Meta" end-to-end (built, flag-gated)

The Practice Date **voice** session can run entirely on Meta as a LiveKit
pipeline (cascade) agent instead of Gemini Live's speech-to-speech model. Gated
by the `voice` surface flag `LLM_PROVIDER_VOICE` (default `gemini`, so the
current Gemini Live path is unchanged). `agent.build_meta_cascade_session`:

| Leg | Vendor / model | Transport |
|---|---|---|
| LLM | Meta Muse Spark `muse-spark-1.3`, `reasoning_effort=minimal` | `livekit-plugins-openai` → Meta Model API |
| STT | Deepgram `nova-3` (configurable) | LiveKit **Inference** gateway (Meta serves no usable REST STT) |
| TTS | Inworld (configurable; Rime/Fish A/B) | LiveKit **Inference** gateway (LiveKit-credit covered) |
| VAD | Silero | LiveKit **Inference** (bundled, local) |

On any build failure (no key, missing plugin) it falls back to Gemini Live, so a
flip can never take practice voice down; normal Ayma voice calls are untouched.
Cascade LLM tokens are metered under `FEATURE_VOICE`. **Not flipped, not
deployed** — a live Meta voice call bills the card until the $150 credit posts,
so flipping is gated on billing.

## 8. Startup-track framing — a real pre-launch product

Ayma is not a hackathon toy; it is a pre-launch product the application
disclosed upfront, now running on Meta models:

- **Android:** live (internal/beta track; the hackathon build deployed to the
  founder's device and beta).
- **iOS:** TestFlight.
- **Pilot:** SJSU campus pilot (per the approved application and `HACKATHON_PLAN`
  §5). Pilot scale / tester count: `TODO(verify)`.

The port and Practice Date are both **new work inside the hackathon window**, on
an existing product, behind flags that keep production on Gemini until a surface
is explicitly flipped.

**Where this goes.** Practice Date teaches you to show up well; Agent Dates —
the AI-to-AI simulation in §1 — decides who is worth showing up for. Together
they are the first step toward the future *Black Mirror*'s "Hang the DJ"
imagined, in its optimistic form: a digital self that dates on your behalf and
finds your person, so real first dates stop being cold opens. That is the
consumer story Ayma launches with on December 1, 2026.

## 9. Credit posture (no dollar figures)

Until the $150 Meta Model API credit posts to billing, every Meta call bills the
card, so flips are deliberate and monitored (text practice flipped and watched;
voice cascade held OFF). Users and judges see **credits**, never dollars. Meta's
own per-model dollar pricing is not yet in the token ledger, so `cost_usd` is 0
for Meta cascade turns while the token cap still applies — a known Deliverable-A
gap, not a hidden cost.

---

### Source of truth

`docs/META_PROVIDER.md` (the port), `docs/PRACTICE_DATE.md` (the feature +
privacy), `docs/HACKATHON_STATUS.md` (deploy log), `docs/HACKATHON_PLAN.md` (the
plan and §5 submission package). Judge "how to try it": `docs/SUBMISSION_ONE_PAGER.md`.
