"""Manual public-profile editing and the approve-before-apply AI proposals."""

import asyncio

import pytest
from fake_firestore import SERVER_TIMESTAMP, FakeDb

import account_ops
import gemini
import profile_manual as pm
import story
import wiki_ingest

UID = "u1"


def _page(db, page_id, **data):
    data.setdefault("page_type", page_id)
    data.setdefault("visibility", "public")
    db.docs[("users", UID, "wiki_pages", page_id)] = data


def _doc(db, page_id):
    return db.docs[("users", UID, "wiki_pages", page_id)]


def _db():
    db = FakeDb()
    _page(
        db,
        "career",
        ai_body="She is a nurse in Boston. She loves her team. "
        "{{private}}She was laid off once.{{/private}}",
    )
    _page(db, "interests", ai_body="She climbs on weekends. She bakes bread.")
    return db


@pytest.fixture
def model(monkeypatch):
    """Scriptable stand-in for the two model calls (prompt file name -> reply)."""
    calls = []
    replies = {"flagged": False, "reason": "", "kinds": {}}

    async def fake_generate_json(contents, system_prompt, response_schema=None, **kw):
        calls.append((contents, system_prompt, kw))
        if "flagged" in response_schema["properties"]:
            return {"flagged": replies["flagged"], "reason": replies["reason"]}
        ids = [
            ln.split(":", 1)[0]
            for ln in contents.splitlines()
            if ln[:1] in ("r", "a") and ":" in ln and ln.split(":")[0][1:].isdigit()
        ]
        return {
            "items": [
                {"id": i, "kind": replies["kinds"][i]}
                for i in ids
                if i in replies["kinds"]
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", fake_generate_json)
    replies["calls"] = calls
    return replies


def _save(db, text, version=None):
    version = version or pm.get_text(db, UID)["version"]
    return asyncio.run(pm.save_text(db, UID, text, version))


def test_get_text_assembles_public_sections_without_private_spans():
    out = pm.get_text(_db(), UID)
    assert "## Career\nShe is a nurse in Boston. She loves her team." in out["text"]
    assert "laid off" not in out["text"]
    assert "## Interests\nShe climbs on weekends." in out["text"]


def test_removed_fact_goes_to_notes_added_fact_is_pinned_wording_is_neither(model):
    db = _db()
    text = pm.get_text(db, UID)["text"]
    new = text.replace(
        "She is a nurse in Boston. She loves her team.",
        "Nurse in Boston. She has a golden retriever.",
    )
    # sentences: r1 "She is a nurse in Boston." r2 "She loves her team."
    #            a1 "Nurse in Boston." a2 "She has a golden retriever."
    model["kinds"] = {
        "r1": "wording_only",
        "r2": "removed_fact",
        "a1": "wording_only",
        "a2": "added_fact",
    }
    out = _save(db, new)
    assert out["removed_to_notes"] == 1 and out["added_facts"] == 1
    assert out["wording_only"] == 2

    page = _doc(db, "career")
    # the user's text is the public text
    assert story.strip_private_spans(page["user_edits"]) == (
        "Nurse in Boston. She has a golden retriever."
    )
    # the removed fact is kept as an ai_only note; wording-only is not
    assert "{{ai_only}}She loves her team.{{/ai_only}}" in page["user_edits"]
    assert "She is a nurse in Boston." not in page["user_edits"]
    # the existing private span survives
    assert "{{private}}She was laid off once.{{/private}}" in page["user_edits"]
    # the added fact is pinned and told to Ayma; wording changes are not
    assert page["manual_pinned"] == ["She has a golden retriever."]
    assert page["ai_body"].endswith("She has a golden retriever.")
    assert "Nurse in Boston." not in page["ai_body"].replace("a nurse in Boston", "")
    # untouched section stays untouched; a version was committed
    assert "user_edits" not in _doc(db, "interests")
    versions = [k for k in db.docs if k[:5] == ("users", UID, "wiki_pages", "career", "versions")]
    assert versions
    # the removed fact shows in the owner's notes view, not on the public one
    notes = story.get_ai_notes(db, UID)["sections"]
    career = next(s for s in notes if s["page_id"] == "career")
    assert "She loves her team." in career["body"]
    assert "She loves her team." not in pm.get_text(db, UID)["text"]


def test_classifier_failure_keeps_removed_facts_and_pins_added(monkeypatch):
    db = _db()

    async def boom(*a, **k):
        if "flagged" in k["response_schema"]["properties"]:
            return {"flagged": False, "reason": ""}
        raise RuntimeError("model down")

    monkeypatch.setattr(gemini, "generate_json", boom)
    text = pm.get_text(db, UID)["text"].replace(
        "She climbs on weekends.", "She surfs."
    )
    out = _save(db, text)
    assert out["removed_to_notes"] == 1 and out["added_facts"] == 1
    assert "{{ai_only}}She climbs on weekends.{{/ai_only}}" in _doc(
        db, "interests"
    )["user_edits"]


def test_unchanged_text_is_a_no_op(model):
    db = _db()
    out = _save(db, pm.get_text(db, UID)["text"])
    assert out["changed"] is False
    assert model["calls"] == []
    assert "user_edits" not in _doc(db, "career")


def test_unpinning_when_the_user_deletes_a_pinned_sentence(model):
    db = _db()
    _page(db, "values", ai_body="She values honesty.", manual_pinned=["She values honesty."])
    text = pm.get_text(db, UID)["text"].replace("She values honesty.", "She values kindness.")
    model["kinds"] = {"r1": "removed_fact", "a1": "added_fact"}
    _save(db, text)
    assert _doc(db, "values")["manual_pinned"] == ["She values kindness."]


@pytest.mark.parametrize(
    "bad",
    [
        "Call me on 415-555-0199",
        "Reach me: jo.smith@example.com",
        "My number is +1 (415) 555 0199",
    ],
)
def test_phone_numbers_and_emails_are_rejected(model, bad):
    db = _db()
    text = pm.get_text(db, UID)["text"] + f"\n{bad}"
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, text)
    assert exc.value.code == "contact_info"
    assert "user_edits" not in _doc(db, "interests")


def test_links_and_years_are_allowed(model):
    db = _db()
    text = pm.get_text(db, UID)["text"].replace(
        "She bakes bread.",
        "Blog at https://example.com/415-555-0199/me and instagram "
        "https://instagram.com/jo. Worked 2015-2019.",
    )
    model["kinds"] = {"r1": "removed_fact", "a1": "added_fact", "a2": "added_fact"}
    assert _save(db, text)["changed"] is True
    assert "https://example.com/415-555-0199/me" in _doc(db, "interests")["user_edits"]


def test_flagged_text_is_rejected_and_nothing_is_written(model):
    db = _db()
    model["flagged"] = True
    model["reason"] = "No harassment."
    text = pm.get_text(db, UID)["text"] + "\nnasty words"
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, text)
    assert exc.value.code == "moderation" and str(exc.value) == "No harassment."
    assert "user_edits" not in _doc(db, "interests")


