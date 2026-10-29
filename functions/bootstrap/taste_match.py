"""Taste match powered by Qloo (Qloo hackathon, Oct 2026).

For a pair of people, reads each person's public "Taste" page (music / film /
dining favourites), resolves those names to Qloo taste-graph entities, and
returns:

* a **taste compatibility signal** — a 0–100 shared-taste score, a label, a
  short human summary, per-domain overlap, and the tastes they share. Both the
  score bars and the shared-taste surface are grounded in the domains BOTH
  people actually stated: a domain only one side listed is never scored, never
  shown as an overlap, and never the "strongest overlap", and the only entities
  surfaced as a shared taste are ones both pages listed — Qloo's cross-domain
  predictions drive the per-domain score but are never presented as a stated
  taste. The per-domain overlap is how much the two people's stated entities and
  Qloo recommendations overlap in each both-stated domain (cross-domain: every
  recommendation is driven by ALL of a person's signals);
* **taste-based date ideas** — Qloo place recommendations near the first
  person's city driven by BOTH people's signals at once, plus a film and a
  music pick both of their taste graphs rank highly.

Privacy: only PUBLIC profile data is read, for both people
(:func:`public_profile.build` — public wiki at query level, private spans
stripped, blocked/deleted refused). Nothing private is sent to Qloo; only
entity names the person published.

Surfaces: ``POST /taste/pair`` (signed in, 18+; caller × another user, shown
on the AI Date Simulation result) and the public judge demo ``GET /taste/demo``
+ ``GET /taste/demo/pair`` (seeded synthetic demo profiles ONLY — never a real
user). Self-contained (with ``qloo_client.py`` + ``qloo_fixture.json`` +
``taste_demo.html``) so it lifts cleanly into the public hackathon repo.
"""

from __future__ import annotations

import asyncio
import logging
import re
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

import public_profile
import qloo_client
from auth import Caller, require_caller
from db import get_db
from practice_date import require_not_underage_uid

logger = logging.getLogger("ayma.taste_match")

TASTE_PAGE_TYPE = "taste"

# Header words people use on a Taste page → our domain keys. music/film/dining
# are the original three; tv/books/podcasts/games are recognised ADDITIVELY —
# present only when a Taste page lists them, absent (and zero extra Qloo calls)
# otherwise, so a music/film/food page behaves exactly as before.
_DOMAIN_ALIASES = {
    "music": "music",
    "artists": "music",
    "bands": "music",
    "film": "film",
    "films": "film",
    "movies": "film",
    "movie": "film",
    "dining": "dining",
    "food": "dining",
    "places": "dining",
    "restaurants": "dining",
    "cafes": "dining",
    "tv": "tv",
    "tv shows": "tv",
    "shows": "tv",
    "television": "tv",
    "series": "tv",
    "books": "books",
    "book": "books",
    "reading": "books",
    "authors": "books",
    "podcasts": "podcasts",
    "podcast": "podcasts",
    "games": "games",
    "game": "games",
    "video games": "games",
    "videogames": "games",
    "gaming": "games",
    "travel": "travel",
    "destinations": "travel",
    "destination": "travel",
    "trips": "travel",
    "places to go": "travel",
    "brands": "brands",
    "brand": "brands",
    "fashion": "brands",
    "style": "brands",
    "nightlife": "nightlife",
    "bars": "nightlife",
    "clubs": "nightlife",
    "going out": "nightlife",
}
_DOMAIN_LABELS = {
    "music": "music",
    "film": "film",
    "dining": "food & places",
    "tv": "TV",
    "books": "books",
    "podcasts": "podcasts",
    "games": "games",
    "travel": "travel",
    "brands": "fashion & brands",
    "nightlife": "nightlife",
}
# Domains that need a tag filter on their Qloo recs (a place type narrowed to a
# scene). Keyed by domain; applied to every insights call for that domain.
_DOMAIN_FILTER_TAGS = {"nightlife": ["urn:tag:category:place:nightlife"]}
_MAX_PER_DOMAIN = 5
_RECS_PER_DOMAIN = 8
_MAX_DATE_PLACES = 3

