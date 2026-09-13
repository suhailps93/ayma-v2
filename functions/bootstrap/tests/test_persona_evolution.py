import asyncio
from datetime import datetime, timezone

import persona_evolution
import prompt as prompt_mod


def _run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------- fake db ---
class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _Query:
    def __init__(self, store, path, docs=None):
        self._store, self._path, self._docs = store, path, docs

    def _all(self):
        if self._docs is not None:
            return self._docs
        depth = len(self._path)
        return [
            _Snap(k[-1], v) for k, v in self._store.docs.items()
            if len(k) == depth + 1 and k[:depth] == self._path
        ]

    def where(self, field, op, value):
        docs = self._all()
        if op == "==":
            hit = [d for d in docs if d.to_dict().get(field) == value]
        elif op == ">=":
            hit = [d for d in docs if d.to_dict().get(field) >= value]
        else:  # pragma: no cover - not exercised by this module
            raise NotImplementedError(op)
        return _Query(self._store, self._path, docs=hit)

    def stream(self):
        return list(self._all())


class _DocRef:
    def __init__(self, store, path):
        self._store, self._path = store, path

    @property
    def id(self):
        return self._path[-1]

    def get(self):
        return _Snap(self._path[-1], self._store.docs.get(self._path))

    def set(self, payload, merge=False):
        cur = dict(self._store.docs.get(self._path) or {}) if merge else {}
        cur.update(payload)
        self._store.docs[self._path] = cur

    def collection(self, name):
        return _ColRef(self._store, self._path + (name,))


