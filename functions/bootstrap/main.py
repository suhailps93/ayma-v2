"""Ayma Main API — Cloud Run service (see ``docs/ARCHITECTURE.md`` §10.1).

Step 1 scaffolding: a single unauthenticated health-check route. The real
endpoint surface (§10.2) and the shared auth / cron middleware (§10.4, §10.5)
land in later steps per ``PLAN.md``.
"""

from __future__ import annotations

import asyncio
import functools
import sys
from pathlib import Path

# Local dev only: load config/secrets from the gitignored repo-root .env files,
# at the top of the entrypoint, before anything reads the environment
# (AGENTS.md §"Data & credentials"). Skipped under pytest so tests stay
# isolated from the developer's local environment. Deployed environments have
# no .env file — Cloud Run injects real env vars / mounted secrets.
if "pytest" not in sys.modules:  # pragma: no cover - deployment/dev only
    from dotenv import load_dotenv

    # Walk up from this file looking for the repo-root .env files. In the
    # deployed container there is no such file and this loop is a no-op.
    for _parent in Path(__file__).resolve().parents:
        if (_parent / ".env.local").exists() or (_parent / ".env").exists():
            load_dotenv(_parent / ".env.local")
            load_dotenv(_parent / ".env")
            break

import json  # noqa: E402
import logging  # noqa: E402
import secrets  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from datetime import datetime  # noqa: E402
from typing import Literal  # noqa: E402

from fastapi import (  # noqa: E402 - must follow the dotenv load
    BackgroundTasks,
    Body,
    Depends,
    FastAPI,
    Request,
)
from fastapi.responses import HTMLResponse, Response, StreamingResponse  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

from fastapi import HTTPException  # noqa: E402

from auth import (  # noqa: E402
    Caller,
    require_admin_password,
    require_caller,
    require_cron,
    require_revenuecat,
    require_uid,
    require_dev,
    require_uid_and_dev_flag,
)
from config import CONFIG  # noqa: E402
import agent_wake  # noqa: E402
import feature_flags  # noqa: E402
import gemini  # noqa: E402
import billing  # noqa: E402
import token_ledger  # noqa: E402
from livekit_token import (  # noqa: E402
    LiveKitConfigError,
    build_room_seed,
    mint_access_token,
    room_name_for,
    seed_room_context,
)
import account_ops  # noqa: E402
import age_gate  # noqa: E402
import account_purge  # noqa: E402
import auto_analysis  # noqa: E402
import deep_dive  # noqa: E402
import face_report  # noqa: E402
import body_report  # noqa: E402
import skill_memory  # noqa: E402
import explore as explore_mod  # noqa: E402
import profile_manual  # noqa: E402
import public_profile as public_profile_mod  # noqa: E402
import share  # noqa: E402
import share_page  # noqa: E402
import referral_page  # noqa: E402
import skills.app_control as app_control_mod  # noqa: E402
import matching  # noqa: E402
import matching_cron  # noqa: E402
import matching_skill  # noqa: E402
from matching_schema import (  # noqa: E402
    BLOCKS_COLLECTION,
    MATCH_STATUS_MUTUAL,
    MATCH_STATUS_SCORED,
    MATCH_STATUS_UNMATCHED,
    MATCHES_COLLECTION,
    block_id,
    clear_stale_candidates,
)
import ai_assessment  # noqa: E402
import dm_ingest  # noqa: E402
import dm_moderation  # noqa: E402
import dm_ops  # noqa: E402
import dm_schema  # noqa: E402
import icebreakers  # noqa: E402
import notifications_ops  # noqa: E402
import notifications_triggers  # noqa: E402
import schema  # noqa: E402
from pair_key import sorted_pair_key, uids_from_pair_key  # noqa: E402
import deep_dive_images  # noqa: E402
import media_embed  # noqa: E402
import photo_notes  # noqa: E402
import photo_attrs  # noqa: E402
import physical_attributes  # noqa: E402
import appearance  # noqa: E402
import backfill_ops  # noqa: E402
import completeness  # noqa: E402
import skill_runs  # noqa: E402
import chat_history  # noqa: E402
import feedback_ops  # noqa: E402
import persona_evolution  # noqa: E402
from db import get_db  # noqa: E402
from post_turn import persist_raw_turns  # noqa: E402
import prompt as prompt_module  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402
import session_mode  # noqa: E402
from skills import (  # noqa: E402
    make_session_tool_fns,
    session_tool_declarations,
)
from skills import questionnaire as questionnaire_skill  # noqa: E402
import turn_caps  # noqa: E402
import context_opt  # noqa: E402
from transcript import ROLE_AYMA, ROLE_USER, Turn, format_recent_turns  # noqa: E402
from wiki_ingest import ingest_or_defer as wiki_ingest  # noqa: E402
from wiki_lint import lint_all  # noqa: E402
from wiki_query import read_wiki_context  # noqa: E402
import story  # noqa: E402
import career_timeline  # noqa: E402
import referrals  # noqa: E402
import reverse_image_search  # noqa: E402
import report_hub  # noqa: E402

logger = logging.getLogger("ayma.api")
# Python drops INFO from every ``ayma.*`` logger unless a handler is attached
# (the root logger has none, so only WARNING+ reached Cloud Logging). The
# diagnostic lines the deep-dive discovery sources emit are INFO.
_ayma_logs = logging.getLogger("ayma")
if not _ayma_logs.handlers:
    _ayma_logs.addHandler(logging.StreamHandler())
    _ayma_logs.setLevel(logging.INFO)

# Cap on the recent-turns window a client may send (§1.5 — it is bounded
# client-side; the server enforces its own ceiling regardless).
_MAX_RECENT_TURNS = 200

# A client-owned id, stable for the lifetime of one chat screen (voice + text
# interleaved land in the same session doc). Optional on the wire; when absent
# the turn simply isn't persisted.
_SESSION_ID = Field(default="", max_length=128, pattern=r"^[A-Za-z0-9_-]*$")


class TurnModel(BaseModel):
    role: Literal["user", "ayma"]
    text: str = Field(min_length=1, max_length=4000)


def _to_turns(models: list[TurnModel]) -> list[Turn]:
    return [Turn(role=m.role, text=m.text) for m in models]


def _persist_session(uid: str, session_id: str, turns: list[Turn]) -> None:
    """Best-effort raw_turns upsert — never fails the request it rides on.

    Also stamps ``users/{uid}.last_active_at`` — the signal the re-engagement
    cron (§7.1) reads. Only genuine user sessions flow through here (chat /
    post-turn / bootstrap); receiving a DM does not count as activity.
    """
    try:
        persist_raw_turns(get_db(), uid, session_id, turns)
    except Exception:  # noqa: BLE001
        logger.exception("failed to persist raw_turns for %s/%s", uid, session_id)
    try:
        get_db().collection("users").document(uid).set(
            {"last_active_at": _server_ts()}, merge=True
        )
    except Exception:  # noqa: BLE001
        logger.exception("failed to stamp last_active_at for %s", uid)


def _bucket():
    from firebase_admin import storage

    return storage.bucket(CONFIG.storage_bucket)


def _ayma_voice_name(uid: str) -> str:
    """The user's ``ayma_voice_name`` preset preference (§13.3), or "" — the
    agent falls back to ``CONFIG.gemini_live_voice`` when it's empty/invalid."""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        return str((snap.to_dict() or {}).get(schema.PF_AYMA_VOICE, "")).strip()
    except Exception:  # noqa: BLE001
        logger.exception("could not read ayma_voice_name for %s", uid)
        return ""


def _ayma_voice_language(uid: str) -> str:
    """The user's speaking-voice instruction — free text like "Malayalam mixed
    with English" or "a Southern US accent", set on the settings screen or by
    ``set_voice_preference`` from conversation. "" = plain English default. A
    mid-call switch by the caller is handled by the prompt (§13.3)."""
    try:
        import voices

        snap = schema.profile_doc(get_db(), uid).get()
        return str(
            (snap.to_dict() or {}).get(voices.PF_AYMA_VOICE_LANGUAGE, "")
        ).strip()[:200]
    except Exception:  # noqa: BLE001
        logger.exception("could not read ayma_voice_language for %s", uid)
        return ""


def _server_ts():
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


async def _enforce_age(uid: str, *, require_birthdate: bool) -> None:
    """18+ gate (see ``age_gate``). Raises 403 ``{"code": "underage" |
    "birthdate_required"}``; an under-18 profile is closed as a side effect."""
    try:
        await asyncio.to_thread(
            age_gate.enforce, get_db(), _bucket, uid,
            require_birthdate=require_birthdate,
        )
    except age_gate.AgeGateError as exc:
        raise HTTPException(
            status_code=403, detail={"code": exc.code, "message": exc.message}
        ) from exc


async def require_adult_uid(uid: str = Depends(require_uid)) -> str:
    """Like ``require_uid`` but only for an adult with a birthdate on file.
    Guards matching / explore / DMs / sharing."""
    await _enforce_age(uid, require_birthdate=True)
    return uid


async def require_not_underage_uid(uid: str = Depends(require_uid)) -> str:
    """Like ``require_uid`` but refuses minors; a user with no birthdate yet is
    let through (mid-onboarding chat / voice)."""
    await _enforce_age(uid, require_birthdate=False)
    return uid


def _recovery_required(uid: str) -> bool:
    return account_ops.is_recovery_required(get_db(), uid)


def _session_mode(caller: Caller) -> str:
    """Derive the caller's ``session_mode`` (§3.3) from auth state + profile
    completeness. Best-effort: a Firestore read failure falls back to the
    conservative ``marketing``."""
    try:
        return session_mode.derive_for(
            get_db(), caller.uid, caller.is_anonymous
        )
    except Exception:  # noqa: BLE001
        logger.exception("session_mode derivation failed for %s", caller.uid)
        return session_mode.MODE_MARKETING


def _interview_progress(uid: str, mode: str) -> str:
    """The 'already captured' preboarding summary for interview-mode prompts —
    stops Ayma re-asking for a field the on-screen form already holds. Empty for
    every other mode. Best-effort: a read failure just omits it."""
    if mode != session_mode.MODE_INTERVIEW:
        return ""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        return session_mode.describe_progress(
            snap.to_dict() if snap.exists else None
        )
    except Exception:  # noqa: BLE001
        logger.exception("interview progress read failed for %s", uid)
        return ""


def _preferences_context(uid: str, mode: str) -> str:
    """The user's saved partner preferences for the system prompt (voice and
    chat). Empty for marketing mode. Best-effort: a read failure omits it."""
    if mode == session_mode.MODE_MARKETING:
        return ""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        return session_mode.describe_preferences(
            snap.to_dict() if snap.exists else None
        )
    except Exception:  # noqa: BLE001
        logger.exception("preferences context read failed for %s", uid)
        return ""


def _questionnaire_note(uid: str, mode: str) -> str:
    """The per-turn questionnaire nudge for a signed-in ``active``-mode user
    with either an explicit completion signal or their current score,
    relationship intent, and the top few nodes to pursue.
    Empty for every other mode (preboarding's own note owns that phase).
    Best-effort: any read failure just omits it."""
    if mode != session_mode.MODE_ACTIVE:
        return ""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        c = (snap.to_dict() or {}).get("completeness") if snap.exists else None
        if not isinstance(c, dict):
            return ""
        score = int(c.get("score") or 0)
        # `complete` is the real "nothing left in today's question set" signal
        # — `score` is capped below 100 even at full coverage (there's always
        # more Ayma could learn), so a literal-100 check would never fire.
        # `score >= 95` is kept as a fallback for a stale cached completeness
        # doc computed before this flag existed.
        # A result computed against an older question tree can claim
        # completion for nodes added since; only trust a current one.
        if completeness.is_current(c) and (
            c.get("complete") is True or score >= 95
        ):
            return (
                (Path(__file__).parent / "prompts" / "questionnaire_complete.md")
                .read_text(encoding="utf-8")
                .strip()
            )
        lines = [
            f"QUESTIONNAIRE (internal note — {score}% of today's tree is "
            "covered; never say that number, or any 'fuller' / 'more "
            "complete' / 'looking good' framing, out loud). When nothing "
            "more urgent is live in the conversation, quietly working through "
            "the profile questionnaire is your top priority — weave in one "
            "question at a time, conversationally (see the questionnaire "
            "guidance in your persona). Call `record_answer` the moment you "
            "have a clear answer.",
        ]
        if c.get("intent_set"):
            intent = str(c.get("intent") or "").replace("_", "-") or "unclear"
            lines.append(f"They're looking for a {intent} relationship.")
        else:
            lines.append(
                "Their relationship intent isn't set yet — finding that out is "
                "the priority, it routes the rest of the questionnaire."
            )
        nxt = [n for n in (c.get("next") or []) if isinstance(n, dict)][:3]
        if nxt:
            lines.append("Highest-priority topics still open:")
            for n in nxt:
                lines.append(f"- {n.get('label')}: {n.get('ayma_prompt')}")
        # This is the exact spot Ayma has actually gotten wrong in production
        # (real transcript, Sept 2026): right after weaving one of the above
        # in, she added a wrap-up line the questionnaire guidance already
        # forbids. Stated as a live banned/fixed pair, right where the
        # decision gets made, since restating the abstract rule alone hasn't
        # stopped the pattern.
        lines.append(
            'Once you\'ve asked one of these, do not add a closing remark '
            'like: "Well, that\'s a good chunk we\'ve covered then. Your '
            'profile\'s looking much fuller. Is there anything you\'ve been '
            'wondering about?" That exact shape — summing up progress, then '
            "handing control back — is banned no matter how it's worded. "
            "Just let your question be the end of the turn, or if it's not "
            "the moment for it, drop it silently and keep talking about "
            "whatever they're actually saying."
        )
        return "\n".join(lines)
    except Exception:  # noqa: BLE001
        logger.exception("questionnaire note read failed for %s", uid)
        return ""


async def _run_ingest(uid: str, session_id: str, turns: list[Turn]) -> None:
    """Wiki ingest (§2.3), run after the response is sent. Best-effort.

    Runs regardless of the user's credit balance — wiki ingest is exempt
    from the credit gate (see ``wiki_ingest`` module docstring); only a
    genuine ingest failure (a real Gemini/Firestore error) flags the session
    for the nightly backfill sweep to retry — via ``wiki_ingest.
    ingest_or_defer``, shared with the voice agent worker's own
    session-shutdown hook (``agent.py``)."""
    try:
        written = await wiki_ingest(get_db(), uid, session_id, turns)
        if written:
            logger.info("wiki ingest wrote %d page(s) for %s", written, uid)
    except Exception:  # noqa: BLE001
        logger.exception("wiki ingest failed for %s", uid)

from monitoring import init_sentry  # noqa: E402

init_sentry("ayma-api")  # no-op without SENTRY_DSN

import biometric_consent  # noqa: E402
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer  # noqa: E402
from firebase_admin import auth as _firebase_auth  # noqa: E402

# Signed-in calls that must work before the biometric consent is recorded:
# routing (/bootstrap reports `biometric_consent_required` itself), the age
# declaration, the consent endpoints, account delete / recover, and the
# pre-sign-in / sign-in helpers.
_CONSENT_EXEMPT_PATHS = frozenset({
    "/health",
    "/bootstrap",
    "/age-gate/declare",
    "/biometric-consent",
    "/biometric-consent/withdraw",
    "/account/delete",
    "/account/recover",
    "/welcome/token",
    "/instagram/signin-auth-url",
    "/instagram/signin",
})
_optional_bearer = HTTPBearer(auto_error=False)


async def require_biometric_consent(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(_optional_bearer),
) -> None:
    """App-wide gate (founder decision 2026-10-25): every authenticated
    feature endpoint refuses a caller without a biometric consent record with
    403 ``{"code": "biometric_consent_required"}``, which the app turns into
    the consent screen. Unauthenticated routes (cron, admin password, public
    share pages, webhooks) and an invalid token (the route's own auth answers
    401) pass through untouched."""
    if credentials is None or request.url.path in _CONSENT_EXEMPT_PATHS:
        return
    try:
        uid = _firebase_auth.verify_id_token(credentials.credentials)["uid"]
    except Exception:  # noqa: BLE001 - the route's own auth dependency rejects it
        return
    if not await asyncio.to_thread(biometric_consent.has_consent, get_db(), uid):
        raise _consent_required_error()


def _consent_required_error() -> HTTPException:
    """403 ``biometric_consent_required``; the header lets the app's HTTP
    layer spot it on any call without parsing the body."""
    return HTTPException(
        status_code=403,
        detail={
            "code": biometric_consent.CODE_REQUIRED,
            "message": biometric_consent.REQUIRED_MESSAGE,
        },
        headers={"X-Ayma-Consent-Required": "1"},
    )


app = FastAPI(
    title="Ayma Main API",
    version=CONFIG.version,
    dependencies=[Depends(require_biometric_consent)],
)

# Per-endpoint fixed-window rate limiting (§10.4, §10.6 step 3). Wraps every
# route; `/cron/*` is still additionally protected by the X-Cron-Secret check.
import ratelimit  # noqa: E402
from ratelimit import RateLimiter  # noqa: E402

app.add_middleware(RateLimiter)


@app.on_event("startup")
async def _warmup() -> None:
    """Pay the Gemini cold-start cost before serving traffic, so the first
    real /chat doesn't eat an ADC/gRPC/transient-5xx hiccup."""
    await gemini.warmup()


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness probe.

    Intentionally unauthenticated — the ID-token middleware added in a later
    step (§10.4) explicitly exempts this route.
    """
    return {"status": "ok", "service": "ayma-api", "version": CONFIG.version}


class BootstrapRequest(BaseModel):
    session_id: str = _SESSION_ID
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )


def _should_auto_dive(uid: str) -> bool:
    """True when ``uid`` has a usable research name and has not yet had the
    one-time automatic self deep-dive (§ auto analysis). Best-effort — any
    read failure just defers the dive to a later bootstrap."""
    try:
        if not deep_dive.profile_full_name(get_db(), uid):
            return False
        snap = get_db().collection("users").document(uid).get()
        if not getattr(snap, "exists", False):
            return True
        return not (snap.to_dict() or {}).get("auto_dive_done")
    except Exception:  # noqa: BLE001
        return False


def _should_auto_scan_photos(uid: str) -> bool:
    """True when ``uid`` has not yet had the one-time automatic reverse-image
    photo scan (§ web photo search). Mirrors :func:`_should_auto_dive`'s
    read/gate shape — a distinct flag (``web_photo_scan_done``) since the two
    background jobs are independent and one failing/being delayed must never
    block the other."""
    try:
        snap = get_db().collection("users").document(uid).get()
        if not getattr(snap, "exists", False):
            return True
        return not (snap.to_dict() or {}).get("web_photo_scan_done")
    except Exception:  # noqa: BLE001
        return False


@app.post("/bootstrap")
async def bootstrap(
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
    req: BootstrapRequest | None = Body(default=None),
) -> dict[str, object]:
    """Session bootstrap (§1.7 step 3, §1.1, §1.5).

    Mints the short-lived, room-scoped LiveKit token, and — when the client
    sends its recent-turns window — attaches the composed system prompt + that
    window to the room metadata so the auto-dispatched agent seeds its Gemini
    Live session with the same context ``/chat`` sees (Step 17). ``session_mode``
    is still the Step 6 stub; real derivation is Step 34.
    """
    uid = caller.uid
    try:
        await asyncio.to_thread(
            age_gate.enforce, get_db(), _bucket, uid, require_birthdate=False
        )
    except age_gate.AgeGateError as exc:
        return {"age_blocked": True, "uid": uid, "code": exc.code,
                "message": exc.message}
    if _recovery_required(uid):
        return {"recovery_required": True, "uid": uid}

    # `session_mode` drives which screen the client opens (§11.2 / entryRouteFor)
    # and is independent of credit state — derive it before anything can short-
    # circuit, so an out-of-credits user still lands on their real screen.
    mode = _session_mode(caller)

    # Mandatory biometric consent (biometric_consent.py): nothing past
    # onboarding — no voice room, no background face jobs — until it is
    # recorded. The app then records the consent ticked at sign-in, or shows
    # the one-time consent screen.
    if not await asyncio.to_thread(biometric_consent.has_consent, get_db(), uid):
        return {
            "biometric_consent_required": True,
            "session_mode": mode,
            "uid": uid,
        }

    # Automatic one-time self deep-dive (§ auto analysis): fires on the first
    # app open once onboarding has given us a real name, writes only to the
    # user's private `ai_only` memory, and never blocks this response.
    #
    # Primary trigger is now `POST /onboarding/complete`, fired reliably the
    # moment onboarding actually finishes rather than racing the next time
    # this endpoint happens to be called (§ web search about me — reliable
    # trigger). Both of these remain here purely as a fallback for any caller
    # that never reaches that endpoint (e.g. an account onboarded before it
    # existed) — each is idempotent via its own one-time flag.
    if _should_auto_dive(uid):
        background.add_task(auto_analysis.analyse_web, get_db(), uid)
    if _should_auto_scan_photos(uid):
        background.add_task(reverse_image_search.auto_scan, get_db(), uid)

    # Voice is an LLM session — no credits, no room (heuristic-only paths keep
    # working). Still return `session_mode` so the client routes normally and
    # merely shows "reload credits"; just drop the LiveKit creds.
    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {
            "session_mode": mode,
            "uid": uid,
            "turn_cap": turn_caps.peek(get_db(), uid, mode),
            "usage_capped": True,
        }

    if not CONFIG.livekit_url:
        raise HTTPException(
            status_code=503, detail="LIVEKIT_URL is not configured."
        )
    room = room_name_for(uid)
    try:
        token = mint_access_token(uid, room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    turns = _to_turns(req.recent_turns) if req else []
    session_id = req.session_id if req else ""

    # A routing-only probe (splash_screen.dart's `session_id=""` call, made
    # purely to read `session_mode` before the user has asked for voice at
    # all — no real caller ever starts a voice session with an empty
    # `session_id`; see `newSessionId()`, always non-empty) must not touch
    # any voice room. Waking the scale-to-zero agent and seeding a room here
    # would waste a Cloud Run cold start on a call that never connects, and
    # `seed_room_context` creating the room would trigger LiveKit's
    # auto-dispatch-on-room-creation into an agent job for a room nobody
    # joins, seeded with this call's empty `recent_turns` (when room names
    # were still one-per-user, the mechanism behind Ayma re-asking
    # already-covered ground on nothing more than the app being reopened,
    # founder report 2026-09-25). Token minting alone is cheap/stateless
    # (just a signed JWT) so it still happens unconditionally below, keeping
    # this call's response shape unchanged for `splash_screen.dart`.
    if session_id:
        # Fire the ayma-agent wake ping as early as possible (§ scale-to-zero,
        # docs/deploy.md §12.2, agent_wake.py) so Cloud Run starts the
        # container in parallel with the LiveKit token mint + room creation
        # below, rather than only after the client has already connected.
        background.add_task(agent_wake.wake_agent)
        voice_language = _ayma_voice_language(uid)
        # Phase 2 voice seed diet (cost program 2026-09-26): the Live API
        # re-bills the whole seeded context on every turn of the call, so at
        # level >= 2 the session is seeded with a compact core persona card
        # (~2k chars of core wiki pages) + the rolling summary + only the last
        # ~10 raw turns, instead of the full wiki block + the whole client
        # window. The FULL window is still persisted below and still travels
        # in the room metadata for the agent's raw_turns shutdown persistence
        # — only what the model sees is dieted (the agent trims its own
        # chat_ctx seeding under the same flag).
        prompt_turns = turns
        summary_text = ""
        if context_opt.voice_seed_diet_enabled():
            prompt_turns = turns[-context_opt.voice_tail_turns():]
            wiki_ctx = read_wiki_context(
                get_db(), uid,
                max_chars=context_opt.core_wiki_chars(),
                include_page_types=context_opt.CORE_PAGE_TYPES,
            )
            summary_text = context_opt.stored_summary_text(get_db(), uid)
        else:
            # `assessment` (Ayma's judgment page, ai_assessment.py) stays out
            # of the standing context — recall-tool reachable, matching gets
            # it explicitly; see ai_assessment's module docstring.
            wiki_ctx = read_wiki_context(
                get_db(), uid,
                exclude_page_types=ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT,
            )
        system_prompt = compose_system_prompt(
            recent_turns=prompt_turns,
            wiki_context=wiki_ctx,
            session_mode=mode,
            profile_progress=_interview_progress(uid, mode),
            preferences_context=_preferences_context(uid, mode),
            questionnaire_note=_questionnaire_note(uid, mode),
            db=get_db(),
            summary_context=summary_text,
            # Voice persona variant (prompt.py `_persona_variant`): the Live
            # API re-bills every resident token per turn, so the seed drops
            # the persona rules that cannot fire in a voice session.
            variant="voice",
        ) + "\n\n" + prompt_module.voice_language_directive(voice_language)
        # Phase 0 measurement (cost program 2026-09-26): what this voice
        # session's Live context is being seeded with, by component. The Live
        # API re-bills the accumulated session context every turn, so this
        # seed is the per-turn floor of the whole call.
        history_rendered = (
            format_recent_turns(prompt_turns) if prompt_turns else ""
        )
        context_opt.record_breakdown(
            get_db(), uid, "voice_seed",
            {
                "system": max(
                    0,
                    len(system_prompt) - len(wiki_ctx) - len(history_rendered)
                    - len(summary_text),
                ),
                "wiki": len(wiki_ctx),
                "history": len(history_rendered),
                "summary": len(summary_text),
            },
            session_id=session_id,
        )
        voice_name = _ayma_voice_name(uid)
        try:
            await seed_room_context(
                room,
                build_room_seed(
                    system_prompt, turns, uid, session_id, voice_name,
                    voice_language=voice_language,
                ),
            )
        except Exception:  # noqa: BLE001 - seeding is best-effort, never blocks voice
            logger.exception("failed to seed room context for %s", room)

        if turns:
            _persist_session(uid, session_id, turns)

    return {
        "session_mode": mode,
        "uid": uid,
        "turn_cap": turn_caps.peek(get_db(), uid, mode),
        "livekit": {
            "token": token,
            "url": CONFIG.livekit_url,
            "room": room,
            # The configured voice backend (`inference` / `google`), only so
            # the client can tag a failed voice start in its crash reports.
            "voice_provider": feature_flags.get("voice_provider"),
        },
    }


@app.post("/onboarding/complete")
async def onboarding_complete(
    background: BackgroundTasks, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The client calls this once, right when preboarding actually finishes
    (§ web search about me — reliable trigger) — the real moment a text-only
    user (who may never call ``/bootstrap`` again) has a usable name and
    profile photo, instead of hoping a `/bootstrap` call happens to race in
    after onboarding before the app is closed.

    Schedules the one-time automatic self web-search dive and the one-time
    automatic reverse-image photo scan as background tasks, each gated by its
    own already-existing one-time flag (``auto_dive_done`` /
    ``web_photo_scan_done``) — so this is safe to call more than once, and
    `/bootstrap` keeps firing the same two jobs as a fallback for any caller
    that never reaches this endpoint. Never blocks on either job; always
    ``200``.
    """
    dive_triggered = _should_auto_dive(uid)
    if dive_triggered:
        background.add_task(auto_analysis.analyse_web, get_db(), uid)
    scan_triggered = _should_auto_scan_photos(uid)
    if scan_triggered:
        background.add_task(reverse_image_search.auto_scan, get_db(), uid)
    return {
        "triggered": dive_triggered or scan_triggered,
        "web_search": dive_triggered,
        "photo_scan": scan_triggered,
    }