# The judge demo may ONLY pair these seeded synthetic profiles.
DEMO_UIDS = {
    "maya": "demo_practice_maya",
    "leo": "demo_practice_leo",
    "aisha": "demo_practice_aisha",
    "noah": "demo_practice_noah",
}
_DEMO_PAGE = Path(__file__).parent / "taste_demo.html"
_demo_cache: dict[tuple[str, str], dict] = {}

NO_TASTE_MESSAGE = (
    "{name} hasn't added a public Taste page yet — add one with lines like "
    "'Music: …', 'Film: …', 'Food: …' to see a taste match."
)
# One-sided states. Rather than dead-ending on "they haven't added it", we tell
# the viewer exactly what's missing and (when it's the other person) surface the
# viewer's OWN tastes so the card still carries their taste signal.
VIEWER_MISSING_MESSAGE = (
    "Add your public Taste page — lines like 'Music: …', 'Film: …', 'Food: …' — "
    "to see how your tastes overlap with {other}."
)
OTHER_MISSING_MESSAGE = (
    "{other} hasn't added a public Taste page yet, so there's no overlap to show "
    "— but yours is ready ({mine}). The moment {other} adds theirs, your shared "
    "tastes and date ideas appear here."
)
_DOMAIN_SUMMARY_ORDER = (
    ("music", "Music"),
    ("film", "Film"),
    ("dining", "Food"),
    ("tv", "TV"),
    ("books", "Books"),
    ("podcasts", "Podcasts"),
    ("games", "Games"),
    ("travel", "Travel"),
    ("brands", "Brands"),
    ("nightlife", "Nightlife"),
)
# Qloo demographic age buckets → short human labels (for the demographics read).
_AGE_LABELS = {
    "24_and_younger": "24 & under",
    "25_to_29": "25–29",
    "30_to_34": "30–34",
    "35_to_44": "35–44",
    "45_to_54": "45–54",
    "55_and_older": "55+",
}


class NoTaste(Exception):
    """A person has no usable public Taste page."""

    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.name = name


def parse_taste(body: str) -> dict[str, list[str]]:
    """``{domain: [names]}`` from a Taste page body.

    Accepts ``Domain: a, b, c`` segments separated by newlines or ``·``;
    unknown headers are ignored, duplicates dropped, order kept."""
    out: dict[str, list[str]] = {}
    for segment in re.split(r"[\n·]", body or ""):
        head, sep, rest = segment.partition(":")
        if not sep:
            continue
        domain = _DOMAIN_ALIASES.get(head.strip().lower())
        if not domain:
            continue
        names = out.setdefault(domain, [])
        for name in rest.split(","):
            name = " ".join(name.split()).strip(" .")
            if name and name not in names and len(names) < _MAX_PER_DOMAIN:
                names.append(name)
    return {d: n for d, n in out.items() if n}


def taste_from_view(view: dict | None) -> tuple[str, str, dict[str, list[str]]]:
    """``(name, city, taste)`` from a :func:`public_profile.build` view."""
    if not view or view.get("deleted") or view.get("blocked"):
        raise ValueError("no reachable profile")
    name = str(view.get("name") or "").strip()
    taste: dict[str, list[str]] = {}
    for page in view.get("pages") or []:
        if page.get("page_type") == TASTE_PAGE_TYPE:
            for domain, names in parse_taste(page.get("body") or "").items():
                merged = taste.setdefault(domain, [])
                merged.extend(n for n in names if n not in merged)
    if not taste:
        raise NoTaste(name or "This person")
    return name, str(view.get("location") or ""), taste


def _view_name(view: dict | None) -> str:
    """Display name from a public view, for a message even when taste is absent."""
    return (str((view or {}).get("name") or "").strip()) or "they"


def _safe_taste(view: dict | None) -> tuple[str, str, dict[str, list[str]]] | None:
    """``taste_from_view`` but ``None`` (not raised) when the person simply has
    no Taste page. An unreachable profile (deleted/blocked) still raises
    ``ValueError`` so the caller can drop the section entirely."""
    try:
        return taste_from_view(view)
    except NoTaste:
        return None


