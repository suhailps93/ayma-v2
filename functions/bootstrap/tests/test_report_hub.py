"""Tests for report_hub.py: ownership resolution, read/write permission
enforcement, and correction routing to each report type's real underlying
producer function. Adapters and producer functions are monkeypatched so
these tests exercise report_hub's own logic in isolation."""

import asyncio

import appearance
import deep_dive
import physical_attributes
import pytest
import report_adapters as ra
import report_blocks as rb
import report_hub
import story


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- resolve_owner / get_report permissions --------------------------------


def test_resolve_owner_appearance_and_story_are_self_owned():
    assert report_hub.resolve_owner("appearance", "u1", "viewer") == "u1"
    assert report_hub.resolve_owner("story_private", "u1", "viewer") == "u1"
    assert report_hub.resolve_owner("story_public", "u1", "viewer") == "u1"
    assert report_hub.resolve_owner("story_ai_notes", "u1", "viewer") == "u1"


def test_resolve_owner_deep_dive_delegates_to_deep_dive_report_owner(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "subject-uid")
    assert report_hub.resolve_owner("deep_dive", "uid_subject-uid", "viewer") == "subject-uid"


def test_get_report_404_for_unknown_type():
    with pytest.raises(ValueError):
        report_hub.get_report(object(), "not_a_type", "x", "u1")


def test_get_report_404_when_adapter_returns_none(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: None)
    with pytest.raises(KeyError):
        report_hub.get_report(object(), "appearance", "u1", "u1")


def test_get_report_403_for_non_owner_on_owner_only_type(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: {
        "id": "current", "created_at": None, "attributes": {}, "face": {}, "body": {},
    })
    with pytest.raises(PermissionError):
        report_hub.get_report(object(), "appearance", "owner-uid", "someone-else")


def test_get_report_owner_can_read_appearance(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: {
        "id": "current", "created_at": None, "attributes": {}, "face": {}, "body": {},
    })
    out = report_hub.get_report(object(), "appearance", "owner-uid", "owner-uid")
    assert out["meta"]["owner_uid"] == "owner-uid"
    assert out["meta"]["viewer_can_edit"] is True


def test_get_report_non_owner_can_read_story_public(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    out = report_hub.get_report(object(), "story_public", "owner-uid", "someone-else")
    assert out["meta"]["owner_uid"] == "owner-uid"
    assert out["meta"]["viewer_can_edit"] is False


def test_get_report_non_owner_can_read_deep_dive(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "owner-uid")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {"name": "X", "summary": "hi", "facts": []}, "name": "X",
    })
    out = report_hub.get_report(object(), "deep_dive", "uid_owner-uid", "someone-else")
    assert out["meta"]["owner_uid"] == "owner-uid"
    assert out["meta"]["viewer_can_edit"] is False


def test_get_report_non_owner_cannot_read_story_private(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    with pytest.raises(PermissionError):
        report_hub.get_report(object(), "story_private", "owner-uid", "someone-else")


def test_get_report_non_owner_cannot_read_story_ai_notes(monkeypatch):
    monkeypatch.setattr(story, "get_ai_notes", lambda db, uid: {"sections": []})
    with pytest.raises(PermissionError):
        report_hub.get_report(object(), "story_ai_notes", "owner-uid", "someone-else")


# --- correct: ownership enforcement -----------------------------------


def test_correct_403_for_non_owner_appearance(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: {
        "id": "current", "attributes": {"record": {}}, "face": {}, "body": {},
    })
    with pytest.raises(PermissionError):
        _run(report_hub.correct(
            object(), "appearance", "owner-uid", "someone-else",
            block_ids=["face"], scope="block", message="that's wrong",
        ))


def test_correct_403_for_non_owner_deep_dive(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "owner-uid")
    with pytest.raises(PermissionError):
        _run(report_hub.correct(
            object(), "deep_dive", "uid_owner-uid", "someone-else",
            block_ids=["fact:f1"], scope="block", message="not right",
        ))


def test_correct_owner_can_correct_deep_dive(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "owner-uid")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {
            "name": "X", "summary": "hi", "confidence": "high",
            "facts": [{"id": "f1", "claim": "wrong claim", "category": "work"}],
            "links": [],
        },
    })
    calls = {}

    async def _correct(db, uid, rid, *, target, feedback):
        calls.update(uid=uid, rid=rid, target=target, feedback=feedback)
        return {"reply": "fixed it"}

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    out = _run(report_hub.correct(
        object(), "deep_dive", "uid_owner-uid", "owner-uid",
        block_ids=["fact:f1"], scope="block", message="not right",
    ))
    assert out["ok"] is True
    assert calls == {"uid": "owner-uid", "rid": "uid_owner-uid", "target": "fact:f1", "feedback": "not right"}


