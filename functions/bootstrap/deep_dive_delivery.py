"""Shared delivery tail + background runner for a web deep dive (§ deep dive).

A finished dive has two user-visible side-effects — the "Web research report"
chat card and a result push — plus the wiki/skill-run bookkeeping. This module
owns that tail so the ONE path serves both callers that need it:

* ``main.py``'s ``POST /deep-dive`` endpoint (text / the report screen's
  "Search again" button) runs :func:`run_job` as a FastAPI background task.
* the ``rerun_web_research`` skill (chat + voice) kicks the SAME background
  runner off through :func:`schedule_self_refresh` and returns immediately — so
  Ayma re-running the report never blocks (or hangs) the turn the way an inline
  ``deep_dive`` self-lookup did (founder bug 2026-11-03: asked in voice to
  "re-run the web search report", got a stuck "Searching the web…").

Importable in BOTH the Main API venv and the voice-agent venv — it pulls in
only plain modules (``chat_history``, ``notifications_triggers``,
``career_timeline``, ``skill_memory``, ``skill_runs``, ``deep_dive``,
``token_ledger``), never ``main`` or ``livekit-agents``.
"""

from __future__ import annotations

import asyncio
import logging

import career_timeline
import chat_history
import deep_dive
import notifications_triggers
import skill_memory
import skill_runs
import token_ledger

logger = logging.getLogger(__name__)

# A finished dive's two user-visible side-effects (the chat card + the result
# push) are Firestore/push writes that can hit a transient blip. Retry them a
# bounded number of times with a short growing backoff rather than surface a
# stuck/failed dive (founder: "auto-retry in the backend without the user
# having to click a button"). Small, so a genuine outage still gives up
# promptly.
_DELIVERY_ATTEMPTS = 3
_DELIVERY_BACKOFF = 1.5  # seconds, multiplied by the attempt number

# Strong references to the fire-and-forget refresh tasks :func:`schedule_self_refresh`
# spawns, so the event loop can't garbage-collect a running task (asyncio only
# holds a weak reference). Discarded when the task finishes.
_PENDING: set[asyncio.Task] = set()


def label(is_self: bool, name: str) -> str:
    """The past-tense tool/card label for a finished dive."""
    return "Researched yourself online" if is_self else f"Researched {name} online"


async def deliver_result(
    db,
    uid: str,
    *,
    chat_text: str,
    label: str,
    subject_image: str,
    notify: bool,
    who: str,
    deep_link: str,
) -> bool:
    """Deliver the user-visible side-effects of a finished dive — the chat card
    and (when ``notify``) the result push — with a bounded retry so a transient
    write failure self-heals in the background.

    Each side-effect lands at most once even across retries (re-appending would
    double the card), so the loop only re-attempts the parts still outstanding.
    The CARD is the in-app delivery (the user sees the report in chat) and alone
    decides success; the PUSH is a best-effort nudge that is retried but never
    gates the result, because it legitimately fails on a device with no valid
    FCM token (e.g. an emulator). Returns True once the card has landed. This
    path never meters: the dive's spend is recorded exactly once inside
    ``deep_dive.run`` and is deliberately kept off the retry loop so a retry can
    never double-charge."""
    card_done = False
    notify_done = not notify
    for attempt in range(1, _DELIVERY_ATTEMPTS + 1):
        try:
            if not card_done:
                chat_history.append(
                    db, uid, "ayma", chat_text,
                    tools=[label], subject_image=subject_image or None,
                )
                card_done = True
            if not notify_done:
                await notifications_triggers.notify_skill_done(
                    db, uid,
                    f"Your web search on {who} is ready.", deep_link,
                )
                notify_done = True
            return True
        except Exception:  # noqa: BLE001
            logger.exception(
                "deep-dive delivery attempt %d/%d failed for %s "
                "(card_done=%s notify_done=%s)",
                attempt, _DELIVERY_ATTEMPTS, uid, card_done, notify_done,
            )
            if attempt < _DELIVERY_ATTEMPTS:
                await asyncio.sleep(_DELIVERY_BACKOFF * attempt)
    # Retries exhausted. The CARD is the in-app delivery — the user sees the
    # report in chat — so it alone gates the run to `done`. The PUSH is only a
    # best-effort nudge and legitimately fails on a device with no valid FCM
    # token (e.g. an emulator), so a push-only failure must NOT fail the run or
    # hide the card. Report success on the card; warn if the push never landed.
    if card_done and not notify_done:
        logger.warning(
            "deep-dive push could not be delivered for %s after %d attempts; "
            "the card is in place, so the run is delivered (push is "
            "best-effort)",
            uid, _DELIVERY_ATTEMPTS,
        )
    return card_done