def _taste_summary(taste: dict[str, list[str]]) -> str:
    """``Music: …; Film: …; Food: …`` from a parsed taste map, for the viewer's
    own tastes in the one-sided empty state."""
    parts = [
        f"{label}: {', '.join(taste[domain])}"
        for domain, label in _DOMAIN_SUMMARY_ORDER
        if taste.get(domain)
    ]
    return "; ".join(parts)


def _label(score: int) -> str:
    if score >= 70:
        return "Strong taste overlap"
    if score >= 45:
        return "Good taste overlap"
    if score >= 25:
        return "Some taste overlap"
    return "Different tastes"


def _join(items: list[str]) -> str:
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


async def _resolve(client, taste: dict[str, list[str]]) -> dict[str, list[dict]]:
    """Resolve each taste name to a Qloo entity of its domain's type."""
    jobs = [
        (domain, asyncio.to_thread(client.search, name, qloo_client.ENTITY_TYPES[domain]))
        for domain, names in taste.items()
        for name in names
    ]
    hits = await asyncio.gather(*(j for _, j in jobs))
    out: dict[str, list[dict]] = {}
    for (domain, _), hit in zip(jobs, hits):
        if hit and all(h["id"] != hit["id"] for h in out.get(domain, [])):
            out.setdefault(domain, []).append(hit)
    return out


# Tag subtypes that read as taste descriptors ("Indie", "A24", "Slow-burn") —
# preferred for the "why you match" headline over niche keyword/dish/decor tags.
_HEADLINE_TAG_SUBTYPES = (":genre:", ":subgenre:", ":theme:", ":style:", ":music:")


def _headline(tid: str) -> bool:
    return any(s in tid for s in _HEADLINE_TAG_SUBTYPES)


def _shared_tags(a_tags: list[dict], b_tags: list[dict], a_ents, b_ents) -> list[str]:
    """The taste descriptors both people's graphs share — the "why you match".

    Two complementary Qloo tag signals, blended into readable labels:

    * **Entity genre/theme tags** — the curated genre/theme/style tags on each
      person's resolved entities (from ``/search``), intersected. These are the
      clean descriptors of what they actually listed (e.g. both love Khruangbin
      → "Psychedelic", "Funk"), so genre/theme matches lead.
    * **Profile tags** — Qloo's affinity-ranked tags for each whole taste
      profile (``client.tags`` → ``/v2/insights filter.type=urn:tag``),
      intersected, as a supplement so broader shared affinities still surface.

    Headline (genre/theme/style) labels always lead; niche keyword tags fill in
    only when nothing cleaner is shared, so a real overlap always shows."""
    from collections import Counter

    def pairs(ents):
        return [
            (name, tid)
            for es in ents.values()
            for e in es
            for name, tid in zip(e["tags"], e.get("tag_ids") or [""] * len(e["tags"]))
        ]

    a_pairs, b_pairs = pairs(a_ents), pairs(b_ents)
    a_counts = Counter(name for name, _ in a_pairs)
    b_names = {name for name, _ in b_pairs}
    nice = {name for name, tid in a_pairs + b_pairs if _headline(tid)}
    ent_shared = [n for n in a_counts if n in b_names]
    ent_shared.sort(key=lambda n: (n not in nice, -a_counts[n], n))
    ent_headline = [n for n in ent_shared if n in nice]

    b_by_id = {t["id"]: t for t in b_tags}
    api = sorted(
        (
            (t["affinity"] + b_by_id[t["id"]]["affinity"], t["name"])
            for t in a_tags
            if t["id"] in b_by_id and _headline(t["id"])
        ),
        key=lambda x: (-x[0], x[1]),
    )
    api_headline = [name for _, name in api]

    shared: list[str] = []
    for name in ent_headline + api_headline + ent_shared:
        if name not in shared:
            shared.append(name)
    return shared[:8]


