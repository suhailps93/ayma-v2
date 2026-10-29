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

## Where the Taste page comes from

Real users populate their PUBLIC Taste page through the normal questionnaire —
no separate taste form or CTA. Three `page_type: "taste"` nodes live in the
question tree (`functions/bootstrap/question_tree.json`, branch `all`, so every
intent and the pre-intent flow see them): `taste_music` (core, weight 5),
`taste_film` and `taste_food` (deep, weight 4). Ayma raises them conversationally
via `next_questions` and records the answer with `record_answer` as a
comma-separated list of up to 5 names.

**Asked early (so the Qloo Taste match stops showing empty).** `taste` is a
_promoted_ section in `completeness.py` (`_EARLY_PAGE_TYPES`): it is always
unlocked and transparent to the sequential core-first gate, so it never waits
behind every earlier section's core and never locks the sections after it.
Combined with `taste_music`'s top weight, that lands `taste_music` near the top
of `next` (right after the routing node — the identity basics come from
preboarding and are not re-asked) for any user who hasn't answered it yet, and
makes the **"Tastes (music, film & food)"** section show as an open, fillable
topic on the complete-profile screen. Once `taste_music` is answered,
`taste_film`/`taste_food` unlock within the section. The complete-profile screen
is server-driven from `GET /questionnaire` (`completeness.questionnaire_view`),
so this needs no separate UI — the promoted section renders there automatically.

On any taste answer, `skills/questionnaire.py::_sync_taste_page` composes the
user's `users/{uid}/wiki_pages/taste` page deterministically in the exact shape
`parse_taste` reads:

```
Music: Khruangbin, Bon Iver, Phoebe Bridgers
Film: Arrival, Amélie, Spirited Away
Food: Tartine Bakery, Zuni Café
```

The page is `visibility: "public"` by design — it is the user's own stated
favourites, meant to be shared, exactly like the seeded demo profiles and the
`qz_*` hard-filter mirror. Because the content IS the user's stated answer (no
model inference, nothing embarrassing a reviewer would need to vet), it is
written straight to `ai_body` rather than through the AI-rewrite approval
proposal flow, so the taste match reads fresh data immediately. A manual
`user_edits` override (if the user ever hand-edits the page) still wins in the
public view and is never touched; an existing visibility choice is preserved.
So a pair who both answered the taste questions get a real score with no manual
Taste-page editing — previously only the four seeded demo profiles and anyone
who hand-added a Taste page had taste data.

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
  Shown as the "Taste match" card on the AI Date Simulation result.
- `GET /match/{match_id}` → `taste` — the match-compatibility report between two
  users embeds the SAME taste match as a labeled "Taste match · powered by Qloo"
  section (`taste_match.report_section`, reusing the `/taste/pair` engine — no
  duplicated Qloo calls). The `taste` value is the taste payload with
  `status: "ok"`, a `{"status":"no_taste","message":…}` empty-state marker when
  one/both lack a public Taste page, or `null` on any other failure (the report
  never errors).
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
`practice_seed.py`; the router mount + `GET /match/{id}` embedding in `main.py`;
Flutter shared card `ayma_flutter/lib/widgets/taste_match_card.dart` +
`taste_models.dart` (reused by the date-sim result and the match report).
