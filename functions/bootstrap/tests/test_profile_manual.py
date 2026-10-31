"""Manual public-profile editing and the approve-before-apply AI proposals."""

import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from fake_firestore import SERVER_TIMESTAMP, FakeDb

import account_ops
import gemini
import profile_manual as pm
import public_profile
import report_adapters as ra
import story
import wiki_ingest
from wiki_schema import is_valid_page_id

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
        _save(db, "## Family\nhello")
    assert exc.value.code == "bad_title"
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
    ops = {(c["op"], c["text"]) for c in prop["changes"]}
    assert ("add", "She climbs and surfs.") in ops
    assert ("remove", "She bakes bread.") in ops
    # every change carries its own stable id
    assert len({c["id"] for c in prop["changes"]}) == len(prop["changes"])


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


def _change_ids(db):
    [prop] = pm.list_proposals(db, UID)
    return {c["text"]: c["id"] for c in prop["changes"]}


def test_apply_one_change_shows_it_publicly_and_leaves_the_rest():
    db = _db()
    # same: "She climbs on weekends."  remove: "She bakes bread."  add: "She surfs."
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    ids = _change_ids(db)
    out = pm.apply_change(db, UID, "interests", ids["She surfs."])
    assert out["remaining"] == 1 and out["ok"] is True
    # exactly the undecided change is left to review, and re-renders on its own
    [prop] = pm.list_proposals(db, UID)
    assert [c["text"] for c in prop["changes"]] == ["She bakes bread."]
    text = pm.get_text(db, UID)["text"]
    assert "She surfs." in text  # applied addition is now public
    assert "She bakes bread." in text  # undecided removal stays public


def test_dismiss_one_change_keeps_it_in_private_profile_and_notes():
    db = _db()
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    ids = _change_ids(db)
    pm.dismiss_change(db, UID, "interests", ids["She surfs."])
    # dismissed addition is excluded from the public profile …
    assert "She surfs." not in pm.get_text(db, UID)["text"]
    # … but kept as an ai_only note and in ai_body (Ayma still knows it)
    page = _doc(db, "interests")
    assert "{{ai_only}}She surfs.{{/ai_only}}" in page["user_edits"]
    assert "She surfs." in page["ai_body"]
    notes = story.get_ai_notes(db, UID)["sections"]
    assert any(
        "She surfs." in s["body"] for s in notes if s["page_id"] == "interests"
    )


def test_applying_a_removal_keeps_the_sentence_in_notes_not_public():
    db = _db()
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    ids = _change_ids(db)
    pm.apply_change(db, UID, "interests", ids["She bakes bread."])
    assert "She bakes bread." not in pm.get_text(db, UID)["text"]
    page = _doc(db, "interests")
    assert "{{ai_only}}She bakes bread.{{/ai_only}}" in page["user_edits"]
    # the removed sentence is added to ai_body so Ayma's matching/chat keep it
    assert "She bakes bread." in page["ai_body"]


def test_deciding_every_change_clears_the_proposal():
    db = _db()
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    ids = _change_ids(db)
    pm.apply_change(db, UID, "interests", ids["She surfs."])
    out = pm.dismiss_change(db, UID, "interests", ids["She bakes bread."])
    assert out["remaining"] == 0
    assert pm.list_proposals(db, UID) == []
    assert _doc(db, "interests")["pending_proposal"] is None


def test_unknown_or_already_decided_change_raises():
    db = _db()
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    ids = _change_ids(db)
    with pytest.raises(KeyError):
        pm.apply_change(db, UID, "interests", "nope")
    pm.apply_change(db, UID, "interests", ids["She surfs."])
    with pytest.raises(KeyError):
        pm.apply_change(db, UID, "interests", ids["She surfs."])
    with pytest.raises(KeyError):
        pm.dismiss_change(db, UID, "interests", ids["She surfs."])


