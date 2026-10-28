# Taste match powered by Qloo (Qloo Agentic Hackathon)

Shared-taste score + taste-based date ideas for a pair, from Qloo's Taste API
(taste graph across music, film and dining). Built on `meta-hackathon` for the
Qloo Agentic Hackathon (Devpost, closes Fri Oct 30 2026, 8:45 PM PT). Additive:
no existing surface changes behaviour.

## Try it (judges)

Public, no sign-in: **`https://ayma-api-235381544962.us-central1.run.app/taste/demo`**.
Pick two of the four synthetic demo profiles (Maya · SF, Leo · Oakland,
Aisha · Berkeley, Noah · San Jose) and press **Match tastes**. JSON:
`GET /taste/demo/pair?a=maya&b=leo`.

In the app: open a demo profile → **Simulate a conversation** → run it; the
**Taste match** card sits under the compatibility score.

## How it works

1. **Taste signals** — each person's PUBLIC "Taste" wiki page (`page_type:
   "taste"`), lines like `Music: Khruangbin, Bon Iver`, `Film: Arrival`,
   `Food: Ramen Shop` (aliases: artists/bands, movies/films, food/places/
   restaurants/cafes; max 5 per domain). Parsed by `taste_match.parse_taste`.
2. **Resolve** every name to a Qloo entity of its domain's type
   (`GET /search?query=…&types=urn:entity:artist|movie|place`).
3. **Compatibility** — for each domain, Qloo recommendations (`GET /v2/insights`,
   `signal.interests.entities` = ALL of a person's entities, so it's
   cross-domain) for person A and for person B; domain score = overlap
   coefficient of the two recommendation sets × 100; overall = mean of domains.
   Shared tastes = names both listed outright, then shared recommendations in
   the joint ranking's order. Label: ≥70 strong, ≥45 good, ≥25 some, else
   different. Summary is a short template over the shared names + best domain.
4. **Date ideas** — one joint Qloo query (both people's entities at once) for
   `urn:entity:place` filtered to the first person's city (`filter.location.query`),
   top 3; plus the top joint film pick ("movie night") and music pick
   ("listening date or live show") that neither person already listed.

## Live vs fixture

`qloo_client.get_client()` returns the live client when `QLOO_API_KEY` is set
(Secret Manager → Cloud Run), else `FixtureQlooClient` — a deterministic mini
taste graph in `functions/bootstrap/qloo_fixture.json` (48 real, well-known
entities; tags illustrative, NOT Qloo data) scoring recommendations by shared
tags. Any live failure (timeout, auth, unexpected payload) falls back to the
fixture for that request. Every response carries `source: "qloo" | "fixture"`;
the web page and app card show a "sample data" chip on fixture.

**Status: LIVE** since 2026-10-27 (ayma-api revision `ayma-api-00221-wjd`): the
deployed service serves `source: "qloo"` from the hackathon Insights API.
Verified demo pairs: maya×leo 25 (music 0, film 25, dining 50), aisha×noah 42
(music 50, film 25, dining 50), maya×aisha 25 (music 50, film 12, dining 12);
~6.5–7.5 s uncached (Insights calls take ~1–4 s each), then cached per pair.

Rate limit: the hackathon key allows 10 requests/second (50,000/month) and one
match makes ~25 calls, so `LiveQlooClient` paces calls process-wide at 8/s and
retries a 429 up to twice after the one-second window resets.

Config (`config.py`): `QLOO_API_BASE_URL` (default
`https://hackathon.api.qloo.com`), `QLOO_TIMEOUT_SECONDS` (default 6). Secret:
`QLOO_API_KEY` — in Secret Manager (ayma-ai), mounted via `SECRETS` in
`scripts/deploy-api.sh` (`--full`); the runtime service account has
`secretAccessor` on it.

## API

- `POST /taste/pair {other_uid}` — signed in, 18+. Caller × other user, both
  from their PUBLIC views (`public_profile.build`; blocked/deleted → 404).
- `GET /taste/demo` — public HTML judge page (`taste_demo.html`).
- `GET /taste/demo/pair?a=&b=` — public; ONLY the four seeded demo ids
  (`maya|leo|aisha|noah`), anything else 404, so it can never read a real user.
  Cached in-process per pair.

Response: `{source, a:{name}, b:{name}, score, score_label, summary, shared[],
domains:[{domain, score}], date_ideas:[{name, kind, why, address}]}`.
No taste page → 404 `{"code":"no_taste","message":…}`.

## Privacy & cost

Public profile data only, for both people (also for the caller — the caller's
own private pages are not used). Only entity names a person published are sent
to Qloo. Not credit-metered (Qloo hackathon key, no LLM call).

## Files (self-contained for the public-repo extraction)

`functions/bootstrap/taste_match.py`, `qloo_client.py`, `qloo_fixture.json`,
`taste_demo.html`, `tests/test_taste_match.py`; the "Taste" pages in
`practice_seed.py`; the router mount in `main.py`; Flutter card under
`ayma_flutter/lib/features/date_sim/`.
