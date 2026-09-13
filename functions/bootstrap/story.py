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

AI-only spans: an inline ``{{ai_only}} … {{/ai_only}}`` marker — the
passage-level equivalent of a page's whole-section ``ai_only`` visibility.
Written by "Delete from profile" (``skills.story_edit.remove_from_profile``):
the passage stays in the body (Ayma still has it, and it's revertible) but is
excluded from both the public view *and* the normal "Story" editor view
(:func:`strip_ai_only_spans`) — only "Ayma's Notes" shows it, rendered in the
app's existing red "removed" tone. A span is one of exactly three kinds —
``public`` / ``private`` / ``ai_only`` — never more than one at a time.

``face-analysis`` / ``body-analysis`` / ``physical-profile`` / ``web-findings``
(:data:`REPORT_LINKED_PAGE_IDS`) each carry a ``report_id`` in their section
dict, pointing at the dedicated report screen for that content (the client
renders a summary card + link there instead of the full body, to avoid
showing the same report twice). ``report_id`` is ``None`` when no report has
been run yet; the key is present only for these four page types — absent
entirely from every other section's dict.

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

NOTE_AI_LEARNED = "learned from a conversation"

PRIVATE_OPEN = "{{private}}"
PRIVATE_CLOSE = "{{/private}}"
AI_ONLY_OPEN = "{{ai_only}}"
AI_ONLY_CLOSE = "{{/ai_only}}"
_SPAN_RE = re.compile(r"\{\{/?(?:private|ai_only)\}\}")

# Skill pages: compiled from structured data, shown under a divider.
SKILL_PAGE_IDS = ("web-findings", "face-analysis", "body-analysis")
_SKILL_ORDER = {pid: i for i, pid in enumerate(SKILL_PAGE_IDS)}
_SKILL_TITLES = {
    "web-findings": "Web findings",
    "face-analysis": "Facial analysis",
    "body-analysis": "Physique analysis",
}

# The four page types with their own dedicated, already-designed report
# screen — the client renders these as a compact summary card + "View full
# report" link instead of the full inline body (§ Your Story report links).
# ``physical-profile`` isn't in ``SKILL_PAGE_IDS`` (it doesn't sort under the
# "FROM AYMA'S SKILLS" divider — see ``_section_order``) but still gets a
# ``report_id`` here.
REPORT_LINKED_PAGE_IDS = (
    "face-analysis",
    "body-analysis",
    "physical-profile",
    "web-findings",
)

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
    """Split a body into ``[{"text", "kind"}]`` runs by its markers, where
    ``kind`` is one of ``"public"`` / ``"private"`` / ``"ai_only"``.

    Two independent depth counters (one per marker type) rather than a
    general nested-span stack — mirrors the original single-counter
    private-only design. Spans of either kind are always flat and
    non-overlapping in practice (every span is written by
    :func:`apply_span_action`, which never nests one kind inside the other),
    so this is enough; if a body ever did have ``ai_only`` opened while
    ``private`` is also open, ``ai_only`` wins (it's the more-hidden state).
    """
    segments: list[dict] = []
    priv_depth = 0
    ai_depth = 0
    pos = 0

    def _kind() -> str:
        if ai_depth > 0:
            return "ai_only"
        if priv_depth > 0:
            return "private"
        return "public"

    for m in _SPAN_RE.finditer(body or ""):
        chunk = body[pos : m.start()]
        if chunk:
            segments.append({"text": chunk, "kind": _kind()})
        tok = m.group()
        if tok == PRIVATE_OPEN:
            priv_depth += 1
        elif tok == PRIVATE_CLOSE:
            priv_depth = max(0, priv_depth - 1)
        elif tok == AI_ONLY_OPEN:
            ai_depth += 1
        elif tok == AI_ONLY_CLOSE:
            ai_depth = max(0, ai_depth - 1)
        pos = m.end()
    tail = (body or "")[pos:]
    if tail:
        segments.append({"text": tail, "kind": _kind()})
    return segments


def _serialize_spans(segments: list[dict]) -> str:
    merged: list[dict] = []
    for seg in segments:
        if not seg["text"]:
            continue
        if merged and merged[-1]["kind"] == seg["kind"]:
            merged[-1]["text"] += seg["text"]
        else:
            merged.append({"text": seg["text"], "kind": seg["kind"]})
    out = []
    for seg in merged:
        if seg["kind"] == "private":
            out.append(PRIVATE_OPEN + seg["text"] + PRIVATE_CLOSE)
        elif seg["kind"] == "ai_only":
            out.append(AI_ONLY_OPEN + seg["text"] + AI_ONLY_CLOSE)
        else:
            out.append(seg["text"])
    return "".join(out)


def strip_private_spans(text: str) -> str:
    """The body with every non-``public`` span (``private`` or ``ai_only``,
    and its content) removed — what the public profile and the Public view
    show."""
    plain = "".join(
        s["text"] for s in _parse_spans(text or "") if s["kind"] == "public"
    )
    return re.sub(r"\n{3,}", "\n\n", plain).strip()


def strip_ai_only_spans(text: str) -> str:
    """The body with only its ``ai_only`` spans (and their content) removed —
    ``private`` spans are kept (still shown, dimmed), since this backs the
    normal editor "Story" view: it must exclude ai-only material but still
    shows private-but-visible-to-the-user passages. Only "Ayma's Notes"
    (:func:`get_ai_notes`) gets the raw, unstripped body."""
    kept = [s for s in _parse_spans(text or "") if s["kind"] != "ai_only"]
    out = _serialize_spans(kept)
    return re.sub(r"\n{3,}", "\n\n", out).strip()


def apply_span_action(body: str, selection: str, action: str) -> str:
    """Wrap / unwrap / delete exactly ``selection`` within ``body``, keeping
    span markers well-formed. ``action`` is ``private`` | ``public`` |
    ``ai_only`` | ``delete``. A selection that isn't found leaves the body
    untouched."""
    if not selection or action not in ("private", "public", "ai_only", "delete"):
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
            new_segments.append({"text": before, "kind": seg["kind"]})
        if middle and action != "delete":
            new_segments.append({"text": middle, "kind": action})
        if after:
            new_segments.append({"text": after, "kind": seg["kind"]})
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


def _all_pages(db, uid) -> list[tuple[str, dict]]:
    """Every page the owner's AI notes may show, including sections "removed
    from profile" (now ``ai_only``) — only ``user_hidden`` is still excluded,
    same as :func:`_editor_pages`."""
    out: list[tuple[str, dict]] = []
    for snap in _pages_col(db, uid).stream():
        data = snap.to_dict() or {}
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
    compiled body. ``web-findings`` gets its bare labels/links promoted to
    markdown; ``face-analysis``/``body-analysis`` show their own maintained
    ``ai_body`` (skill_memory's accumulated write) like any ordinary page —
    they are NOT re-derived from the separate, single-latest ``{kind}_reports``
    collection used elsewhere for a tappable report-card UI."""
    ue = (data.get(F_USER_EDITS) or "").strip()
    if ue:
        return ue
    if page_id == "web-findings":
        return _web_findings_markdown(data)
    return (data.get(F_AI_BODY) or "").strip()


def _skill_report_id(db, uid: str, page_id: str) -> str | None:
    """The id of the dedicated report screen's report backing one of
    :data:`REPORT_LINKED_PAGE_IDS`, or ``None`` when no such report has been
    run yet (the wiki page can carry real content — e.g. from background
    auto-analysis — well before the first explicit report exists).

    ``face-analysis`` / ``body-analysis`` / ``physical-profile`` all fold into
    the single unified ``appearance_reports`` doc (one Appearance report,
    opened client-side at ``/appearance/{id}`` — PLAN.md 1.8.0);
    ``web-findings`` is the user's own self-dive, keyed deterministically and
    opened at ``/deep-dive/{id}``. Best-effort: a lookup failure just omits
    the link rather than breaking the story read."""
    try:
        if page_id in ("face-analysis", "body-analysis", "physical-profile"):
            import appearance

            rid = str((appearance.current(db, uid) or {}).get("report_id") or "")
            return rid.strip() or None
        if page_id == "web-findings":
            import deep_dive

            if not deep_dive.has_dive(db, uid, target_uid=uid):
                return None
            return deep_dive.dive_report_id(target_uid=uid) or None
    except Exception:  # noqa: BLE001 - a lookup failure just omits the link
        logger.exception(
            "story: skill report_id lookup failed for %s/%s", uid, page_id
        )
    return None


# --- skill sections: structured -> markdown -----------------------


def _photo_url_safe(storage_path: str):
    """Shared helper: also used by ``main.py`` to resolve a user's profile
    photo URL, unrelated to the report markdown below — keep even though the
    report path stops using it here."""
    if not storage_path:
        return None
    try:
        import public_profile

        return public_profile._photo_url(storage_path)
    except Exception:  # noqa: BLE001
        return None


# ``_latest_report``/``_report_markdown`` are no longer called from
# ``_display_body`` (face-analysis/body-analysis now show their own
# maintained ``ai_body`` instead of re-deriving from the single-latest
# ``{kind}_reports`` doc — see ``_display_body``'s docstring). Nothing else
# in the codebase calls them today (checked: only ``story.py`` referenced
# them), so they are currently dead code. Left in place rather than deleted:
# they're a ready-made "single latest report + photo, markdown-with-images"
# renderer that a future dedicated Face/Body report VIEW screen (one that
# actually supports markdown images, unlike Story's SelectableMarkdown)
# could legitimately reuse.
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


# --- per-section version history (each section = a file, its own git log) ---

SECTION_VERSIONS = "versions"
MAX_SECTION_VERSIONS = 50


def _section_versions_col(db, uid, page_id: str):
    return _pages_col(db, uid).document(page_id).collection(SECTION_VERSIONS)


def _section_history(db, uid, page_id: str) -> list[tuple[str, dict]]:
    out = [
        (snap.id, snap.to_dict() or {})
        for snap in _section_versions_col(db, uid, page_id).stream()
    ]
    out.sort(key=lambda t: (int(t[1].get("created_at_ms") or 0), t[0]))
    return out  # oldest first


def _snapshot_section(
    db,
    uid,
    page_id: str,
    author: str,
    note: str = "",
    *,
    body: str | None = None,
    visibility: str | None = None,
) -> str:
    """Commit the section's current (or explicitly given) state to its history.
    Prunes to the newest ``MAX_SECTION_VERSIONS``."""
    if body is None or visibility is None:
        snap = _pages_col(db, uid).document(page_id).get()
        data = snap.to_dict() or {}
        if body is None:
            body = _display_body(db, uid, page_id, data)
        if visibility is None:
            visibility = data.get(F_VISIBILITY) or VIS_PRIVATE
    ref = _section_versions_col(db, uid, page_id).document()
    ref.set(
        {
            "body": body,
            "visibility": visibility,
            "author": author,
            "note": note or "",
            "created_at": _server_ts(),
            "created_at_ms": _now_ms(),
        }
    )
    hist = _section_history(db, uid, page_id)
    for vid, _ in hist[: max(0, len(hist) - MAX_SECTION_VERSIONS)]:
        _section_versions_col(db, uid, page_id).document(vid).delete()
    return ref.id


def list_section_versions(db, uid: str, page_id: str) -> list[dict]:
    rows = [
        {
            "id": vid,
            "author": data.get("author") or AUTHOR_USER,
            "note": data.get("note") or "",
            "visibility": data.get("visibility") or VIS_PRIVATE,
            "created_at": _iso(data.get("created_at")),
            "created_at_ms": int(data.get("created_at_ms") or 0),
        }
        for vid, data in _section_history(db, uid, page_id)
    ]
    rows.reverse()  # newest first
    return rows


def get_section_version(db, uid: str, page_id: str, version_id: str) -> dict:
    snap = _section_versions_col(db, uid, page_id).document(version_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(version_id)
    data = snap.to_dict() or {}
    return {
        "id": version_id,
        "body": data.get("body") or "",
        "visibility": data.get("visibility") or VIS_PRIVATE,
        "author": data.get("author") or AUTHOR_USER,
        "note": data.get("note") or "",
        "created_at": _iso(data.get("created_at")),
        "created_at_ms": int(data.get("created_at_ms") or 0),
    }


# --- public API: reads --------------------------------------------


def _section_dict(
    db, uid, page_id: str, data: dict, *, include_ai_only: bool = False
) -> dict:
    """Owner-only section: display body plus canonical edit_body for saves."""
    page_type = str(data.get(F_PAGE_TYPE) or "misc")
    body = _display_body(db, uid, page_id, data)
    edit_body = body
    if not include_ai_only:
        body = strip_ai_only_spans(body)
    section = {
        "page_id": page_id,
        "page_type": page_type,
        "title": _section_title(page_id, page_type),
        "body": body,
        "edit_body": edit_body,
        "user_hidden": data.get(F_USER_HIDDEN) is True,
        "visibility": data.get(F_VISIBILITY) or VIS_PRIVATE,
        "user_edited": bool((data.get(F_USER_EDITS) or "").strip()),
        "is_skill": page_id in SKILL_PAGE_IDS,
        "has_private_spans": PRIVATE_OPEN in body,
        "ai_updated_since_user": _ai_updated_since_user(data),
        "order": _section_order(page_id, page_type),
    }
    if page_id in REPORT_LINKED_PAGE_IDS:
        section["report_id"] = _skill_report_id(db, uid, page_id)
    return section


def get_story(db, uid: str) -> dict:
    """The whole story document once. The client renders the Public preview by
    filtering locally (``visibility == 'public'`` + :func:`strip_private_spans`).
    Each section carries its own version history under
    ``wiki_pages/{id}/versions``.
    """
    sections = []
    for page_id, data in _editor_pages(db, uid):
        section = _section_dict(db, uid, page_id, data)
        if section["visibility"] not in (VIS_PUBLIC, VIS_PRIVATE):
            section["visibility"] = VIS_PRIVATE
        sections.append(section)
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections}


def get_ai_notes(db, uid: str) -> dict:
    """"AI notes": every wiki page the caller has, regardless of visibility —
    a superset of ``get_story``'s "Everything" that also includes any page
    still ``ai_only``, and any inline ``{{ai_only}}`` passage within an
    otherwise-visible page. Each section carries its own real ``visibility``
    so the client can colour-code public/private/ai_only in one list."""
    sections = [
        _section_dict(db, uid, page_id, data, include_ai_only=True)
        for page_id, data in _all_pages(db, uid)
    ]
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections}


# --- provenance ("why Ayma believes this") -------------------------


def get_section_provenance(db, uid: str, page_id: str) -> dict:
    """Page-level provenance for one section — never fabricated per-sentence
    confidence (the founder's own scope call): when Ayma's compiled body last
    moved, when the user last edited it, and the conversations that fed it,
    resolved from ``source_turn_ids`` (``raw_turns`` session-doc ids,
    stamped by ``wiki_ingest._write_page``) into human-facing dates.

    Real confidence exists only on individual web-research facts (the
    deep-dive report's own digest) — never here."""
    _ref, data = _require_page(db, uid, page_id)
    turn_ids = [
        str(t) for t in (data.get("source_turn_ids") or []) if str(t).strip()
    ]
    col = db.collection("users").document(uid).collection("raw_turns")
    sources: list[dict] = []
    for tid in turn_ids:
        try:
            snap = col.document(tid).get()
        except Exception:  # noqa: BLE001 - one bad turn id must not break the rest
            continue
        if not getattr(snap, "exists", False):
            continue
        tdata = snap.to_dict() or {}
        ts = tdata.get("updated_at")
        sources.append(
            {"date": _iso(ts), "session_id": tid, "_epoch": _to_epoch(ts)}
        )
    sources.sort(key=lambda s: s["_epoch"], reverse=True)
    for s in sources:
        del s["_epoch"]
    return {
        "page_id": page_id,
        "conversation_count": len(turn_ids),
        "updated_at": _iso(data.get(F_AI_BODY_UPDATED_AT)),
        "user_updated_at": _iso(data.get(F_USER_UPDATED_AT)),
        # Most-recent handful — "Learned across N conversations" already says
        # the total; the list itself is a "Sources" preview, not a full log.
        "sources": sources[:8],
    }


# --- public API: writes -----------------------------------------


def _require_page(db, uid, page_id: str) -> tuple[object, dict]:
    ref = _pages_col(db, uid).document(page_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        raise KeyError(page_id)
    return ref, (snap.to_dict() or {})


def save_section(
    db, uid: str, page_id: str, body: str, visibility=None, *,
    allow_hidden_changes: bool = False,
) -> dict:
    """Reject hidden-content loss before writing. Clients round-trip edit_body.

    Trusted scoped passage tools alone may intentionally change hidden content.
    """
    ref, data = _require_page(db, uid, page_id)
    if not allow_hidden_changes:
        existing = _parse_spans(_display_body(db, uid, page_id, data))
        remaining = "".join(
            seg["text"] for seg in _parse_spans(body or "")
            if seg["kind"] == "ai_only"
        )
        for seg in existing:
            if seg["kind"] != "ai_only":
                continue
            index = remaining.find(seg["text"])
            if index < 0:
                raise ValueError(
                    "This save would lose hidden passages. Reload the story "
                    "and edit edit_body, preserving its ai_only spans."
                )
            remaining = remaining[index + len(seg["text"]):]
    payload = {
        F_USER_EDITS: (body or "").strip(),
        F_USER_UPDATED_AT: _server_ts(),
    }
    if visibility in (VIS_PUBLIC, VIS_PRIVATE):
        payload[F_VISIBILITY] = visibility
    ref.set(payload, merge=True)
    return {
        "head_version_id": _snapshot_section(db, uid, page_id, AUTHOR_USER)
    }


def set_visibility(db, uid: str, page_id: str, visibility: str) -> dict:
    if visibility not in (VIS_PUBLIC, VIS_PRIVATE):
        raise ValueError(visibility)
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(page_id, str(data.get(F_PAGE_TYPE) or "misc"))
    ref.set(
        {F_VISIBILITY: visibility, F_USER_UPDATED_AT: _server_ts()}, merge=True
    )
    return {
        "head_version_id": _snapshot_section(
            db, uid, page_id, AUTHOR_USER, f"made {label} {visibility}"
        )
    }


# --- passage chat -------------------------------------------------

_CHAT_SYS = (
    "You help someone shape one section of their personal dating-profile story "
    "by chatting about a highlighted passage. You have the full section body "
    "and the passage they highlighted. Answer their message in one or two "
    "sentences (`reply`), then pick ONE action:\n"
    "- Just talking / still figuring it out -> action \"chat\".\n"
    "- They want to make ONLY the highlighted passage private, public, or "
    "deleted -> action \"span\" with `span_action` = private|public|delete. "
    "Do NOT write `revised_body` for this; the app applies it to exactly the "
    "highlighted text.\n"
    "- They want to reword the highlighted passage (or the section) -> action "
    "\"chat\" and return `revised_body`: the ENTIRE section body with the "
    "wording change applied, everything else byte-for-byte. Use "
    "{{private}}…{{/private}} only if they also asked for that.\n"
    "- They want the WHOLE section made private or public -> action \"move\" "
    "with `target_visibility`. Only when they clearly mean the whole section, "
    "not the passage.\n"
    "- They want the WHOLE section deleted -> action \"remove\".\n"
    "When unsure whether they mean the passage or the section, assume the "
    "passage (\"span\")."
)
_CHAT_SCHEMA = {
    "type": "object",
    "properties": {
        "reply": {"type": "string"},
        "revised_body": {"type": "string"},
        "action": {
            "type": "string",
            "enum": ["chat", "span", "move", "remove"],
        },
        "span_action": {
            "type": "string",
            "enum": ["private", "public", "delete"],
        },
        "target_visibility": {"type": "string", "enum": ["public", "private"]},
    },
    "required": ["reply"],
}


def _chat_contents(body: str, selection: str, messages: list[dict]) -> str:
    thread = "\n".join(
        f"{'Them' if str(m.get('role')) == 'user' else 'You'}: "
        f"{str(m.get('text', '')).strip()}"
        for m in messages
        if str(m.get("text", "")).strip()
    )
    return (
        f"Full section body:\n{body}\n\n"
        f"Highlighted passage:\n{selection.strip() or '(none)'}\n\n"
        f"Conversation so far:\n{thread or '(just opened)'}"
    )


async def edit_section(
    db, uid: str, page_id: str, selection: str, messages: list[dict]
) -> dict:
    """One turn of the passage chat. Returns ``{reply, revised_body, action,
    target_visibility}`` — ``revised_body`` set only when Ayma proposes a
    concrete rewrite. Writes nothing."""
    _ref, data = _require_page(db, uid, page_id)
    body = _display_body(db, uid, page_id, data)
    try:
        result = await gemini.generate_json(
            _chat_contents(body, selection, messages or []),
            system_prompt=_CHAT_SYS,
            response_schema=_CHAT_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_WIKI,
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    result = result if isinstance(result, dict) else {}
    action = str(result.get("action") or "chat").strip().lower()
    if action not in ("chat", "span", "move", "remove"):
        action = "chat"
    sel = (selection or "").strip()
    span_action = str(result.get("span_action") or "").strip().lower()

    # Safety net: the model likes to call a passage-level privacy change a whole
    # -section "move". If they highlighted a passage that's a real substring of
    # the body (not ~the whole thing), treat it as a span op on that passage.
    if (
        action == "move"
        and sel
        and sel in body
        and len(sel) < len(body) * 0.9
    ):
        action = "span"
        tv = str(result.get("target_visibility") or "").strip().lower()
        span_action = tv if tv in ("public", "private") else "private"

    out: dict = {
        "reply": str(result.get("reply") or "").strip(),
        "revised_body": str(result.get("revised_body") or "").strip(),
        "action": action,
    }

    if action == "span":
        if span_action not in ("private", "public", "delete") or not sel:
            # Nothing actionable — fall back to a plain chat turn.
            out["action"] = "chat"
        else:
            # Deterministic: only the highlighted passage changes, markers stay
            # well-formed. Never trust the model's own body here.
            out["span_action"] = span_action
            out["revised_body"] = apply_span_action(body, sel, span_action)
    elif action == "move":
        cur = data.get(F_VISIBILITY) or VIS_PRIVATE
        target = str(result.get("target_visibility") or "").strip().lower()
        out["target_visibility"] = (
            target
            if target in (VIS_PUBLIC, VIS_PRIVATE)
            else (VIS_PRIVATE if cur == VIS_PUBLIC else VIS_PUBLIC)
        )
    return out


def remove_section(db, uid: str, page_id: str) -> dict:
    """Delete a section from the editor. ``ai_body`` is untouched — Ayma keeps
    it — and a revert to an earlier version can bring it back. The pre-delete
    state is committed to the section's history first."""
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(page_id, str(data.get(F_PAGE_TYPE) or "misc"))
    _snapshot_section(
        db,
        uid,
        page_id,
        AUTHOR_USER,
        f"deleted {label}",
        body=_display_body(db, uid, page_id, data),
        visibility=(
            data.get(F_VISIBILITY)
            if (data.get(F_VISIBILITY) in (VIS_PUBLIC, VIS_PRIVATE))
            else VIS_PRIVATE
        ),
    )
    ref.set(
        {
            F_USER_HIDDEN: True,
            F_USER_EDITS: "",
            F_VISIBILITY: VIS_AI_ONLY,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    return {"deleted": True}


def revert_section(db, uid: str, page_id: str, version_id: str) -> dict:
    """Restore a section's body + visibility from one of its own versions.
    ``ai_body`` is never touched; a section deleted after that version comes
    back."""
    v = get_section_version(db, uid, page_id, version_id)  # raises KeyError
    vis = v["visibility"] if v["visibility"] in (VIS_PUBLIC, VIS_PRIVATE) else VIS_PRIVATE
    _pages_col(db, uid).document(page_id).set(
        {
            F_USER_EDITS: v["body"],
            F_VISIBILITY: vis,
            F_USER_HIDDEN: False,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    return {
        "head_version_id": _snapshot_section(
            db, uid, page_id, AUTHOR_USER, f"reverted to {version_id}"
        )
    }


def maybe_snapshot_section_after_ai(db, uid: str, page_id: str):
    """Commit an Ayma-authored version of one section after a material
    ``ai_body`` change — but only while the section still shows Ayma's body
    (no user override), and debounced per section. Best-effort; never raises
    (ingest rides on it)."""
    try:
        snap = _pages_col(db, uid).document(page_id).get()
        data = snap.to_dict() or {}
        if (data.get(F_USER_EDITS) or "").strip():
            return None  # the user's body is what shows; ai change is invisible
        hist = _section_history(db, uid, page_id)
        if hist:
            _vid, newest = hist[-1]
            if newest.get("author") == AUTHOR_AYMA:
                age_ms = _now_ms() - int(newest.get("created_at_ms") or 0)
                if age_ms < SNAPSHOT_DEBOUNCE_SECONDS * 1000:
                    return None
        return _snapshot_section(
            db, uid, page_id, AUTHOR_AYMA, NOTE_AI_LEARNED
        )
    except Exception:  # noqa: BLE001
        logger.exception(
            "story section snapshot after ai change failed: %s/%s", uid, page_id
        )
        return None