def test_new_suggestions_notify_once_then_not_until_something_changes():
    db = _db()
    db.docs[("users", UID)] = {}
    # No pending changes yet -> nothing to notify.
    assert pm.consume_new_suggestions(db, UID) == 0

    # Ayma proposes a rewrite: the pending count goes 0 -> 2, so notify.
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    assert pm.consume_new_suggestions(db, UID) == 2
    # A second run with nothing new must NOT re-ping.
    assert pm.consume_new_suggestions(db, UID) == 0

    # The user decides one change; still nothing *new*, so no re-ping.
    ids = _change_ids(db)
    pm.dismiss_change(db, UID, "interests", ids["She surfs."])
    assert pm.consume_new_suggestions(db, UID) == 0

    # A genuinely new suggestion on another section re-pings (with the count).
    _ingest_write(db, "career", "She is a doctor now in Boston.")
    assert pm.consume_new_suggestions(db, UID) > 0
    assert pm.consume_new_suggestions(db, UID) == 0


def test_notified_set_resets_when_nothing_is_pending():
    db = _db()
    db.docs[("users", UID)] = {}
    _ingest_write(db, "interests", "She climbs on weekends. She surfs.")
    assert pm.consume_new_suggestions(db, UID) == 2
    # Decide every change: the pending set empties and the stored set resets.
    pm.dismiss_proposal(db, UID, "interests")
    assert pm.consume_new_suggestions(db, UID) == 0
    assert db.docs[("users", UID)].get("profile_suggestions_notified") == []
    # A fresh suggestion after the reset notifies again (0 -> >0).
    _ingest_write(db, "interests", "She climbs on weekends. She paints.")
    assert pm.consume_new_suggestions(db, UID) > 0


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
    public = story.strip_private_spans(body)
    # the pinned sentence stays public …
    assert "She has a golden retriever." in public
    # … and the earlier ai_only note is kept, off the public profile
    assert "She bakes bread." in body and "She bakes bread." not in public


def test_ai_rewrite_with_same_public_text_makes_no_proposal_and_clears_stale():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    _ingest_write(db, "interests", "She climbs on weekends. She bakes bread.")
    assert pm.list_proposals(db, UID) == []


def test_list_proposals_clears_stale_and_malformed_proposals():
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    [_prop] = pm.list_proposals(db, UID)
    ref = story._pages_col(db, UID).document("interests")
    # The user's own edit now matches Ayma's rewrite: nothing left to review.
    ref.set({"user_edits": "She climbs and surfs."}, merge=True)
    assert pm.list_proposals(db, UID) == []
    assert _doc(db, "interests")["pending_proposal"] is None
    # A proposal in an unexpected shape is cleared rather than shown blank.
    ref.set({"pending_proposal": "not-a-dict"}, merge=True)
    assert pm.list_proposals(db, UID) == []
    assert _doc(db, "interests")["pending_proposal"] is None


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


def test_user_edit_suppresses_the_next_diverging_reingest():
    # Founder bug 2026-10-28: a user-requested surgical story edit
    # (edit_story_entry -> story.save_section) must never be re-surfaced — nor
    # reverted — as a pending "Public profile updates" card by a lagging
    # re-ingest. The one-shot guard swallows the next diverging rewrite.
    db = _db()
    story.save_section(
        db, UID, "interests", "She climbs on weekends. She bakes sourdough."
    )
    assert _doc(db, "interests")["suppress_next_proposal"] is True
    assert _doc(db, "interests")["pending_proposal"] is None
    # A lagging re-ingest still carries Ayma's old memory (it diverges from the
    # user's text) — no proposal, and the user's wording is left untouched.
    _ingest_write(db, "interests", "She climbs and surfs.")
    assert pm.list_proposals(db, UID) == []
    text = pm.get_text(db, UID)["text"]
    assert "She bakes sourdough." in text and "surfs" not in text
    # the guard was spent on that diverging rewrite
    assert _doc(db, "interests")["suppress_next_proposal"] is False
    # a later genuinely-new rewrite proposes normally again
    _ingest_write(
        db, "interests", "She climbs on weekends. She bakes sourdough. She paints."
    )
    assert any(
        "paints" in c["text"]
        for p in pm.list_proposals(db, UID)
        for c in p["changes"]
    )


