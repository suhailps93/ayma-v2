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

import node_visual

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

# --- graph redirect (person-graph authoritative) ---------------------------
# When PERSON_GRAPH_READS is on the wiki is frozen, so each skill page is homed
# as a stable emergent node ``emergent.skill.<page_type>`` instead; the grounding
# renderer maps that id back to the page_type for the context-diet filters. The
# compiled ``ai_body`` (the latest report / findings) is the node's answer, so
# the chat grounding and Your Story reads surface it exactly as the wiki page did.
_SKILL_SECTION = "misc"
_SKILL_VIS = {
    "web_findings": "private",
    "face_analysis": "private",
    "body_analysis": "private",
    "physical_profile": "private",
    "interactions": "ayma_only",
}


def _graph_reads_on() -> bool:
    from config import CONFIG

    return bool(CONFIG.person_graph_reads)


def _skill_node_id(page_type: str) -> str:
    return f"emergent.skill.{page_type}"


def _graph_upsert_skill(
    db, uid: str, page_type: str, ai_body: str, gist: str = "",
    visual: dict | None = None,
) -> None:
    """Upsert the compiled skill page as its graph node (idempotent by id). An
    earlier user promotion to public is preserved; ``interactions`` stays
    ayma_only always. ``gist`` is the node's short one-line headline (gist-first
    writing) and ``visual`` its write-time render pick; the long compiled body
    stays in the node answer."""
    import person_graph_store as store

    nid = _skill_node_id(page_type)
    vis = _SKILL_VIS.get(page_type, "private")
    if page_type != "interactions":
        cur = store.node_overlay_entry(db, uid, nid)
        if cur.get("visibility") and cur["visibility"] != "ai_only":
            vis = cur["visibility"]  # keep a prior promotion
    store.upsert_fact_node(
        db, uid, nid, ai_body,
        section=_SKILL_SECTION,
        visibility=vis,
        provenance="inferred",
        label=page_type.replace("_", " "),
        gist=(gist or None),
        visual=visual,
        source_kind="skill_memory", source_ref=page_type,
    )


def _page_ref(db, uid: str, page_type: str):
    return _page_ref_by_id(db, uid, _PAGES[page_type])


def _page_ref_by_id(db, uid: str, page_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(page_id)
    )


def _upsert(
    db, uid: str, page_type: str, ai_body: str, gist: str = "",
    visual: dict | None = None,
) -> None:
    ai_body = (ai_body or "").strip()
    if not uid or not ai_body:
        return
    if _graph_reads_on():
        try:
            _graph_upsert_skill(db, uid, page_type, ai_body, gist=gist, visual=visual)
        except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
            logger.exception("skill_memory: %s graph save failed for %s", page_type, uid)
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


# --- gist headlines (gist-first writing) ------------------------------------
# A node's one-line headline. The web digest emits its own `gist` (gist-first
# prompt); a report's gist is its short verdict line. Bounded so it stays a
# headline, never a paragraph. The long compiled body stays in the node answer.
_GIST_MAX = 100


def _clip_gist(text: str) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= _GIST_MAX else text[: _GIST_MAX - 1].rstrip() + "…"


def _web_findings_gist(digest: dict) -> str:
    d = digest or {}
    gist = str(d.get("gist", "")).strip()
    if gist:
        return _clip_gist(gist)
    name = str(d.get("name", "")).strip() or "this person"
    return _clip_gist(f"Web findings on {name}")


def _report_gist(report: dict, *, noun: str) -> str:
    r = report or {}
    verdict = str(r.get("verdict", "")).strip()
    note = str(r.get("verdict_note", "")).strip()
    head = verdict or f"{noun} read"
    if note:
        head = f"{head} — {note}"
    return _clip_gist(head)


# --- public API ------------------------------------------------------------


# --- web findings as per-element graph nodes (founder Nov 18) ---------------
#
# A web search no longer lands as ONE lump (the single ``emergent.skill.web_
# findings`` node that held the whole digest text). With the person-graph
# authoritative it lands as ONE SOURCE-TAGGED NODE PER FINDING — each summary
# sentence, each fact, each link, each social profile — so tapping a web finding
# opens THAT finding only, never the whole report. Every node carries where it
# came from (``source_kind="web_search"`` + the web link in ``source_ref``) and
# maps to the ``web_findings`` page_type (``emergent.webfind.*``) so grounding /
# persona keep grouping and filtering it exactly as the lump did. Flag OFF (prod)
# is unchanged: the wiki ``web-findings`` page lump is still written.

