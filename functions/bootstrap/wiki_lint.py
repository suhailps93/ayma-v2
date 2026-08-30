"""Wiki lint (ARCHITECTURE.md §2.3 Lint, §2.8 step 6).

A scheduled pass (`POST /cron/lint`) that scans each user's `wiki_pages` for
contradictions, stale claims, orphans and missing links, and writes
`lint_flags` onto the affected page for admin review. It never edits `ai_body`
and never resolves anything — flags are advisory.

`lint_flags` is recomputed whole each run: a page that comes back clean has its
flags cleared.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.wiki")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "wiki_lint.md"

_FLAG_TYPES = {"contradiction", "stale", "orphan", "missing_link"}

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "flags": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "page_id": {"type": "string"},
                    "type": {"type": "string"},
                    "detail": {"type": "string"},
                },
                "required": ["page_id", "type", "detail"],
            },
        }
    },
    "required": ["flags"],
}


@lru_cache(maxsize=1)
def load_lint_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _pages_block(pages: list[dict]) -> str:
    out = []
    for p in pages:
        out.append(
            f"--- page_id: {p['page_id']} (type: {p.get('page_type', '?')}, "
            f"links: {p.get('links') or []}) ---\n{p.get('ai_body', '').strip()}"
        )
    return "\n\n".join(out)


def _read_pages(db, uid: str) -> list[dict]:
    col = (
        db.collection("users").document(uid).collection("wiki_pages")
    )
    pages = []
    for snap in col.stream():
        data = snap.to_dict() or {}
        if (data.get("ai_body") or "").strip():
            pages.append(
                {
                    "page_id": snap.id,
                    "page_type": data.get("page_type"),
                    "ai_body": data.get("ai_body", ""),
                    "links": data.get("links") or [],
                }
            )
    return pages


async def lint_user(db, uid: str) -> int:
    """Lint one user's wiki. Returns the number of pages that ended up flagged."""
    pages = _read_pages(db, uid)
    if len(pages) < 2:
        # Nothing to cross-check; still clear any stale flags below.
        flags_by_page: dict[str, list] = {}
    else:
        result = await gemini.generate_json(
            _pages_block(pages),
            system_prompt=load_lint_prompt(),
            response_schema=_RESPONSE_SCHEMA,
        )
        raw = (result or {}).get("flags", []) if isinstance(result, dict) else []
        valid_ids = {p["page_id"] for p in pages}
        flags_by_page = {}
        for f in raw:
            if not isinstance(f, dict):
                continue
            pid = str(f.get("page_id", ""))
            ftype = f.get("type")
            detail = str(f.get("detail", "")).strip()
            if pid not in valid_ids or ftype not in _FLAG_TYPES or not detail:
                continue
            flags_by_page.setdefault(pid, []).append(
                {
                    "type": ftype,
                    "detail": detail,
                    # a real datetime, not SERVER_TIMESTAMP — the sentinel is
                    # rejected inside an array element by Firestore.
                    "flagged_at": datetime.now(timezone.utc),
                }
            )

    col = db.collection("users").document(uid).collection("wiki_pages")
    flagged = 0
    for p in pages:
        new_flags = flags_by_page.get(p["page_id"], [])
        col.document(p["page_id"]).set(
            {"lint_flags": new_flags}, merge=True
        )
        if new_flags:
            flagged += 1
    return flagged


async def lint_all(db, limit: int | None = None) -> dict:
    """Lint every user (optionally capped). Returns a small summary."""
    users = db.collection("users")
    query = users.limit(limit) if limit else users
    checked = 0
    flagged_pages = 0
    for snap in query.stream():
        checked += 1
        try:
            flagged_pages += await lint_user(db, snap.id)
        except Exception:  # noqa: BLE001 - one bad user must not stop the sweep
            logger.exception("lint failed for user %s", snap.id)
    return {"users_checked": checked, "pages_flagged": flagged_pages}
