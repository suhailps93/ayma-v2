"""Wiki query — compile the user's wiki pages into the system prompt
(ARCHITECTURE.md §2.3 Query, §2.8 step 4, §13.5 layer 3).

The AI read path is every page's ``ai_body``, unfiltered (§2.1) — ``ai_only``
included; that tier only means "never shown to a client", not "hidden from
Ayma". Step 24 compiles all of a user's pages, bounded by a character budget;
relevance ranking / retrieval can layer on later.
"""

from __future__ import annotations

import logging
import re

logger = logging.getLogger("ayma.wiki")

# Rough ceiling on the wiki block so a large wiki can't crowd out the rest of
# the prompt. Pages are added whole until the budget is spent.
_MAX_CHARS = 12000

# Budget for one `recall` tool result (context_opt Phase 3) — a targeted
# slice, not the whole wiki back again.
_RECALL_MAX_CHARS = 3000


def read_wiki_context(
    db,
    uid: str,
    max_chars: int = _MAX_CHARS,
    exclude_page_types: frozenset[str] | None = None,
    include_page_types: frozenset[str] | None = None,
) -> str:
    """Return the wiki block for ``uid``'s system prompt, or ``""`` if the user
    has no pages yet.

    ``exclude_page_types`` drops whole page types from the block — for a
    caller that cares about the user's stated/inferred facts, not Ayma's own
    meta-pages about the *session* (``interactions``, ``steering``). Default
    ``None`` keeps every page, unfiltered, for the main chat-context use.

    ``include_page_types`` keeps ONLY the listed page types (context_opt's
    level-2 wiki trim / the level-2+ core persona card) — ``None`` keeps
    everything, exactly as before. Both filters compose; exclude wins on
    overlap.
    """
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
        page_type = data.get("page_type") or "misc"
        if exclude_page_types and page_type in exclude_page_types:
            continue
        if include_page_types is not None and page_type not in include_page_types:
            continue
        body = (data.get("ai_body") or "").strip()
        if body:
            pages.append((page_type, snap.id, body))
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


# --- recall(topic) — on-demand wiki retrieval (context_opt Phase 3) ----------

_RECALL_WORD_RE = re.compile(r"[a-z0-9]{3,}")

# Words too generic to score on — they'd match every page.
_RECALL_STOPWORDS = frozenset(
    "the and for with what who how does did about their they them she her his "
    "him you your this that from have has was were are can tell know like "
    "want said says user ayma".split()
)


def _recall_terms(topic: str) -> list[str]:
    return [
        w
        for w in _RECALL_WORD_RE.findall((topic or "").lower())
        if w not in _RECALL_STOPWORDS
    ]


def recall_snippets(
    db, uid: str, topic: str, max_chars: int = _RECALL_MAX_CHARS
) -> str:
    """Targeted wiki retrieval backing the ``recall(topic)`` tool (context_opt
    Phase 3): score every page by keyword overlap with ``topic`` (terms in the
    page type, page id, or ``ai_body``) and return the best-matching pages'
    bodies up to ``max_chars``. Plain keyword scoring, no LLM/embedding call —
    the point of recall is to be far cheaper than shipping the whole wiki
    every turn. Returns a clear "nothing on that" line (never raises) so the
    model gets honest feedback instead of a silent empty string."""
    terms = _recall_terms(topic)
    if not uid or not terms:
        return "No notes found on that topic."
    try:
        snaps = list(
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .stream()
        )
    except Exception:  # noqa: BLE001 - a recall failure must not break the turn
        logger.exception("wiki recall read failed for %s", uid)
        return "Could not check the notes right now."

    scored: list[tuple[int, str, str, str]] = []
    for snap in snaps:
        data = snap.to_dict() or {}
        body = (data.get("ai_body") or "").strip()
        if not body:
            continue
        page_type = data.get("page_type") or "misc"
        haystack = f"{page_type} {snap.id} {body}".lower()
        score = sum(haystack.count(t) for t in terms)
        if score > 0:
            scored.append((score, page_type, snap.id, body))
    if not scored:
        return "No notes found on that topic."

    scored.sort(key=lambda p: (-p[0], p[1], p[2]))
    out = ["From your notes on this person:"]
    used = 0
    for _score, page_type, page_id, body in scored:
        block = f"\n### {page_type} — {page_id}\n{body}"
        if used + len(block) > max_chars:
            if used == 0:  # one huge page — return a truncated slice, not nothing
                out.append(block[:max_chars])
            break
        out.append(block)
        used += len(block)
    return "\n".join(out)
