"""The user's own LinkedIn URL — given with their consent, never scraped.

Stored on the profile doc (``schema.PF_LINKEDIN_URL``). A future self deep-dive
hands it straight to Gemini's ``url_context`` tool (see :func:`deep_dive.run`)
instead of asking again; nothing here scrapes LinkedIn or calls an unofficial
API — it only ever reads a user-supplied URL.

The legacy structured career-timeline subsystem that also lived here (Gemini
extraction persisted onto the ``career`` wiki page) was removed Nov 16 2026: it
rendered the same facts the graph Career section already shows and its lazy
``.set(merge=True)`` kept recreating the Phase-7-deleted ``wiki_pages/career``
doc. Career now lives only in the graph Career section. This module keeps its
name because ``deep_dive`` and ``skills/story_manage`` import
``career_timeline.get_linkedin_url`` / ``set_linkedin_url``.
"""

from __future__ import annotations

import re

import schema

# --- LinkedIn URL: user-given, their own consent, never scraped -------------

# Deliberately permissive about the exact path (a personal profile is
# `/in/...`, but accept any linkedin.com URL rather than second-guessing the
# user) — the only thing enforced here is that it's actually a LinkedIn link.
_LINKEDIN_RE = re.compile(r"^https?://([\w-]+\.)?linkedin\.com/", re.IGNORECASE)


def is_linkedin_url(url: str) -> bool:
    return bool(_LINKEDIN_RE.match((url or "").strip()))


# Node id of the Career LinkedIn button in the Node-Visualiser tree (stable so
# a re-fetch keys onto the same node). The Career "special visualiser" is just
# the Career graph section + this public LinkedIn link node on top (NOTE 250 §3).
LINKEDIN_NODE_ID = "career.linkedin"


def linkedin_link_node(db, uid: str) -> dict | None:
    """A `link` node (Contract 1 — the P0 link kind) for ``uid``'s LinkedIn, or
    ``None`` when none is on file. Injected at the top of the Career section of
    the story / public-profile tree so the Career visualiser renders the public
    LinkedIn button. Public: a LinkedIn URL is public professional info."""
    url = get_linkedin_url(db, uid)
    if not url:
        return None
    return {
        "id": LINKEDIN_NODE_ID,
        "section": "career",
        "label": "LinkedIn",
        "text": "LinkedIn",
        "answer_type": "link",
        "link_url": url,
        "link_platform": "linkedin",
        "level": 1,
        "visibility": "public",
        "subtree_visibility": "public",
        "editable": False,
    }


def get_linkedin_url(db, uid: str) -> str:
    """The user's own LinkedIn URL, if they've given Ayma one. Best-effort —
    a read failure reads as "none on file", never an error."""
    if not uid:
        return ""
    # 1. Profile document
    try:
        data = schema.profile_doc(db, uid).get().to_dict() or {}
        url = str(data.get(schema.PF_LINKEDIN_URL) or "").strip()
        if url and is_linkedin_url(url):
            return url
    except Exception:  # noqa: BLE001
        pass

    # 2. User document fallback
    try:
        u_data = schema.user_doc(db, uid).get().to_dict() or {}
        url = str(u_data.get(schema.PF_LINKEDIN_URL) or u_data.get("linkedin") or "").strip()
        if url and is_linkedin_url(url):
            try:
                schema.profile_doc(db, uid).set({schema.PF_LINKEDIN_URL: url}, merge=True)
            except Exception:  # noqa: BLE001
                pass
            return url
    except Exception:  # noqa: BLE001
        pass

    # 3. Supplemental collection fallback (volunteered in chat, e.g. demo-test1)
    try:
        import supplemental
        supp = supplemental.read_supplemental(db, uid)
        for entry in supp:
            val = str(entry.get("value") or "").strip()
            topic = str(entry.get("topic") or "").lower()
            entry_id = str(entry.get("id") or "").lower()
            if is_linkedin_url(val) or "linkedin" in topic or "linkedin" in entry_id:
                if is_linkedin_url(val):
                    url = val
                else:
                    m = _LINKEDIN_RE.search(val)
                    url = m.group(0).rstrip(".,;") if m else ""
                if url and is_linkedin_url(url):
                    try:
                        schema.profile_doc(db, uid).set({schema.PF_LINKEDIN_URL: url}, merge=True)
                    except Exception:  # noqa: BLE001
                        pass
                    return url
    except Exception:  # noqa: BLE001
        pass

    return ""


def set_linkedin_url(db, uid: str, url: str | None) -> str:
    """Store the user's own LinkedIn profile URL, given with their explicit
    consent, so a future self deep-dive can hand it straight to Gemini's
    ``url_context`` tool (see :func:`deep_dive.run`) instead of asking again.
    This is the ONLY LinkedIn mechanism in this app: no scraper, no
    unofficial API call — just a user-supplied URL read by a tool Gemini
    already has attached to the research call. Raises ``ValueError`` for
    anything that isn't plausibly a linkedin.com link.

    A present LinkedIn URL can NEVER be overwritten with None, empty, or an
    invalid URL (NOTE 250 Leg 3 data protection) — if a valid URL is already on
    file, an empty/None update preserves the existing URL."""
    cleaned = (url or "").strip()
    if not is_linkedin_url(cleaned):
        existing = get_linkedin_url(db, uid)
        if existing:
            return existing
        raise ValueError("that doesn't look like a linkedin.com URL")
    schema.profile_doc(db, uid).set({schema.PF_LINKEDIN_URL: cleaned}, merge=True)
    try:
        schema.user_doc(db, uid).set({schema.PF_LINKEDIN_URL: cleaned}, merge=True)
    except Exception:  # noqa: BLE001
        pass
    try:
        import supplemental

        supplemental.record_supplemental(
            db, uid, "career", "LinkedIn profile", cleaned, status="answered"
        )
    except Exception:  # noqa: BLE001
        pass
    return cleaned
