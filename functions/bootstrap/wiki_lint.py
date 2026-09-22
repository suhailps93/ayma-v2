"""Wiki lint (ARCHITECTURE.md §2.3 Lint, §2.8 step 6).

A scheduled pass (`POST /cron/lint`) that scans each user's `wiki_pages` for
contradictions, stale claims, orphans and missing links, and writes
`lint_flags` onto the affected page for admin review. It never edits `ai_body`
and never resolves anything — flags are advisory.

`lint_flags` is recomputed whole each run: a page that comes back clean has its
flags cleared.

``lint_all`` (the cron sweep) runs on the Gemini Batch API — see
``gemini_batch.py`` for why: this is the ideal case for it (purely scheduled,
nobody waiting on a result, advisory-only output) at 50% of the synchronous
cost. It's a two-phase submit/poll: each `/cron/lint` tick either finalizes a
previously-submitted job that has since finished, or submits a fresh one —
never blocks the request on the job actually completing. ``lint_user`` (a
single user, synchronous) is unchanged and still used directly by tests and
any future one-off/manual lint.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import gemini
import gemini_batch

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

    from matching_schema import TRUST_FLAG_SELF_CONTRADICTION
    from trust_flags import add_trust_flag

    for page_flags in flags_by_page.values():
        for f in page_flags:
            if f["type"] == "contradiction":
                add_trust_flag(
                    db, uid, TRUST_FLAG_SELF_CONTRADICTION, f["detail"]
                )
    return flagged


async def lint_user(db, uid: str) -> int:
    """Lint one user's wiki right now, synchronously. Returns the number of
    pages that ended up flagged. Used by tests and any future one-off/manual
    lint; the scheduled sweep (``lint_all``) batches instead — see module
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
        )
        flags_by_page = _flags_from_result(pages, result)
    return _write_flags(db, uid, pages, flags_by_page)


def _state_ref(db):
    return db.collection(_STATE_COLLECTION).document(_STATE_DOC)


def _load_pending(db) -> dict | None:
    snap = _state_ref(db).get()
    return snap.to_dict() if snap.exists else None


def _submit_new(db, limit: int | None) -> dict:
    """Gather every user's wiki pages. Anyone with fewer than two pages needs
    no model call — clear their flags immediately, same as ``lint_user``
    would. Everyone else goes into one Batch job; nothing here waits for it."""
    users = db.collection("users")
    query = users.limit(limit) if limit else users

    skipped = 0
    batched_uids: list[str] = []
    items: list[str] = []
    for snap in query.stream():
        uid = snap.id
        try:
            pages = _read_pages(db, uid)
        except Exception:  # noqa: BLE001 - one bad user must not stop the sweep
            logger.exception("lint: failed to read pages for %s", uid)
            continue
        if len(pages) < 2:
            _write_flags(db, uid, pages, {})
            skipped += 1
            continue
        batched_uids.append(uid)
        items.append(_pages_block(pages))

    if not items:
        return {
            "status": "done", "users_checked": skipped,
            "pages_flagged": 0, "batched": 0,
        }

    submission = gemini_batch.submit_json_batch(
        items, load_lint_prompt(), _RESPONSE_SCHEMA, job_tag="wiki_lint",
    )
    _state_ref(db).set(
        {
            "job_name": submission.job_name,
            "dest_prefix": submission.dest_prefix,
            "uids": batched_uids,
            "count": submission.count,
            "submitted_at": datetime.now(timezone.utc),
        }
    )
    return {
        "status": "submitted", "job_name": submission.job_name,
        "users_checked": skipped, "batched": len(batched_uids),
    }


def _finalize(db, state: dict) -> dict | None:
    """Poll the pending job once. Returns the run summary once it's done
    (applying results and clearing state, whether it succeeded or hit a
    terminal failure) — or ``None`` while it's still running, in which case
    the caller reports "pending" and leaves the state doc alone for the next
    tick to try again."""
    job_name = state.get("job_name", "")
    job = gemini_batch.poll_json_batch(job_name)
    if not gemini_batch.is_batch_done(job):
        return None

    uids: list[str] = state.get("uids") or []
    if not gemini_batch.is_batch_succeeded(job):
        logger.error(
            "wiki lint batch %s ended in %s: %s", job_name, job.state, job.error,
        )
        _state_ref(db).delete()
        return {"status": "failed", "job_name": job_name, "job_state": str(job.state)}

    dest = (
        job.output_info.gcs_output_directory
        if getattr(job, "output_info", None) else None
    ) or state.get("dest_prefix", "")
    try:
        results = gemini_batch.fetch_json_batch_results(dest, expected_count=len(uids))
    except Exception:  # noqa: BLE001 - never crash the cron endpoint
        logger.exception("wiki lint: failed to read batch results for %s", job_name)
        _state_ref(db).delete()
        return {"status": "failed", "job_name": job_name, "job_state": "result_read_error"}

    checked = 0
    flagged_pages = 0
    for uid, result in zip(uids, results):
        try:
            pages = _read_pages(db, uid)
            flags_by_page = _flags_from_result(pages, result) if result is not None else {}
            flagged_pages += _write_flags(db, uid, pages, flags_by_page)
            checked += 1
        except Exception:  # noqa: BLE001 - one bad user must not stop the sweep
            logger.exception("wiki lint: failed to apply batch result for %s", uid)
    _state_ref(db).delete()
    return {"status": "done", "users_checked": checked, "pages_flagged": flagged_pages}


async def lint_all(db, limit: int | None = None) -> dict:
    """The scheduled sweep (optionally capped on a fresh submission). Each
    tick either finalizes a previously-submitted Batch job that has since
    completed, or — if nothing is pending — submits a new one. See the
    module docstring; this never blocks on a job actually finishing."""
    state = await asyncio.to_thread(_load_pending, db)
    if state:
        result = await asyncio.to_thread(_finalize, db, state)
        if result is not None:
            return result
        return {"status": "pending", "job_name": state.get("job_name", "")}
    return await asyncio.to_thread(_submit_new, db, limit)
