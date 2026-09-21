"""Round-trip tests for report_adapters.py: a known, realistic Firestore-doc
shape from each real producer -> the block model -> every field that matters
actually made it across. Each producer's own read function is monkeypatched
directly (``appearance.get_report``, ``deep_dive.read_dive``,
``story.get_story`` / ``get_ai_notes``, ``matching_skill.read_match``) so
these tests never touch Firestore and stay pinned to the real return shape
those functions document."""

import appearance
import deep_dive
import matching_skill
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
        "source_photos": ["users/u1/photos/a.jpg", "users/u1/photos/b.jpg"],
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
        "source_photos": ["users/u1/photos/a.jpg"],
    },
    "body": {"status": "needs_body_photo"},
    "photo_count": 3,
}


def _fake_photo_url(monkeypatch):
    """Deterministic stand-in for ``public_profile._photo_url`` — turns a
    Storage path into ``https://cdn/<path>`` so tests can assert on it
    without touching real Firebase Storage. Returns ``None`` (drops the
    photo) for a path containing "missing", exercising the fail-soft path."""
    import public_profile

    def fake(path: str):
        if not path or "missing" in path:
            return None
        return f"https://cdn/{path}"

    monkeypatch.setattr(public_profile, "_photo_url", fake)


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


def test_appearance_adapter_attributes_section_includes_every_source_photo(monkeypatch):
    """§ regression fix: the Attributes section used to show a row of photo
    thumbnails under "ATTRIBUTES" — "which photos were actually used" for
    the structured attribute read. That's ``attributes.source_photos`` on
    the persisted report — this pins it down as a ``photo_grid`` block
    carrying EVERY source photo (founder: "Include all pictures used for
    the aggregate"), not just one."""
    _fake_photo_url(monkeypatch)
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_APPEARANCE_DOC))
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    grid = blocks["attr:photos"]
    assert grid["type"] == rb.PHOTO_GRID
    assert grid["editable"] is False
    assert grid["photos"] == [
        {"url": "https://cdn/users/u1/photos/a.jpg"},
        {"url": "https://cdn/users/u1/photos/b.jpg"},
    ]
    # it's part of the Attributes section, alongside the field rows
    headings = {sec["heading"]: sec for sec in report["sections"]}
    assert any(b["block_id"] == "attr:photos" for b in headings["Attributes"]["blocks"])


def test_appearance_adapter_attributes_photo_grid_drops_unresolvable_paths(monkeypatch):
    """A path ``public_profile._photo_url`` can't resolve (deleted photo,
    missing blob) is dropped, not shown as a broken thumbnail."""
    _fake_photo_url(monkeypatch)
    doc = dict(_APPEARANCE_DOC)
    doc["attributes"] = dict(
        doc["attributes"],
        source_photos=[
            "users/u1/photos/a.jpg",
            "users/u1/photos/missing.jpg",
            "users/u1/photos/b.jpg",
        ],
    )
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: doc)
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["attr:photos"]["photos"] == [
        {"url": "https://cdn/users/u1/photos/a.jpg"},
        {"url": "https://cdn/users/u1/photos/b.jpg"},
    ]


def test_appearance_adapter_attributes_no_photo_block_when_no_source_photos(monkeypatch):
    _fake_photo_url(monkeypatch)
    doc = dict(_APPEARANCE_DOC)
    doc["attributes"] = dict(doc["attributes"], source_photos=[])
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: doc)
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert "attr:photos" not in blocks and "attr:photo" not in blocks


