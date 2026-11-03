"""``find_fact_source`` — answer "where did you get this from" (§ founder bug
report, 2026-09-21: asked Ayma where she got his child's name/daycare from —
in the Family section of his Story/Ayma's-notes report — and got a generic
"you told me" instead of the actual message/date).

Searches every place a fact can carry provenance (added alongside this tool,
see each module's own docstring for the write side):

* ``profile/main.provenance.{field}`` — ``set_profile_field`` (skills/
  set_profile_field.py): the verbatim user message a profile field was set
  from.
* ``questionnaire/{node_id}.provenance`` — ``record_answer`` /
  ``set_relationship_intent`` (skills/questionnaire.py): same, per node. A
  node recorded before this feature shipped has no ``provenance`` map but
  still has its recorded ``value`` — returned as a lower-confidence match
  (``"exact": false``) rather than nothing, since it IS what's on file, just
  not pinned to an exact message/time.
* ``wiki_pages/{page_id}.source_log`` — ``wiki_ingest.py``: the verbatim
  conversation excerpt behind the last few times that page's ``ai_body``
  (the Story / Ayma's-notes prose — the Family section lives here) actually
  changed. This is page-level, not sentence-level — Gemini synthesises the
  prose, so there's no reliable pointer to one exact sentence — but handing
  Ayma the real excerpt lets *her* judge and quote the right part, which is
  what actually fixes the bug report (a generic answer) without fabricating
  precision the system doesn't have.
* ``deep_dives/{key}.digest`` — ``deep_dive.py``: facts already carry a
  ``source_url`` each (this predates this change — deep dive was already
  doing this right), and links / social profiles / found photos carry
  their URL by construction, so every kind of web find comes back as a
  ``"web_search"`` match with the exact claim-or-title + URL (a photo
  traces to the page it was found on, not the image file).
* ``appearance_reports/current`` — ``appearance.py`` (``correct_finding``,
  reached via the ``correct_appearance_item`` tool): also predates this
  change and already did the right thing independently — a face/body
  correction stores the user's own text verbatim (``user_correction``), and
  every corrected finding's prior value keeps a truncated verbatim
  ``reason`` ("you corrected this: ...") + real timestamp in
  ``finding_history``. This just surfaces that existing data here too.

Every candidate is scored by simple keyword overlap against ``query`` and the
top few are returned; ``matches: []`` when nothing overlaps — Ayma is
instructed (persona.md) to say so honestly rather than invent a source.
"""

from __future__ import annotations

import re
from typing import Callable

from timefmt import iso_or_str
from ._base import Skill

_MAX_MATCHES = 6
_MIN_WORD_LEN = 3
_STOPWORDS = {
    "the", "and", "for", "that", "this", "with", "from", "your", "you",
    "did", "was", "were", "did", "get", "got", "where", "how", "know",
    "tell", "said", "about",
}


def _tokens(text: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", (text or "").lower())
    return {w for w in words if len(w) >= _MIN_WORD_LEN and w not in _STOPWORDS}


def _score(query_tokens: set[str], text: str) -> int:
    if not query_tokens:
        return 0
    return len(query_tokens & _tokens(text))



DESCRIPTION = (
    "Find the exact source of one fact about the user — ALWAYS call it "
    "before answering 'where did you get that / how do you know'. Returns "
    "the chat quote (+ when) or web URL + line; empty → say you have no record."
)

DECLARATION = {
    "name": "find_fact_source",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "the fact to trace (not the question)",
            }
        },
        "required": ["query"],
    },
}


def _profile_matches(db, uid: str, qtok: set[str]) -> list[dict]:
    out: list[dict] = []
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        data = snap.to_dict() or {} if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        return out
    provenance = data.get("provenance") or {}
    if not isinstance(provenance, dict):
        return out
    for field, prov in provenance.items():
        if not isinstance(prov, dict):
            continue
        quote = str(prov.get("quote") or "")
        value = str(data.get(field) or "")
        score = _score(qtok, f"{field} {value} {quote}")
        if score <= 0:
            continue
        out.append(
            {
                "type": "chat",
                "exact": True,
                "field": field,
                "current_value": value,
                "quote": quote,
                "when": iso_or_str(prov.get("at"), none=""),
                "_score": score,
            }
        )
    return out