# --- POST /welcome/token (pre-sign-in voice greeting) ------------------

_WELCOME_GREETING = (
    "Open the call. In two or three sentences: you're Ayma, their matchmaker "
    "— you get to know them by talking, then find and introduce people who "
    "actually fit. Then tell them to sign in on this screen (Google, email or "
    "phone) to get started. Warm, brief, inviting — no questions yet."
)
# Best-effort per-IP throttle (single process; a burst across Cloud Run
# instances can still slip through — acceptable for an ephemeral greeting room).
_welcome_hits: dict[str, list[float]] = {}
_WELCOME_MAX_PER_MIN = 4


def _welcome_rate_ok(ip: str) -> bool:
    import time as _t

    now = _t.time()
    hits = [h for h in _welcome_hits.get(ip, []) if now - h < 60]
    if len(hits) >= _WELCOME_MAX_PER_MIN:
        _welcome_hits[ip] = hits
        return False
    hits.append(now)
    _welcome_hits[ip] = hits
    if len(_welcome_hits) > 4000:  # crude cap so the dict can't grow unbounded
        _welcome_hits.clear()
    return True


@app.post("/welcome/token")
async def welcome_token(
    request: Request, background: BackgroundTasks
) -> dict[str, object]:
    """A LiveKit token for the pre-sign-in "welcome" room. Unauthenticated by
    design — there is no account yet. The auto-dispatched agent reads a
    greeting-framed persona from the room metadata and opens the call; the
    session carries no ``uid`` (unmetered) and is meant to last under a minute.
    """
    ip = (request.client.host if request.client else "") or "unknown"
    if not _welcome_rate_ok(ip):
        raise HTTPException(status_code=429, detail="Slow down a moment.")
    if not CONFIG.livekit_url:
        raise HTTPException(status_code=503, detail="Voice is unavailable.")

    # See the matching call in /bootstrap above — wakes the scale-to-zero
    # ayma-agent worker as early as possible.
    background.add_task(agent_wake.wake_agent)
    room = f"welcome-{secrets.token_urlsafe(9)}"
    try:
        token = mint_access_token(f"guest-{room}", room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    try:
        await seed_room_context(
            room,
            build_room_seed(
                prompt_module.compose_welcome_prompt(),
                [],
                "",
                "",
                greeting_instructions=_WELCOME_GREETING,
            ),
        )
    except Exception:  # noqa: BLE001 - best-effort; the agent still has a base persona
        logger.exception("failed to seed welcome room %s", room)

    return {"livekit": {"token": token, "url": CONFIG.livekit_url, "room": room}}


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    session_id: str = _SESSION_ID
    # A client-generated id unique to ONE user send (stable across retries of
    # that same send). Makes the turn idempotent: a retry whose original
    # attempt actually landed — the app was backgrounded and the socket died
    # while the server kept working — is answered from the persisted reply
    # (or joined to the still-running turn) instead of generated and billed
    # again. Optional: an older client simply gets no dedup.
    client_msg_id: str = Field(
        default="", max_length=64, pattern=r"^[A-Za-z0-9_-]*$"
    )
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )
    viewing_profile_uid: str = Field(default="", max_length=128)
    # A photo the user attached, already uploaded to their own uploads/ tree
    # (§2.2). Empty for a plain text turn.
    image_path: str = Field(default="", max_length=256)
    # Set when the chat is opened in a sheet from the Your Story editor: the
    # section being worked on and (optionally) the highlighted passage. Ayma
    # gets these as context plus the story-edit tools bound to that section.
    story_page_id: str = Field(default="", max_length=80)
    story_passage: str = Field(default="", max_length=8000)
    # Set when the Ask Ayma overlay is opened from one row of the structured
    # career timeline instead of a highlighted passage — scopes the
    # `edit_career_timeline_entry` / `delete_career_timeline_entry` tools to
    # that entry. `story_page_id` is still set (to "career") alongside this.
    story_timeline_entry_id: str = Field(default="", max_length=64)
    # Set when the Ask Ayma chat is opened from a deep-dive (web-search) report
    # item: a fact, the summary, a social-profile link, or a "photos of you
    # found online" image. `deep_dive_target` is "summary", "fact:<fact_id>",
    # "social:<url>", or "photo:<url>".
    deep_dive_report_id: str = Field(default="", max_length=128)
    deep_dive_target: str = Field(default="", max_length=2200)
    # Set when the Ask Ayma chat is opened from one finding on the Appearance
    # report: a `physical_attributes.fields()` name, or the literal "face"/"body".
    appearance_finding_id: str = Field(default="", max_length=64)
    # Set when the Ask Ayma chat is opened from a Match report — the
    # `matches/{matchId}` doc id (`pair_key.sorted_pair_key`). Unlike Story /
    # deep-dive / Appearance, this doesn't unlock any new tool (the score
    # itself can't be edited); it just briefs Ayma that a disputed fact
    # behind the score should be corrected via the profile/questionnaire
    # tools she already has, then followed by a Recalculate.
    match_report_id: str = Field(default="", max_length=128)
    # Set when the chat is opened to edit the user's OWN public profile: unlocks
    # the profile section-edit tools (list / rewrite / show-hide a section).
    profile_edit: bool = False
    # Set when the chat is opened from "Chat about it" on one photo in Your
    # Story: unlocks the photo-note tool, scoped to that photo.
    photo_url: str = Field(default="", max_length=2000)
    photo_source: str = Field(default="", max_length=16)
    # The screen the user was looking at when this chat was opened (the
    # floating Ayma launcher's page-context threading, §F4) — the same shape
    # as the Flutter client's `ScreenContext`/`AppContext`. Folded into the
    # system prompt as a short one-line description
    # (`skills.app_control._describe`) unless `screen == "profile"`, which
    # already gets the much richer `viewing_profile_uid` briefing above.
    screen: str = Field(default="", max_length=32)
    screen_subject_uid: str = Field(default="", max_length=128)
    screen_subject_name: str = Field(default="", max_length=200)
    screen_note: str = Field(default="", max_length=500)
    # The generic capture of that screen (route pattern, a screen-owned
    # summary, and the live text + operable controls); see
    # `app_registry.json` `screen_context`.
    screen_route: str = Field(default="", max_length=200)
    screen_detail: str = Field(default="", max_length=1500)
    screen_visible: str = Field(default="", max_length=3200)


_USAGE_CAPPED_REPLY = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)

# A photo the user shares in chat is usually a selfie — but not always (they
# might be showing you someone whose profile they're browsing). Before Ayma
# reacts to it as "you", check the face against the user's most authoritative
# reference (`deep_dive_images.reference_embeddings_for`). `sim >=
# _VERIFY_THRESHOLD` → it's them; a clear gap below → someone else; the band
# in between (and any failure / no reference at all) → can't tell. The margin
# is `deep_dive_images._VERIFY_MARGIN` — shared, not re-declared here.
_SHARED_PHOTO_NOT_SELF_MARGIN = deep_dive_images._VERIFY_MARGIN

_SHARED_PHOTO_NOTES = {
    "self": (
        "The photo the user just shared looks like them (a selfie / photo of "
        "themselves)."
    ),
    "not_self": (
        "The photo the user just shared does NOT look like the account holder "
        "— it appears to be someone else. Do not respond as if it's a photo of "
        "them. If you don't already know who this is, ask who's in the picture "
        "before commenting on their looks."
    ),
    "unknown": (
        "You can't verify whether the photo the user just shared is of them. "
        "Don't assume it's a selfie; if it matters, ask who's in it."
    ),
}


def _classify_shared_photo(db, uid: str, image: tuple[bytes, str]) -> str:
    """Best-effort face match of a chat-shared photo against the user's own
    profile photos. Returns ``"self"`` / ``"not_self"`` / ``"unknown"`` —
    ``"unknown"`` whenever there's nothing to compare against or anything
    fails (embedding, compare). Never raises; runs one extra embed call, so
    call it from a worker thread with the image already downloaded.

    This is the freshest, most contextually-grounded same-person signal in
    the app — computed at the exact moment the user shares the photo. A
    confident result (``"self"``/``"not_self"``) is persisted onto the
    photo's gallery note by :func:`_persist_shared_photo_verdict` right after
    this returns, so Your Story's photo gallery (``photo_notes.
    classify_and_dedupe``'s lazy fallback verdict, §``_face_verdict``) agrees
    with what the user was just told in chat instead of disagreeing forever."""
    try:
        refs = deep_dive_images.reference_embeddings_for(db, uid)
    except Exception:  # noqa: BLE001
        return "unknown"
    if not refs:
        return "unknown"
    try:
        img_bytes, mime = image
        emb = media_embed.embed_image_bytes(img_bytes, mime)
    except Exception:  # noqa: BLE001
        logger.warning("shared-photo verify: embed failed for %s", uid,
                       exc_info=True)
        return "unknown"
    return deep_dive_images.classify_face_match(emb, refs)


def _persist_shared_photo_verdict(
    db, uid: str, image_path: str, kind: str
) -> None:
    """Write a confident :func:`_classify_shared_photo` verdict onto this
    photo's ``photo_notes`` entry, so the Your Story gallery's "Ayma thinks
    this is you" reflects the same-turn chat check rather than whatever the
    gallery's own lazy classifier (``photo_notes.classify_and_dedupe`` /
    ``_face_verdict``) may have cached earlier from a weaker reference. Only
    called for ``"self"``/``"not_self"`` — never for ``"unknown"``, which has
    nothing new to say and must not clobber an existing verdict.

    Deliberately overwrites (via ``photo_notes.set_context``) rather than
    skip-if-cached: this real-time check is the more authoritative signal, so
    it should win over a stale one. Best-effort — a failure here never
    affects the chat turn itself."""
    try:
        from public_profile import _photo_url
        import photo_notes

        url = _photo_url(image_path)
        if not url:
            return
        photo_notes.set_context(
            db, uid, url, is_user="yes" if kind == "self" else "no"
        )
    except Exception:  # noqa: BLE001
        logger.warning(
            "shared-photo verify: failed to persist verdict for %s", uid,
            exc_info=True,
        )


def _resolve_photo_context_image(url: str) -> tuple[bytes, str] | None:
    """Best-effort fetch of the actual bytes for a photo-scoped chat's
    ``photo_url`` (the "Chat about it" / "Talking about this photo" flow) —
    so Ayma actually sees what the chat is about, not just a text note about
    where it came from.

    ``url`` is the resolved download URL the client already displays
    (``public_profile._photo_url``'s format for a profile/chat-sourced photo,
    some other site entirely for a ``source="web"`` deep-dive find — see
    ``AiNotePhoto`` in the Flutter client). Tries our own Storage URL shape
    first via ``photo_notes.resolve_storage_path`` + the same authenticated
    ``media_embed.download_bytes`` every other image on this backend goes
    through; falls back to a plain HTTP GET (``deep_dive_images._fetch_image``,
    the same helper deep-dive already uses for images found on the open web)
    for a URL that isn't one of ours. Never raises — a deleted photo, an
    expired link, or a transient Storage/network error should degrade to the
    older text-only framing, not fail the whole chat turn."""
    try:
        storage_path = photo_notes.resolve_storage_path(url)
        if storage_path:
            return media_embed.download_bytes(storage_path)
        return deep_dive_images._fetch_image(url)
    except Exception:  # noqa: BLE001 - best-effort; caller falls back to text
        logger.warning(
            "photo-context image fetch failed for %s", url, exc_info=True
        )
        return None


@dataclass
class _ChatCtx:
    uid: str
    image: tuple[bytes, str] | None
    image_path: str
    window: list
    system_prompt: str
    story_page_id: str = ""
    story_passage: str = ""
    story_timeline_entry_id: str = ""
    deep_dive_report_id: str = ""
    deep_dive_target: str = ""
    appearance_finding_id: str = ""
    match_report_id: str = ""
    profile_edit: bool = False
    photo_url: str = ""
    photo_source: str = ""
    # The actual bytes of the ``photo_url`` photo, resolved by
    # :func:`_resolve_photo_context_image` when this turn has no fresh
    # ``image_path`` of its own — ``None`` when there's no photo context or
    # the fetch failed. Kept separate from ``image`` (a photo freshly
    # attached *this turn*) since it must never trigger the "just shared a
    # photo" history/caption/self-match handling in ``_finalize_chat`` /
    # ``_run_chat_followups`` — this photo isn't new, Ayma is just now able
    # to see it.
    photo_image: tuple[bytes, str] | None = None
    # Mutable sink the bound ``edit_photo`` (skills/photo_edit.py) and
    # ``generate_image`` (skills/generate_image.py) tools write
    # ``image_path`` / ``image_url`` into on success — the tool's own return
    # value only ever reaches the model as text, so this is how the finished
    # chat turn (§ /chat, /chat/stream) and the durable transcript
    # (``_finalize_chat``) learn an edited/generated photo was made this turn.
    photo_edit_result: dict = field(default_factory=dict)


async def _prepare_chat(
    req: ChatRequest, caller: Caller
) -> tuple[dict | None, _ChatCtx | None]:
    """Shared setup for ``/chat`` and ``/chat/stream``: turn cap → image →
    prompt compose. Returns ``(early_response, None)`` when the turn is capped,
    else ``(None, ctx)``. Raises ``HTTPException`` for a bad image path."""
    uid = caller.uid
    mode = _session_mode(caller)
    cap = turn_caps.evaluate(get_db(), uid, mode)
    if not cap.allowed:
        return (
            {
                "reply": cap.canned_reply or "",
                "capped": True,
                "fallback_form": cap.fallback_form,
                "turn_cap": {
                    "mode": cap.mode, "count": cap.count, "cap": cap.cap
                },
            },
            None,
        )

    image_path = req.image_path.strip()
    image: tuple[bytes, str] | None = None
    if image_path:
        if not image_path.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_path must be under the caller's uploads/ tree.",
            )
        try:
            img_bytes, mime = await asyncio.to_thread(
                media_embed.download_bytes, image_path
            )
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(
                status_code=502, detail=f"Could not read the image: {exc}"
            ) from exc
        # No app-side content check on a photo the user shares privately with
        # Ayma — Gemini's own API safety is the backstop.
        image = (img_bytes, mime)

    # Is that shared photo actually the account holder? Best-effort face check
    # so Ayma doesn't answer "how do I look?" about a stranger. One extra embed
    # call, off-thread, only when an image is already in hand — never 500s.
    shared_photo_note = ""
    if image is not None:
        kind = await asyncio.to_thread(
            _classify_shared_photo, get_db(), uid, image
        )
        shared_photo_note = _SHARED_PHOTO_NOTES.get(kind, "")
        if kind in ("self", "not_self"):
            await asyncio.to_thread(
                _persist_shared_photo_verdict, get_db(), uid, image_path, kind
            )

    # "Chat about it" / "Talking about this photo": the chat is scoped to one
    # existing photo (`photo_url`), separate from a brand-new attachment via
    # `image_path` above. When this turn has no fresh attachment of its own,
    # resolve that photo's actual bytes so Ayma can see it too, not just read
    # a text note about where it came from (§ founder bug report — Ayma had
    # zero visual access to "Talking about this photo").
    photo_url = req.photo_url.strip()
    photo_source = req.photo_source.strip()
    photo_image: tuple[bytes, str] | None = None
    if photo_url and image is None:
        photo_image = await asyncio.to_thread(
            _resolve_photo_context_image, photo_url
        )

    window = _to_turns(req.recent_turns)
    story_page_id = req.story_page_id.strip()
    story_passage = req.story_passage.strip()
    story_timeline_entry_id = req.story_timeline_entry_id.strip()
    deep_dive_report_id = req.deep_dive_report_id.strip()
    deep_dive_target = req.deep_dive_target.strip()
    appearance_finding_id = req.appearance_finding_id.strip()
    match_report_id = req.match_report_id.strip()
    screen = req.screen.strip()
    viewing_profile_uid = req.viewing_profile_uid.strip()
    # Skip when the profile case already covers it — a bare "looking at X's
    # profile" line would only be redundant next to the full briefing below.
    screen_route = req.screen_route.strip()
    current_screen_context = (
        ""
        if not (screen or screen_route)
        or (screen == "profile" and viewing_profile_uid)
        else app_control_mod._describe(
            {
                "screen": screen,
                "subject_uid": req.screen_subject_uid.strip(),
                "subject_name": req.screen_subject_name.strip(),
                "note": req.screen_note.strip(),
                "detail": req.screen_detail.strip(),
                "route": screen_route,
                "visible": req.screen_visible.strip(),
            }
        )
    )
    # Phase 2 context diet (cost program 2026-09-26), all level-gated with the
    # old full-context path preserved verbatim at level < 2:
    # * wiki: only the always-on core + the page types this message's topics
    #   route to (context_opt.wiki_include_types), on a smaller budget,
    #   instead of the full ~12k-char block;
    # * history: the rolling summary + the last N raw turns instead of the
    #   whole ~200-turn client window. The FULL window still drives
    #   persistence and tool provenance below — only the prompt is dieted.
    if context_opt.recall_enabled():
        # Phase 3: the standing wiki context is just the core persona card —
        # everything else is one `recall(topic)` tool call away (the tool is
        # registered in this turn's tool set under the same flag).
        wiki_ctx = read_wiki_context(
            get_db(), uid,
            max_chars=context_opt.core_wiki_chars(),
            include_page_types=context_opt.CORE_PAGE_TYPES,
        )
    elif context_opt.wiki_trim_enabled():
        wiki_ctx = read_wiki_context(
            get_db(), uid,
            max_chars=context_opt.trim_wiki_chars(),
            include_page_types=context_opt.wiki_include_types(req.message),
        )
    else:
        # `assessment` (Ayma's judgment page) is excluded from the standing
        # chat context on every level — recall-tool reachable when needed.
        wiki_ctx = read_wiki_context(
            get_db(), uid,
            exclude_page_types=ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT,
        )
    prompt_window = window
    summary_text = ""
    if context_opt.summary_enabled():
        prompt_window = context_opt.trim_history(window)
        if len(window) > len(prompt_window):
            summary_text = context_opt.stored_summary_text(get_db(), uid)
    system_prompt = compose_system_prompt(
        recent_turns=prompt_window,
        wiki_context=wiki_ctx,
        session_mode=mode,
        profile_progress=_interview_progress(uid, mode),
        preferences_context=_preferences_context(uid, mode),
        questionnaire_note=_questionnaire_note(uid, mode),
        viewing_profile_context=public_profile_mod._viewing_profile_context(
            get_db(), uid, viewing_profile_uid
        ),
        story_context=_story_edit_context(
            story_page_id, story_passage, story_timeline_entry_id
        )
        or _deep_dive_edit_context(deep_dive_report_id, deep_dive_target)
        or _appearance_edit_context(appearance_finding_id)
        or _match_edit_context(match_report_id)
        or _photo_edit_context(photo_url, photo_source, photo_image is not None)
        or (_attached_photo_edit_context() if image is not None else ""),
        shared_photo_note=shared_photo_note,
        current_screen_context=current_screen_context,
        db=get_db(),
        summary_context=summary_text,
        # Phase 1 (cost program 2026-09-26): byte-stable prompt prefix for
        # Gemini's implicit prefix caching. Level 0 keeps the old order
        # byte-for-byte.
        stable_prefix=context_opt.stable_prefix_enabled(),
    )
    # Phase 0 measurement (cost program 2026-09-26): per-component prompt-size
    # breakdown for this turn — logged always, persisted to `token_turns` when
    # CONTEXT_OPT_MEASURE is on. `system` is everything in the prompt that
    # isn't the wiki block, the rendered history window, or the summary.
    history_rendered = format_recent_turns(prompt_window) if prompt_window else ""
    context_opt.record_breakdown(
        get_db(), uid, "chat",
        {
            "system": max(
                0,
                len(system_prompt) - len(wiki_ctx) - len(history_rendered)
                - len(summary_text),
            ),
            "wiki": len(wiki_ctx),
            "history": len(history_rendered),
            "summary": len(summary_text),
            "message": len(req.message),
        },
        session_id=req.session_id,
    )
    return (
        None,
        _ChatCtx(
            uid, image, image_path, window, system_prompt,
            story_page_id, story_passage, story_timeline_entry_id,
            deep_dive_report_id, deep_dive_target, appearance_finding_id,
            match_report_id,
            bool(req.profile_edit),
            photo_url, photo_source, photo_image,
        ),
    )


def _story_edit_context(page_id: str, passage: str, timeline_entry_id: str = "") -> str:
    if not page_id:
        return ""
    if timeline_entry_id:
        return (
            "STORY EDITOR: the user opened this chat from one entry of their "
            "Your Story career timeline (a single job or degree), not a "
            "highlighted passage. Use `edit_career_timeline_entry` to correct "
            "its organisation/title/degree/dates, or "
            "`delete_career_timeline_entry` if they want that entry removed "
            "entirely. Confirm what you did in one line and keep chatting — "
            "it's saved immediately, no separate accept step."
        )
    lines = [
        "STORY EDITOR: the user opened this chat from their Your Story editor "
        "to work on one section of their profile story.",
    ]
    if passage:
        lines.append(f'They highlighted this passage:\n"{passage}"')
        lines.append(
            "Use `set_passage_privacy` / `edit_passage` / `remove_from_profile` "
            "to change *that passage only*. `remove_from_profile` is NOT a "
            "hard delete — it takes the passage off their profile (public and "
            "normal Story views) but keeps it in your memory, visible to them "
            "under Ayma's Notes; say it that way, don't imply it's gone for "
            "good. Use `set_section_privacy` only if they clearly mean the "
            "whole section. Confirm what you did in one line and keep "
            "chatting — the change is saved as a version they can revert, so "
            "there's no separate accept step."
        )
    else:
        lines.append(
            "No passage is highlighted — talk about the section as a whole. "
            "Use `set_section_privacy` for a whole-section visibility change."
        )
    return "\n".join(lines)


def _deep_dive_edit_context(report_id: str, target: str) -> str:
    if not report_id or not target:
        return ""
    if target == "summary":
        return (
            "WEB-SEARCH REPORT: the user opened this chat from the summary "
            "of their deep-dive report. Use `correct_deep_dive_item` with "
            "their feedback, close to verbatim, to revise it — the summary "
            "can't be deleted outright, only revised. Confirm what you did "
            "in one line and keep chatting."
        )
    kind = target.split(":", 1)[0]
    noun = {"fact": "claim", "social": "social-profile link", "photo": "photo"}.get(kind, "finding")
    lines = [
        f"WEB-SEARCH REPORT: the user opened this chat from one {noun} on "
        "their deep-dive report.",
        f"Use `correct_deep_dive_item` with their feedback, close to "
        f"verbatim, if they're correcting or adding nuance to this {noun}.",
    ]
    if kind in ("fact", "social", "photo"):
        lines.append(
            f"Use `remove_deep_dive_item` (no arguments) if they've clearly "
            f"said this {noun} is wrong or not theirs (e.g. \"delete this\", "
            f"\"that's not my photo\", \"that's not my link\") — it's a real, "
            "immediate removal from the report and it won't come back on a "
            "future search."
        )
    lines.append("Confirm what you did in one line and keep chatting.")
    return "\n".join(lines)