def test_guard_is_not_wasted_on_a_no_op_reingest_in_between():
    # The guard protects the first rewrite that genuinely DIVERGES, even when a
    # no-op (unchanged) ingest pass runs in between — otherwise a stray no-op
    # could spend the guard and let the next pass revert the user's edit.
    db = _db()
    story.save_section(
        db, UID, "interests", "She climbs on weekends. She bakes sourdough."
    )
    # A no-op re-ingest (Ayma's text already matches the user's) keeps the guard.
    _ingest_write(db, "interests", "She climbs on weekends. She bakes sourdough.")
    assert _doc(db, "interests")["suppress_next_proposal"] is True
    assert pm.list_proposals(db, UID) == []
    # The next diverging pass is still swallowed by the surviving guard.
    _ingest_write(db, "interests", "She climbs and surfs.")
    assert pm.list_proposals(db, UID) == []
    assert "She bakes sourdough." in pm.get_text(db, UID)["text"]


def test_apply_all_refuses_a_stale_proposal_and_never_regresses_the_line():
    # Founder bug 2026-10-28: "Apply all" applied an OLDER proposed value,
    # reverting the user's correct edit. A proposal whose frozen base no longer
    # matches the live public text (the user edited the line to a third value)
    # is refused and cleared — never written over the user's current wording.
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    [_prop] = pm.list_proposals(db, UID)
    ref = story._pages_col(db, UID).document("interests")
    # A stale card lingers while the user has since edited the line directly.
    ref.set({"user_edits": "She climbs daily. She bakes challah."}, merge=True)
    with pytest.raises(KeyError):
        pm.apply_proposal(db, UID, "interests")
    assert _doc(db, "interests")["pending_proposal"] is None
    text = pm.get_text(db, UID)["text"]
    assert "She bakes challah." in text and "surfs" not in text
    # and the stale card self-heals off the review list on the next read
    assert pm.list_proposals(db, UID) == []


def test_only_one_card_per_section_latest_rewrite_wins():
    # No duplicate cards: a newer rewrite REPLACES the section's previous
    # pending proposal rather than piling a second one on top of it.
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    _ingest_write(db, "interests", "She climbs and paints.")
    props = pm.list_proposals(db, UID)
    assert len(props) == 1
    texts = [c["text"] for c in props[0]["changes"]]
    assert any("paints" in t for t in texts)
    assert all("surfs" not in t for t in texts)


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


# --- custom (user-titled) sections --------------------------------------


def _customs(db):
    return {
        k[3]: v
        for k, v in db.docs.items()
        if k[:3] == ("users", UID, "wiki_pages")
        and len(k) == 4
        and v.get("custom_section")
    }


def test_new_heading_creates_a_public_misc_custom_section(model):
    db = _db()
    model["kinds"] = {"a1": "added_fact"}
    text = pm.get_text(db, UID)["text"] + "\n\n## My Travel Rules\nAlways pack light."
    out = _save(db, text)
    assert out["changed"] is True and out["added_facts"] == 1
    page = _doc(db, "custom-my-travel-rules")
    assert page["page_type"] == "misc" and page["visibility"] == "public"
    assert page["title"] == "My Travel Rules" and page["custom_section"] is True
    assert page["user_hidden"] is False
    assert page["manual_pinned"] == ["Always pack light."]
    assert page["ai_body"] == "Always pack light."
    # the title was moderated together with the new text
    assert "Section title: My Travel Rules" in model["calls"][0][0]
    # it renders on the public profile under the user's title, after the rest
    sections = pm.public_sections(db, UID)
    assert sections[-1] == {
        "page_id": "custom-my-travel-rules",
        "title": "My Travel Rules",
        "body": "Always pack light.",
    }
    report, *_ = ra.story_public_blocks(db, UID)
    assert "My Travel Rules" in [s["heading"] for s in report["sections"]]
    titles = [p["title"] for p in public_profile._public_pages(db, UID)]
    assert "My Travel Rules" in titles


