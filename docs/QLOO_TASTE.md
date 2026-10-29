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

The card (`taste_match_card.dart`) shows the overall score, label, summary,
shared-taste chips and date ideas, plus **per-domain bars** — one horizontal
0–100 bar per domain (accent fill on a faint track, value right-aligned with
tabular figures), ordered Music → Film → Food & places (`dining` → "Food &
places"), reproducing the public demo `taste_demo.html`. Bars appear only when
both sides have taste (`domains` non-empty); otherwise the card shows the
no-Taste-page note. Below the summary it also surfaces the depth fields: a
**"Why you match"** row of outline tag chips from `shared_tags` (wrapping,
visually distinct from the filled `shared` entity chips, hidden when empty) and
a compact muted **demographics line** from `demographics.note` (shown only when
the block is non-null and its note non-empty; the raw skew maps are not shown).
Pure presentation over the data the report/pair already return (`taste.domains`,
`taste.shared_tags`, `taste.demographics`) — both new rows are additive and
hidden when their data is absent.

## How it works

1. **Taste signals** — each person's PUBLIC "Taste" wiki page (`page_type:
   "taste"`), lines like `Music: Khruangbin, Bon Iver`, `Film: Arrival`,
   `Food: Ramen Shop`, and optionally `TV:`, `Books:`, `Podcasts:`, `Games:`,
   `Travel:`, `Brands:`, `Nightlife:` (full alias + header list below; max 5 per
   domain). Parsed by `taste_match.parse_taste`.
2. **Resolve** every name to a Qloo entity of its domain's type
   (`GET /search?query=…&types=urn:entity:…`) — ten entity types (below).
   Resolved entities carry their Qloo `tags` (names) and `tag_ids` (URNs).
3. **Compatibility** — for each domain **both** people listed, Qloo
   recommendations (`GET /v2/insights`, `signal.interests.entities` = ALL of a
   person's entities, so it's cross-domain) for person A and for person B;
   domain score = overlap coefficient × 100 of the two sets, each being that
   person's **stated entities in the domain plus** their recs (so a directly-
   shared favourite always counts and a shared domain never reads a spurious 0);
   overall = mean of the both-stated domains. **Shared tastes = only names both
   people listed outright** — Qloo's cross-domain predicted entities drive the
   score but are never surfaced as a stated/shared taste. Label: ≥70 strong,
   ≥45 good, ≥25 some, else different. Summary is a short template: it phrases a
   shared taste only from the names both listed, and appends the strongest-
   overlap domain only above the "Different tastes" band, so the header label
   and the narrative never contradict. **Only domains BOTH people listed are
   scored** — a domain only one side filled is never scored, never an overlap
   bar, and never the strongest overlap (bug G); a music/film/food page makes
   exactly the original calls, TV/Books/… add theirs only when both list them.
4. **Why you match (`shared_tags`)** — `GET /v2/insights filter.type=urn:tag`
   gives Qloo's affinity-ranked tags for each whole taste profile; the engine
   intersects the two (genre/theme/style labels surfaced ahead of niche keyword
   tags), blended with the genre/theme tags their resolved entities share, into
   readable descriptors ("Atmospheric", "Melancholic", "Psychedelic") — the
   explainability of the match.
5. **Audience read (`demographics`)** — `GET /v2/insights
   filter.type=urn:demographics` per person returns Qloo's signed age/gender
   over/under-index for each taste entity; averaged into one `{age, gender}`
   read per person, surfaced as `top_age` / `gender_lean` + a shared note. Only
   taste entity ids are sent — never user identity.
6. **Date ideas** — one joint Qloo query (both people's entities at once) for
   `urn:entity:place`, filtered to the first person's city
   (`filter.location.query`) and **tag-aligned to both people** via `filter.tags`
   = the place tags their dining picks share (unfiltered fallback so ideas never
   go dark), top 3; each place "why" names the shared tag. Plus one pick per
   other present domain (film → "movie night", music → "listening date", TV →
   "binge night", books → "book swap", podcasts, games → "game night", travel →
   "weekend trip", nightlife → "night out", brands → "browse together") that the
   joint Qloo ranking puts highly and neither person already listed.

## Qloo API surface we use (depth + breadth)

This is the full enumeration of the Qloo API the taste engine touches — the
"Technological Implementation / Qloo depth" writeup. All calls are `GET` with
the `X-Api-Key` header against `https://hackathon.api.qloo.com`.

**Endpoints & `/v2/insights` surface:**

| Call | Params used | Response path | Drives |
|---|---|---|---|
| `GET /search` | `query`, `types` (one `urn:entity:*`), `take` | `results[]` → `entity_id`, `name`, `tags[].name`, `tags[].tag_id` | name → entity, with tags + tag ids |
| `GET /v2/insights` (entity) | `filter.type=urn:entity:*`, `signal.interests.entities`, `filter.location.query`, `filter.tags`, `take` | `results.entities[]` → `name`, `entity_id`, `query.affinity`, `tags[]`, `properties.address` | per-domain recs → overlap score; joint recs → date ideas |
| `GET /v2/insights` (tags) | `filter.type=urn:tag`, `signal.interests.entities`, `take` | `results.tags[]` → `tag_id`, `name`, `query.affinity` | `shared_tags` (why you match) |
| `GET /v2/insights` (demographics) | `filter.type=urn:demographics`, `signal.interests.entities` | `results.demographics[].query.age.{bucket}`, `.gender.{male,female}` | `demographics` (audience skew) |

Age buckets returned: `24_and_younger`, `25_to_29`, `30_to_34`, `35_to_44`,
`45_to_54`, `55_and_older`; gender: `male`, `female` (signed over/under-index,
roughly −1…+1). `filter.location.query` + `filter.tags` together can over-narrow
and return zero places — the engine falls back to the unfiltered joint query.
`filter.tags` takes tag URNs only (freeform strings are rejected), so place
alignment uses the `tag_id`s the two dining picks share. Nightlife uses
`urn:entity:place` narrowed by `filter.tags=urn:tag:category:place:nightlife`
(verified: that tag + a location filter returns zero, so nightlife recs run
without the location filter).

**Entity types (breadth) ↔ Taste-page headers.** Every type below was verified
to resolve against the LIVE hackathon API (search + insights):

| Domain key | Entity type URN | Header strings parsed (case-insensitive) |
|---|---|---|
| `music` | `urn:entity:artist` | Music, Artists, Bands |
| `film` | `urn:entity:movie` | Film, Films, Movie, Movies |
| `dining` | `urn:entity:place` | Dining, Food, Places, Restaurants, Cafes |
| `tv` | `urn:entity:tv_show` | TV, TV shows, Shows, Television, Series |
| `books` | `urn:entity:book` | Books, Book, Reading, Authors |
| `podcasts` | `urn:entity:podcast` | Podcasts, Podcast |
| `games` | `urn:entity:videogame` | Games, Game, Video games, Videogames, Gaming |
| `travel` | `urn:entity:destination` | Travel, Destinations, Destination, Trips, Places to go |
| `brands` | `urn:entity:brand` | Brands, Brand, Fashion, Style |
| `nightlife` | `urn:entity:place` + nightlife tag | Nightlife, Bars, Clubs, Going out |

> Note on `videogame`: the LIVE hackathon API uses `urn:entity:videogame` (no
> underscore). `urn:entity:video_game` returns HTTP 400 there, so the no-underscore
> form is authoritative for this deployment.

The first three (music/film/dining) are the original demo domains; the rest are
**additive** — recognised only when a Taste page lists them, never required. A
Taste page with only Music/Film/Food scores and calls exactly as before.

**New response fields (additive — for the Flutter card + demo-data follow-up):**
- `shared_tags: string[]` — readable shared taste descriptors (genre/theme tags),
  the "why you match" headline.
- `demographics: {a, b, note} | null` — per person `{top_age, gender_lean, age:{bucket:skew}, gender:{male,female}}`; `note` is a short comparison; `null` when Qloo has no read (e.g. the offline fixture).
- `domains[].domain` and `date_ideas[].kind` now range over the ten domain keys
  above (previously only music/film/dining).

No existing field (`source, a, b, score, score_label, summary, shared, domains,
date_ideas`) was renamed or removed.

**Also available (enumerated, not needed by the match):** `GET /v2/tags`
(resolve freeform text → tag URNs) and `GET /v2/audiences` /
`GET /v2/audiences/types` (`signal.demographics.audiences`); `signal.location`,
`filter.location.radius` (metres), `filter.popularity.min/max` (0–1 percentile),
`filter.exclude.*`, and `filter.type=urn:heatmap` (geo grid). The engine sticks
to the four call shapes above — the ones that improve a *pair* taste match.

## Where the Taste page comes from

Real users populate their PUBLIC Taste page through the normal questionnaire —
no separate taste form or CTA. Three `page_type: "taste"` nodes live in the
question tree (`functions/bootstrap/question_tree.json`, branch `all`, so every
intent and the pre-intent flow see them): `taste_music` (core, weight 5),
`taste_film` and `taste_food` (deep, weight 5). All three carry equal top weight
so answering one domain never crowds the other two out of `next_questions` — a
user with Music filled but Film/Food empty still gets Film and Food ranked at the
very top (founder directive, Qloo demo). Ayma raises them conversationally via
`next_questions` and records the answer with `record_answer` as a comma-separated
list of up to 5 names.

**Asked early (so the Qloo Taste match stops showing empty).** `taste` is a
_promoted_ section in `completeness.py` (`_EARLY_PAGE_TYPES`): it is always
unlocked and transparent to the sequential core-first gate, so it never waits
behind every earlier section's core and never locks the sections after it.
Combined with `taste_music`'s top weight, that lands `taste_music` near the top
of `next` (right after the routing node — the identity basics come from
preboarding and are not re-asked) for any user who hasn't answered it yet, and
makes the **"Tastes (music, film & food)"** section show as an open, fillable
topic on the complete-profile screen. Once `taste_music` is answered,
`taste_film`/`taste_food` unlock within the section and — at equal top weight —
sit at the very top of `next` until they too are answered. The complete-profile screen
is server-driven from `GET /questionnaire` (`completeness.questionnaire_view`),
so this needs no separate UI — the promoted section renders there automatically.

**Three capture paths, all land on the structured Taste page (never Interests).**
There are three ways taste reaches the public Taste page, and none duplicates
into the Interests story:

1. **Direct answer** — Ayma calls `record_answer(taste_music|taste_film|
   taste_food, …)`; the answer is stored on the questionnaire node.
2. **Free-chat extraction** — when the user just names favourites in
   conversation ("I love Iron Man, WALL-E and the Marvel movies", "big AC/DC
   fan", "I could eat ramen every day") without Ayma asking the node outright,
   the `wiki_ingest` pass that compiles the wiki returns a structured
   `taste: {music, film, food}` block (named favourites only, the user's own,
   ≤5 per domain — see `prompts/wiki_ingest.md`, now explicit about capturing
   all three domains). `wiki_ingest` hands it to
   `skills/questionnaire.py::merge_taste_mentions`, which APPENDS those names to
   the taste questionnaire nodes (dedup, cap 5, never overwriting a direct
   answer) and recomposes the Taste page.
3. **Backfill from existing context** (`functions/bootstrap/taste_backfill.py`)
   — for a user whose taste is still thin, mine everything they have ALREADY
   said: their whole Story (all `wiki_pages` via `wiki_query.read_wiki_context`)
   **and** their past voice + text conversation history
   (`chat_history._collect` over `chat_messages` + `raw_turns`). A dedicated
   Gemini pass (`prompts/taste_extract.md`, model from `config.py`) pulls out
   music/film/food favourites across all three domains, folded through the same
   `merge_taste_mentions`. **Idempotent and cheap:** a no-op (three Firestore
   reads, no LLM) the moment all three domains have an entry; only a thin signal
   (any domain empty) runs the extraction. **Triggered** fire-and-forget on
   `GET /completeness` and `GET /questionnaire` (`taste_backfill.schedule`) and
   awaited for both people inside `GET /match/{id}` just before
   `report_section`, so the card fills rather than showing blank Film/Food.
   Exempt from the credit gate (`enforce_cap=False`) like `wiki_ingest`, metered
   under the `taste_backfill` ledger feature. Reads only each user's OWN private
   content to write only names that user themselves stated onto their OWN public
   Taste page — no cross-user private read reaches Qloo or another viewer.

So Film:/Food: fill from the user's film/cuisine mentions **during the taste
flow or free chat** even when Ayma didn't explicitly ask those nodes — the bug
the founder hit (films dumped into the Interests story, Taste `Film:`/`Food:`
left empty, Food never captured). The `wiki_ingest` prompt now routes named
favourite music/films/food to the `taste` block, keeps `interests` for hobbies/
activities only (not lists of favourite titles/dishes), and a narrative `taste`
page op from the model is dropped (the structured path owns that page). The
`interests` page_type description in `wiki_schema.json` was tightened to stop
the "tastes" overlap that invited the misrouting.

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
taste graph in `functions/bootstrap/qloo_fixture.json` (72 real, well-known
entities across all ten domains — artists, movies, TV, books, podcasts,
destinations, brands, places incl. nightlife; tags illustrative, NOT Qloo data)
scoring recommendations by shared tags, with `tags()`/`demographics()` offline
stand-ins (demographics degrades to `null`). Any live failure (timeout, auth,
unexpected payload) falls back to the fixture for that request. Every response carries `source: "qloo" | "fixture"`;
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

**One-sided empty state (improved).** When only one side has a Taste page the
card no longer dead-ends on a bare "they haven't added it." The message is
tailored (`taste_match._resolve_pair`):
- **Viewer has taste, match doesn't** (the founder's "Dillu" case) — the message
  surfaces the viewer's OWN tastes ("…but yours is ready (Music: …; Film: …;
  Food: …). The moment {name} adds theirs, your shared tastes and date ideas
  appear here.") so the viewer's taste signal still shows.
