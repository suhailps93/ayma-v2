"""Wiki-page reads and skill-section markdown compilation.

Tier-2 sweep monolith split #12: the ``--- page reads ---`` and ``--- skill
sections: structured -> markdown ---`` sections of the former ``story.py``
monolith, moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging
import re

from story_common import (
    F_AI_BODY,
    F_AI_BODY_UPDATED_AT,
    F_PAGE_TYPE,
    F_USER_EDITS,
    F_USER_HIDDEN,
    F_USER_UPDATED_AT,
    F_VISIBILITY,
    VIS_AI_ONLY,
    VIS_PRIVATE,
    _label,
    _pages_col,
    _to_epoch,
)

logger = logging.getLogger("ayma.story")


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

            # A self dive is stored keyed by the caller's *name*
            # (`target_uid=""` on every self-dive call site), never by uid —
            # same gotcha `/deep-dive/mine` in main.py already works around.
            # Looking this up by `target_uid=uid` (as this used to) silently
            # misses every self-dive, which is why the Story screen's
            # "BEYOND OUR CONVERSATIONS" card never showed a report link.
            name = deep_dive.profile_full_name(db, uid)
            if not name:
                return None
            if not deep_dive.has_dive(db, uid, name=name):
                return None
            return deep_dive.dive_report_id(name=name) or None
    except Exception:  # noqa: BLE001 - a lookup failure just omits the link
        logger.exception(
            "story: skill report_id lookup failed for %s/%s", uid, page_id
        )
    return None


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