def _demo_read(demo: dict) -> dict | None:
    """One person's audience skew → ``{top_age, gender_lean, age, gender}``, or
    ``None`` when Qloo returned no demographics (offline, or a thin signal)."""
    if not demo:
        return None
    age = demo.get("age") or {}
    gender = demo.get("gender") or {}
    top_age = max(age, key=age.get) if age else None
    gender_lean = None
    if gender:
        male, female = gender.get("male", 0.0), gender.get("female", 0.0)
        gender_lean = (
            "male" if male > female else "female" if female > male else "balanced"
        )
    return {
        "top_age": _AGE_LABELS.get(top_age, top_age) if top_age else None,
        "gender_lean": gender_lean,
        "age": age,
        "gender": gender,
    }


def _demographics_block(
    a_name: str, b_name: str, a_demo: dict, b_demo: dict
) -> dict | None:
    """The ``demographics`` response block from each person's Qloo audience skew.

    Sends only taste entity ids to Qloo (never user identity); reads back the
    age/gender lean of the AUDIENCE for those tastes. ``None`` when neither side
    has data, so the card simply omits it."""
    a_read, b_read = _demo_read(a_demo), _demo_read(b_demo)
    if not a_read and not b_read:
        return None
    note = ""
    if a_read and b_read and a_read["top_age"] and b_read["top_age"]:
        if a_read["top_age"] == b_read["top_age"]:
            note = f"Both your tastes index with the {a_read['top_age']} crowd."
        else:
            note = (
                f"{a_name}'s tastes index {a_read['top_age']}, "
                f"{b_name}'s {b_read['top_age']}."
            )
    return {"a": a_read, "b": b_read, "note": note}


