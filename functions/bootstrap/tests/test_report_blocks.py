import report_blocks as rb


# --- block constructors ---------------------------------------------------


def test_text_block_shape():
    b = rb.text_block("b1", "Hello there.")
    assert b == {"block_id": "b1", "type": "text", "editable": True, "text": "Hello there."}


def test_fact_block_shape():
    b = rb.fact_block("f1", "Works as an engineer.", tag="work", confidence="high")
    assert b == {
        "block_id": "f1", "type": "fact", "editable": True,
        "text": "Works as an engineer.", "tag": "work", "confidence": "high",
    }


def test_attribute_block_shape():
    b = rb.attribute_block("attr:eye_color", "Eye color", "brown", source="stated")
    assert b == {
        "block_id": "attr:eye_color", "type": "attribute", "editable": True,
        "label": "Eye color", "value": "brown", "source": "stated", "confidence": "",
    }


def test_photo_block_defaults_non_editable():
    b = rb.photo_block("photo:x", "https://x/y.jpg", verified=True)
    assert b["editable"] is False
    assert b["url"] == "https://x/y.jpg"
    assert b["verified"] is True


def test_photo_grid_block():
    photos = [{"url": "a"}, {"url": "b"}]
    b = rb.photo_grid_block("grid1", photos)
    assert b["type"] == "photo_grid" and b["photos"] == photos


def test_link_block():
    b = rb.link_block("social:https://x", "https://x", label="@me", tag="instagram")
    assert b["type"] == "link" and b["label"] == "@me" and b["tag"] == "instagram"


def test_stat_block():
    b = rb.stat_block("face", "Above average", 7.5, basis="Above average")
    assert b["type"] == "stat" and b["value"] == 7.5


def test_section_head_block_is_never_editable():
    b = rb.section_head_block("attr:status", "Add a photo.")
    assert b["editable"] is False and b["type"] == "section_head"


# --- envelope --------------------------------------------------------------


def test_make_report_and_section():
    report = rb.make_report(
        "Title",
        [rb.make_section("Sec A", [rb.text_block("b1", "x")])],
    )
    assert report == {
        "title": "Title",
        "sections": [{"heading": "Sec A", "blocks": [rb.text_block("b1", "x")]}],
    }


def test_all_block_ids():
    report = rb.make_report(
        "T",
        [
            rb.make_section("A", [rb.text_block("b1", "x"), rb.text_block("b2", "y")]),
            rb.make_section("B", [rb.text_block("b3", "z")]),
        ],
    )
    assert rb.all_block_ids(report) == ["b1", "b2", "b3"]


def test_find_block():
    report = rb.make_report("T", [rb.make_section("A", [rb.text_block("b1", "x")])])
    assert rb.find_block(report, "b1")["text"] == "x"
    assert rb.find_block(report, "nope") is None


def test_section_for_block():
    report = rb.make_report(
        "T",
        [
            rb.make_section("A", [rb.text_block("b1", "x")]),
            rb.make_section("B", [rb.text_block("b2", "y")]),
        ],
    )
    assert rb.section_for_block(report, "b2")["heading"] == "B"
    assert rb.section_for_block(report, "nope") is None


def test_block_ids_in_sections():
    report = rb.make_report(
        "T",
        [
            rb.make_section("A", [rb.text_block("b1", "x"), rb.text_block("b2", "y")]),
            rb.make_section("B", [rb.text_block("b3", "z")]),
        ],
    )
    assert rb.block_ids_in_sections(report, {"A"}) == ["b1", "b2"]
    assert rb.block_ids_in_sections(report, {"A", "B"}) == ["b1", "b2", "b3"]
    assert rb.block_ids_in_sections(report, {"nope"}) == []


# --- sentence splitting ----------------------------------------------------


def test_split_sentences_basic():
    out = rb.split_sentences("Works as an engineer. Lives in Austin.")
    assert out == ["Works as an engineer.", "Lives in Austin."]


def test_split_sentences_every_piece_is_a_substring_of_input():
    text = (
        "Ran a startup for 5 years! Now consults part-time. "
        "Studied CS at MIT.\n\nSecond paragraph here."
    )
    for piece in rb.split_sentences(text):
        assert piece in text


def test_split_sentences_bullets_kept_as_separate_lines():
    text = "- First item here.\n- Second item, different sentence."
    out = rb.split_sentences(text)
    assert len(out) == 2
    assert out[0].startswith("- First")
    assert out[1].startswith("- Second")


def test_split_sentences_blank_input():
    assert rb.split_sentences("") == []
    assert rb.split_sentences("   ") == []


def test_split_sentences_single_sentence_no_terminal_punct():
    assert rb.split_sentences("just a fragment") == ["just a fragment"]


# --- teaser ------------------------------------------------------------


def test_teaser_uses_title_and_first_gist():
    report = rb.make_report(
        "Web search: Jane Doe",
        [rb.make_section("Summary", [rb.text_block("s1", "Works as a designer.")])],
    )
    assert rb.teaser_from_blocks(report) == "Web search: Jane Doe — Works as a designer."


def test_teaser_falls_back_to_heading_when_no_text_or_fact_blocks():
    report = rb.make_report(
        "Appearance",
        [rb.make_section("Attributes", [rb.attribute_block("attr:x", "X", "y")])],
    )
    assert rb.teaser_from_blocks(report) == "Appearance — Attributes"


def test_teaser_falls_back_to_title_with_no_sections():
    assert rb.teaser_from_blocks(rb.make_report("Empty", [])) == "Empty"


def test_teaser_is_capped():
    long_text = "x" * 400
    report = rb.make_report("T", [rb.make_section("S", [rb.text_block("b1", long_text)])])
    out = rb.teaser_from_blocks(report)
    assert len(out) <= rb._MAX_TEASER
    assert out.endswith("…")