def _appearance_edit_context(finding_id: str) -> str:
    if not finding_id:
        return ""
    is_axis = finding_id in ("face", "body")
    lines = [
        "APPEARANCE REPORT: the user opened this chat from one finding on "
        f"their Appearance report ({finding_id}).",
        "Use `correct_appearance_item` with their feedback, close to "
        "verbatim, to correct it.",
    ]
    if not is_axis:
        lines.append(
            "Use `clear_appearance_item` (no arguments) if they want their "
            "stated value removed entirely so it reverts to whatever your "
            "photo analysis shows (or unknown) — e.g. \"delete this\", "
            "\"I never said that, remove it\"."
        )
    lines.append("Confirm what you did in one line and keep chatting — every change saves immediately.")
    return "\n".join(lines)


def _match_edit_context(match_report_id: str) -> str:
    if not match_report_id:
        return ""
    return (
        "MATCH REPORT: the user opened this chat from a Match report. The "
        "compatibility score is computed algorithmically from both people's "
        "profiles — you can't edit the score or its breakdown directly, and "
        "there's no tool for that. But if they push back on a FACT behind "
        "the score (e.g. \"I don't live in Colorado\", a stale questionnaire "
        "answer, anything else in their own profile), fix the underlying "
        "data: use `set_profile_field` for identity fields (location, "
        "birthdate, gender, interested_in, etc.) or `record_answer` for a "
        "questionnaire item. Once it's corrected, tell them to tap "
        "Recalculate on the report — say a recalculation will pick up the "
        "fix, don't claim you've updated the score yourself, since you've "
        "only fixed what feeds into it. If what they're disputing is about "
        "the OTHER person, explain you can only edit their own profile, not "
        "the other person's."
    )


def _attached_photo_edit_context() -> str:
    """Same `edit_photo` permission `_photo_edit_context` gives the "Chat
    about it" flow, for a photo attached directly to a normal chat message
    instead — no `photo_url`/Your Story origin at all, just an image on this
    turn (§ founder report: "make him a wolf" on a photo attached in the main
    chat got "I can't actually edit or generate photos" because the tool was
    only ever bound when `photo_url` was set)."""
    return (
        "The user just attached a photo to this message, which you can see. "
        "If they ask for an edited version of the photo itself (e.g. 'make "
        "this a studio photo', 'make him a wolf', 'brighten this up'), call "
        "`edit_photo` with what they asked for — you CAN generate a real "
        "edited image yourself, right now; don't say you can't edit images "
        "or offer only text advice when they've actually asked for an edit."
    )


def _photo_edit_context(url: str, source: str, attached: bool = False) -> str:
    if not url:
        return ""
    where = {
        "profile": "one of their public profile photos",
        "chat": "a photo they shared with you in chat",
        "web": "a photo you found of them on the open web",
    }.get(source, "a photo")
    can_delete = (
        "If they ask you to remove/delete this photo, use `delete_photo` — "
        "you CAN do that yourself, right now; don't tell them you can't or "
        "send them to do it manually in the app."
    )
    if attached:
        can_edit = (
            "If they ask for an edited version of this photo itself (e.g. "
            "'make this a studio photo', 'give it a plain background', "
            "'brighten this up'), call `edit_photo` with what they asked for "
            "— you CAN generate a real edited image yourself, right now; "
            "don't say you can't edit images or offer only text advice when "
            "they've actually asked for the edit."
        )
        return (
            "PHOTO: the user opened this chat from Your Story to talk about "
            f"{where}, which you can see attached to this message. If they "
            "tell you something new about it — who's in it, that it isn't "
            "them — call `update_photo_note` to write that down; don't just "
            f"say it back to them. {can_delete} {can_edit}"
        )
    # The photo couldn't be attached this turn (fetch failed, or gone) — fall
    # back to the older text-only framing rather than claiming she can see
    # something she can't.
    return (
        "PHOTO: the user opened this chat from Your Story to talk about "
        f"{where}. If they tell you what it shows, who's in it, or that it "
        "isn't them, call `update_photo_note` to write that down — don't "
        f"just say it back to them. {can_delete}"
    )


# The generate→moderate→persist pipeline of every in-flight chat turn runs in
# its own task, held here so a client disconnect (app backgrounded mid-send —
# the founder bug 2026-09-28) can only cancel the RESPONSE, never the turn:
# uvicorn/starlette cancel a StreamingResponse's generator the moment the
# socket drops (verified in tests/test_chat.py), which used to abort the
# Gemini call mid-flight — or worse, after it was billed but before
# `_finalize_chat` persisted the reply. The strong references also keep the
# orphaned tasks alive to completion (asyncio only weakly references tasks).
_TURN_TASKS: set[asyncio.Task] = set()

# In-flight turns by (uid, client_msg_id), so a retry of a send whose first
# attempt is STILL RUNNING joins that run's result instead of starting (and
# billing) a second one. Per-process — a retry landing on another Cloud Run
# instance falls through to the persisted-reply check instead.
_INFLIGHT_TURNS: dict[tuple[str, str], asyncio.Task] = {}


def _turn_key(uid: str, req: ChatRequest) -> tuple[str, str] | None:
    cmid = (req.client_msg_id or "").strip()
    return (uid, cmid) if cmid else None


def _spawn_turn(coro, *, key: tuple[str, str] | None = None) -> asyncio.Task:
    """Run ``coro`` in a disconnection-proof task: strongly referenced until
    done, registered under ``key`` for in-flight retry joining, failures
    logged (an orphaned turn has no response left to surface them on)."""
    task = asyncio.create_task(coro)
    _TURN_TASKS.add(task)
    if key is not None:
        _INFLIGHT_TURNS[key] = task

    def _done(t: asyncio.Task) -> None:
        _TURN_TASKS.discard(t)
        if key is not None and _INFLIGHT_TURNS.get(key) is t:
            del _INFLIGHT_TURNS[key]
        if not t.cancelled() and t.exception() is not None:
            logger.error("chat turn task failed: %r", t.exception())

    task.add_done_callback(_done)
    return task


async def _persisted_turn_reply(uid: str, req: ChatRequest) -> dict | None:
    """The already-persisted response for this exact send, if its first
    attempt completed server-side — the idempotent answer to a retry."""
    key = _turn_key(uid, req)
    if key is None:
        return None
    try:
        found = await asyncio.to_thread(
            chat_history.reply_for_client_id, get_db(), uid, key[1]
        )
    except Exception:  # noqa: BLE001 - dedup is best-effort, never a 500
        return None
    if found is None:
        return None
    return {
        "reply": found["text"],
        "tools_used": found.get("tools") or [],
        "image_url": found.get("image_url", ""),
        "duplicate": True,
    }


def _finalize_chat(
    background: BackgroundTasks,
    ctx: _ChatCtx,
    req: ChatRequest,
    reply_text: str,
    tools_used: list[str] | None = None,
) -> None:
    """Durable transcript + raw_turns + wiki-ingest kickoff after a reply
    (shared by both endpoints). Best-effort — never raises."""
    client_msg_id = (req.client_msg_id or "").strip()
    if client_msg_id:
        # A twin of this send (a cross-instance retry racing the shielded
        # original) may have finalized already — don't append the turn twice.
        try:
            if chat_history.reply_for_client_id(
                get_db(), ctx.uid, client_msg_id
            ) is not None:
                return
        except Exception:  # noqa: BLE001
            pass
    try:
        chat_history.append(
            get_db(), ctx.uid, "user", req.message,
            image_path=ctx.image_path or None,
            client_msg_id=client_msg_id or None,
        )
        chat_history.append(
            get_db(), ctx.uid, "ayma", reply_text, tools=tools_used,
            image_path=ctx.photo_edit_result.get("image_path") or None,
            # The durable token URL too: a generated image's ayma_generated/…
            # path is NOT client-resolvable (Storage rules only open
            # uploads/{uid}), so without the URL the image vanishes from the
            # transcript on reload (founder bug 2026-09-27).
            image_url=ctx.photo_edit_result.get("image_url") or None,
            # On the reply too, so a client reconciling a dropped connection
            # can find this send's finished reply by exact id.
            client_msg_id=client_msg_id or None,
        )
    except Exception:  # noqa: BLE001
        logger.exception("chat_history append failed for %s", ctx.uid)
    else:
        background.add_task(
            notifications_triggers.notify_ayma_reply,
            get_db(), ctx.uid, reply_text,
        )

    if req.session_id:
        user_text = req.message
        if ctx.image is not None:
            user_text = f"{req.message}\n[shared a photo]".strip()
        full_window = ctx.window + [
            Turn(ROLE_USER, user_text),
            Turn(ROLE_AYMA, reply_text),
        ]
        _persist_session(ctx.uid, req.session_id, full_window)
        # Phase 2 (cost program 2026-09-26): keep the rolling summary fresh in
        # the background. maybe_update_summary is itself threshold-gated (only
        # summarizes once ≥N new turns accumulated), so this is NOT an LLM
        # call per message — most turns it's a single user-doc read, and at
        # level < 2 it's skipped entirely.
        if context_opt.summary_enabled():
            background.add_task(
                context_opt.maybe_update_summary, get_db(), ctx.uid,
                full_window, session_id=req.session_id,
            )
        # No per-turn wiki ingest any more — it re-read the whole transcript +
        # every page after every message (§ cost review 2026-09-07). Ayma folds
        # things in herself via the `remember` tool, and `/post_turn` runs a
        # full pass at session end. A shared photo is the one exception worth
        # capturing right away, so its caption isn't lost.
        if ctx.image is not None:
            background.add_task(
                _run_chat_followups, ctx.uid, req.session_id, full_window,
                ctx.image_path,
            )


@app.post("/chat", dependencies=[Depends(require_not_underage_uid)])
async def chat(
    req: ChatRequest,
    caller: Caller = Depends(require_caller),
) -> dict[str, object]:
    """Text chat turn (§1.7 step 2, §1.5, §3.3). Non-streaming; the client
    prefers ``/chat/stream`` for live status, and falls back here.

    Idempotent per ``client_msg_id``: a retry of a send that already finished
    is answered from the persisted reply; one whose first attempt is still
    running joins that run. The turn itself executes in a shielded task
    (:func:`_spawn_turn`) so a client disconnect mid-request — app
    backgrounded, socket dropped — never aborts generation or persistence."""
    dup = await _persisted_turn_reply(caller.uid, req)
    if dup is not None:
        return dup
    key = _turn_key(caller.uid, req)
    joined = _INFLIGHT_TURNS.get(key) if key is not None else None
    if joined is not None:
        try:
            return dict(await asyncio.shield(joined))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - model/transport → 502
            raise HTTPException(
                status_code=502, detail=f"Gemini call failed: {exc}"
            ) from exc

    early, ctx = await _prepare_chat(req, caller)
    if early is not None:
        return early
    assert ctx is not None

    async def _turn() -> dict[str, object]:
        try:
            reply = await _generate_chat_reply(ctx, req)
        except token_ledger.TokenCapExceeded:
            return {
                "reply": _USAGE_CAPPED_REPLY,
                "capped": False,
                "fallback_form": False,
                "usage_capped": True,
            }
        finalize_bg = BackgroundTasks()
        _finalize_chat(finalize_bg, ctx, req, reply.text, reply.tools_used)
        _spawn_turn(finalize_bg())
        return {
            "reply": reply.text,
            "tools_used": reply.tools_used,
            "image_url": ctx.photo_edit_result.get("image_url", ""),
        }

    task = _spawn_turn(_turn(), key=key)
    try:
        # shield: cancelling THIS handler (client gone) must not cancel the
        # turn — it finishes, persists, and stays joinable/deduped by id.
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(
            status_code=502, detail=f"Gemini call failed: {exc}"
        ) from exc


async def _generate_chat_reply(ctx: _ChatCtx, req: ChatRequest):
    """The non-streaming Gemini call for one prepared turn."""
    return await gemini.generate_reply(
        req.message,
        system_prompt=ctx.system_prompt,
        tool_declarations=session_tool_declarations(
            story=bool(ctx.story_page_id),
            profile_edit=ctx.profile_edit,
            photo=bool(ctx.photo_url or ctx.image),
            deep_dive=bool(ctx.deep_dive_report_id and ctx.deep_dive_target),
            appearance=bool(ctx.appearance_finding_id),
        ),
        tool_fns=make_session_tool_fns(
            get_db(),
            ctx.uid,
            session_ctx={
                "session_id": req.session_id,
                "turn_index": len(ctx.window),
                "turns": ctx.window + [Turn(ROLE_USER, req.message)],
            },
            story_ctx=(
                {
                    "page_id": ctx.story_page_id,
                    "passage": ctx.story_passage,
                    "timeline_entry_id": ctx.story_timeline_entry_id,
                }
                if ctx.story_page_id
                else None
            ),
            profile_edit=ctx.profile_edit,
            photo_ctx=(
                {
                    "url": ctx.photo_url,
                    "source": ctx.photo_source,
                    "image": ctx.image or ctx.photo_image,
                    "result": ctx.photo_edit_result,
                }
                if ctx.photo_url or ctx.image
                else None
            ),
            image_path=ctx.image_path,
            deep_dive_ctx=(
                {"report_id": ctx.deep_dive_report_id, "target": ctx.deep_dive_target}
                if ctx.deep_dive_report_id and ctx.deep_dive_target else None
            ),
            appearance_ctx=(
                {"finding_id": ctx.appearance_finding_id}
                if ctx.appearance_finding_id else None
            ),
            # generate_image delivers through the same sink edit_photo
            # uses, so the reply's image_url / transcript attach below
            # work unchanged for a generated image.
            image_result=ctx.photo_edit_result,
        ),
        image=ctx.image or ctx.photo_image,
        uid=ctx.uid,
        feature=token_ledger.FEATURE_CHAT,
        session_id=req.session_id,
    )


def _sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"


_SSE_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}

# Whole-turn ceiling for /chat/stream and the idle gap after which the relay
# emits an SSE comment so the client can tell a slow turn from a dead socket.
# Module-level so tests can shrink them.
_CHAT_TURN_TIMEOUT_SECONDS = 200.0
_SSE_KEEPALIVE_SECONDS = 15.0
_CHAT_TIMEOUT_DETAIL = "Ayma took too long to answer. Please try again."


def _sse_response(gen) -> StreamingResponse:
    return StreamingResponse(
        gen, media_type="text/event-stream", headers=_SSE_HEADERS
    )


async def _sse_once(ev: dict):
    yield _sse(ev)


def _reply_event(result: dict) -> dict:
    """A /chat-shaped response dict as the single SSE reply event a
    duplicate/joined ``/chat/stream`` request emits."""
    ev = {
        "type": "reply",
        "text": result.get("reply", ""),
        "tools_used": result.get("tools_used") or [],
        "image_url": result.get("image_url", ""),
        "duplicate": True,
    }
    if result.get("usage_capped"):
        ev["usage_capped"] = True
    return ev


@app.post("/chat/stream", dependencies=[Depends(require_not_underage_uid)])
async def chat_stream(
    req: ChatRequest,
    caller: Caller = Depends(require_caller),
):
    """Text chat turn as Server-Sent Events: ``{"type":"status","label":"…"}``
    while a tool runs (so the client can show *"Searching the web…"* live),
    then one ``{"type":"reply","text":…,"tools_used":[…]}``. Same persistence
    as ``/chat`` once the reply lands.

    Disconnection-proof: starlette cancels a StreamingResponse's generator
    the moment the client socket drops (verified — backgrounding the app
    mid-send did exactly that), so the generate→moderate→persist pipeline
    runs in its own :func:`_spawn_turn` task and only the SSE *relay* reads
    from it. A dead client kills the relay; the turn still finishes, the
    reply + image land in chat history, and the ledger stays consistent.
    Idempotent per ``client_msg_id`` exactly like ``/chat``."""
    dup = await _persisted_turn_reply(caller.uid, req)
    if dup is not None:
        return _sse_response(_sse_once(_reply_event(dup)))
    key = _turn_key(caller.uid, req)
    joined = _INFLIGHT_TURNS.get(key) if key is not None else None
    if joined is not None:

        async def _joined_gen():
            try:
                result = dict(await asyncio.shield(joined))
            except Exception as exc:  # noqa: BLE001
                yield _sse({"type": "error", "detail": str(exc)})
                return
            yield _sse(_reply_event(result))

        return _sse_response(_joined_gen())

    early, ctx = await _prepare_chat(req, caller)
    if early is not None:
        return _sse_response(_sse_once({"type": "reply", **early}))
    assert ctx is not None

    # The turn task hands events to the response through this queue —
    # unbounded, so a gone client can never make the turn block on a put.
    queue: asyncio.Queue[dict | None] = asyncio.Queue()

    async def _turn() -> dict[str, object]:
        reply_text = ""
        tools_used: list[str] = []
        result: dict[str, object] = {}
        try:
            try:
                async with asyncio.timeout(_CHAT_TURN_TIMEOUT_SECONDS):
                    async for ev in gemini.generate_reply_events(
                        req.message,
                        system_prompt=ctx.system_prompt,
                        tool_declarations=session_tool_declarations(
                            story=bool(ctx.story_page_id),
                            profile_edit=ctx.profile_edit,
                            photo=bool(ctx.photo_url or ctx.image),
                            deep_dive=bool(ctx.deep_dive_report_id and ctx.deep_dive_target),
                            appearance=bool(ctx.appearance_finding_id),
                        ),
                        tool_fns=make_session_tool_fns(
                            get_db(),
                            ctx.uid,
                            session_ctx={
                                "session_id": req.session_id,
                                "turn_index": len(ctx.window),
                                "turns": ctx.window + [Turn(ROLE_USER, req.message)],
                            },
                            story_ctx=(
                                {
                                    "page_id": ctx.story_page_id,
                                    "passage": ctx.story_passage,
                                    "timeline_entry_id": ctx.story_timeline_entry_id,
                                }
                                if ctx.story_page_id
                                else None
                            ),
                            profile_edit=ctx.profile_edit,
                            photo_ctx=(
                                {
                                    "url": ctx.photo_url,
                                    "source": ctx.photo_source,
                                    "image": ctx.image or ctx.photo_image,
                                    "result": ctx.photo_edit_result,
                                }
                                if ctx.photo_url or ctx.image
                                else None
                            ),
                            image_path=ctx.image_path,
                            deep_dive_ctx=(
                                {"report_id": ctx.deep_dive_report_id, "target": ctx.deep_dive_target}
                                if ctx.deep_dive_report_id and ctx.deep_dive_target else None
                            ),
                            appearance_ctx=(
                                {"finding_id": ctx.appearance_finding_id}
                                if ctx.appearance_finding_id else None
                            ),
                            image_result=ctx.photo_edit_result,
                        ),
                            image=ctx.image or ctx.photo_image,
                            uid=ctx.uid,
                            feature=token_ledger.FEATURE_CHAT,
                            session_id=req.session_id,
                    ):
                        if ev.get("type") == "reply":
                            reply_text = ev["text"]
                            tools_used = ev["tools_used"]
                            ev = {
                                **ev,
                                "image_url": ctx.photo_edit_result.get(
                                    "image_url", ""
                                ),
                            }
                            result = {
                                "reply": reply_text,
                                "tools_used": tools_used,
                                "image_url": ev["image_url"],
                            }
                        queue.put_nowait(ev)
            except token_ledger.TokenCapExceeded:
                queue.put_nowait({
                    "type": "reply", "text": _USAGE_CAPPED_REPLY,
                    "tools_used": [], "usage_capped": True,
                })
                return {
                    "reply": _USAGE_CAPPED_REPLY, "tools_used": [],
                    "image_url": "", "usage_capped": True,
                }
            except TimeoutError:
                logger.error("chat stream timed out for %s", ctx.uid)
                queue.put_nowait(
                    {"type": "error", "detail": _CHAT_TIMEOUT_DETAIL}
                )
                raise
            except Exception as exc:  # noqa: BLE001
                logger.exception("chat stream failed for %s", ctx.uid)
                queue.put_nowait({"type": "error", "detail": str(exc)})
                raise
            if reply_text:
                finalize_bg = BackgroundTasks()
                _finalize_chat(finalize_bg, ctx, req, reply_text, tools_used)
                _spawn_turn(finalize_bg())
            return result
        finally:
            queue.put_nowait(None)  # end-of-stream for the relay

    _spawn_turn(_turn(), key=key)

    async def _relay():
        while True:
            try:
                ev = await asyncio.wait_for(
                    queue.get(), timeout=_SSE_KEEPALIVE_SECONDS
                )
            except TimeoutError:
                yield ": keepalive\n\n"
                continue
            if ev is None:
                return
            yield _sse(ev)

    return _sse_response(_relay())


async def _run_chat_followups(
    uid: str, session_id: str, turns: list[Turn], image_path: str
) -> None:
    """After the reply is sent: caption any attached photo so wiki ingest can
    remember what was in it, then run the normal ingest (§2.2, §2.3).

    A chat image is now also run through the §8.5 media pipeline (``/media``,
    ``context="chat"``) by the client, best-effort and possibly still in
    flight — so its ``user_media`` record (with the already-computed
    attributes / embedding) may or may not exist yet by the time this runs.
    When it does, this reuses it for the same "of user / other / group"
    phrasing every other photo caption gets (:func:`photo_pipeline.
    caption_turn_text`); when it doesn't, this falls back to a plain caption,
    same as before that pipeline existed.
    """
    enriched = turns
    if image_path:
        try:
            import photo_notes
            import photo_pipeline

            img_bytes, mime = await asyncio.to_thread(
                media_embed.download_bytes, image_path
            )
            caption = (await photo_pipeline._caption(img_bytes, mime, uid=uid)).strip()
            if caption:
                shot_type, match = "", ""
                try:
                    media_id = await asyncio.to_thread(
                        photo_notes._media_id_for_path, get_db(), uid, image_path
                    )
                    record = (
                        await asyncio.to_thread(_media_record, uid, media_id)
                        if media_id else {}
                    )
                    attrs = record.get("attributes") or {}
                    shot_type = str(attrs.get("shot_type", "") or "")
                    embedding = photo_notes._vec(record.get("embedding"))
                    if shot_type != "group" and embedding:
                        refs = await asyncio.to_thread(
                            deep_dive_images.reference_embeddings_for,
                            get_db(), uid,
                        )
                        match = deep_dive_images.classify_face_match(
                            embedding, refs
                        )
                except Exception:  # noqa: BLE001
                    shot_type, match = "", ""
                note = photo_pipeline.caption_turn_text(
                    caption, shot_type=shot_type, match=match
                )
                enriched = turns + [Turn(ROLE_USER, note)]
        except Exception:  # noqa: BLE001
            logger.exception("chat photo caption failed for %s", uid)
    await _run_ingest(uid, session_id, enriched)


class PostTurnRequest(BaseModel):
    session_id: str = Field(max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )


