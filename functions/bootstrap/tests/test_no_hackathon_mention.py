"""locks in the founder rule (Nov 6, 2026) that Ayma never raises the topic of hackathons unprompted — for any user, chat or voice; it cannot silently drop from a prompt."""

from prompt import compose_system_prompt


def _has_rule(text):
    low = " ".join(text.lower().split())
    assert "hackathons (hard rule)" in low
    assert "never raise the topic of hackathons" in low
    assert "brings hackathons up first" in low


def test_chat_system_prompt_has_no_hackathon_mention_rule():
    _has_rule(compose_system_prompt(variant="text"))


def test_voice_system_prompt_has_no_hackathon_mention_rule():
    _has_rule(compose_system_prompt(variant="voice"))


def test_fresh_user_system_prompt_has_no_hackathon_mention_rule():
    _has_rule(compose_system_prompt())
