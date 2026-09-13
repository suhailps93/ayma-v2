"""Structured career/education timeline (§ Your Story career timeline).

A REAL structured timeline — not just prettier prose — built from what Ayma
already knows: the compiled ``career`` wiki page prose, plus (when a self
deep-dive has been run) any web-research facts it tagged ``work``/``education``.
Those facts may themselves be grounded in the person's own LinkedIn page —
see :func:`deep_dive.run`'s ``url_context`` hand-off — but nothing here ever
scrapes LinkedIn or calls an unofficial API; it only ever reads material the
Gemini research/digest pipeline already produced with the user's consent.

Confidence-gated: :func:`get_or_build_timeline`/:func:`extract` always persist
the extraction, but ``show_timeline`` is only ``true`` when every entry AND
the overall read are at least ``medium`` confidence. Below that, the client
renders Career & Education as flowing prose only, exactly like every other
section — never a shaky-looking structured template.

The timeline is chat-editable the same way any other Your Story statement is:
``skills/story_edit.py``'s ``edit_career_timeline_entry`` /
``delete_career_timeline_entry`` tools call :func:`edit_entry` /
:func:`delete_entry` below, scoped to one entry id.
"""

from __future__ import annotations

import hashlib
import logging
import re
import time
from pathlib import Path

from firebase_admin import firestore

import gemini
import schema
import story
import token_ledger
from token_ledger import FEATURE_CAREER_TIMELINE

logger = logging.getLogger("ayma.career_timeline")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "career_timeline.md"

CAREER_PAGE_ID = "career"

# Persisted on the `career` wiki_pages doc, alongside (never replacing) its
# usual `ai_body`/`user_edits` prose fields.
FIELD_TIMELINE = "career_timeline"

# high/medium only — the confidence-gate floor for showing the timeline UI at
# all (§ founder's own scope: "structured template should show up only when
# Ayma have decent confidence").
_DECENT = ("high", "medium")

_MAX_ENTRIES = 12


def _server_ts():
    return firestore.SERVER_TIMESTAMP


def _now_ms() -> int:
    return int(time.time() * 1000)


# --- LinkedIn URL: user-given, their own consent, never scraped -------------

# Deliberately permissive about the exact path (a personal profile is
# `/in/...`, but accept any linkedin.com URL rather than second-guessing the
# user) — the only thing enforced here is that it's actually a LinkedIn link.
_LINKEDIN_RE = re.compile(r"^https?://([\w-]+\.)?linkedin\.com/", re.IGNORECASE)


def is_linkedin_url(url: str) -> bool:
    return bool(_LINKEDIN_RE.match((url or "").strip()))


def get_linkedin_url(db, uid: str) -> str:
    """The user's own LinkedIn URL, if they've given Ayma one. Best-effort —
    a read failure reads as "none on file", never an error."""
    try:
        data = schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        return ""
    return str(data.get(schema.PF_LINKEDIN_URL) or "").strip()


def set_linkedin_url(db, uid: str, url: str) -> str:
    """Store the user's own LinkedIn profile URL, given with their explicit
    consent, so a future self deep-dive can hand it straight to Gemini's
    ``url_context`` tool (see :func:`deep_dive.run`) instead of asking again.
    This is the ONLY LinkedIn mechanism in this app: no scraper, no
    unofficial API call — just a user-supplied URL read by a tool Gemini
    already has attached to the research call. Raises ``ValueError`` for
    anything that isn't plausibly a linkedin.com link."""
    url = (url or "").strip()
    if not is_linkedin_url(url):
        raise ValueError("that doesn't look like a linkedin.com URL")
    schema.profile_doc(db, uid).set({schema.PF_LINKEDIN_URL: url}, merge=True)
    return url


# --- extraction --------------------------------------------------------

_SYSTEM = _PROMPT_PATH.read_text(encoding="utf-8").strip()

_TIMELINE_SCHEMA = {
    "type": "object",
    "properties": {
        "overall_confidence": {
            "type": "string",
            "enum": ["high", "medium", "low", "none"],
        },
        "entries": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "enum": ["work", "education"]},
                    "org": {"type": "string"},
                    "title_or_degree": {"type": "string"},
                    "start": {"type": "string"},
                    "end": {"type": "string"},
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                    },
                },
                "required": ["kind", "org", "confidence"],
            },
        },
    },
    "required": ["overall_confidence", "entries"],
}


