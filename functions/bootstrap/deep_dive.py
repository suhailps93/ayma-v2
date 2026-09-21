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

import hashlib
import logging
import re
import time
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import gemini
import schema
from token_ledger import FEATURE_DEEPDIVE

_PROMPTS_PATH = Path(__file__).with_name("prompts") / "deep_dive.md"

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


def dive_report_id(target_uid: str = "", name: str = "") -> str:
    """The stable id of the stored dive for a subject — same value used as the
    ``deep_dives`` doc id and the ``[deep_dive:<id>]`` chat marker."""
    return _cache_key(target_uid, name)


def read_dive(db, uid: str, report_id: str) -> dict | None:
    """The stored dive doc for ``report_id`` (a :func:`dive_report_id` value),
    or ``None``. Best-effort — a read failure is a miss."""
    report_id = (report_id or "").strip()
    if not db or not uid or not report_id:
        return None
    try:
        snap = _cache_ref(db, uid, report_id).get()
        if not getattr(snap, "exists", False):
            return None
        data = snap.to_dict() or {}
        if not isinstance(data.get("digest"), dict):
            return None
        return data
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive report read failed for %s/%s", uid, report_id)
        return None


def has_dive(db, uid: str, *, target_uid: str = "", name: str = "") -> bool:
    """Whether a stored dive exists for this subject (any age)."""
    return read_dive(db, uid, _cache_key(target_uid, name)) is not None


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


# Wiki page types a self-dive can draw a compact disambiguation line from —
# enough to tell apart "same name, different person" or narrow a common name,
# never a full narrative dump (§ Part 1). "career" covers studies too, per
# wiki_schema.json's own description of that page type.
_WIKI_CONTEXT_TYPES = ("identity", "career", "interests")
_MAX_WIKI_CONTEXT = 350
_MAX_DISPUTED_CONTEXT = 300


def _first_sentence(body: str, limit: int) -> str:
    """The first sentence of ``body``, hard-capped at ``limit`` chars — a
    one-line pull, not the page's full prose."""
    body = re.sub(r"\s+", " ", (body or "")).strip()
    if not body:
        return ""
    m = re.match(r"(.{1,%d}?[.!?])(\s|$)" % max(limit, 1), body)
    sentence = (m.group(1) if m else body[:limit]).strip()
    if not sentence:
        return ""
    if not sentence.endswith((".", "!", "?")):
        sentence += "."
    return sentence


def wiki_dive_context(db, uid: str) -> str:
    """A compact, factual one-liner-per-page pull from the user's own wiki
    (``identity`` / ``career`` / ``interests``) — e.g. "Works as a robotics
    engineer at Acme; lives in Austin." Purely disambiguation material for a
    *self* web search: helping tell the right person apart from someone who
    shares their name, never a source of "fact" to report back or trust over
    what the web search actually turns up (the research/digest prompts in
    ``prompts/deep_dive.md`` say this explicitly)."""
    if not db or not uid:
        return ""
    try:
        snaps = list(
            db.collection("users").document(uid).collection("wiki_pages").stream()
        )
    except Exception:  # noqa: BLE001 - a wiki read failure must not break a dive
        logger.exception("deep-dive wiki-context read failed for %s", uid)
        return ""
    bodies: dict[str, str] = {}
    for snap in snaps:
        data = snap.to_dict() or {}
        pt = data.get("page_type")
        body = str(data.get("ai_body") or "").strip()
        if pt in _WIKI_CONTEXT_TYPES and body and pt not in bodies:
            bodies[pt] = body
    bits = [
        _first_sentence(bodies[pt], 140)
        for pt in _WIKI_CONTEXT_TYPES
        if bodies.get(pt)
    ]
    bits = [b for b in bits if b]
    if not bits:
        return ""
    return " ".join(bits)[:_MAX_WIKI_CONTEXT]