def test_appearance_adapter_face_and_body_each_show_their_own_source_photo(monkeypatch):
    """Face/Body each read off exactly one best photo (``face_report.run``/
    ``body_report.run``'s own single-item ``source_photos``) — a single
    ``photo`` block, not a grid."""
    _fake_photo_url(monkeypatch)
    doc = dict(_APPEARANCE_DOC)
    doc["body"] = {
        "usable": True, "overall_score": 6.0, "verdict": "Average",
        "source_photos": ["users/u1/photos/c.jpg"],
    }
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: doc)
    report, *_ = ra.appearance_blocks(object(), "u1")
    blocks = _blocks(report)
    assert blocks["face:photo"]["type"] == rb.PHOTO
    assert blocks["face:photo"]["url"] == "https://cdn/users/u1/photos/a.jpg"
    assert blocks["face:photo"]["editable"] is False
    assert blocks["body:photo"]["url"] == "https://cdn/users/u1/photos/c.jpg"


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

    link_id = "link:https://x.com/a"
    assert blocks[link_id]["url"] == "https://x.com/a"
    # Editable by default (§ deep_dive.dispute_link) — same as social_blocks
    # right below: a plain web link is just as correctable/removable as a
    # social-profile link, not a client-side dead end.
    assert blocks[link_id]["editable"] is True

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


_PA_TWO_FIELDS = {
    "fields": {
        "eye_color": {"value": "brown", "source": "stated", "confidence": "high"},
        "build": {"value": "athletic", "source": "photo", "confidence": "medium"},
        "hair_color": {"value": "unknown", "source": "none", "confidence": "none"},
    },
    "photo_count": 2,
}


# --- attribute visibility (§ founder follow-up 2026-09-20: attributes are --
# PRIVATE BY DEFAULT on the Story-public Living Report — every field stays
# off a stranger's view of someone's public Story until the owner explicitly
# makes it public via the make-public/make-private quick action
# (physical_attributes.set_public, routed through report_hub). The owner's
# own view, by contrast, still sees every known field (§ point 5: so they
# can review/toggle them), each carrying its real public/private state.


def test_story_public_adapter_hides_every_attribute_by_default_from_a_stranger(monkeypatch):
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: dict(_PA_TWO_FIELDS))
    monkeypatch.setattr(physical_attributes, "public_fields", lambda db, uid: set())
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1", viewer_uid="stranger-uid")
    headings = [sec["heading"] for sec in report["sections"]]
    # no Attributes section at all — nothing is public yet.
    assert headings == ["Identity"]


def test_story_public_adapter_omits_attributes_for_a_stranger_when_viewer_uid_missing(monkeypatch):
    """Fails closed, mirroring `deep_dive_blocks`'s candidate gating: a
    caller that forgets to pass `viewer_uid` gets the same (attribute-free,
    unless something's actually public) result as a stranger, never the
    owner's full review view."""
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: dict(_PA_TWO_FIELDS))
    monkeypatch.setattr(physical_attributes, "public_fields", lambda db, uid: set())
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Identity"]


def test_story_public_adapter_shows_a_stranger_only_the_made_public_fields(monkeypatch):
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: dict(_PA_TWO_FIELDS))
    monkeypatch.setattr(physical_attributes, "public_fields", lambda db, uid: {"eye_color"})
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1", viewer_uid="stranger-uid")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Attributes", "Identity"]
    blocks = _blocks(report)
    assert blocks["attr:eye_color"]["value"] == "brown"
    # made-public field never carries a `public` key for a non-owner — it's
    # already, definitionally, the public subset.
    assert "public" not in blocks["attr:eye_color"]
    # the still-private field never shows up at all for a stranger.
    assert "attr:build" not in blocks
    # unknown-valued fields are dropped here exactly like in the Appearance
    # adapter — same helper, same rule.
    assert "attr:hair_color" not in blocks


def test_story_public_adapter_owner_sees_every_field_with_its_real_visibility(monkeypatch):
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: dict(_PA_TWO_FIELDS))
    monkeypatch.setattr(physical_attributes, "public_fields", lambda db, uid: {"eye_color"})
    monkeypatch.setattr(story, "get_story", lambda db, uid: _STORY_DATA)
    report, *_ = ra.story_public_blocks(object(), "u1", viewer_uid="u1")
    blocks = _blocks(report)
    assert blocks["attr:eye_color"]["value"] == "brown"
    assert blocks["attr:eye_color"]["public"] is True
    assert blocks["attr:build"]["value"] == "athletic"
    assert blocks["attr:build"]["public"] is False
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


