"""Your Story — the codebase-style editor over the user's wiki pages.

Groups the user's ``users/{uid}/wiki_pages`` (minus ``ai_only`` and
``user_hidden`` ones) into editable sections, keeps whole-story version
snapshots per side (``private`` | ``public``), and runs the highlight-to-chat
edit flow.

Two bodies live on each page:

* effective PRIVATE body = ``user_edits`` if non-empty else ``ai_body``
* PUBLIC body            = ``public_body`` (independent content)

``ai_body`` is never written here. Every field name this module needs is
defined locally — ``schema.py`` is read-only.
"""

from __future__ import annotations

import logging
import time

from firebase_admin import firestore

import gemini
import token_ledger

logger = logging.getLogger("ayma.story")

# --- Firestore field / collection names (local, not in schema.py) -----------
WIKI_PAGES = "wiki_pages"
STORY_VERSIONS = "story_versions"

F_AI_BODY = "ai_body"
F_USER_EDITS = "user_edits"
F_PUBLIC_BODY = "public_body"
F_PUBLIC_BODY_SEEDED = "public_body_seeded"
F_VISIBILITY = "visibility"
F_USER_HIDDEN = "user_hidden"
F_USER_UPDATED_AT = "user_updated_at"
F_AI_BODY_UPDATED_AT = "ai_body_updated_at"
F_PAGE_TYPE = "page_type"

VIS_PUBLIC = "public"
VIS_PRIVATE = "private"
VIS_AI_ONLY = "ai_only"

SIDE_PRIVATE = "private"
SIDE_PUBLIC = "public"
AUTHOR_USER = "user"
AUTHOR_AYMA = "ayma"

# Debounce window for back-to-back Ayma snapshots (§ data model).
SNAPSHOT_DEBOUNCE_SECONDS = 300
MAX_VERSIONS_PER_SIDE = 200

NOTE_AI_LEARNED = "learned from a conversation"


def _server_ts():
    return firestore.SERVER_TIMESTAMP


def _now_ms() -> int:
    return int(time.time() * 1000)


def humanize(page_type: str) -> str:
    """``career`` -> ``Career``; ``web_findings`` -> ``Web Findings``."""
    base = (page_type or "misc").replace("_", " ").replace("-", " ").strip()
    return base.title() if base else "Misc"


def _side(side: str) -> str:
    return SIDE_PUBLIC if side == SIDE_PUBLIC else SIDE_PRIVATE


def _pages_col(db, uid):
    return db.collection("users").document(uid).collection(WIKI_PAGES)


def _versions_col(db, uid):
    return db.collection("users").document(uid).collection(STORY_VERSIONS)


def _to_epoch(v) -> float:
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if hasattr(v, "timestamp"):
        try:
            return float(v.timestamp())
        except Exception:  # noqa: BLE001
            return 0.0
    return 0.0


def _iso(v):
    return v.isoformat() if hasattr(v, "isoformat") else None


def _effective_private(data: dict) -> str:
    ue = (data.get(F_USER_EDITS) or "").strip()
    return ue if ue else (data.get(F_AI_BODY) or "").strip()


def _editor_pages(db, uid) -> list[tuple[str, dict]]:
    """Every wiki page the editor may show: not ``ai_only``, not
    ``user_hidden``. Sorted by ``(page_type, page_id)``."""
    out: list[tuple[str, dict]] = []
    for snap in _pages_col(db, uid).stream():
        data = snap.to_dict() or {}
        if (data.get(F_VISIBILITY) or VIS_PRIVATE) == VIS_AI_ONLY:
            continue
        if data.get(F_USER_HIDDEN) is True:
            continue
        out.append((snap.id, data))
    out.sort(key=lambda t: (str(t[1].get(F_PAGE_TYPE) or "misc"), t[0]))
    return out


def _ai_updated_since_user(data: dict) -> bool:
    ai_at = data.get(F_AI_BODY_UPDATED_AT)
    if ai_at is None:
        return False
    user_at = data.get(F_USER_UPDATED_AT)
    if user_at is None:
        return True
    return _to_epoch(ai_at) > _to_epoch(user_at)


# --- snapshots -------------------------------------------------------------


def _side_versions(db, uid, side: str) -> list[tuple[str, dict]]:
    """All snapshots for ``side``, oldest first."""
    out: list[tuple[str, dict]] = []
    for snap in _versions_col(db, uid).stream():
        data = snap.to_dict() or {}
        if data.get("side") != side:
            continue
        out.append((snap.id, data))
    out.sort(key=lambda t: (int(t[1].get("created_at_ms") or 0), t[0]))
    return out


