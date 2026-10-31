"""Server-side implementations of the Ayma MCP tools.

Every function here assumes the connected agent is **untrusted**: the client's
model decides *what* to do, but each tool re-enforces, server-side, exactly the
safety gates the in-app path enforces — scope, the 18+ age gate, moderation,
no-PII and per-user data scoping — because the token only proves *which user*
asked, never that the request is safe.

ZERO AYMA LLM SPEND (the headline constraint): no tool here calls Ayma's chat /
reasoning model. Reads, searches and gated writes only. The one model call is
``dm_moderation.moderate`` on an outgoing DM — a safety classifier run with
``enforce_cap=False`` and not attributed to the user, the same cents-level
moderation the in-app send already runs. Nothing generates story/bio/DM/persona
text: that is the *client* model's job, and the generated text arrives here as
an argument to a validated write.

These are FastAPI-free so they unit-test against the in-memory Firestore fake.
``mcp_server.py`` wraps each one as an MCP tool, resolving the ``Principal``
from the request's Bearer token first.
"""

from __future__ import annotations

import logging

import age_gate
import dm_moderation
import dm_ops
import mcp_oauth
import practice_core
import profile_manual
import public_profile
import schema
import story
import token_ledger
from matching_schema import MATCHES_COLLECTION
from matching_skill import read_match
from mcp_oauth import Principal
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.mcp.tools")

_MAX_DM_CHARS = 4000
_DEFAULT_THREAD_LIMIT = 30
_MAX_THREAD_LIMIT = 100

# Structured identity fields an agent may set, mapped to the shared, validated
# `set_profile_field` skill (which enforces the 18+ floor on `birthdate`).
_STRUCTURED_FIELDS = ("name", "gender", "interested_in", "location", "phone", "birthdate")
# The free-text public-profile narrative, written through the same fail-closed
# moderation + no-PII path the in-app editor uses.
_PUBLIC_TEXT_KEYS = ("public_text", "bio", "story")


class McpToolError(Exception):
    """A tool refusal the client should see. ``code`` is a short machine token
    (``forbidden_scope`` / ``age`` / ``moderation`` / ``contact_info`` /
    ``not_found`` / ``blocked`` / ``invalid``)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# ---- gate helpers -------------------------------------------------------- #


def _require_scope(principal: Principal, scope: str) -> None:
    if not principal.has_scope(scope):
        raise McpToolError(
            "forbidden_scope",
            f"This connection was not granted the '{scope}' scope.",
        )


def _storage_bucket():
    from firebase_admin import storage

    return storage.bucket()


def _require_age(db, uid: str, *, require_birthdate: bool) -> None:
    """Run the authoritative 18+ gate; translate its refusal into an
    :class:`McpToolError`. ``age_gate.enforce`` also closes an under-18 account
    it discovers — the same behaviour as the in-app routes."""
    try:
        age_gate.enforce(db, _storage_bucket, uid, require_birthdate=require_birthdate)
    except age_gate.AgeGateError as exc:
        raise McpToolError("age", exc.message) from exc


def _meter(uid: str, tool: str) -> None:
    token_ledger.record_mcp_tool_call(uid, tool)


# ---- profile ------------------------------------------------------------- #


def get_profile(db, principal: Principal) -> dict:
    """The caller's own structured profile + their private story narrative."""
    _require_scope(principal, mcp_oauth.SCOPE_PROFILE_READ)
    uid = principal.uid
    _require_age(db, uid, require_birthdate=False)
    profile = schema.profile_doc(db, uid).get().to_dict() or {}
    structured = {
        "name": profile.get(schema.PF_NAME),
        "birthdate": _isoish(profile.get(schema.PF_BIRTHDATE)),
        "gender": profile.get(schema.PF_GENDER),
        "interested_in": profile.get(schema.PF_INTERESTED_IN),
        "location": profile.get(schema.PF_LOCATION),
        "phone": profile.get("phone"),
        "paused": bool(profile.get(schema.PF_PAUSED)),
        "photo_count": len(profile.get(schema.PF_PHOTOS) or []),
    }
    try:
        sections = (story.get_story(db, uid) or {}).get("sections", [])
    except Exception:  # noqa: BLE001 - story read must not break the tool
        logger.exception("mcp get_profile story read failed uid=%s", uid)
        sections = []
    narrative = [
        {
            "title": s.get("title"),
            "body": s.get("body"),
            "visibility": s.get("visibility"),
            "user_edited": s.get("user_edited"),
        }
        for s in sections
        if (s.get("body") or "").strip()
    ]
    _meter(uid, "get_profile")
    return {"profile": structured, "story": narrative}


