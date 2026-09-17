"""Per-user Gemini token accounting + a credit balance.

Every Gemini call the user's activity drives — text chat with Ayma, icebreaker
generation, the matching skill, wiki ingest, natural-language Explore parsing,
Ayma's background check-in, and the Gemini Live voice session (recorded by the
agent worker) — adds its token count to ``users/{uid}.token_usage``:

    token_usage: {
      total: <int>,
      input: <int>,   # prompt / input tokens, summed lifetime (cost audits)
      output: <int>,  # candidates / output tokens, summed lifetime
      cost_usd: <float>,  # real $ cost, summed lifetime since this field
                          # started being written (see below) — starts at
                          # zero, only ever added to, never backfilled
      features: { chat: <int>, voice: <int>, matching: <int>, wiki: <int>,
                  explore: <int>, reengage: <int>, ... },
      updated_at: <server ts>
    }

``input``/``output`` are additive accounting fields only — Gemini prices input
and output tokens very differently (see PLAN.md F1/F2), so a real-dollar cost
audit needs the split. ``total`` remains the one number credit charging and
the token cap read (see :func:`_credit_view`); the split is never used there
and never changes what a call costs the user. Note ``total`` can exceed
``input + output`` when thinking or tool-use tokens are billed (Gemini's own
``total_token_count`` includes those; the input/output split here does not).

``cost_usd`` is the running real-dollar cost of the account, computed from
``input``/``output`` at each :func:`add`/:func:`record` call using the
per-model pricing in ``_MODEL_PRICING`` below (founder request, 2026-09-16:
"exact value based on the usage period ... start from zero and then just add
as they go"). It is a Firestore ``Increment`` applied alongside ``input``/
``output`` in the very same write, so it only ever grows from real recorded
calls going forward — usage docs written before the input/output split
existed (pre commit 278c562) have no ``input``/``output`` and contribute
``$0`` here rather than an estimate; this module never re-derives ``cost_usd``
from a full history scan.

Spend is shown to the user as **credits**:
``used = ceil(total / CONFIG.tokens_per_credit)``,
``remaining = grant + added - used``, where ``grant`` is
``users/{uid}.credit_grant`` if set (paid tiers) else ``CONFIG.credits_free_grant``
and ``added`` is ``users/{uid}.credits_added`` (the running sum of top-ups —
free reloads for now, see :func:`topup`).

:func:`check` raises :class:`TokenCapExceeded` once ``remaining`` hits 0; a
top-up clears it. Recording is best-effort and never raises.
"""

from __future__ import annotations

import logging

from config import CONFIG
from db import get_db

logger = logging.getLogger("ayma.tokens")

_FIELD = "token_usage"

# Feature labels — keep stable, they surface in the client breakdown.
FEATURE_CHAT = "chat"
FEATURE_VOICE = "voice"
FEATURE_ICEBREAKERS = "icebreakers"
FEATURE_MATCHING = "matching"
FEATURE_WIKI = "wiki"
FEATURE_EXPLORE = "explore"  # natural-language Explore search parsing
FEATURE_REENGAGE = "reengage"  # Ayma's background check-in message
FEATURE_DEEPDIVE = "deepdive"  # web deep-dive research on a named person
FEATURE_FACE_REPORT = "face_report"  # honest facial-beauty analysis of a photo
FEATURE_BODY_REPORT = "body_report"  # honest physique analysis of a photo
FEATURE_PHYSICAL_ATTRS = "physical_attrs"  # structured physical-profile extraction
FEATURE_COMPLETENESS = "completeness"  # profile-completeness narrative coverage pass
FEATURE_PERSONA_EVOLUTION = "persona_evolution"  # daily crowd feedback aggregation + eval gate (§15 Part B)
FEATURE_CAREER_TIMELINE = "career_timeline"  # structured career/education timeline extraction
FEATURE_PHOTO_EDIT = "photo_edit"  # edit_photo tool — Gemini image-edit model call

_CREDITS_ADDED_FIELD = "credits_added"  # top-of-doc int, bumped by top-ups


class TokenCapExceeded(RuntimeError):
    """Raised before a metered Gemini call when the user is out of credits."""


