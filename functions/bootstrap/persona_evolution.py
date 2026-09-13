"""Daily crowd-feedback aggregation → base-persona evolution (ARCHITECTURE.md
§15 Part B).

Separate from the real-time per-user loop (``feedback_ops.record`` → that
one user's ``steering`` wiki page, immediate, unreviewed — see
``feedback_ops.py``). This module runs once a day (``POST
/cron/persona-evolution``) and decides how the shared, generic
``lessons.md`` persona corrections should evolve based on what recurs across
*many* users:

1. **Aggregate** — pull ``feedback`` rows from a rolling window (default 7
   days: long enough for a real weekly cadence of feedback to accumulate
   evidence, short enough that a stale pattern doesn't keep re-proposing
   itself indefinitely) across every user, grouped by category.
2. **Propose** — one Gemini call, given that aggregate plus the *current
   effective* ``lessons.md`` (Firestore-backed, ``prompt.py``), asking for a
   structured proposal (see ``prompts/persona_evolution.md`` for the full
   instructions the model is given).
3. If the proposal is **critical** (the model's own judgement, biased toward
   caution per the founder: "when in doubt... wait for admin approval") — do
   not apply. Write a ``persona_change_proposals/{id}`` doc, ``status:
   "pending"``, and stop.
4. If **not critical** — run the automated eval gate (below). Pass → apply
   immediately to ``config/ayma_persona`` and log to ``persona_change_log``.
   Fail (a regression) → do not apply; write the same kind of proposal doc,
   ``status: "eval_failed"``, so a human can see what was tried.

Both proposal statuses land on the same admin review surface
(``GET/POST /admin/persona-changes*`` in ``main.py``) — approve applies the
exact same path a passing automated gate would have used; reject just marks
the doc, no side effects.

### The eval gate (v1 — a "good enough automated regression check", explicitly
not a research-grade eval harness): a small fixed set of scripted scenarios
(``persona_eval_scenarios.json``) covering the behaviours most likely to
regress. For each scenario, Ayma's reply is generated twice — once under the
current lessons content, once under the proposed one, otherwise identical
context — and a separate Gemini judge call scores whether the proposed reply
is a regression against the current one for that scenario specifically (see
``prompts/persona_eval_judge.md``). **Any single scenario scored as a
regression fails the whole gate** — deliberately not averaged away, matching
the same "when in doubt, hold" spirit as the critical classifier.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path

from firebase_admin import firestore

import gemini
import prompt as prompt_mod
import token_ledger
from transcript import Turn

logger = logging.getLogger("ayma.persona_evolution")

_DIR = Path(__file__).parent
_PROPOSE_PROMPT_PATH = _DIR / "prompts" / "persona_evolution.md"
_JUDGE_PROMPT_PATH = _DIR / "prompts" / "persona_eval_judge.md"
_SCENARIOS_PATH = _DIR / "persona_eval_scenarios.json"

# Rolling aggregation window — see module docstring for why 7 days.
WINDOW_DAYS = 7

_CONFIG_COLLECTION = "config"
_PERSONA_DOC = "ayma_persona"
_LESSONS_FIELD = "lessons_md"
_FEEDBACK_COLLECTION = "feedback"
_PROPOSALS_COLLECTION = "persona_change_proposals"
_LOG_COLLECTION = "persona_change_log"

# Feedback previews folded into the aggregate summary, per category — enough
# for the model to ground its proposal without shipping the whole window.
_EXAMPLES_PER_CATEGORY = 5

_PROPOSE_SCHEMA = {
    "type": "object",
    "properties": {
        "proposed_lessons_md": {"type": "string"},
        "summary": {"type": "string"},
        "rationale": {"type": "string"},
        "critical": {"type": "boolean"},
        "critical_reason": {"type": "string"},
    },
    "required": [
        "proposed_lessons_md", "summary", "rationale", "critical",
        "critical_reason",
    ],
}

_JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "regression": {"type": "boolean"},
        "reason": {"type": "string"},
    },
    "required": ["regression", "reason"],
}


def _load_propose_prompt() -> str:
    return _PROPOSE_PROMPT_PATH.read_text(encoding="utf-8").strip()


def _load_judge_prompt() -> str:
    return _JUDGE_PROMPT_PATH.read_text(encoding="utf-8").strip()


def load_eval_scenarios() -> list[dict]:
    data = json.loads(_SCENARIOS_PATH.read_text(encoding="utf-8"))
    return data.get("scenarios", [])


# --------------------------------------------------------------- config doc

def _config_doc(db):
    return db.collection(_CONFIG_COLLECTION).document(_PERSONA_DOC)


def current_lessons_md(db) -> str:
    """The full effective ``lessons.md`` content right now: the Firestore
    config doc's raw value if present, else the static seed file — the same
    source ``prompt.py`` composes prompts from, just unfiltered (comments
    included) so the model sees the file as a human would edit it."""
    try:
        snap = _config_doc(db).get()
        if snap.exists:
            value = (snap.to_dict() or {}).get(_LESSONS_FIELD)
            if isinstance(value, str) and value.strip():
                return value
    except Exception:  # noqa: BLE001 - config read must never crash the job
        logger.exception("persona_evolution: reading config/ayma_persona failed")
    return prompt_mod._static_lessons_seed()


def _apply_lessons(db, new_md: str) -> None:
    _config_doc(db).set(
        {_LESSONS_FIELD: new_md, "updated_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )


def _log_change(db, before: str, after: str, summary: str, eval_result: dict | None) -> None:
    db.collection(_LOG_COLLECTION).document().set({
        "lessons_md_before": before,
        "lessons_md_after": after,
        "summary": summary,
        "applied_at": firestore.SERVER_TIMESTAMP,
        "eval_result": eval_result,
    })


def _write_proposal(
    db,
    *,
    proposed_md: str,
    current_md: str,
    summary: str,
    rationale: str,
    critical_reason: str,
    based_on_feedback_count: int,
    status: str,
    eval_result: dict | None = None,
) -> str:
    doc = db.collection(_PROPOSALS_COLLECTION).document()
    payload = {
        "proposed_lessons_md": proposed_md,
        "current_lessons_md": current_md,
        "summary": summary,
        "rationale": rationale,
        "critical_reason": critical_reason,
        "based_on_feedback_count": based_on_feedback_count,
        "created_at": firestore.SERVER_TIMESTAMP,
        "status": status,
    }
    if eval_result is not None:
        payload["eval_result"] = eval_result
    doc.set(payload)
    return doc.id


# --------------------------------------------------------------- aggregate

def _recent_feedback(db, window_days: int = WINDOW_DAYS) -> list[dict]:
    cutoff = datetime.now(timezone.utc) - timedelta(days=window_days)
    try:
        snaps = (
            db.collection(_FEEDBACK_COLLECTION)
            .where("created_at", ">=", cutoff)
            .stream()
        )
    except Exception:  # noqa: BLE001 - the job must never crash on a bad query
        logger.exception("persona_evolution: feedback query failed")
        return []
    return [s.to_dict() or {} for s in snaps]


def summarize_feedback(rows: list[dict], window_days: int = WINDOW_DAYS) -> str:
    """Group ``rows`` by category into the aggregate text block the propose
    prompt reads: counts, distinct users, and a few example notes/quotes per
    category so the model has something concrete to ground a proposal in."""
    if not rows:
        return ""
    by_cat: dict[str, list[dict]] = {}
    for r in rows:
        by_cat.setdefault(r.get("category") or "other", []).append(r)

    lines = [
        f"Feedback from the last {window_days} days, {len(rows)} rows total "
        f"across {len({r.get('uid') for r in rows if r.get('uid')})} users:"
    ]
    for cat, items in sorted(by_cat.items(), key=lambda kv: -len(kv[1])):
        users = {i.get("uid") for i in items if i.get("uid")}
        lines.append(
            f"\n### {cat} — {len(items)} occurrences across {len(users)} users"
        )
        for item in items[:_EXAMPLES_PER_CATEGORY]:
            note = (item.get("note") or "").strip()
            quote = (item.get("quote") or "").strip()
            bits = [b for b in (note, f'"{quote}"' if quote else "") if b]
            if bits:
                lines.append("- " + " — ".join(bits))
    return "\n".join(lines)


# --------------------------------------------------------------- propose

async def _propose(aggregate_summary: str, current_md: str) -> dict:
    contents = (
        f"{aggregate_summary}\n\n"
        f"Current lessons.md content:\n{current_md or '(empty — no lessons yet)'}"
    )
    result = await gemini.generate_json(
        contents,
        system_prompt=_load_propose_prompt(),
        response_schema=_PROPOSE_SCHEMA,
        feature=token_ledger.FEATURE_PERSONA_EVOLUTION,
        enforce_cap=False,
    )
    return result if isinstance(result, dict) else {}


# --------------------------------------------------------------- eval gate

async def _scenario_reply(lessons_md: str, scenario: dict) -> str:
    history = [
        Turn(role=str(t.get("role", "")), text=str(t.get("text", "")))
        for t in scenario.get("history", [])
    ]
    system_prompt = prompt_mod.compose_system_prompt(
        recent_turns=history, lessons_md_override=lessons_md,
    )
    reply = await gemini.generate_reply(
        scenario["message"],
        system_prompt=system_prompt,
        feature=token_ledger.FEATURE_PERSONA_EVOLUTION,
    )
    return reply.text


async def _judge_scenario(
    scenario: dict, current_reply: str, proposed_reply: str
) -> dict:
    history_lines = "\n".join(
        f"{t.get('role')}: {t.get('text')}" for t in scenario.get("history", [])
    )
    contents = (
        f"Scenario focus: {scenario.get('focus', '')}\n\n"
        f"Conversation so far:\n{history_lines or '(none — opening message)'}\n"
        f"User's next message: {scenario.get('message', '')}\n\n"
        f"Current reply:\n{current_reply}\n\n"
        f"Proposed reply:\n{proposed_reply}"
    )
    result = await gemini.generate_json(
        contents,
        system_prompt=_load_judge_prompt(),
        response_schema=_JUDGE_SCHEMA,
        feature=token_ledger.FEATURE_PERSONA_EVOLUTION,
        enforce_cap=False,
    )
    return result if isinstance(result, dict) else {"regression": True, "reason": "unparseable judge response"}


async def run_eval_gate(current_md: str, proposed_md: str) -> dict:
    """Run every scripted scenario through both persona versions and judge
    each one. Returns ``{"passed": bool, "scenarios": [...]}`` — a single
    scenario judged a regression fails the whole gate (not averaged away)."""
    scenarios = load_eval_scenarios()
    results = []
    passed = True
    for scenario in scenarios:
        try:
            current_reply = await _scenario_reply(current_md, scenario)
            proposed_reply = await _scenario_reply(proposed_md, scenario)
            verdict = await _judge_scenario(scenario, current_reply, proposed_reply)
        except Exception:  # noqa: BLE001 - a scenario failing to run is not a
            # pass — conservative: treat it like a regression so a broken eval
            # never silently waves a change through.
            logger.exception(
                "persona_evolution: eval scenario %s failed", scenario.get("id")
            )
            results.append({
                "id": scenario.get("id"), "regression": True,
                "reason": "scenario failed to run", "error": True,
            })
            passed = False
            continue

        regression = bool(verdict.get("regression"))
        results.append({
            "id": scenario.get("id"),
            "regression": regression,
            "reason": verdict.get("reason", ""),
        })
        if regression:
            passed = False
    return {"passed": passed, "scenarios": results}


# --------------------------------------------------------------- daily run

async def run(db, window_days: int = WINDOW_DAYS) -> dict:
    """One full daily pass. Never raises — a failure is logged and reported
    in the returned dict so the cron caller still gets a 200."""
    try:
        rows = _recent_feedback(db, window_days)
        count = len(rows)
        if count == 0:
            return {"ran": True, "based_on_feedback_count": 0, "action": "no_feedback"}

        aggregate_summary = summarize_feedback(rows, window_days)
        current_md = current_lessons_md(db)
        proposal = await _propose(aggregate_summary, current_md)

        proposed_md = str(proposal.get("proposed_lessons_md") or "").strip()
        if not proposed_md or proposed_md == current_md.strip():
            return {
                "ran": True, "based_on_feedback_count": count,
                "action": "no_change_proposed",
            }

        summary = str(proposal.get("summary", ""))
        rationale = str(proposal.get("rationale", ""))
        critical = bool(proposal.get("critical"))
        critical_reason = str(proposal.get("critical_reason", ""))

        if critical:
            proposal_id = _write_proposal(
                db, proposed_md=proposed_md, current_md=current_md,
                summary=summary, rationale=rationale,
                critical_reason=critical_reason,
                based_on_feedback_count=count, status="pending",
            )
            return {
                "ran": True, "based_on_feedback_count": count,
                "action": "held_critical", "proposal_id": proposal_id,
            }

        eval_result = await run_eval_gate(current_md, proposed_md)
        if eval_result["passed"]:
            _apply_lessons(db, proposed_md)
            _log_change(db, current_md, proposed_md, summary, eval_result)
            return {
                "ran": True, "based_on_feedback_count": count,
                "action": "applied", "eval_result": eval_result,
            }

        proposal_id = _write_proposal(
            db, proposed_md=proposed_md, current_md=current_md,
            summary=summary, rationale=rationale,
            critical_reason=critical_reason,
            based_on_feedback_count=count, status="eval_failed",
            eval_result=eval_result,
        )
        return {
            "ran": True, "based_on_feedback_count": count,
            "action": "eval_failed", "proposal_id": proposal_id,
            "eval_result": eval_result,
        }
    except Exception:  # noqa: BLE001 - a cron job must never 500
        logger.exception("persona_evolution: daily run failed")
        return {"ran": False, "error": "persona_evolution run failed"}


# --------------------------------------------------------------- admin surface

def _sort_key(value):
    return value if value is not None else datetime.min.replace(tzinfo=timezone.utc)


def list_pending(db) -> list[dict]:
    """Every proposal awaiting admin attention (``pending`` or
    ``eval_failed``), most recent first."""
    out: list[dict] = []
    for status in ("pending", "eval_failed"):
        for snap in (
            db.collection(_PROPOSALS_COLLECTION)
            .where("status", "==", status)
            .stream()
        ):
            data = snap.to_dict() or {}
            data["id"] = snap.id
            out.append(data)
    out.sort(key=lambda d: _sort_key(d.get("created_at")), reverse=True)
    return out


def approve(db, proposal_id: str) -> bool:
    """Apply a pending/eval_failed proposal's ``proposed_lessons_md`` — same
    apply path the automated gate uses on a pass. Returns ``False`` if no such
    proposal exists."""
    doc = db.collection(_PROPOSALS_COLLECTION).document(proposal_id)
    snap = doc.get()
    if not snap.exists:
        return False
    data = snap.to_dict() or {}
    proposed_md = str(data.get("proposed_lessons_md") or "")
    current_md = current_lessons_md(db)
    _apply_lessons(db, proposed_md)
    _log_change(
        db, current_md, proposed_md, str(data.get("summary", "")),
        data.get("eval_result"),
    )
    doc.set(
        {"status": "approved", "reviewed_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )
    return True


def reject(db, proposal_id: str, reason: str = "") -> bool:
    """Mark a proposal rejected. No changes applied. Returns ``False`` if no
    such proposal exists."""
    doc = db.collection(_PROPOSALS_COLLECTION).document(proposal_id)
    snap = doc.get()
    if not snap.exists:
        return False
    payload = {"status": "rejected", "reviewed_at": firestore.SERVER_TIMESTAMP}
    reason = reason.strip()
    if reason:
        payload["reject_reason"] = reason[:1000]
    doc.set(payload, merge=True)
    return True