def test_correct_404_when_report_missing(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: None)
    with pytest.raises(KeyError):
        _run(report_hub.correct(
            object(), "appearance", "owner-uid", "owner-uid",
            block_ids=["face"], scope="block", message="fix it",
        ))


def test_correct_422_for_empty_block_ids():
    with pytest.raises(ValueError):
        _run(report_hub.correct(
            object(), "appearance", "u1", "u1",
            block_ids=[], scope="block", message="fix it",
        ))


def test_correct_422_for_blank_message(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: {
        "attributes": {"record": {}}, "face": {}, "body": {},
    })
    with pytest.raises(ValueError):
        _run(report_hub.correct(
            object(), "appearance", "u1", "u1",
            block_ids=["face"], scope="block", message="   ",
        ))


# --- correct: routing to the real producer function -----------------------


_APPEARANCE_DOC = {
    "attributes": {"record": {"eye_color": {"value": "blue", "source": "photo"}}},
    "face": {"overall_score": 6, "verdict": "Average", "strengths": [], "improvements": [], "recommendations": []},
    "body": {"status": "needs_body_photo"},
}


def test_correct_routes_attribute_block_to_appearance_correct_finding(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    calls = {}

    async def _correct(db, uid, finding_id, message):
        calls.update(uid=uid, finding_id=finding_id, message=message)
        return {"ok": True, "reply": "updated", "finding_id": finding_id, "value": "brown"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    out = _run(report_hub.correct(
        object(), "appearance", "u1", "u1",
        block_ids=["attr:eye_color"], scope="block", message="it's brown",
    ))
    assert calls == {"uid": "u1", "finding_id": "eye_color", "message": "it's brown"}
    assert out["results"][0]["block_id"] == "eye_color"
    assert out["ok"] is True


def test_correct_routes_face_subitem_block_to_the_whole_face_axis(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    calls = []

    async def _correct(db, uid, finding_id, message):
        calls.append(finding_id)
        return {"ok": True, "reply": "ok"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    _run(report_hub.correct(
        object(), "appearance", "u1", "u1",
        block_ids=["face"], scope="block", message="too harsh",
    ))
    assert calls == ["face"]


def test_correct_section_scope_dedupes_to_one_call_per_target(monkeypatch):
    doc = dict(_APPEARANCE_DOC)
    doc["face"] = {
        "overall_score": 6, "verdict": "Average",
        "strengths": ["a", "b"], "improvements": ["c"], "recommendations": [],
    }
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: doc)
    calls = []

    async def _correct(db, uid, finding_id, message):
        calls.append(finding_id)
        return {"ok": True, "reply": "ok"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    # tap the section header -> bundles every block in "Face", which all
    # route to the SAME underlying target ("face") -> exactly one call.
    out = _run(report_hub.correct(
        object(), "appearance", "u1", "u1",
        block_ids=["face:strength:0"], scope="section", message="too harsh",
    ))
    assert calls == ["face"]
    assert len(out["results"]) == 1


def test_correct_routes_fact_block_to_deep_dive_correct_finding(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "u1")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {"name": "X", "summary": "s", "facts": [{"id": "f1", "claim": "c", "category": "work"}], "links": []},
    })
    calls = {}

    async def _correct(db, uid, rid, *, target, feedback):
        calls.update(target=target, feedback=feedback)
        return {"reply": "updated"}

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["fact:f1"], scope="block", message="wrong",
    ))
    assert calls == {"target": "fact:f1", "feedback": "wrong"}


def test_correct_quick_delete_routes_fact_block_to_dispute_fact(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "u1")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {"name": "X", "summary": "s", "facts": [{"id": "f1", "claim": "c", "category": "work"}], "links": []},
    })
    calls = {}

    def _dispute(db, uid, rid, fid):
        calls.update(uid=uid, rid=rid, fid=fid)
        return {"report_id": rid}

    monkeypatch.setattr(deep_dive, "dispute_fact", _dispute)
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["fact:f1"], scope="block", message="Delete",
    ))
    assert calls == {"uid": "u1", "rid": "name_x", "fid": "f1"}
    assert out["ok"] is True


