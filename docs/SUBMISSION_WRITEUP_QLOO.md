# Ayma — Qloo Agentic Hackathon write-up

**Title:** Ayma — your AI avatar goes on the date, and Qloo tells you where you'd click

**One-liner:** Ayma builds an AI avatar of you from what you share, sends it on
simulated first dates with other people's avatars, and uses the **Qloo Taste
API** to turn both sides' music / film / food into a shared-taste score and real
taste-based date ideas — a place to meet, a film to see, an artist to put on.

Every number below is grounded in the deployed service or the code on the
`meta-hackathon` branch. Anything not independently verifiable is marked
`TODO(verify)` rather than invented.

---

## 1. What it is

Ayma is a voice-first AI dating companion (live in beta). For this hackathon we
added a **Qloo-powered taste layer**. For any pair of people it:

- resolves each person's stated **music / film / food** favourites to **Qloo
  taste-graph entities**,
- scores how much their tastes overlap (**0–100**, per domain and overall),
- names the **tastes they share**, and
- generates **taste-based date ideas** — a place near them, a film, and an
  artist that Qloo ranks highly for **both** of them at once.

It shows up in three places: the public **judge demo page** (no login), the
**"Taste match · powered by Qloo"** card in the match report between two users,
and the result of an Ayma-run **AI date simulation**. The taste questions
(music/film/food) are asked inside Ayma's normal questionnaire, so a real user's
public Taste page fills itself with no separate form.

## 2. Why it's agentic

Ayma is an agent that acts on your behalf, not a form you fill in. It builds a
persistent **AI avatar** of each user from what they share, and those avatars go
on **AI-to-AI simulated first dates** — the "Hang the DJ" idea: your agent takes
the awkward first date for you and reports back who you'd actually click with.

The Qloo taste match is a **tool the agent calls** inside that loop. The agent
decides *when* taste is relevant, hands Qloo only the taste names each side
published, and uses Qloo's taste reasoning to ground the simulated date in
reality: it doesn't just say "you're compatible," it says *you both land on
Khruangbin and Spirited Away, so meet at a listening bar and see Lady Bird.* The
date ideas come straight out of Qloo's cross-domain insights, not a template.
Qloo supplies the taste intelligence; the agent supplies the timing, the
conversation, and the debrief.

## 3. Qloo integration depth

All Qloo access is in `functions/bootstrap/qloo_client.py` (the API client) and
`functions/bootstrap/taste_match.py` (the logic). The client is self-contained
(stdlib HTTP, no SDK) and authed with the `QLOO_API_KEY` secret via the
`X-Api-Key` header.

**Endpoints / signals used:**

| Qloo call | How Ayma uses it |
|---|---|
| `GET /search?query=…&types=…` | Resolve each favourite name to a Qloo entity. Types: `urn:entity:artist` (music), `urn:entity:movie` (film), `urn:entity:place` (food & places). |
| `GET /v2/insights` with `signal.interests.entities` | Taste-graph recommendations driven by **all** of a person's resolved entities at once — so every recommendation is **cross-domain** (your films and food influence your music recs, not just your music). `filter.type` selects the output entity type; `take` bounds the set. |
| `GET /v2/insights` with `filter.location.query` | The date-ideas query: places near the first person's city, driven by **both** people's entities together. |
| entity `affinity` + `tags` (in the insights payload) | `tags` annotate *why* a date idea fits ("jazz, live-music, cinematic"); `affinity` orders the joint picks. |

**Scoring.** For each domain we pull Qloo recommendations for person A and for
person B; the domain score is the **overlap coefficient** of the two
recommendation sets (`|A∩B| / min(|A|,|B|)`) × 100; the overall score is the mean
across domains. Shared tastes are the names both people listed outright, then the
recommendations both taste graphs surface, in the joint ranking's order. Labels:
≥70 strong · ≥45 good · ≥25 some · else different.

**Date ideas.** One joint insights call for `urn:entity:place` filtered to the
first person's city gives the top 3 places; the top joint `movie` and `artist`
that neither person already listed become the "movie night" and "listening date"
picks — each annotated with its Qloo tags.

**Rate handling (real, in the client).** The hackathon key allows 10 req/s; one
match fires ~25 calls, so `LiveQlooClient` paces calls process-wide at 8/s and
retries a 429 twice after the one-second window resets. Results are cached per
pair.

