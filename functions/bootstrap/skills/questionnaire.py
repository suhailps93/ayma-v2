"""Questionnaire tools — Ayma works through the tree-based deep-matchmaking
questionnaire (:mod:`question_tree`) conversationally, one node at a time.

* ``next_questions`` — the current top unanswered / partial nodes for the
  user's intent tree, so Ayma knows what to pursue next.
* ``record_answer`` — validate an answer against a node's kind/options and
  write it to ``users/{uid}/questionnaire/{node_id}``. Hard-filter answers are
  also mirrored, normalised, onto ``profile/main`` under a ``qz_{node_id}`` key
  so the deterministic matching filter can read them without re-parsing.
* ``set_relationship_intent`` — convenience wrapper for the routing node; it
  switches which branch of the tree is active.

Every write triggers a debounced background completeness recompute.
"""

from __future__ import annotations

import json
import re
from typing import Callable

from firebase_admin import firestore

import question_tree

from ._base import Skill, last_user_quote

_SOURCES = ("stated", "inferred")

# Founder directive, 2026-09-20: never let a pronoun/gender-identity value be
# guessed. Every other hard-filter node may be recorded as source="inferred"
# ("confidently infer one from what they said"), but gender_identity is
# identity-sensitive the same way physical_attributes.py treats a "stated"
# attribute as unimpeachable — it must come from the user actually saying it,
# never a model's read of their name, voice, or photo.
_NO_INFERENCE_IDS = frozenset({"gender_identity"})

_TRUE_WORDS = {
    "true", "yes", "y", "1", "yep", "yeah", "yup", "do", "does", "positive",
}
_FALSE_WORDS = {
    "false", "no", "n", "0", "nope", "nah", "none", "never", "don't", "dont",
}

_NEXT_LIMIT = 4

# A narrative answer must carry real substance to count as covered: a bare
# "yes", "fine" or "idk" would otherwise mark the node 100% answered while
# Ayma still knows nothing concrete.
_MIN_NARRATIVE_WORDS = 4


# --- value validation / normalisation --------------------------------------


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().casefold())


def _match_option(value: str, options: list[str]) -> str | None:
    v = _norm(value)
    if not v:
        return None
    for o in options:
        if _norm(o) == v:
            return o
    for o in options:
        oc = _norm(o)
        if v and (v in oc or oc in v):
            return o
    def _toks(s: str) -> set[str]:
        return {
            t.strip(",.;:!?()")
            for t in s.replace("/", " ").replace("-", " ").split()
            if len(t.strip(",.;:!?()")) > 2
        }

    def _overlap(a: set[str], b: set[str]) -> int:
        n = 0
        for x in a:
            for y in b:
                if x == y or (
                    len(x) >= 4 and len(y) >= 4 and (x[:4] == y[:4])
                ):
                    n += 1
                    break
        return n

    vt = _toks(v)
    best, best_n = None, 0
    for o in options:
        n = _overlap(vt, _toks(_norm(o)))
        if n > best_n:
            best, best_n = o, n
    return best if best_n else None


def _match_scale(value: str, scale: dict):
    v = _norm(value)
    lo, hi = int(scale["min"]), int(scale["max"])
    m = re.search(r"-?\d+", v)
    if m:
        n = int(m.group())
        return n if lo <= n <= hi else None
    if not v:
        return None
    if any(w in v for w in ("lowest", "minimum", "not at all", "bottom")):
        return lo
    if any(w in v for w in ("highest", "maximum", "completely", "top")):
        return hi
    if any(w in v for w in ("mid", "middle", "medium", "moderate", "balanced",
                            "average", "so-so", "in between")):
        return (lo + hi) // 2
    if "low" in v:
        return lo
    if "high" in v:
        return hi
    if _norm(scale["min_label"]) in v or v in _norm(scale["min_label"]):
        return lo
    if _norm(scale["max_label"]) in v or v in _norm(scale["max_label"]):
        return hi
    return None


