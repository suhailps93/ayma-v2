"""Deep-dive web research on a named person (§ deep dive).

Given a full name (+ optional disambiguating context) this runs a two-step
Gemini pass:

1. a grounded research call (``google_search`` + ``url_context``) that sweeps
   the open web and writes up what it finds, with source links;
2. a structured digest of that write-up — a short "who this appears to be",
   the specific claims (each with a source and a confidence), and the links
   (each flagged likely / maybe / unclear as being the same person).

Two callers:

* the user on **themselves** — "look me up so I don't have to repeat it".
  Ayma then walks the digest with them; their confirmations land in the wiki
  through the normal ingest path (nothing is written to the wiki here).
* the user on **someone they're meeting** — a private research note shown only
  to them. Never written to anyone's wiki.
"""

from __future__ import annotations

import logging
import re
import time

import gemini
import schema
from token_ledger import FEATURE_DEEPDIVE

logger = logging.getLogger("ayma.deepdive")

# A dive is cached per (caller, subject) and reused instead of re-searching the
# web, as long as it's younger than this. The web changes slowly for the kind
# of facts a dive surfaces, and a fresh search is the single most expensive
# thing Ayma does (§ cost review 2026-09-07).
_MAX_CACHE_AGE_DAYS = 60
_CACHE_COL = "deep_dives"


def _cache_key(target_uid: str, name: str) -> str:
    """Stable id for a dive subject: the app uid when we have one, else a slug
    of the name so a free-text "look up Jane Doe" reuses too."""
    t = (target_uid or "").strip()
    if t:
        return f"uid_{t}"
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
    return f"name_{slug}" if slug else ""


def _cache_ref(db, uid: str, key: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(_CACHE_COL)
        .document(key)
    )


def _epoch(ts) -> float:
    try:
        return ts.timestamp()
    except Exception:  # noqa: BLE001
        return 0.0


def cached_dive(
    db,
    uid: str,
    *,
    target_uid: str = "",
    name: str = "",
    max_age_days: int = _MAX_CACHE_AGE_DAYS,
) -> dict | None:
    """A stored digest for this (caller, subject) if one exists and is younger
    than ``max_age_days`` — else ``None``. Best-effort; a read failure is a miss.
    The returned dict carries ``from_cache`` / ``cached_age_days``."""
    key = _cache_key(target_uid, name)
    if not db or not uid or not key:
        return None
    try:
        snap = _cache_ref(db, uid, key).get()
        if not snap.exists:
            return None
        data = snap.to_dict() or {}
        digest = data.get("digest")
        if not isinstance(digest, dict):
            return None
        age_days = (time.time() - _epoch(data.get("created_at"))) / 86400
        if age_days < 0 or age_days > max_age_days:
            return None
        out = dict(digest)
        out["from_cache"] = True
        out["cached_age_days"] = round(age_days, 1)
        return out
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive cache read failed for %s/%s", uid, key)
        return None


def store_dive(
    db, uid: str, digest: dict, *, target_uid: str = "", name: str = ""
) -> None:
    """Persist a fresh digest so the next dive on the same subject reuses it."""
    key = _cache_key(target_uid, name)
    if not db or not uid or not key or not isinstance(digest, dict):
        return
    try:
        from firebase_admin import firestore

        _cache_ref(db, uid, key).set(
            {
                "digest": digest,
                "name": digest.get("name") or name,
                "target_uid": (target_uid or "").strip(),
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive cache write failed for %s/%s", uid, key)


def _profile_dict(db, uid: str) -> dict:
    try:
        return schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001 - a profile read must never break a lookup
        return {}


def profile_full_name(db, uid: str) -> str:
    """The subject's research name: ``"{first_name} {last_name}"`` when the
    profile carries both, else the plain ``name`` field (``""`` if neither)."""
    data = _profile_dict(db, uid)
    first = str(data.get("first_name", "")).strip()
    last = str(data.get("last_name", "")).strip()
    if first and last:
        return f"{first} {last}"
    return str(data.get("name", "")).strip()


def profile_dive_context(db, uid: str) -> str:
    """Extra disambiguation drawn from the user's own profile for a *self*
    lookup — location as plain context, and the phone number as a
    use-only-to-disambiguate note that is never fed into the search query."""
    data = _profile_dict(db, uid)
    bits: list[str] = []
    loc = str(data.get(schema.PF_LOCATION, "")).strip()
    if loc:
        bits.append(f"Location: {loc}.")
    phone = str(data.get("phone", "")).strip()
    if phone:
        bits.append(
            f"(the user also gave the phone number {phone} — only use it to "
            f"disambiguate, never publish or repeat it)"
        )
    return " ".join(bits)

_RESEARCH_SYSTEM = (
    "You are a careful open-source researcher. You are given a person's full "
    "name and some context. Search the web thoroughly — professional profiles, "
    "company pages, news, talks, papers, personal sites, social profiles, "
    "directories. Report everything you can attribute to this specific person, "
    "always noting the source URL. Where several people share the name, say so "
    "and separate them. Do not invent anything; if the web is thin, say that. "
    "This is a consented lookup — either the person researching themselves, or "
    "someone doing normal due diligence before a date."
)

_DIGEST_SYSTEM = (
    "Turn the research notes into a compact JSON digest. Be conservative: only "
    "include a claim if the notes support it, and set confidence honestly. "
    "`is_them` on each link says how sure we are the link is about THIS person "
    "(same name alone is 'maybe'). Keep `summary` to 2-4 plain sentences."
)

_DIGEST_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "confidence": {
            "type": "string",
            "enum": ["high", "medium", "low", "not_found"],
        },
        "facts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "claim": {"type": "string"},
                    "category": {
                        "type": "string",
                        "description": "work | education | location | "
                        "projects | writing | press | social | other",
                    },
                    "source_url": {"type": "string"},
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                    },
                },
                "required": ["claim", "category", "confidence"],
            },
        },
        "links": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "url": {"type": "string"},
                    "title": {"type": "string"},
                    "is_them": {
                        "type": "string",
                        "enum": ["likely", "maybe", "unclear"],
                    },
                    "note": {"type": "string"},
                },
                "required": ["url", "is_them"],
            },
        },
        "caveats": {"type": "string"},
    },
    "required": ["summary", "confidence", "facts", "links"],
}