@app.post("/post-turn")
async def post_turn(
    req: PostTurnRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Session-end persistence of the raw turn window (§1.7 step 8) + wiki
    ingest (§2.3, Step 21).

    The client calls this when a chat screen closes / a voice session ends;
    ``/chat`` also persists and ingests inline per turn.
    """
    turns = _to_turns(req.recent_turns)
    _persist_session(uid, req.session_id, turns)
    if turns:
        background.add_task(_run_ingest, uid, req.session_id, turns)
        # Cheap per-user nudge: fill in at most one missing profile-building
        # skill (cheapest first) so an active user's wiki populates without
        # waiting for `POST /cron/skill-backfill`.
        background.add_task(skill_runs.reconcile, get_db(), uid, user_limit=1)
        # Refresh the questionnaire completeness score once the wiki ingest
        # above has had a chance to land (debounced; recomputes the narrative
        # pass only if the wiki text actually changed).
        background.add_task(completeness.recompute, get_db(), uid)
        # Refresh Ayma's assessment (judgment) page on the same session-end
        # cadence — gated inside on new material (wiki/DM fingerprint +
        # watermark + debounce), so an unchanged user costs no LLM call.
        background.add_task(ai_assessment.maybe_refresh, get_db(), uid)
    return {"ok": True, "persisted": len(turns)}


@app.get("/chat/history")
async def chat_history_page(
    before: str = "",
    limit: int = 40,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The durable Ayma-tab transcript (§2.2), newest page first-loaded.

    Returns up to ``limit`` messages older than ``before`` (an ISO-8601
    timestamp from a prior ``next_before``), oldest-first, plus the cursor for
    the next older page.
    """
    cursor: datetime | None = None
    if before.strip():
        try:
            cursor = datetime.fromisoformat(before.strip())
        except ValueError:
            raise HTTPException(  # noqa: B904
                status_code=422, detail="`before` must be ISO-8601."
            )
    return await asyncio.to_thread(
        chat_history.recent, get_db(), uid, before=cursor, limit=limit
    )


class VoiceContextRequest(BaseModel):
    """What the user is looking at, mirrored while a voice call is live (§5.6).
    An empty ``screen`` clears the mirror (call ended / app backgrounded)."""

    screen: str = Field(default="", max_length=40)
    subject_uid: str = Field(default="", max_length=128)
    subject_name: str = Field(default="", max_length=120)
    note: str = Field(default="", max_length=200)
    # What the screen is showing (e.g. Explore's visible people), capped.
    detail: str = Field(default="", max_length=1500)
    # The route pattern and the generic live capture (text + controls).
    route: str = Field(default="", max_length=200)
    visible: str = Field(default="", max_length=3200)


def _voice_context_doc(uid: str):
    return (
        get_db()
        .collection("users")
        .document(uid)
        .collection("voice_context")
        .document("current")
    )


@app.post("/voice/context")
async def set_voice_context(
    req: VoiceContextRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The LiveKit agent's ``current_screen`` tool reads this so Ayma knows
    what "them / this / here" means in a call. The client posts it on every
    screen change while a session is live, and clears it when the call ends."""
    if not (req.screen.strip() or req.route.strip()):
        await asyncio.to_thread(_voice_context_doc(uid).delete)
        return {"ok": True, "cleared": True}
    await asyncio.to_thread(
        _voice_context_doc(uid).set,
        {
            "screen": req.screen.strip(),
            "subject_uid": req.subject_uid.strip(),
            "subject_name": req.subject_name.strip(),
            "note": req.note.strip(),
            "detail": req.detail.strip(),
            "route": req.route.strip(),
            "visible": req.visible.strip(),
            "updated_at": _server_ts(),
        },
    )
    return {"ok": True}


@app.delete("/voice/context")
async def clear_voice_context(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    await asyncio.to_thread(_voice_context_doc(uid).delete)
    return {"ok": True, "cleared": True}


class MediaRequest(BaseModel):
    storage_path: str = Field(min_length=1, max_length=500)
    context: Literal["profile", "chat", "dm"] = "profile"
    # Whatever the user typed alongside this photo (a chat message sent with
    # it) — optional, empty for a profile-grid upload (nothing is "said" when
    # adding one). Folded into the caption composer (§ photo_pipeline).
    caption_context: str = Field(default="", max_length=2000)


@app.post("/media")
async def register_media(
    req: MediaRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Embed an uploaded photo and record it on ``user_media`` (§2.5, §2.8
    step 7). The client uploads the file to ``uploads/{uid}/…`` first, then
    calls this. The unified ``/media/upload`` entry + full §8.5 pipeline is
    Phase 10.
    """
    prefix = f"uploads/{uid}/"
    if not req.storage_path.startswith(prefix):
        raise HTTPException(
            status_code=403,
            detail="storage_path must be under the caller's uploads/ tree.",
        )
    import photo_pipeline

    try:
        result = await photo_pipeline.process(
            get_db(),
            uid,
            req.storage_path,
            req.context,
            wiki_uids=[uid] if req.context in ("profile", "chat") else None,
            accompanying_text=req.caption_context,
        )
    except Exception as exc:  # noqa: BLE001 - surface embed/storage failure
        raise HTTPException(
            status_code=502, detail=f"Media pipeline failed: {exc}"
        ) from exc

    if req.context == "profile":
        # A profile-grid photo isn't "added" yet at this point — it only
        # becomes visible via POST /media/photos or /media/photos/batch,
        # which run the batched Appearance pipeline
        # (appearance.run_batch_photos) themselves. Triggering analysis here
        # too used to double-analyse every profile upload (register + grid
        # add) — one of the causes of the old "7+ history entries from 4
        # photos" bug (§ appearance report v2).
        pass
    else:
        # A chat/DM attachment never goes through the grid — this is its
        # only analysis trigger, so keep it here. Auto-analysis (§ auto
        # analysis): the user's own photo -> face/body read into their
        # private `ai_only` memory, in the background. Reuses the
        # embedding/attributes the pipeline just computed rather than
        # re-deriving them, and is gated by them (group shot / face-match /
        # usable flags).
        background.add_task(
            auto_analysis.analyse_photo, get_db(), uid, req.storage_path,
            embedding=result.get("embedding"), attributes=result.get("attributes"),
        )

    return {
        "ok": True,
        "media_id": result["media_id"],
        "moderation_status": result["moderation_status"],
        "published": result["published"],
        "reason": result["reason"],
        "photo_attrs": result["attributes"],
    }


@app.get("/verification/status")
async def verification_status(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Whether the caller has a stored verification selfie yet — backs the
    "Verify your face" action / unverified badge in Settings."""
    try:
        snap = await asyncio.to_thread(
            get_db().collection("users").document(uid).get
        )
        data = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        logger.exception("verification status read failed for %s", uid)
        data = {}
    verified = bool((data.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
        schema.FACE_VERIFICATION_EMBEDDING
    ))
    return {"verified": verified}


class VerificationSelfieRequest(BaseModel):
    storage_path: str = Field(min_length=1, max_length=500)


@app.post("/verification/selfie")
async def verification_selfie(
    req: VerificationSelfieRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Pre-boarding / settings verification selfie (§ face verification): a
    single front-camera photo, captured for verification only — never a grid
    / gallery / Explore photo, and deliberately not a ``user_media`` doc.

    Moderated exactly like any other upload (a rejection here is no
    exception), then embedded and stored on ``users/{uid}.face_verification``
    — the account's most authoritative face-match reference from here on
    (:func:`deep_dive_images.reference_embeddings_for`). Also seeds the
    user's initial Appearance read the same way any other qualifying photo
    would, via :func:`auto_analysis.analyse_photo`'s normal gating.
    """
    prefix = f"verification/{uid}/"
    if not req.storage_path.startswith(prefix):
        raise HTTPException(
            status_code=403,
            detail="storage_path must be under the caller's verification/ tree.",
        )
    if not await asyncio.to_thread(biometric_consent.has_consent, get_db(), uid):
        raise _consent_required_error()
    try:
        image, mime = await asyncio.to_thread(
            media_embed.download_bytes, req.storage_path
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Could not read the selfie: {exc}"
        ) from exc

    import photo_moderation

    verdict = await photo_moderation.moderate(image, mime, uid=uid)
    if not verdict["allowed"]:
        return {
            "ok": True,
            "verified": False,
            "moderation_status": schema.MEDIA_STATUS_FLAGGED,
            "reason": verdict["reason"],
        }

    embedding = await asyncio.to_thread(
        media_embed.embed_image_bytes, image, mime
    )
    attributes = await photo_attrs.extract_attributes(image, mime, uid=uid)

    from google.cloud.firestore_v1.vector import Vector

    payload = {
        schema.FIELD_FACE_VERIFICATION: {
            schema.FACE_VERIFICATION_EMBEDDING: Vector(embedding),
            schema.FACE_VERIFICATION_STORAGE_PATH: req.storage_path,
            schema.FACE_VERIFICATION_VERIFIED_AT: _server_ts(),
        },
    }
    await asyncio.to_thread(
        lambda: get_db().collection("users").document(uid).set(
            payload, merge=True
        )
    )

    # Seed the initial Appearance read the normal way — gated exactly like
    # any other photo (group shot / face-match / usable-for-face-or-body).
    background.add_task(
        auto_analysis.analyse_photo, get_db(), uid, req.storage_path,
        embedding=embedding, attributes=attributes,
    )

    return {
        "ok": True,
        "verified": True,
        "moderation_status": schema.MEDIA_STATUS_APPROVED,
        "reason": "",
    }


@app.post("/account/delete")
async def account_delete(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Soft-delete: quarantine the account into ``deleted_accounts/{uid}`` and
    remove the live copies (§3.6). The Auth account is left intact so the user
    can sign back in and recover within the window."""
    try:
        result = await asyncio.to_thread(
            account_ops.soft_delete, get_db(), _bucket(), uid
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Account delete failed: {exc}"
        ) from exc
    return {"ok": True, **result}


@app.post("/account/recover")
async def account_recover(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Restore a soft-deleted account from its quarantine (§3.6)."""
    if not _recovery_required(uid):
        raise HTTPException(
            status_code=409, detail="Nothing to recover for this account."
        )
    try:
        result = await asyncio.to_thread(
            account_ops.recover, get_db(), _bucket(), uid
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Account recovery failed: {exc}"
        ) from exc
    if result.get("reason") == age_gate.CLOSED_REASON_UNDERAGE:
        raise HTTPException(
            status_code=403,
            detail={"code": age_gate.STATUS_UNDERAGE,
                    "message": age_gate.UNDERAGE_MESSAGE},
        )
    return {"ok": True, **result}


class BiometricConsentRequest(BaseModel):
    agreed: bool
    consent_version: str = Field(min_length=1, max_length=40)
    region: str = Field(default="", max_length=8)


@app.get("/biometric-consent")
async def biometric_consent_status(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The caller's face-matching consent state (consent screen, Settings)."""
    try:
        return await asyncio.to_thread(biometric_consent.status, get_db(), uid)
    except Exception as exc:  # noqa: BLE001
        logger.exception("biometric consent status read failed for %s", uid)
        raise HTTPException(
            status_code=502, detail="Could not read your consent."
        ) from exc


@app.post("/biometric-consent")
async def biometric_consent_accept(
    req: BiometricConsentRequest, uid: str = Depends(require_not_underage_uid)
) -> dict[str, object]:
    """Record the explicit "I agree" from the consent screen. Validates that
    the person agreed to the current consent version; 400 otherwise. A
    soft-deleted account must be recovered first (409): writing the record
    would recreate the live ``users/{uid}`` doc."""
    if await asyncio.to_thread(_recovery_required, uid):
        raise HTTPException(
            status_code=409, detail="Recover your account first."
        )
    try:
        result = await asyncio.to_thread(
            biometric_consent.record, get_db(), uid,
            agreed=req.agreed, version=req.consent_version, region=req.region,
        )
    except biometric_consent.ConsentError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("biometric consent write failed for %s", uid)
        raise HTTPException(
            status_code=502, detail="Could not save your consent."
        ) from exc
    return {"ok": True, **result}


@app.post("/biometric-consent/withdraw")
async def biometric_consent_withdraw(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Withdraw the consent: deletes all face data now and deletes the
    account (consent is required to use Ayma)."""
    try:
        result = await asyncio.to_thread(
            biometric_consent.withdraw, get_db(), _bucket(), uid
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("biometric consent withdrawal failed for %s", uid)
        raise HTTPException(
            status_code=502, detail="Could not withdraw your consent."
        ) from exc
    return {"ok": True, **result}


class AgeDeclaration(BaseModel):
    birthdate: str = Field(max_length=40)


@app.post("/age-gate/declare")
async def age_gate_declare(
    req: AgeDeclaration, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The client reports the birthdate the person just entered. The server
    judges it (never trusting a client verdict); a birthdate under 18 closes
    the account (privacy policy "Children"). Writes no birthdate."""
    bd = age_gate.to_date(req.birthdate)
    if bd is None:
        raise HTTPException(status_code=400, detail="Invalid birthdate.")
    if age_gate.age_on(bd, age_gate.today_utc()) >= age_gate.MIN_AGE_YEARS:
        return {"ok": True, "adult": True}
    try:
        await asyncio.to_thread(
            age_gate.close_underage, get_db(), _bucket(), uid,
            source="client_declared",
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Could not close account: {exc}"
        ) from exc
    return {"ok": True, "adult": False}


@app.get("/explore")
async def explore(
    q: str = "",
    location: str = "",
    hair_color: str = "",
    glasses: str = "",
    age_min: int | None = None,
    age_max: int | None = None,
    limit: int = 30,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """Live Explore feed (§6.1). ``q`` is parsed once into the filter schema;
    dropdown params override it."""
    try:
        nl = await explore_mod.parse_nl_query(q, uid=uid) if q.strip() else {}
    except Exception:  # noqa: BLE001 - a bad NL parse falls back to no filter
        logger.warning("explore: NL parse failed for %r", q, exc_info=True)
        nl = {}
    dropdown = {
        "location": location,
        "hair_color": hair_color,
        "glasses": glasses,
        "age_min": age_min,
        "age_max": age_max,
    }
    filters = explore_mod.merge_filters(dropdown, nl)
    try:
        snap = await asyncio.to_thread(schema.profile_doc(get_db(), uid).get)
        filters = explore_mod.apply_saved_age_range(
            filters, snap.to_dict() if snap.exists else None
        )
    except Exception:  # noqa: BLE001 - no saved range just means no default
        logger.warning("explore: saved age range read failed", exc_info=True)
    try:
        cards = await asyncio.to_thread(
            explore_mod.explore, get_db(), uid, filters, min(limit, 60)
        )
    except Exception:  # noqa: BLE001 - Explore must render even if the feed errors
        logger.exception("explore: feed build failed for %s", uid)
        cards = []
    return {"cards": cards, "filters_applied": filters}


@app.get("/explore/profile/{other_uid}")
async def explore_profile(
    other_uid: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Another user's public profile — the Explore card tap-through: public
    wiki narrative, visible photos, plus the caller-relative score / like
    state and the DM thread id."""
    view = await asyncio.to_thread(
        public_profile_mod.build, get_db(), uid, other_uid.strip()
    )
    if view is None:
        raise HTTPException(status_code=404, detail="No such profile.")
    return view


class DeepDiveRequest(BaseModel):
    # Empty / own uid -> research yourself; another uid -> that person. `name`
    # overrides the name we'd otherwise read from their profile.
    target_uid: str = Field(default="", max_length=128)
    name: str = Field(default="", max_length=120)
    context: str = Field(default="", max_length=600)
    # Skip the ≤2-month cache and force a fresh web search.
    force: bool = False


def _profile_full_name(uid: str) -> str:
    """The subject's research name — ``"{first_name} {last_name}"`` when the
    profile has both, else the plain ``name`` field."""
    return deep_dive.profile_full_name(get_db(), uid)


def _deep_dive_label(is_self: bool, name: str) -> str:
    return "Researched yourself online" if is_self else f"Researched {name} online"


def _deep_dive_subject_image(is_self: bool, target: str) -> str:
    if is_self or not target:
        return ""
    return story._photo_url_safe(_primary_profile_photo_path(target)) or ""


async def _finish_deep_dive(
    uid: str, digest: dict, *, is_self: bool, target: str, name: str, notify: bool
) -> dict:
    """Shared tail for a deep dive (cache hit or fresh): persist, drop Ayma's
    summary into the transcript, optionally push, and shape the response."""
    # Only a lookup on *yourself* belongs in your wiki / Your Story. Research on
    # someone you're meeting is a private note for the chat + the reuse cache,
    # never your own story.
    if is_self:
        skill_memory.save_web_findings(get_db(), uid, digest)
        skill_memory.promote(get_db(), uid, "web_findings")
        skill_runs.record(
            get_db(), uid, skill_runs.DEEP_DIVE,
            status=skill_runs.STATUS_OK, source="user", detail="self",
        )
        # Best-effort: re-derive the structured career timeline now that fresh
        # web-research facts (possibly LinkedIn-derived — § career timeline)
        # are on hand. Never blocks/fails the deep-dive response itself.
        try:
            await career_timeline.extract(get_db(), uid)
        except Exception:  # noqa: BLE001
            logger.exception("career-timeline extraction after self-dive failed for %s", uid)
    else:
        # The person researched is NOT the account holder, so none of the
        # digest belongs in the user's wiki. Drop a single behavioural
        # breadcrumb into the `interactions` page — the next wiki ingest folds
        # it (and any preference it reveals) into `interactions` / other pages.
        try:
            skill_memory.note_interaction(
                get_db(), uid, f"ran a deep dive on {name}",
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive interaction breadcrumb failed for %s", uid)
    # A short teaser + the `[deep_dive:<id>]` sentinel below — never the
    # full summary/facts/links/photos dumped into the chat line itself
    # (§ founder: keep report-result chat messages to a teaser + link; the
    # findings live in the report screen).
    summary = deep_dive.teaser(digest)
    subject_image = _deep_dive_subject_image(is_self, target)
    label = _deep_dive_label(is_self, name)

    # A dive that actually found something is a re-openable report: tag the turn
    # with a `[deep_dive:<id>]` marker (same id as the deep_dives doc) so the
    # chat can show a "View research" card, on reload too.
    report_id = ""
    if digest.get("confidence") != "not_found" and (
        digest.get("facts") or digest.get("summary")
    ):
        report_id = deep_dive.dive_report_id(
            "" if is_self else target, name
        )
    chat_text = f"{summary}\n\n[deep_dive:{report_id}]" if report_id else summary
    try:
        chat_history.append(
            get_db(), uid, "ayma", chat_text,
            tools=[label], subject_image=subject_image or None,
        )
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive chat_history append failed for %s", uid)
    if notify:
        who = "yourself" if is_self else name
        # Point the push at the re-openable report when the dive produced one;
        # a "not found" dive has no report_id, so fall back to chat (that's
        # where the "nothing found" summary actually lives).
        deep_link = f"deep_dive/{report_id}" if report_id else "chat"
        await notifications_triggers.notify_skill_done(
            get_db(), uid, f"Your web search on {who} is ready.", deep_link,
        )
    return {
        "digest": digest,
        "summary": summary,
        "report_id": report_id,
        "is_self": is_self,
        "subject_image": subject_image,
        "tool_label": label,
    }


async def _deep_dive_job(
    uid: str, name: str, context: str, is_self: bool, target: str, force: bool
) -> None:
    """The slow part of a deep dive, run as a background task so it finishes
    even if the app is backgrounded or closed. Delivers via a push + the chat
    transcript. Never raises.

    Always finishes the run doc the endpoint opened (``done`` once the digest
    is stored, ``failed`` otherwise) so the app's "Searching the web…" state
    ends; a job killed before its ``finally`` is caught by the stale-run
    timeout in :func:`deep_dive.run_status`."""
    report_id = deep_dive.dive_report_id("" if is_self else target, name)
    status = deep_dive.RUN_FAILED
    try:
        try:
            digest = await deep_dive.run(
                name, db=get_db(), uid=uid, context=context,
                is_self=is_self, target_uid="" if is_self else target, force=force,
            )
        except token_ledger.TokenCapExceeded:
            logger.info("deep-dive job skipped for %s (credit cap)", uid)
            return
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive job failed for %s", uid)
            return
        status = deep_dive.RUN_DONE
        try:
            await _finish_deep_dive(
                uid, digest, is_self=is_self, target=target, name=name, notify=True,
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive job delivery failed for %s", uid)
    finally:
        await asyncio.to_thread(deep_dive.mark_run, get_db(), uid, report_id, status)


@app.post("/deep-dive")
async def deep_dive_endpoint(
    req: DeepDiveRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Consented web deep-dive on a named person (§ deep dive).

    A cached dive (≤2 months) comes back inline — but only for a dive on
    *someone else*. Researching yourself always runs fresh: the cache exists
    so other people looking you up (and the "View research" report) don't
    re-trigger a search, not so your own re-run goes stale. A fresh dive
    overwrites that same cache doc, so both stay current afterward. Runs as a
    background job — it finishes server-side even if the app is closed, and
    the result lands in the chat transcript with a push when it's done.
    """
    target = (req.target_uid or "").strip()
    is_self = not target or target == uid
    name = req.name.strip() or _profile_full_name(uid if is_self else target)
    if not name:
        raise HTTPException(
            status_code=400,
            detail="No name to search — set it on the profile first.",
        )
    context = req.context.strip() or (
        "" if is_self else "Someone the user is considering a date with."
    )
    if is_self:
        extra = deep_dive.profile_dive_context(get_db(), uid, name)
        if extra:
            context = f"{context} {extra}".strip()

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    cached = (
        None
        if req.force or is_self
        else deep_dive.reusable_report(
            get_db(), uid,
            target_uid="" if is_self else target, name=name, is_self=is_self,
        )
    )
    if cached is not None:
        cached["is_self"] = is_self
        return await _finish_deep_dive(
            uid, cached, is_self=is_self, target=target, name=name, notify=False,
        )

    report_id = deep_dive.dive_report_id("" if is_self else target, name)
    await asyncio.to_thread(
        deep_dive.mark_run, get_db(), uid, report_id, deep_dive.RUN_RUNNING,
    )
    background.add_task(
        _deep_dive_job, uid, name, context, is_self, target, req.force,
    )
    return {
        "queued": True,
        "report_id": report_id,
        "is_self": is_self,
        "subject_image": _deep_dive_subject_image(is_self, target),
        "tool_label": _deep_dive_label(is_self, name),
    }


@app.get("/deep-dive-report/{report_id}")
async def deep_dive_report(
    report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored deep dive by id — from a chat ``[deep_dive:<id>]``
    marker or the "View research" button on a profile. 404 when the caller has
    no such dive. ``run_status`` is the caller's latest queued run on this
    report (``running`` / ``done`` / ``failed`` / ``""`` — see
    :func:`deep_dive.run_status`); the app shows its in-progress banner only
    while it is ``running``.

    A ``uid_<subject>``-shaped id (a dive on a known app user) is
    self-describing and lives under that PERSON's own collection, not the
    caller's — it's their persistent report, shared by everyone who's
    searched them (§ persistent web-search report). When it is, this also
    prefers that person's own live self-dive (freshest — includes any
    correction they've made since) over whatever was last mirrored here."""
    report_id = report_id.strip()
    self_describing = report_id.startswith("uid_") and len(report_id) > len("uid_")

    def _read() -> dict | None:
        db = get_db()
        owner = deep_dive.report_owner(report_id, uid)
        data = deep_dive.read_dive(db, owner, report_id)
        if data is None and owner != uid:
            # Backward compat: a dive on someone else minted before this fix
            # was stored under the SEARCHER's own collection, not the
            # subject's — so a marker from before still opens.
            data = deep_dive.read_dive(db, uid, report_id)
            owner = uid if data is not None else owner
        if data is not None and owner != uid:
            name = str(data.get("name") or (data.get("digest") or {}).get("name") or "")
            if name:
                fresher = deep_dive.read_dive(db, owner, deep_dive.dive_report_id(name=name))
                if fresher is not None:
                    data = fresher
        return data

    data = await asyncio.to_thread(_read)
    if data is None:
        raise HTTPException(status_code=404, detail="No such report.")
    run = await asyncio.to_thread(deep_dive.run_status, get_db(), uid, report_id)
    digest = data.get("digest") or {}
    # A self-describing id's subject is the uid embedded in it (it may have
    # been swapped above for that subject's own, differently-keyed, self-dive
    # doc — whose own `target_uid` field is empty, since it's stored as if it
    # were their own dive). A plain (name-keyed) id's subject is whatever the
    # doc itself says — always "" for a genuine self dive.
    target = (
        deep_dive.report_owner(report_id, uid)
        if self_describing
        else str(data.get("target_uid") or "")
    )
    created = data.get("created_at")
    return {
        "digest": digest,
        "name": str(data.get("name") or digest.get("name") or ""),
        "target_uid": target,
        "is_self": target == uid if self_describing else not target,
        "subject_image": (
            _deep_dive_subject_image(False, target) if target else ""
        ),
        "created_at": (
            created.isoformat() if hasattr(created, "isoformat") else None
        ),
        "run_status": run,
    }


@app.get("/deep-dive/mine")
async def deep_dive_mine(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's own current self-dive, if any — backs the one-row history
    under the "Search the web about me" skill card.

    A self dive is stored keyed by the caller's *name* (``target_uid=""``),
    never by uid — the same lookup ``_ai_view_photos`` uses for a self dive's
    web photos, after a bug there once looked it up by uid and silently found
    nothing. Mirrors that here rather than re-introducing it.

    ``{"exists": false}`` when the caller has no name on their profile yet, or
    has never run a self dive.
    """
    def _read() -> tuple[str, dict | None]:
        db = get_db()
        name = deep_dive.profile_full_name(db, uid)
        if not name:
            return "", None
        report_id = deep_dive.dive_report_id(name=name)
        return report_id, deep_dive.read_dive(db, uid, report_id)

    report_id, data = await asyncio.to_thread(_read)
    if data is None:
        return {"exists": False}
    digest = data.get("digest") or {}
    created = data.get("created_at")
    return {
        "exists": True,
        "report_id": report_id,
        "summary": str(digest.get("summary") or ""),
        "confidence": str(digest.get("confidence") or "not_found"),
        "created_at": (
            created.isoformat() if hasattr(created, "isoformat") else None
        ),
    }


@app.post("/deep-dive/{report_id}/facts/{fact_id}/dispute")
async def deep_dive_dispute_fact(
    report_id: str, fact_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Mark one fact on a stored dive report incorrect (§ deep dive corrections).

    Removes it from the persisted digest — the report shows it gone from now
    on, not just hidden client-side — and remembers it as the user's own
    correction so a later dive on the same subject doesn't just resurrect the
    same wrong claim (:func:`deep_dive.disputed_facts_context`). Self-dives
    only: 403 when the report is about someone else. 404 when there's no such
    report, or no such fact on it.
    """
    try:
        result = await asyncio.to_thread(
            deep_dive.dispute_fact,
            get_db(), uid, report_id.strip(), fact_id.strip(),
        )
    except PermissionError:
        raise HTTPException(
            status_code=403,
            detail="Only a report about yourself can be corrected this way.",
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("deep-dive dispute failed for %s/%s", uid, report_id)
        raise HTTPException(
            status_code=502, detail="Couldn't record that correction."
        ) from exc
    if result is None:
        raise HTTPException(status_code=404, detail="No such fact to dispute.")
    return {"ok": True, "digest": result["digest"]}


class DeepDiveCorrectionRequest(BaseModel):
    # "summary", or "fact:<fact_id>" — which item on the report the user
    # tapped before typing their feedback.
    target: str = Field(min_length=1, max_length=140)
    feedback: str = Field(min_length=1, max_length=1000)


@app.post("/deep-dive/{report_id}/correct")
async def deep_dive_correct(
    report_id: str,
    req: DeepDiveCorrectionRequest,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Free-text correction on one item of the caller's own "about me"
    web-search report (§ deep-dive corrections) — the same tap-a-claim-and-
    tell-Ayma-in-plain-language pattern as the Story editor's passage chat
    (``story.edit_section``), applied to a deep-dive finding instead of a
    wiki section.

    Gemini reads the targeted claim (or the summary) plus the free-text
    feedback and decides whether it means the item should be removed,
    revised, or just carries a caveat — the change lands on the persisted
    report immediately. Self-dives only: 403 for a report about someone
    else. 404 when there's no such report, or ``target`` names a fact that
    isn't on it.
    """
    try:
        result = await deep_dive.correct_finding(
            get_db(), uid, report_id.strip(),
            target=req.target.strip(), feedback=req.feedback,
        )
    except PermissionError:
        raise HTTPException(
            status_code=403,
            detail="Only a report about yourself can be corrected this way.",
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        logger.exception("deep-dive correction failed for %s/%s", uid, report_id)
        raise HTTPException(
            status_code=502, detail="Couldn't record that correction."
        ) from exc
    if result is None:
        raise HTTPException(status_code=404, detail="No such item to correct.")
    return {
        "ok": True,
        "reply": result["reply"],
        "action": result["action"],
        "digest": result["digest"],
    }


# --- POST/GET /web-search/photos/* (§ web photo search) --------------------


@app.get("/web-search/photos/candidates")
async def web_search_photo_candidates(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Pending reverse-image-search candidates awaiting the user's
    confirm/reject — the "is this you?" review queue (§ web photo search).
    Never anything already confirmed/rejected; those are done."""
    candidates = await asyncio.to_thread(
        reverse_image_search.list_candidates, get_db(), uid
    )
    return {"candidates": candidates}


class WebPhotoRescanRequest(BaseModel):
    # Empty -> re-scan the current primary profile photo (the "search my
    # photos again" skill action). Non-empty -> the specific photo(s) from a
    # newly added batch — see reverse_image_search.py's module docstring for
    # why this is presently a manually-callable placeholder for that hook.
    storage_paths: list[str] = Field(default_factory=list, max_length=20)


@app.post("/web-search/photos/rescan")
async def web_search_photo_rescan(
    background: BackgroundTasks,
    req: WebPhotoRescanRequest | None = Body(default=None),
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Run (or re-run) reverse-image search against one or more of the
    caller's own photos (§ web photo search). Always a background task —
    queued and returns immediately; results land as pending candidates for
    ``GET /web-search/photos/candidates``."""
    paths = [p.strip() for p in (req.storage_paths if req else []) if p.strip()]
    background.add_task(
        reverse_image_search.scan, get_db(), uid, storage_paths=paths or None
    )
    return {"queued": True}


@app.post("/web-search/photos/candidates/{candidate_id}/confirm")
async def web_search_photo_confirm(
    candidate_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The user confirms a staged candidate is really them — merges it into
    the persistent "about me" report's ``confirmed_photos``. 404 when there's
    no such (still-pending) candidate."""
    result = await asyncio.to_thread(
        reverse_image_search.confirm_candidate,
        get_db(), uid, candidate_id.strip(),
    )
    if result is None:
        raise HTTPException(status_code=404, detail="No such candidate.")
    return {"ok": True, "candidate": result}


@app.post("/web-search/photos/candidates/{candidate_id}/reject")
async def web_search_photo_reject(
    candidate_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The user says a staged candidate is NOT them — dismissed, never
    written to the report. 404 when there's no such candidate."""
    result = await asyncio.to_thread(
        reverse_image_search.reject_candidate,
        get_db(), uid, candidate_id.strip(),
    )
    if result is None:
        raise HTTPException(status_code=404, detail="No such candidate.")
    return {"ok": True, "candidate": result}


# --- POST /face-report + /body-report ------------------------------------


class FaceReportRequest(BaseModel):
    # A chat attachment (must be under uploads/{caller}/) takes precedence;
    # otherwise the primary profile photo of `target_uid` (empty -> self).
    attachment_path: str = Field(default="", max_length=256)
    target_uid: str = Field(default="", max_length=128)


# `/body-report` shares the request shape.
BodyReportRequest = FaceReportRequest


def _primary_profile_photo_path(uid: str) -> str:
    """The ``storage_path`` of ``uid``'s primary (lowest-order) profile
    photo, or ``""`` if they have none."""
    try:
        prof = schema.profile_doc(get_db(), uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        return ""
    entries = [
        p for p in (prof.get(schema.PF_PHOTOS) or []) if isinstance(p, dict)
    ]
    entries.sort(key=lambda p: p.get("order", 0))
    for e in entries:
        sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
        if sp:
            return sp
        mid = str(e.get("media_id") or "").strip()
        if not mid:
            continue
        try:
            media = (
                get_db()
                .collection("users")
                .document(uid)
                .collection("user_media")
                .document(mid)
                .get()
                .to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            media = {}
        sp = str(media.get("storage_path") or "").strip()
        if sp:
            return sp
    return ""


def _resolve_report_image(
    caller_uid: str, attachment_path: str, target_uid: str
) -> tuple[bytes, str, str]:
    """``(bytes, mime, storage_path)`` for a face/body report request. 403 for
    an attachment outside the caller's own upload space; 400 when no photo can
    be found. The storage path is kept so the stored report can embed the
    analysed image."""
    attachment_path = (attachment_path or "").strip()
    if attachment_path:
        if not attachment_path.startswith(f"uploads/{caller_uid}/"):
            raise HTTPException(
                status_code=403, detail="Not your attachment."
            )
        storage_path = attachment_path
    else:
        target = (target_uid or "").strip() or caller_uid
        storage_path = _primary_profile_photo_path(target)
        if not storage_path:
            raise HTTPException(
                status_code=400,
                detail="No photo to analyse — add a profile photo first.",
            )
    try:
        image_bytes, mime = media_embed.download_bytes(storage_path)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=400, detail=f"Couldn't read that photo: {exc}"
        ) from exc
    return image_bytes, mime, storage_path


async def _run_report_endpoint(
    engine, req: "FaceReportRequest", uid: str, pointer: str
) -> dict[str, object]:
    """Shared body for ``/face-report`` and ``/body-report``: resolve the
    photo, run ``engine.run``, store the report, drop an Ayma pointer into the
    transcript, and return ``{report, report_id}``."""
    image_bytes, mime, image_path = _resolve_report_image(
        uid, req.attachment_path, req.target_uid
    )
    try:
        report = await engine.run(
            image_bytes, mime, uid=uid, source_path=image_path
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Report failed: {exc}"
        ) from exc

    page_type = "face_analysis" if pointer == "face" else "body_analysis"
    if pointer == "face":
        skill_memory.save_face_analysis(get_db(), uid, report)
    else:
        skill_memory.save_body_analysis(get_db(), uid, report)

    # The explicit-ask path (§ auto analysis §4): a self report the user asked
    # for is promoted into their visible `private` wiki. A report on someone
    # else's photo is never promoted.
    target = (req.target_uid or "").strip()
    if (not target or target == uid) and report.get("usable", True):
        skill_memory.promote(get_db(), uid, page_type)

    report_id = ""
    try:
        ref = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{pointer}_reports")
            .add(
                {
                    "report": report,
                    "image_path": image_path,
                    "created_at": _server_ts(),
                }
            )
        )
        report_id = getattr(ref[1], "id", "") if isinstance(ref, tuple) else ""
    except Exception:  # noqa: BLE001
        logger.exception("%s-report store failed for %s", pointer, uid)

    # Stamp the skill-run ledger for a usable self report (a report on someone
    # else's photo is never a profile-building run; an unusable read writes no
    # doc, so the reconciler is still free to retry on the profile photo).
    if (not target or target == uid) and report.get("usable", True):
        skill_runs.record(
            get_db(), uid,
            skill_runs.FACE_REPORT if pointer == "face" else skill_runs.BODY_REPORT,
            status=skill_runs.STATUS_OK, source="user", detail="endpoint",
        )

    if report.get("usable", True):
        # A short teaser + the `[face_report:<id>]` / `[body_report:<id>]`
        # sentinel the client renders as a "View report" card — never the
        # score/verdict dumped into the chat line itself (§ founder: keep
        # report-result chat messages to a teaser + link).
        kind = "facial-beauty" if pointer == "face" else "physique"
        line = f"Here's your {kind} report."
        if report_id:
            line = f"{line}\n\n[{pointer}_report:{report_id}]"
        try:
            chat_history.append(get_db(), uid, "ayma", line)
        except Exception:  # noqa: BLE001
            logger.exception(
                "%s-report chat_history append failed for %s", pointer, uid
            )
    return {"report": report, "report_id": report_id}


@app.post("/face-report")
async def face_report_endpoint(
    req: FaceReportRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """An honest, data-driven facial-beauty report on a photo (§ face report).
    Runs on a chat attachment or the subject's primary profile photo; stores
    the report and drops an Ayma pointer into the transcript."""
    return await _run_report_endpoint(face_report, req, uid, "face")


@app.post("/body-report")
async def body_report_endpoint(
    req: BodyReportRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """An honest, data-driven physique report on a photo (§ body report).
    Same shape as ``/face-report``."""
    return await _run_report_endpoint(body_report, req, uid, "body")


@app.get("/skills/report/{kind}/{report_id}")
async def skills_report(
    kind: str, report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored face / body report by id — from a chat marker
    (``[face_report:<id>]`` / ``[body_report:<id>]``) or a history list.
    ``kind`` is ``face`` or ``body``; 404 when the caller has no such report."""
    if kind not in ("face", "body"):
        raise HTTPException(
            status_code=400, detail="kind must be 'face' or 'body'."
        )

    def _read() -> dict[str, object] | None:
        snap = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{kind}_reports")
            .document(report_id.strip())
            .get()
        )
        if not getattr(snap, "exists", False):
            return None
        data = snap.to_dict() or {}
        created = data.get("created_at")
        return {
            "report": data.get("report") or {},
            "image_path": str(data.get("image_path") or ""),
            "created_at": (
                created.isoformat()
                if hasattr(created, "isoformat")
                else None
            ),
        }

    out = await asyncio.to_thread(_read)
    if out is None:
        raise HTTPException(status_code=404, detail="No such report.")
    return out


@app.get("/skills/reports/{kind}")
async def skills_reports(
    kind: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """List the caller's stored face / body reports, newest first — backs the
    per-skill history on the Skills screen. Unusable reads are filtered out."""
    if kind not in ("face", "body"):
        raise HTTPException(
            status_code=400, detail="kind must be 'face' or 'body'."
        )

    def _list() -> list[dict[str, object]]:
        from firebase_admin import firestore

        col = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{kind}_reports")
        )
        try:
            snaps = list(
                col.order_by(
                    "created_at", direction=firestore.Query.DESCENDING
                )
                .limit(30)
                .stream()
            )
        except Exception:  # noqa: BLE001 - missing index / empty collection
            snaps = sorted(
                col.stream(),
                key=lambda s: str((s.to_dict() or {}).get("created_at") or ""),
                reverse=True,
            )
        out: list[dict[str, object]] = []
        for s in snaps:
            data = s.to_dict() or {}
            report = data.get("report") or {}
            if not report.get("usable", True):
                continue
            created = data.get("created_at")
            out.append(
                {
                    "id": s.id,
                    "image_path": str(data.get("image_path") or ""),
                    "overall_score": report.get("overall_score", 0),
                    "verdict": str(report.get("verdict") or ""),
                    "created_at": (
                        created.isoformat()
                        if hasattr(created, "isoformat")
                        else None
                    ),
                }
            )
            if len(out) >= 20:
                break
        return out

    return {"reports": await asyncio.to_thread(_list)}


class _OtherUid(BaseModel):
    other_uid: str = Field(min_length=1, max_length=128)


class _MiniProfilesRequest(BaseModel):
    uids: list[str] = Field(default_factory=list, max_length=100)


@app.post("/profiles/mini")
async def profiles_mini(
    req: _MiniProfilesRequest, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """``{uid: {name, photo}}`` for a batch of users — the name + a resolved
    photo URL for message-list rows and match cards. A user can't resolve
    another person's Storage path themselves, so the URL is minted here."""
    db = get_db()

    def _one(other: str) -> dict:
        try:
            prof = (
                db.collection("users").document(other)
                .collection("profile").document("main").get().to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            return {"name": "", "photo": "", "online": False}
        photo = ""
        try:
            from public_profile import _photo_url

            path = _primary_profile_photo_path(other)
            photo = (_photo_url(path) or "") if path else ""
        except Exception:  # noqa: BLE001
            photo = ""
        # "Online" = touched the API in the last 5 min (last_active_at is
        # stamped on every authed request — see _stamp_last_active).
        online = False
        try:
            import time as _t

            udoc = db.collection("users").document(other).get().to_dict() or {}
            la = udoc.get(schema.FIELD_LAST_ACTIVE_AT)
            if hasattr(la, "timestamp"):
                online = (_t.time() - la.timestamp()) < 300
        except Exception:  # noqa: BLE001
            online = False
        return {
            "name": str(prof.get("name") or "").strip(),
            "photo": photo,
            "online": online,
        }

    seen: set[str] = set()
    out: dict[str, dict] = {}
    for u in req.uids:
        u = (u or "").strip()
        if u and u not in seen:
            seen.add(u)
            out[u] = await asyncio.to_thread(_one, u)
    return {"profiles": out}


@app.post("/explore/like")
async def explore_like(
    req: _OtherUid,
    background: BackgroundTasks,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """Record interest; a reciprocal like flips ``matches/{id}.status`` to
    ``mutual_interest`` (creating the doc if Pass 2 hasn't run, §6.5)."""
    other = req.other_uid.strip()
    if other == uid:
        raise HTTPException(status_code=400, detail="Cannot like yourself.")
    db = get_db()
    db.collection("users").document(uid).collection("likes").document(
        other
    ).set({"liked_at": _server_ts()})

    reciprocal = (
        db.collection("users")
        .document(other)
        .collection("likes")
        .document(uid)
        .get()
        .exists
    )
    if not reciprocal:
        return {"ok": True, "mutual": False}

    lo, hi = sorted((uid, other))
    db.collection(MATCHES_COLLECTION).document(sorted_pair_key(uid, other)).set(
        {
            "uids": [lo, hi],
            "status": MATCH_STATUS_MUTUAL,
            "updated_at": _server_ts(),
        },
        merge=True,
    )
    background.add_task(_notify_mutual_match, uid, other)
    return {"ok": True, "mutual": True}


@app.post("/explore/unlike")
async def explore_unlike(
    req: _OtherUid,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """Undo a like (§6.5) — the mirror of ``/explore/like``. Deletes
    ``users/{uid}/likes/{other}``; if the like had made the pair mutual, walks
    ``matches/{id}.status`` back off ``mutual_interest`` (to ``scored`` when a
    score is on file, else ``unmatched``) so the two drop out of each other's
    matches. Idempotent — unliking when nothing is liked is a 200 no-op.
    Best-effort on the match-doc cleanup; a missing/gone doc never 500s."""
    other = req.other_uid.strip()
    if other == uid:
        raise HTTPException(status_code=400, detail="Cannot unlike yourself.")
    db = get_db()
    db.collection("users").document(uid).collection("likes").document(
        other
    ).delete()

    try:
        ref = db.collection(MATCHES_COLLECTION).document(
            sorted_pair_key(uid, other)
        )
        snap = ref.get()
        cur = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        if cur.get("status") == MATCH_STATUS_MUTUAL:
            ref.set(
                {
                    "status": (
                        MATCH_STATUS_SCORED
                        if cur.get("score") is not None
                        else MATCH_STATUS_UNMATCHED
                    ),
                    "updated_at": _server_ts(),
                },
                merge=True,
            )
    except Exception:  # noqa: BLE001
        logger.exception(
            "unlike match-doc cleanup failed for %s x %s", uid, other
        )

    return {"ok": True}


@app.post("/explore/pass")
async def explore_pass(
    req: _OtherUid, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Seen/passed marker — not a block (§6.5); the card stops resurfacing."""
    get_db().collection("users").document(uid).collection(
        "explore_passed"
    ).document(req.other_uid.strip()).set({"passed_at": _server_ts()})
    return {"ok": True}


class DmMessageRequest(BaseModel):
    type: Literal[
        "text", "photo", "voice", "shared_profile", "image", "file", "shared_report"
    ]
    # Required for text/photo/voice/shared_profile; an optional caption for
    # image/file (validated per-type in the handler).
    body: str = Field(default="", max_length=4000)
    # image/file only: the uploaded object under the caller's ``uploads/`` tree.
    attachment_url: str = Field(default="", max_length=2048)
    attachment_path: str = Field(default="", max_length=1024)
    mime: str = Field(default="", max_length=255)
    file_name: str = Field(default="", max_length=255)
    size: int = Field(default=0, ge=0)
    # shared_report only: the ``POST /share`` token; title/summary/card are
    # read from the stored snapshot, never trusted from the client.
    share_token: str = Field(default="", max_length=128)


@app.post("/dm/{thread_id}/messages")
async def dm_send(
    thread_id: str,
    req: DmMessageRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """Send a DM message (§6.6). ``thread_id`` is the sorted-pair id; the caller
    must be a participant. Ingestion into the wiki (§6.8) is Step 51."""
    from pair_key import uids_from_pair_key

    try:
        a, b = uids_from_pair_key(thread_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if uid not in (a, b):
        raise HTTPException(status_code=403, detail="Not your thread.")
    other = b if uid == a else a

    if req.type in ("text", "shared_profile") and not req.body.strip():
        raise HTTPException(status_code=400, detail="Empty message.")
    if req.type in ("photo", "voice") and not req.body.startswith(
        f"uploads/{uid}/"
    ):
        raise HTTPException(
            status_code=400,
            detail="photo/voice body must be a path under your uploads/.",
        )

    attachment: dict[str, object] | None = None
    if req.type in dm_schema.ATTACHMENT_MESSAGE_TYPES:
        if not req.attachment_path.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=400,
                detail="attachment_path must be under your uploads/.",
            )
        attachment = {
            "attachment_url": req.attachment_url,
            "attachment_path": req.attachment_path,
            "mime": req.mime,
            "file_name": req.file_name,
            "size": req.size,
        }

    report_share: dict[str, str] | None = None
    if req.type == "shared_report":
        snap = await asyncio.to_thread(
            share.fetch_public, get_db(), req.share_token
        )
        if snap is None:
            raise HTTPException(status_code=400, detail="Unknown share.")
        report_share = {
            "token": req.share_token,
            "title": str(snap["title"]),
            "summary": str(snap["summary"]),
            "card_url": f"{share.share_url(req.share_token)}/card.png",
        }

    # Text moderation (audit Task 1): never blocks or delays the send — the
    # Gemini call runs in the background *after* the message is persisted and
    # the response returned; a flagged verdict is applied to the stored doc
    # after the fact. Scoped to DM text only; never touches /chat or
    # /chat/stream.
    try:
        msg_id = await asyncio.to_thread(
            dm_ops.post_message,
            get_db(),
            uid,
            other,
            req.type,
            req.body,
            attachment,
            None,
            report_share,
        )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Blocked.") from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # Notify first — it's time-sensitive and cheap; the moderation pass and
    # wiki ingest (each one or more Gemini calls) run after so neither ever
    # delays the push or the response the sender is waiting on.
    background.add_task(
        _notify_new_dm, thread_id, uid, other, req.type, req.body
    )
    if req.type == "text":
        background.add_task(
            _moderate_dm_message, thread_id, msg_id, req.body, uid
        )
    background.add_task(
        _run_dm_ingest,
        thread_id,
        msg_id,
        uid,
        other,
        req.type,
        req.body,
        req.attachment_path,
    )
    return {"ok": True, "message_id": msg_id, "thread_id": thread_id}


async def _notify_new_dm(
    thread_id: str, sender: str, recipient: str, mtype: str, body: str
) -> None:
    await notifications_triggers.notify_new_dm(
        get_db(), thread_id, sender, recipient, mtype, body
    )


async def _notify_mutual_match(uid_a: str, uid_b: str) -> None:
    await notifications_triggers.notify_mutual_match(get_db(), uid_a, uid_b)


async def _moderate_dm_message(
    thread_id: str, msg_id: str, text: str, sender_uid: str = ""
) -> None:
    """Run the Gemini moderation pass after the DM has already been sent and
    the sender's response returned, then flag the stored doc if needed."""
    try:
        verdict = await dm_moderation.moderate(text)
        if verdict.get("flagged"):
            await asyncio.to_thread(
                dm_ops.mark_moderated, get_db(), thread_id, msg_id, verdict
            )
            # A fresh flag is exactly the material Ayma's assessment page is
            # for (founder's canonical case: an unsolicited sexual DM) —
            # refresh it now rather than waiting for the sender's next
            # session end. New-flag material bypasses the refresh debounce.
            if sender_uid:
                await ai_assessment.maybe_refresh(get_db(), sender_uid)
    except Exception:  # noqa: BLE001
        logger.exception(
            "DM moderation task failed for %s/%s", thread_id, msg_id
        )


async def _run_dm_ingest(
    thread_id: str,
    msg_id: str,
    sender: str,
    other: str,
    mtype: str,
    body: str,
    attachment_path: str = "",
) -> None:
    try:
        await dm_ingest.ingest_dm_message(
            get_db(),
            thread_id,
            msg_id,
            sender,
            other,
            mtype,
            body,
            attachment_path,
        )
    except Exception:  # noqa: BLE001
        logger.exception("DM ingest task failed for %s", thread_id)


@app.get("/dm/{thread_id}/icebreakers")
async def dm_icebreakers(
    thread_id: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Suggested opener chips for this thread (§6.9). Empty until a
    compatibility check has produced a ``matches`` doc for the pair."""
    try:
        a, b = uids_from_pair_key(thread_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if uid not in (a, b):
        raise HTTPException(status_code=403, detail="Not your thread.")
    other = b if uid == a else a
    chips = await icebreakers.suggest(get_db(), uid, other)
    return {"icebreakers": chips}


class ProfileShareRequest(BaseModel):
    shared_uid: str = Field(min_length=1, max_length=128)
    thread_with: str = Field(min_length=1, max_length=128)


@app.post("/profile/share")
async def profile_share(
    req: ProfileShareRequest, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Send a ``shared_profile`` message into the DM thread with
    ``thread_with`` (§6.7)."""
    try:
        msg_id = await asyncio.to_thread(
            dm_ops.post_message,
            get_db(),
            uid,
            req.thread_with.strip(),
            "shared_profile",
            req.shared_uid.strip(),
        )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Blocked.") from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "message_id": msg_id}


# --- Shareable reports (web research / Match) ------------------------------


class ShareCreateRequest(BaseModel):
    report_type: str = Field(min_length=1, max_length=64)
    report_id: str = Field(min_length=1, max_length=256)


class ShareRevokeRequest(BaseModel):
    token: str = Field(min_length=1, max_length=128)


@app.post("/share")
async def share_create(
    req: ShareCreateRequest, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Snapshot one of the caller's reports behind an unguessable public link
    (idempotent per report). See ``share.create``."""
    try:
        return await asyncio.to_thread(
            share.create, get_db(), uid, req.report_type, req.report_id.strip()
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such report.") from None


@app.post("/share/revoke")
async def share_revoke(
    req: ShareRevokeRequest, uid: str = Depends(require_uid)
) -> dict[str, bool]:
    try:
        await asyncio.to_thread(share.revoke, get_db(), uid, req.token)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such share.") from None
    return {"ok": True}


async def _public_snapshot(token: str) -> dict:
    snap = await asyncio.to_thread(share.fetch_public, get_db(), token)
    if snap is None:
        raise HTTPException(status_code=404, detail="This link isn't available.")
    return snap


@app.get("/s/{token}", response_class=HTMLResponse)
async def share_page_html(token: str) -> HTMLResponse:
    """Public, unauthenticated, server-rendered view of a shared report."""
    snap = await _public_snapshot(token)
    return HTMLResponse(share_page.render_page(token, snap))


@app.get("/s/{token}/data")
async def share_data(token: str) -> dict[str, object]:
    """The snapshot in the in-app ``GET /report`` shape, for the app's
    read-only deep-link view."""
    snap = await _public_snapshot(token)
    return {
        "title": snap["title"],
        "sections": snap["sections"],
        "meta": {"owner_uid": "", "viewer_can_edit": False},
    }


@app.get("/s/{token}/card.png")
async def share_card(token: str, format: Literal["story", "link"] = "link") -> Response:
    """The branded share card: ``link`` 1200x630 (og:image) or ``story``
    1080x1920."""
    snap = await _public_snapshot(token)
    png = await asyncio.to_thread(share_page.render_card, snap, format)
    return Response(
        png, media_type="image/png", headers={"Cache-Control": "public, max-age=300"}
    )


@app.get("/.well-known/assetlinks.json")
async def assetlinks() -> list[dict[str, object]]:
    """Android app-link verification for ``/s/*`` (driven by config)."""
    if not CONFIG.share_assetlinks_sha256:
        raise HTTPException(status_code=404, detail="Not configured.")
    return [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": CONFIG.share_android_package,
                "sha256_cert_fingerprints": list(CONFIG.share_assetlinks_sha256),
            },
        }
    ]


# --- Referrals (founder feature 2026-09-29): shareable invite link ---------


@app.get("/r/{code}", response_class=HTMLResponse)
async def referral_landing(code: str) -> HTMLResponse:
    """Public download page for an invite link (Firebase Hosting rewrites
    ``/r/**`` here). Never touches the database."""
    return HTMLResponse(
        referral_page.render_page(code),
        headers={"Cache-Control": "public, max-age=300"},
    )


@app.get("/r/{code}/card.png")
async def referral_card(code: str) -> Response:
    """The 1200x630 link-preview image (og:image) for an invite link."""
    png = await asyncio.to_thread(referral_page.render_card, code)
    return Response(
        png, media_type="image/png", headers={"Cache-Control": "public, max-age=3600"}
    )


@app.get("/referral")
async def referral_info(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's referral code + shareable link, minted lazily on first
    request (referrals.py). Attribution only — no rewards yet."""
    code = await asyncio.to_thread(referrals.code_for, get_db(), uid)
    return {"code": code, "link": referrals.link_for(code)}


class ReferralRedeemRequest(BaseModel):
    code: str = Field(min_length=1, max_length=256)


@app.post("/referral/redeem")
async def referral_redeem(
    req: ReferralRedeemRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Attribute the (new) caller to the owner of ``code`` — the sign-up flow
    calls this right after account creation. There is no server-side
    user-creation endpoint (accounts are born in Firebase Auth and
    ``users/{uid}`` accretes lazily), so this is the sign-up seam. Idempotent;
    invalid / self / already-referred are silently ``applied: false`` — a bad
    code must never break sign-up."""
    applied = await asyncio.to_thread(referrals.redeem, get_db(), uid, req.code)
    return {"applied": applied}


class BlockRequest(BaseModel):
    blocked_uid: str = Field(min_length=1, max_length=128)


@app.post("/block")
async def block_user(
    req: BlockRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Block a user — excluded from all future candidate sourcing (§5.1, §5.10
    step 11). Used from both Explore and DM in Phase 8."""
    from firebase_admin import firestore

    blocked = req.blocked_uid.strip()
    if blocked == uid:
        raise HTTPException(status_code=400, detail="Cannot block yourself.")
    db = get_db()
    db.collection(BLOCKS_COLLECTION).document(block_id(uid, blocked)).set(
        {
            "blocker": uid,
            "blocked": blocked,
            "created_at": _server_ts(),
        }
    )
    # Hide the pair's DM thread from the blocker (§6.11 step 11). Message
    # sends both ways are already refused by dm_ops once a block exists.
    thread_ref = db.collection("dm_threads").document(
        sorted_pair_key(uid, blocked)
    )
    if thread_ref.get().exists:
        thread_ref.set(
            {"hidden_for": firestore.ArrayUnion([uid])}, merge=True
        )
    return {"ok": True}


def _require_meta_integrations() -> None:
    """Instagram / Facebook are deferred to V2: 404 while the flag is off."""
    import feature_flags

    if not feature_flags.enabled("meta_integrations"):
        raise HTTPException(
            status_code=404,
            detail="Instagram and Facebook integrations are not available.",
        )


@app.get("/instagram/auth-url", dependencies=[Depends(_require_meta_integrations)])
async def instagram_auth_url(uid: str = Depends(require_uid)) -> dict[str, str]:
    """The URL the client opens to authorise Instagram access (§8.1)."""
    import instagram

    try:
        return {"url": instagram.auth_url(state=uid)}
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


class InstagramConnectRequest(BaseModel):
    code: str = Field(min_length=1, max_length=4096)


@app.post("/instagram/connect", dependencies=[Depends(_require_meta_integrations)])
async def instagram_connect(
    req: InstagramConnectRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Exchange the OAuth ``code``, store the token, import recent photos +
    captions (§8.2, §8.7 step 2)."""
    import instagram

    try:
        return await asyncio.to_thread(
            instagram.connect, get_db(), uid, req.code
        )
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/instagram/disconnect", dependencies=[Depends(_require_meta_integrations)])
async def instagram_disconnect(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Forget the Instagram token; imported photos stay (§8.1)."""
    import instagram

    await asyncio.to_thread(instagram.disconnect, get_db(), uid)
    return {"ok": True}


@app.get("/instagram/signin-auth-url", dependencies=[Depends(_require_meta_integrations)])
async def instagram_signin_auth_url() -> dict[str, str]:
    """"Sign in with Instagram" (new) — the URL the client opens to authorise.
    Unlike ``/instagram/auth-url`` above, this is reachable with no Firebase
    auth yet, so it takes no ``uid`` dependency."""
    import instagram

    try:
        return {"url": instagram.signin_auth_url()}
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


class InstagramSigninRequest(BaseModel):
    code: str = Field(min_length=1, max_length=4096)


@app.post("/instagram/signin", dependencies=[Depends(_require_meta_integrations)])
async def instagram_signin(req: InstagramSigninRequest) -> dict[str, object]:
    """Exchange the OAuth ``code``, resolve/create the Firebase user tied to
    that Instagram identity, and mint a custom token
    (``FirebaseAuth.instance.signInWithCustomToken`` on the client). No
    ``uid`` dependency — there is none yet."""
    import instagram

    try:
        return await asyncio.to_thread(instagram.signin, get_db(), req.code)
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.get("/google/auth-url")
async def google_auth_url(uid: str = Depends(require_uid)) -> dict[str, str]:
    """The URL the client opens to authorise Google account import (Gmail +
    Calendar — mirrors the Instagram flow above)."""
    import google_account

    try:
        return {"url": google_account.auth_url(state=uid)}
    except google_account.GoogleAccountError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


class GoogleConnectRequest(BaseModel):
    code: str = Field(min_length=1, max_length=4096)


@app.post("/google/connect")
async def google_connect(
    req: GoogleConnectRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Exchange the OAuth ``code``, store the refresh token, and schedule a
    bounded background sync (never blocks this request on Gmail/Calendar
    calls)."""
    import google_account

    try:
        return await asyncio.to_thread(
            google_account.connect, get_db(), uid, req.code
        )
    except google_account.GoogleAccountError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/google/disconnect")
async def google_disconnect(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Revoke the token with Google and delete the stored refresh token."""
    import google_account

    await asyncio.to_thread(google_account.disconnect, get_db(), uid)
    return {"ok": True}


@app.get("/google/status")
async def google_status(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Non-secret connection status for the client (never the token itself)."""
    import google_account

    return await asyncio.to_thread(google_account.status, get_db(), uid)


@app.get("/admin", response_class=HTMLResponse, include_in_schema=False)
async def admin_dashboard() -> str:
    """Static admin dashboard shell (§14.3) — plain HTML/CSS/vanilla JS, no
    build step. Inert on its own: it renders nothing sensitive until a viewer
    types the admin password into the page, which the page then sends as the
    ``X-Admin-Password`` header on its own ``fetch()`` calls to the real gated
    data endpoints (``/admin/provider-spend``, ``/admin/users``). The
    password is kept only in this tab's ``sessionStorage`` — never embedded in
    this HTML, never put in a URL, never logged server-side. This route is
    deliberately NOT behind ``require_admin_password`` itself."""
    from admin_dashboard import DASHBOARD_HTML

    return DASHBOARD_HTML


@app.get(
    "/admin/provider-spend", dependencies=[Depends(require_admin_password)]
)
async def admin_provider_spend() -> dict[str, object]:
    """Provider usage and spend straight from the providers (Google Cloud
    Billing export, LiveKit Analytics API). Every panel is either a figure
    fetched from that source or ``available: false`` with a reason — see
    ``provider_spend.py``."""
    import provider_spend

    return await asyncio.to_thread(provider_spend.snapshot)


@app.get(
    "/admin/feature-flags", dependencies=[Depends(require_admin_password)]
)
async def admin_feature_flags() -> dict[str, object]:
    """Effective value and source of every feature flag (read-only) — see
    ``feature_flags.py`` / docs/FEATURE_FLAGS.md."""
    import feature_flags

    return {"flags": await asyncio.to_thread(feature_flags.snapshot)}


@app.get("/admin/vendors", dependencies=[Depends(require_admin_password)])
async def admin_vendors() -> dict[str, object]:
    """Every paid vendor with its value, method (API vs Muse-collected),
    fetch time, stale flag and "how to check" block — see ``vendor_spend.py``."""
    import provider_spend
    import vendor_spend

    def _build() -> dict[str, object]:
        return vendor_spend.build(get_db(), provider_spend.snapshot())

    return await asyncio.to_thread(_build)


@app.post("/admin/vendor-spend", dependencies=[Depends(require_admin_password)])
async def admin_vendor_spend_record(request: Request) -> dict[str, object]:
    """Record one vendor figure (the Muse daily routine posts here). Rejects
    anything without ``source_url`` and ``fetched_at``."""
    import vendor_spend

    try:
        payload = await request.json()
    except ValueError:
        raise HTTPException(status_code=422, detail="body must be valid JSON")
    try:
        doc = await asyncio.to_thread(vendor_spend.record, get_db(), payload)
    except vendor_spend.ValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    return {"ok": True, "recorded": doc}


@app.get("/admin/users", dependencies=[Depends(require_admin_password)])
async def admin_users(q: str = "") -> dict[str, object]:
    """Search users by uid or name substring (§14.3)."""
    import admin

    return {"users": await asyncio.to_thread(admin.search_users, get_db(), q)}


@app.get(
    "/admin/users/{uid}", dependencies=[Depends(require_admin_password)]
)
async def admin_user_detail(uid: str) -> dict[str, object]:
    """Full per-user detail over the data model (§14.3): account, profile,
    wiki pages (incl. ``ai_only``), matches, dm_threads, trust_flags, and any
    ``deleted_accounts`` record."""
    import admin

    return await asyncio.to_thread(admin.user_detail, get_db(), uid)


@app.get(
    "/admin/users/{uid}/full", dependencies=[Depends(require_admin_password)]
)
async def admin_user_full_detail(uid: str) -> dict[str, object]:
    """Everything live for ``uid`` (founder request 2026-09-20): account
    fields, profile, every per-user data category (photos/user_media,
    appearance/physical/face/body reports, deep dives, skill runs, wiki
    pages incl. version history, AI-companion chat transcript, etc. — see
    ``schema.ACCOUNT_SUBCOLLECTIONS``), matches, dm_threads (with messages),
    blocks, and feedback/bug reports. Superset of ``/admin/users/{uid}``."""
    import admin_lookup

    return await asyncio.to_thread(admin_lookup.live_user_detail, get_db(), uid)


@app.get(
    "/admin/archived-accounts/{uid}",
    dependencies=[Depends(require_admin_password)],
)
async def admin_archived_account_detail(uid: str) -> dict[str, object]:
    """A fully-deleted uid's data (founder request 2026-09-20): the
    permanent ``archived_accounts/{uid}`` once the recovery window has
    closed, else the still-recoverable ``deleted_accounts/{uid}`` quarantine.
    ``{"uid": uid, "found": False}`` if this uid was never deleted."""
    import admin_lookup

    detail = await asyncio.to_thread(
        admin_lookup.archived_account_detail, get_db(), uid
    )
    if detail is None:
        return {"uid": uid, "found": False}
    return {"found": True, **detail}


@app.get(
    "/admin/knowledge-archives/{uid}",
    dependencies=[Depends(require_admin_password)],
)
async def admin_knowledge_archive_list(uid: str) -> dict[str, object]:
    """Every "delete everything Ayma knows" snapshot taken for ``uid``
    (founder request 2026-09-20), oldest first. Fetch one in full via
    ``/admin/knowledge-archives/{uid}/{archive_id}``."""
    import admin_lookup

    return {
        "archives": await asyncio.to_thread(
            admin_lookup.knowledge_archive_list, get_db(), uid
        )
    }


@app.get(
    "/admin/knowledge-archives/{uid}/{archive_id}",
    dependencies=[Depends(require_admin_password)],
)
async def admin_knowledge_archive_detail(
    uid: str, archive_id: str
) -> dict[str, object]:
    """Full content of one knowledge-wipe snapshot: every wiki page, report,
    deep dive, chat transcript, etc. that was live for ``uid`` at the moment
    that "delete everything Ayma knows" run happened."""
    import admin_lookup

    detail = await asyncio.to_thread(
        admin_lookup.knowledge_archive_detail, get_db(), uid, archive_id
    )
    if detail is None:
        raise HTTPException(status_code=404, detail="No such archive.")
    return detail


@app.get(
    "/admin/media-url", dependencies=[Depends(require_admin_password)]
)
async def admin_media_url(path: str) -> dict[str, object]:
    """Resolve a Storage path (as it appears in a live or archived
    ``user_media`` doc's ``storage_path`` field) to a viewable download URL,
    so the admin dashboard's user-lookup view can render actual photos
    instead of raw paths (founder request 2026-09-20: "see everything
    including photos"). Reuses the exact same download-URL scheme the app
    itself already serves photos with (``public_profile._photo_url``) — no
    separate signing logic introduced here."""
    from public_profile import _photo_url

    if not path:
        raise HTTPException(status_code=400, detail="path is required.")
    url = await asyncio.to_thread(_photo_url, path)
    return {"path": path, "url": url}


@app.get(
    "/admin/users/{uid}/credits", dependencies=[Depends(require_admin_password)]
)
async def admin_user_credits(uid: str) -> dict[str, object]:
    """Token usage + credit balance for ``uid`` (founder request
    2026-09-20: the user-lookup view's "credits" line) — the exact same
    figures ``token_ledger.usage`` gives the user themselves at
    ``GET /usage``."""
    return await asyncio.to_thread(
        functools.partial(token_ledger.usage, uid, include_dollars=True)
    )


@app.get(
    "/admin/persona-changes", dependencies=[Depends(require_admin_password)]
)
async def admin_persona_changes() -> dict[str, object]:
    """Persona-evolution proposals awaiting a decision (§15 Part B) — those a
    daily aggregation run classified ``critical``, plus any that failed the
    automated eval gate. Most recent first."""
    return {
        "proposals": await asyncio.to_thread(
            persona_evolution.list_pending, get_db()
        )
    }


@app.post(
    "/admin/persona-changes/{proposal_id}/approve",
    dependencies=[Depends(require_admin_password)],
)
async def admin_persona_change_approve(proposal_id: str) -> dict[str, object]:
    """Apply a held proposal's ``proposed_lessons_md`` to the live persona
    config (same path the automated gate uses on a pass) and mark it
    ``approved``."""
    ok = await asyncio.to_thread(
        persona_evolution.approve, get_db(), proposal_id
    )
    if not ok:
        raise HTTPException(status_code=404, detail="No such proposal.")
    return {"ok": True}


@app.post(
    "/admin/persona-changes/{proposal_id}/reject",
    dependencies=[Depends(require_admin_password)],
)
async def admin_persona_change_reject(
    proposal_id: str, reason: str = ""
) -> dict[str, object]:
    """Mark a held proposal ``rejected``. No changes are applied. Optional
    ``?reason=`` query param is stored for reference."""
    ok = await asyncio.to_thread(
        persona_evolution.reject, get_db(), proposal_id, reason
    )
    if not ok:
        raise HTTPException(status_code=404, detail="No such proposal.")
    return {"ok": True}


class WikiPromoteRequest(BaseModel):
    page_type: str = Field(min_length=1, max_length=40)


_PROMOTABLE_PAGE_TYPES = {
    "web_findings",
    "face_analysis",
    "body_analysis",
    "physical_profile",
}


@app.post("/wiki/promote")
async def wiki_promote(
    req: WikiPromoteRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Add what Ayma found to the user's story — flip a skill-memory page
    (``web_findings`` / ``face_analysis`` / ``body_analysis``) from Ayma's
    private ``ai_only`` memory to the user's private wiki. ``{"promoted": bool}``
    — ``false`` when there is no such page yet."""
    if req.page_type not in _PROMOTABLE_PAGE_TYPES:
        raise HTTPException(
            status_code=400, detail="Not a promotable page type."
        )
    promoted = await asyncio.to_thread(
        skill_memory.promote, get_db(), uid, req.page_type
    )
    return {"promoted": promoted}


def _ai_view_photos(uid: str) -> list[dict[str, object]]:
    """Every photo Ayma holds of the caller: their profile-grid photos
    (``source: "profile"``), any image they've sent in the Ayma chat
    (``source: "chat"``), then face-verified photos Ayma has found of them on
    the open web during a "search me" deep dive (``source: "web"``). De-duped
    by URL, then by image content (the same photo under two URLs collapses to
    one — see ``photo_notes.classify_and_dedupe``), capped at 60.

    Each carries its stable ``id``, any note the user or Ayma has written
    (``context``), and ``is_user`` — Ayma's own face-match verdict, computed
    (and cached) here rather than asked of the user. Deleting a photo doesn't
    drop it from this list: it comes back with ``deleted: true`` instead, so
    the client can move it under AI notes ("deleted by you") rather than
    losing it — the record it came from (grid entry / chat message / dive)
    stays untouched either way. A photo superseded by "Make public" (the
    original chat/web copy, once its promoted twin exists) really does drop
    out — that one isn't a user-visible delete.
    """
    from firebase_admin import firestore

    import photo_notes
    from public_profile import _photo_url

    db = get_db()
    notes = photo_notes.all_notes(db, uid)
    candidates: list[dict[str, object]] = []
    seen: set[str] = set()

    def _add(
        url: str, source: str, *, source_page: str = "",
        embedding: list[float] | None = None,
    ) -> None:
        if not url or url in seen or len(candidates) >= 90:
            return
        seen.add(url)
        note = notes.get(photo_notes.photo_id(url), {})
        if note.get("status") == "superseded":
            return
        entry: dict[str, object] = {
            "id": photo_notes.photo_id(url),
            "url": url,
            "source": source,
            "context": note.get("context", ""),
            "is_user": note.get("is_user", ""),
            "deleted": note.get("status") == "deleted",
            "_embedding": embedding if embedding is not None else note.get("embedding"),
        }
        if source_page:
            entry["source_page"] = source_page
        candidates.append(entry)

    try:
        prof = schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        prof = {}
    try:
        for m in photo_notes.profile_photo_media(db, uid, prof):
            _add(m["url"], "profile", embedding=m.get("embedding"))
    except Exception:  # noqa: BLE001
        logger.warning("ai-view: profile photos failed for %s", uid)

    try:
        msgs = list(
            db.collection("users")
            .document(uid)
            .collection("chat_messages")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(200)
            .stream()
        )
    except Exception:  # noqa: BLE001
        msgs = []
    for snap in msgs:
        path = str((snap.to_dict() or {}).get("image_path") or "").strip()
        if path:
            _add(_photo_url(path) or "", "chat")

    try:
        import deep_dive

        # A self dive is stored keyed by name (target_uid="" — see the
        # deep-dive endpoint/skill, which always pass "" for is_self), never
        # by the caller's own uid. Looking it up by uid here silently missed
        # every self dive's web photos.
        report_id = deep_dive.dive_report_id(
            name=deep_dive.profile_full_name(db, uid)
        )
        dive = deep_dive.read_dive(db, uid, report_id)
        digest = (dive or {}).get("digest") if dive else None
        for img in (digest or {}).get("web_images") or []:
            if isinstance(img, dict) and img.get("verified"):
                _add(
                    str(img.get("url") or ""), "web",
                    source_page=str(img.get("source_page") or ""),
                )
    except Exception:  # noqa: BLE001
        logger.warning("ai-view: web photos failed for %s", uid)

    # A deleted photo that's no longer found live (e.g. a removed profile
    # photo) has to be recovered from its own note — it's the only place its
    # URL still exists.
    for note in notes.values():
        url = str(note.get("url") or "")
        if note.get("status") == "deleted" and url and url not in seen:
            _add(url, note.get("source") or "chat")

    out = photo_notes.classify_and_dedupe(db, uid, candidates)
    return out[:60]


@app.get("/wiki/ai-view")
async def wiki_ai_view(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Debug: the compiled wiki context Ayma reads about the caller, verbatim
    (every page's ``ai_body``), plus every photo Ayma has of them. Temporary —
    remove before launch."""
    text = await asyncio.to_thread(read_wiki_context, get_db(), uid)
    photos = await asyncio.to_thread(_ai_view_photos, uid)
    return {"text": text or "", "photos": photos}


class PhotoNoteRequest(BaseModel):
    url: str = Field(min_length=1, max_length=2000)
    context: str | None = Field(default=None, max_length=2000)
    is_user: str | None = Field(default=None, max_length=8)


class PhotoActionRequest(BaseModel):
    url: str = Field(min_length=1, max_length=2000)
    source: str = Field(default="", max_length=16)


@app.put("/wiki/photo-note")
async def wiki_photo_note(
    req: PhotoNoteRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Set what a photo is / whether it's the user — shown to the owner as
    part of Your Story, never in the public view."""
    import photo_notes

    try:
        note = await asyncio.to_thread(
            photo_notes.set_context,
            get_db(), uid, req.url, context=req.context, is_user=req.is_user,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, **note}


@app.post("/wiki/photo-hide")
async def wiki_photo_hide(
    req: PhotoActionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Take a photo out of "photos Ayma has" — the profile-grid copy, if any,
    is soft-removed the same way any profile-photo delete works; Ayma keeps
    the underlying record either way."""
    import photo_notes

    try:
        await asyncio.to_thread(
            photo_notes.hide_photo, get_db(), uid, req.url, source=req.source
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/wiki/photo-publish")
async def wiki_photo_publish(
    req: PhotoActionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Promote a chat or web photo onto the public profile grid — runs the
    same moderation + embedding pipeline as any profile upload."""
    import photo_notes

    try:
        result = await photo_notes.publish_photo(
            get_db(), uid, req.url, source=req.source
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - moderation/embed/storage failure
        logger.exception("photo-publish failed for %s", uid)
        raise HTTPException(
            status_code=502, detail=f"Couldn't publish that photo: {exc}"
        ) from exc
    return {"ok": True, **result}


@app.post("/wiki/reset")
async def wiki_reset(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Wipe what Ayma has learned (§14.2; founder request 2026-09-20): archives
    every ``schema.KNOWLEDGE_SUBCOLLECTIONS`` category (wiki pages, raw turns,
    chat transcript, questionnaire, completeness cache, photo notes, every
    appearance/physical/face/body report, deep dives, skill runs) plus
    conversational feedback into a timestamped, admin-only
    ``archived_knowledge/{uid}/snapshots/{archive_id}`` snapshot, then resets
    the live copies. ``users/{uid}``, ``profile``, photos, credits and auth
    are untouched — this is distinct from account deletion (§3.6). Can be run
    more than once; each run gets its own snapshot. See
    ``knowledge_wipe.py``'s module docstring for the full line-drawing
    rationale on what counts as "Ayma's knowledge"."""
    import knowledge_wipe

    result = await asyncio.to_thread(knowledge_wipe.wipe_knowledge, get_db(), uid)
    return result


# --- Your Story editor (§ Your Story) -------------------------------------


class StorySaveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    body: str = Field(default="", max_length=20000)
    visibility: Literal["private", "public"] | None = None


class StoryVisibilityRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    visibility: Literal["private", "public"]


class StoryChatMessage(BaseModel):
    role: Literal["user", "ayma"]
    text: str = Field(default="", max_length=4000)


class StoryEditRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    selection: str = Field(default="", max_length=8000)
    messages: list[StoryChatMessage] = Field(default_factory=list, max_length=40)


class StoryRemoveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)


class StorySectionRevertRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    version_id: str = Field(min_length=1, max_length=128)


@app.get("/story")
async def story_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The whole story document once — every visible section (title, body,
    visibility, flags). The client renders the Public preview by filtering
    ``visibility == 'public'`` and stripping private spans locally. Each
    section's version history lives at ``/story/section/{id}/versions``."""
    return await asyncio.to_thread(story.get_story, get_db(), uid)


@app.get("/story/ai-notes")
async def story_ai_notes(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Every wiki page the caller has, regardless of visibility — public,
    private, and anything still ai_only — each carrying its own real
    visibility. Your Story's "AI notes" tab: a superset of "Everything",
    colour-coded by that visibility. See story.get_ai_notes."""
    return await asyncio.to_thread(story.get_ai_notes, get_db(), uid)


@app.put("/story/section")
async def story_save_section(
    req: StorySaveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Persist an edited section body (as a ``user_edits`` override),
    optionally changing its visibility, and commit a version to its history."""
    try:
        return await asyncio.to_thread(
            story.save_section,
            get_db(), uid, req.page_id, req.body, req.visibility,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/section/visibility")
async def story_set_visibility(
    req: StoryVisibilityRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Flip a whole section between ``public`` and ``private``."""
    try:
        return await asyncio.to_thread(
            story.set_visibility, get_db(), uid, req.page_id, req.visibility
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/edit")
async def story_edit(
    req: StoryEditRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One turn of the passage chat. Returns ``{reply, revised_body?, action,
    target_visibility?}`` — ``revised_body`` set only when Ayma proposes a
    concrete rewrite — or ``{usage_capped:true}``. Writes nothing."""
    try:
        return await story.edit_section(
            get_db(),
            uid,
            req.page_id,
            req.selection,
            [m.model_dump() for m in req.messages],
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/section/remove")
async def story_remove_section(
    req: StoryRemoveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Delete a section from the editor (``ai_only`` + ``user_hidden``,
    ``ai_body`` untouched). Its pre-delete state stays in history so a revert
    brings it back."""
    try:
        return await asyncio.to_thread(
            story.remove_section, get_db(), uid, req.page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


class ProfileTextSaveRequest(BaseModel):
    text: str = Field(default="", max_length=30000)
    base_version: str = Field(min_length=1, max_length=64)


class PartnerPreferencesRequest(BaseModel):
    partner_age_min: int | None = Field(default=None, ge=18, le=99)
    partner_age_max: int | None = Field(default=None, ge=18, le=99)
    distance_pref: str | None = Field(default=None, max_length=16)


@app.put("/profile/preferences")
async def profile_preferences_save(
    req: PartnerPreferencesRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Edit profile: save the partner age range and distance preference where
    matching already reads them (questionnaire doc + ``qz_*`` profile mirror).
    422 on a value the questionnaire would not accept."""
    try:
        recorded = await asyncio.to_thread(
            lambda: questionnaire_skill.save_partner_preferences(
                get_db(),
                uid,
                age_min=req.partner_age_min,
                age_max=req.partner_age_max,
                distance_pref=req.distance_pref,
            )
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"ok": True, "recorded": recorded}


@app.get("/profile/public-text")
async def profile_public_text(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's public profile as one plain text (each section under a
    ``## Title`` heading) for the manual editor, plus the ``version`` to send
    back on save."""
    return await asyncio.to_thread(profile_manual.get_text, get_db(), uid)


@app.put("/profile/public-text")
async def profile_public_text_save(
    req: ProfileTextSaveRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Save a manual edit of the public text: moderated, diffed, removed facts
    kept in the private AI notes, added facts pinned. 409 when the profile
    changed since the editor loaded, 422 when the text is refused."""
    try:
        return await profile_manual.save_text(
            get_db(), uid, req.text, req.base_version
        )
    except profile_manual.ProfileTextError as exc:
        status = 409 if exc.code == "stale" else 503 if exc.code == (
            "moderation_unavailable"
        ) else 422
        raise HTTPException(
            status_code=status, detail={"code": exc.code, "message": str(exc)}
        ) from exc


@app.get("/profile/proposals")
async def profile_proposals(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Ayma's pending updates to the public profile text, each with a
    sentence-level before/after diff, awaiting Apply or Dismiss."""
    return {
        "proposals": await asyncio.to_thread(
            profile_manual.list_proposals, get_db(), uid
        )
    }


@app.post("/profile/proposals/{page_id}/apply")
async def profile_proposal_apply(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    try:
        return await asyncio.to_thread(
            profile_manual.apply_proposal, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No pending update.")


@app.post("/profile/proposals/{page_id}/dismiss")
async def profile_proposal_dismiss(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    try:
        return await asyncio.to_thread(
            profile_manual.dismiss_proposal, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No pending update.")


@app.get("/story/section/{page_id}/versions")
async def story_section_versions(
    page_id: str, uid: str = Depends(require_uid)
) -> list[dict[str, object]]:
    """One section's version history, newest first."""
    return await asyncio.to_thread(
        story.list_section_versions, get_db(), uid, page_id
    )


@app.get("/story/section/{page_id}/versions/{version_id}")
async def story_section_version(
    page_id: str, version_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One stored section version in full (body + visibility)."""
    try:
        return await asyncio.to_thread(
            story.get_section_version, get_db(), uid, page_id, version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@app.post("/story/section/revert")
async def story_section_revert(
    req: StorySectionRevertRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Restore one section's body + visibility from one of its own versions
    (never ``ai_body``); a section deleted after that version comes back."""
    try:
        return await asyncio.to_thread(
            story.revert_section, get_db(), uid, req.page_id, req.version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@app.get("/story/section/{page_id}/provenance")
async def story_section_provenance(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """"Why Ayma believes this" for one section (§ Your Story provenance):
    conversations that fed it + last-updated dates. Page-level only, by the
    founder's own scope call — no fabricated per-sentence confidence. Real
    confidence exists only on individual web-research facts, surfaced by the
    deep-dive report itself, not here."""
    try:
        return await asyncio.to_thread(
            story.get_section_provenance, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.get("/story/career-timeline")
async def story_career_timeline(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The structured career/education timeline (§ Your Story career
    timeline): built lazily on first read, then cached on the ``career`` wiki
    page. ``show_timeline`` is only ``true`` once Ayma has decent confidence
    in every entry — otherwise the client renders Career & Education as
    flowing prose only, same as any other section. Always carries
    ``linkedin_url`` (``""`` if none on file yet)."""
    return await career_timeline.get_or_build_timeline(get_db(), uid)


@app.post("/story/career-timeline/refresh")
async def story_career_timeline_refresh(
    uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Force a fresh extraction pass — e.g. right after the user adds their
    LinkedIn URL, or corrects the Career & Education prose."""
    return await career_timeline.extract(get_db(), uid)


class LinkedInUrlRequest(BaseModel):
    url: str = Field(min_length=1, max_length=300)


@app.post("/story/linkedin")
async def story_set_linkedin(
    req: LinkedInUrlRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Save the user's own LinkedIn profile URL, given with their explicit
    consent (§ Your Story career timeline). No scraper, no LinkedIn API call
    of any kind: this URL is simply handed to Gemini's ``url_context`` tool on
    the next self deep-dive, which reads that one page directly as part of
    the same grounded research call "search me" already runs."""
    try:
        url = await asyncio.to_thread(
            career_timeline.set_linkedin_url, get_db(), uid, req.url
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"linkedin_url": url}


@app.get("/usage")
async def token_usage(
    caller: tuple[str, bool] = Depends(require_uid_and_dev_flag),
    period: str | None = None,
) -> dict[str, object]:
    """This user's lifetime Gemini-token usage — the running total plus a
    per-feature breakdown (chat / voice / matching / wiki / explore / reengage)
    — and the derived credit balance (grant + top-ups − used). Credits only:
    the dollar cost / real-money fields are included solely for callers on the
    dev-view allowlist (``CONFIG.dev_view_emails`` / ``dev_view_uids``), and
    ``is_dev`` tells the app whether to show its Dev view entry. ``period``
    (``since_credit`` | ``7d`` | ``30d`` | ``all``) adds ``period_usage``: the
    credits spent per feature (with friendly labels) over that window."""
    uid, is_dev = caller
    if period is not None and period not in token_ledger.PERIODS:
        raise HTTPException(status_code=400, detail="unknown period")
    extra = {} if period is None else {"period": period}
    view = await asyncio.to_thread(
        functools.partial(
            token_ledger.usage, uid, include_dollars=is_dev, **extra
        )
    )
    return {**view, "is_dev": is_dev}


@app.post("/usage/reset-real-money")
async def usage_reset_real_money(
    uid: str = Depends(require_dev),
) -> dict[str, object]:
    """Dev-view-only: reset the real-money tracker to $0.00 "since last reset" —
    a marker write, never a wipe: the all-time dollar total and the
    per-conversation spend history keep counting (see
    ``token_ledger.reset_real_money``). Returns the fresh usage view."""
    return await asyncio.to_thread(token_ledger.reset_real_money, uid)


@app.post("/credits/topup")
async def credits_topup(
    background: BackgroundTasks,
    caller: tuple[str, bool] = Depends(require_uid_and_dev_flag),
) -> dict[str, object]:
    """Reload the user's credit balance by ``CONFIG.credit_topup_amount`` —
    only for dev-view allowlisted callers or while
    ``CONFIG.credit_free_topup_enabled`` (env
    ``CREDITS_FREE_TOPUP_ENABLED``, default OFF). Otherwise a free reload
    would undercut the paywall, so the call changes nothing and answers
    ``402`` with ``{error: "upgrade_required", message}``. On success returns
    the fresh usage view and kicks off a background pass to re-ingest any
    conversations skipped while broke (§15)."""
    uid, is_dev = caller
    if not (is_dev or CONFIG.credit_free_topup_enabled):
        raise HTTPException(
            status_code=402,
            detail={
                "error": "upgrade_required",
                "message": token_ledger.UPGRADE_MESSAGE,
            },
        )
    await asyncio.to_thread(
        token_ledger.topup, uid, CONFIG.credit_topup_amount
    )
    background.add_task(backfill_ops.drain, get_db(), uid)
    return await asyncio.to_thread(token_ledger.usage, uid)


class DevFlagsRequest(BaseModel):
    """Body of ``POST /dev/flags`` — only ``dev_panel`` may be written."""

    model_config = {"extra": "forbid"}

    password: str = Field(min_length=1, max_length=256)
    dev_panel: bool


@app.get("/dev/flags")
async def dev_flags_get(uid: str = Depends(require_uid)) -> dict[str, bool]:
    """The effective ``dev_panel`` flag (the app's Developer panel gate)."""
    import dev_flags

    return {"dev_panel": await asyncio.to_thread(dev_flags.current)}


@app.post("/dev/flags")
async def dev_flags_set(
    request: Request, body: DevFlagsRequest, uid: str = Depends(require_uid)
) -> dict[str, bool]:
    """Switch ``dev_panel`` live from the app's Developer panel. The password
    is checked server-side against ``DEV_PANEL_PASSWORD`` with a Firestore-backed
    lockout (see ``dev_flags``); the write lands in ``config/feature_flags`` and
    its ``app_config/dev_panel`` mirror, which the app listens to."""
    import dev_flags

    try:
        value = await asyncio.to_thread(
            dev_flags.set_dev_panel,
            get_db(), uid, body.password, body.dev_panel,
            ip=ratelimit.trusted_client_ip(request),
        )
    except dev_flags.NotConfigured as exc:
        raise HTTPException(
            status_code=503, detail="Developer flag switching is not configured."
        ) from exc
    except dev_flags.LockedOut as exc:
        raise HTTPException(
            status_code=429,
            detail="Too many wrong passwords. Try again later.",
            headers={"Retry-After": str(exc.retry_after)},
        ) from exc
    except dev_flags.BadPassword as exc:
        raise HTTPException(status_code=403, detail="Wrong password.") from exc
    return {"dev_panel": value}


@app.post("/webhooks/revenuecat", dependencies=[Depends(require_revenuecat)])
async def revenuecat_webhook(request: Request) -> dict[str, str]:
    """RevenueCat subscription events -> plan/pool changes (``billing``).
    Authenticated by the shared ``Authorization`` secret; idempotent on the
    event id; ``app_user_id`` is the Firebase uid. A user doc that doesn't
    exist yet answers 404 so RevenueCat redelivers."""
    try:
        payload = await request.json()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON.") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid payload.")
    try:
        status_text = await asyncio.to_thread(
            billing.handle_event, get_db(), payload, CONFIG
        )
    except billing.UnknownUser as exc:
        raise HTTPException(status_code=404, detail="Unknown user.") from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("revenuecat webhook failed")
        raise HTTPException(status_code=500, detail="Webhook failed.") from exc
    return {"status": status_text}


class FeedbackRequest(BaseModel):
    category: str = Field(default="thumbs_down", max_length=40)
    note: str = Field(default="", max_length=4000)
    quote: str = Field(default="", max_length=4000)
    session_id: str = Field(default="", max_length=128)


@app.post("/feedback")
async def submit_feedback(
    req: FeedbackRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One-tap / typed conversational feedback about Ayma's conduct (§15). Lands
    in the ``feedback`` bucket the weekly review aggregates; Ayma also writes
    here herself via ``record_feedback``."""
    fid = await asyncio.to_thread(
        feedback_ops.record,
        get_db(), uid, req.category, req.note,
        quote=req.quote, source="thumbs_down", session_id=req.session_id,
    )
    return {"ok": fid is not None, "id": fid}


class ProductFeedbackRequest(BaseModel):
    kind: Literal["bug", "idea"] = "bug"
    text: str = Field(min_length=1, max_length=4000)
    image_paths: list[str] = Field(default_factory=list, max_length=6)
    app_version: str = Field(default="", max_length=64)


@app.post("/product-feedback")
async def submit_product_feedback(
    req: ProductFeedbackRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Bug reports and feature requests from the Profile screen (§15). Ayma
    never reads this bucket — the dev team triages it by hand. Screenshots must
    already be uploaded under the caller's ``uploads/`` tree."""
    for p in req.image_paths:
        if p and not p.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_paths must be under the caller's uploads/ tree.",
            )
    fid = await asyncio.to_thread(
        feedback_ops.record_product,
        get_db(), uid, req.kind, req.text, req.image_paths,
        app_version=req.app_version,
    )
    return {"ok": fid is not None, "id": fid}


@app.get("/voice/presets")
async def voice_presets(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The selectable Gemini Live voice presets for the settings picker
    (§13.3). Includes the user's current choice."""
    import voices

    return {
        "presets": [
            {"name": n, "description": d}
            for n, d in voices.VOICE_PRESETS.items()
        ],
        "current": _ayma_voice_name(uid),
        "default": CONFIG.gemini_live_voice,
        # The accent/language is a free-text instruction, not a fixed list —
        # "Malayalam mixed with English", "a soft Southern US accent", etc.
        # current_language is whatever Ayma has as her default right now
        # (set here or learned from conversation via set_voice_preference).
        "current_language": _ayma_voice_language(uid),
        "language_examples": list(voices.LANGUAGE_EXAMPLES),
    }


@app.get("/voice/preview/{voice_name}")
async def voice_preview_endpoint(
    voice_name: str, uid: str = Depends(require_uid)
) -> dict[str, str]:
    """A short spoken "Hi, I'm Ayma…" sample in ``voice_name`` for the settings
    picker (§13.3). Generated once per preset via Gemini TTS, then cached in
    Storage — subsequent calls just return the cached clip's URL."""
    import voices
    import voice_preview

    if not voices.is_valid_voice(voice_name):
        raise HTTPException(status_code=404, detail="Unknown voice preset.")
    try:
        url = await voice_preview.preview_url(voice_name)
    except Exception as exc:  # noqa: BLE001 - surface TTS/storage failure as 502
        logger.exception("voice preview failed for %s", voice_name)
        raise HTTPException(
            status_code=502, detail="Could not generate a voice preview."
        ) from exc
    return {"url": url}


@app.get("/media/photos")
async def media_photos_list(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The current profile-photo grid (§8.3)."""
    import photo_ops

    return {"photos": await asyncio.to_thread(photo_ops.list_photos, get_db(), uid)}


class PhotoRef(BaseModel):
    media_id: str = Field(min_length=1, max_length=128)


def _media_record(uid: str, media_id: str) -> dict:
    """The stored ``users/{uid}/user_media/{media_id}`` doc, or ``{}`` if it
    can't be read."""
    try:
        snap = (
            get_db()
            .collection("users")
            .document(uid)
            .collection("user_media")
            .document(media_id)
            .get()
        )
        return snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception(
            "media record lookup failed for %s/%s", uid, media_id
        )
        return {}


def _resolve_new_photo(uid: str, media_id: str) -> tuple[str, list[float] | None, dict | None] | None:
    """A newly-grid-added media id resolved to
    ``(storage_path, embedding, attributes)`` for
    :func:`appearance.run_batch_photos`, or ``None`` when it has no storage
    path (shouldn't happen for an approved photo, but never block on it)."""
    import photo_notes

    record = _media_record(uid, media_id)
    storage_path = str(record.get("storage_path") or "").strip()
    if not storage_path:
        return None
    return (
        storage_path, photo_notes._vec(record.get("embedding")),
        record.get("attributes"),
    )


@app.post("/media/photos")
async def media_photos_add(
    req: PhotoRef,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Add an already-processed photo to the grid (§8.7 step 6). A single add
    is a batch of one — see ``POST /media/photos/batch`` for adding several
    photos picked in one action."""
    import photo_ops

    try:
        photos = await asyncio.to_thread(
            photo_ops.add_photo, get_db(), uid, req.media_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    resolved = await asyncio.to_thread(_resolve_new_photo, uid, req.media_id)
    background.add_task(
        appearance.run_batch_photos, get_db(), uid,
        [resolved] if resolved else [], source="add_photo",
    )
    return {"ok": True, "photos": photos}


class PhotoBatchRef(BaseModel):
    media_ids: list[str] = Field(min_length=1, max_length=9)


@app.post("/media/photos/batch")
async def media_photos_add_batch(
    req: PhotoBatchRef,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Add several already-processed photos to the grid in ONE call — the
    batched add-photos flow (§ appearance batching) onboarding and "add more
    photos" should use instead of looping ``POST /media/photos`` once per
    photo: picking N photos in one action analyses them together, as one
    update to the caller's single persistent Appearance report, instead of N
    separate per-photo runs."""
    import photo_ops

    result = await asyncio.to_thread(
        photo_ops.add_photos, get_db(), uid, req.media_ids
    )
    resolved = [
        r for r in (
            await asyncio.gather(
                *[
                    asyncio.to_thread(_resolve_new_photo, uid, mid)
                    for mid in result["added"]
                ]
            )
        ) if r is not None
    ]
    background.add_task(
        appearance.run_batch_photos, get_db(), uid, resolved,
        source="add_photos_batch",
    )
    return {
        "ok": True, "photos": result["photos"],
        "added": result["added"], "failed": result["failed"],
    }


@app.post("/media/photos/{media_id}/remove")
async def media_photos_remove(
    media_id: str,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Soft-remove a photo from the grid — the ``user_media`` doc, Storage
    file and embedding all stay (§8.3, §8.7 step 5)."""
    import photo_ops

    photos = await asyncio.to_thread(
        photo_ops.remove_photo, get_db(), uid, media_id
    )
    # The photo set changed — rebuild the physical-attributes record.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}


class PhotoOrder(BaseModel):
    media_ids: list[str] = Field(min_length=0, max_length=32)


@app.put("/media/photos/order")
async def media_photos_reorder(
    req: PhotoOrder,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Reorder the grid; ``media_ids[0]`` becomes the primary photo (§8.3)."""
    import photo_ops

    photos = await asyncio.to_thread(
        photo_ops.reorder_photos, get_db(), uid, req.media_ids
    )
    # Reordering changes which photos lead the physical-attributes read.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}


def _physical_attrs_payload(doc: dict | None) -> dict[str, object]:
    """Shape the stored ``physical_attributes/current`` doc for the client."""
    if not doc:
        return {
            "record": None,
            "fields": {},
            "photo_count": 0,
            "photo_paths": [],
            "summary": "",
            "id": "",
        }
    updated = doc.get("updated_at")
    reported = doc.get("reported_at")
    fields = doc.get("fields") or {}
    # A stable id for the re-openable report: the last explicit run's history
    # doc id when there is one, else "current".
    report_id = str(doc.get("report_id") or "") or "current"
    return {
        "record": {
            "fields": fields,
            "photo_count": int(doc.get("photo_count") or 0),
            "model": str(doc.get("model") or ""),
            "updated_at": updated.isoformat()
            if hasattr(updated, "isoformat")
            else None,
        },
        # Flat, source-tagged fields — the client renders these directly.
        "fields": fields,
        "photo_count": int(doc.get("photo_count") or 0),
        # Storage paths actually used to derive the record — "" (never a
        # crash) for a report stored before this field existed.
        "photo_paths": list(doc.get("photo_paths") or []),
        # A short human line Ayma can relay after a manual refresh.
        "summary": physical_attributes.summary(fields) if fields else "",
        "id": report_id,
        "created_at": (
            reported.isoformat()
            if hasattr(reported, "isoformat")
            else (updated.isoformat() if hasattr(updated, "isoformat") else None)
        ),
    }


def _physical_report_shape(rid: str, data: dict) -> dict[str, object]:
    """Shape a ``physical_reports`` history doc (or the ``current`` doc) as a
    re-openable report for ``GET /physical-attributes-report/{id}``."""
    fields = data.get("fields") or {}
    created = (
        data.get("created_at")
        or data.get("reported_at")
        or data.get("updated_at")
    )
    return {
        "id": rid,
        "fields": fields,
        "photo_count": int(data.get("photo_count") or 0),
        "photo_paths": list(data.get("photo_paths") or []),
        "summary": str(data.get("summary") or "")
        or (physical_attributes.summary(fields) if fields else ""),
        "model": str(data.get("model") or ""),
        "created_at": (
            created.isoformat() if hasattr(created, "isoformat") else None
        ),
    }


@app.get("/physical-attributes")
async def physical_attributes_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The caller's own structured physical-attributes record (§ physical
    attributes) — every field with its ``{value, source, confidence}``. Empty
    ``record`` when it hasn't been built yet."""
    doc = await asyncio.to_thread(physical_attributes.current, get_db(), uid)
    return _physical_attrs_payload(doc)


class PhysicalAttrsRefreshRequest(BaseModel):
    # Extra chat-uploaded photos (each under ``uploads/{caller}/``) folded into
    # the vision pass alongside the user's profile grid. Capped, best-effort.
    image_paths: list[str] = Field(default_factory=list, max_length=6)


@app.post("/physical-attributes/refresh")
async def physical_attributes_refresh(
    req: PhysicalAttrsRefreshRequest | None = None,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Force a re-run of the physical-attributes read for the caller (self
    only). Best-effort — returns the freshly stored record, or the existing one
    if there was nothing new to read. ``image_paths`` adds extra photos to the
    vision pass on top of the profile grid."""
    paths = [p.strip() for p in (req.image_paths if req else []) if p.strip()]
    for p in paths:
        if not p.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_paths must be under the caller's uploads/ tree.",
            )

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    extra: list[tuple[bytes, str, str]] = []
    for p in paths:
        try:
            data, mime = await asyncio.to_thread(media_embed.download_bytes, p)
        except Exception:  # noqa: BLE001 - a bad attachment just isn't used
            logger.warning("physical-attrs: unreadable extra image %s", p)
            continue
        if data:
            extra.append((data, mime or "image/jpeg", p))

    kwargs = {"extra_images": extra} if extra else {}
    # persist_report=True: an explicit, user-invoked run — append a history doc
    # and promote the private-wiki "Physical profile" section into the story.
    await physical_attributes.refresh(
        get_db(), uid, persist_report=True, **kwargs
    )
    doc = await asyncio.to_thread(physical_attributes.current, get_db(), uid)
    return {"ok": True, **_physical_attrs_payload(doc)}


@app.get("/physical-attributes-report/{report_id}")
async def physical_attributes_report(
    report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored physical-attributes report by id (from a chat
    ``[physical:<id>]`` marker or the Skills-screen history). ``current``
    returns the live record; 404 when the caller has no such report."""
    rid = report_id.strip()

    def _read() -> dict[str, object] | None:
        db = get_db()
        if rid and rid != "current":
            snap = (
                db.collection("users")
                .document(uid)
                .collection(physical_attributes.REPORTS_COLLECTION)
                .document(rid)
                .get()
            )
            if getattr(snap, "exists", False):
                return _physical_report_shape(rid, snap.to_dict() or {})
        doc = physical_attributes.current(db, uid)
        if not doc:
            return None
        return _physical_report_shape(
            str(doc.get("report_id") or "") or "current", doc
        )

    out = await asyncio.to_thread(_read)
    if out is None:
        raise HTTPException(status_code=404, detail="No such report.")
    return out


@app.get("/physical-attributes/history")
async def physical_attributes_history(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The caller's past physical-attributes runs, newest first — backs the
    per-skill history on the Skills screen. Each row re-opens as a report."""

    def _list() -> list[dict[str, object]]:
        from firebase_admin import firestore

        col = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(physical_attributes.REPORTS_COLLECTION)
        )
        try:
            snaps = list(
                col.order_by(
                    "created_at", direction=firestore.Query.DESCENDING
                )
                .limit(20)
                .stream()
            )
        except Exception:  # noqa: BLE001 - missing index / empty collection
            snaps = sorted(
                col.stream(),
                key=lambda s: str((s.to_dict() or {}).get("created_at") or ""),
                reverse=True,
            )
        out: list[dict[str, object]] = []
        for s in snaps:
            data = s.to_dict() or {}
            fields = data.get("fields") or {}
            created = data.get("created_at")
            out.append(
                {
                    "id": s.id,
                    "summary": str(data.get("summary") or ""),
                    "photo_count": int(data.get("photo_count") or 0),
                    "attribute_count": len(
                        physical_attributes.flat_mirror(fields)
                    ),
                    "created_at": (
                        created.isoformat()
                        if hasattr(created, "isoformat")
                        else None
                    ),
                }
            )
            if len(out) >= 15:
                break
        return out

    return {"reports": await asyncio.to_thread(_list)}


@app.get("/physical-attributes/schema")
async def physical_attributes_schema(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The physical-attribute field schema the report screen's tap-to-correct
    edit UI needs — each field's type (``enum`` / ``int`` / ``string``) and,
    for an ``enum`` field, its selectable values. Sourced straight from
    :func:`physical_attributes.field_schema`, itself read off
    ``explore_filter_schema.json`` — the same file ``fields()``/
    ``_enum_values()`` build off of for ``POST /physical-attributes/correct``
    validation, so the client is never carrying a second copy of the enum
    lists."""
    return {"fields": list(physical_attributes.field_schema())}


class PhysicalAttrCorrection(BaseModel):
    field: str
    value: str | int


class PhysicalAttrsCorrectRequest(BaseModel):
    corrections: list[PhysicalAttrCorrection] = Field(min_length=1, max_length=20)


def _validate_physical_attr_correction(field: str, raw_value: object) -> object:
    """Validate + coerce one user correction against the exact same
    enum/numeric/free-text rules ``physical_attributes.py`` enforces
    everywhere else (``fields()`` for the known field names, ``_coerce`` +
    ``_is_known`` for the value itself) — no parallel schema. Raises
    ``HTTPException(422)`` naming the offending field on any rejection."""
    if field not in physical_attributes.fields():
        raise HTTPException(
            status_code=422,
            detail=f"Unknown physical-attribute field: {field!r}",
        )
    coerced = physical_attributes._coerce(field, raw_value)
    if not physical_attributes._is_known(field, coerced):
        raise HTTPException(
            status_code=422,
            detail=f"Invalid value for {field}: {raw_value!r}",
        )
    return coerced


@app.post("/physical-attributes/correct")
async def physical_attributes_correct(
    req: PhysicalAttrsCorrectRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Let the caller directly set one or more physical-attribute fields on
    their own ``profile/main`` — the exact structured fields
    ``physical_attributes.resolve_stated()`` reads first and
    ``physical_attributes.merge()`` always prioritises over the photo-derived
    read (§ physical attributes). This is the direct path the report screen's
    tap-to-correct UI uses instead of relying on the indirect wiki-text scan.

    Every correction in the batch is validated (unknown field name, or a
    value that doesn't coerce to a known value for that field — e.g. an enum
    outside its allowed set, or a non-numeric height/weight) before anything
    is written; a single bad entry rejects the whole batch with a 422 naming
    it, so a partial correction is never silently half-applied.

    Schedules a background ``physical_attributes.refresh`` (mirrors every
    other write that changes what the physical-attributes record should say,
    e.g. a photo upload/reorder/remove) so ``physical_attributes/current``
    and the Explore mirror reflect the correction without the caller having
    to explicitly re-run a report."""
    accepted: dict[str, object] = {}
    for c in req.corrections:
        f = c.field.strip()
        accepted[f] = _validate_physical_attr_correction(f, c.value)

    def _write() -> None:
        get_db().collection("users").document(uid).collection(
            "profile"
        ).document("main").set(accepted, merge=True)

    await asyncio.to_thread(_write)
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "fields": accepted}


# --- Appearance: one unified read of the user's photos (§ appearance) ------


class AppearanceReportRequest(BaseModel):
    # Extra chat-uploaded photos (each under ``uploads/{caller}/``) folded into
    # the vision passes alongside the user's profile grid. Capped, best-effort.
    image_paths: list[str] = Field(default_factory=list, max_length=6)
    # Gate the face / physique sections — the client sets these from
    # ``GET /appearance/coverage`` but the run is never hard-blocked.
    want_face: bool = True
    want_body: bool = True


@app.post("/appearance/report")
async def appearance_report_run(
    req: AppearanceReportRequest | None = None,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Build the caller's unified Appearance report — structured attributes plus
    an honest face and physique analysis — and persist it. Respects the credit
    cap; ``image_paths`` adds chat attachments to the vision passes."""
    req = req or AppearanceReportRequest()
    paths = [p.strip() for p in req.image_paths if p.strip()]
    for p in paths:
        if not p.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_paths must be under the caller's uploads/ tree.",
            )

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    extra: list[tuple[bytes, str, str]] = []
    for p in paths:
        try:
            data, mime = await asyncio.to_thread(media_embed.download_bytes, p)
        except Exception:  # noqa: BLE001 - a bad attachment just isn't used
            logger.warning("appearance: unreadable extra image %s", p)
            continue
        if data:
            extra.append((data, mime or "image/jpeg", p))

    try:
        report = await appearance.run_appearance(
            get_db(),
            uid,
            extra_images=extra or None,
            want_face=bool(req.want_face),
            want_body=bool(req.want_body),
            source="endpoint",
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Appearance report failed: {exc}"
        ) from exc
    if report is None:
        raise HTTPException(
            status_code=400,
            detail="No photo to analyse — add a profile photo first.",
        )

    report_id = report.get("id", "")
    line = "Here's your Appearance report."
    if report_id:
        line = f"{line}\n\n[appearance:{report_id}]"
    try:
        chat_history.append(get_db(), uid, "ayma", line)
    except Exception:  # noqa: BLE001
        logger.exception("appearance: chat_history append failed for %s", uid)
    return {"ok": True, "report": report, "report_id": report_id}


@app.get("/appearance/report/{report_id}")
async def appearance_report_get(
    report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored Appearance report by id — from an ``[appearance:<id>]``
    chat marker or the Skills-screen history. ``current`` returns the latest;
    404 when the caller has no such report."""
    out = await asyncio.to_thread(
        appearance.get_report, get_db(), uid, report_id
    )
    if out is None:
        raise HTTPException(status_code=404, detail="No such report.")
    return out


@app.get("/appearance/history")
async def appearance_history_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The caller's Appearance runs newest-first, with the pre-merge
    ``face_reports`` / ``body_reports`` / ``physical_reports`` collections
    folded in as read-only ``legacy: true`` rows."""
    return {
        "reports": await asyncio.to_thread(appearance.history, get_db(), uid)
    }


@app.get("/appearance/coverage")
async def appearance_coverage_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """``{has_face_photo, has_body_photo}`` for the caller — derived from the
    shot-type tags on their current grid photos. Backs the Skills-screen
    coverage line; never hard-blocks a run."""
    return await asyncio.to_thread(photo_attrs.coverage, get_db(), uid)


class AppearanceFindingCorrectRequest(BaseModel):
    # A physical_attributes field name (e.g. "visible_tattoos"), or "face" /
    # "body" for those two composite reads.
    finding_id: str = Field(min_length=1, max_length=64)
    message: str = Field(min_length=1, max_length=2000)


@app.post("/appearance/finding/correct")
async def appearance_finding_correct(
    req: AppearanceFindingCorrectRequest,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Free-text correction for ONE finding in the caller's Appearance report
    (§ appearance corrections) — the user taps a claim and tells Ayma in
    plain language what's wrong, mirroring ``POST /story/edit``'s
    passage-chat pattern but committed immediately (see
    :func:`appearance.correct_finding`'s docstring for the full contract,
    including how an attribute correction becomes a durable ``stated`` value
    versus a face/body correction, which doesn't have that precedence slot).

    Returns ``{ok, reply, finding_id, value}`` or ``{usage_capped: true}``."""
    try:
        return await appearance.correct_finding(
            get_db(), uid, req.finding_id.strip(), req.message
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


# --- generic reports (§ generic reports) --------------------------------
#
# ONE block-shaped read + ONE tap-to-correct across every report type —
# Appearance, deep-dive/web-search, and Story in each of its three view
# modes ("story_private", "story_public", "story_ai_notes" — the last being
# "Ayma's Notes", confirmed to be a view mode of Story, not a separate
# feature). See report_hub.py for the report-type registry, ownership
# resolution, and the correction router; report_adapters.py for the
# read-only Firestore-shape -> block-shape transforms; report_blocks.py for
# the block schema itself. Nothing here changes any producer's storage or
# its own dedicated endpoints above — this is purely additive.


class ReportCorrectRequest(BaseModel):
    block_ids: list[str] = Field(min_length=1, max_length=50)
    scope: Literal["block", "section", "report"] = "block"
    # Free text for a real tap-to-correct turn, or one of the three fixed
    # quick-action phrases ("make public" / "make private" / "delete") a
    # client's quick-action buttons send verbatim — see
    # report_hub.QUICK_MAKE_PUBLIC et al. Both travel through this same
    # shape; report_hub tells them apart.
    message: str = Field(min_length=1, max_length=2000)


@app.get("/report/{report_type}/{report_id}")
async def report_get(
    report_type: str, report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Generic report reader: ``{title, sections, meta}`` for any report
    type via its adapter. Any authenticated caller may read whatever that
    report type already lets a non-owner read today (a deep-dive report on
    someone else, someone's public Story) — everything else 403s for a
    non-owner. 404 when there's nothing to report yet, or ``report_type``
    isn't recognised. See ``report_hub.get_report``."""
    if report_type not in report_hub.REPORT_TYPES:
        raise HTTPException(status_code=404, detail="No such report type.")
    try:
        return await asyncio.to_thread(
            report_hub.get_report, get_db(), report_type, report_id, uid
        )
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such report.")


@app.post("/report/{report_type}/{report_id}/correct")
async def report_correct(
    report_type: str,
    report_id: str,
    req: ReportCorrectRequest,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Generic tap-to-correct: one block, a whole section (every block that
    shares its heading), or the whole report, plus the user's own words —
    routed to whichever real producer function owns the referenced
    block(s) (``appearance.correct_finding``/``.clear_finding``,
    ``deep_dive.correct_finding``/``.dispute_*``, or a small composition of
    Story's own passage-privacy/edit/remove primitives). Only the report's
    OWNER may mutate it: a non-owner's attempt is rejected with 403 here,
    before any producer call. See ``report_hub.correct``."""
    if report_type not in report_hub.REPORT_TYPES:
        raise HTTPException(status_code=404, detail="No such report type.")
    try:
        return await report_hub.correct(
            get_db(), report_type, report_id, uid,
            block_ids=req.block_ids, scope=req.scope, message=req.message,
        )
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such report.")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/skill-runs")
async def skill_runs_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's profile-building skill-run ledger (§ skill runs) — when
    ``deep_dive`` and the unified ``appearance`` read last ran and how — plus
    the list still missing. Backs a later Skills screen.
    """
    def _read() -> tuple[dict, list[str]]:
        db = get_db()
        return skill_runs.get_all(db, uid), skill_runs.missing(db, uid)

    runs, missing = await asyncio.to_thread(_read)
    shaped = {
        skill: {
            "last_run_at": (
                rec.get("last_run_at").isoformat()
                if hasattr(rec.get("last_run_at"), "isoformat")
                else None
            ),
            "last_status": rec.get("last_status"),
            "source": rec.get("source"),
        }
        for skill, rec in runs.items()
    }
    return {"runs": shaped, "missing": missing}


@app.get("/completeness")
async def completeness_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's profile-completeness summary for the tree-based
    questionnaire (§ questionnaire revamp): overall ``score`` %, resolved
    ``intent`` branch, per-section progress, and the top unanswered nodes to
    pursue next. Served from the cached
    ``profile/main.completeness`` map, recomputed when absent or stale."""
    return await completeness.get_or_recompute(get_db(), uid)


@app.get("/questionnaire")
async def questionnaire_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's full intent-routed question tree with per-node coverage —
    ``{intent, intent_set, score, nodes: [{...node..., status, value,
    source}]}``. Drives the Flutter "Complete your profile" screen."""
    return await completeness.questionnaire_view(get_db(), uid)


class FcmTokenRequest(BaseModel):
    token: str = Field(min_length=1, max_length=4096)


@app.post("/notifications/token")
async def notifications_register_token(
    req: FcmTokenRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Register/refresh this device's FCM token (§7.2, §7.9 step 2)."""
    try:
        await asyncio.to_thread(
            notifications_ops.register_token, get_db(), uid, req.token
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/notifications/token/remove")
async def notifications_unregister_token(
    req: FcmTokenRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Drop a device token (sign-out or token rotation)."""
    await asyncio.to_thread(
        notifications_ops.unregister_token, get_db(), uid, req.token
    )
    return {"ok": True}


@app.post("/run-matching")
async def run_matching(uid: str = Depends(require_adult_uid)) -> dict[str, object]:
    """On-demand Pass 1 over the full pool (§5.3, §5.10 step 5). Writes
    ``users/{uid}/match_candidates/*``, feeds Explore. Heuristic-only — no
    Gemini call — so it's not credit-gated; the endpoint rate limit is the
    guard."""
    try:
        candidates = await asyncio.to_thread(
            matching.source_and_score, get_db(), uid, None
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Matching failed: {exc}"
        ) from exc
    return {"ok": True, "candidates": len(candidates)}


class MatchResponseRequest(BaseModel):
    response: Literal["accept", "reject"]


@app.post("/match/{match_id}/respond")
async def match_respond(
    match_id: str,
    req: MatchResponseRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """Accept or reject a scored match (§5.7, §14.3). Reject unmatches it;
    accept records this user's interest and flips to ``mutual_interest`` once
    both participants have accepted."""
    db = get_db()
    ref = db.collection(MATCHES_COLLECTION).document(match_id)
    snap = ref.get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="No such match.")
    data = snap.to_dict() or {}
    if uid not in (data.get("uids") or []):
        raise HTTPException(status_code=403, detail="Not your match.")

    if req.response == "reject":
        ref.set(
            {"status": "unmatched", "updated_at": _server_ts()}, merge=True
        )
        return {"ok": True, "status": "unmatched"}

    accepted = set(data.get("accepted_by") or [])
    accepted.add(uid)
    uids = list(data.get("uids") or [])
    both = accepted.issuperset(set(uids))
    already_mutual = data.get("status") == "mutual_interest"
    status = "mutual_interest" if both else data.get("status", "scored")
    ref.set(
        {
            "accepted_by": sorted(accepted),
            "status": status,
            "updated_at": _server_ts(),
        },
        merge=True,
    )
    if both and not already_mutual and len(uids) == 2:
        background.add_task(_notify_mutual_match, uids[0], uids[1])
    return {"ok": True, "status": status}


class CompatibilityRequest(BaseModel):
    other_uid: str = Field(min_length=1, max_length=128)
    # Re-score even if a result already exists (the "Recalculate" button).
    force: bool = False


def _match_label(name: str) -> str:
    return f"Checked your match with {name}"


def _match_chat_text(name: str, pct: int, match_id: str) -> str:
    """The chat event for a finished match: a one-line teaser with the score
    and the `[match:<id>]` sentinel (the client strips it and shows the match
    card that opens `/match/<id>`). Never the report itself (§ founder: keep
    report-result chat messages to a teaser + link)."""
    return f"Your match with {name} is ready: {pct}%.\n\n[match:{match_id}]"


async def _match_job(uid: str, other: str) -> None:
    """Score one pair and persist ``matches/{matchId}``, then push. Runs as a
    background task so it completes even if the app leaves. Never raises."""
    db = get_db()
    try:
        result = await matching_skill.score_pair(db, uid, other)
    except token_ledger.TokenCapExceeded:
        logger.info("match job skipped for %s (credit cap)", uid)
        return
    except Exception:  # noqa: BLE001
        logger.exception("match job failed for %s x %s", uid, other)
        return

    match_id = sorted_pair_key(uid, other)
    lo, hi = sorted((uid, other))
    ref = db.collection(MATCHES_COLLECTION).document(match_id)
    payload = {
        "uids": [lo, hi],
        "score": result["score"],
        "structured_score": result.get("structured_score"),
        "dimensions": result.get("dimensions") or [],
        "omitted_dimensions": result.get("omitted_dimensions") or [],
        "user_explanation": result["user_explanation"],
        "ai_explanation": result["ai_explanation"],
        "shared": result.get("shared") or [],
        "tensions": result.get("tensions") or [],
        "missing": result.get("missing") or [],
        "gate_failures": result.get("gate_failures") or [],
        "score_confidence": result.get("score_confidence"),
        "confidence_note": result.get("confidence_note") or "",
        "method": result.get("method") or "",
        "trust_flags": result["trust_flags"],
        "updated_at": _server_ts(),
    }
    if not ref.get().exists:
        payload["status"] = MATCH_STATUS_SCORED
        payload["scored_at"] = _server_ts()
    ref.set(payload, merge=True)
    # This is now the authoritative score for the pair (fresh on a first
    # score, and just as authoritative again on a "Recalculate") — drop any
    # stale Pass-1 heuristic entry either side still has so nothing else
    # (Explore included) can ever read a number older than this one.
    try:
        clear_stale_candidates(db, uid, other)
    except Exception:  # noqa: BLE001 - stale-candidate cleanup must never
        # block the match result itself from landing.
        logger.exception("match job: stale candidate cleanup failed for %s x %s", uid, other)

    pct = round(float(result["score"]) * 100)
    try:
        name = _profile_full_name(other) or "your match"
    except Exception:  # noqa: BLE001 - a name read must not lose the result
        logger.exception("match job: name read failed for %s", other)
        name = "your match"
    # Drop the result into the Ayma conversation as an event, the same way a
    # finished deep dive does (`_finish_deep_dive`): a short line plus the
    # `[match:<id>]` sentinel the chat renders as a tappable match-score card.
    # Whoever started the match (a tap on the profile, Recalculate on the
    # report, or Ayma tapping Run match for the user in a call or in text),
    # the result lands in the chat even though it finishes after that turn.
    try:
        chat_history.append(
            db, uid, "ayma",
            _match_chat_text(name, pct, match_id),
            tools=[_match_label(name)],
            subject_image=_deep_dive_subject_image(False, other) or None,
        )
    except Exception:  # noqa: BLE001 - the chat event must never block the push
        logger.exception("match chat event failed for %s", uid)
    try:
        await notifications_triggers.notify_skill_done(
            db, uid, f"Your match with {name} is ready — {pct}%.",
            f"match/{match_id}",
        )
    except Exception:  # noqa: BLE001
        logger.exception("match-done notification failed for %s", uid)


@app.post("/check-compatibility")
async def check_compatibility(
    req: CompatibilityRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_adult_uid),
) -> dict[str, object]:
    """On-demand Pass 2 for one pair (§5.3, §5.10 step 6). The scoring runs as
    a background job so it finishes even if the app is closed; the result lands
    in ``matches/{matchId}`` and a push points at the report."""
    other = req.other_uid.strip()
    if other == uid:
        raise HTTPException(status_code=400, detail="Cannot match with self.")
    match_id = sorted_pair_key(uid, other)

    # A match score is deterministic — the same two wikis always produce the
    # same numbers. So once a pair is scored, "Run match" just returns that
    # result; only "Recalculate" (force) re-runs it. This also stops repeated
    # taps from spending credits and spamming notifications.
    if not req.force:
        try:
            snap = get_db().collection(MATCHES_COLLECTION).document(
                match_id
            ).get()
            d = snap.to_dict() or {}
            if snap.exists and d.get("score") is not None:
                return {
                    "ok": True,
                    "queued": False,
                    "match_id": match_id,
                    "score": d.get("score"),
                    "shared": d.get("shared") or [],
                    "tensions": d.get("tensions") or [],
                    "explanation": (d.get("user_explanation") or {}).get(
                        uid, ""
                    ),
                }
        except Exception:  # noqa: BLE001
            logger.exception("check-compat cache read failed for %s", match_id)

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"ok": False, "usage_capped": True}

    background.add_task(_match_job, uid, other)
    return {"ok": True, "queued": True, "match_id": match_id}


@app.get("/match/{match_id}")
async def match_report(
    match_id: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """The shareable match report for one pair — score, what lines up / what
    doesn't, the note written to the caller, and both people's photos. 404 if
    the pair has never been scored."""
    from pair_key import uids_from_pair_key

    try:
        a, b = uids_from_pair_key(match_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if uid not in (a, b):
        raise HTTPException(status_code=403, detail="Not your match.")
    other = b if uid == a else a

    snap = get_db().collection(MATCHES_COLLECTION).document(match_id).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="Not scored yet.")
    d = snap.to_dict() or {}

    def _photo(u: str) -> str:
        return story._photo_url_safe(_primary_profile_photo_path(u)) or ""

    return {
        "match_id": match_id,
        "score": d.get("score"),
        "structured_score": d.get("structured_score"),
        "dimensions": d.get("dimensions") or [],
        "shared": d.get("shared") or [],
        "tensions": d.get("tensions") or [],
        "missing": d.get("missing") or [],
        "gate_failures": d.get("gate_failures") or [],
        "score_confidence": d.get("score_confidence"),
        "confidence_note": d.get("confidence_note") or "",
        "method": d.get("method") or "",
        "explanation": (d.get("user_explanation") or {}).get(uid, ""),
        "other": {
            "uid": other,
            "name": _profile_full_name(other),
            "photo": _photo(other),
        },
        "me": {"photo": _photo(uid)},
        "updated_at": (
            d["updated_at"].isoformat()
            if hasattr(d.get("updated_at"), "isoformat")
            else None
        ),
    }


@app.post("/cron/purge-deleted", dependencies=[Depends(require_cron)])
async def cron_purge_deleted() -> dict:
    """Permanent purge of soft-deleted accounts past the recovery window
    (§3.6, §3.10 step 10). Daily Cloud Scheduler."""
    return await asyncio.to_thread(
        account_purge.purge_expired, get_db(), _bucket()
    )


@app.post("/cron/match", dependencies=[Depends(require_cron)])
async def cron_match(user_limit: int | None = None) -> dict:
    """Scheduled two-pass matching over the lighter pool (§5.3, §5.10 step 7)."""
    return await matching_cron.run(get_db(), user_limit)


@app.post("/cron/ingest-backfill", dependencies=[Depends(require_cron)])
async def cron_ingest_backfill(user_limit: int = 200) -> dict:
    """Nightly safety net (§15): re-ingest conversations that were skipped
    while a user was out of credits, for any user that now has some."""
    return await backfill_ops.sweep(get_db(), user_limit)


@app.post("/cron/google-sync", dependencies=[Depends(require_cron)])
async def cron_google_sync(user_limit: int = 100) -> dict:
    """Periodic re-sync for every connected Google account, skipping anyone
    synced within ``CONFIG.google_sync_min_interval_hours``. Needs a daily
    Cloud Scheduler job hitting this with the ``X-Cron-Secret`` header."""
    import google_account

    return await google_account.sweep(get_db(), user_limit=user_limit)


@app.post(
    "/cron/physical-attributes-backfill",
    dependencies=[Depends(require_cron)],
)
async def cron_physical_attributes_backfill(user_limit: int = 200) -> dict:
    """Backfill (§ physical attributes): build the structured record for every
    user who has photos but no ``physical_attributes/current`` doc yet."""
    return await physical_attributes.backfill_missing(
        get_db(), user_limit=user_limit
    )


@app.post("/cron/photo-tags-backfill", dependencies=[Depends(require_cron)])
async def cron_photo_tags_backfill(user_limit: int = 200) -> dict:
    """Backfill shot-type tags (§ appearance): re-run the per-photo attribute
    pass for every approved ``user_media`` photo processed before shot-type
    tagging existed. Needs a Cloud Scheduler job hitting this with the
    ``X-Cron-Secret`` header."""
    return await photo_attrs.backfill_missing_tags(
        get_db(), user_limit=user_limit
    )


@app.post(
    "/cron/usable-for-body-resync", dependencies=[Depends(require_cron)]
)
async def cron_usable_for_body_resync(user_limit: int = 500) -> dict:
    """One-time fix (§ founder report — a sitting/clothed body photo and a
    cropped mirror selfie both got excluded from the physique report under
    the old "full-length / standing" rule): re-derive every already-tagged
    photo's ``usable_for_body`` from its already-stored ``shot_type`` — no
    Gemini calls, just a data fix, so existing photos benefit without a
    re-upload. One-off; not meant to be scheduled recurring."""
    return await photo_attrs.resync_usable_for_body(get_db(), user_limit=user_limit)


@app.post("/cron/skill-backfill", dependencies=[Depends(require_cron)])
async def cron_skill_backfill(user_limit: int = 100) -> dict:
    """Run every profile-building skill that has never run for a user, so each
    user's wiki gets fully populated (§ skill runs). Needs a daily Cloud
    Scheduler job hitting this with the ``X-Cron-Secret`` header."""
    return await skill_runs.sweep(get_db(), user_limit=user_limit)


@app.post("/cron/completeness-backfill", dependencies=[Depends(require_cron)])
async def cron_completeness_backfill(user_limit: int = 200) -> dict:
    """Force-recompute the questionnaire completeness score for every user with
    a profile (§ questionnaire revamp). Daily Cloud Scheduler job with the
    ``X-Cron-Secret`` header."""
    return await completeness.backfill(get_db(), user_limit=user_limit)


@app.post("/cron/reengage", dependencies=[Depends(require_cron)])
async def cron_reengage(user_limit: int | None = None) -> dict:
    """Scheduled re-engagement sweep (§7.1, §7.9 step 7). For each user idle
    past the threshold and out of backoff, Ayma writes one `raw_turns` message
    and a check-in push."""
    import reengagement

    return await reengagement.run(get_db(), user_limit)


@app.post("/cron/lint", dependencies=[Depends(require_cron)])
async def cron_lint(limit: int | None = None) -> dict:
    """Scheduled wiki lint (§2.3, §2.8 step 6). Cloud Scheduler hits this daily
    with the ``X-Cron-Secret`` header; ``?limit=`` caps the sweep for manual
    runs. Writes ``lint_flags`` onto affected pages, resolves nothing.

    Runs on the Gemini Batch API (``gemini_batch.py``) — cheap, and nobody is
    waiting on the result, so a tick may return ``{"status": "submitted"}``
    or ``{"status": "pending"}`` instead of the final tally; a later tick
    (this cron running again) applies the results once the job lands."""
    return await lint_all(get_db(), limit=limit)


@app.post("/cron/persona-evolution", dependencies=[Depends(require_cron)])
async def cron_persona_evolution(window_days: int = persona_evolution.WINDOW_DAYS) -> dict:
    """Daily crowd-feedback aggregation → base-persona evolution (§15 Part B).
    Cloud Scheduler hits this once a day with the ``X-Cron-Secret`` header.
    Aggregates the last ``window_days`` of ``feedback`` across every user,
    proposes a `lessons.md` update, and either applies it (non-critical, eval
    gate passes), or holds it on ``/admin/persona-changes`` for review
    (critical, or the eval gate fails it)."""
    return await persona_evolution.run(get_db(), window_days=window_days)
