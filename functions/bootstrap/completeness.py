"""Per-user profile-completeness engine for the tree-based questionnaire.

Scores how much of the user's intent-routed question tree
(:mod:`question_tree`) is answered — from the ``users/{uid}/questionnaire``
store, from derivable ``profile/main`` fields, and, for the open-ended narrative
nodes, from a single cached LLM pass over the user's wiki text.

The result is persisted to ``users/{uid}/profile/main.completeness`` (a map) and
surfaced by ``GET /completeness`` and ``GET /questionnaire``. :func:`recompute`
is the debounced entry point wired into the wiki-ingest tail, the questionnaire
skill, and ``set_profile_field``.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from datetime import datetime, timezone
from pathlib import Path

import gemini
import question_tree
import token_ledger
import wiki_query

logger = logging.getLogger("ayma.completeness")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "completeness_narrative.md"

# Debounce window for :func:`recompute` — a fresh result within this many
# seconds is returned as-is unless ``force=True``.
_DEBOUNCE_SECONDS = 60

# Node id → the ``profile/main`` field that already answers it (preboarding). A
# non-blank value there marks the node covered without a questionnaire entry.
_PROFILE_DERIVABLE = {
    "legal_first_name": "name",
    "date_of_birth": "birthdate",
    "gender_identity": "gender",
    "target_match_genders": "interested_in",
    "primary_location": "location",
}

_NARRATIVE_COVERAGE = {"covered": 1.0, "partial": 0.5, "missing": 0.0}

_PAGE_TYPE_LABELS = {
    "identity": "Identity & basics",
    "career": "Work & ambition",
    "family": "Family & kinship",
    "relationships": "Relationship style",
    "dealbreakers": "Dealbreakers",
    "values": "Values & beliefs",
    "personality": "Personality & temperament",
    "interests": "Interests",
    "lifestyle": "Daily life & habits",
    "goals": "Goals & timelines",
    "sensitive": "Private context",
    "steering": "How to talk to me",
    "web_findings": "From the web",
    "face_analysis": "Face analysis",
    "body_analysis": "Body analysis",
    "misc": "Other",
}

# How many highest-weight open nodes to surface as "do these next".
_NEXT_LIMIT = 6


def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _blank(v) -> bool:
    return v in (None, "", [], {})


def _stringify(v) -> str:
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    return str(v)


def _status(coverage: float) -> str:
    if coverage >= 1.0:
        return "covered"
    if coverage > 0.0:
        return "partial"
    return "missing"


def _age_seconds(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        ts = datetime.fromisoformat(iso)
    except (TypeError, ValueError):
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - ts).total_seconds()


# --- Firestore helpers ---------------------------------------------------------


def _profile_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
    )


def _profile(db, uid: str) -> dict:
    try:
        snap = _profile_ref(db, uid).get()
        return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001 - a read failure just yields no derivations
        logger.exception("completeness: profile read failed for %s", uid)
        return {}


def _questionnaire_store(db, uid: str) -> dict[str, dict]:
    try:
        out: dict[str, dict] = {}
        for snap in (
            db.collection("users")
            .document(uid)
            .collection("questionnaire")
            .stream()
        ):
            out[snap.id] = snap.to_dict() or {}
        return out
    except Exception:  # noqa: BLE001
        logger.exception("completeness: questionnaire read failed for %s", uid)
        return {}


def _read_completeness(db, uid: str) -> dict | None:
    prof = _profile(db, uid)
    val = prof.get("completeness")
    return val if isinstance(val, dict) else None


def _persist(db, uid: str, result: dict) -> None:
    try:
        _profile_ref(db, uid).set({"completeness": result}, merge=True)
    except Exception:  # noqa: BLE001
        logger.exception("completeness: persist failed for %s", uid)


# --- intent -----------------------------------------------------------------


def _resolve_intent(store: dict, profile: dict) -> tuple[str, bool]:
    """``(branch, explicitly_set)``. Branch is the routed
    :mod:`question_tree` branch; ``explicitly_set`` is False when the user has
    given no usable ``relationship_intent`` (unset or "Not sure yet")."""
    raw = (store.get("relationship_intent") or {}).get("value") or profile.get(
        "relationship_intent"
    )
    branch = question_tree.branch_for_intent(raw)
    explicitly_set = bool(
        raw and str(raw).strip().lower() not in ("", "not sure yet", "undecided")
    )
    return branch, explicitly_set


# --- narrative LLM pass (cached on the wiki hash) -----------------------------


def _cache_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("completeness_cache")
        .document("narrative")
    )


async def _run_narrative_llm(uid: str, wiki_text: str, topics: list[dict]) -> dict:
    schema = {
        "type": "object",
        "properties": {
            "assessments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "status": {
                            "type": "string",
                            "enum": ["covered", "partial", "missing"],
                        },
                    },
                    "required": ["id", "status"],
                },
            }
        },
        "required": ["assessments"],
    }
    contents = (
        "USER WIKI:\n"
        + wiki_text
        + "\n\nNARRATIVE TOPICS:\n"
        + json.dumps({"narrative_topics": topics}, ensure_ascii=False)
    )
    raw = await gemini.generate_json(
        contents,
        _prompt(),
        schema,
        uid=uid,
        feature=token_ledger.FEATURE_COMPLETENESS,
        enforce_cap=False,
        temperature=0.0,
    )
    wanted = {t["id"] for t in topics}
    out: dict[str, str] = {}
    for a in (raw or {}).get("assessments", []):
        if a.get("id") in wanted and a.get("status") in _NARRATIVE_COVERAGE:
            out[a["id"]] = a["status"]
    for t in topics:
        out.setdefault(t["id"], "missing")
    return out


async def _narrative_status(db, uid: str, targets: list[dict]) -> dict[str, str]:
    """``{node_id: "covered"|"partial"|"missing"}`` for the narrative nodes in
    ``targets``. Cached on ``users/{uid}/completeness_cache/narrative`` keyed by
    a hash of the wiki text + the target id set, so an unchanged wiki never
    re-hits Gemini."""
    if not targets:
        return {}
    topics = [
        {"id": n["id"], "label": n["label"], "ayma_prompt": n["ayma_prompt"]}
        for n in targets
    ]
    missing_all = {t["id"]: "missing" for t in topics}
    try:
        wiki_text = wiki_query.read_wiki_context(db, uid) or ""
    except Exception:  # noqa: BLE001
        logger.exception("completeness: wiki read failed for %s", uid)
        return missing_all
    key = hashlib.sha256(
        ("|".join(sorted(t["id"] for t in topics)) + "||" + wiki_text).encode(
            "utf-8"
        )
    ).hexdigest()

    ref = None
    try:
        ref = _cache_ref(db, uid)
        snap = ref.get()
        if getattr(snap, "exists", False):
            cached = snap.to_dict() or {}
            if cached.get("wiki_hash") == key and isinstance(
                cached.get("result"), dict
            ):
                return {t["id"]: cached["result"].get(t["id"], "missing") for t in topics}
    except Exception:  # noqa: BLE001
        logger.exception("completeness: narrative cache read failed for %s", uid)

    if not wiki_text.strip():
        result = dict(missing_all)
    else:
        try:
            result = await _run_narrative_llm(uid, wiki_text, topics)
        except Exception:  # noqa: BLE001 - best-effort; leave uncached so it retries
            logger.exception("completeness: narrative LLM pass failed for %s", uid)
            return dict(missing_all)

    if ref is not None:
        try:
            ref.set(
                {"wiki_hash": key, "result": result, "updated_at": _now_iso()},
                merge=True,
            )
        except Exception:  # noqa: BLE001
            logger.exception("completeness: narrative cache write failed for %s", uid)
    return result


# --- evaluation + scoring ---------------------------------------------------


async def _evaluate(db, uid: str) -> tuple[str, bool, list[dict]]:
    """``(branch, intent_set, evaluated)`` where each ``evaluated`` entry is
    ``{node, coverage, status, value, source}``."""
    profile = _profile(db, uid)
    store = _questionnaire_store(db, uid)
    branch, intent_set = _resolve_intent(store, profile)
    nodes = question_tree.nodes_for_intent(
        "nikah" if branch == "nikah" else branch
    )

    narrative_targets = [
        n
        for n in nodes
        if n["kind"] == "narrative"
        and n["id"] not in _PROFILE_DERIVABLE
        and n["id"] not in store
    ]
    narr = await _narrative_status(db, uid, narrative_targets)

    evaluated: list[dict] = []
    for n in nodes:
        nid = n["id"]
        deriv = _PROFILE_DERIVABLE.get(nid)
        if deriv and not _blank(profile.get(deriv)):
            cov, src, val = 1.0, "profile", _stringify(profile.get(deriv))
        elif nid in store:
            entry = store[nid]
            raw_src = str(entry.get("source") or "stated").lower()
            cov = 0.7 if raw_src == "inferred" else 1.0
            src = raw_src if raw_src in ("stated", "inferred") else "stated"
            val = entry.get("value")
        elif n["kind"] == "narrative":
            st = narr.get(nid, "missing")
            cov = _NARRATIVE_COVERAGE.get(st, 0.0)
            src = "wiki" if cov > 0 else None
            val = None
        else:
            cov, src, val = 0.0, None, None
        evaluated.append(
            {
                "node": n,
                "coverage": cov,
                "status": _status(cov),
                "value": val,
                "source": src,
            }
        )
    return branch, intent_set, evaluated


def _score(evaluated: list[dict]) -> int:
    total_w = sum(e["node"]["weight"] for e in evaluated)
    if not total_w:
        return 0
    got = sum(e["node"]["weight"] * e["coverage"] for e in evaluated)
    return round(100 * got / total_w)


def _sections(evaluated: list[dict]) -> list[dict]:
    order: list[str] = []
    groups: dict[str, list[dict]] = {}
    for e in evaluated:
        pt = e["node"]["page_type"]
        if pt not in groups:
            groups[pt] = []
            order.append(pt)
        groups[pt].append(e)
    out: list[dict] = []
    for pt in order:
        grp = groups[pt]
        w = sum(e["node"]["weight"] for e in grp)
        wc = sum(e["node"]["weight"] * e["coverage"] for e in grp)
        out.append(
            {
                "page_type": pt,
                "label": _PAGE_TYPE_LABELS.get(pt, pt.replace("_", " ").title()),
                "pct": round(100 * wc / w) if w else 0,
                "answered": sum(1 for e in grp if e["coverage"] >= 0.7),
                "total": len(grp),
            }
        )
    return out


def _next(evaluated: list[dict]) -> list[dict]:
    open_nodes = [
        (i, e)
        for i, e in enumerate(evaluated)
        if e["coverage"] < 1.0 and e["node"]["id"] not in _PROFILE_DERIVABLE
    ]
    open_nodes.sort(key=lambda t: (-t[1]["node"]["weight"], t[0]))
    picked = []
    for _, e in open_nodes[:_NEXT_LIMIT]:
        n = e["node"]
        picked.append(
            {
                "id": n["id"],
                "label": n["label"],
                "page_type": n["page_type"],
                "kind": n["kind"],
                "options": n["options"],
                "scale": n["scale"],
                "ayma_prompt": n["ayma_prompt"],
                "weight": n["weight"],
            }
        )
    return picked


def _summarise(branch: str, intent_set: bool, evaluated: list[dict]) -> dict:
    return {
        "score": _score(evaluated),
        "intent": branch,
        "intent_set": intent_set,
        "sections": _sections(evaluated),
        "next": _next(evaluated),
        "updated_at": _now_iso(),
    }


# --- public API -----------------------------------------------------------


async def compute(db, uid: str) -> dict:
    """Full recompute: evaluate every node in the user's intent tree, persist
    the summary to ``profile/main.completeness`` and return it."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    result = _summarise(branch, intent_set, evaluated)
    _persist(db, uid, result)
    return result