# Real Gemini API pricing, $ per 1,000,000 tokens — fetched from the official
# Gemini Developer API pricing page (https://ai.google.dev/gemini-api/docs/pricing)
# on 2026-09-16, cross-checked against web search results the same day. Only
# the three model ids this app actually calls (config.py's "LOCKED MODELS")
# are listed; an unlisted or unpriceable model contributes $0 rather than a
# guess — see :func:`cost_usd_for`.
_MODEL_PRICING: dict[str, dict[str, float | None]] = {
    # Text / wiki / matching / icebreakers / explore / reengage / deep-dive /
    # face+body report / physical-attrs / completeness / persona-evolution /
    # career-timeline — everything that calls gemini.generate_reply/_json/
    # research, all of which use CONFIG.gemini_model. Standard-tier,
    # introductory rate in effect through 2026-12-31 (rises to $1.50 / $7.50
    # on 2027-01-01 — revisit this table then).
    "gemini-3.7-flash": {"input": 0.75, "output": 3.75},
    # Gemini Live native-audio voice session (agent.py). The pricing page
    # splits text vs. audio/video rates; livekit's RealtimeModelMetrics
    # input_tokens/output_tokens are "each already inclusive of audio" (see
    # the commit that added the split) and every Ayma voice turn is audio
    # in/audio out, so the audio rate applies on both sides.
    "gemini-live-2.5-flash-native-audio": {"input": 3.00, "output": 12.00},
    # Photo-edit ("Chat about it" -> edit_photo tool). Input (text+image) is
    # token-priced at $0.30/1M tokens; output is billed **per generated
    # image** ($0.039/image) on the official page, not per output token. The
    # ledger only ever records token counts (not images produced), so the
    # output side can't be converted to $ without guessing a tokens-per-image
    # ratio — left unpriced (output: None -> $0 contribution) rather than
    # fabricated. Input cost is still real and included.
    "gemini-2.5-flash-image": {"input": 0.30, "output": None},
}


def _model_for_feature(feature: str) -> str:
    """Which LOCKED model (config.py) a usage-ledger ``feature`` bucket was
    actually billed against. Every feature except voice and photo_edit routes
    through gemini.generate_reply/_json/research, which all call
    ``CONFIG.gemini_model``."""
    if feature == FEATURE_VOICE:
        return CONFIG.gemini_live_model
    if feature == FEATURE_PHOTO_EDIT:
        return CONFIG.gemini_image_edit_model
    return CONFIG.gemini_model


def cost_usd_for(feature: str, input_tokens: int, output_tokens: int) -> float:
    """Real-dollar cost of one recorded call, from :data:`_MODEL_PRICING`.
    ``0.0`` whenever the model isn't in the pricing table, its input/output
    rate isn't known (see the photo-edit image-output note above), or the
    token count is 0/absent — never an estimate. Used by both :func:`add`
    (text/vision path) and the voice worker's ``relay_token_usage``
    (``agent.py``), so pricing lives in exactly one place."""
    price = _MODEL_PRICING.get(_model_for_feature(feature))
    if not price:
        return 0.0
    cost = 0.0
    in_rate = price.get("input")
    out_rate = price.get("output")
    if input_tokens > 0 and in_rate is not None:
        cost += (input_tokens / 1_000_000) * in_rate
    if output_tokens > 0 and out_rate is not None:
        cost += (output_tokens / 1_000_000) * out_rate
    return cost


def _usage_from_response(response) -> tuple[int, int, int]:
    """``(input_tokens, output_tokens, total_tokens)`` for one ``google-genai``
    response (all 0 if unavailable). ``input``/``output`` come straight from
    ``usage_metadata.prompt_token_count`` / ``candidates_token_count`` — the
    exact attribute names on this SDK's
    ``GenerateContentResponseUsageMetadata``. ``total`` prefers the SDK's own
    ``total_token_count`` (unchanged from before — this is still what credit
    charging uses); it can be larger than ``input + output`` since it also
    folds in thinking/tool-use tokens that this split doesn't break out."""
    meta = getattr(response, "usage_metadata", None)
    if meta is None:
        return 0, 0, 0
    input_tokens = int(getattr(meta, "prompt_token_count", 0) or 0)
    output_tokens = int(getattr(meta, "candidates_token_count", 0) or 0)
    total = getattr(meta, "total_token_count", None)
    total_tokens = int(total) if total is not None else input_tokens + output_tokens
    return input_tokens, output_tokens, total_tokens