def test_correct_quick_delete_on_social_routes_to_dispute_social_link(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "u1")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {
            "name": "X", "summary": "s", "facts": [], "links": [],
            "social_handles": [{"platform": "x", "handle": "h", "url": "https://x.com/h"}],
        },
    })
    calls = {}

    def _dispute(db, uid, rid, url):
        calls.update(url=url)
        return {"report_id": rid}

    monkeypatch.setattr(deep_dive, "dispute_social_link", _dispute)
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["social:https://x.com/h"], scope="block", message="make private",
    ))
    # "make private" isn't a delete -> not applicable for deep_dive; dispute
    # must NOT have been called.
    assert calls == {}
    assert out["ok"] is False


def test_correct_quick_delete_summary_is_refused(monkeypatch):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "u1")
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {"name": "X", "summary": "About them.", "facts": [], "links": []},
    })
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["summary:sent:0"], scope="block", message="delete",
    ))
    assert out["ok"] is False
    assert "can't be deleted" in out["results"][0]["reply"]


# --- pending candidates (§ founder: replaces the Photo candidates screen) --

_ONE_CANDIDATE = {"candidate_id": "cand1", "image_url": "https://x/y.jpg", "status": "pending"}


def _deep_dive_with_candidates(monkeypatch, candidates, *, owner="u1"):
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: owner)
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: {
        "digest": {"name": "X", "summary": "s", "facts": [], "links": []},
    })
    import reverse_image_search

    monkeypatch.setattr(reverse_image_search, "list_candidates", lambda db, uid: candidates)
    return reverse_image_search


def test_correct_deep_dive_confirm_candidate_routes_to_real_confirm_fn(monkeypatch):
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    calls = {}

    def _confirm(db, uid, cid):
        calls.update(uid=uid, cid=cid)
        return {"candidate_id": cid, "status": "confirmed"}

    monkeypatch.setattr(ris, "confirm_candidate", _confirm)
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="This is me",
    ))
    assert calls == {"uid": "u1", "cid": "cand1"}
    assert out["ok"] is True
    assert "added it to your report" in out["results"][0]["reply"]


def test_correct_deep_dive_reject_candidate_routes_to_real_reject_fn(monkeypatch):
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    calls = {}

    def _reject(db, uid, cid):
        calls.update(uid=uid, cid=cid)
        return {"candidate_id": cid, "status": "rejected"}

    monkeypatch.setattr(ris, "reject_candidate", _reject)
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="Not me",
    ))
    assert calls == {"uid": "u1", "cid": "cand1"}
    assert out["ok"] is True
    assert "dismissed" in out["results"][0]["reply"]


def test_correct_deep_dive_candidate_phrase_match_is_case_insensitive(monkeypatch):
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    calls = []
    monkeypatch.setattr(
        ris, "confirm_candidate",
        lambda db, uid, cid: calls.append(cid) or {"candidate_id": cid},
    )
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="THIS IS ME",
    ))
    assert calls == ["cand1"]
    assert out["ok"] is True


def test_correct_deep_dive_candidate_free_text_is_refused_without_calling_either_fn(monkeypatch):
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    confirm_calls = []
    reject_calls = []
    monkeypatch.setattr(ris, "confirm_candidate", lambda *a: confirm_calls.append(a))
    monkeypatch.setattr(ris, "reject_candidate", lambda *a: reject_calls.append(a))
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="hmm not totally sure",
    ))
    assert confirm_calls == [] and reject_calls == []
    assert out["ok"] is False
    assert "This is me" in out["results"][0]["reply"]


def test_correct_deep_dive_candidate_make_public_is_not_a_thing(monkeypatch):
    """The standard make-public/make-private/delete set does NOT apply to a
    candidate block — it gets its own fixed pair instead (§ module
    docstring)."""
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    confirm_calls = []
    monkeypatch.setattr(ris, "confirm_candidate", lambda *a: confirm_calls.append(a))
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="delete",
    ))
    assert confirm_calls == []
    assert out["ok"] is False


def test_correct_deep_dive_confirm_candidate_already_decided(monkeypatch):
    ris = _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)])
    monkeypatch.setattr(ris, "confirm_candidate", lambda db, uid, cid: None)
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="block", message="This is me",
    ))
    assert out["ok"] is False
    assert "already" in out["results"][0]["reply"]