_WEBFIND_PREFIX = "emergent.webfind."
# ``emergent.webfind.report.*`` is the structured dive digest node (report_doc,
# non-rendering) — the per-element finding nodes must never collide with it.
_WEBFIND_REPORT_PREFIX = "emergent.webfind.report."


def _hash12(text: str) -> str:
    import hashlib

    return hashlib.sha1((text or "").encode("utf-8")).hexdigest()[:12]


def _fact_node_id(fact: dict) -> str:
    fid = str((fact or {}).get("id") or "").strip()
    if not fid:
        # Stable id derived from claim+category, mirroring ``deep_dive.fact_id``
        # (no import, to avoid a load-time cycle): position shifts once a fact is
        # disputed away, so never key on list index.
        claim = str((fact or {}).get("claim", "")).strip().lower()
        category = str((fact or {}).get("category", "")).strip().lower()
        fid = _hash12(f"{category}|{claim}")
    return f"{_WEBFIND_PREFIX}fact.{fid}"


def _web_finding_specs(digest: dict) -> list[tuple[str, str, str]]:
    """Split a deep-dive digest into ``(node_id, text, source_ref)`` per DISTINCT
    finding — summary sentences, facts, links, social profiles. Deterministic, no
    fabrication: every piece is lifted verbatim from the stored digest."""
    from report_blocks import split_sentences

    d = digest or {}
    specs: list[tuple[str, str, str]] = []

    # Summary — one node per sentence. A summary is a synthesis, so it has no one
    # link; it inherits the first fact's source as its best available citation.
    facts = [f for f in (d.get("facts") or []) if isinstance(f, dict)]
    summary_src = ""
    for f in facts:
        u = str(f.get("source_url") or "").strip()
        if u:
            summary_src = u
            break
    summary = str(d.get("summary") or "").strip()
    if summary:
        for i, sent in enumerate(split_sentences(summary)):
            sent = sent.strip()
            if sent:
                specs.append((f"{_WEBFIND_PREFIX}summary.{i}", sent, summary_src))

    # Facts — one node each, carrying the exact source url it was found at.
    for f in facts:
        claim = str(f.get("claim") or "").strip()
        if not claim:
            continue
        specs.append((_fact_node_id(f), claim, str(f.get("source_url") or "").strip()))

    # Links — one node each, the url itself is both the finding and the source.
    for ln in d.get("links") or []:
        if not isinstance(ln, dict):
            continue
        url = str(ln.get("url") or "").strip()
        if not url:
            continue
        title = str(ln.get("title") or "").strip() or url
        specs.append((f"{_WEBFIND_PREFIX}link.{_hash12(url)}", f"{title}: {url}", url))

    # Social profiles — one node each.
    for s in d.get("social_handles") or []:
        if not isinstance(s, dict):
            continue
        url = str(s.get("url") or "").strip()
        handle = str(s.get("handle") or "").strip()
        platform = str(s.get("platform") or "").strip()
        label = (
            f"@{handle}" if handle
            else (str(s.get("display_name") or "").strip() or platform)
        )
        key = url or f"{platform}:{handle}"
        if not key or not label:
            continue
        text = f"{label} ({platform})" if platform else label
        if url:
            text = f"{text}: {url}"
        specs.append((f"{_WEBFIND_PREFIX}social.{_hash12(key)}", text, url))

    return specs


def _graph_write_web_findings(db, uid: str, digest: dict) -> None:
    """Write the digest as per-element ``emergent.webfind.*`` nodes (replacing the
    old single ``emergent.skill.web_findings`` lump). Stale finding nodes from a
    prior dive are cleared first (the lump was overwritten wholesale — same
    semantics); the old lump node, if present, is removed. Each node keeps a
    prior user visibility promotion, defaults ``private``, and is deduped by
    normalized text within the batch (stable ids dedupe across re-runs)."""
    import person_graph_store as store

    specs = _web_finding_specs(digest)
    new_ids = {nid for nid, _, _ in specs}

    overlay = store.load_overlay(db, uid)
    stale = [
        nid
        for nid in overlay
        if nid.startswith(_WEBFIND_PREFIX)
        and not nid.startswith(_WEBFIND_REPORT_PREFIX)
        and nid not in new_ids
    ]
    stale.append(_skill_node_id("web_findings"))  # retire the legacy lump
    store.delete_nodes(db, uid, stale)

    seen: set[str] = set()
    for node_id, text, src in specs:
        norm = " ".join(text.casefold().split())
        if not norm or norm in seen:
            continue
        seen.add(norm)
        vis = "private"
        cur = store.node_overlay_entry(db, uid, node_id)
        if cur.get("visibility") and cur["visibility"] != "ai_only":
            vis = cur["visibility"]  # keep a prior promotion
        store.upsert_fact_node(
            db, uid, node_id, text,
            section=_SKILL_SECTION,
            visibility=vis,
            provenance="inferred",
            label="web finding",
            source_kind="web_search",
            source_ref=src,
        )


