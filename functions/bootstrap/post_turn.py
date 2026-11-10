"""Session-end persistence of the raw turn window (§1.7 step 8) and, via
:func:`persist_and_ingest`, the wiki-memory extraction that rides on it
(§2.3, Step 21).

One Firestore doc per session at ``users/{uid}/raw_turns/{session_id}``,
upserted with the full interleaved voice+text window. It is written repeatedly
during a session (each ``/chat`` turn, the agent worker's shutdown, an explicit
client ``/post-turn``) but only ever as a single doc — "batch write the full
turn window once per session".
"""

from __future__ import annotations

import asyncio
import logging
import time

from firebase_admin import firestore

from transcript import Turn

logger = logging.getLogger("ayma.post_turn")


def persist_raw_turns(
    db: firestore.firestore.Client,
    uid: str,
    session_id: str,
    turns: list[Turn],
    voice_provider: str | None = None,
) -> None:
    """Upsert the session's raw-turn window. No-op for an empty window.
    ``voice_provider`` (voice sessions only) tags which backend ran the call."""
    if not uid or not session_id or not turns:
        return
    doc = (
        db.collection("users")
        .document(uid)
        .collection("raw_turns")
        .document(session_id)
    )
    entries: list[dict] = [{"role": t.role, "text": t.text} for t in turns]
    for entry, turn in zip(entries, turns):
        if getattr(turn, "created_at", None):
            entry["created_at"] = turn.created_at
    # A ``raw_turns`` doc holds the whole session as one ``turns`` array;
    # ``set(merge=True)`` replaces that array wholesale on every write. The
    # voice agent stamps each turn with its own ``created_at`` as it is spoken,
    # but the client's own best-effort ``/post-turn`` / ``/chat`` window carries
    # no per-turn times — so if the client's write lands last it would blank the
    # agent's stamps and collapse the whole session back onto the single
    # ``updated_at`` minute on reload (founder bug 2026-11-09). When this write
    # carries no per-turn times, carry forward any already stored, matched by
    # (role, text), so the agent's real per-turn times survive.
    if not any("created_at" in e for e in entries):
        prior = _stored_turn_times(doc)
        if prior:
            used: dict[tuple[str, str], int] = {}
            for entry in entries:
                key = (entry["role"], entry["text"])
                times = prior.get(key)
                if times:
                    idx = used.get(key, 0)
                    if idx < len(times):
                        entry["created_at"] = times[idx]
                        used[key] = idx + 1
    payload = {
        "turns": entries,
        "turn_count": len(turns),
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    if voice_provider:
        payload["voice_provider"] = voice_provider
    doc.set(payload, merge=True)


def _stored_turn_times(doc) -> dict[tuple[str, str], list[str]]:
    """The per-turn ``created_at`` values already stored on ``doc``, keyed by
    ``(role, text)`` (a list per key so repeated identical turns keep order).
    Best-effort — a read failure just means no times to preserve."""
    try:
        snap = doc.get()
    except Exception:  # noqa: BLE001 - never fail a persist over a read
        return {}
    if not getattr(snap, "exists", False):
        return {}
    out: dict[tuple[str, str], list[str]] = {}
    for turn in (snap.to_dict() or {}).get("turns") or []:
        created = turn.get("created_at")
        if not created:
            continue
        key = (str(turn.get("role", "")), str(turn.get("text", "")))
        out.setdefault(key, []).append(str(created))
    return out


async def persist_and_ingest(
    db: firestore.firestore.Client,
    uid: str,
    session_id: str,
    turns: list[Turn],
    voice_provider: str | None = None,
) -> None:
    """Session-end persistence, complete: the durable raw-turn window
    (:func:`persist_raw_turns`) *and* an attempt to fold this session into the
    wiki (``wiki_ingest.ingest``, §2.3). Both halves are best-effort
    — this never raises, so it is always safe as a shutdown/disconnect hook.

    Root cause this closes (real conversation, uid
    iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-20): during a live voice session,
    the user gave a real, substantive answer to a questionnaire narrative
    node right before the session's credits ran out. In-session wiki writes
    only happen via the rate-limited ``remember`` tool (deferred, at most
    once every few turns) or a clean client-initiated ``POST /post-turn`` —
    neither of which is guaranteed once a room closes abnormally (out of
    credits, dropped network, backgrounded/killed app). The voice agent
    worker's own shutdown hook (``agent.py``) *does* always fire on room
    close and already had the full turn window in hand, but historically
    called only :func:`persist_raw_turns` — the transcript was saved, but
    nothing ever tried to extract it into ``wiki_pages``, and it wasn't even
    flagged ``ingest_pending`` for the nightly backfill sweep to pick up
    later. The answer was acknowledged in-session by Ayma but never written
    anywhere durable, so the questionnaire node it belonged to
    (``past_relationship_narrative``) still read as unanswered next session
    and got re-asked from scratch.

    Shutdown-deadline safety (2026-10-25): the worker gets a bounded window
    after the room closes, and production logs showed the process being
    killed mid-ingest. So the order is critical-first: the raw window is
    written (off the event loop) and flagged ``ingest_pending`` *before* any
    LLM call, then the wiki ingest and the summary refresh run concurrently.
    The flag is cleared only after the ingest succeeds; if the process dies
    or the ingest fails first, the nightly ``backfill_ops`` sweep re-ingests
    the session instead of it being silently lost.
    """
    started = time.monotonic()
    timings: dict[str, int] = {}
    persisted = False
    try:
        await asyncio.to_thread(
            persist_raw_turns, db, uid, session_id, turns,
            voice_provider=voice_provider,
        )
        persisted = True
    except Exception:  # noqa: BLE001 - shutdown/disconnect hooks must not raise
        logger.exception("raw_turns persist failed for %s/%s", uid, session_id)
    timings["persist"] = _elapsed_ms(started)
    if not uid or not session_id or not turns:
        return
    import backfill_ops

    if persisted:
        await asyncio.to_thread(backfill_ops.mark_pending, db, uid, session_id)

    async def _ingest() -> None:
        step = time.monotonic()
        try:
            import wiki_ingest

            await wiki_ingest.ingest(db, uid, session_id, turns)
        except Exception:  # noqa: BLE001 - left ingest_pending for the sweep
            logger.exception(
                "wiki ingest failed for %s/%s, left pending", uid, session_id
            )
        else:
            await asyncio.to_thread(
                backfill_ops.clear_pending, db, uid, session_id
            )
        timings["ingest"] = _elapsed_ms(step)

    # Phase 2 (cost program 2026-09-26): keep the rolling summary fresh at
    # session end too, so a voice-heavy user's next seed carries their recent
    # sessions even if they never send a text message. Threshold-gated inside
    # (no LLM call unless ≥N un-summarized turns) and a no-op below level 2.
    async def _summary() -> None:
        step = time.monotonic()
        try:
            import context_opt

            if context_opt.summary_enabled():
                await context_opt.maybe_update_summary(
                    db, uid, turns, session_id=session_id
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "context summary update failed for %s/%s", uid, session_id
            )
        timings["summary"] = _elapsed_ms(step)

    await asyncio.gather(_ingest(), _summary())
    logger.info(
        "session-flush persisted uid=%s session=%s turns=%d persist_ms=%d "
        "ingest_ms=%d summary_ms=%d total_ms=%d",
        uid, session_id, len(turns), timings["persist"],
        timings.get("ingest", -1), timings.get("summary", -1),
        _elapsed_ms(started),
    )


def _elapsed_ms(since: float) -> int:
    return int((time.monotonic() - since) * 1000)