def test_correct_deep_dive_confirm_candidate_non_owner_403(monkeypatch):
    _deep_dive_with_candidates(monkeypatch, [dict(_ONE_CANDIDATE)], owner="owner-uid")
    with pytest.raises(PermissionError):
        _run(report_hub.correct(
            object(), "deep_dive", "uid_owner-uid", "someone-else",
            block_ids=["candidate:cand1"], scope="block", message="This is me",
        ))


def test_correct_deep_dive_section_scope_confirms_every_pending_candidate(monkeypatch):
    """Tapping the "Photos to confirm" section header bundles every pending
    candidate in it — one confirm call per candidate, all from one "This is
    me"."""
    ris = _deep_dive_with_candidates(
        monkeypatch,
        [
            {"candidate_id": "cand1", "image_url": "https://x/1.jpg", "status": "pending"},
            {"candidate_id": "cand2", "image_url": "https://x/2.jpg", "status": "pending"},
        ],
    )
    calls = []
    monkeypatch.setattr(
        ris, "confirm_candidate",
        lambda db, uid, cid: calls.append(cid) or {"candidate_id": cid},
    )
    out = _run(report_hub.correct(
        object(), "deep_dive", "name_x", "u1",
        block_ids=["candidate:cand1"], scope="section", message="This is me",
    ))
    assert sorted(calls) == ["cand1", "cand2"]
    assert out["ok"] is True
    assert len(out["results"]) == 2


# --- story routing ----------------------------------------------------


def _page(uid, page_id):
    return object(), {"user_edits": "", "ai_body": "First sentence. Second sentence."}


def _story_data(page_id="identity", body="First sentence. Second sentence.", visibility="private"):
    return {"sections": [{"page_id": page_id, "title": page_id.title(), "body": body, "visibility": visibility}]}


def test_correct_story_quick_privacy_routes_to_apply_span_action_and_save(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: _story_data())
    monkeypatch.setattr(story, "_require_page", lambda db, uid, pid: _page(uid, pid))
    monkeypatch.setattr(story, "_display_body", lambda db, uid, pid, data: "First sentence. Second sentence.")
    calls = {}

    def _apply(body, selection, action):
        calls["span"] = (selection, action)
        return body.replace(selection, "{{private}}" + selection + "{{/private}}")

    def _save(db, uid, pid, body, visibility=None, *, allow_hidden_changes=False):
        calls["save"] = (pid, body, allow_hidden_changes)
        return {"head_version_id": "v1"}

    monkeypatch.setattr(story, "apply_span_action", _apply)
    monkeypatch.setattr(story, "save_section", _save)
    out = _run(report_hub.correct(
        object(), "story_private", "u1", "u1",
        block_ids=["page:identity:sent:0"], scope="block", message="make private",
    ))
    assert calls["span"] == ("First sentence.", "private")
    assert calls["save"][0] == "identity" and calls["save"][2] is True
    assert out["ok"] is True


def test_correct_story_quick_delete_section_scope_routes_to_remove_section(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: _story_data())
    monkeypatch.setattr(story, "_require_page", lambda db, uid, pid: _page(uid, pid))
    monkeypatch.setattr(story, "_display_body", lambda db, uid, pid, data: "First sentence. Second sentence.")
    calls = {}

    def _remove(db, uid, pid):
        calls["removed"] = pid
        return {"deleted": True}

    monkeypatch.setattr(story, "remove_section", _remove)
    out = _run(report_hub.correct(
        object(), "story_private", "u1", "u1",
        block_ids=["page:identity:sent:0"], scope="section", message="delete",
    ))
    assert calls["removed"] == "identity"
    assert out["ok"] is True


def test_correct_story_free_text_applies_span_action_from_edit_section(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: _story_data())
    monkeypatch.setattr(story, "_require_page", lambda db, uid, pid: _page(uid, pid))
    monkeypatch.setattr(story, "_display_body", lambda db, uid, pid, data: "First sentence. Second sentence.")

    async def _edit_section(db, uid, pid, selection, messages):
        assert selection == "First sentence."
        return {"reply": "reworded it", "revised_body": "Reworded sentence. Second sentence.", "action": "chat"}

    monkeypatch.setattr(story, "edit_section", _edit_section)
    calls = {}

    def _save(db, uid, pid, body, visibility=None, *, allow_hidden_changes=False):
        calls["saved"] = body

    monkeypatch.setattr(story, "save_section", _save)
    out = _run(report_hub.correct(
        object(), "story_private", "u1", "u1",
        block_ids=["page:identity:sent:0"], scope="block", message="reword this please",
    ))
    assert calls["saved"] == "Reworded sentence. Second sentence."
    assert out["results"][0]["reply"] == "reworded it"


