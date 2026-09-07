"""Skill results saved to Ayma's private memory (§ skill memory).

Every run of ``deep_dive`` / ``face_report`` / ``body_report`` — whether the
chat skill or the REST endpoint — compiles its findings into an ``ai_only``
wiki page. Ayma then carries the finding in context on every future turn
(``read_wiki_context`` feeds every ``ai_only`` page into the prompt) WITHOUT it
showing up in the user's own wiki views until they ask for it via
``POST /wiki/promote``.

Pages, one per finding kind, upserted in place:

* ``web-findings``  — ``page_type="web_findings"``  — the deep-dive digest
* ``face-analysis`` — ``page_type="face_analysis"`` — a facial-analysis report
* ``body-analysis`` — ``page_type="body_analysis"`` — a physique report

All writes are best-effort: a failure is logged, never raised. ``created_at``
is kept on re-run and ``updated_at`` refreshed; a page the user has already
promoted (visibility no longer ``ai_only``) keeps its visibility on re-run.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from firebase_admin import firestore

logger = logging.getLogger("ayma.skillmemory")

# Auto-analysis (§ auto analysis) MERGES successive per-photo reads into the
# face / body pages instead of overwriting: a "latest read" block plus a short
# dated history of prior reads. The accumulated ``ai_body`` is capped here,
# oldest history lines dropped first.
_MERGE_CAP = 4000

# page_type -> wiki page_id
_PAGES: dict[str, str] = {
    "web_findings": "web-findings",
    "face_analysis": "face-analysis",
    "body_analysis": "body-analysis",
}

PROMOTABLE: frozenset[str] = frozenset(_PAGES)


def _page_ref(db, uid: str, page_type: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(_PAGES[page_type])
    )


def _upsert(db, uid: str, page_type: str, ai_body: str) -> None:
    ai_body = (ai_body or "").strip()
    if not uid or not ai_body:
        return
    try:
        doc = _page_ref(db, uid, page_type)
        snap = doc.get()
        exists = getattr(snap, "exists", False)
        cur = (snap.to_dict() or {}) if exists else {}
        # Default to ai_only; if the user already promoted the page, keep the
        # visibility they chose.
        visibility = "ai_only"
        if exists and cur.get("visibility") and cur["visibility"] != "ai_only":
            visibility = cur["visibility"]
        payload = {
            "ai_body": ai_body,
            "visibility": visibility,
            "page_type": page_type,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if not exists:
            payload["created_at"] = firestore.SERVER_TIMESTAMP
        doc.set(payload, merge=True)
    except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
        logger.exception(
            "skill_memory: %s save failed for %s", page_type, uid
        )


# --- compilers ---------------------------------------------------------------


def _web_findings_md(digest: dict) -> str:
    d = digest or {}
    name = str(d.get("name", "")).strip() or "this person"
    conf = str(d.get("confidence", "")).strip() or "unknown"
    lines = [
        f"What the open web says about {name} — gathered by Ayma in a "
        f"consented lookup, not stated by the user. Overall confidence: "
        f"{conf}.",
    ]
    summary = str(d.get("summary", "")).strip()
    if summary:
        lines += ["", summary]

    facts = [f for f in (d.get("facts") or []) if isinstance(f, dict)]
    if facts:
        lines += ["", "Facts found:"]
        for f in facts:
            claim = str(f.get("claim", "")).strip()
            if not claim:
                continue
            cat = str(f.get("category", "")).strip()
            src = str(f.get("source_url", "")).strip()
            fc = str(f.get("confidence", "")).strip()
            tail = ", ".join(x for x in (cat, fc, src) if x)
            lines.append(f"- {claim}" + (f" ({tail})" if tail else ""))

    links = [ln for ln in (d.get("links") or []) if isinstance(ln, dict)]
    links = [ln for ln in links if str(ln.get("url", "")).strip()]
    if links:
        lines += ["", "Links:"]
        for ln in links:
            url = str(ln["url"]).strip()
            title = str(ln.get("title", "")).strip() or url
            tag = str(ln.get("is_them", "")).strip() or "unclear"
            lines.append(f"- {title} ({tag}): {url}")

    caveats = str(d.get("caveats", "")).strip()
    if caveats:
        lines += ["", f"Caveats: {caveats}"]
    return "\n".join(lines).strip()


def _report_md(report: dict, *, kind: str, noun: str) -> str:
    r = report or {}
    score = r.get("overall_score", 0)
    verdict = str(r.get("verdict", "")).strip()
    head = (
        f"{kind} notes from a photo the user shared — Ayma's honest read, "
        f"not stated by the user. Overall {score}/10"
        + (f" — {verdict}." if verdict else ".")
    )
    lines = [head]
    note = str(r.get("verdict_note", "")).strip()
    if note:
        lines.append(note)

    feats = [f for f in (r.get("features") or []) if isinstance(f, dict)]
    if feats:
        lines += ["", "Feature scores:"]
        for f in feats:
            fn = str(f.get("name", "")).strip()
            if not fn:
                continue
            fnote = str(f.get("note", "")).strip()
            lines.append(
                f"- {fn}: {f.get('score', 0)}/10"
                + (f" — {fnote}" if fnote else "")
            )

    qf = r.get("quick_facts")
    if isinstance(qf, dict) and qf:
        pairs = "; ".join(
            f"{k}: {v}" for k, v in qf.items() if str(v).strip()
        )
        if pairs:
            lines += ["", f"Quick facts: {pairs}"]

    for label, key in (("Strengths", "strengths"), ("Improvements", "improvements")):
        items = [str(x).strip() for x in (r.get(key) or []) if str(x).strip()]
        if items:
            lines += ["", f"{label}:"]
            lines += [f"- {x}" for x in items]

    recos = [x for x in (r.get("recommendations") or []) if isinstance(x, dict)]
    if recos:
        lines += ["", "Recommendations:"]
        for x in recos:
            text = str(x.get("text", "")).strip()
            if not text:
                continue
            cat = str(x.get("category", "")).strip()
            lines.append(f"- " + (f"[{cat}] " if cat else "") + text)

    return "\n".join(lines).strip()


# --- public API ------------------------------------------------------------


def save_web_findings(db, uid: str, digest: dict) -> None:
    """Compile a deep-dive digest into the ``web-findings`` ``ai_only`` page."""
    _upsert(db, uid, "web_findings", _web_findings_md(digest or {}))


def save_face_analysis(db, uid: str, report: dict) -> None:
    """Compile a face report into the ``face-analysis`` ``ai_only`` page."""
    if not (report or {}).get("usable", True):
        return
    _upsert(
        db, uid, "face_analysis",
        _report_md(report or {}, kind="Facial-analysis", noun="face"),
    )


def save_body_analysis(db, uid: str, report: dict) -> None:
    """Compile a body report into the ``body-analysis`` ``ai_only`` page."""
    if not (report or {}).get("usable", True):
        return
    _upsert(
        db, uid, "body_analysis",
        _report_md(report or {}, kind="Physique-analysis", noun="physique"),
    )


def _report_one_liner(report: dict, stamp: str) -> str:
    """A single dated history line for a merged report page."""
    r = report or {}
    score = r.get("overall_score", 0)
    verdict = str(r.get("verdict", "")).strip()
    note = str(r.get("verdict_note", "")).strip()
    line = f"- {stamp}: {score}/10" + (f" — {verdict}" if verdict else "")
    if note:
        line += f" ({note})"
    return line


def _accumulated_body(latest_md: str, history: list[str]) -> str:
    lines = ["Latest read:", "", latest_md.strip()]
    if history:
        lines += [
            "",
            "Earlier reads from other photos of the user (oldest first):",
            *history,
        ]
    return "\n".join(lines).strip()


def _merge_report(
    db, uid: str, page_type: str, report: dict, *, kind: str, noun: str
) -> None:
    """Accumulate a per-photo report into ``page_type``'s ``ai_only`` page —
    a fresh "latest read" block plus a growing dated history, capped at
    ``_MERGE_CAP`` chars (oldest history lines dropped first). Skips an
    unusable report. Never raises."""
    if not uid or not (report or {}).get("usable", True):
        return
    try:
        doc = _page_ref(db, uid, page_type)
        snap = doc.get()
        exists = getattr(snap, "exists", False)
        cur = (snap.to_dict() or {}) if exists else {}

        latest_md = _report_md(report or {}, kind=kind, noun=noun)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        history = [
            str(x) for x in (cur.get("reads") or []) if str(x).strip()
        ]
        history.append(_report_one_liner(report or {}, stamp))

        ai_body = _accumulated_body(latest_md, history)
        while len(ai_body) > _MERGE_CAP and len(history) > 1:
            history.pop(0)
            ai_body = _accumulated_body(latest_md, history)
        if len(ai_body) > _MERGE_CAP:
            ai_body = ai_body[:_MERGE_CAP].rstrip()

        visibility = "ai_only"
        if exists and cur.get("visibility") and cur["visibility"] != "ai_only":
            visibility = cur["visibility"]

        payload = {
            "ai_body": ai_body,
            "reads": history,
            "visibility": visibility,
            "page_type": page_type,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if not exists:
            payload["created_at"] = firestore.SERVER_TIMESTAMP
        doc.set(payload, merge=True)
    except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
        logger.exception(
            "skill_memory: %s merge failed for %s", page_type, uid
        )


def merge_face_analysis(db, uid: str, report: dict) -> None:
    """Accumulate an auto-analysis face report into the ``face-analysis`` page
    (§ auto analysis) — updates rather than overwrites as more photos arrive."""
    _merge_report(
        db, uid, "face_analysis", report or {},
        kind="Facial-analysis", noun="face",
    )


def merge_body_analysis(db, uid: str, report: dict) -> None:
    """Accumulate an auto-analysis body report into the ``body-analysis`` page
    (§ auto analysis) — updates rather than overwrites as more photos arrive."""
    _merge_report(
        db, uid, "body_analysis", report or {},
        kind="Physique-analysis", noun="physique",
    )


def promote(db, uid: str, page_type: str) -> bool:
    """Flip a skill-memory page from ``ai_only`` to ``private`` so it shows in
    the user's own private story. Returns ``False`` if ``page_type`` is not a
    skill-memory type or the page does not exist; ``True`` once it is (or was
    already) visible."""
    if page_type not in _PAGES:
        return False
    try:
        doc = _page_ref(db, uid, page_type)
        snap = doc.get()
        if not getattr(snap, "exists", False):
            return False
        cur = snap.to_dict() or {}
        if cur.get("visibility", "ai_only") == "ai_only":
            doc.set(
                {
                    "visibility": "private",
                    "updated_at": firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )
        return True
    except Exception:  # noqa: BLE001
        logger.exception("skill_memory: promote %s failed for %s", page_type, uid)
        return False
