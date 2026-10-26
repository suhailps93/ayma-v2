"""The real Ayma plan facts, built from the single source of truth.

Ayma must state actual plan prices, monthly credit pools, the free-plan grant
and what credits are spent on — never invented dating-app perks. Rather than
hardcode any of that into a prompt (which would drift the moment prices or
credits change), this module renders ``prompts/plan_facts.md`` from the live
values: paid tiers and prices from ``config.PLAN_TIERS``, the credit scale and
free grants from ``config.CONFIG``, and the spend categories from
``token_ledger.FEATURE_LABELS`` (the same labels the Plan page shows). The
framing text lives in the markdown template (AGENTS.md: no prompt strings in
code files); this module only fills the ``{{PLANS}}``, ``{{FREE}}`` and
``{{FEATURES}}`` placeholders.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import billing
from config import CONFIG, PLAN_TIERS
from token_ledger import FEATURE_LABELS

_TEMPLATE_PATH = Path(__file__).resolve().parent / "prompts" / "plan_facts.md"


def _plans_block() -> str:
    """One indented sub-bullet per paid tier, cheapest first:
    ``  - Plus — $10/mo → 700 credits``."""
    rows = []
    for tier in sorted(PLAN_TIERS.values(), key=lambda t: t.price_usd):
        credits = billing.credits_for(tier.pool_usd, CONFIG)
        rows.append(
            f"  - {tier.plan_id.capitalize()} — ${tier.price_usd}/mo "
            f"→ {credits:,} credits"
        )
    return "\n".join(rows)


def _free_block() -> str:
    """The free plan's one-time start grant and daily allowance, in credits."""
    start = billing.credits_for(CONFIG.free_start_grant_usd, CONFIG)
    daily = billing.credits_for(CONFIG.free_daily_allowance_usd, CONFIG)
    return (
        f"{start:,} credits to start (one time), then {daily:,} credits a day "
        f"(resets daily, does not roll over)"
    )


def _features_block() -> str:
    """What credits are spent on — the live set of Plan-page feature labels."""
    return ", ".join(FEATURE_LABELS.values())


@lru_cache(maxsize=1)
def plan_facts() -> str:
    """The rendered plan-facts block for Ayma's system prompt (voice + text).

    Values are read once at process start (prices and credits only change on a
    deploy), so this is cached process-wide."""
    template = _TEMPLATE_PATH.read_text(encoding="utf-8").strip()
    return (
        template.replace("{{PLANS}}", _plans_block())
        .replace("{{FREE}}", _free_block())
        .replace("{{FEATURES}}", _features_block())
    )