def test_empty_custom_heading_creates_nothing(model):
    db = _db()
    out = _save(db, pm.get_text(db, UID)["text"] + "\n\n## Empty One\n")
    assert out["changed"] is False and not _customs(db)


def test_heading_equal_to_a_known_section_maps_to_it_case_insensitively(model):
    db = _db()
    text = pm.get_text(db, UID)["text"].replace("## Interests", "## INTERESTS")
    assert _save(db, text)["changed"] is False
    assert not _customs(db)


def test_known_section_name_without_a_visible_section_is_rejected(model):
    db = _db()
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"] + "\n\n## Family\nHi there.")
    assert exc.value.code == "bad_title"
    assert not _customs(db)


@pytest.mark.parametrize(
    "title",
    [
        "x" * (pm.MAX_TITLE_CHARS + 1),
        "Call 415-555-0199",
        "Mail jo@example.com",
        "See https://example.com",
        "see www.example.com",
        "!!!",
    ],
)
def test_bad_custom_titles_are_rejected(model, title):
    db = _db()
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"] + f"\n\n## {title}\nSome text.")
    assert exc.value.code == "bad_title"
    assert not _customs(db) and model["calls"] == []


def test_flagged_custom_title_is_rejected_by_the_safety_pass(model):
    db = _db()
    model["flagged"] = True
    model["reason"] = "Not allowed."
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"] + "\n\n## Bad Title\nFine text.")
    assert exc.value.code == "moderation"
    assert not _customs(db)


def test_duplicate_new_titles_are_rejected(model):
    db = _db()
    text = pm.get_text(db, UID)["text"] + "\n\n## Pets\nA cat.\n\n## pets\nA dog."
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, text)
    assert exc.value.code == "bad_sections"


def test_custom_section_limit(model):
    db = _db()
    many = "".join(
        f"\n\n## Topic {i}\nFact {i}." for i in range(pm.MAX_CUSTOM_SECTIONS)
    )
    _save(db, pm.get_text(db, UID)["text"] + many)
    assert len(_customs(db)) == pm.MAX_CUSTOM_SECTIONS
    with pytest.raises(pm.ProfileTextError) as exc:
        _save(db, pm.get_text(db, UID)["text"] + "\n\n## One More\nFact.")
    assert exc.value.code == "too_many_sections"
    assert len(_customs(db)) == pm.MAX_CUSTOM_SECTIONS