def disputed_facts_context(db, uid: str, name: str) -> str:
    """A note of claims the user already told Ayma are wrong about *this*
    subject, from a prior self-dive report — so a re-search doesn't just
    resurrect the same wrong claim (§ Part 2). Empty when there's no stored
    report for ``name`` yet, or nothing has been disputed on it."""
    key = _cache_key("", name)
    if not db or not uid or not key:
        return ""
    try:
        snap = _cache_ref(db, uid, key).get()
        if not getattr(snap, "exists", False):
            return ""
        data = snap.to_dict() or {}
        disputed = data.get("disputed_facts") or []
        claims = [
            str(d.get("claim", "")).strip()
            for d in disputed
            if isinstance(d, dict) and str(d.get("claim", "")).strip()
        ]
        if not claims:
            return ""
        note = (
            "The user has already told Ayma these specific claims are WRONG "
            "— do not report them again unless the web independently "
            "re-verifies them with new evidence: " + "; ".join(claims[:8]) + "."
        )
        return note[:_MAX_DISPUTED_CONTEXT]
    except Exception:  # noqa: BLE001
        logger.exception(
            "deep-dive disputed-facts read failed for %s/%s", uid, key
        )
        return ""


def profile_dive_context(db, uid: str, name: str = "") -> str:
    """Extra disambiguation drawn from the user's own profile and wiki for a
    *self* lookup: location as plain context, the phone number as a
    use-only-to-disambiguate note never fed into the search query, a compact
    factual pull from the user's own wiki (:func:`wiki_dive_context`), and —
    when ``name`` is given and this subject has a prior report with disputed
    facts — a note of the specific claims already told wrong
    (:func:`disputed_facts_context`). All of it is disambiguation material,
    never a source of "fact" the research/digest prompts should copy or trust
    over the live web (see ``prompts/deep_dive.md``)."""
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
    wiki_bit = wiki_dive_context(db, uid)
    if wiki_bit:
        bits.append(
            "What the user has told Ayma before (background for "
            f"disambiguation only, not verified — see instructions): {wiki_bit}"
        )
    if name:
        disputed_bit = disputed_facts_context(db, uid, name)
        if disputed_bit:
            bits.append(disputed_bit)
    return " ".join(bits)


def fact_id(fact: dict) -> str:
    """Stable id for one digest fact, derived from its claim + category text
    rather than array position — position shifts once facts start getting
    removed by a dispute (§ Part 2)."""
    claim = str((fact or {}).get("claim", "")).strip().lower()
    category = str((fact or {}).get("category", "")).strip().lower()
    basis = f"{category}|{claim}"
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()[:12]