- **Viewer missing, match has taste** — prompts the viewer to add their page and
  names the match.
- **Both missing** — the generic add-a-Taste-page hint.
  This copy is **server-driven** (the Flutter card renders the server `message`
  as its note — `TasteMatchLoad.fromReportValue` / `loadTasteMatch`), so it ships
  the moment ayma-api deploys, no app release needed. Full dual-sided rendering
  (score, shared chips, date ideas) is unchanged when both have taste.
- `GET /taste/demo` — public HTML judge page (`taste_demo.html`).
- `GET /taste/demo/pair?a=&b=` — public; ONLY the four seeded demo ids
  (`maya|leo|aisha|noah`), anything else 404, so it can never read a real user.
  Cached in-process per pair.

Response: `{source, a:{name}, b:{name}, score, score_label, summary, shared[],
shared_tags[], demographics:{a,b,note}|null, domains:[{domain, score}],
date_ideas:[{name, kind, why, address}]}`. `shared_tags` and `demographics` are
additive (see "Qloo API surface" above); `domain`/`kind` range over the ten
domain keys. No taste page → 404 `{"code":"no_taste","message":…}`.

## Privacy & cost

Public profile data only, for both people (also for the caller — the caller's
own private pages are not used). Only entity names a person published are sent
to Qloo — including the demographics call, which sends **only taste entity ids,
never user identity** (name, uid, birthdate, gender, location are never sent).
The `demographics` block is the *audience* Qloo associates with those public
tastes, not the user's own attributes. The match itself is not credit-metered (Qloo hackathon key, no LLM
call). The **taste backfill** is the one taste path that does read a user's own
private content and does make an LLM call: it reads only that user's OWN Story
and conversations, extracts only names they themselves stated, and writes them
onto their OWN public Taste page by the same rules `wiki_ingest` already applies
— no cross-user private read, and nothing private ever reaches Qloo or another
viewer. It is metered (exempt from the credit gate, like `wiki_ingest`) under the
`taste_backfill` ledger feature, and is idempotent (a no-op once all three
domains are filled).

## Files (self-contained for the public-repo extraction)

`functions/bootstrap/taste_match.py`, `qloo_client.py`, `qloo_fixture.json`,
`taste_demo.html`, `tests/test_taste_match.py`; the "Taste" pages in
`practice_seed.py` (all four demo profiles — maya/leo/aisha/noah — carry FULL
Music/Film/Food on BOTH sides, so every demo pair renders a real overlap + date
ideas); the taste capture path `skills/questionnaire.py` (`_sync_taste_page` +
`merge_taste_mentions`), the free-chat extraction in `wiki_ingest.py` /
`prompts/wiki_ingest.md` (+ the tightened `interests` description in
`wiki_schema.json`), and the context backfill `taste_backfill.py` /
`prompts/taste_extract.md` / `tests/test_taste_backfill.py`; the router mount + `GET /match/{id}` embedding in
`main.py`; Flutter shared card `ayma_flutter/lib/widgets/taste_match_card.dart`
+ `taste_models.dart` (reused by the date-sim result and the match report; the
one-sided copy is server-driven, so no app change was needed).
