"""Round-trip tests for report_adapters.py: a known, realistic Firestore-doc
shape from each real producer -> the block model -> every field that matters
actually made it across. Each producer's own read function is monkeypatched
directly (``appearance.get_report``, ``deep_dive.read_dive``,
``story.get_story`` / ``get_ai_notes``) so these tests never touch Firestore
and stay pinned to the real return shape those functions document."""

import appearance
import deep_dive
import physical_attributes
import report_adapters as ra
import report_blocks as rb
import story


def _blocks(report):
    return {b["block_id"]: b for sec in report["sections"] for b in sec["blocks"]}


# --- appearance ----------------------------------------------------------

_APPEARANCE_DOC = {
    "id": "current",
    "created_at": None,
    "attributes": {
        "record": {
            "eye_color": {"value": "brown", "source": "stated", "confidence": "high"},
            "height_estimate_cm": {"value": 180, "source": "photo", "confidence": "medium"},
            "hair_color": {"value": "unknown", "source": "none", "confidence": "none"},
        },
        "summary": "Physical profile — eyes: brown.",
    },
    "face": {
        "usable": True,
        "overall_score": 7.5,
        "verdict": "Above average",
        "verdict_note": "Clear skin, symmetric features.",
        "strengths": ["Strong jawline"],
        "improvements": ["Trim the beard"],
        "recommendations": [{"category": "skincare", "text": "Use SPF daily"}],
        "quick_facts": {"face_shape": "oval", "age_estimate": ""},
    },
    "body": {"status": "needs_body_photo"},
    "photo_count": 3,
}


def test_appearance_adapter_carries_every_known_attribute(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    report, created, updated = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["attr:eye_color"]["value"] == "brown"
    assert blocks["attr:eye_color"]["source"] == "stated"
    assert blocks["attr:height_estimate_cm"]["value"] == 180
    # unknown-valued fields are dropped, not carried across as noise
    assert "attr:hair_color" not in blocks


def test_appearance_adapter_carries_face_axis_fields(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["face"]["value"] == 7.5
    assert blocks["face"]["basis"] == "Above average"
    assert blocks["face:note"]["text"] == "Clear skin, symmetric features."
    assert blocks["face:strength:0"]["text"] == "Strong jawline"
    assert blocks["face:improvement:0"]["text"] == "Trim the beard"
    assert blocks["face:reco:0"]["text"] == "Use SPF daily"
    assert blocks["face:reco:0"]["tag"] == "skincare"
    assert blocks["face:quick:face_shape"]["value"] == "oval"
    # a blank quick_fact never becomes a block
    assert "face:quick:age_estimate" not in blocks


def test_appearance_adapter_body_axis_status_placeholder(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["body:status"]["type"] == rb.SECTION_HEAD
    assert blocks["body:status"]["editable"] is False


def test_appearance_adapter_none_when_no_report(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: None)
    report, created, updated = ra.appearance_blocks(object(), "u1")
    assert report is None and created is None and updated is None


# --- deep-dive -------------------------------------------------------------

_DIGEST = {
    "name": "Jane Doe",
    "summary": "Works as a designer. Lives in Austin.",
    "confidence": "high",
    "caveats": "Common name, some ambiguity.",
    "facts": [
        {"id": "f1", "claim": "Studied at MIT", "category": "education", "confidence": "high"},
    ],
    "links": [{"url": "https://x.com/a", "title": "Profile", "is_them": "likely"}],
    "social_handles": [
        {"platform": "instagram", "handle": "janedoe", "url": "https://instagram.com/janedoe"}
    ],
    "web_images": [{"url": "https://img/1.jpg", "source_page": "https://src", "verified": True}],
    "confirmed_photos": [
        {"image_url": "https://img/2.jpg", "source_title": "Some site"}
    ],
}

_DIVE_DOC = {
    "digest": _DIGEST,
    "name": "Jane Doe",
    "target_uid": "",
    "created_at": None,
    "updated_at": None,
}


def test_deep_dive_adapter_carries_summary_facts_links_socials_photos(monkeypatch):
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: dict(_DIVE_DOC))
    report, created, updated = ra.deep_dive_blocks(object(), "u1", "name_jane-doe")
    blocks = _blocks(report)

    assert blocks["summary:sent:0"]["text"] == "Works as a designer."
    assert blocks["summary:sent:1"]["text"] == "Lives in Austin."
    assert blocks["confidence"]["value"] == "high"
    assert blocks["caveats"]["text"] == "Common name, some ambiguity."

    assert blocks["fact:f1"]["text"] == "Studied at MIT"
    assert blocks["fact:f1"]["tag"] == "education"

    assert blocks["link:0"]["url"] == "https://x.com/a"
    assert blocks["link:0"]["editable"] is False

    social_id = "social:https://instagram.com/janedoe"
    assert blocks[social_id]["label"] == "@janedoe"

    photo_id = "photo:https://img/1.jpg"
    assert blocks[photo_id]["verified"] is True
    assert blocks[photo_id]["caption"] == "https://src"

    confirmed = blocks["confirmed_photos"]
    assert confirmed["type"] == rb.PHOTO_GRID
    assert confirmed["photos"] == [{"url": "https://img/2.jpg", "caption": "Some site"}]

    assert report["title"] == "Web search: Jane Doe"


def test_deep_dive_adapter_none_when_no_dive(monkeypatch):
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: None)
    report, created, updated = ra.deep_dive_blocks(object(), "u1", "nope")
    assert report is None


def test_deep_dive_adapter_omits_empty_sections(monkeypatch):
    doc = dict(_DIVE_DOC)
    doc["digest"] = {"name": "Nobody", "summary": "", "confidence": "not_found", "facts": [], "links": []}
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: doc)
    report, *_ = ra.deep_dive_blocks(object(), "u1", "name_nobody")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Summary"]