def test_correct_story_non_correctable_block_reports_gracefully(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: _story_data(body=""))
    out = _run(report_hub.correct(
        object(), "story_private", "u1", "u1",
        block_ids=["page:identity:empty"], scope="block", message="fix this",
    ))
    assert out["ok"] is False
    assert "isn't something I can correct" in out["results"][0]["reply"]


# --- scope resolution ----------------------------------------------------


def test_resolve_target_block_ids_report_scope_returns_everything():
    report = rb.make_report(
        "T",
        [
            rb.make_section("A", [rb.text_block("b1", "x")]),
            rb.make_section("B", [rb.text_block("b2", "y")]),
        ],
    )
    out = report_hub._resolve_target_block_ids(report, ["b1"], "report")
    assert set(out) == {"b1", "b2"}


def test_resolve_target_block_ids_bad_scope_raises():
    report = rb.make_report("T", [rb.make_section("A", [rb.text_block("b1", "x")])])
    with pytest.raises(ValueError):
        report_hub._resolve_target_block_ids(report, ["b1"], "bogus")


def test_resolve_target_block_ids_unknown_block_raises_for_block_scope():
    report = rb.make_report("T", [rb.make_section("A", [rb.text_block("b1", "x")])])
    with pytest.raises(ValueError):
        report_hub._resolve_target_block_ids(report, ["nope"], "block")


# --- story_public: narrative Story only, same shape as story_private/ ------
# story_ai_notes (§ founder 2026-09-21, reversing part of a 2026-09-20
# change: "The attributes section should be part of the report that shows
# face and physique analysis. Don't have to duplicate anywhere else.")
#
# story_public no longer carries any attr: blocks — its former physical-
# attributes Attributes section (added 2026-09-20, converging in the old
# "My public profile" self-view) was removed again; see
# report_adapters.story_public_blocks. GET stays readable by any
# authenticated caller; only the owner may ever correct it.


def test_get_report_story_public_owner_sees_viewer_can_edit_true(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    out = report_hub.get_report(object(), "story_public", "owner-uid", "owner-uid")
    assert out["meta"]["viewer_can_edit"] is True


def test_correct_story_public_page_block_routes_to_story(monkeypatch):
    monkeypatch.setattr(
        story, "get_story",
        lambda db, uid: {
            "sections": [
                {"page_id": "identity", "title": "Identity", "body": "Hi there.", "visibility": "public"}
            ]
        },
    )
    monkeypatch.setattr(story, "_require_page", lambda db, uid, pid: _page(uid, pid))
    monkeypatch.setattr(story, "_display_body", lambda db, uid, pid, data: "Hi there.")
    appearance_touched = {"called": False}
    monkeypatch.setattr(
        appearance, "correct_finding",
        lambda *a, **k: appearance_touched.__setitem__("called", True),
    )

    async def _edit_section(db, uid, pid, selection, messages):
        return {"reply": "ok", "action": "chat", "revised_body": "Hi there, revised."}

    monkeypatch.setattr(story, "edit_section", _edit_section)
    calls = {}
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, visibility=None, **kw: calls.update(body=body),
    )
    out = _run(report_hub.correct(
        object(), "story_public", "owner-uid", "owner-uid",
        block_ids=["page:identity:sent:0"], scope="block", message="reword it",
    ))
    assert appearance_touched["called"] is False
    assert calls["body"] == "Hi there, revised."
    assert out["ok"] is True