def _head_version_id(db, uid, side: str):
    vs = _side_versions(db, uid, side)
    return vs[-1][0] if vs else None


def _section_body(data: dict, side: str) -> str:
    if side == SIDE_PUBLIC:
        return (data.get(F_PUBLIC_BODY) or "").strip()
    return _effective_private(data)


def _snapshot(db, uid, side: str, author: str, note: str = "") -> str:
    sections = []
    for page_id, data in _editor_pages(db, uid):
        page_type = str(data.get(F_PAGE_TYPE) or "misc")
        sections.append(
            {
                "page_id": page_id,
                "page_type": page_type,
                "title": humanize(page_type),
                "body": _section_body(data, side),
                "visibility": data.get(F_VISIBILITY) or VIS_PRIVATE,
            }
        )
    ref = _versions_col(db, uid).document()
    ref.set(
        {
            "side": side,
            "sections": sections,
            "author": author,
            "note": note or "",
            "created_at": _server_ts(),
            "created_at_ms": _now_ms(),
        }
    )
    _prune(db, uid, side)
    return ref.id


def _prune(db, uid, side: str) -> None:
    vs = _side_versions(db, uid, side)
    excess = len(vs) - MAX_VERSIONS_PER_SIDE
    for vid, _ in vs[: max(0, excess)]:
        _versions_col(db, uid).document(vid).delete()


# --- reads ---------------------------------------------------------------


def get_story(db, uid: str, side: str) -> dict:
    side = _side(side)
    sections = []
    for page_id, data in _editor_pages(db, uid):
        page_type = str(data.get(F_PAGE_TYPE) or "misc")
        body = _section_body(data, side)
        if side == SIDE_PUBLIC:
            user_edited = bool((data.get(F_PUBLIC_BODY) or "").strip())
        else:
            user_edited = bool((data.get(F_USER_EDITS) or "").strip())
        sections.append(
            {
                "page_id": page_id,
                "page_type": page_type,
                "title": humanize(page_type),
                "body": body,
                "visibility": data.get(F_VISIBILITY) or VIS_PRIVATE,
                "user_edited": user_edited,
                "needs_seed": side == SIDE_PUBLIC and body == "",
                "ai_updated_since_user": (
                    side == SIDE_PRIVATE and _ai_updated_since_user(data)
                ),
            }
        )
    return {
        "sections": sections,
        "head_version_id": _head_version_id(db, uid, side),
    }


def list_versions(db, uid: str, side: str) -> list[dict]:
    side = _side(side)
    vs = _side_versions(db, uid, side)  # oldest first
    rows: list[dict] = []
    for i, (vid, data) in enumerate(vs):
        cur = {s["page_id"]: s for s in (data.get("sections") or [])}
        if i == 0:
            changed = sorted({s.get("page_type") for s in cur.values() if s.get("page_type")})
        else:
            prev = {s["page_id"]: s for s in (vs[i - 1][1].get("sections") or [])}
            changed_types: set[str] = set()
            for key in set(cur) | set(prev):
                a, b = prev.get(key), cur.get(key)
                if (
                    a is None
                    or b is None
                    or a.get("body") != b.get("body")
                    or a.get("visibility") != b.get("visibility")
                ):
                    t = (b or a or {}).get("page_type")
                    if t:
                        changed_types.add(t)
            changed = sorted(changed_types)
        rows.append(
            {
                "id": vid,
                "author": data.get("author") or AUTHOR_USER,
                "note": data.get("note") or "",
                "created_at": _iso(data.get("created_at")),
                "created_at_ms": int(data.get("created_at_ms") or 0),
                "changed_sections": changed,
            }
        )
    rows.reverse()  # newest first
    return rows