def test_story_adapters_exclude_report_linked_pages(monkeypatch):
    """``face-analysis``/``body-analysis``/``physical-profile``/
    ``web-findings`` already have their own dedicated report type
    (``appearance``/``deep_dive``) and their own client-side summary-card +
    link treatment (``story.py``: "to avoid showing the same report twice")
    — none of the three Story adapters should also emit them as plain
    sentence blocks."""
    data = {
        "sections": [
            {
                "page_id": "career", "title": "Career",
                "body": "Real narrative text.", "visibility": "public",
            },
            {
                "page_id": "face-analysis", "title": "Facial analysis",
                "body": "Overall 8/10 — strong jawline.", "visibility": "public",
                "report_id": "current",
            },
            {
                "page_id": "web-findings", "title": "Web findings",
                "body": "Overall confidence: high.", "visibility": "public",
                "report_id": "dive1",
            },
        ]
    }
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: None)
    monkeypatch.setattr(story, "get_story", lambda db, uid: data)
    monkeypatch.setattr(story, "get_ai_notes", lambda db, uid: data)

    for build in (ra.story_private_blocks, ra.story_ai_notes_blocks):
        report, *_ = build(object(), "u1")
        headings = [sec["heading"] for sec in report["sections"]]
        assert headings == ["Career"]
        blocks = _blocks(report)
        assert not any(k.startswith("page:face-analysis:") for k in blocks)
        assert not any(k.startswith("page:web-findings:") for k in blocks)

    report, *_ = ra.story_public_blocks(object(), "u1")
    headings = [sec["heading"] for sec in report["sections"]]
    assert headings == ["Career"]


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


# --- match -------------------------------------------------------------
#
# Match is read-only for both participants and has NO correction path at all
# (§ ra.match_blocks's own docstring, § report_hub.py's module docstring) —
# a match score is algorithmically computed, not user-authored content.
# Every block the adapter builds is therefore ``editable=False``; these
# tests pin that down explicitly, not just the field values.

_MATCH_DOC = {
    "score": 0.82,
    "score_confidence": 0.7,
    "confidence_note": "High confidence — both profiles are detailed.",
    "method": "Five dimensions measured from your answers; two estimated.",
    "user_explanation": {
        "alice-uid": "You two share a lot of values. Your rhythms differ a bit.",
        "bob-uid": "Bob's own version of the same note.",
    },
    "dimensions": [
        {
            "key": "values", "label": "Values & worldview", "weight": 0.22,
            "score": 88.0, "rationale": "Both prioritize family closely.",
            "evidence": ["Both mention weekly family calls."],
            "confidence": "high", "source": "structured", "covered_nodes": ["n1", "n2"],
        },
        {
            "key": "interests", "label": "Shared interests", "weight": 0.04,
            "score": 60.0, "rationale": "Some overlap in hobbies.",
            "evidence": [], "confidence": "medium", "source": "llm", "covered_nodes": [],
        },
    ],
    "omitted_dimensions": ["communication"],
    "shared": ["Both value family closeness"],
    "tensions": ["Different social energy levels"],
    "missing": ["Communication & emotional needs"],
    "gate_failures": [],
}


def test_match_adapter_carries_score_and_viewers_own_explanation(monkeypatch):
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, created, updated = ra.match_blocks(
        object(), "alice-uid", "alice-uid__bob-uid"
    )
    blocks = _blocks(report)
    assert blocks["score"]["value"] == "82%"
    assert blocks["score"]["basis"] == "High confidence"
    assert blocks["explanation:sent:0"]["text"] == "You two share a lot of values."
    assert blocks["explanation:sent:1"]["text"] == "Your rhythms differ a bit."
    # never the OTHER participant's own explanation text
    full_text = " ".join(
        b["text"] for sec in report["sections"] for b in sec["blocks"] if "text" in b
    )
    assert "Bob's own version" not in full_text
    assert report["title"] == "Match with Bob Bee"