async def update_profile(db, principal: Principal, fields: dict) -> dict:
    """Apply client-supplied profile text. Structured identity fields go through
    the shared ``set_profile_field`` skill (18+ floor on birthdate); the
    free-text public narrative goes through ``profile_manual.save_text``
    (fail-closed moderation + no-PII). Returns a per-field result map."""
    _require_scope(principal, mcp_oauth.SCOPE_PROFILE_WRITE)
    uid = principal.uid
    if not isinstance(fields, dict) or not fields:
        raise McpToolError("invalid", "Pass a non-empty `fields` object.")
    _require_age(db, uid, require_birthdate=False)

    results: dict[str, str] = {}

    # Structured identity fields -> the validated skill (sync).
    structured = {k: v for k, v in fields.items() if k in _STRUCTURED_FIELDS}
    if structured:
        from skills.set_profile_field import _bind as _bind_set_field

        setter = _bind_set_field(db, uid)
        for field, value in structured.items():
            results[field] = setter(field, str(value))

    # Free-text public narrative -> the fail-closed moderation + PII path.
    text_val = next(
        (fields[k] for k in _PUBLIC_TEXT_KEYS if k in fields and fields[k] is not None),
        None,
    )
    if text_val is not None:
        current = profile_manual.get_text(db, uid)
        try:
            await profile_manual.save_text(
                db, uid, str(text_val), current.get("version", "")
            )
            results["public_text"] = "saved"
        except profile_manual.ProfileTextError as exc:
            raise McpToolError(exc.code, str(exc)) from exc

    if not results:
        raise McpToolError(
            "invalid",
            "No writable field supplied. Allowed: "
            + ", ".join(_STRUCTURED_FIELDS + ("public_text",)),
        )
    _meter(uid, "update_profile")
    return {"updated": results}


# ---- matches ------------------------------------------------------------- #


def list_matches(db, principal: Principal) -> dict:
    """The caller's scored matches (grounding data). Only the caller's own
    ``user_explanation`` is ever returned; ``ai_explanation`` never leaves the
    server."""
    _require_scope(principal, mcp_oauth.SCOPE_MATCHES_READ)
    uid = principal.uid
    _require_age(db, uid, require_birthdate=True)
    snaps = list(
        db.collection(MATCHES_COLLECTION)
        .where("uids", "array_contains", uid)
        .stream()
    )
    out: list[dict] = []
    for snap in snaps:
        d = snap.to_dict() or {}
        uids = d.get("uids") or []
        if uid not in uids:  # defensive — the query already guarantees this
            continue
        other_uid = next((u for u in uids if u != uid), None)
        if not other_uid:
            continue
        built = None
        try:
            built = public_profile.build(db, uid, other_uid)
        except Exception:  # noqa: BLE001
            built = None
        if built and built.get("blocked"):
            continue
        out.append(
            {
                "match_id": snap.id,
                "other_uid": other_uid,
                "name": (built or {}).get("name"),
                "photo": ((built or {}).get("photos") or [None])[0],
                "score": d.get("score"),
                "structured_score": d.get("structured_score"),
                "status": d.get("status"),
                "your_explanation": (d.get("user_explanation") or {}).get(uid),
                "shared": d.get("shared") or [],
                "tensions": d.get("tensions") or [],
            }
        )
    out.sort(key=lambda r: (r.get("score") or 0), reverse=True)
    _meter(uid, "list_matches")
    return {"matches": out}