def test_correct_story_public_non_owner_403(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    with pytest.raises(PermissionError):
        _run(report_hub.correct(
            object(), "story_public", "owner-uid", "someone-else",
            block_ids=["page:identity:sent:0"], scope="block", message="reword it",
        ))


def test_correct_story_public_attribute_block_id_no_longer_resolves(monkeypatch):
    """An `attr:` block id can't be tapped on story_public any more — the
    report never contains one, so `_resolve_target_block_ids` rejects it
    (`scope="block"` with no matching block is a `ValueError` -> the caller
    sees this as a plain "nothing to correct" failure, never a dispatch to
    Appearance's correction functions)."""
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    appearance_touched = {"called": False}
    monkeypatch.setattr(
        appearance, "correct_finding",
        lambda *a, **k: appearance_touched.__setitem__("called", True),
    )
    with pytest.raises(ValueError):
        _run(report_hub.correct(
            object(), "story_public", "owner-uid", "owner-uid",
            block_ids=["attr:eye_color"], scope="block", message="it's brown",
        ))
    assert appearance_touched["called"] is False


def test_correct_appearance_attribute_quick_make_public_is_still_refused(monkeypatch):
    """Appearance's own Attributes section (always self-owned/private-to-
    the-owner already) never had a public/private setting, and still
    doesn't — this quick action just says there's nothing to toggle. (The
    story_public-only path that once made this conditional, § founder
    follow-up 2026-09-20, was itself removed 2026-09-21 along with
    story_public's Attributes section — see report_hub._correct_appearance's
    docstring.)"""
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    calls = []
    monkeypatch.setattr(physical_attributes, "set_public", lambda *a: calls.append(a))
    out = _run(report_hub.correct(
        object(), "appearance", "u1", "u1",
        block_ids=["attr:eye_color"], scope="block", message="make public",
    ))
    assert calls == []
    assert out["ok"] is False
    assert "public/private setting" in out["results"][0]["reply"]


# --- end-to-end: a confirmed/rejected candidate stops being pending --------
#
# Real deep_dive.read_dive/report_owner and real reverse_image_search.
# confirm_candidate/reject_candidate/list_candidates against an in-memory
# fake Firestore (test_deep_dive._FakeDb) — nothing mocked at the
# report_hub level — proving the whole round trip: GET shows the pending
# candidate, POST .../correct decides it, a later GET no longer shows it.


def _seeded_fake_db():
    from test_deep_dive import _FakeDb

    db = _FakeDb()
    db.seed(
        ("users", "owner-uid", "deep_dives", "uid_owner-uid"),
        {"digest": {"name": "Jane Doe", "summary": "Works as a designer.",
                     "confidence": "high", "facts": [], "links": []},
         "name": "Jane Doe", "target_uid": ""},
    )
    db.seed(
        ("users", "owner-uid", "web_photo_candidates", "cand1"),
        {"candidate_id": "cand1", "image_url": "https://web/found.jpg",
         "source_title": "Some Site", "source_domain": "somesite.com",
         "status": "pending"},
    )
    return db


def test_confirmed_candidate_no_longer_appears_as_pending():
    db = _seeded_fake_db()

    before = report_hub.get_report(db, "deep_dive", "uid_owner-uid", "owner-uid")
    headings = [sec["heading"] for sec in before["sections"]]
    assert "Photos to confirm" in headings

    out = _run(report_hub.correct(
        db, "deep_dive", "uid_owner-uid", "owner-uid",
        block_ids=["candidate:cand1"], scope="block", message="This is me",
    ))
    assert out["ok"] is True

    after = report_hub.get_report(db, "deep_dive", "uid_owner-uid", "owner-uid")
    headings = [sec["heading"] for sec in after["sections"]]
    assert "Photos to confirm" not in headings


def test_rejected_candidate_no_longer_appears_as_pending():
    db = _seeded_fake_db()

    out = _run(report_hub.correct(
        db, "deep_dive", "uid_owner-uid", "owner-uid",
        block_ids=["candidate:cand1"], scope="block", message="Not me",
    ))
    assert out["ok"] is True

    after = report_hub.get_report(db, "deep_dive", "uid_owner-uid", "owner-uid")
    headings = [sec["heading"] for sec in after["sections"]]
    assert "Photos to confirm" not in headings


def test_a_non_owner_never_sees_the_pending_candidate_at_all():
    db = _seeded_fake_db()
    out = report_hub.get_report(db, "deep_dive", "uid_owner-uid", "someone-else")
    headings = [sec["heading"] for sec in out["sections"]]
    assert "Photos to confirm" not in headings


# --- match: read for both participants, no correction path at all --------
#
# § report_hub.py's module docstring / report_adapters.match_blocks's own
# docstring: a match score is algorithmically computed, not user-authored
# content, so BOTH participants can read it but NEITHER can "correct" it —
# no owner-gated mutation quick-actions are ever offered for this type.


def test_resolve_owner_match_returns_the_callers_own_uid_for_either_participant():
    assert report_hub.resolve_owner("match", "alice-uid__bob-uid", "alice-uid") == "alice-uid"
    assert report_hub.resolve_owner("match", "alice-uid__bob-uid", "bob-uid") == "bob-uid"


def test_resolve_owner_match_returns_none_for_a_non_participant():
    assert report_hub.resolve_owner("match", "alice-uid__bob-uid", "eve-uid") is None


def test_resolve_owner_match_returns_none_for_a_malformed_match_id():
    assert report_hub.resolve_owner("match", "not-a-pair-key", "alice-uid") is None


def test_get_report_match_participant_can_read(monkeypatch):
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (
        {"title": "Match with Bob", "sections": []}, None, None,
    ))
    out = report_hub.get_report(object(), "match", "alice-uid__bob-uid", "alice-uid")
    assert out["title"] == "Match with Bob"
    assert out["meta"]["owner_uid"] == "alice-uid"


