"""Your Story — the single-document editor over the user's wiki pages.

One scrolling document: every ``users/{uid}/wiki_pages`` the user is allowed to
see (not ``ai_only``, not ``user_hidden``), each rendered as ONE body —
``user_edits`` if the user has overridden it, otherwise ``ai_body`` (skill
pages are compiled from their structured source). ``ai_body`` is never written
here.

Visibility is ``public`` | ``private`` only in the UI. ``ai_only`` survives in
Firestore purely as the resting state of a section the user deleted (kept so
Ayma still carries it and a revert can restore it).

Private spans: an inline ``{{private}} … {{/private}}`` marker inside a body.
Shown dimmed in the private view; stripped entirely from the public view and
from ``public_profile``.

Every Firestore field name lives here — ``schema.py`` is read-only.
"""

from __future__ import annotations

import logging
import re
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
F_VISIBILITY = "visibility"
F_USER_HIDDEN = "user_hidden"
F_USER_UPDATED_AT = "user_updated_at"
F_AI_BODY_UPDATED_AT = "ai_body_updated_at"
F_PAGE_TYPE = "page_type"

VIS_PUBLIC = "public"
VIS_PRIVATE = "private"
VIS_AI_ONLY = "ai_only"

AUTHOR_USER = "user"
AUTHOR_AYMA = "ayma"

SNAPSHOT_DEBOUNCE_SECONDS = 300
MAX_VERSIONS = 200

NOTE_AI_LEARNED = "learned from a conversation"

PRIVATE_OPEN = "{{private}}"
PRIVATE_CLOSE = "{{/private}}"
_SPAN_RE = re.compile(r"\{\{/?private\}\}")

# Skill pages: compiled from structured data, shown under a divider.
SKILL_PAGE_IDS = ("web-findings", "face-analysis", "body-analysis")
_SKILL_ORDER = {pid: i for i, pid in enumerate(SKILL_PAGE_IDS)}
_SKILL_TITLES = {
    "web-findings": "Web findings",
    "face-analysis": "Facial analysis",
    "body-analysis": "Physique analysis",
}

# Narrative section display order; unknown page_types sort after, alpha by title.
_NARRATIVE_ORDER = [
    "identity",
    "background",
    "career",
    "values",
    "personality",
    "goals",
    "relationships",
    "family",
    "dealbreakers",
    "lifestyle",
    "interests",
    "health",
    "misc",
]


def _server_ts():
    return firestore.SERVER_TIMESTAMP


def _now_ms() -> int:
    return int(time.time() * 1000)


def humanize(text: str) -> str:
    """``web_findings`` -> ``Web Findings`` (title case, for section headings)."""
    base = (text or "").replace("_", " ").replace("-", " ").strip()
    return base.title() if base else "Misc"


def _label(text: str) -> str:
    """``hair_styling`` -> ``Hair styling`` (sentence case, for inline labels)."""
    base = (text or "").replace("_", " ").replace("-", " ").strip()
    return base[:1].upper() + base[1:] if base else ""


def _section_title(page_id: str, page_type: str) -> str:
    if page_id in _SKILL_TITLES:
        return _SKILL_TITLES[page_id]
    return humanize(page_type)


def _section_order(page_id: str, page_type: str) -> int:
    if page_id in _SKILL_ORDER:
        return 300 + _SKILL_ORDER[page_id]
    if page_type in _NARRATIVE_ORDER:
        return 100 + _NARRATIVE_ORDER.index(page_type)
    return 200


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


# --- private spans ------------------------------------------------------


def _parse_spans(body: str) -> list[dict]:
    """Split a body into ``[{"text", "private"}]`` runs by its markers."""
    segments: list[dict] = []
    depth = 0
    pos = 0
    for m in _SPAN_RE.finditer(body or ""):
        chunk = body[pos : m.start()]
        if chunk:
            segments.append({"text": chunk, "private": depth > 0})
        depth = depth + 1 if m.group() == PRIVATE_OPEN else max(0, depth - 1)
        pos = m.end()
    tail = (body or "")[pos:]
    if tail:
        segments.append({"text": tail, "private": depth > 0})
    return segments