async def _match_with(client, a: tuple, b: tuple) -> dict:
    a_name, a_city, a_taste = a
    b_name, b_city, b_taste = b
    a_ents, b_ents = await asyncio.gather(
        _resolve(client, a_taste), _resolve(client, b_taste)
    )
    a_ids = [e["id"] for es in a_ents.values() for e in es]
    b_ids = [e["id"] for es in b_ents.values() for e in es]
    if not a_ids:
        raise NoTaste(a_name)
    if not b_ids:
        raise NoTaste(b_name)
    both_ids = a_ids + [i for i in b_ids if i not in a_ids]

    # Score only the domains BOTH people actually listed (ordered by
    # ENTITY_TYPES). A shared taste can only exist where both sides stated
    # entries, so a domain only one person filled is never scored, never shown
    # as an overlap bar, and never the "strongest overlap" (bug G: Qloo
    # cross-domain predictions for a domain the viewer left blank must not be
    # surfaced as a stated/shared taste). A music/film/food pair still fires
    # exactly the original three domains; TV/Books/… add their calls only when
    # BOTH pages list them.
    domains = [
        d for d in qloo_client.ENTITY_TYPES if d in a_taste and d in b_taste
    ]
    rec_jobs = []
    for domain in domains:
        etype = qloo_client.ENTITY_TYPES[domain]
        dft = _DOMAIN_FILTER_TAGS.get(domain)
        rec_jobs.append(asyncio.to_thread(client.insights, etype, a_ids, filter_tags=dft, take=_RECS_PER_DOMAIN))
        rec_jobs.append(asyncio.to_thread(client.insights, etype, b_ids, filter_tags=dft, take=_RECS_PER_DOMAIN))
        rec_jobs.append(asyncio.to_thread(client.insights, etype, both_ids, filter_tags=dft, take=_RECS_PER_DOMAIN))

    # Tag-align the date places to BOTH people: the place tags their dining
    # picks share (filter.tags takes tag URNs, not freeform strings). Empty when
    # they share no dining tags — then the places call is unfiltered as before.
    place_filter_tags = sorted(
        {t for e in a_ents.get("dining", []) for t in e.get("tag_ids") or [] if t}
        & {t for e in b_ents.get("dining", []) for t in e.get("tag_ids") or [] if t}
    )
    location = a_city or b_city or None
    places_job = asyncio.to_thread(
        client.insights,
        qloo_client.ENTITY_TYPES["dining"],
        both_ids,
        location=location,
        filter_tags=place_filter_tags or None,
        take=_MAX_DATE_PLACES,
    )
    jobs = [
        *rec_jobs,
        places_job,
        asyncio.to_thread(client.tags, a_ids, take=40),
        asyncio.to_thread(client.tags, b_ids, take=40),
        asyncio.to_thread(client.demographics, a_ids),
        asyncio.to_thread(client.demographics, b_ids),
    ]
    results = await asyncio.gather(*jobs)
    recs = results[: len(rec_jobs)]
    places, a_tags, b_tags, a_demo, b_demo = results[len(rec_jobs):]
    # If the tag filter excluded every place, fall back to the unfiltered picks
    # so date ideas never go dark on a tight tag match.
    if not places and place_filter_tags:
        places = await asyncio.to_thread(
            client.insights,
            qloo_client.ENTITY_TYPES["dining"],
            both_ids,
            location=location,
            take=_MAX_DATE_PLACES,
        )

    shared_tags = _shared_tags(a_tags, b_tags, a_ents, b_ents)
    demographics = _demographics_block(a_name, b_name, a_demo, b_demo)

    per_domain: list[dict] = []
    shared: list[str] = []
    joint_by_domain: dict[str, list[dict]] = {}
    # The ONLY entities surfaced as a shared taste are ones BOTH people listed
    # on their own Taste page — never a Qloo cross-domain prediction (bug G).
    a_seed = {e["id"]: e["name"] for es in a_ents.values() for e in es}
    seed_ids = set(a_ids) | set(b_ids)
    for e in (e for es in b_ents.values() for e in es):
        if e["id"] in a_seed and e["name"] not in shared:
            shared.append(e["name"])
    # Per-domain overlap, for the both-stated domains only. Each person's set is
    # their stated entities in the domain PLUS Qloo's recommendations for it, so
    # a directly-shared favourite always counts and a genuinely shared domain
    # never reads as a spurious 0 (bug G: Music/Film scored 0 while an
    # inferred-only domain scored highest). Qloo's predicted entities drive the
    # score but are never surfaced as a stated/shared taste.
    for i, domain in enumerate(domains):
        a_recs, b_recs, joint = recs[3 * i], recs[3 * i + 1], recs[3 * i + 2]
        joint_by_domain[domain] = joint
        a_set = {r["id"] for r in a_recs} | {e["id"] for e in a_ents.get(domain, [])}
        b_set = {r["id"] for r in b_recs} | {e["id"] for e in b_ents.get(domain, [])}
        if not a_set or not b_set:
            continue
        common = a_set & b_set
        per_domain.append(
            {
                "domain": domain,
                "score": round(100 * len(common) / min(len(a_set), len(b_set))),
            }
        )

    score = (
        round(sum(d["score"] for d in per_domain) / len(per_domain))
        if per_domain
        else 0
    )
    shared = shared[:6]
    best = max(per_domain, key=lambda d: d["score"], default=None)
    # The narrative must agree with the header label (bug G: header said
    # "Different tastes" while the narrative claimed an overlap). Only genuine
    # stated overlap is phrased as a shared taste; the "Different tastes" band
    # (score < 25) never claims one, and the strongest-overlap line is appended
    # only above that band so header and narrative can't contradict.
    if shared:
        summary = f"{a_name} and {b_name} both listed {_join(shared[:3])}."
    elif score >= 25:
        summary = (
            f"{a_name} and {b_name} didn't list the same favourites, but their "
            "taste graphs lean the same way."
        )
    else:
        summary = f"{a_name} and {b_name} have quite different taste graphs."
    if best and best["score"] > 0 and score >= 25:
        summary += f" Strongest overlap: {_DOMAIN_LABELS[best['domain']]}."

    # Cross-domain hook: the place recs are tag-aligned to both people, so say
    # which shared taste drives them ("because you both lean …").
    tag_hook = f" Because you both lean {shared_tags[0]}." if shared_tags else ""
    date_ideas = [
        {
            "name": p["name"],
            "kind": "dining",
            "why": "Ranked by Qloo for both of your tastes"
            + (f" ({', '.join(p['tags'][:3])})" if p["tags"] else "")
            + "."
            + tag_hook,
            "address": p["address"],
        }
        for p in places
    ]
    # One pick per OTHER present domain (film + music as before; TV/Books/
    # Podcasts/Games join only when the pair listed them).
    for domain, lead in (
        ("film", "Movie night"),
        ("music", "Listening date or live show"),
        ("tv", "Binge night"),
        ("books", "Book swap"),
        ("podcasts", "A podcast to share"),
        ("games", "Game night"),
        ("travel", "Weekend trip"),
        ("nightlife", "Night out"),
        ("brands", "Browse together"),
    ):
        if domain not in joint_by_domain:
            continue
        pick = next(
            (r for r in joint_by_domain[domain] if r["id"] not in seed_ids),
            None,
        ) or next(iter(joint_by_domain[domain]), None)
        if pick:
            date_ideas.append(
                {
                    "name": pick["name"],
                    "kind": domain,
                    "why": f"{lead}: Qloo ranks it highly for both of you.",
                    "address": None,
                }
            )

    return {
        "source": client.source,
        "a": {"name": a_name},
        "b": {"name": b_name},
        "score": score,
        "score_label": _label(score),
        "summary": summary,
        "shared": shared,
        "shared_tags": shared_tags,
        "demographics": demographics,
        "domains": per_domain,
        "date_ideas": date_ideas,
    }