# --- scored_result_blocks (§ face/body/deep-dive teaser convergence) ------


_SCORED = {
    "usable": True,
    "overall_score": 7.0,
    "verdict": "Above average",
    "verdict_note": "Clear skin.",
    "strengths": ["Strong jawline"],
    "improvements": ["Trim the beard"],
    "recommendations": [{"category": "skincare", "text": "Use SPF daily"}],
    "quick_facts": {"face_shape": "oval", "age_estimate": ""},
}


def test_scored_result_blocks_not_usable_returns_one_section_head():
    blocks = rb.scored_result_blocks(
        {"usable": False}, id_prefix="face", not_usable_text="bad photo"
    )
    assert blocks == [rb.section_head_block("face:status", "bad photo")]


def test_scored_result_blocks_missing_usable_key_defaults_to_usable():
    # face_report.run()/body_report.run() always set "usable", but a caller
    # handing in a dict that omits it entirely should default open, same as
    # `.get("usable", True)` everywhere else in this codebase.
    blocks = rb.scored_result_blocks({}, id_prefix="face", not_usable_text="bad photo")
    assert blocks == []


def test_scored_result_blocks_carries_every_field(monkeypatch):
    blocks = rb.scored_result_blocks(_SCORED, id_prefix="face", not_usable_text="x")
    by_id = {b["block_id"]: b for b in blocks}
    assert by_id["face"]["value"] == 7.0
    assert by_id["face"]["basis"] == "Above average"
    assert by_id["face:note:sent:0"]["text"] == "Clear skin."
    assert by_id["face:strength:0"]["text"] == "Strong jawline"
    assert by_id["face:improvement:0"]["text"] == "Trim the beard"
    assert by_id["face:reco:0"]["text"] == "Use SPF daily"
    assert by_id["face:quick:face_shape"]["value"] == "oval"
    assert "face:quick:age_estimate" not in by_id


def test_scored_result_blocks_id_prefix_scopes_block_ids():
    blocks = rb.scored_result_blocks(_SCORED, id_prefix="body", not_usable_text="x")
    ids = {b["block_id"] for b in blocks}
    assert "body" in ids and "body:strength:0" in ids
    assert not any(i.startswith("face") for i in ids)


def test_scored_result_blocks_splits_a_corrected_multi_sentence_note():
    # `verdict_note` starts as one sentence (§ face_report/body_report's own
    # prompt schema: "one sentence"), but `appearance.correct_finding` folds
    # every correction onto it in place (`axis["verdict_note"] = f"{prev}
    # {note}"`) — so a note that has been corrected even once is genuinely
    # multi-sentence prose. Regression: this used to come back as ONE
    # un-split `text` block, the one narrative-prose path in Appearance that
    # bypassed the Flutter side's per-sentence tap target the same way the
    # founder's screenshot reported ("this font is not clickable to edit").
    result = {
        **_SCORED,
        "verdict_note": "Clear skin overall. A little redness near the jaw.",
    }
    blocks = rb.scored_result_blocks(result, id_prefix="face", not_usable_text="x")
    by_id = {b["block_id"]: b for b in blocks}
    assert by_id["face:note:sent:0"]["text"] == "Clear skin overall."
    assert by_id["face:note:sent:1"]["text"] == "A little redness near the jaw."
    assert by_id["face:note:sent:0"]["type"] == rb.TEXT
    assert "face:note" not in by_id  # the old, un-split id is gone entirely


def test_scored_result_blocks_score_is_not_editable_but_rest_of_axis_is():
    # § founder: "In the face/physique report user should NOT be able to
    # change the score. That should only come from Ayma." The score is
    # Ayma's own algorithmic verdict (like Match's score, already
    # `editable=False`), never user-authored content to correct/delete via
    # tap-to-chat — but nothing else about the axis changes: note,
    # strengths, improvements, recommendations, and quick facts stay
    # `editable=True` exactly as before.
    blocks = rb.scored_result_blocks(_SCORED, id_prefix="face", not_usable_text="x")
    by_id = {b["block_id"]: b for b in blocks}
    assert by_id["face"]["type"] == rb.STAT
    assert by_id["face"]["editable"] is False
    assert by_id["face:note:sent:0"]["editable"] is True
    assert by_id["face:strength:0"]["editable"] is True
    assert by_id["face:improvement:0"]["editable"] is True
    assert by_id["face:reco:0"]["editable"] is True
    assert by_id["face:quick:face_shape"]["editable"] is True


# --- digest_is_empty (§ face/body/deep-dive teaser convergence) -----------


def test_digest_is_empty_true_for_not_found_confidence_without_content():
    assert rb.digest_is_empty({"confidence": "not_found", "summary": "", "facts": [], "links": []}) is True


def test_digest_is_empty_false_for_not_found_confidence_with_content():
    assert rb.digest_is_empty({"confidence": "not_found", "summary": "something", "facts": [{"x": 1}]}) is False
    assert rb.digest_is_empty({"confidence": "not_found", "summary": "", "facts": [], "links": [{"url": "https://a.com"}]}) is False
    assert rb.digest_is_empty({"confidence": "not_found", "summary": "", "caveats": "Ambiguous."}) is False


def test_digest_is_empty_true_when_no_facts_and_no_summary():
    assert rb.digest_is_empty({"confidence": "high", "summary": "", "facts": []}) is True


def test_digest_is_empty_false_with_real_content():
    assert rb.digest_is_empty({"confidence": "high", "summary": "Works as a designer.", "facts": []}) is False
    assert rb.digest_is_empty({"confidence": "medium", "summary": "", "facts": [{"claim": "x"}]}) is False


def test_digest_is_empty_true_for_non_dict():
    assert rb.digest_is_empty(None) is True
