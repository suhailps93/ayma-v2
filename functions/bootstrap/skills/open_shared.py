"""``open_shared_report`` — pull a report (or a human DM chat) the user
shared into this chat.

Send-to-Ayma used to ship (or, for web research and Appearance, silently
drop) a shared report's contents with the user's message. The reference
pattern (founder, 2026-11-09: "point to the link or reference to the
report and Ayma pull it using a tool call") replaces that: the chat turn
carries only the reference — the share kind + the report id the share kit
already had (``shared_kind`` / ``shared_ref_id`` / ``shared_subject_uid``
on the chat request) — and Ayma opens the exact record herself with this
tool before answering about it, the agent-side equivalent of tapping the
card.

The reference is bound server-side (``main._prepare_chat`` →
``skills.make_session_tool_fns``'s ``shared_ctx``), never taken from the
model, so the tool can only ever open the one report the user actually
shared in this conversation. The fetch goes through
:func:`report_hub.get_report` — the same reader behind
``GET /report/{type}/{id}`` — so the access rules are exactly the app's:
owner-only report types (Appearance, private Story, match) resolve only
for their owner / a match participant, and a report the caller may not
see, or one that no longer exists, comes back as an honest failure the
model must relay instead of answering from other context.

A ``conversation`` share carries a DM thread id (not a report id) and is
pulled instead through :func:`fetch_shared_conversation_text`, which reads
the thread's recent messages — participant-guarded, so a thread the caller
is not in never resolves — and renders them the same way ``read_dm_thread``
does.

Text chat only: a staged share card is a composer affordance, and voice
already has the live screen mirror for the page the user is looking at.
"""

from __future__ import annotations

import logging
from typing import Callable

from ._base import Skill

logger = logging.getLogger(__name__)

# Share-kit kind -> report_hub report type. ``profile`` is absent on
# purpose: profile shares stay on the viewing-briefing path (founder
# confirmed working, 2026-11-09) and never produce this tool.
_KIND_TO_REPORT_TYPE = {
    "deep_dive": "deep_dive",
    "appearance": "appearance",
    "match": "match",
    "story": "story_private",
}

# A pulled report is context, not a document dump: enough for the model
# to answer real questions about it, bounded like every other context
# block in the prompt.
_MAX_CHARS = 4000

_DECLARATION = {
    "name": "open_shared_report",
    "description": (
        "Open the report or chat the user shared with you in this "
        "conversation (the card in the chat — a web research report, an "
        "Appearance report, a match report, their Story, or their DM chat "
        "with another person). Call this FIRST, before answering anything "
        "about the shared item: it returns the actual contents / messages. "
        "If it says it could not be opened, tell the user plainly that you "
        "couldn't open what they shared — never answer about it from other "
        "profiles, other reports, or earlier conversation instead."
    ),
    "parameters": {"type": "object", "properties": {}},
}

_HONEST_FAILURE = (
    "error: I couldn't open that report — tell the user plainly that you "
    "couldn't open what they shared, and do not answer about it from "
    "other context."
)

_CONVO_HONEST_FAILURE = (
    "error: I couldn't open that chat — tell the user plainly that you "
    "couldn't open the conversation they shared, and do not answer about "
    "it from another conversation or from guesswork."
)


def fetch_shared_conversation_text(
    db, uid: str, thread_id: str, subject_name: str = ""
) -> str:
    """The shared DM thread's recent messages for caller ``uid``, or an honest
    failure string. The caller must be a participant of the thread (the same
    rule the DM screen enforces) — a thread id they are not in never resolves.
    The messages are pulled by reference (the thread id the share carried),
    never shipped inline (founder 2026-11-09)."""
    from . import read_dm_thread

    tid = (thread_id or "").strip()
    if not tid:
        return _CONVO_HONEST_FAILURE
    # Access guard: only a participant may read the thread.
    try:
        doc = db.collection("dm_threads").document(tid).get()
        data = (doc.to_dict() if doc.exists else None) or {}
    except Exception:  # noqa: BLE001
        logger.exception("open_shared_report: dm thread read failed for %s", tid)
        return _CONVO_HONEST_FAILURE
    if uid not in (data.get("participants") or []):
        return _CONVO_HONEST_FAILURE
    label = (subject_name or "").strip() or "them"
    text = read_dm_thread.render_thread_messages(db, uid, tid, label)
    if text is None:
        return _CONVO_HONEST_FAILURE
    return text