def _serialize_spans(segments: list[dict]) -> str:
    merged: list[dict] = []
    for seg in segments:
        if not seg["text"]:
            continue
        if merged and merged[-1]["private"] == seg["private"]:
            merged[-1]["text"] += seg["text"]
        else:
            merged.append({"text": seg["text"], "private": seg["private"]})
    out = []
    for seg in merged:
        if seg["private"]:
            out.append(PRIVATE_OPEN + seg["text"] + PRIVATE_CLOSE)
        else:
            out.append(seg["text"])
    return "".join(out)


def strip_private_spans(text: str) -> str:
    """The body with every ``{{private}}…{{/private}}`` span (and its content)
    removed — what the public profile and the Public view show."""
    plain = "".join(s["text"] for s in _parse_spans(text or "") if not s["private"])
    return re.sub(r"\n{3,}", "\n\n", plain).strip()


def apply_span_action(body: str, selection: str, action: str) -> str:
    """Wrap / unwrap / delete exactly ``selection`` within ``body``, keeping the
    private-span markers well-formed. ``action`` is ``private`` | ``public`` |
    ``delete``. A selection that isn't found leaves the body untouched."""
    if not selection or action not in ("private", "public", "delete"):
        return body
    segments = _parse_spans(body)
    plain = "".join(s["text"] for s in segments)
    idx = plain.find(selection)
    if idx < 0:
        return body
    start, end = idx, idx + len(selection)

    new_segments: list[dict] = []
    cursor = 0
    for seg in segments:
        t = seg["text"]
        lo = max(0, min(len(t), start - cursor))
        hi = max(0, min(len(t), end - cursor))
        cursor += len(t)
        before, middle, after = t[:lo], t[lo:hi], t[hi:]
        if before:
            new_segments.append({"text": before, "private": seg["private"]})
        if middle and action != "delete":
            new_segments.append(
                {"text": middle, "private": action == "private"}
            )
        if after:
            new_segments.append({"text": after, "private": seg["private"]})
    return _serialize_spans(new_segments)


# --- page reads ------------------------------------------------------


def _effective_body(data: dict) -> str:
    ue = (data.get(F_USER_EDITS) or "").strip()
    return ue if ue else (data.get(F_AI_BODY) or "").strip()


def _editor_pages(db, uid) -> list[tuple[str, dict]]:
    """Pages the editor may show: not ``ai_only``, not ``user_hidden``."""
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


def _display_body(db, uid, page_id: str, data: dict) -> str:
    """What the editor renders for a section: a user override wins, else the
    compiled body (skill pages get structured markdown, others ``ai_body``)."""
    ue = (data.get(F_USER_EDITS) or "").strip()
    if ue:
        return ue
    if page_id in SKILL_PAGE_IDS:
        return _skill_markdown(db, uid, page_id, data)
    return (data.get(F_AI_BODY) or "").strip()


# --- skill sections: structured -> markdown -----------------------


def _photo_url_safe(storage_path: str):
    if not storage_path:
        return None
    try:
        import public_profile

        return public_profile._photo_url(storage_path)
    except Exception:  # noqa: BLE001
        return None


def _latest_report(db, uid, kind: str) -> dict | None:
    col = db.collection("users").document(uid).collection(f"{kind}_reports")
    best: dict | None = None
    best_key = -1.0
    try:
        snaps = list(col.stream())
    except Exception:  # noqa: BLE001
        return None
    for snap in snaps:
        d = snap.to_dict() or {}
        if not (d.get("report") or {}).get("usable", True):
            continue
        k = _to_epoch(d.get("created_at"))
        if best is None or k >= best_key:
            best, best_key = d, k
    return best


