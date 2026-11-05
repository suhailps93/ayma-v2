"""Wiki lint (ARCHITECTURE.md §2.3 Lint, §2.8 step 6).

A scheduled pass (`POST /cron/lint`) that scans each user's `wiki_pages` for
contradictions, stale claims, orphans and missing links, and writes
`lint_flags` onto the affected page for admin review. It never edits `ai_body`
and never resolves anything — flags are advisory.

`lint_flags` is recomputed whole each run: a page that comes back clean has its
flags cleared.

``lint_all`` (the cron sweep) is DISABLED (founder rule 2026-11-04 — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 7): the two-phase submit/poll ran on
the Vertex Batch API, which needs the direct-Google path, and the LiveKit
gateway has no batch tier. Each ``/cron/lint`` tick reports
``{"status": "disabled", ...}`` and clears any stale pending-batch state.
``lint_user`` (a single user, synchronous, via the LiveKit-routed
``gemini.generate_json``) still works and is used directly by tests and any
future one-off/manual lint.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.wiki")

# Where the two-phase sweep parks its "job submitted, not yet finalized"
# state between cron ticks. One doc — only one lint batch is ever in flight.
_STATE_COLLECTION = "system"
_STATE_DOC = "wiki_lint_batch"

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


def _flags_from_result(pages: list[dict], result: object) -> dict[str, list[dict]]:
    """The model's ``{"flags": [...]}`` result -> ``{page_id: [flag, ...]}``,
    dropping anything that names a page/type this user doesn't actually
    have."""
    raw = (result or {}).get("flags", []) if isinstance(result, dict) else []
    valid_ids = {p["page_id"] for p in pages}
    flags_by_page: dict[str, list[dict]] = {}
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
    return flags_by_page


def _write_flags(db, uid: str, pages: list[dict], flags_by_page: dict) -> int:
    """Recompute ``lint_flags`` whole for every one of ``uid``'s pages (a
    clean page's flags are cleared) and feed any contradiction into the
    user's trust flags (§5.5). Returns the count of pages left flagged."""
    col = db.collection("users").document(uid).collection("wiki_pages")
    flagged = 0
    for p in pages:
        new_flags = flags_by_page.get(p["page_id"], [])
        col.document(p["page_id"]).set(
            {"lint_flags": new_flags}, merge=True
        )
        if new_flags:
            flagged += 1

    import trust_flags

    trust_flags.sync_self_contradictions(
        db, uid,
        [
            f["detail"]
            for page_flags in flags_by_page.values()
            for f in page_flags
            if f["type"] == "contradiction"
        ],
    )
    return flagged


async def lint_user(db, uid: str) -> int:
    """Lint one user's wiki right now, synchronously. Returns the number of
    pages that ended up flagged. Used by tests and any future one-off/manual
    lint; the scheduled sweep (``lint_all``) is disabled — see the module
    docstring."""
    pages = _read_pages(db, uid)
    if len(pages) < 2:
        # Nothing to cross-check; still clear any stale flags below.
        flags_by_page: dict[str, list] = {}
    else:
        result = await gemini.generate_json(
            _pages_block(pages),
            system_prompt=load_lint_prompt(),
            response_schema=_RESPONSE_SCHEMA,
            uid=uid,
            feature="wiki",
            enforce_cap=False,
        )
        flags_by_page = _flags_from_result(pages, result)
    return _write_flags(db, uid, pages, flags_by_page)


def _state_ref(db):
    return db.collection(_STATE_COLLECTION).document(_STATE_DOC)


def _load_pending(db) -> dict | None:
    snap = _state_ref(db).get()
    return snap.to_dict() if snap.exists else None


async def lint_all(db, limit: int | None = None) -> dict:
    """The scheduled sweep — DISABLED (see the module docstring). Reports
    ``disabled`` instead of submitting a Vertex batch, and clears any stale
    pending-batch state left from before the kill so no tick ever polls
    Google again. ``limit`` is kept so the cron call site is unchanged."""
    state = await asyncio.to_thread(_load_pending, db)
    if state:
        try:
            await asyncio.to_thread(_state_ref(db).delete)
        except Exception:  # noqa: BLE001 - state cleanup is best-effort
            logger.warning("wiki lint: stale batch state cleanup failed")
        return {
            "status": "disabled",
            "job_name": state.get("job_name", ""),
            "reason": "batch_disabled_direct_google_killed",
        }
    return {"status": "disabled", "reason": "batch_disabled_direct_google_killed"}