def test_moderation_outage_fails_closed(monkeypatch):
    db = _db()

    async def boom(*a, **k):
        raise RuntimeError("down")

    monkeypatch.setattr(gemini, "generate_json", boom)
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"] + "\nnew line")
    assert exc.value.code == "moderation_unavailable"


def test_too_long_stale_and_unknown_heading(model):
    db = _db()
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, "x" * (pm.MAX_TEXT_CHARS + 1))
    assert exc.value.code == "too_long"
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"], version="old")
    assert exc.value.code == "stale"
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, "## Nonsense\nhello")
    assert exc.value.code == "bad_sections"
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, "stray line\n" + pm.get_text(db, UID)["text"])
    assert exc.value.code == "bad_sections"


def test_user_typed_span_markers_are_stripped(model):
    db = _db()
    text = pm.get_text(db, UID)["text"].replace(
        "She bakes bread.", "{{ai_only}}hidden{{/ai_only}} Bread."
    )
    model["kinds"] = {"r1": "wording_only", "a1": "wording_only"}
    _save(db, text)
    assert "{{ai_only}}hidden" not in _doc(db, "interests")["user_edits"]


def test_deleting_a_whole_section_keeps_its_text_in_notes(model):
    db = _db()
    text = pm.get_text(db, UID)["text"]
    text = text[: text.index("## Interests")].strip()
    _save(db, text)
    body = _doc(db, "interests")["user_edits"]
    assert "{{ai_only}}She climbs on weekends.\nShe bakes bread.{{/ai_only}}" in body
    assert "Interests" not in pm.get_text(db, UID)["text"]


# --- AI proposals -------------------------------------------------------


def _ingest_write(db, page_id, new_body, visibility="public"):
    wiki_ingest._write_page(
        db,
        UID,
        "s1",
        {
            "page_id": page_id,
            "page_type": page_id,
            "visibility": visibility,
            "ai_body": new_body,
        },
    )