def test_match_adapter_shows_the_other_participants_explanation_for_them(monkeypatch):
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Alice A")
    report, *_ = ra.match_blocks(object(), "bob-uid", "alice-uid__bob-uid")
    blocks = _blocks(report)
    assert blocks["explanation:sent:0"]["text"] == "Bob's own version of the same note."


def test_match_adapter_carries_dimension_score_weight_and_evidence(monkeypatch):
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, *_ = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    blocks = _blocks(report)
    assert blocks["dim:values"]["value"] == 88.0
    assert blocks["dim:values"]["basis"] == "22% weight · measured"
    assert blocks["dim:values:rationale"]["text"] == "Both prioritize family closely."
    assert blocks["dim:values:evidence:0"]["text"] == "Both mention weekly family calls."
    assert blocks["dim:interests"]["basis"] == "4% weight · estimated"
    # no evidence given for "interests" -> no evidence block, no crash
    assert "dim:interests:evidence:0" not in blocks


def test_match_adapter_omitted_dimension_produces_no_blocks(monkeypatch):
    """§ today's fix: a dimension neither pass could ground in real evidence
    is left OUT of the persisted `dimensions` list entirely (see
    matching_skill._merge_dimensions) rather than defaulted to a fabricated
    score. The adapter must not invent one either — it only ever iterates
    `dimensions`, so "communication" (named in `omitted_dimensions`, absent
    from `dimensions`) gets zero blocks and zero section, exactly like every
    other omitted dimension."""
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, *_ = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    headings = [sec["heading"] for sec in report["sections"]]
    assert "Communication & emotional needs" not in headings
    blocks = _blocks(report)
    assert not any(bid.startswith("dim:communication") for bid in blocks)
    # it's still surfaced under "what'd sharpen this score" — this adapter
    # doesn't drop the fact it was omitted, just the fabricated number.
    assert "Communication & emotional needs" in [
        b["text"] for b in blocks.values() if b["block_id"].startswith("missing:")
    ]


def test_match_adapter_dealbreakers_section(monkeypatch):
    doc = dict(_MATCH_DOC)
    doc["gate_failures"] = [
        {"node_id": "relationship_intent", "label": "Relationship intent", "reason": "One wants casual, the other serious."},
    ]
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: doc)
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, *_ = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    blocks = _blocks(report)
    assert blocks["dealbreaker:0"]["text"] == "One wants casual, the other serious."
    assert blocks["dealbreaker:0"]["tag"] == "Relationship intent"


def test_match_adapter_none_when_never_scored(monkeypatch):
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: None)
    report, created, updated = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    assert report is None and created is None and updated is None


def test_match_adapter_none_for_a_malformed_match_id(monkeypatch):
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    report, *_ = ra.match_blocks(object(), "alice-uid", "not-a-pair-key")
    assert report is None


def test_match_adapter_every_block_is_uncorrectable(monkeypatch):
    """No block this adapter builds is ever a real correction target (§
    module docstring / report_hub.py's `correct()`: there is no mutation
    path for `match` at all) — pin that down as a property of every block,
    not just the ones exercised by name above."""
    doc = dict(_MATCH_DOC)
    doc["gate_failures"] = [{"label": "L", "reason": "R"}]
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: doc)
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, *_ = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    for sec in report["sections"]:
        for b in sec["blocks"]:
            assert b["editable"] is False, b["block_id"]


def test_match_adapter_placeholder_when_not_scored_but_doc_thin(monkeypatch):
    """Defensive: a persisted doc with no `score` and no explanation for this
    viewer (shouldn't happen in practice — `_match_job` only ever writes a
    doc once scoring succeeds — but the adapter fails soft, not with a
    crash or an empty, confusing report)."""
    monkeypatch.setattr(
        matching_skill, "read_match",
        lambda db, mid: {"user_explanation": {}, "dimensions": []},
    )
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Bob Bee")
    report, *_ = ra.match_blocks(object(), "alice-uid", "alice-uid__bob-uid")
    blocks = _blocks(report)
    assert blocks["score:status"]["type"] == rb.SECTION_HEAD