_MAX_NAME = 120
_MAX_CONTEXT = 600


async def run(
    name: str,
    *,
    db=None,
    uid: str | None = None,
    context: str = "",
    is_self: bool = False,
    target_uid: str = "",
    force: bool = False,
) -> dict:
    """Research ``name`` and return
    ``{name, summary, confidence, facts, links, caveats, is_self}``.

    Raises ``ValueError`` for an empty name. Metered to ``uid`` under the
    ``deepdive`` feature; a cap hit propagates ``TokenCapExceeded``.

    When ``db`` is given, a dive on the same subject younger than
    ``_MAX_CACHE_AGE_DAYS`` is returned from cache (no web search, no metering)
    unless ``force`` is set; a fresh dive is written back to that cache."""
    name = (name or "").strip()[:_MAX_NAME]
    if not name:
        raise ValueError("a full name is required")
    context = (context or "").strip()[:_MAX_CONTEXT]

    if db is not None and uid and not force:
        hit = cached_dive(db, uid, target_uid=target_uid, name=name)
        if hit is not None:
            hit["is_self"] = is_self
            logger.info(
                "deep-dive cache hit for %s (%.1fd old)",
                uid,
                hit.get("cached_age_days", -1),
            )
            return hit

    who = "yourself" if is_self else "this person"
    ask = (
        f"Full name: {name}\n"
        f"Context: {context or '(none given)'}\n\n"
        f"Research {who} and write up everything you can find, with source "
        f"URLs inline."
    )
    prose, sources = await gemini.research(
        ask,
        system_prompt=_RESEARCH_SYSTEM,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
        max_output_tokens=6000,
    )

    src_lines = "\n".join(
        f"- {s['url']}  ({s.get('title', '')})" for s in sources
    )
    digest = await gemini.generate_json(
        f"Full name: {name}\nContext: {context or '(none)'}\n\n"
        f"RESEARCH NOTES:\n{prose or '(the search returned little)'}\n\n"
        f"SOURCE LINKS SEEN:\n{src_lines or '(none)'}",
        system_prompt=_DIGEST_SYSTEM,
        response_schema=_DIGEST_SCHEMA,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
    )
    if not isinstance(digest, dict):
        digest = {}

    result = {
        "name": name,
        "is_self": is_self,
        "summary": str(digest.get("summary", "")).strip(),
        "confidence": str(digest.get("confidence", "not_found")),
        "facts": [f for f in (digest.get("facts") or []) if isinstance(f, dict)],
        "links": [ln for ln in (digest.get("links") or []) if isinstance(ln, dict)],
        "caveats": str(digest.get("caveats", "")).strip(),
    }
    if db is not None and uid:
        store_dive(db, uid, result, target_uid=target_uid, name=name)
    return result


def render(digest: dict) -> str:
    """A short chat-ready summary of a :func:`run` result — what Ayma says
    before she starts confirming details with the user."""
    name = digest.get("name", "them")
    conf = digest.get("confidence", "not_found")
    if conf == "not_found" or (not digest.get("facts") and not digest.get("summary")):
        return (
            f"I searched the web for {name} and didn't find much I could "
            f"confidently pin to one person. Want to tell me the basics yourself?"
        )

    lines = []
    if digest.get("from_cache"):
        age = digest.get("cached_age_days") or 0
        when = "earlier today" if age < 1 else (
            "yesterday" if age < 2 else f"about {round(age)} days ago"
        )
        lines.append(f"_Reusing the search I ran {when} — nothing here changes "
                     f"fast. Ask me to search again if you want it fresh._")
        lines.append("")
    lines.append(digest.get("summary", "").strip())
    facts = digest.get("facts") or []
    if facts:
        lines.append("")
        for f in facts[:8]:
            claim = str(f.get("claim", "")).strip()
            if claim:
                lines.append(f"- {claim}")
    links = [ln for ln in (digest.get("links") or []) if ln.get("url")]
    if links:
        lines.append("")
        lines.append("Links I think are you/them:")
        for ln in links[:6]:
            tag = ln.get("is_them", "unclear")
            lines.append(f"- [{ln.get('title') or ln['url']}]({ln['url']}) ({tag})")
    if digest.get("caveats"):
        lines.append("")
        lines.append(f"_{digest['caveats']}_")
    lines.append("")
    lines.append(
        "Which of these are right, and is anything off or missing?"
        if digest.get("is_self")
        else "Anything here you want me to keep in mind, or that looks wrong?"
    )
    return "\n".join(x for x in lines if x is not None).strip()
