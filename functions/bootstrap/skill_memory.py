"""Skill results saved to Ayma's private memory (§ skill memory).

Every run of ``deep_dive`` / ``face_report`` / ``body_report`` — whether the
chat skill or the REST endpoint — compiles its findings into a ``private``
wiki page: visible to the owning user in their own story, never to anyone
else. It's the user's own photo or the user's own lookup request, so it
belongs to them like any other story content — it's just not part of the
shareable public profile.

Pages, one per finding kind, upserted in place:

* ``web-findings``  — ``page_type="web_findings"``  — the deep-dive digest
* ``face-analysis`` — ``page_type="face_analysis"`` — a facial-analysis report
* ``body-analysis`` — ``page_type="body_analysis"`` — a physique report
* ``physical-profile`` — ``page_type="physical_profile"`` — the structured
  physical-attributes record (:func:`save_physical_profile`)

All writes are best-effort: a failure is logged, never raised. ``created_at``
is kept on re-run and ``updated_at`` refreshed; a page whose visibility has
already been explicitly promoted away from the code default (e.g. to
``public``) keeps that choice on re-run. A legacy page still carrying the old
``ai_only`` default gets bumped up to ``private`` on its next write.
"""

from __future__ import annotations

import logging
import re
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
    "physical_profile": "physical-profile",
}

PROMOTABLE: frozenset[str] = frozenset(_PAGES)


def _page_ref(db, uid: str, page_type: str):
    return _page_ref_by_id(db, uid, _PAGES[page_type])


def _page_ref_by_id(db, uid: str, page_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(page_id)
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
        # Default to private (visible to the owning user, not to anyone
        # else); if the page's visibility was explicitly set to something
        # else (e.g. promoted to public), keep that choice.
        visibility = "private"
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
    """Compile a deep-dive digest into the ``web-findings`` ``private`` page."""
    _upsert(db, uid, "web_findings", _web_findings_md(digest or {}))


def save_face_analysis(db, uid: str, report: dict) -> None:
    """Compile a face report into the ``face-analysis`` ``private`` page."""
    if not (report or {}).get("usable", True):
        return
    _upsert(
        db, uid, "face_analysis",
        _report_md(report or {}, kind="Facial-analysis", noun="face"),
    )


def save_body_analysis(db, uid: str, report: dict) -> None:
    """Compile a body report into the ``body-analysis`` ``private`` page."""
    if not (report or {}).get("usable", True):
        return
    _upsert(
        db, uid, "body_analysis",
        _report_md(report or {}, kind="Physique-analysis", noun="physique"),
    )


def save_physical_profile(db, uid: str, body_md: str) -> None:
    """Upsert the structured physical-attributes rendering into the
    ``physical-profile`` page. Re-running replaces the body wholesale (never
    appends); defaults to ``private`` and keeps an explicitly-set visibility
    (e.g. promoted to ``public``). The caller passes an already-rendered,
    source-tagged markdown block."""
    _upsert(db, uid, "physical_profile", body_md or "")


# --- interactions log ------------------------------------------------------

# The `interactions` wiki page: a dated log of what the USER did with Ayma
# (deep dives run, profiles asked about, matches pursued) and the preference it
# hints at — never another person's biography. Newest line first, capped.
_INTERACTIONS_PAGE_ID = "interactions"
_INTERACTIONS_MAX_LINES = 15
_INTERACTIONS_HEADER = (
    "Things the user did with Ayma and what it suggests about them — a dated "
    "log of the user's own behaviour, newest first. Not biographies of other "
    "people."
)


def note_interaction(db, uid: str, text: str, *, stamp: str | None = None) -> None:
    """Prepend one short dated line to the user's ``interactions`` ``private``
    wiki page. Used for breadcrumbs the next wiki ingest folds in — e.g. a
    non-self deep dive ("ran a deep dive on Jordan"). Reverse-chronological,
    capped at ``_INTERACTIONS_MAX_LINES`` (oldest dropped). Best-effort: a
    failure is logged, never raised. Keeps an explicitly-set visibility if the
    page's visibility was already changed to something else (e.g. ``public``)."""
    text = " ".join((text or "").split())
    if not uid or not text:
        return
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    line = f"- {stamp} — {text}"
    try:
        doc = _page_ref_by_id(db, uid, _INTERACTIONS_PAGE_ID)
        snap = doc.get()
        exists = getattr(snap, "exists", False)
        cur = (snap.to_dict() or {}) if exists else {}
        prior = [
            ln.rstrip()
            for ln in (cur.get("ai_body") or "").splitlines()
            if ln.strip().startswith("- ")
        ]
        lines = ([line] + prior)[:_INTERACTIONS_MAX_LINES]
        ai_body = _INTERACTIONS_HEADER + "\n\n" + "\n".join(lines)

        visibility = "private"
        if exists and cur.get("visibility") and cur["visibility"] != "ai_only":
            visibility = cur["visibility"]

        payload = {
            "ai_body": ai_body,
            "visibility": visibility,
            "page_type": "interactions",
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if not exists:
            payload["created_at"] = firestore.SERVER_TIMESTAMP
        doc.set(payload, merge=True)
    except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
        logger.exception("skill_memory: note_interaction failed for %s", uid)


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


_SCORE_RE = re.compile(r":\s*(-?\d+(?:\.\d+)?)\s*/\s*10\b")


def _parse_scores(history: list[str]) -> list[float]:
    """The numeric ``overall_score`` parsed out of every ``- date: N/10 —
    …`` history line (:func:`_report_one_liner`'s own format)."""
    out: list[float] = []
    for line in history:
        m = _SCORE_RE.search(line)
        if not m:
            continue
        try:
            out.append(float(m.group(1)))
        except ValueError:
            continue
    return out


def _median(scores: list[float]) -> float:
    s = sorted(scores)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


def _format_score(score: float) -> str:
    return f"{score:g}" if score == int(score) else f"{score:.1f}"


def _accumulated_body(latest_md: str, history: list[str]) -> str:
    lines: list[str] = []
    scores = _parse_scores(history)
    if scores:
        median = _median(scores)
        n = len(scores)
        lines += [
            f"Overall: {_format_score(median)}/10 (median across {n} "
            f"read{'s' if n != 1 else ''}) — the headline score below is a "
            "running median across every photo analysed so far, not just "
            "this one.",
            "",
        ]
    lines += ["Latest read:", "", latest_md.strip()]
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
    """Accumulate a per-photo report into ``page_type``'s ``private`` page —
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

        visibility = "private"
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