# --- pending reverse-image-search candidates (§ founder: replaces the ------
# standalone Photo candidates screen) ---------------------------------------

_CANDIDATE = {
    "candidate_id": "cand1",
    "image_url": "https://web/found.jpg",
    "match_type": "similar",
    "source_url": "https://somesite.com/page",
    "source_title": "Some Site Gallery",
    "source_domain": "somesite.com",
    "status": "pending",
}


def test_deep_dive_adapter_includes_candidates_for_the_owner(monkeypatch):
    import reverse_image_search

    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: dict(_DIVE_DOC))
    monkeypatch.setattr(
        reverse_image_search, "list_candidates", lambda db, uid: [dict(_CANDIDATE)]
    )
    report, *_ = ra.deep_dive_blocks(object(), "owner-uid", "name_jane-doe", viewer_uid="owner-uid")
    blocks = _blocks(report)
    b = blocks["candidate:cand1"]
    assert b["type"] == rb.PHOTO
    assert b["url"] == "https://web/found.jpg"
    assert b["caption"] == "Some Site Gallery"
    assert b["status"] == "pending"
    assert b["editable"] is True
    headings = [sec["heading"] for sec in report["sections"]]
    assert "Photos to confirm" in headings


def test_deep_dive_adapter_omits_candidates_for_a_non_owner(monkeypatch):
    import reverse_image_search

    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: dict(_DIVE_DOC))
    calls = []
    monkeypatch.setattr(
        reverse_image_search, "list_candidates",
        lambda db, uid: calls.append(uid) or [dict(_CANDIDATE)],
    )
    report, *_ = ra.deep_dive_blocks(
        object(), "owner-uid", "name_jane-doe", viewer_uid="someone-else"
    )
    headings = [sec["heading"] for sec in report["sections"]]
    assert "Photos to confirm" not in headings
    # never even queried for a non-owner viewer — belt & suspenders against
    # a future change accidentally leaking pending candidates in a log/trace.
    assert calls == []


def test_deep_dive_adapter_omits_candidates_when_viewer_uid_not_given(monkeypatch):
    """Fails closed: a caller that forgets to pass ``viewer_uid`` gets the
    same (candidate-free) result as a non-owner, never the owner's."""
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: dict(_DIVE_DOC))
    report, *_ = ra.deep_dive_blocks(object(), "owner-uid", "name_jane-doe")
    headings = [sec["heading"] for sec in report["sections"]]
    assert "Photos to confirm" not in headings


def test_deep_dive_adapter_omits_the_section_when_no_pending_candidates(monkeypatch):
    import reverse_image_search

    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: dict(_DIVE_DOC))
    monkeypatch.setattr(reverse_image_search, "list_candidates", lambda db, uid: [])
    report, *_ = ra.deep_dive_blocks(object(), "owner-uid", "name_jane-doe", viewer_uid="owner-uid")
    headings = [sec["heading"] for sec in report["sections"]]
    assert "Photos to confirm" not in headings


# --- story -----------------------------------------------------------------

_STORY_DATA = {
    "sections": [
        {
            "page_id": "identity",
            "title": "Identity",
            "body": "I'm a product designer. I grew up in Ohio.",
            "visibility": "public",
        },
        {
            "page_id": "career",
            "title": "Career",
            "body": "Worked at three startups.",
            "visibility": "private",
        },
    ]
}


def test_story_private_adapter_carries_every_section_and_sentence(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_private_blocks(object(), "u1")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Identity", "Career"]
    blocks = _blocks(report)
    assert blocks["page:identity:sent:0"]["text"] == "I'm a product designer."
    assert blocks["page:identity:sent:1"]["text"] == "I grew up in Ohio."
    assert blocks["page:career:sent:0"]["text"] == "Worked at three startups."


def test_story_public_adapter_only_includes_public_sections(monkeypatch):
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: None)
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Identity"]
    blocks = _blocks(report)
    assert "page:career:sent:0" not in blocks