def _entry_id(entry: dict) -> str:
    """Stable id derived from content, not array position — position shifts
    once entries start getting edited/removed."""
    basis = "|".join(
        [
            str(entry.get("kind", "")).strip().lower(),
            str(entry.get("org", "")).strip().lower(),
            str(entry.get("title_or_degree", "")).strip().lower(),
        ]
    )
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()[:12]


def _decent(overall: str, entries: list[dict]) -> bool:
    if not entries or overall not in _DECENT:
        return False
    return all(str(e.get("confidence")) in _DECENT for e in entries)


def _career_body(db, uid: str) -> str:
    try:
        _ref, data = story._require_page(db, uid, CAREER_PAGE_ID)
    except KeyError:
        return ""
    return story._display_body(db, uid, CAREER_PAGE_ID, data)


def _digest_work_education_facts(db, uid: str) -> str:
    """Web-research facts tagged work/education from the user's own self
    deep-dive, if one has been run — the one path through which LinkedIn-
    derived material (when the user gave Ayma their LinkedIn URL) can reach
    this extraction. Best-effort; never raises."""
    try:
        import deep_dive

        name = deep_dive.profile_full_name(db, uid)
        if not name:
            return ""
        dive = deep_dive.read_dive(db, uid, deep_dive.dive_report_id(name=name))
        if not dive:
            return ""
        digest = dive.get("digest") or {}
        lines = [
            f"- {f.get('claim', '')} ({f.get('category', '')}, "
            f"{f.get('confidence', '')} confidence)"
            for f in (digest.get("facts") or [])
            if isinstance(f, dict) and f.get("category") in ("work", "education")
        ]
        return "\n".join(lines)
    except Exception:  # noqa: BLE001
        logger.exception("career_timeline: reading the self-dive digest failed for %s", uid)
        return ""