def test_rename_keeps_the_page_and_body(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## Pets\nA cat named Miso.")
    text = pm.get_text(db, UID)["text"].replace("## Pets", "## My Animals")
    out = _save(db, text)
    assert out["sections"] == ["custom-pets"]
    assert set(_customs(db)) == {"custom-pets"}
    assert _doc(db, "custom-pets")["title"] == "My Animals"
    assert pm.public_sections(db, UID)[-1]["title"] == "My Animals"
    assert any("Section title: My Animals" in c[0] for c in model["calls"])


def test_edit_custom_section_text(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## Pets\nA cat named Miso.")
    model["kinds"] = {"r1": "removed_fact", "a1": "added_fact"}
    _save(
        db,
        pm.get_text(db, UID)["text"].replace("A cat named Miso.", "A dog named Bo."),
    )
    page = _doc(db, "custom-pets")
    assert story.strip_private_spans(page["user_edits"]) == "A dog named Bo."
    assert "{{ai_only}}A cat named Miso.{{/ai_only}}" in page["user_edits"]


def test_deleting_a_custom_section_keeps_facts_in_notes_and_it_can_return(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## Pets\nA cat named Miso.")
    model["kinds"] = {"r1": "removed_fact"}
    text = pm.get_text(db, UID)["text"].replace("## Pets\nA cat named Miso.", "")
    out = _save(db, text)
    assert out["removed_to_notes"] == 1
    page = _doc(db, "custom-pets")
    assert "{{ai_only}}A cat named Miso.{{/ai_only}}" in page["user_edits"]
    assert all(s["page_id"] != "custom-pets" for s in pm.public_sections(db, UID))
    notes = story.get_ai_notes(db, UID)["sections"]
    assert any("Miso" in s["body"] for s in notes if s["page_id"] == "custom-pets")
    # the same title again revives the same page and keeps the retained note
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## pets\nTwo cats now.")
    assert set(_customs(db)) == {"custom-pets"}
    page = _doc(db, "custom-pets")
    assert "{{ai_only}}A cat named Miso.{{/ai_only}}" in page["user_edits"]
    assert story.strip_private_spans(page["user_edits"]) == "Two cats now."


def test_non_latin_title_gets_a_valid_page_id(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## 趣味\nHiking.")
    (page_id,) = _customs(db)
    assert is_valid_page_id(page_id)


def test_custom_ids_never_collide(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## Pets!\nA cat.\n\n## Pets?\nA dog.")
    assert set(_customs(db)) == {"custom-pets", "custom-pets-2"}


def test_ai_proposal_for_a_custom_section_uses_its_title(model):
    db = _db()
    _save(db, pm.get_text(db, UID)["text"] + "\n\n## Pets\nA cat named Miso.")
    cur = _doc(db, "custom-pets")
    cur.update(
        pm.route_ai_update(
            "custom-pets",
            cur,
            {"visibility": "public", "ai_body": "A cat named Miso. And a dog."},
        )
    )
    assert [p["title"] for p in pm.list_proposals(db, UID)] == ["Pets"]


# --- founder bug 2026-10-28: duplicate / garbled / resurrected proposals ----


def test_reworded_pin_is_not_resurrected_as_a_proposal():
    # Founder bug: the user edited "speaks Malayalam, English, and Tamil and
    # Hindi" down to "Malayalam and English", but the older wording lingered in
    # manual_pinned. preserve() re-appended it verbatim because it was no longer
    # a substring, so a rewrite that otherwise matched the user's text still
    # produced a spurious Apply/Dismiss card. A pinned sentence already present
    # as a reworded restatement must not be re-attached.
    db = _db()
    _page(
        db,
        "identity",
        ai_body="He currently lives in San Jose and speaks Malayalam and English.",
        user_edits="He currently lives in San Jose and speaks Malayalam and English.",
        manual_pinned=[
            "He currently lives in San Jose and speaks Malayalam, English, "
            "and Tamil and Hindi"
        ],
    )
    # Ayma re-ingests the same (user-approved) fact.
    _ingest_write(
        db, "identity",
        "He currently lives in San Jose and speaks Malayalam and English.",
    )
    # No card: the rewrite matches the live public text once the stale pin is
    # no longer force-appended.
    assert pm.list_proposals(db, UID) == []
    text = pm.get_text(db, UID)["text"]
    # and the sentence appears exactly once — no garbled duplicate.
    assert text.count("speaks Malayalam") == 1
    assert "Tamil and Hindi" not in text


def test_apply_does_not_duplicate_a_reworded_pinned_fact():
    # Founder bug: a stale pinned sentence ("bachelors of science") that the
    # user had reworded ("BTech") was appended on apply, leaving both variants —
    # "...BTech... ...bachelors of science..." — garbled duplicate text. Apply
    # must write the current value once, never re-add the superseded wording.
    db = _db()
    _page(
        db,
        "career",
        ai_body="She is a nurse. She completed her BTech at MG University.",
        user_edits="She is a nurse. She completed her BTech at MG University.",
        manual_pinned=["She completed her bachelors of science at MG University."],
    )
    _ingest_write(
        db, "career",
        "She is a surgeon. She completed her BTech at MG University.",
    )
    [prop] = pm.list_proposals(db, UID)
    # the proposal is only the real nurse->surgeon change, no stale-pin noise
    assert any(c["op"] == "add" and "surgeon" in c["text"] for c in prop["changes"])
    assert all("bachelors of science" not in c["text"] for c in prop["changes"])
    pm.apply_proposal(db, UID, "career")
    public = story.strip_private_spans(_doc(db, "career")["user_edits"])
    assert "surgeon" in public
    assert public.count("MG University") == 1  # the fact once, no duplicate
    assert "bachelors of science" not in public
    # the superseded pin is pruned from the stored list, not carried forward
    assert "bachelors of science" not in " ".join(
        _doc(db, "career").get("manual_pinned") or []
    )


def test_genuinely_distinct_pin_is_still_kept_on_apply():
    # The dedupe must not over-suppress: a pinned fact that is NOT a restatement
    # of anything in the rewrite is still guaranteed to stay public.
    db = _db()
    _page(
        db,
        "interests",
        ai_body="She climbs on weekends.",
        user_edits="She climbs on weekends.",
        manual_pinned=["She volunteers at an animal shelter."],
    )
    _ingest_write(db, "interests", "She climbs and surfs.")
    pm.apply_proposal(db, UID, "interests")
    public = story.strip_private_spans(_doc(db, "interests")["user_edits"])
    assert "She volunteers at an animal shelter." in public
    assert "surfs" in public


def test_duplicate_change_rows_are_collapsed_in_the_review_card():
    # Even if a messy frozen base repeats a sentence, the card never shows the
    # same change twice.
    before = "She bakes bread. She bakes bread."
    after = "She paints."
    items = pm._change_items(
        story.strip_private_spans(before), story.strip_private_spans(after)
    )
    # the raw change list carries every decidable position …
    assert sum(1 for it in items if it["op"] == "remove") == 2
    # … but the displayed rows collapse the identical removals to one.
    shown = pm._dedupe_changes(items)
    removes = [c for c in shown if c["op"] == "remove"]
    assert len(removes) == 1


def test_recent_user_edit_suppresses_lagging_reingest_across_the_window():
    # Founder bug: one stale ingest could spend the one-shot guard and the NEXT
    # lagging pass would then revert the user's edit. Any re-ingest landing
    # within the suppression window of the user's edit is swallowed — even when
    # the explicit one-shot flag is already gone.
    db = _db()
    _page(
        db,
        "interests",
        ai_body="She climbs on weekends.",
        user_edits="She climbs on weekends. She bakes sourdough.",
        user_updated_at=datetime.now(timezone.utc),  # just edited
        # note: no suppress_next_proposal flag set at all
    )
    _ingest_write(db, "interests", "She climbs and surfs.")  # diverging, lagging
    assert pm.list_proposals(db, UID) == []
    assert "She bakes sourdough." in pm.get_text(db, UID)["text"]
    assert "surfs" not in pm.get_text(db, UID)["text"]


def test_old_user_edit_outside_window_lets_a_genuine_rewrite_propose():
    # Once the window lapses, a genuinely new Ayma discovery surfaces normally.
    db = _db()
    _page(
        db,
        "interests",
        ai_body="She climbs on weekends.",
        user_edits="She climbs on weekends.",
        user_updated_at=datetime.now(timezone.utc) - timedelta(hours=2),
    )
    _ingest_write(db, "interests", "She climbs on weekends. She paints.")
    assert any(
        "paints" in c["text"]
        for p in pm.list_proposals(db, UID)
        for c in p["changes"]
    )


def test_only_one_pending_proposal_field_per_section():
    # Structural guarantee behind "one card per section": pending_proposal is a
    # single dict the latest rewrite overwrites — never a growing collection.
    db = _db()
    _ingest_write(db, "interests", "She climbs and surfs.")
    _ingest_write(db, "interests", "She climbs and paints.")
    prop = _doc(db, "interests")["pending_proposal"]
    assert isinstance(prop, dict)
    assert "paints" in prop["after"] and "surfs" not in prop["after"]