def _block_text(block: dict) -> str:
    """One report block as a plain-text line (``""`` for blocks with no
    text worth handing the model — bare photos and photo grids)."""
    btype = block.get("type")
    if btype in ("text", "fact", "section_head"):
        return str(block.get("text") or "").strip()
    if btype in ("attribute", "stat"):
        label = str(block.get("label") or "").strip()
        value = block.get("value")
        if value is None or value == "":
            return ""
        if isinstance(value, (dict, list)):
            import json

            value = json.dumps(value, ensure_ascii=False)
        return f"{label}: {value}" if label else str(value)
    if btype == "link":
        label = str(block.get("label") or "").strip()
        url = str(block.get("url") or "").strip()
        if not url:
            return ""
        return f"{label}: {url}" if label else url
    if btype == "photo":
        caption = str(block.get("caption") or "").strip()
        return f"[photo] {caption}" if caption else ""
    return ""


def render_report_text(report: dict) -> str:
    """A block report (``report_hub.get_report``'s ``{title, sections}``)
    as the plain text the model reads — title, section headings, and each
    block's text, capped at :data:`_MAX_CHARS`."""
    lines: list[str] = []
    title = str(report.get("title") or "").strip()
    if title:
        lines.append(title)
    for section in report.get("sections") or []:
        heading = str(section.get("heading") or "").strip()
        body = [
            text
            for block in section.get("blocks") or []
            if (text := _block_text(block))
        ]
        if not body:
            continue
        if heading:
            lines.append(f"\n## {heading}")
        lines.extend(body)
    out = "\n".join(lines).strip()
    if len(out) > _MAX_CHARS:
        out = out[:_MAX_CHARS].rstrip() + "\n[report truncated]"
    return out


def fetch_shared_report_text(
    db,
    uid: str,
    *,
    kind: str,
    report_id: str,
    subject_uid: str,
    subject_name: str = "",
    version: str = "",
) -> str:
    """The shared report's (or chat's) text for caller ``uid``, or an honest
    failure string. The one fetch path — the tool below and the tests both go
    through here."""
    # A human chat (`conversation`) is pulled by its DM thread id, not from
    # report_hub — the share carried the thread id in ``report_id``.
    if (kind or "").strip() == "conversation":
        return fetch_shared_conversation_text(db, uid, report_id, subject_name)

    import report_hub

    report_type = _KIND_TO_REPORT_TYPE.get((kind or "").strip())
    if report_type is None:
        return _HONEST_FAILURE
    # Story and Appearance ids ARE the subject uid (the share kit's refId
    # for Appearance is the uid; Story carries no refId at all) — the
    # generic rule "refId, else the subject uid" covers every kind.
    rid = (report_id or "").strip() or (subject_uid or "").strip()
    if not rid:
        return _HONEST_FAILURE
    try:
        report = report_hub.get_report(db, report_type, rid, uid)
    except (KeyError, PermissionError, ValueError):
        return _HONEST_FAILURE
    except Exception:  # noqa: BLE001 - a read failure is a miss, said honestly
        logger.exception(
            "open_shared_report: fetch failed for %s/%s", report_type, rid
        )
        return _HONEST_FAILURE
    # Appearance is one live record per user, replaced wholesale by every
    # re-run — so the share reference carries the run's version stamp
    # (the report's ``created_at``, captured on the page the user opened)
    # and a mismatch means the exact run they shared is gone. Fail
    # honestly rather than answering about a different run (founder,
    # 2026-11-09: resolve by the record he opened, not by "latest").
    version = (version or "").strip()
    if version and report_type == "appearance":
        current = str((report.get("meta") or {}).get("created_at") or "")
        if current != version:
            return (
                "error: the Appearance report the user shared has been "
                "re-run since they shared it, so that exact report is no "
                "longer there — tell the user plainly that you couldn't "
                "open the report they shared and ask them to share it "
                "again; do not answer about a different run."
            )
    text = render_report_text(report)
    return text or _HONEST_FAILURE


def _bind(
    db,
    uid: str,
    *,
    kind: str = "",
    report_id: str = "",
    subject_uid: str = "",
    subject_name: str = "",
    version: str = "",
) -> Callable[..., str]:
    def open_shared_report() -> str:
        return fetch_shared_report_text(
            db,
            uid,
            kind=kind,
            report_id=report_id,
            subject_uid=subject_uid,
            subject_name=subject_name,
            version=version,
        )

    return open_shared_report


SKILL = Skill(declaration=_DECLARATION, bind=_bind)