def add(
    uid: str,
    feature: str,
    tokens: int,
    *,
    input_tokens: int = 0,
    output_tokens: int = 0,
) -> None:
    """Add ``tokens`` to the user's total and the per-feature bucket. ``tokens``
    still drives the credit cap exactly as before; ``input_tokens``/
    ``output_tokens`` are additive accounting-only fields for cost audits
    (PLAN.md F1/F2) and never affect what a call costs the user."""
    if not uid or tokens <= 0:
        return
    try:
        from firebase_admin import firestore

        payload = {
            "total": firestore.Increment(tokens),
            "features": {feature: firestore.Increment(tokens)},
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if input_tokens > 0:
            payload["input"] = firestore.Increment(input_tokens)
        if output_tokens > 0:
            payload["output"] = firestore.Increment(output_tokens)
        cost = cost_usd_for(feature, input_tokens, output_tokens)
        if cost > 0:
            payload["cost_usd"] = firestore.Increment(cost)
        get_db().collection("users").document(uid).set(
            {_FIELD: payload}, merge=True
        )
    except Exception:  # noqa: BLE001 - metering must never break a request
        logger.exception("token add failed for %s/%s", uid, feature)


def record(uid: str | None, feature: str, response) -> None:
    """Extract the token count from a ``google-genai`` response and add it,
    along with the input/output split for cost audits."""
    if not uid:
        return
    input_tokens, output_tokens, total_tokens = _usage_from_response(response)
    add(
        uid, feature, total_tokens,
        input_tokens=input_tokens, output_tokens=output_tokens,
    )


def _read(uid: str) -> dict:
    snap = get_db().collection("users").document(uid).get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    u = data.get(_FIELD) or {}
    grant = data.get("credit_grant")
    return {
        "total": int(u.get("total", 0) or 0),
        # Input/output split — accounting only, see module docstring; never
        # read by _credit_view.
        "input": int(u.get("input", 0) or 0),
        "output": int(u.get("output", 0) or 0),
        "cost_usd": float(u.get("cost_usd", 0) or 0),
        "features": {k: int(v) for k, v in (u.get("features") or {}).items()},
        # Per-user credit grant override (paid tiers); None -> the free grant.
        "grant": int(grant) if grant is not None else None,
        # Credits added by top-ups (free reloads for now).
        "added": int(data.get(_CREDITS_ADDED_FIELD, 0) or 0),
    }


def _ceil_div(n: int, d: int) -> int:
    return -(-n // d) if d > 0 else 0


def _credit_view(u: dict) -> dict:
    """`{grant, added, used, remaining}` from a :func:`_read` result — the one
    place the credit sum is computed. ``remaining = grant + added - used``."""
    ratio = max(1, CONFIG.tokens_per_credit)
    grant = u["grant"] if u["grant"] is not None else CONFIG.credits_free_grant
    added = int(u.get("added", 0) or 0)
    used = _ceil_div(u["total"], ratio)
    return {
        "grant": grant,
        "added": added,
        "used": used,
        "remaining": max(0, grant + added - used),
    }


def topup(uid: str, amount: int) -> dict:
    """Reload the balance so the user has **at least ``amount`` usable credits**
    afterwards. A heavy user can be far past their grant (``used`` >> ``grant``
    + ``added``); a plain ``+amount`` would leave ``remaining`` stuck at 0, so a
    reload first forgives that overspend, then adds ``amount``:

        new_added = max(added + amount, used - grant + amount)

    -> ``remaining`` becomes exactly ``amount`` for a broke user, and ``+amount``
    for anyone still in the black. Best-effort; returns the fresh credit view.
    """
    if not uid or amount <= 0:
        return credits(uid) if uid else {}
    try:
        from firebase_admin import firestore

        u = _read(uid)
        view = _credit_view(u)
        new_added = max(view["added"] + amount, view["used"] - view["grant"] + amount)
        get_db().collection("users").document(uid).set(
            {
                _CREDITS_ADDED_FIELD: int(new_added),
                "credits_updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001 - a failed top-up must not 500 the request
        logger.exception("credit top-up failed for %s (+%s)", uid, amount)
    return credits(uid)


def credit_costs() -> dict:
    """Shown per-action credit estimates for token-intensive buttons. Only
    actions that spend Gemini tokens are listed — Pass-1 pool matching is
    heuristic-only and free, so it isn't here. Tunable via ``CREDIT_COST_*``
    env vars; the true spend still lands in the ledger."""
    return {
        "match_score": CONFIG.credit_cost_match_score,
        "photo_edit": CONFIG.credit_cost_photo_edit,
    }


def credits(uid: str) -> dict:
    """The user-facing credit view: ``{grant, added, used, remaining}``. Free
    plan unless the user doc carries a ``credit_grant`` override; ``added`` is
    the sum of top-ups."""
    return _credit_view(_read(uid))


def check(uid: str | None) -> None:
    """Raise :class:`TokenCapExceeded` when the user has no credits left
    (``grant + added - used <= 0``). Topping up clears it."""
    if not uid:
        return
    try:
        remaining = _credit_view(_read(uid))["remaining"]
    except Exception:  # noqa: BLE001
        logger.exception("credit check read failed for %s", uid)
        return
    if remaining <= 0:
        raise TokenCapExceeded(f"out of credits (uid={uid})")


def usage(uid: str) -> dict:
    """The client-facing view: raw lifetime token accounting (total + a
    per-feature breakdown across chat / voice / matching / wiki / explore /
    reengage) plus the derived credit balance and per-action credit costs.
    ``input``/``output`` are the lifetime prompt/candidates split for cost
    audits (PLAN.md F1/F2) — accounting only, not used by ``credits``.
    ``cost_usd`` is the real infrastructure $ this drove, distinct from and
    never conflated with the credit balance — see the module docstring.
    """
    u = _read(uid)
    cred = _credit_view(u)
    return {
        "total": u["total"],
        "input": u["input"],
        "output": u["output"],
        "cost_usd": round(u["cost_usd"], 6),
        "cap": CONFIG.token_cap_per_user,
        "remaining": max(0, CONFIG.token_cap_per_user - u["total"]),
        "features": u["features"],
        "credits": cred,
        "tokens_per_credit": max(1, CONFIG.tokens_per_credit),
        "costs": credit_costs(),
    }
