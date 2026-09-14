from wiki_schema import (
    default_visibility_for,
    is_valid_page_id,
    load_wiki_schema,
    page_types,
    visibility_values,
)


def test_schema_loads_with_the_expected_shape():
    schema = load_wiki_schema()
    assert schema["version"] == 1
    for key in (
        "page_id",
        "page_types",
        "visibility",
        "fields",
        "update_rules",
        "pending_questions",
    ):
        assert key in schema


def test_page_types_and_visibility_values():
    types = page_types()
    assert "career" in types and "sensitive" in types
    assert visibility_values() == ("public", "private", "ai_only")


def test_default_visibility_lookup():
    assert default_visibility_for("sensitive") == "private"
    assert "steering" in page_types()
    assert default_visibility_for("interests") == "public"
    assert default_visibility_for("career") == "public"
    # public-by-default now — Ayma marks only genuinely sensitive things private
    assert default_visibility_for("lifestyle") == "public"
    assert default_visibility_for("family") == "public"
    # unknown type falls back to the schema default (also public)
    assert default_visibility_for("nope") == "public"


def test_interactions_and_steering_page_types_are_ai_only():
    # Unlike `sensitive` (the user's own stated content, just not public),
    # `interactions` is Ayma's own behavioural inference about the user and
    # `steering` is a standing instruction about the user, not a fact of
    # theirs — neither is shown to the user by default.
    for page_type in ("interactions", "steering"):
        assert page_type in page_types()
        assert default_visibility_for(page_type) == "ai_only"


def test_skill_page_types_default_to_private():
    # The user's own shared content / self-requested skill output — visible
    # to them, just not part of the shareable public profile. `ai_only` is
    # reserved for content Ayma infers about the user on her own.
    for page_type in (
        "web_findings",
        "face_analysis",
        "body_analysis",
        "sensitive",
    ):
        assert default_visibility_for(page_type) == "private"


def test_schema_carries_an_account_holder_scope_note():
    schema = load_wiki_schema()
    assert "ACCOUNT HOLDER" in schema["scope"]
    assert "interactions" in schema["scope"]


def test_page_id_validation():
    assert is_valid_page_id("career-ambitions")
    assert is_valid_page_id("family")
    assert not is_valid_page_id("Career Ambitions")
    assert not is_valid_page_id("trailing-")
    assert not is_valid_page_id("x" * 200)
    assert not is_valid_page_id("")