def dispute_fact(db, uid: str, report_id: str, target_fact_id: str) -> dict | None:
    """Mark one fact on a stored dive report incorrect: remove it from the
    persisted ``digest.facts`` and remember it as the user's own correction in
    ``disputed_facts`` on the same doc, so :func:`disputed_facts_context` picks
    it up on the next dive for this subject.

    Returns the updated ``{report_id, digest, disputed_facts}`` on success, or
    ``None`` when there's no such report or no such fact on it. Raises
    ``PermissionError`` when the report is about someone other than the
    caller — disputing a fact is a *self*-dive action only, never available on
    a report about someone the user looked up."""
    report_id = (report_id or "").strip()
    target_fact_id = (target_fact_id or "").strip()
    if not db or not uid or not report_id or not target_fact_id:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    target = str(data.get("target_uid") or "").strip()
    if target and target != uid:
        raise PermissionError("dispute is only ever available on a self-dive")

    kept: list[dict] = []
    removed: dict | None = None
    for f in digest.get("facts") or []:
        if not isinstance(f, dict):
            continue
        this_id = str(f.get("id") or "") or fact_id(f)
        if removed is None and this_id == target_fact_id:
            removed = f
            continue
        kept.append(f)
    if removed is None:
        return None

    digest = dict(digest)
    digest["facts"] = kept
    disputed = list(data.get("disputed_facts") or [])
    disputed.append(
        {
            "claim": str(removed.get("claim", "")).strip(),
            "category": str(removed.get("category", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
    )
    ref.set({"digest": digest, "disputed_facts": disputed}, merge=True)
    return {"report_id": report_id, "digest": digest, "disputed_facts": disputed}


# --- free-text corrections (§ deep dive corrections, Part 2 follow-up) ------
#
# A softer sibling of :func:`dispute_fact`: instead of a one-tap "this is
# wrong" that always removes the claim, this is the tap-a-claim,
# talk-in-your-own-words pattern Your Story's "Edit with Ayma" uses — the
# user's own message decides whether the right move is to drop the claim
# entirely, revise its wording, add a caveat, or leave it as is. Self-dives
# only, like `dispute_fact`.

_CORRECTION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {
            "type": "string",
            "enum": ["remove", "revise", "caveat", "keep"],
        },
        "revised_text": {"type": "string"},
        "reply": {"type": "string"},
    },
    "required": ["action", "revised_text", "reply"],
}

_CORRECTION_SYSTEM = (
    "You are Ayma. The user is correcting one piece of a web-research report "
    "about themselves, in their own words. Decide the right action:\n"
    '- "remove": the claim is simply wrong — drop it entirely.\n'
    '- "revise": the claim is basically right but needs a specific fix — '
    'write the corrected version in "revised_text".\n'
    '- "caveat": the claim might be right but needs a qualifier or context — '
    'write the ORIGINAL text plus that qualifier in "revised_text".\n'
    '- "keep": the message doesn\'t actually call for a change (a question, '
    'agreement, or something unrelated) — set "revised_text" to the '
    "original, unchanged.\n"
    "Always write a short, warm, first-person reply as Ayma (one sentence)."
)


async def correct(
    db, uid: str, report_id: str, target: str, feedback: str
) -> dict | None:
    """Free-text correction of one piece of a stored *self*-dive report — the
    overall ``summary`` (``target="summary"``) or one fact
    (``target="fact:<id>"``) — the tap-a-claim conversational pattern the rest
    of the app uses, instead of a structured editor.

    Returns ``{reply, action, digest}`` on success — ``digest`` is the full,
    updated report the caller re-renders from. ``None`` when there's no such
    report. Raises ``ValueError`` for an unknown ``target`` (→ 404) or blank
    ``feedback`` (→ 422), and ``PermissionError`` when the report isn't the
    caller's own self-dive (→ 403), exactly like :func:`dispute_fact`.
    Propagates ``token_ledger.TokenCapExceeded`` on a credit-cap hit."""
    report_id = (report_id or "").strip()
    target = (target or "").strip()
    feedback = (feedback or "").strip()
    if not feedback:
        raise ValueError("feedback must not be blank")
    if not db or not uid or not report_id:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    owner = str(data.get("target_uid") or "").strip()
    if owner and owner != uid:
        raise PermissionError("correcting a report is only ever available on a self-dive")

    target_fact_id = ""
    if target == "summary":
        original = str(digest.get("summary", "")).strip()
    elif target.startswith("fact:"):
        target_fact_id = target[len("fact:"):]
        original = None
        for f in digest.get("facts") or []:
            if not isinstance(f, dict):
                continue
            this_id = str(f.get("id") or "") or fact_id(f)
            if this_id == target_fact_id:
                original = str(f.get("claim", "")).strip()
                break
        if original is None:
            raise ValueError(f"Unknown correction target: {target!r}")
    else:
        raise ValueError(f"Unknown correction target: {target!r}")

    result = await gemini.generate_json(
        f'Current text: "{original}"\nThe user says: "{feedback}"',
        system_prompt=_CORRECTION_SYSTEM,
        response_schema=_CORRECTION_SCHEMA,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
    )
    action = str((result or {}).get("action") or "keep")
    if action not in ("remove", "revise", "caveat", "keep"):
        action = "keep"
    revised = str((result or {}).get("revised_text") or original).strip()
    reply = str((result or {}).get("reply") or "").strip() or "Noted."

    digest = dict(digest)
    disputed = list(data.get("disputed_facts") or [])

    if target == "summary":
        if action == "remove":
            digest["summary"] = ""
        elif action == "revise":
            digest["summary"] = revised
        elif action == "caveat" and revised and revised != original:
            digest["caveats"] = (str(digest.get("caveats") or "").strip() + " " + revised).strip()
        # "keep": no change.
    else:
        facts = []
        for f in digest.get("facts") or []:
            if not isinstance(f, dict):
                continue
            this_id = str(f.get("id") or "") or fact_id(f)
            if this_id != target_fact_id:
                facts.append(f)
                continue
            if action == "remove":
                disputed.append(
                    {
                        "claim": str(f.get("claim", "")).strip(),
                        "category": str(f.get("category", "")).strip(),
                        "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                    }
                )
                continue
            if action in ("revise", "caveat") and revised:
                f = dict(f)
                f["claim"] = revised
            facts.append(f)
        digest["facts"] = facts

    ref.set({"digest": digest, "disputed_facts": disputed}, merge=True)
    return {"reply": reply, "action": action, "digest": digest}


@lru_cache(maxsize=1)
def _prompt_sections() -> dict[str, str]:
    """The ``## name`` sections of ``prompts/deep_dive.md``."""
    text = _PROMPTS_PATH.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^##\s+([\w-]+)\s*$", line)
        if m:
            if key is not None:
                out[key] = "\n".join(buf).strip()
            key, buf = m.group(1), []
        elif key is not None:
            buf.append(line)
    if key is not None:
        out[key] = "\n".join(buf).strip()
    return out


_RESEARCH_SYSTEM = _prompt_sections()["research_system"]

_DIGEST_SYSTEM = _prompt_sections()["digest_system"]

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
        "social_profiles": {
            "type": "array",
            "description": "Social-media profiles the notes tie to this "
            "person — never a guessed handle.",
            "items": {
                "type": "object",
                "properties": {
                    "platform": {
                        "type": "string",
                        "description": "instagram | x | twitter | linkedin | "
                        "facebook | tiktok | github | youtube",
                    },
                    "handle": {"type": "string"},
                    "url": {"type": "string"},
                    "tie_signal": {
                        "type": "string",
                        "description": "why this profile is this person "
                        "(name match, photo match, bio, linked from a "
                        "confirmed page)",
                    },
                },
                "required": ["platform"],
            },
        },
        "caveats": {"type": "string"},
    },
    "required": ["summary", "confidence", "facts", "links"],
}