def get_version(db, uid: str, version_id: str) -> dict:
    snap = _versions_col(db, uid).document(version_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(version_id)
    data = snap.to_dict() or {}
    return {
        "id": version_id,
        "side": data.get("side"),
        "author": data.get("author") or AUTHOR_USER,
        "note": data.get("note") or "",
        "created_at": _iso(data.get("created_at")),
        "created_at_ms": int(data.get("created_at_ms") or 0),
        "sections": data.get("sections") or [],
    }


# --- writes ------------------------------------------------------------


def _require_page(db, uid, page_id: str) -> tuple[object, dict]:
    ref = _pages_col(db, uid).document(page_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        raise KeyError(page_id)
    return ref, (snap.to_dict() or {})


def save_section(
    db, uid: str, page_id: str, side: str, body: str, visibility=None
) -> dict:
    side = _side(side)
    ref, _data = _require_page(db, uid, page_id)
    payload = {F_USER_UPDATED_AT: _server_ts()}
    if side == SIDE_PUBLIC:
        payload[F_PUBLIC_BODY] = (body or "").strip()
        payload[F_PUBLIC_BODY_SEEDED] = True
    else:
        payload[F_USER_EDITS] = (body or "").strip()
    if visibility in (VIS_PUBLIC, VIS_PRIVATE, VIS_AI_ONLY):
        payload[F_VISIBILITY] = visibility
    ref.set(payload, merge=True)
    return {"head_version_id": _snapshot(db, uid, side, AUTHOR_USER)}


_SEED_SYS = (
    "You adapt one section of someone's private self-description into a short, "
    "share-appropriate version for their public dating profile. Keep it warm, "
    "concrete and true to the source. Drop anything sensitive, negative, "
    "medical, financial, or personally identifying that a stranger should not "
    "see. Tighten it to a few sentences. Respond as JSON "
    '{"draft": "<the public version>"}.'
)
_SEED_SCHEMA = {
    "type": "object",
    "properties": {"draft": {"type": "string"}},
    "required": ["draft"],
}


async def _seed_draft(uid: str, page_type: str, private_body: str) -> str:
    if not private_body.strip():
        return ""
    contents = (
        f"Section: {humanize(page_type)}\n\n"
        f"Private version:\n{private_body.strip()}"
    )
    result = await gemini.generate_json(
        contents,
        system_prompt=_SEED_SYS,
        response_schema=_SEED_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_WIKI,
    )
    if isinstance(result, dict):
        return str(result.get("draft") or "").strip()
    return ""


async def seed_public(db, uid: str, page_id: str) -> dict:
    ref, data = _require_page(db, uid, page_id)
    draft = await _seed_draft(
        uid, str(data.get(F_PAGE_TYPE) or "misc"), _effective_private(data)
    )
    ref.set(
        {
            F_PUBLIC_BODY: draft,
            F_PUBLIC_BODY_SEEDED: True,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    return {"draft": draft}


_EDIT_SYS = (
    "You help someone edit one section of their personal profile from a "
    "highlighted passage plus a plain-language instruction. Classify the "
    "instruction and respond as JSON with an `action`:\n"
    '- "rewrite": return {"action":"rewrite","revised_body":"<FULL revised '
    'section body>"}. Deleting the highlighted line is a rewrite with that '
    "line removed.\n"
    '- "move": the user wants this section made private or public. Return '
    '{"action":"move","target_side":"private"|"public"}.\n'
    '- "remove": the user wants the whole section gone. Return '
    '{"action":"remove"}.\n'
    "Return the entire section body for a rewrite, not just the changed part."
)
_EDIT_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["rewrite", "move", "remove"]},
        "revised_body": {"type": "string"},
        "target_side": {"type": "string", "enum": ["private", "public"]},
    },
    "required": ["action"],
}


def _edit_contents(side: str, body: str, selection: str, instruction: str) -> str:
    return (
        f"Side being edited: {side}\n\n"
        f"Full section body:\n{body}\n\n"
        f"Highlighted passage:\n{selection.strip() or '(none)'}\n\n"
        f"Instruction:\n{instruction.strip()}"
    )


async def edit_section(
    db, uid: str, page_id: str, side: str, selection: str, instruction: str
) -> dict:
    side = _side(side)
    _ref, data = _require_page(db, uid, page_id)
    body = _section_body(data, side)
    try:
        result = await gemini.generate_json(
            _edit_contents(side, body, selection, instruction),
            system_prompt=_EDIT_SYS,
            response_schema=_EDIT_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_WIKI,
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    action = ""
    if isinstance(result, dict):
        action = str(result.get("action") or "").strip().lower()

    if action == "move":
        target = str((result or {}).get("target_side") or "").strip().lower()
        if target not in (SIDE_PRIVATE, SIDE_PUBLIC):
            target = SIDE_PUBLIC if side == SIDE_PRIVATE else SIDE_PRIVATE
        return {"action": "move", "target_side": target}
    if action == "remove":
        return {"action": "remove"}

    revised = ""
    if isinstance(result, dict):
        revised = str(result.get("revised_body") or "").strip()
    return {"action": "rewrite", "revised_body": revised or body}


async def move_section(db, uid: str, page_id: str, target_side: str) -> dict:
    """Move the section a highlighted passage sits in between the private
    story and the public profile (§ addendum)."""
    target_side = _side(target_side)
    ref, data = _require_page(db, uid, page_id)
    label = humanize(str(data.get(F_PAGE_TYPE) or "misc"))

    if target_side == SIDE_PRIVATE:
        # public -> private: fold public_body into user_edits, clear public.
        public_body = (data.get(F_PUBLIC_BODY) or "").strip()
        user_edits = (data.get(F_USER_EDITS) or "").strip()
        if public_body and user_edits:
            merged = f"{user_edits}\n\n{public_body}"
        else:
            merged = user_edits or public_body
        ref.set(
            {
                F_VISIBILITY: VIS_PRIVATE,
                F_USER_EDITS: merged,
                F_PUBLIC_BODY: "",
                F_PUBLIC_BODY_SEEDED: False,
                F_USER_UPDATED_AT: _server_ts(),
            },
            merge=True,
        )
        note = f"moved {label} to private"
        head = _snapshot(db, uid, SIDE_PRIVATE, AUTHOR_USER, note)
        _snapshot(db, uid, SIDE_PUBLIC, AUTHOR_USER, note)
        return {"head_version_id": head}

    # private -> public: seed public_body from the effective private body,
    # leave the private body as-is.
    draft = await _seed_draft(
        uid, str(data.get(F_PAGE_TYPE) or "misc"), _effective_private(data)
    )
    ref.set(
        {
            F_VISIBILITY: VIS_PUBLIC,
            F_PUBLIC_BODY: draft,
            F_PUBLIC_BODY_SEEDED: True,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    note = f"moved {label} to public"
    head = _snapshot(db, uid, SIDE_PUBLIC, AUTHOR_USER, note)
    _snapshot(db, uid, SIDE_PRIVATE, AUTHOR_USER, note)
    return {"head_version_id": head}


def remove_section(db, uid: str, page_id: str) -> dict:
    """Take the whole section out of the editor. ``ai_body`` is untouched — the
    section survives as an AI-only record — and a revert can bring it back."""
    ref, data = _require_page(db, uid, page_id)
    label = humanize(str(data.get(F_PAGE_TYPE) or "misc"))
    ref.set(
        {
            F_USER_HIDDEN: True,
            F_USER_EDITS: "",
            F_PUBLIC_BODY: "",
            F_PUBLIC_BODY_SEEDED: False,
            F_VISIBILITY: VIS_AI_ONLY,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    note = f"removed {label}"
    head = _snapshot(db, uid, SIDE_PRIVATE, AUTHOR_USER, note)
    _snapshot(db, uid, SIDE_PUBLIC, AUTHOR_USER, note)
    return {"head_version_id": head}


def revert(db, uid: str, version_id: str, side: str) -> dict:
    snap = _versions_col(db, uid).document(version_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(version_id)
    vdata = snap.to_dict() or {}
    side = _side(vdata.get("side") or side)

    for s in vdata.get("sections") or []:
        page_id = s.get("page_id")
        if not page_id:
            continue
        vis = s.get("visibility") or VIS_PRIVATE
        if vis == VIS_AI_ONLY:
            continue  # never restore ai_only pages, never touch ai_body
        ref = _pages_col(db, uid).document(page_id)
        payload = {
            F_USER_UPDATED_AT: _server_ts(),
            F_USER_HIDDEN: False,
            F_VISIBILITY: vis,
        }
        if side == SIDE_PUBLIC:
            payload[F_PUBLIC_BODY] = (s.get("body") or "").strip()
            payload[F_PUBLIC_BODY_SEEDED] = True
        else:
            payload[F_USER_EDITS] = (s.get("body") or "").strip()
        ref.set(payload, merge=True)

    head = _snapshot(db, uid, side, AUTHOR_USER, f"reverted to {version_id}")
    return {"head_version_id": head}


def maybe_snapshot_after_ai(db, uid: str):
    """Cut an Ayma-authored private snapshot after a material ``ai_body``
    change — debounced so a burst of ingests yields one snapshot. Best-effort;
    never raises (ingest rides on it)."""
    try:
        side = SIDE_PRIVATE
        vs = _side_versions(db, uid, side)
        if vs:
            _vid, newest = vs[-1]
            if newest.get("author") == AUTHOR_AYMA:
                age_ms = _now_ms() - int(newest.get("created_at_ms") or 0)
                if age_ms < SNAPSHOT_DEBOUNCE_SECONDS * 1000:
                    return None
        return _snapshot(db, uid, side, AUTHOR_AYMA, NOTE_AI_LEARNED)
    except Exception:  # noqa: BLE001
        logger.exception("story snapshot after ai change failed for %s", uid)
        return None