**Resilience.** A `FixtureQlooClient` (48 real, well-known entities in
`qloo_fixture.json`; tags illustrative, not Qloo data) stands in when no key is
set, and **any** live failure (timeout, auth, odd payload) falls back to it for
that request — so the surface never goes dark. Every response carries
`source: "qloo" | "fixture"`; the UI shows a "sample data" chip on fixture.

## 4. It's live — verified

Public, no sign-in, free through judging:
**<https://ayma-api-235381544962.us-central1.run.app/taste/demo>**

Verified on **2026-10-29** against the deployed service (all `source: "qloo"`,
i.e. the real Qloo Insights API, not the fixture):

| Pair | Score | music / film / dining |
|---|---|---|
| Maya × Leo | 25 — some overlap | 0 / 25 / 50 |
| Aisha × Noah | 42 — some overlap | 50 / 25 / 50 |
| Maya × Aisha | 25 — some overlap | 50 / 12 / 12 |
| Leo × Noah | 25 — some overlap | 0 / 25 / 50 |

Example (Aisha × Noah): shared *Fleet Foxes, Free Solo, Sufjan Stevens*; date
ideas *Berkeley Rose Garden, Cafe Milano, Saul's Deli* (places), *Marriage Story*
(film), *Sufjan Stevens* (music) — all Qloo-ranked for both. First (uncached)
match ~6.5–7.5 s (each Insights call is ~1–4 s); cached thereafter.

Deployed revision / live since: `TODO(verify)` the exact current `ayma-api`
revision (recorded as `ayma-api-00221-wjd`, live since 2026-10-27, in
`docs/QLOO_TASTE.md`). The demo responding with `source: "qloo"` today confirms
the live key path is working regardless of the exact revision string.

## 5. Open-source repo

Scoped public repo (Apache-2.0, license detectable in the GitHub About):
**<https://github.com/suhailps93/ayma-taste-qloo>**

It contains the real `qloo_client.py` + `taste_match.py` + fixture + demo page,
a **standalone runnable demo** (`python3 demo_taste.py` → Music/Film/Food → Qloo
→ score + date ideas, no key/db/network needed), self-contained tests
(`12 passed`), and docs. It deliberately excludes Ayma's private core (auth,
matching, Firestore, the Gemini client, the voice worker, the app shell); those
narrow interfaces are reproduced by clearly-labelled test-only stubs. No secrets.

## 6. Significant update during the window ("New & Existing" rule)

Ayma existed before the hackathon as a dating companion, but **the entire Qloo
taste layer is new, built in late October 2026 for this hackathon** — there was
no taste graph, no shared-taste score, and no taste-based date ideas in Ayma
before this. It is additive: no pre-existing surface changed behaviour, and the
Qloo code sits behind its own kill switch. What's new and Qloo-specific:
`qloo_client.py`, `taste_match.py`, `qloo_fixture.json`, `taste_demo.html`, the
taste questions in the questionnaire, the public Taste page that fills from them,
the match-report "Taste match · powered by Qloo" section, and the public judge
demo. All of it is in the public repo above and on the `meta-hackathon` branch.

## 7. Impact

Dating apps match on photos and checkboxes; the first date is still a cold,
high-stakes guess. Ayma's agent takes that guess off the table — it rehearses
and even simulates the date for you — and Qloo is what makes the result
*actionable*: not a vibe score, but "here's the taste you actually share and
here's exactly where to go." It turns a compatibility number into a plan.

## 8. Cost & safety

- **Public data only.** Only taste names a person published are sent to Qloo —
  never private pages, contact details, coordinates, or the caller's own private
  data.
- **18+.** The signed-in endpoint is age-gated; the public demo pairs only the
  four fabricated demo profiles and refuses any other id, so it can never read a
  real user.
- **Kill switch.** The `qloo_enabled` flag (default on) short-circuits every
  taste match **before any outbound Qloo call**, so billing can be stopped
  instantly with no redeploy (`scripts/flags.py set qloo_enabled=false --yes`).
- Not credit-metered to users (Qloo hackathon key, no LLM call in the taste path).

## Still needing the founder
- Devpost account submission (the write-up text, the repo link, the demo link,
  the video) — I can't submit on your behalf.
- `TODO(verify)`: the exact current deployed `ayma-api` revision and remaining
  Qloo API quota/credits.
- App download links for judges (Android internal-testing link; the public
  TestFlight link Astro is setting up) — see `docs/QLOO_JUDGE_ACCESS.md`.