async def match(a: tuple, b: tuple, client=None) -> dict:
    """Taste match for two ``(name, city, taste)`` tuples. Uses the live Qloo
    client when configured; any live failure falls back to the fixture so the
    surface never goes dark (the response's ``source`` says which ran).

    Kill switch: when the ``qloo_enabled`` feature flag is OFF this makes NO
    Qloo call at all (not even the fixture) and raises :class:`NoTaste`, so
    every surface degrades to the no-taste empty state and nothing can bill
    Qloo. Flip it with ``scripts/flags.py set qloo_enabled=false --yes`` (no
    redeploy). See docs/FEATURE_FLAGS.md."""
    if not qloo_client.qloo_enabled():
        logger.info("qloo_enabled is off — skipping all Qloo calls (kill switch)")
        raise NoTaste((a[0] if a else "") or "This person")
    client = client or qloo_client.get_client()
    try:
        return await _match_with(client, a, b)
    except qloo_client.QlooError:
        logger.warning("qloo live call failed; using fixture", exc_info=True)
        return await _match_with(qloo_client.FixtureQlooClient(), a, b)


def _no_taste_detail(exc: NoTaste) -> dict:
    return {"code": "no_taste", "message": NO_TASTE_MESSAGE.format(name=exc.name)}


async def _resolve_pair(db, viewer_uid: str, other_uid: str) -> tuple[str, object]:
    """Resolve the viewer × other taste pair from both PUBLIC views.

    Returns ``("ok", match_payload)`` when BOTH have a usable Taste page, else
    ``("no_taste", message)`` naming which side is missing — surfacing the
    viewer's own tastes when it's the OTHER person who hasn't added one, so the
    card never dead-ends. Raises ``ValueError`` if a profile is unreachable
    (deleted/blocked), so the caller can omit the section."""
    a_view = await asyncio.to_thread(public_profile.build, db, viewer_uid, viewer_uid)
    b_view = await asyncio.to_thread(public_profile.build, db, viewer_uid, other_uid)
    a = _safe_taste(a_view)
    b = _safe_taste(b_view)
    other_name = _view_name(b_view)
    if a and b:
        return "ok", await match(a, b)
    if a and not b:
        return "no_taste", OTHER_MISSING_MESSAGE.format(
            other=other_name, mine=_taste_summary(a[2])
        )
    if b and not a:
        return "no_taste", VIEWER_MISSING_MESSAGE.format(other=other_name)
    return "no_taste", NO_TASTE_MESSAGE.format(name=other_name)