def _match_bool(value: str):
    v = _norm(value)
    tokens = set(v.replace("-", " ").split())
    if tokens & _TRUE_WORDS or v in _TRUE_WORDS:
        return True
    if tokens & _FALSE_WORDS or v in _FALSE_WORDS:
        return False
    if "non smoker" in v or "doesn't" in v or "does not" in v:
        return False
    if "smok" in v or "vape" in v:
        return True
    return None


def _validate(node: dict, value: str):
    """``(ok, normalised, mirror_value, error)``. ``normalised`` is the string
    stored on the questionnaire doc; ``mirror_value`` is the deterministic value
    mirrored onto ``profile/main`` for a hard-filter node."""
    kind = node["kind"]
    raw = (value or "").strip()
    if kind == "narrative":
        # Only the open-ended story nodes (`*_narrative`); identity facts like
        # a first name or a city are legitimately one or two words.
        story = node["id"].endswith("_narrative")
        if not raw or (story and len(raw.split()) < _MIN_NARRATIVE_WORDS):
            return (
                False, None, None,
                "that's too thin to record - get the concrete specifics "
                "(who, what, how) from them first, in a full sentence or two",
            )
        return True, raw, raw, None
    if kind in ("enum",):
        opt = _match_option(raw, node["options"])
        if opt is None:
            return (
                False, None, None,
                f"'{value}' isn't one of: {', '.join(node['options'])}",
            )
        return True, opt, opt, None
    if kind == "multi":
        parts = re.split(r"\s*(?:,|;|/| and | & )\s*", raw)
        picked: list[str] = []
        for p in parts:
            opt = _match_option(p, node["options"])
            if opt and opt not in picked:
                picked.append(opt)
        if not picked:
            return (
                False, None, None,
                f"'{value}' didn't match any of: {', '.join(node['options'])}",
            )
        return True, ", ".join(picked), picked, None
    if kind == "scale":
        n = _match_scale(raw, node["scale"])
        if n is None:
            s = node["scale"]
            return (
                False, None, None,
                f"give a number {s['min']}-{s['max']} for that "
                f"({s['min_label']} … {s['max_label']})",
            )
        return True, str(n), int(n), None
    if kind == "bool":
        b = _match_bool(raw)
        if b is None:
            return False, None, None, "answer that one yes or no"
        return True, ("true" if b else "false"), bool(b), None
    return False, None, None, f"can't record a {kind} answer"


# --- shared write ---------------------------------------------------------


def _profile_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
    )