async def recompute(db, uid: str, *, force: bool = False) -> dict:
    """Debounced :func:`compute`. Returns the stored summary unchanged when it
    is younger than :data:`_DEBOUNCE_SECONDS`, unless ``force``."""
    if not db or not uid:
        return {}
    try:
        if not force:
            existing = _read_completeness(db, uid)
            if existing is not None:
                age = _age_seconds(existing.get("updated_at"))
                if age is not None and age < _DEBOUNCE_SECONDS:
                    return existing
        return await compute(db, uid)
    except Exception:  # noqa: BLE001 - runs as a background task; never propagate
        logger.exception("completeness: recompute failed for %s", uid)
        return {}


async def _safe_recompute(db, uid: str) -> None:
    try:
        await recompute(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("completeness: scheduled recompute failed for %s", uid)


def schedule(db, uid: str) -> bool:
    """Fire-and-forget a debounced recompute on the running loop. Returns False
    (a no-op) when there is no loop — e.g. a synchronous unit test."""
    if not db or not uid:
        return False
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return False
    loop.create_task(_safe_recompute(db, uid))
    return True


async def get_or_recompute(db, uid: str) -> dict:
    """The cached summary, recomputing when it is absent or stale."""
    existing = _read_completeness(db, uid)
    if existing is not None:
        age = _age_seconds(existing.get("updated_at"))
        if age is not None and age < _DEBOUNCE_SECONDS:
            return existing
    return await compute(db, uid)


async def questionnaire_view(db, uid: str) -> dict:
    """``{intent, intent_set, score, nodes: [{...node..., status, value,
    source}]}`` for the user's intent tree — backs ``GET /questionnaire``."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    return {
        "intent": branch,
        "intent_set": intent_set,
        "score": _score(evaluated),
        "nodes": [
            {
                **e["node"],
                "status": e["status"],
                "value": e["value"],
                "source": e["source"],
            }
            for e in evaluated
        ],
    }


async def backfill(db, user_limit: int = 200) -> dict:
    """Force-recompute completeness for up to ``user_limit`` users that have a
    ``profile/main`` doc. Never raises."""
    out = {"users": 0, "recomputed": 0, "errors": 0}
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("completeness backfill: user scan failed")
        return out
    for snap in users:
        if out["users"] >= user_limit:
            break
        uid = snap.id
        try:
            prof = _profile_ref(db, uid).get()
            if not getattr(prof, "exists", False):
                continue
            out["users"] += 1
            await recompute(db, uid, force=True)
            out["recomputed"] += 1
        except Exception:  # noqa: BLE001
            logger.exception("completeness backfill failed for %s", uid)
            out["errors"] += 1
    return out