class _ColRef(_Query):
    def __init__(self, store, path):
        super().__init__(store, path)
        self._n = 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._n += 1
            doc_id = f"auto-{self._n}"
        return _DocRef(self._store, self._path + (doc_id,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _ColRef(self, (name,))


def _logs(db):
    return [v for k, v in db.docs.items() if k[0] == "persona_change_log"]


def _seed_feedback(db, n=3, category="repeated_question"):
    now = datetime.now(timezone.utc)
    for i in range(n):
        db.docs[("feedback", f"f{i}")] = {
            "uid": f"u{i}", "category": category, "note": f"note {i}",
            "quote": "", "created_at": now,
        }


# ---------------------------------------------------------------- aggregate

def test_summarize_feedback_groups_by_category_with_counts_and_users():
    rows = [
        {"uid": "a", "category": "repeated_question", "note": "asked twice"},
        {"uid": "b", "category": "repeated_question", "note": "again!"},
        {"uid": "a", "category": "tone", "note": "too flat", "quote": "meh"},
    ]
    summary = persona_evolution.summarize_feedback(rows, window_days=7)
    assert "repeated_question — 2 occurrences across 2 users" in summary
    assert "tone — 1 occurrences across 1 users" in summary
    assert "asked twice" in summary and "again!" in summary
    assert '"meh"' in summary


def test_summarize_feedback_is_empty_for_no_rows():
    assert persona_evolution.summarize_feedback([]) == ""


# ---------------------------------------------------------------- config doc

def test_current_lessons_md_reads_firestore_when_present():
    db = FakeDb()
    db.docs[("config", "ayma_persona")] = {"lessons_md": "- from firestore"}
    assert persona_evolution.current_lessons_md(db) == "- from firestore"


def test_current_lessons_md_falls_back_to_the_static_seed_when_absent():
    db = FakeDb()
    assert persona_evolution.current_lessons_md(db) == prompt_mod._static_lessons_seed()


# ---------------------------------------------------------------- eval gate

def test_eval_gate_passes_when_no_scenario_regresses(monkeypatch):
    async def _fake_reply(lessons_md, scenario):
        return f"reply-{scenario['id']}"

    async def _fake_judge(scenario, current_reply, proposed_reply):
        return {"regression": False, "reason": "equally warm"}

    monkeypatch.setattr(persona_evolution, "_scenario_reply", _fake_reply)
    monkeypatch.setattr(persona_evolution, "_judge_scenario", _fake_judge)

    result = _run(persona_evolution.run_eval_gate("current", "proposed"))
    assert result["passed"] is True
    scenarios = persona_evolution.load_eval_scenarios()
    assert len(result["scenarios"]) == len(scenarios)


def test_eval_gate_any_single_regression_fails_the_whole_gate(monkeypatch):
    scenarios = persona_evolution.load_eval_scenarios()
    assert len(scenarios) >= 8
    flagged_id = scenarios[2]["id"]

    async def _fake_reply(lessons_md, scenario):
        return f"reply-{scenario['id']}"

    async def _fake_judge(scenario, current_reply, proposed_reply):
        return {
            "regression": scenario["id"] == flagged_id,
            "reason": "worse" if scenario["id"] == flagged_id else "fine",
        }

    monkeypatch.setattr(persona_evolution, "_scenario_reply", _fake_reply)
    monkeypatch.setattr(persona_evolution, "_judge_scenario", _fake_judge)

    result = _run(persona_evolution.run_eval_gate("current", "proposed"))
    # every scenario still gets judged (not short-circuited)...
    assert len(result["scenarios"]) == len(scenarios)
    # ...but ONE regression is enough to fail the whole gate
    assert result["passed"] is False
    regressed = [s for s in result["scenarios"] if s["regression"]]
    assert len(regressed) == 1
    assert regressed[0]["id"] == flagged_id


def test_eval_gate_treats_a_broken_scenario_as_a_failure_not_a_pass(monkeypatch):
    async def _boom(lessons_md, scenario):
        raise RuntimeError("gemini exploded")

    async def _fake_judge(scenario, current_reply, proposed_reply):
        return {"regression": False, "reason": "fine"}

    monkeypatch.setattr(persona_evolution, "_scenario_reply", _boom)
    monkeypatch.setattr(persona_evolution, "_judge_scenario", _fake_judge)

    result = _run(persona_evolution.run_eval_gate("current", "proposed"))
    assert result["passed"] is False


# ---------------------------------------------------------------- run()

def test_run_reports_no_feedback_when_the_window_is_empty():
    db = FakeDb()
    result = _run(persona_evolution.run(db))
    assert result == {
        "ran": True, "based_on_feedback_count": 0, "action": "no_feedback",
    }


def test_run_skips_when_the_model_proposes_no_real_change(monkeypatch):
    db = FakeDb()
    _seed_feedback(db)
    current = persona_evolution.current_lessons_md(db)

    async def _fake_propose(summary, current_md):
        return {
            "proposed_lessons_md": current_md, "summary": "no pattern yet",
            "rationale": "", "critical": False, "critical_reason": "",
        }

    monkeypatch.setattr(persona_evolution, "_propose", _fake_propose)
    result = _run(persona_evolution.run(db))
    assert result["action"] == "no_change_proposed"
    assert ("config", "ayma_persona") not in db.docs
    assert current == persona_evolution.current_lessons_md(db)


def test_run_holds_a_critical_proposal_for_admin_review(monkeypatch):
    db = FakeDb()
    _seed_feedback(db)

    async def _fake_propose(summary, current_md):
        assert "repeated_question" in summary
        return {
            "proposed_lessons_md": "- new bullet about a sensitive topic",
            "summary": "s", "rationale": "r",
            "critical": True, "critical_reason": "touches a sensitive topic",
        }

    monkeypatch.setattr(persona_evolution, "_propose", _fake_propose)
    # if the eval gate ran, the test should still pass either way — but it
    # must NOT be needed to reach the critical branch:
    monkeypatch.setattr(
        persona_evolution, "run_eval_gate",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("eval gate must not run for a critical proposal")),
    )

    result = _run(persona_evolution.run(db))
    assert result["action"] == "held_critical"
    doc = db.docs[("persona_change_proposals", result["proposal_id"])]
    assert doc["status"] == "pending"
    assert doc["proposed_lessons_md"] == "- new bullet about a sensitive topic"
    assert doc["critical_reason"] == "touches a sensitive topic"
    assert doc["based_on_feedback_count"] == 3
    # never applied automatically
    assert ("config", "ayma_persona") not in db.docs


def test_run_applies_immediately_when_not_critical_and_the_gate_passes(monkeypatch):
    db = FakeDb()
    _seed_feedback(db)

    async def _fake_propose(summary, current_md):
        return {
            "proposed_lessons_md": "- new additive bullet", "summary": "s",
            "rationale": "r", "critical": False, "critical_reason": "small tweak",
        }

    async def _fake_gate(current_md, proposed_md):
        return {"passed": True, "scenarios": [{"id": "x", "regression": False, "reason": "fine"}]}

    monkeypatch.setattr(persona_evolution, "_propose", _fake_propose)
    monkeypatch.setattr(persona_evolution, "run_eval_gate", _fake_gate)

    result = _run(persona_evolution.run(db))
    assert result["action"] == "applied"
    assert db.docs[("config", "ayma_persona")]["lessons_md"] == "- new additive bullet"
    logs = _logs(db)
    assert len(logs) == 1
    assert logs[0]["lessons_md_after"] == "- new additive bullet"
    assert logs[0]["eval_result"]["passed"] is True
    # no proposal doc for an applied change
    assert not any(k[0] == "persona_change_proposals" for k in db.docs)


def test_run_holds_for_admin_when_the_eval_gate_fails(monkeypatch):
    db = FakeDb()
    _seed_feedback(db)

    async def _fake_propose(summary, current_md):
        return {
            "proposed_lessons_md": "- risky bullet", "summary": "s",
            "rationale": "r", "critical": False, "critical_reason": "",
        }

    async def _fake_gate(current_md, proposed_md):
        return {
            "passed": False,
            "scenarios": [{"id": "rambling_pacing_trap", "regression": True, "reason": "more robotic"}],
        }

    monkeypatch.setattr(persona_evolution, "_propose", _fake_propose)
    monkeypatch.setattr(persona_evolution, "run_eval_gate", _fake_gate)

    result = _run(persona_evolution.run(db))
    assert result["action"] == "eval_failed"
    doc = db.docs[("persona_change_proposals", result["proposal_id"])]
    assert doc["status"] == "eval_failed"
    assert doc["eval_result"]["passed"] is False
    assert ("config", "ayma_persona") not in db.docs


def test_run_never_raises_and_reports_failure_instead(monkeypatch):
    db = FakeDb()
    _seed_feedback(db)

    async def _boom(summary, current_md):
        raise RuntimeError("gemini is down")

    monkeypatch.setattr(persona_evolution, "_propose", _boom)
    result = _run(persona_evolution.run(db))
    assert result["ran"] is False
    assert "error" in result


# ---------------------------------------------------------------- admin surface

def test_list_pending_filters_status_and_sorts_most_recent_first():
    db = FakeDb()
    db.docs[("persona_change_proposals", "p_old_pending")] = {
        "status": "pending", "created_at": datetime(2026, 1, 1, tzinfo=timezone.utc),
    }
    db.docs[("persona_change_proposals", "p_new_pending")] = {
        "status": "pending", "created_at": datetime(2026, 3, 1, tzinfo=timezone.utc),
    }
    db.docs[("persona_change_proposals", "p_approved")] = {
        "status": "approved", "created_at": datetime(2026, 4, 1, tzinfo=timezone.utc),
    }
    db.docs[("persona_change_proposals", "p_eval_failed")] = {
        "status": "eval_failed", "created_at": datetime(2026, 2, 1, tzinfo=timezone.utc),
    }
    out = persona_evolution.list_pending(db)
    assert [d["id"] for d in out] == ["p_new_pending", "p_eval_failed", "p_old_pending"]


def test_approve_applies_the_proposal_and_logs_it():
    db = FakeDb()
    db.docs[("persona_change_proposals", "p1")] = {
        "status": "eval_failed", "proposed_lessons_md": "- approved bullet",
        "summary": "s", "eval_result": {"passed": False},
    }
    assert persona_evolution.approve(db, "p1") is True
    assert db.docs[("config", "ayma_persona")]["lessons_md"] == "- approved bullet"
    assert db.docs[("persona_change_proposals", "p1")]["status"] == "approved"
    logs = _logs(db)
    assert logs and logs[0]["lessons_md_after"] == "- approved bullet"


def test_approve_returns_false_for_a_missing_proposal():
    db = FakeDb()
    assert persona_evolution.approve(db, "nope") is False
    assert ("config", "ayma_persona") not in db.docs


def test_reject_marks_status_and_stores_the_reason_without_applying_anything():
    db = FakeDb()
    db.docs[("persona_change_proposals", "p1")] = {"status": "pending"}
    assert persona_evolution.reject(db, "p1", "not a real pattern") is True
    doc = db.docs[("persona_change_proposals", "p1")]
    assert doc["status"] == "rejected"
    assert doc["reject_reason"] == "not a real pattern"
    assert ("config", "ayma_persona") not in db.docs


def test_reject_returns_false_for_a_missing_proposal():
    db = FakeDb()
    assert persona_evolution.reject(db, "nope") is False
