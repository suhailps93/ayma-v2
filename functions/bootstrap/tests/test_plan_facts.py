"""Founder bug 2026-10-25: asked "What will Max give me?", Ayma invented
generic dating-app perks ("unlimited likes", "see who already liked you") that
Ayma does not have. The fix grounds her in the real plan facts, rendered from
``config``/``token_ledger`` and injected into every system prompt."""

import billing
import plan_facts
from config import CONFIG, PLAN_TIERS
from prompt import compose_system_prompt
from token_ledger import FEATURE_LABELS


def test_plan_facts_states_real_prices_and_credits_from_config():
    """Each paid tier's real price and its monthly credit pool (pool_usd via
    the one credits scale) come straight from the source of truth — so Max is
    $100/mo for 8,000 credits, Pro $20 for 1,400, Plus $10 for 700."""
    facts = plan_facts.plan_facts()
    for tier in PLAN_TIERS.values():
        credits = billing.credits_for(tier.pool_usd, CONFIG)
        assert f"${tier.price_usd}/mo" in facts
        assert f"{credits:,} credits" in facts
    # The specific pool the Plan page shows for Pro, pinned.
    assert billing.credits_for(PLAN_TIERS["pro"].pool_usd, CONFIG) == 1400


def test_plan_facts_states_the_real_free_grant():
    start = billing.credits_for(CONFIG.free_start_grant_usd, CONFIG)
    daily = billing.credits_for(CONFIG.free_daily_allowance_usd, CONFIG)
    facts = plan_facts.plan_facts()
    assert f"{start:,} credits to start" in facts
    assert f"{daily:,} credits a day" in facts


def test_plan_facts_lists_what_credits_buy_from_the_ledger_labels():
    """What credits are spent on is the live Plan-page feature set, not a
    hand-written list that could drift from the ledger."""
    facts = plan_facts.plan_facts()
    for label in FEATURE_LABELS.values():
        assert label in facts


def test_plan_facts_invents_no_dating_app_perks():
    """The exact hallucinations from the founder bug — and anything implying a
    cap on likes — must never appear: Ayma has no such features."""
    lowered = plan_facts.plan_facts().lower()
    for phantom in (
        "unlimited likes",
        "see who already liked",
        "see who liked",
        "swipe",
        "boost",
        "super like",
    ):
        assert phantom not in lowered


def test_plan_facts_are_in_both_voice_and_text_system_prompts():
    """Grounding is useless if a surface misses it; both the lean voice seed and
    the full text prompt must carry the block, right after the persona."""
    for variant in ("voice", "text"):
        composed = compose_system_prompt(variant=variant)
        assert plan_facts.plan_facts() in composed


def test_persona_forbids_inventing_plan_features():
    """The persona itself must carry the no-hallucination rule for
    plans/pricing/features (complements the match-grounding rule)."""
    from prompt import load_persona

    persona = load_persona().lower()
    assert "talking about plans, credits and pricing" in persona
    assert "unlimited likes" in persona
    assert "see who already liked you" in persona
    assert "never invent" in persona
    assert "plan page" in persona