def save_web_findings(db, uid: str, digest: dict) -> None:
    """Record a deep-dive digest. Person-graph authoritative: ONE source-tagged
    node per finding (:func:`_graph_write_web_findings`). Flag OFF (prod): the
    unchanged ``web-findings`` wiki page lump."""
    if not uid:
        return
    if _graph_reads_on():
        try:
            _graph_write_web_findings(db, uid, digest or {})
        except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
            logger.exception("skill_memory: web_findings graph save failed for %s", uid)
        return
    gist = _web_findings_gist(digest or {})
    _upsert(
        db, uid, "web_findings",
        _web_findings_md(digest or {}),
        gist=gist,
        # A web-research finding renders as a card (headline + brief detail).
        visual=node_visual.card(title=gist, body=str((digest or {}).get("summary", "")).strip()),
    )


def migrate_web_findings(db, uid: str) -> int:
    """One-off: re-split a user's existing web-findings lump into per-element
    nodes, losslessly, from the LIVE stored digest — the most recent
    ``emergent.webfind.report.*`` dive node (the structured source the lump was
    rendered from). Deletes the legacy ``emergent.skill.web_findings`` lump.
    Returns the number of per-element finding nodes written (0 = nothing to
    migrate). Idempotent. Only meaningful with ``person_graph_reads`` ON."""
    import person_graph_store as store

    overlay = store.load_overlay(db, uid)
    reports = [
        (nid, e) for nid, e in overlay.items()
        if nid.startswith(_WEBFIND_REPORT_PREFIX) and isinstance(e, dict)
    ]
    if not reports:
        # Nothing structured to re-split — still retire the lump so it can't
        # linger as a competing render of the same findings.
        store.delete_nodes(db, uid, [_skill_node_id("web_findings")])
        return 0
    reports.sort(key=lambda r: str(r[1].get("updated_at") or ""), reverse=True)
    digest = (reports[0][1].get("answer") or {}).get("digest") or {}
    _graph_write_web_findings(db, uid, digest)
    return len(_web_finding_specs(digest))


def save_face_analysis(db, uid: str, report: dict) -> None:
    """Compile a face report into the ``face-analysis`` ``private`` page."""
    if not (report or {}).get("usable", True):
        return
    gist = _report_gist(report or {}, noun="Face")
    _upsert(
        db, uid, "face_analysis",
        _report_md(report or {}, kind="Facial-analysis", noun="face"),
        gist=gist,
        visual=node_visual.card(title=str((report or {}).get("verdict", "")).strip(),
                                body=str((report or {}).get("verdict_note", "")).strip()),
    )


def save_body_analysis(db, uid: str, report: dict) -> None:
    """Compile a body report into the ``body-analysis`` ``private`` page."""
    if not (report or {}).get("usable", True):
        return
    gist = _report_gist(report or {}, noun="Physique")
    _upsert(
        db, uid, "body_analysis",
        _report_md(report or {}, kind="Physique-analysis", noun="physique"),
        gist=gist,
        visual=node_visual.card(title=str((report or {}).get("verdict", "")).strip(),
                                body=str((report or {}).get("verdict_note", "")).strip()),
    )


