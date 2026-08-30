"""Wiki query — compile the user's wiki pages into the system prompt
(ARCHITECTURE.md §2.3 Query, §2.8 step 4, §13.5 layer 3).

The AI read path is every page's ``ai_body``, unfiltered (§2.1) — ``ai_only``
included; that tier only means "never shown to a client", not "hidden from
Ayma". Step 24 compiles all of a user's pages, bounded by a character budget;
relevance ranking / retrieval can layer on later.
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.wiki")

# Rough ceiling on the wiki block so a large wiki can't crowd out the rest of
# the prompt. Pages are added whole until the budget is spent.
_MAX_CHARS = 12000


def read_wiki_context(db, uid: str, max_chars: int = _MAX_CHARS) -> str:
    """Return the wiki block for ``uid``'s system prompt, or ``""`` if the user
    has no pages yet."""
    if not uid:
        return ""
    try:
        snaps = list(
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .stream()
        )
    except Exception:  # noqa: BLE001 - a wiki read failure must not break chat
        logger.exception("wiki read failed for %s", uid)
        return ""

    pages = []
    for snap in snaps:
        data = snap.to_dict() or {}
        body = (data.get("ai_body") or "").strip()
        if body:
            pages.append((data.get("page_type") or "misc", snap.id, body))
    if not pages:
        return ""

    pages.sort(key=lambda p: (p[0], p[1]))
    out = [
        "What you already know about this person, from previous conversations "
        "(your compiled notes — do not read them back verbatim, just talk like "
        "someone who remembers):"
    ]
    used = 0
    for page_type, page_id, body in pages:
        block = f"\n### {page_type} — {page_id}\n{body}"
        if used + len(block) > max_chars:
            break
        out.append(block)
        used += len(block)
    return "\n".join(out)