def _report_markdown(db, uid, kind: str, data: dict) -> str:
    doc = _latest_report(db, uid, kind)
    if not doc:
        return (data.get(F_AI_BODY) or "").strip()
    report = doc.get("report") or {}
    lines: list[str] = []

    url = _photo_url_safe(str(doc.get("image_path") or ""))
    if url:
        lines += [f"![]({url})", ""]

    score = report.get("overall_score")
    verdict = str(report.get("verdict") or "").strip()
    if score is not None:
        head = f"**{score} / 10**"
        if verdict:
            head += f" — {verdict}"
        lines.append(head)
    note = str(report.get("verdict_note") or "").strip()
    if note:
        lines += ["", note]

    strengths = [str(x).strip() for x in (report.get("strengths") or []) if str(x).strip()]
    if strengths:
        lines += ["", "### Strengths", *[f"- {x}" for x in strengths]]

    improvements = [
        str(x).strip() for x in (report.get("improvements") or []) if str(x).strip()
    ]
    if improvements:
        lines += ["", "### Worth working on", *[f"- {x}" for x in improvements]]

    reco_lines: list[str] = []
    for r in report.get("recommendations") or []:
        if not isinstance(r, dict):
            continue
        text = str(r.get("text") or "").strip()
        if not text:
            continue
        cat = _label(str(r.get("category") or ""))
        reco_lines.append(f"- **{cat}:** {text}" if cat else f"- {text}")
    if reco_lines:
        lines += ["", "### Recommendations", *reco_lines]

    return "\n".join(lines).strip()


_URL_RE = re.compile(r"(?<!\()(?<!\]\()(https?://[^\s)]+)")


def _web_findings_markdown(data: dict) -> str:
    """The ``web-findings`` prose, with its bare ``Label:`` lines promoted to
    headings and bare URLs linkified."""
    body = (data.get(F_AI_BODY) or "").strip()
    if not body:
        return ""
    out_lines: list[str] = []
    for line in body.split("\n"):
        stripped = line.strip()
        low = stripped.lower().rstrip(":")
        if low in ("facts found", "links", "caveats", "sources"):
            out_lines.append(f"### {stripped.rstrip(':')}")
            continue
        # "- Title (tag): https://…"  ->  "- [Title](https://…)"
        m = re.match(r"^-\s+(.+?)\s+\([^)]*\):\s*(https?://\S+)\s*$", stripped)
        if m:
            out_lines.append(f"- [{m.group(1)}]({m.group(2)})")
            continue
        out_lines.append(_URL_RE.sub(r"[\1](\1)", line))
    return "\n".join(out_lines).strip()


def _skill_markdown(db, uid, page_id: str, data: dict) -> str:
    if page_id == "web-findings":
        return _web_findings_markdown(data)
    kind = "face" if page_id == "face-analysis" else "body"
    return _report_markdown(db, uid, kind, data)


# --- versions -------------------------------------------------------


def _all_versions(db, uid) -> list[tuple[str, dict]]:
    out: list[tuple[str, dict]] = []
    for snap in _versions_col(db, uid).stream():
        out.append((snap.id, snap.to_dict() or {}))
    out.sort(key=lambda t: (int(t[1].get("created_at_ms") or 0), t[0]))
    return out


def _head_version_id(db, uid):
    vs = _all_versions(db, uid)
    return vs[-1][0] if vs else None


def _snapshot(db, uid, author: str, note: str = "") -> str:
    sections = []
    for page_id, data in _editor_pages(db, uid):
        page_type = str(data.get(F_PAGE_TYPE) or "misc")
        sections.append(
            {
                "page_id": page_id,
                "page_type": page_type,
                "title": _section_title(page_id, page_type),
                "body": _display_body(db, uid, page_id, data),
                "visibility": data.get(F_VISIBILITY) or VIS_PRIVATE,
            }
        )
    ref = _versions_col(db, uid).document()
    ref.set(
        {
            "sections": sections,
            "author": author,
            "note": note or "",
            "created_at": _server_ts(),
            "created_at_ms": _now_ms(),
        }
    )
    _prune(db, uid)
    return ref.id


def _prune(db, uid) -> None:
    vs = _all_versions(db, uid)
    for vid, _ in vs[: max(0, len(vs) - MAX_VERSIONS)]:
        _versions_col(db, uid).document(vid).delete()


# --- public API: reads --------------------------------------------


