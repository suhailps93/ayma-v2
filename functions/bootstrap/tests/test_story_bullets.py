"""Bullet read-time split / write-time compose over the span model."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_bullets as sb  # noqa: E402


def _texts(bullets):
    return [b["text"] for b in bullets]


def _vis(bullets):
    return [b["visibility"] for b in bullets]


def test_split_sentences_one_thought_each():
    assert sb.split_sentences("I love hiking. I run a startup! Do you?") == [
        "I love hiking.",
        "I run a startup!",
        "Do you?",
    ]


def test_split_sentences_keeps_abbreviations_and_decimals_whole():
    assert sb.split_sentences("I work at Acme Inc. in SF.") == [
        "I work at Acme Inc. in SF."
    ]
    assert sb.split_sentences("I'm 5.11 tall and lift.") == [
        "I'm 5.11 tall and lift."
    ]


def test_split_sentences_treats_newlines_and_bullet_markers_as_boundaries():
    assert sb.split_sentences("- first thought\n- second thought") == [
        "first thought",
        "second thought",
    ]


def test_parse_public_page_spans_to_bullet_visibility():
    body = "I grew up in Lahore. {{private}}I had a tough divorce.{{/private}} {{ai_only}}Avoid pushing on this.{{/ai_only}}"
    bullets = sb.parse_bullets(body, "public", page_id="identity")
    assert _texts(bullets) == [
        "I grew up in Lahore.",
        "I had a tough divorce.",
        "Avoid pushing on this.",
    ]
    assert _vis(bullets) == ["public", "private", "ai_only"]
    # ids are stable and distinct
    ids = [b["id"] for b in bullets]
    assert len(set(ids)) == 3
    assert sb.parse_bullets(body, "public", page_id="identity")[0]["id"] == ids[0]


def test_private_page_clamps_unwrapped_bullets_to_private():
    # a private page: an un-wrapped sentence is private, not public
    bullets = sb.parse_bullets("My net worth is complicated.", "private", page_id="finances")
    assert _vis(bullets) == ["private"]


def test_ai_only_page_forces_ai_only():
    bullets = sb.parse_bullets("Talk gently about family.", "ai_only")
    assert _vis(bullets) == ["ai_only"]


def test_compose_sets_page_visibility_to_most_public_bullet():
    out = sb.compose_body([
        {"text": "I am a pilot.", "visibility": "public"},
        {"text": "I earn a lot.", "visibility": "private"},
        {"text": "Do not mention the ex.", "visibility": "ai_only"},
    ])
    assert out["visibility"] == "public"
    assert "I am a pilot." in out["body"]
    assert "{{private}}I earn a lot.{{/private}}" in out["body"]
    assert "{{ai_only}}Do not mention the ex.{{/ai_only}}" in out["body"]


def test_compose_all_private_becomes_private_page():
    out = sb.compose_body([
        {"text": "Secret one.", "visibility": "private"},
        {"text": "Secret two.", "visibility": "private"},
    ])
    assert out["visibility"] == "private"
    # consecutive same-kind bullets share one span
    assert out["body"] == "{{private}}Secret one. Secret two.{{/private}}"


def test_compose_empty_is_private_empty_page():
    out = sb.compose_body([])
    assert out == {"body": "", "visibility": "private"}
    # whitespace-only bullets are dropped
    assert sb.compose_body([{"text": "   ", "visibility": "public"}]) == {
        "body": "", "visibility": "private",
    }


def test_round_trip_public_with_private_and_ai_only():
    body = "First public thought. {{private}}A private one.{{/private}} {{ai_only}}An Ayma note.{{/ai_only}}"
    bullets = sb.parse_bullets(body, "public")
    out = sb.compose_body(bullets)
    assert out["visibility"] == "public"
    # re-parsing the composed body yields the same bullets (text + visibility)
    again = sb.parse_bullets(out["body"], out["visibility"])
    assert _texts(again) == _texts(bullets)
    assert _vis(again) == _vis(bullets)