def test_get_report_match_non_participant_gets_404_not_403(monkeypatch):
    """A non-participant learns NOTHING about whether this pair has even
    been scored — 404 ("no such report"), never 403 ("exists but not
    yours")."""
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (
        {"title": "Match", "sections": []}, None, None,
    ))
    with pytest.raises(KeyError):
        report_hub.get_report(object(), "match", "alice-uid__bob-uid", "eve-uid")


def test_get_report_match_404_when_never_scored(monkeypatch):
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (None, None, None))
    with pytest.raises(KeyError):
        report_hub.get_report(object(), "match", "alice-uid__bob-uid", "alice-uid")


def test_get_report_match_viewer_can_edit_is_always_false_for_a_participant(monkeypatch):
    """The one deliberate departure from the `owner == viewer_uid` rule
    every other report type follows: a match participant DOES resolve as
    their own "owner" (for read purposes), but must never see edit/
    quick-action affordances client-side, because there is nothing to
    correct here at all."""
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (
        {"title": "Match with Bob", "sections": []}, None, None,
    ))
    out = report_hub.get_report(object(), "match", "alice-uid__bob-uid", "alice-uid")
    assert out["meta"]["viewer_can_edit"] is False


def test_correct_match_participant_gets_a_clear_nothing_to_correct_reply(monkeypatch):
    """A stray direct POST to /report/match/{id}/correct (never issued by
    the real client, since `viewer_can_edit` is force-False for this type —
    see the test above) must not silently no-op or 500; it gets a real,
    deliberate answer and never touches any mutation function."""
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (
        {"title": "Match with Bob", "sections": [
            rb.make_section("Match", [rb.stat_block("score", "Match score", "82%", editable=False)]),
        ]}, None, None,
    ))
    out = _run(report_hub.correct(
        object(), "match", "alice-uid__bob-uid", "alice-uid",
        block_ids=["score"], scope="block", message="this is wrong",
    ))
    assert out["ok"] is False
    assert "nothing here to correct" in out["results"][0]["reply"]


def test_correct_match_non_participant_404_not_403(monkeypatch):
    """Same "never even confirm this pair exists" rule as the read path
    (see `test_get_report_match_non_participant_gets_404_not_403`) — a
    non-participant's write attempt fails at `resolve_owner` (which never
    resolves them to anything for a pair they're not in) before the
    owner-mismatch check that would otherwise raise `PermissionError` is
    even reached."""
    monkeypatch.setattr(ra, "match_blocks", lambda db, uid, mid: (
        {"title": "Match", "sections": []}, None, None,
    ))
    with pytest.raises(KeyError):
        _run(report_hub.correct(
            object(), "match", "alice-uid__bob-uid", "eve-uid",
            block_ids=["score"], scope="block", message="fix it",
        ))


def test_get_report_appearance_always_reads_the_one_current_doc(monkeypatch):
    """Regression: the URL's report_id for this type IS the subject uid (see
    `resolve_owner`), never a real appearance-report doc id — passing it
    through to `appearance.get_report` used to make every real request 404
    (it tried to look up a legacy doc literally named after the uid)."""
    seen_rid = []

    def fake_get_report(db, uid, rid):
        seen_rid.append(rid)
        return {"attributes": {}, "face": {}, "body": {}}

    monkeypatch.setattr(appearance, "get_report", fake_get_report)
    report_hub.get_report(object(), "appearance", "owner-uid", "owner-uid")
    assert seen_rid == ["current"]