def get_story(db, uid: str) -> dict:
    """The whole story document once. The client renders the Public preview by
    filtering locally (``visibility == 'public'`` + :func:`strip_private_spans`).
    """
    sections = []
    for page_id, data in _editor_pages(db, uid):
        page_type = str(data.get(F_PAGE_TYPE) or "misc")
        body = _display_body(db, uid, page_id, data)
        vis = data.get(F_VISIBILITY) or VIS_PRIVATE
        if vis not in (VIS_PUBLIC, VIS_PRIVATE):
            vis = VIS_PRIVATE
        sections.append(
            {
                "page_id": page_id,
                "page_type": page_type,
                "title": _section_title(page_id, page_type),
                "body": body,
                "visibility": vis,
                "user_edited": bool((data.get(F_USER_EDITS) or "").strip()),
                "is_skill": page_id in SKILL_PAGE_IDS,
                "has_private_spans": PRIVATE_OPEN in body,
                "ai_updated_since_user": _ai_updated_since_user(data),
                "order": _section_order(page_id, page_type),
            }
        )
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections, "head_version_id": _head_version_id(db, uid)}


def list_versions(db, uid: str) -> list[dict]:
    vs = _all_versions(db, uid)  # oldest first
    rows: list[dict] = []
    for i, (vid, data) in enumerate(vs):
        cur = {s["page_id"]: s for s in (data.get("sections") or [])}
        if i == 0:
            changed = sorted(
                {s.get("page_type") for s in cur.values() if s.get("page_type")}
            )
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
        "author": data.get("author") or AUTHOR_USER,
        "note": data.get("note") or "",
        "created_at": _iso(data.get("created_at")),
        "created_at_ms": int(data.get("created_at_ms") or 0),
        "sections": data.get("sections") or [],
    }


# --- public API: writes -----------------------------------------


def _require_page(db, uid, page_id: str) -> tuple[object, dict]:
    ref = _pages_col(db, uid).document(page_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        raise KeyError(page_id)
    return ref, (snap.to_dict() or {})


def save_section(db, uid: str, page_id: str, body: str, visibility=None) -> dict:
    ref, _data = _require_page(db, uid, page_id)
    payload = {
        F_USER_EDITS: (body or "").strip(),
        F_USER_UPDATED_AT: _server_ts(),
    }
    if visibility in (VIS_PUBLIC, VIS_PRIVATE):
        payload[F_VISIBILITY] = visibility
    ref.set(payload, merge=True)
    return {"head_version_id": _snapshot(db, uid, AUTHOR_USER)}


def set_visibility(db, uid: str, page_id: str, visibility: str) -> dict:
    if visibility not in (VIS_PUBLIC, VIS_PRIVATE):
        raise ValueError(visibility)
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(page_id, str(data.get(F_PAGE_TYPE) or "misc"))
    ref.set(
        {F_VISIBILITY: visibility, F_USER_UPDATED_AT: _server_ts()}, merge=True
    )
    return {
        "head_version_id": _snapshot(
            db, uid, AUTHOR_USER, f"made {label} {visibility}"
        )
    }


def span_action(
    db, uid: str, page_id: str, selection: str, action: str
) -> dict:
    """Wrap / unwrap / delete a substring within a section, then snapshot."""
    if action not in ("private", "public", "delete"):
        raise ValueError(action)
    ref, data = _require_page(db, uid, page_id)
    body = _display_body(db, uid, page_id, data)
    new_body = apply_span_action(body, selection, action).strip()
    ref.set(
        {F_USER_EDITS: new_body, F_USER_UPDATED_AT: _server_ts()}, merge=True
    )
    return {
        "head_version_id": _snapshot(db, uid, AUTHOR_USER),
        "body": new_body,
    }


_EDIT_SYS = (
    "You help someone edit one section of their personal profile from a "
    "highlighted passage plus a plain-language instruction. Classify the "
    "instruction and respond as JSON with an `action`:\n"
    '- "rewrite": return {"action":"rewrite","revised_body":"<the FULL '
    'revised section body>"}. Deleting the highlighted line is a rewrite with '
    "that line removed.\n"
    '- "move": the user wants this section shown publicly or kept private. '
    'Return {"action":"move","target_visibility":"public"|"private"}.\n'
    '- "remove": the user wants the whole section deleted. Return '
    '{"action":"remove"}.\n'
    "For a rewrite, return the entire section body, not just the changed part. "
    "You may use {{private}}…{{/private}} to mark a passage as private."
)
_EDIT_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["rewrite", "move", "remove"]},
        "revised_body": {"type": "string"},
        "target_visibility": {"type": "string", "enum": ["public", "private"]},
    },
    "required": ["action"],
}