_MAX_NAME = 120
# Room for the original location/phone bits plus the new wiki-disambiguation
# and disputed-facts additions (each separately capped above) — still a
# handful of short lines, never paragraphs.
_MAX_CONTEXT = 1000


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

    When ``db`` is given, a dive on *someone else* younger than
    ``_MAX_CACHE_AGE_DAYS`` is returned from cache (no web search, no
    metering) unless ``force`` is set. Researching **yourself** always
    re-searches — the cache exists so someone else looking you up (or
    reopening your saved report) doesn't retrigger a search, not so your own
    re-run goes stale; a fresh dive is written back to that same cache doc
    either way."""
    name = (name or "").strip()[:_MAX_NAME]
    if not name:
        raise ValueError("a full name is required")
    context = (context or "").strip()[:_MAX_CONTEXT]

    if db is not None and uid and not force and not is_self:
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
    # If the user has given Ayma their own LinkedIn URL (their own consent,
    # their own public page — never scraped, never an unofficial API call),
    # hand it straight to Gemini's `url_context` tool (already attached to
    # this call, see gemini.research) so it reads that page directly as part
    # of the same grounded research pass. § Your Story career timeline.
    linkedin_note = ""
    if is_self and db is not None and uid:
        try:
            import career_timeline

            linkedin_url = career_timeline.get_linkedin_url(db, uid)
            if linkedin_url:
                linkedin_note = (
                    "\nThe user has also given you their own LinkedIn profile "
                    f"URL — review it directly: {linkedin_url}"
                )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive: linkedin url lookup failed for %s", uid)
    ask = (
        f"Full name: {name}\n"
        f"Context: {context or '(none given)'}\n\n"
        f"Research {who} and write up everything you can find, with source "
        f"URLs inline.{linkedin_note}"
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

    def _real_url(u: str) -> str:
        # Gemini grounding hands back opaque redirect URLs — useless to a
        # reader and ugly in the wiki. Drop them.
        u = str(u or "").strip()
        bad = ("vertexaisearch.cloud.google.com", "grounding-api-redirect")
        return "" if any(b in u for b in bad) else u

    facts = []
    for f in (digest.get("facts") or []):
        if not isinstance(f, dict):
            continue
        f = dict(f)
        f["source_url"] = _real_url(f.get("source_url", ""))
        # A stable id per fact — array position shifts once a dispute (§ Part
        # 2) starts removing entries, so the client needs something durable.
        f["id"] = fact_id(f)
        facts.append(f)
    links = []
    for ln in (digest.get("links") or []):
        if not isinstance(ln, dict):
            continue
        ln = dict(ln)
        ln["url"] = _real_url(ln.get("url", ""))
        if ln["url"]:
            links.append(ln)

    # Find photos of this person on the open web and keep only the ones whose
    # face matches their own profile photos. Works for self *and* an Explore
    # user — keyed to whichever person the dive is about. Best-effort.
    #
    # Two sources, merged: the Programmable Search image API (richer, needs
    # IMAGE_SEARCH_API_KEY / IMAGE_SEARCH_CSE_ID) and — always on, no key — the
    # primary image (og:image / twitter:image) of each link the dive already
    # tied to this person.
    web_images: list[dict] = []
    social_handles: list[dict] = []
    img_target = target_uid or (uid if is_self else "")
    if db is not None:
        try:
            import deep_dive_images

            loc = (
                str(_profile_dict(db, img_target).get("location") or "").strip()
                if img_target
                else ""
            )
            web_images = await deep_dive_images.find_web_images(
                db, img_target, name, extra_terms=loc, links=links, uid=uid
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive image step failed for %s", img_target)

        # Social-media handles the dive can tie to this person by name and/or a
        # profile-photo face match. Confidence-gated — an empty list when
        # nothing clears the bar (never a low-confidence guess).
        try:
            import deep_dive_social

            social_handles = deep_dive_social.find_social_handles(
                links,
                facts,
                name,
                summary_text=str(digest.get("summary", "")),
                digest_socials=digest.get("social_profiles") or [],
                db=db,
                target_uid=img_target or None,
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive social step failed")

    result = {
        "name": name,
        "is_self": is_self,
        "summary": str(digest.get("summary", "")).strip(),
        "confidence": str(digest.get("confidence", "not_found")),
        "facts": facts,
        "links": links,
        "web_images": web_images,
        "social_handles": social_handles,
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
    imgs = digest.get("web_images") or []
    verified_imgs = [im for im in imgs if im.get("verified")]
    who_p = "you" if digest.get("is_self") else "them"
    if verified_imgs:
        n = len(verified_imgs)
        lines.append("")
        lines.append(
            f"I also found {n} photo{'s' if n != 1 else ''} online that look "
            f"like {who_p} — see them in the report."
        )
    elif imgs:
        lines.append("")
        lines.append(
            f"I found some photos online that might be {who_p}, but couldn't "
            "confirm the face — they're in the report, unverified."
        )
    socials = [s for s in (digest.get("social_handles") or []) if s.get("url")]
    if socials:
        lines.append("")
        lines.append(
            "Profiles I'm fairly sure are you:"
            if digest.get("is_self")
            else "Profiles I'm fairly sure are them:"
        )
        for s in socials[:6]:
            plat = str(s.get("platform", "")).strip() or "profile"
            handle = str(s.get("handle", "")).strip()
            label = f"@{handle}" if handle else (
                str(s.get("display_name", "")).strip() or s["url"]
            )
            tag = "verified" if s.get("confidence") == "high" else "likely"
            lines.append(
                f"- {plat.capitalize()}: [{label}]({s['url']}) ({tag})"
            )
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