async def extract(db, uid: str) -> dict:
    """One structured-extraction Gemini call over the user's career material,
    persisted onto the ``career`` wiki page (:data:`FIELD_TIMELINE`) and
    returned as ``{entries, overall_confidence, show_timeline, updated_at}``
    (or ``{"usage_capped": True}`` on a credit-cap hit). Always safe to call
    repeatedly — the confidence gate, not caller judgement, decides whether
    the client renders the visual timeline."""
    career_body = _career_body(db, uid)
    digest_bits = _digest_work_education_facts(db, uid)
    linkedin_url = get_linkedin_url(db, uid)
    linkedin_note = (
        f"The user's own LinkedIn profile is {linkedin_url} — it may already "
        "be reflected in the web-research facts above if a self search has "
        "reviewed it."
        if linkedin_url
        else "No LinkedIn URL is on file for this user yet."
    )
    contents = (
        "CAREER & EDUCATION SECTION (compiled from conversation):\n"
        f"{career_body or '(nothing yet)'}\n\n"
        "WEB-RESEARCH FACTS TAGGED WORK/EDUCATION:\n"
        f"{digest_bits or '(none)'}\n\n"
        f"{linkedin_note}"
    )

    try:
        result = await gemini.generate_json(
            contents,
            system_prompt=_SYSTEM,
            response_schema=_TIMELINE_SCHEMA,
            uid=uid,
            feature=FEATURE_CAREER_TIMELINE,
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    result = result if isinstance(result, dict) else {}
    overall = str(result.get("overall_confidence") or "none").strip().lower()
    if overall not in ("high", "medium", "low", "none"):
        overall = "none"

    entries: list[dict] = []
    for e in (result.get("entries") or [])[:_MAX_ENTRIES]:
        if not isinstance(e, dict):
            continue
        kind = str(e.get("kind") or "").strip().lower()
        org = str(e.get("org") or "").strip()
        if kind not in ("work", "education") or not org:
            continue
        confidence = str(e.get("confidence") or "low").strip().lower()
        if confidence not in ("high", "medium", "low"):
            confidence = "low"
        entry = {
            "kind": kind,
            "org": org,
            "title_or_degree": str(e.get("title_or_degree") or "").strip(),
            "start": str(e.get("start") or "").strip(),
            "end": str(e.get("end") or "").strip(),
            "confidence": confidence,
        }
        entry["id"] = _entry_id(entry)
        entries.append(entry)

    payload = {
        "entries": entries,
        "overall_confidence": overall,
        "show_timeline": _decent(overall, entries),
        "updated_at": _now_ms(),
    }
    try:
        story._pages_col(db, uid).document(CAREER_PAGE_ID).set(
            {FIELD_TIMELINE: payload}, merge=True
        )
    except Exception:  # noqa: BLE001 - extraction result is still returned
        logger.exception("career_timeline: persisting the timeline failed for %s", uid)
    return payload


def _read_payload(db, uid: str) -> dict | None:
    try:
        snap = story._pages_col(db, uid).document(CAREER_PAGE_ID).get()
    except Exception:  # noqa: BLE001
        return None
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    payload = data.get(FIELD_TIMELINE)
    return payload if isinstance(payload, dict) else None


async def get_or_build_timeline(db, uid: str) -> dict:
    """The persisted timeline, built lazily the first time it's asked for
    (then cached on the ``career`` page) — so a plain ``GET`` never silently
    returns "nothing" for a user who simply hasn't triggered a self-dive or
    refresh yet. Always carries ``linkedin_url`` (``""`` if none on file) so
    the client can offer "Add your LinkedIn" precisely when there is none."""
    payload = _read_payload(db, uid)
    if payload is None:
        payload = await extract(db, uid)
    out = dict(payload)
    out["linkedin_url"] = get_linkedin_url(db, uid)
    return out


# --- chat-editable, one entry at a time ---------------------------------


def _entries_or_none(db, uid: str) -> tuple[dict, list[dict]] | None:
    payload = _read_payload(db, uid)
    if payload is None:
        return None
    return payload, list(payload.get("entries") or [])


def edit_entry(db, uid: str, entry_id: str, changes: dict) -> str:
    """Apply a user-directed correction ("that's wrong, I left in 2023") to
    one timeline entry — org / title_or_degree / start / end. Persists
    immediately, same as every other Your Story edit; no separate accept
    step. Called by ``skills/story_edit.py``'s ``edit_career_timeline_entry``
    tool."""
    entry_id = (entry_id or "").strip()
    if not entry_id:
        return "no timeline entry is in focus"
    found_pair = _entries_or_none(db, uid)
    if found_pair is None:
        return "there's no timeline yet"
    payload, entries = found_pair
    hit = False
    for e in entries:
        if isinstance(e, dict) and e.get("id") == entry_id:
            for field in ("org", "title_or_degree", "start", "end"):
                if changes.get(field) is not None:
                    e[field] = str(changes[field]).strip()
            hit = True
            break
    if not hit:
        return "couldn't find that timeline entry"
    payload = dict(payload)
    payload["entries"] = entries
    story._pages_col(db, uid).document(CAREER_PAGE_ID).set(
        {FIELD_TIMELINE: payload}, merge=True
    )
    return "updated that timeline entry"


def delete_entry(db, uid: str, entry_id: str) -> str:
    """Remove one timeline entry entirely. Re-applies the confidence gate
    afterward so an emptied/thinned timeline correctly falls back to prose."""
    entry_id = (entry_id or "").strip()
    if not entry_id:
        return "no timeline entry is in focus"
    found_pair = _entries_or_none(db, uid)
    if found_pair is None:
        return "there's no timeline yet"
    payload, entries = found_pair
    kept = [e for e in entries if not (isinstance(e, dict) and e.get("id") == entry_id)]
    if len(kept) == len(entries):
        return "couldn't find that timeline entry"
    payload = dict(payload)
    payload["entries"] = kept
    payload["show_timeline"] = _decent(
        str(payload.get("overall_confidence") or "none"), kept
    )
    story._pages_col(db, uid).document(CAREER_PAGE_ID).set(
        {FIELD_TIMELINE: payload}, merge=True
    )
    return "removed that timeline entry"
