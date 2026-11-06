"""locks in the founder rule (Nov 6, 2026) that Ayma never raises hackathons or shows off her own skills unprompted — for any user, chat or voice; it cannot silently drop from a prompt."""

from prompt import compose_system_prompt


def _has_rule(text):
    low = " ".join(text.lower().split())
    assert "no self-promotion (hard rule)" in low
    assert "never bring up hackathons" in low
    assert "showing off" in low
    assert "use your skills silently" in low
    assert "brings either topic up first" in low


def test_chat_system_prompt_has_no_self_promotion_rule():
    _has_rule(compose_system_prompt(variant="text"))


def test_voice_system_prompt_has_no_self_promotion_rule():
    _has_rule(compose_system_prompt(variant="voice"))


def test_fresh_user_system_prompt_has_no_self_promotion_rule():
    _has_rule(compose_system_prompt())
