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
* ``deep_dives/{key}.digest.facts`` — ``deep_dive.py``: already carries a
  ``source_url`` per fact (this predates this change — deep dive was already
  doing this right), so those come back as ``"web_search"`` matches with the
  exact claim + URL.

Every candidate is scored by simple keyword overlap against ``query`` and the
top few are returned; ``matches: []`` when nothing overlaps — Ayma is
instructed (persona.md) to say so honestly rather than invent a source.
"""

from __future__ import annotations

import re
from typing import Callable

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


def _iso(ts) -> str:
    if ts is None:
        return ""
    for attr in ("isoformat",):
        fn = getattr(ts, attr, None)
        if callable(fn):
            try:
                return fn()
            except Exception:  # noqa: BLE001
                pass
    return str(ts)


DESCRIPTION = (
    "Look up the exact source of one specific fact in the user's profile, "
    "questionnaire answers, or Story/Ayma's-notes when they ask something "
    "like 'where did you get this from' / 'who told you that' / 'how do you "
    "know that'. Pass a short description of the fact itself (e.g. \"my "
    "son's name\", \"the daycare\", \"my job title\") — not the question. "
    "Returns the specific chat quote (with roughly when it was said) or web "
    "source (URL + the exact line) behind it, or an empty list if nothing "
    "on file supports it — in which case say honestly you don't have a "
    "record of the exact source. Never answer a 'where did you get this "
    "from' question without calling this first."
)

DECLARATION = {
    "name": "find_fact_source",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "a short description of the fact to trace, in your own "
                    "words — e.g. 'son's name and daycare', 'current job'"
                ),
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
                "when": _iso(prov.get("at")),
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
                    "when": _iso(prov.get("at")),
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
                    "when": _iso(data.get("updated_at")),
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
                    "when": _iso(entry.get("at")),
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
                    "when": _iso(data.get("created_at")),
                    "_score": score,
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
        )
        matches.sort(key=lambda m: m["_score"], reverse=True)
        for m in matches:
            m.pop("_score", None)
        top = matches[:_MAX_MATCHES]
        return json.dumps({"matches": top}, ensure_ascii=False)

    return find_fact_source


SKILL = Skill(declaration=DECLARATION, bind=_bind)