def test_story_public_adapter_converges_physical_attributes(monkeypatch):
    """§ founder direction 2026-09-20: the former "My public profile"
    self-view's structured fields (ethnicity, eyes, hair, height, ...) are
    now part of the SAME Living Report the Story-public adapter builds,
    not a second parallel data source — as an "Attributes" section ahead
    of the narrative Story sections, built the exact same way Appearance's
    own Attributes section is."""
    monkeypatch.setattr(
        physical_attributes, "current",
        lambda db, uid: {
            "fields": {
                "eye_color": {"value": "brown", "source": "stated", "confidence": "high"},
                "hair_color": {"value": "unknown", "source": "none", "confidence": "none"},
            },
            "photo_count": 2,
        },
    )
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Attributes", "Identity"]
    blocks = _blocks(report)
    assert blocks["attr:eye_color"]["value"] == "brown"
    assert blocks["attr:eye_color"]["source"] == "stated"
    # unknown-valued fields are dropped here exactly like in the Appearance
    # adapter — same helper, same rule.
    assert "attr:hair_color" not in blocks


def test_story_public_adapter_strips_private_spans(monkeypatch):
    data = {
        "sections": [
            {
                "page_id": "identity",
                "title": "Identity",
                "body": "Public bit. {{private}}Secret bit.{{/private}} More public.",
                "visibility": "public",
            }
        ]
    }
    monkeypatch.setattr(story, "get_story", lambda db, uid: data)
    report, *_ = ra.story_public_blocks(object(), "u1")
    full_text = " ".join(
        b["text"] for sec in report["sections"] for b in sec["blocks"] if "text" in b
    )
    assert "Secret bit" not in full_text
    assert "Public bit" in full_text and "More public" in full_text


def test_story_ai_notes_adapter_includes_ai_only_material(monkeypatch):
    data = {
        "sections": [
            {
                "page_id": "identity",
                "title": "Identity",
                "body": "Kept passage. {{ai_only}}Removed passage.{{/ai_only}}",
                "visibility": "private",
            }
        ]
    }
    monkeypatch.setattr(story, "get_ai_notes", lambda db, uid: data)
    report, *_ = ra.story_ai_notes_blocks(object(), "u1")
    full_text = " ".join(
        b["text"] for sec in report["sections"] for b in sec["blocks"] if "text" in b
    )
    assert "Removed passage" in full_text
    assert report["title"] == "Ayma's Notes"


def test_story_adapter_empty_section_gets_placeholder(monkeypatch):
    data = {"sections": [{"page_id": "misc", "title": "Misc", "body": "", "visibility": "private"}]}
    monkeypatch.setattr(story, "get_story", lambda db, uid: data)
    report, *_ = ra.story_private_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["page:misc:empty"]["type"] == rb.SECTION_HEAD


# --- teaser convergence (§ founder follow-up 2026-09-20) -------------------
#
# face_report.teaser / body_report.teaser and report_adapters._axis_blocks
# used to independently hand-maintain the exact same "usable: False" copy —
# the drift risk being flagged here. Pin them together so a future edit to
# one that forgets the other fails a test instead of silently diverging.


def test_axis_not_usable_text_matches_face_report_engine_exactly():
    import face_report

    assert ra._AXIS_NOT_USABLE_TEXT["face"] == face_report._NOT_USABLE


def test_axis_not_usable_text_matches_body_report_engine_exactly():
    import body_report

    assert ra._AXIS_NOT_USABLE_TEXT["body"] == body_report._NOT_USABLE


def test_deep_dive_teaser_and_adapter_agree_on_emptiness(monkeypatch):
    """deep_dive.teaser() and report_adapters.deep_dive_blocks() must reach
    the SAME not-found/thin-result verdict for the same digest — both go
    through report_blocks.digest_is_empty now, so this can no longer drift
    (the report placeholder text and the chat teaser text stay each
    producer's own wording; only the underlying condition is shared)."""
    thin_digest = {"name": "Nobody", "confidence": "not_found", "summary": "", "facts": [], "links": []}
    assert "didn't find much" in deep_dive.teaser(thin_digest)

    doc = dict(_DIVE_DOC)
    doc["digest"] = thin_digest
    monkeypatch.setattr(deep_dive, "read_dive", lambda db, uid, rid: doc)
    report, *_ = ra.deep_dive_blocks(object(), "u1", "name_nobody")
    blocks = _blocks(report)
    assert blocks["summary:status"]["type"] == rb.SECTION_HEAD


def test_face_report_teaser_and_appearance_adapter_agree_on_a_bad_photo(monkeypatch):
    """The exact same input (a face_report.run()-shaped ``usable: False``
    result) must produce the exact same block/teaser text whether it's read
    through the chat-time engine teaser or through the persisted Appearance
    adapter — same underlying ``report_blocks.scored_result_blocks`` call."""
    import face_report

    bad = {"usable": False}
    chat_text = face_report.teaser(bad)
    appearance_doc = dict(_APPEARANCE_DOC, face=bad)
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: appearance_doc)
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["face:status"]["text"] == chat_text