def _record(
    db, uid: str, node_id: str, value: str, source: str,
    *, session_id: str = "", turn_index: int = 0, turns: list | None = None,
) -> str:
    node = question_tree.node(node_id)
    if node is None:
        return f"no questionnaire item called '{node_id}'"
    src = source if source in _SOURCES else "stated"
    if node_id in _NO_INFERENCE_IDS and src == "inferred":
        return (
            "gender identity can only be recorded when the user actually "
            "states it — ask them directly instead of inferring it"
        )
    ok, normalised, mirror, err = _validate(node, value)
    if not ok:
        return err or "couldn't use that answer"

    doc = {
        "node_id": node_id,
        "value": normalised,
        "source": src,
        "confidence": "high" if src == "stated" else "low",
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    # Provenance (§ fact-source-of-truth, 2026-09-21): the verbatim user
    # message this answer came from, so `find_fact_source` can quote it back
    # instead of a generic "you told me". This doc is fully owned by one
    # node_id, so overwriting the whole `provenance` map on every call (no
    # partial-merge dance, unlike `profile/main`) is safe.
    quote = last_user_quote(turns)
    if quote:
        doc["provenance"] = {
            "source_type": "chat",
            "quote": quote,
            "session_id": session_id,
            "turn_index": turn_index,
            "at": firestore.SERVER_TIMESTAMP,
        }

    (
        db.collection("users")
        .document(uid)
        .collection("questionnaire")
        .document(node_id)
    ).set(doc, merge=True)

    profile_patch: dict = {}
    if node.get("hard_filter"):
        profile_patch[f"qz_{node_id}"] = mirror
    if node_id == "relationship_intent":
        profile_patch["relationship_intent"] = normalised
    if profile_patch:
        profile_patch["updated_at"] = firestore.SERVER_TIMESTAMP
        _profile_ref(db, uid).set(profile_patch, merge=True)

    try:
        import completeness

        completeness.schedule(db, uid)
    except Exception:  # noqa: BLE001 - best-effort, never fail the write
        pass

    tag = " (inferred)" if src == "inferred" else ""
    return f"recorded {node['label'].lower()}: {normalised}{tag}"


# --- next_questions -----------------------------------------------------------

_NEXT_DESCRIPTION = (
    "The questionnaire items still worth asking, highest priority first. "
    "Returns JSON: a short list of {id, label, kind, options, scale, "
    "ayma_prompt, weight, sensitive}."
)

_NEXT_DECLARATION = {
    "name": "next_questions",
    "description": _NEXT_DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}


def _bind_next(db, uid: str) -> Callable[..., str]:
    async def next_questions() -> str:
        import completeness

        res = await completeness.recompute(db, uid, force=True)
        nxt = (res or {}).get("next") or []
        keys = (
            "id", "label", "kind", "options", "scale", "ayma_prompt", "weight",
            "sensitive",
        )
        questions = [{k: q.get(k) for k in keys} for q in nxt[:_NEXT_LIMIT]]
        # Remember these were just offered so a still-unanswered one among
        # them (declined/deflected rather than recorded) doesn't monopolise
        # the top of the list on the very next call — see
        # completeness._OFFER_COOLDOWN_SECONDS for why.
        completeness.mark_offered(db, uid, [q["id"] for q in questions])
        return json.dumps({"questions": questions}, ensure_ascii=False)

    return next_questions


# --- record_answer ---------------------------------------------------------

_RECORD_DESCRIPTION = (
    "Record the user's answer to one questionnaire item the moment you have "
    "it. source='inferred' only for a hard-filter answer you're sure of; "
    "gender_identity must always be 'stated', never inferred."
)

_RECORD_DECLARATION = {
    "name": "record_answer",
    "description": _RECORD_DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "node_id": {
                "type": "string",
                "description": "item id from next_questions",
            },
            "value": {"type": "string"},
            "source": {
                "type": "string",
                "enum": list(_SOURCES),
            },
        },
        "required": ["node_id", "value", "source"],
    },
}


def _bind_record(
    db, uid: str, *, session_id: str = "", turn_index: int = 0,
    turns: list | None = None,
) -> Callable[..., str]:
    def record_answer(node_id: str, value: str, source: str = "stated") -> str:
        return _record(
            db, uid, node_id, value, source,
            session_id=session_id, turn_index=turn_index, turns=turns,
        )

    return record_answer


# --- set_relationship_intent --------------------------------------------------

_INTENT_DESCRIPTION = (
    "Set what relationship they're looking for — Casual, Long-term, Marriage "
    "or Not sure yet. Establish it early; it routes the questionnaire."
)

_INTENT_DECLARATION = {
    "name": "set_relationship_intent",
    "description": _INTENT_DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "intent": {"type": "string"}
        },
        "required": ["intent"],
    },
}


def _bind_intent(
    db, uid: str, *, session_id: str = "", turn_index: int = 0,
    turns: list | None = None,
) -> Callable[..., str]:
    def set_relationship_intent(intent: str) -> str:
        return _record(
            db, uid, "relationship_intent", intent, "stated",
            session_id=session_id, turn_index=turn_index, turns=turns,
        )

    return set_relationship_intent


SKILLS: list[Skill] = [
    Skill(declaration=_NEXT_DECLARATION, bind=_bind_next),
    Skill(declaration=_RECORD_DECLARATION, bind=_bind_record),
    Skill(declaration=_INTENT_DECLARATION, bind=_bind_intent),
]