async def finish(
    db,
    uid: str,
    digest: dict,
    *,
    is_self: bool,
    target: str,
    name: str,
    notify: bool,
    subject_image: str = "",
) -> dict:
    """Shared tail for a deep dive (cache hit or fresh): persist, drop Ayma's
    summary into the transcript, optionally push, and shape the response.

    ``subject_image`` is the non-self subject's profile-photo URL (``""`` for a
    self dive, which is the only shape the skill uses); the caller computes it
    because only the Main API process can resolve a profile-photo path.
    ``"delivered"`` in the returned dict reports whether the user-visible CARD
    landed (the push is best-effort and never gates this), so the background
    job can wait to mark the run ``done`` until the card is actually in place."""
    # Only a lookup on *yourself* belongs in your wiki / Your Story. Research on
    # someone you're meeting is a private note for the chat + the reuse cache,
    # never your own story.
    #
    # These wiki / skill-run writes are NON-ESSENTIAL bookkeeping: a failure
    # here must never skip the user-visible card + push + the already-metered
    # spend that follow. (QA 00:41: an unguarded save_web_findings throw here
    # silently dropped the card and the notification while the report itself
    # still got written.) Guard loudly and carry on.
    if is_self:
        try:
            skill_memory.save_web_findings(db, uid, digest)
            skill_memory.promote(db, uid, "web_findings")
            skill_runs.record(
                db, uid, skill_runs.DEEP_DIVE,
                status=skill_runs.STATUS_OK, source="user", detail="self",
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "deep-dive wiki/skill-run bookkeeping failed for %s "
                "(continuing to card + notify)", uid,
            )
        # Best-effort: re-derive the structured career timeline now that fresh
        # web-research facts (possibly LinkedIn-derived — § career timeline)
        # are on hand. Never blocks/fails the deep-dive response itself.
        try:
            await career_timeline.extract(db, uid)
        except Exception:  # noqa: BLE001
            logger.exception("career-timeline extraction after self-dive failed for %s", uid)
    else:
        # The person researched is NOT the account holder, so none of the
        # digest belongs in the user's wiki. Drop a single behavioural
        # breadcrumb into the `interactions` page — the next wiki ingest folds
        # it (and any preference it reveals) into `interactions` / other pages.
        try:
            skill_memory.note_interaction(
                db, uid, f"ran a deep dive on {name}",
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive interaction breadcrumb failed for %s", uid)
    # A short teaser + the `[deep_dive:<id>]` sentinel below — never the
    # full summary/facts/links/photos dumped into the chat line itself
    # (§ founder: keep report-result chat messages to a teaser + link; the
    # findings live in the report screen).
    summary = deep_dive.teaser(digest)
    card_label = label(is_self, name)

    # A dive that actually found something is a re-openable report: tag the turn
    # with a `[deep_dive:<id>]` marker (same id as the deep_dives doc) so the
    # chat can show a "View research" card, on reload too.
    report_id = ""
    if digest.get("confidence") != "not_found" and (
        digest.get("facts") or digest.get("summary")
    ):
        report_id = deep_dive.dive_report_id("" if is_self else target, name)
    chat_text = f"{summary}\n\n[deep_dive:{report_id}]" if report_id else summary
    # Card + (optional) push are the user-visible payoff — deliver them with a
    # bounded retry and report whether they landed. Point the push at the
    # re-openable report when the dive produced one; a "not found" dive has no
    # report_id, so fall back to chat (that's where the "nothing found" summary
    # actually lives).
    who = "yourself" if is_self else name
    deep_link = f"deep_dive/{report_id}" if report_id else "chat"
    delivered = await deliver_result(
        db, uid, chat_text=chat_text, label=card_label,
        subject_image=subject_image, notify=notify, who=who, deep_link=deep_link,
    )
    return {
        "digest": digest,
        "summary": summary,
        "report_id": report_id,
        "is_self": is_self,
        "subject_image": subject_image,
        "tool_label": card_label,
        "delivered": delivered,
    }


async def run_job(
    db,
    uid: str,
    *,
    name: str,
    context: str,
    is_self: bool,
    target: str,
    force: bool,
    subject_image: str = "",
) -> None:
    """The slow part of a deep dive, run as a background task so it finishes
    even if the app is backgrounded or closed. Delivers via a push + the chat
    transcript. Never raises.

    Finishes the run doc the caller opened only once the user-visible CARD
    actually landed: ``done`` when the digest is stored AND the card was
    delivered, ``failed`` otherwise (digest failed, or it succeeded server-side
    but the card could not be delivered even after the bounded retry). The push
    is best-effort — it is retried but a final push failure never fails the run
    or hides the card (it legitimately fails on a device with no valid FCM
    token, e.g. an emulator). Marking ``done`` before delivery once let a run
    read ``done`` server-side while the user got no card and no notification (QA
    00:41); the spend, metered inside ``deep_dive.run`` before this point, is
    never re-charged by the delivery retry. A job killed before its ``finally``
    is caught by the stale-run timeout in :func:`deep_dive.run_status`."""
    report_id = deep_dive.dive_report_id("" if is_self else target, name)
    status = deep_dive.RUN_FAILED
    try:
        try:
            digest = await deep_dive.run(
                name, db=db, uid=uid, context=context,
                is_self=is_self, target_uid="" if is_self else target, force=force,
            )
        except token_ledger.TokenCapExceeded:
            logger.info("deep-dive job skipped for %s (credit cap)", uid)
            return
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive job failed for %s", uid)
            return
        # Digest stored and spend already metered inside run(). Deliver the
        # card (and best-effort push) BEFORE marking the run done — delivery has
        # its own bounded retry, so only flip to `done` once the card confirms
        # the user actually got the result. If the card can't be delivered,
        # leave the run `failed` (honest + recoverable: the report is written,
        # so it still opens from history) rather than a false `done`.
        delivered = False
        try:
            result = await finish(
                db, uid, digest, is_self=is_self, target=target, name=name,
                notify=True, subject_image=subject_image,
            )
            delivered = bool(result.get("delivered"))
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive job delivery failed for %s", uid)
        if delivered:
            status = deep_dive.RUN_DONE
        else:
            logger.error(
                "deep-dive job for %s/%s completed server-side but could not "
                "deliver the card after retries (push is best-effort); leaving "
                "the run recoverable (not `done`)", uid, report_id,
            )
    finally:
        await asyncio.to_thread(deep_dive.mark_run, db, uid, report_id, status)


def schedule_self_refresh(db, uid: str) -> tuple[str, str]:
    """Kick off a background re-run of the caller's OWN web-research report,
    exactly like the report screen's "Search again" button (``POST /deep-dive``
    with ``force``): mark the run ``running`` and spawn :func:`run_job` as a
    detached task, returning ``(report_id, name)`` straight away so the caller
    (the ``rerun_web_research`` skill, in chat OR voice) never blocks on the
    research. ``("", "")`` when the caller has no name on their profile yet —
    there's nothing to search.

    The task delivers the refreshed report to the chat transcript + a push when
    it lands, so the user gets the result whether or not they're still on the
    call. A credit cap is handled inside :func:`run_job` (the job no-ops); the
    caller checks the cap first to give an immediate honest reply."""
    name = deep_dive.profile_full_name(db, uid)
    if not name:
        return ("", "")
    context = deep_dive.profile_dive_context(db, uid, name) or ""
    report_id = deep_dive.dive_report_id(name=name)
    deep_dive.mark_run(db, uid, report_id, deep_dive.RUN_RUNNING)
    task = asyncio.create_task(
        run_job(
            db, uid, name=name, context=context,
            is_self=True, target="", force=True, subject_image="",
        )
    )
    _PENDING.add(task)
    task.add_done_callback(_PENDING.discard)
    return (report_id, name)