def test_ai_rewrite_of_a_public_page_becomes_a_proposal_not_a_silent_edit():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    page = _doc(db, "interests")
    assert page["ai_body"] == "She climbs and surfs."  # Ayma's memory moves
    assert page["user_edits"] == "She climbs on weekends. She bakes bread."
    assert pm.get_text(db, UID)["text"].count("surfs") == 0  # public unchanged
    [prop] = pm.list_proposals(db, UID)
    assert prop["page_id"] == "interests"
    assert prop["after"] == "She climbs and surfs."
    assert {"op": "add", "text": "She climbs and surfs."} in prop["diff"]
    assert {"op": "remove", "text": "She bakes bread."} in prop["diff"]


def test_apply_makes_the_proposal_the_public_text_and_commits_a_version():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    pm.apply_proposal(db, UID, "interests")
    assert "She climbs and surfs." in pm.get_text(db, UID)["text"]
    assert pm.list_proposals(db, UID) == []
    assert _doc(db, "interests")["pending_proposal"] is None
    authors = [
        v["author"]
        for k, v in db.docs.items()
        if k[:5] == ("users", UID, "wiki_pages", "interests", "versions")
    ]
    assert authors == ["ayma"]


def test_dismiss_keeps_the_current_text():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    pm.dismiss_proposal(db, UID, "interests")
    assert pm.list_proposals(db, UID) == []
    assert "She bakes bread." in pm.get_text(db, UID)["text"]
    with pytest.raises(KeyError):
        pm.dismiss_proposal(db, UID, "interests")
    with pytest.raises(KeyError):
        pm.apply_proposal(db, UID, "interests")


def test_proposal_never_drops_pinned_sentences_or_ai_only_notes(model):
    db = _db()
    model["kinds"] = {"r1": "removed_fact", "a1": "added_fact"}
    text = pm.get_text(db, UID)["text"].replace(
        "She bakes bread.", "She has a golden retriever."
    )
    _save(db, text)
    _ingest_write(db, "interests", "She climbs and surfs.")  # drops both
    pm.apply_proposal(db, UID, "interests")
    body = _doc(db, "interests")["user_edits"]
    assert "She has a golden retriever." in story.strip_private_spans(body)
    assert "{{ai_only}}She bakes bread.{{/ai_only}}" in body


def test_ai_rewrite_with_same_public_text_makes_no_proposal_and_clears_stale():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    _ingest_write(db, "interests", "She climbs on weekends. She bakes bread.")
    assert pm.list_proposals(db, UID) == []


def test_new_private_and_first_time_pages_are_written_straight_through():
    db = _db()
    _ingest_write(db, "family", "She has two sisters.")
    assert "user_edits" not in _doc(db, "family")
    assert "pending_proposal" not in _doc(db, "family")
    _page(db, "health", ai_body="Old.", visibility="private")
    _ingest_write(db, "health", "New.", visibility="private")
    assert pm.list_proposals(db, UID) == []


def test_saving_a_manual_edit_discards_a_stale_proposal(model):
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    model["kinds"] = {"r1": "wording_only", "a1": "wording_only"}
    text = pm.get_text(db, UID)["text"].replace("She bakes bread.", "Bread baker.")
    _save(db, text)
    assert pm.list_proposals(db, UID) == []


def test_ingest_prompt_starts_from_saved_text_and_lists_pinned():
    db = _db()
    _page(
        db,
        "values",
        ai_body="old ai",
        user_edits="the saved text",
        manual_pinned=["Pinned one."],
    )
    pages = {p["page_id"]: p for p in wiki_ingest._read_existing_pages(db, UID)}
    assert pages["values"]["ai_body"] == "the saved text"
    block = wiki_ingest._existing_pages_block([pages["values"]])
    assert "the saved text" in block and "- Pinned one." in block


def test_account_deletion_wipes_notes_pins_and_proposals(model, monkeypatch):
    monkeypatch.setattr(account_ops.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    db = _db()
    db.docs[("users", UID)] = {"created_at": 1}
    model["kinds"] = {"r1": "removed_fact", "a1": "added_fact"}
    _save(db, pm.get_text(db, UID)["text"].replace("She bakes bread.", "She surfs."))
    _ingest_write(db, "career", "She is a doctor now.")
    account_ops.soft_delete(db, None, UID)
    live = [k for k in db.docs if k[:2] == ("users", UID)]
    assert live == []