def _questionnaire_matches(db, uid: str, qtok: set[str]) -> list[dict]:
    out: list[dict] = []
    try:
        import question_tree

        docs = (
            db.collection("users")
            .document(uid)
            .collection("questionnaire")
            .stream()
        )
    except Exception:  # noqa: BLE001
        return out
    for snap in docs:
        data = snap.to_dict() or {}
        value = str(data.get("value") or "")
        node = question_tree.node(snap.id) or {}
        label = str(node.get("label") or snap.id)
        prov = data.get("provenance") if isinstance(data.get("provenance"), dict) else None
        quote = str((prov or {}).get("quote") or "")
        score = _score(qtok, f"{label} {value} {quote}")
        if score <= 0:
            continue
        if prov:
            out.append(
                {
                    "type": "chat",
                    "exact": True,
                    "field": label,
                    "current_value": value,
                    "quote": quote,
                    "when": iso_or_str(prov.get("at"), none=""),
                    "_score": score,
                }
            )
        else:
            out.append(
                {
                    "type": "chat",
                    "exact": False,
                    "field": label,
                    "current_value": value,
                    "quote": "",
                    "when": iso_or_str(data.get("updated_at"), none=""),
                    "_score": score,
                }
            )
    return out


def _wiki_matches(db, uid: str, qtok: set[str]) -> list[dict]:
    out: list[dict] = []
    try:
        docs = (
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .stream()
        )
    except Exception:  # noqa: BLE001
        return out
    for snap in docs:
        data = snap.to_dict() or {}
        for entry in data.get("source_log") or []:
            if not isinstance(entry, dict):
                continue
            excerpt = str(entry.get("excerpt") or "")
            score = _score(qtok, f"{snap.id} {excerpt}")
            if score <= 0:
                continue
            out.append(
                {
                    "type": "chat",
                    "exact": True,
                    "field": snap.id,
                    "quote": excerpt,
                    "when": iso_or_str(entry.get("at"), none=""),
                    "_score": score,
                }
            )
    return out


def _deep_dive_matches(db, uid: str, qtok: set[str]) -> list[dict]:
    out: list[dict] = []
    try:
        docs = (
            db.collection("users")
            .document(uid)
            .collection("deep_dives")
            .stream()
        )
    except Exception:  # noqa: BLE001
        return out
    for snap in docs:
        data = snap.to_dict() or {}
        digest = data.get("digest") or {}
        if not isinstance(digest, dict):
            continue
        subject = str(digest.get("name") or "")
        when = iso_or_str(data.get("created_at"), none="")
        for fact in digest.get("facts") or []:
            if not isinstance(fact, dict):
                continue
            claim = str(fact.get("claim") or "")
            url = str(fact.get("source_url") or "")
            score = _score(qtok, f"{subject} {claim}")
            if score <= 0:
                continue
            out.append(
                {
                    "type": "web_search",
                    "exact": bool(url),
                    "field": subject,
                    "quote": claim,
                    "url": url,
                    "when": when,
                    "_score": score,
                }
            )
        # A find need not be a fact claim (§ J7: the PERSONAL WEBSITE find is
        # a plain web link) — the report's links, social profiles, and found
        # photos are just as traceable, and their URL is always present.
        for link in digest.get("links") or []:
            if not isinstance(link, dict):
                continue
            url = str(link.get("url") or "").strip()
            if not url:
                continue
            title = str(link.get("title") or "").strip() or url
            score = _score(qtok, f"{subject} {title} {url}")
            if score <= 0:
                continue
            out.append(
                {
                    "type": "web_search",
                    "exact": True,
                    "field": subject,
                    "quote": title,
                    "url": url,
                    "when": when,
                    "_score": score,
                }
            )
        for handle in digest.get("social_handles") or []:
            if not isinstance(handle, dict):
                continue
            url = str(handle.get("url") or "").strip()
            if not url:
                continue
            platform = str(handle.get("platform") or "").strip()
            name = str(handle.get("handle") or "").strip()
            label = (
                f"@{name} ({platform})".strip()
                if name
                else str(handle.get("display_name") or platform).strip()
            )
            score = _score(qtok, f"{subject} {platform} {name} {label} {url}")
            if score <= 0:
                continue
            out.append(
                {
                    "type": "web_search",
                    "exact": True,
                    "field": subject,
                    "quote": label or url,
                    "url": url,
                    "when": when,
                    "_score": score,
                }
            )
        for image in digest.get("web_images") or []:
            if not isinstance(image, dict):
                continue
            page = str(image.get("source_page") or "").strip()
            img_url = str(image.get("url") or "").strip()
            url = page or img_url
            if not url:
                continue
            caption = page or str(image.get("caption") or "").strip()
            score = _score(qtok, f"{subject} {caption} {img_url}")
            if score <= 0:
                continue
            out.append(
                {
                    "type": "web_search",
                    "exact": True,
                    "field": subject,
                    "quote": caption or "Photo found online",
                    "url": url,
                    "when": when,
                    "_score": score,
                }
            )
    return out