def get_match(db, principal: Principal, other_uid: str) -> dict:
    """One match's compatibility detail, as grounding for the client's own
    reasoning. Reads an already-scored match only — it never triggers scoring
    (that would spend an Ayma LLM). ``ai_explanation`` is never returned."""
    _require_scope(principal, mcp_oauth.SCOPE_MATCHES_READ)
    uid = principal.uid
    if not (other_uid or "").strip():
        raise McpToolError("invalid", "Pass the other user's `other_uid`.")
    _require_age(db, uid, require_birthdate=True)
    match_id = sorted_pair_key(uid, other_uid)
    doc = read_match(db, match_id)
    if not doc:
        raise McpToolError(
            "not_found",
            "No scored match exists for this pair yet. Ask the user to run a "
            "compatibility check in the Ayma app first — the MCP server never "
            "triggers scoring (it would spend Ayma's own AI budget).",
        )
    if uid not in (doc.get("uids") or []):
        raise McpToolError("forbidden", "That match does not belong to you.")
    built = None
    try:
        built = public_profile.build(db, uid, other_uid)
    except Exception:  # noqa: BLE001
        built = None
    _meter(uid, "get_match")
    return {
        "match_id": match_id,
        "other_uid": other_uid,
        "name": (built or {}).get("name"),
        "score": doc.get("score"),
        "structured_score": doc.get("structured_score"),
        "status": doc.get("status"),
        "dimensions": doc.get("dimensions") or [],
        "shared": doc.get("shared") or [],
        "tensions": doc.get("tensions") or [],
        "missing": doc.get("missing") or [],
        "your_explanation": (doc.get("user_explanation") or {}).get(uid),
        "score_confidence": doc.get("score_confidence"),
    }


# ---- direct messages ----------------------------------------------------- #


def list_threads(db, principal: Principal) -> dict:
    """The caller's DM threads. Blocked pairs are omitted."""
    _require_scope(principal, mcp_oauth.SCOPE_DM_READ)
    uid = principal.uid
    _require_age(db, uid, require_birthdate=True)
    snaps = list(
        db.collection("dm_threads")
        .where("participants", "array_contains", uid)
        .stream()
    )
    out: list[dict] = []
    for snap in snaps:
        d = snap.to_dict() or {}
        other_uid = next((p for p in (d.get("participants") or []) if p != uid), None)
        if not other_uid:
            continue
        try:
            if dm_ops.blocked_between(db, uid, other_uid):
                continue
        except Exception:  # noqa: BLE001
            pass
        name = None
        try:
            prof = (
                schema.profile_doc(db, other_uid).get().to_dict() or {}
            )
            name = prof.get(schema.PF_NAME)
        except Exception:  # noqa: BLE001
            pass
        last = d.get("last_message_at")
        out.append(
            {
                "other_uid": other_uid,
                "name": name,
                "last_message_at": _isoish(last),
                "unread": int((d.get("unread") or {}).get(uid, 0) or 0),
            }
        )
    out.sort(key=lambda r: r.get("last_message_at") or "", reverse=True)
    _meter(uid, "list_threads")
    return {"threads": out}


def get_thread(db, principal: Principal, other_uid: str, limit: int = _DEFAULT_THREAD_LIMIT) -> dict:
    """Recent messages in the caller's thread with ``other_uid``. The thread id
    is derived from the caller's own uid, so this can only ever read the
    caller's own conversation — no cross-user read is possible."""
    _require_scope(principal, mcp_oauth.SCOPE_DM_READ)
    uid = principal.uid
    if not (other_uid or "").strip():
        raise McpToolError("invalid", "Pass the other user's `other_uid`.")
    _require_age(db, uid, require_birthdate=True)
    try:
        n = max(1, min(int(limit), _MAX_THREAD_LIMIT))
    except (TypeError, ValueError):
        n = _DEFAULT_THREAD_LIMIT
    thread_id = sorted_pair_key(uid, other_uid)
    snaps = list(
        db.collection("dm_threads")
        .document(thread_id)
        .collection("messages")
        .stream()
    )
    snaps.sort(key=lambda s: _sortable(((s.to_dict() or {}).get("created_at"))))
    rows = snaps[-n:]
    messages = []
    for snap in rows:
        m = snap.to_dict() or {}
        mtype = str(m.get("type") or "text")
        body = str(m.get("body") or "")
        if mtype != "text":
            body = {"photo": "[photo]", "voice": "[voice message]",
                    "shared_profile": "[shared a profile]"}.get(mtype, f"[{mtype}]")
        messages.append(
            {
                "from": "me" if m.get("sender_uid") == uid else "them",
                "type": mtype,
                "body": body,
                "at": _isoish(m.get("created_at")),
                "flagged": bool(m.get("moderated")),
            }
        )
    _meter(uid, "get_thread")
    return {"other_uid": other_uid, "messages": messages}