async def report_section(db, viewer_uid: str, other_uid: str) -> dict | None:
    """The "Taste match · powered by Qloo" section for the match report between
    the viewer and another matched user, from BOTH people's PUBLIC Taste pages
    only (same engine as ``POST /taste/pair`` — no duplicated Qloo calls, no
    private or cross-user private reads).

    Returns the taste-match payload (``score`` / ``score_label`` / ``summary``
    / ``shared`` / ``domains`` / ``date_ideas`` / ``source``) with
    ``status: "ok"``; a ``{"status": "no_taste", "message": …}`` empty-state
    marker when one or both people have no public Taste page; or ``None`` on
    any unexpected failure, so the report renders without the section rather
    than erroring. A live Qloo failure already falls back to the fixture inside
    :func:`match`, so this never dark-fails on a transient vendor error. The
    one-sided empty state (viewer has taste, match doesn't) surfaces the viewer's
    own tastes rather than a bare "they haven't added it" — see
    :func:`_resolve_pair`."""
    try:
        status, payload = await _resolve_pair(db, viewer_uid, other_uid)
        if status == "ok":
            result = payload
            result["status"] = "ok"
            return result
        return {"status": "no_taste", "message": payload}
    except NoTaste as exc:
        # Kill switch (qloo disabled) — match() short-circuits to NoTaste.
        return {
            "status": "no_taste",
            "message": NO_TASTE_MESSAGE.format(name=exc.name),
        }
    except ValueError:
        return None
    except Exception:  # noqa: BLE001 — the report must render without this section
        logger.warning("taste section for match report failed", exc_info=True)
        return None


# --------------------------------------------------------------------------- #
# HTTP API (mounted by main.py via app.include_router)
# --------------------------------------------------------------------------- #
router = APIRouter(tags=["taste_match"])


class PairRequest(BaseModel):
    other_uid: str = Field(..., min_length=1, max_length=128)


@router.post("/taste/pair", dependencies=[Depends(require_not_underage_uid)])
async def taste_pair(
    req: PairRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """Taste compatibility + date ideas for the caller and ``other_uid``, from
    both people's PUBLIC Taste pages."""
    db = get_db()
    other = req.other_uid.strip()
    try:
        status, payload = await _resolve_pair(db, caller.uid, other)
    except NoTaste as exc:
        # Kill switch (qloo disabled) — match() short-circuits to NoTaste.
        raise HTTPException(status_code=404, detail=_no_taste_detail(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="No profile to match with.") from exc
    if status == "ok":
        return payload
    raise HTTPException(
        status_code=404, detail={"code": "no_taste", "message": payload}
    )


@router.get("/taste/demo", response_class=HTMLResponse, include_in_schema=False)
async def taste_demo_page() -> HTMLResponse:
    """Public judge demo page (seeded synthetic profiles only)."""
    return HTMLResponse(_DEMO_PAGE.read_text(encoding="utf-8"))


@router.get("/taste/demo/pair")
async def taste_demo_pair(
    a: str = Query(..., max_length=16), b: str = Query(..., max_length=16)
) -> dict[str, object]:
    """Public, unauthenticated taste match between two SEEDED DEMO profiles
    (``maya``/``leo``/``aisha``/``noah``). Any other id is refused, so this
    route can never read a real user. Results are cached per pair."""
    a_key, b_key = a.strip().lower(), b.strip().lower()
    if a_key not in DEMO_UIDS or b_key not in DEMO_UIDS or a_key == b_key:
        raise HTTPException(status_code=404, detail="Pick two different demo profiles.")
    if (a_key, b_key) in _demo_cache:
        return _demo_cache[(a_key, b_key)]
    db = get_db()
    a_uid, b_uid = DEMO_UIDS[a_key], DEMO_UIDS[b_key]
    try:
        pa = taste_from_view(await asyncio.to_thread(public_profile.build, db, b_uid, a_uid))
        pb = taste_from_view(await asyncio.to_thread(public_profile.build, db, a_uid, b_uid))
        result = await match(pa, pb)
    except NoTaste as exc:
        raise HTTPException(status_code=404, detail=_no_taste_detail(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Demo profile not seeded.") from exc
    _demo_cache[(a_key, b_key)] = result
    return result