def _edit_contents(body: str, selection: str, instruction: str) -> str:
    return (
        f"Full section body:\n{body}\n\n"
        f"Highlighted passage:\n{selection.strip() or '(none)'}\n\n"
        f"Instruction:\n{instruction.strip()}"
    )


async def edit_section(
    db, uid: str, page_id: str, selection: str, instruction: str
) -> dict:
    _ref, data = _require_page(db, uid, page_id)
    body = _display_body(db, uid, page_id, data)
    try:
        result = await gemini.generate_json(
            _edit_contents(body, selection, instruction),
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
        cur = data.get(F_VISIBILITY) or VIS_PRIVATE
        target = str((result or {}).get("target_visibility") or "").strip().lower()
        if target not in (VIS_PUBLIC, VIS_PRIVATE):
            target = VIS_PRIVATE if cur == VIS_PUBLIC else VIS_PUBLIC
        return {"action": "move", "target_visibility": target}
    if action == "remove":
        return {"action": "remove"}

    revised = ""
    if isinstance(result, dict):
        revised = str(result.get("revised_body") or "").strip()
    return {"action": "rewrite", "revised_body": revised or body}


def remove_section(db, uid: str, page_id: str) -> dict:
    """Delete a section from the editor. ``ai_body`` is untouched — Ayma keeps
    it — and a revert to an earlier version can bring it back."""
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(page_id, str(data.get(F_PAGE_TYPE) or "misc"))
    ref.set(
        {
            F_USER_HIDDEN: True,
            F_USER_EDITS: "",
            F_VISIBILITY: VIS_AI_ONLY,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    return {
        "head_version_id": _snapshot(db, uid, AUTHOR_USER, f"deleted {label}")
    }


def revert(db, uid: str, version_id: str) -> dict:
    snap = _versions_col(db, uid).document(version_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(version_id)
    vdata = snap.to_dict() or {}

    for s in vdata.get("sections") or []:
        page_id = s.get("page_id")
        if not page_id:
            continue
        vis = s.get("visibility") or VIS_PRIVATE
        if vis == VIS_AI_ONLY:
            continue  # never restore an ai_only page, never touch ai_body
        _pages_col(db, uid).document(page_id).set(
            {
                F_USER_UPDATED_AT: _server_ts(),
                F_USER_HIDDEN: False,
                F_VISIBILITY: vis if vis in (VIS_PUBLIC, VIS_PRIVATE) else VIS_PRIVATE,
                F_USER_EDITS: (s.get("body") or "").strip(),
            },
            merge=True,
        )

    return {
        "head_version_id": _snapshot(
            db, uid, AUTHOR_USER, f"reverted to {version_id}"
        )
    }


def maybe_snapshot_after_ai(db, uid: str):
    """Cut an Ayma-authored snapshot after a material ``ai_body`` change —
    debounced so a burst of ingests yields one snapshot. Best-effort; never
    raises (ingest rides on it)."""
    try:
        vs = _all_versions(db, uid)
        if vs:
            _vid, newest = vs[-1]
            if newest.get("author") == AUTHOR_AYMA:
                age_ms = _now_ms() - int(newest.get("created_at_ms") or 0)
                if age_ms < SNAPSHOT_DEBOUNCE_SECONDS * 1000:
                    return None
        return _snapshot(db, uid, AUTHOR_AYMA, NOTE_AI_LEARNED)
    except Exception:  # noqa: BLE001
        logger.exception("story snapshot after ai change failed for %s", uid)
        return None
