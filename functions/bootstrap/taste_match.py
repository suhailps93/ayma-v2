"""Taste match powered by Qloo (Qloo hackathon, Oct 2026).

For a pair of people, reads each person's public "Taste" page (music / film /
dining favourites), resolves those names to Qloo taste-graph entities, and
returns:

* a **taste compatibility signal** — a 0–100 shared-taste score, a label, a
  short human summary, per-domain overlap, and the tastes they share; computed
  from how much the two people's Qloo recommendations overlap in each domain
  (cross-domain: every recommendation is driven by ALL of a person's signals);
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

# Header words people use on a Taste page → our domain keys.
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
}
_DOMAIN_LABELS = {"music": "music", "film": "film", "dining": "food & places"}
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

    domains = list(qloo_client.ENTITY_TYPES)
    rec_jobs = []
    for domain in domains:
        etype = qloo_client.ENTITY_TYPES[domain]
        rec_jobs.append(asyncio.to_thread(client.insights, etype, a_ids, take=_RECS_PER_DOMAIN))
        rec_jobs.append(asyncio.to_thread(client.insights, etype, b_ids, take=_RECS_PER_DOMAIN))
        rec_jobs.append(asyncio.to_thread(client.insights, etype, both_ids, take=_RECS_PER_DOMAIN))
    places_job = asyncio.to_thread(
        client.insights,
        qloo_client.ENTITY_TYPES["dining"],
        both_ids,
        location=a_city or b_city or None,
        take=_MAX_DATE_PLACES,
    )
    *recs, places = await asyncio.gather(*rec_jobs, places_job)

    per_domain: list[dict] = []
    shared: list[str] = []
    joint_by_domain: dict[str, list[dict]] = {}
    # Tastes both people listed outright come first.
    a_seed = {e["id"]: e["name"] for es in a_ents.values() for e in es}
    seed_ids = set(a_ids) | set(b_ids)
    for e in (e for es in b_ents.values() for e in es):
        if e["id"] in a_seed and e["name"] not in shared:
            shared.append(e["name"])
    for i, domain in enumerate(domains):
        a_recs, b_recs, joint = recs[3 * i], recs[3 * i + 1], recs[3 * i + 2]
        joint_by_domain[domain] = joint
        a_set = {r["id"] for r in a_recs}
        b_set = {r["id"] for r in b_recs}
        if not a_set or not b_set:
            continue
        common = a_set & b_set
        per_domain.append(
            {
                "domain": domain,
                "score": round(100 * len(common) / min(len(a_set), len(b_set))),
            }
        )
        # Shared recommendations, in the joint ranking's order.
        for r in joint:
            if r["id"] in common and r["name"] not in shared:
                shared.append(r["name"])

    score = (
        round(sum(d["score"] for d in per_domain) / len(per_domain))
        if per_domain
        else 0
    )
    shared = shared[:6]
    best = max(per_domain, key=lambda d: d["score"], default=None)
    if shared:
        summary = (
            f"{a_name} and {b_name}'s tastes meet around {_join(shared[:3])}."
        )
    else:
        summary = f"{a_name} and {b_name} have quite different taste graphs."
    if best and best["score"] > 0:
        summary += f" Strongest overlap: {_DOMAIN_LABELS[best['domain']]}."

    date_ideas = [
        {
            "name": p["name"],
            "kind": "dining",
            "why": "Ranked by Qloo for both of your tastes"
            + (f" ({', '.join(p['tags'][:3])})" if p["tags"] else "")
            + ".",
            "address": p["address"],
        }
        for p in places
    ]
    for domain, kind, lead in (
        ("film", "film", "Movie night"),
        ("music", "music", "Listening date or live show"),
    ):
        pick = next(
            (r for r in joint_by_domain.get(domain, []) if r["id"] not in seed_ids),
            None,
        ) or next(iter(joint_by_domain.get(domain, [])), None)
        if pick:
            date_ideas.append(
                {
                    "name": pick["name"],
                    "kind": kind,
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
    :func:`match`, so this never dark-fails on a transient vendor error."""
    try:
        a = taste_from_view(
            await asyncio.to_thread(public_profile.build, db, viewer_uid, viewer_uid)
        )
        b = taste_from_view(
            await asyncio.to_thread(public_profile.build, db, viewer_uid, other_uid)
        )
        result = await match(a, b)
        result["status"] = "ok"
        return result
    except NoTaste as exc:
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
        a = taste_from_view(await asyncio.to_thread(public_profile.build, db, caller.uid, caller.uid))
        b = taste_from_view(await asyncio.to_thread(public_profile.build, db, caller.uid, other))
        return await match(a, b)
    except NoTaste as exc:
        raise HTTPException(status_code=404, detail=_no_taste_detail(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="No profile to match with.") from exc


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