def save_physical_profile(db, uid: str, body_md: str) -> None:
    """Upsert the structured physical-attributes rendering into the
    ``physical-profile`` page. Re-running replaces the body wholesale (never
    appends); defaults to ``private`` and keeps an explicitly-set visibility
    (e.g. promoted to ``public``). The caller passes an already-rendered,
    source-tagged markdown block."""
    first_line = next((ln.strip() for ln in (body_md or "").splitlines() if ln.strip()), "")
    gist = _clip_gist(first_line) if first_line else "Physical attributes"
    _upsert(
        db, uid, "physical_profile", body_md or "", gist=gist,
        visual=node_visual.card(title=gist, body=""),
    )


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
    """Prepend one short dated line to the user's ``interactions`` ``ai_only``
    wiki page. Used for breadcrumbs the next wiki ingest folds in — e.g. a
    non-self deep dive ("ran a deep dive on Jordan"). Reverse-chronological,
    capped at ``_INTERACTIONS_MAX_LINES`` (oldest dropped). Best-effort: a
    failure is logged, never raised. Visibility is always forced to
    ``ai_only`` here — Ayma's own behavioural inference about the user is
    never user-visible by default, regardless of any prior explicit value on
    the page (unlike the skill-report pages in this module, which do keep a
    user's own promotion choice)."""
    text = " ".join((text or "").split())
    if not uid or not text:
        return
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    line = f"- {stamp} — {text}"
    if _graph_reads_on():
        try:
            import person_graph_store as store

            cur = store.node_overlay_entry(db, uid, _skill_node_id("interactions"))
            prior = [
                ln.rstrip()
                for ln in str(cur.get("answer") or "").splitlines()
                if ln.strip().startswith("- ")
            ]
            lines = ([line] + prior)[:_INTERACTIONS_MAX_LINES]
            ai_body = _INTERACTIONS_HEADER + "\n\n" + "\n".join(lines)
            _graph_upsert_skill(db, uid, "interactions", ai_body)
        except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
            logger.exception("skill_memory: note_interaction graph save failed for %s", uid)
        return
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

        payload = {
            "ai_body": ai_body,
            "visibility": "ai_only",
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


def _entry_text(entry) -> str:
    """A history entry's rendered line, whichever shape it's in: a legacy
    plain string (every entry saved before photo references existed), or the
    current ``{"text", "photo"}`` dict."""
    return str(entry.get("text", "")) if isinstance(entry, dict) else str(entry)


def _entry_photo(entry) -> str:
    """A history entry's source-photo Storage path, or ``""`` — always ``""``
    for a legacy plain-string entry."""
    return str(entry.get("photo") or "") if isinstance(entry, dict) else ""


def _parse_scores(history: list) -> list[float]:
    """The numeric ``overall_score`` parsed out of every ``- date: N/10 —
    …`` history line (:func:`_report_one_liner`'s own format)."""
    out: list[float] = []
    for entry in history:
        m = _SCORE_RE.search(_entry_text(entry))
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


def _accumulated_body(latest_md: str, history: list) -> str:
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
            *[_entry_text(e) for e in history],
        ]
    return "\n".join(lines).strip()


def _merge_report(
    db, uid: str, page_type: str, report: dict, *, kind: str, noun: str
) -> None:
    """Accumulate a per-photo report into ``page_type``'s ``private`` page —
    a fresh "latest read" block plus a growing dated history, capped at
    ``_MERGE_CAP`` chars (oldest history lines dropped first). Each history
    entry is ``{"text": <one-liner>, "photo": <storage_path or "">}`` — the
    photo taken from ``report["source_photos"][0]`` when the engine supplied
    one — so a user browsing history can see which photo produced which read.
    A history entry saved before this field existed stays a plain string;
    :func:`_entry_text` / :func:`_entry_photo` read either shape. Skips an
    unusable report. Never raises."""
    if not uid or not (report or {}).get("usable", True):
        return
    if _graph_reads_on():
        # Graph home: store the latest compiled report as the node body. The
        # structured per-photo ``reads`` history + photo refs are a report-screen
        # feature the separate reports-as-views phase models as per-field
        # appearance nodes; here the latest read is what the grounding / story
        # read need.
        try:
            _graph_upsert_skill(
                db, uid, page_type, _report_md(report or {}, kind=kind, noun=noun)
            )
        except Exception:  # noqa: BLE001 - memory is best-effort, never fail a skill
            logger.exception("skill_memory: %s graph merge failed for %s", page_type, uid)
        return
    try:
        doc = _page_ref(db, uid, page_type)
        snap = doc.get()
        exists = getattr(snap, "exists", False)
        cur = (snap.to_dict() or {}) if exists else {}

        latest_md = _report_md(report or {}, kind=kind, noun=noun)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        history = [
            x for x in (cur.get("reads") or []) if _entry_text(x).strip()
        ]
        photos = (report or {}).get("source_photos") or []
        photo = str(photos[0] or "") if photos else ""
        history.append(
            {"text": _report_one_liner(report or {}, stamp), "photo": photo}
        )

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
    if _graph_reads_on():
        try:
            import person_graph_store as store

            nid = _skill_node_id(page_type)
            cur = store.node_overlay_entry(db, uid, nid)
            if not cur:
                return False
            if cur.get("visibility", "ai_only") == "ai_only":
                store.set_visibility(db, uid, nid, "private")
            return True
        except Exception:  # noqa: BLE001
            logger.exception("skill_memory: %s graph promote failed for %s", page_type, uid)
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