def _appearance_matches(db, uid: str, qtok: set[str]) -> list[dict]:
    """The Appearance report (face/body/attribute findings — the
    ``correct_appearance_item`` tool, ``appearance.correct_finding``) already
    keeps real provenance for a correction, independently of this feature:
    the face/body axes store the user's own correction text verbatim
    (``user_correction``), and every corrected finding's prior value is kept
    in ``finding_history`` with a truncated verbatim ``reason`` ("you
    corrected this: ...") plus a real ``changed_at_ms`` timestamp — see
    ``appearance.py::correct_finding`` / ``_push_finding_history``. This just
    surfaces that existing data through the same lookup."""
    out: list[dict] = []
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("appearance_reports")
            .document("current")
            .get()
        )
        data = snap.to_dict() or {} if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        return out
    if not data:
        return out

    for axis_key in ("face", "body"):
        axis = data.get(axis_key)
        if not isinstance(axis, dict):
            continue
        correction = str(axis.get("user_correction") or "").strip()
        if not correction:
            continue
        score = _score(qtok, f"{axis_key} {correction}")
        if score <= 0:
            continue
        out.append(
            {
                "type": "chat", "exact": True, "field": axis_key,
                "quote": correction, "when": "", "_score": score,
            }
        )

    history = data.get("finding_history") or {}
    if isinstance(history, dict):
        for field, entries in history.items():
            for entry in entries or []:
                if not isinstance(entry, dict):
                    continue
                reason = str(entry.get("reason") or "")
                prefix = "you corrected this: "
                if not reason.startswith(prefix):
                    continue
                score = _score(qtok, f"{field} {reason}")
                if score <= 0:
                    continue
                when = ""
                ms = entry.get("changed_at_ms")
                if isinstance(ms, (int, float)):
                    from datetime import datetime, timezone

                    when = datetime.fromtimestamp(
                        ms / 1000, tz=timezone.utc
                    ).isoformat()
                out.append(
                    {
                        "type": "chat", "exact": True, "field": field,
                        "quote": reason[len(prefix):],
                        "when": when, "_score": score,
                    }
                )
    return out


def _bind(db, uid: str) -> Callable[..., str]:
    def find_fact_source(query: str) -> str:
        import json

        qtok = _tokens(query)
        if not qtok:
            return "give me a short description of the fact to trace"
        matches = (
            _profile_matches(db, uid, qtok)
            + _questionnaire_matches(db, uid, qtok)
            + _wiki_matches(db, uid, qtok)
            + _deep_dive_matches(db, uid, qtok)
            + _appearance_matches(db, uid, qtok)
        )
        matches.sort(key=lambda m: m["_score"], reverse=True)
        for m in matches:
            m.pop("_score", None)
        top = matches[:_MAX_MATCHES]
        return json.dumps({"matches": top}, ensure_ascii=False)

    return find_fact_source


SKILL = Skill(declaration=DECLARATION, bind=_bind)
