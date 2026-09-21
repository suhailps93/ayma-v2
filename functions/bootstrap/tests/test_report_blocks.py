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
