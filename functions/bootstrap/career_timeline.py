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
    try:
        import supplemental
        supplemental.record_supplemental(
            db, uid, "career", "LinkedIn profile", url, status="answered"
        )
    except Exception:  # noqa: BLE001
        pass
    return url