async def send_message(db, principal: Principal, other_uid: str, text: str) -> dict:
    """Send a DM the client's model composed. Stricter than the in-app send:
    because an autonomous agent is sending it, this path **fails closed** —
    contact info (email/phone) and flagged content are refused rather than sent
    and annotated. Consent = the block gate + the 18+ gate."""
    _require_scope(principal, mcp_oauth.SCOPE_DM_SEND)
    uid = principal.uid
    if not (other_uid or "").strip():
        raise McpToolError("invalid", "Pass the recipient's `other_uid`.")
    text = (text or "").strip()
    if not text:
        raise McpToolError("invalid", "Message text is empty.")
    if len(text) > _MAX_DM_CHARS:
        raise McpToolError("invalid", f"Message exceeds {_MAX_DM_CHARS} characters.")
    _require_age(db, uid, require_birthdate=True)

    # No-PII: reuse the public-profile editor's contact-info check.
    try:
        profile_manual.check_contact_info(text)
    except profile_manual.ProfileTextError as exc:
        raise McpToolError("contact_info", str(exc)) from exc

    # Moderation: fail CLOSED for the untrusted agent path.
    verdict = await dm_moderation.moderate(text)
    if verdict.get("flagged"):
        raise McpToolError(
            "moderation",
            "That message was blocked by moderation (" + (verdict.get("reason") or "policy") + ").",
        )

    try:
        message_id = dm_ops.post_message(
            db, uid, other_uid, "text", text, moderation=verdict
        )
    except PermissionError as exc:
        raise McpToolError("blocked", "You can't message this person.") from exc
    except ValueError as exc:
        raise McpToolError("invalid", str(exc)) from exc

    _meter(uid, "send_message")
    return {"ok": True, "message_id": message_id, "thread_id": sorted_pair_key(uid, other_uid)}


# ---- persona context (for client-run practice) --------------------------- #


def get_persona_context(db, principal: Principal, other_uid: str) -> dict:
    """The viewer-visible persona context for a person, so the CLIENT'S model
    can run a practice simulation itself. Built only from what the caller can
    already see (``practice_core.build_persona_context`` — the privacy
    boundary); the persona reply is NEVER generated here."""
    _require_scope(principal, mcp_oauth.SCOPE_PERSONA_READ)
    uid = principal.uid
    if not (other_uid or "").strip():
        raise McpToolError("invalid", "Pass the other user's `other_uid`.")
    _require_age(db, uid, require_birthdate=True)
    ctx = practice_core.build_persona_context(db, uid, other_uid)
    if ctx is None:
        raise McpToolError(
            "not_found",
            "No persona is available for this person (deleted, blocked, or no "
            "visible profile).",
        )
    _meter(uid, "get_persona_context")
    return {
        "other_uid": other_uid,
        "name": ctx.name,
        "age": ctx.age,
        "location": ctx.location,
        "photo_count": ctx.photo_count,
        "pages": ctx.pages,
        "persona_prompt": ctx.to_prompt_block(),
        "note": (
            "Use this context to roleplay the persona YOURSELF. The Ayma MCP "
            "server deliberately does not generate the persona's replies."
        ),
    }


# ---- small utils --------------------------------------------------------- #


def _isoish(value):
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value if isinstance(value, (str, int, float)) else None


def _sortable(value):
    """A comparable key for a created_at that might be a datetime, a string, or
    a test sentinel. Missing/odd values sort first."""
    if hasattr(value, "isoformat"):
        return (1, value.isoformat())
    if isinstance(value, str):
        return (1, value)
    return (0, "")
