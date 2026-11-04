"""Live world-state refresh for the main voice call.

THE DEFECT (founder, live calls 2026-11-03): Ayma's picture of the world
went stale for the whole call. The screen mirror
(``users/{uid}/voice_context/current``) was only read when the model
happened to call the ``current_screen`` tool, so after any screen switch
she did not know what was on screen until the user told her to "read it".
Async completions had the same problem: a date simulation launched during
the call could finish — match report and all — while her context still
carried her own earlier "it's on its way" narration, so she kept saying
"let's see when the match report comes through" about a finished thing.

THE FIX: a per-turn refresh of a single tagged context item. On every
final user transcript (the same event every other per-turn mechanism in
``agent.py`` hangs off — mute control, the voice-command relay),
:class:`WorldStateRefresher` re-reads the world — the fresh screen mirror
plus the user's recent date-sim outcomes plus the on-screen person's
match-report readiness — and REPLACES one ``[Live context …]`` system
item in the agent's chat context via ``Agent.update_chat_ctx`` (the SDK
path that also forwards to a realtime session, so the cascade and Gemini
Live paths are both covered). Change-gated by fingerprint: when nothing
changed, the context is left untouched, so a quiet call pays a few small
Firestore reads per user turn and nothing else.

CALIBRATION (founder): this is context freshness, NOT a notification
feature. The refresher never speaks, never calls ``say`` /
``generate_reply``, and never announces a completion — it only makes sure
that when the user next asks, she answers from the current state. The
header on the item tells the model the same: background facts, never to
be read aloud, and newer than anything she said earlier in the call.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Callable

from livekit.agents import llm

import pair_key

from . import app_control_mirror as mirror

logger = logging.getLogger("ayma.world_state")

# The one context item this module owns. Identified by its content prefix
# so it can be replaced (never duplicated) on every refresh, and dropped
# entirely when the world goes quiet (mirror stale, no recent sims). The
# header doubles as the model's framing: background truth, not a script.
_STATE_PREFIX = "[Live context"
_STATE_HEADER = (
    "[Live context — auto-refreshed by the app every turn. Background "
    "facts only: never read this aloud, never announce it, and if it "
    "conflicts with anything said earlier in this call, THIS is the "
    "current truth.]"
)

# The mirror's full ``visible`` capture runs to ~3,200 chars; the standing
# note keeps a shorter slice — she can always call ``current_screen`` for
# the full read. The whole note is capped so the (single, replaced) item
# never becomes a growing block in a long call.
_VISIBLE_CAP = 900
_SUMMARY_CAP = 240
_STATE_MAX_CHARS = 1800

# Sims worth standing context: launched in the last day (a call talks
# about today's sims, not last month's), plus anything still running
# regardless of age. Newest first, at most this many lines.
_SIM_WINDOW_S = 24 * 3600
_SIMS_CAP = 3

# date_sim.py status values, as literals — importing date_sim would drag
# the whole sim engine into this module for three strings.
_SIM_RUNNING = "running"
_SIM_DONE = "done"
_SIM_ERROR = "error"


def _epoch(ts) -> float:
    """Seconds-since-epoch for a Firestore timestamp/datetime; 0.0 when the
    value is missing or not a timestamp (sorts such a row oldest)."""
    try:
        return float(ts.timestamp())
    except (AttributeError, TypeError, ValueError):
        return 0.0


def _screen_section(db, uid: str) -> tuple[str, dict]:
    """(describe-text, raw mirror data). The text is "" when the mirror is
    missing or stale — exactly the ``current_screen`` tool's own
    semantics, so the standing note never claims a screen the tool would
    deny."""
    try:
        snap = mirror._voice_context_doc(db, uid).get()
    except Exception:  # noqa: BLE001 - context is best-effort
        logger.exception("world-state mirror read failed for %s", uid)
        return "", {}
    data = snap.to_dict() if getattr(snap, "exists", False) else None
    if not data or not mirror._is_fresh(data.get("updated_at")):
        return "", {}
    data = dict(data)
    visible = str(data.get("visible") or "")
    if len(visible) > _VISIBLE_CAP:
        data["visible"] = visible[:_VISIBLE_CAP]
    return mirror._describe(data), data


def _sims_section(db, uid: str, now: float) -> tuple[list[str], set[str]]:
    """Lines for the user's recent date sims, newest first, plus the set
    of partner uids whose sim is DONE (so the report section does not
    repeat what a sim line already covered). Streams the per-user
    subcollection and sorts in Python — the same shape as ``_dm_threads``
    in the mirror module — because a user's sim count is small and each
    sim is a deliberate act."""
    try:
        snaps = list(
            db.collection("users").document(uid)
            .collection("date_sims").stream()
        )
    except Exception:  # noqa: BLE001 - context is best-effort
        logger.exception("world-state sims read failed for %s", uid)
        return [], set()
    rows = [
        (_epoch((s.to_dict() or {}).get("created_at")), s.to_dict() or {})
        for s in snaps
    ]
    rows.sort(key=lambda r: r[0], reverse=True)
    lines: list[str] = []
    done_uids: set[str] = set()
    for created, d in rows:
        status = str(d.get("status") or "").strip()
        if status not in (_SIM_RUNNING, _SIM_DONE, _SIM_ERROR):
            continue
        if status != _SIM_RUNNING and now - created > _SIM_WINDOW_S:
            continue
        persona = d.get("persona") or {}
        name = str(persona.get("name") or "").strip() or "someone"
        other = str(d.get("other_uid") or "").strip()
        if status == _SIM_RUNNING:
            lines.append(f"Agent date with {name}: still running.")
        elif status == _SIM_ERROR:
            lines.append(
                f"Agent date with {name}: failed — it did not finish."
            )
        else:
            verdict = d.get("verdict") or {}
            score = verdict.get("score")
            score_txt = (
                f" — compatibility score {score}/100"
                if score is not None else ""
            )
            summary = str(verdict.get("summary") or "").strip()[:_SUMMARY_CAP]
            line = (
                f"Agent date with {name}: FINISHED{score_txt}. "
                "The match report from it is ready."
            )
            if summary:
                line += f" Summary: {summary}"
            lines.append(line)
            if other:
                done_uids.add(other)
        if len(lines) >= _SIMS_CAP:
            break
    return lines, done_uids


def _report_ready(d: dict | None) -> bool:
    """The match-report completeness bar, mirroring main.py's
    ``_match_doc_is_complete``: a full-scorer doc (score + structured
    breakdown + method + the names-in-narrative marker), not a lite seed
    doc."""
    if not d or d.get("score") is None:
        return False
    return (
        d.get("structured_score") is not None
        and bool(d.get("method"))
        and d.get("names_in_narrative") is True
    )


def _subject_report_section(
    db, uid: str, mirror_data: dict, done_uids: set[str]
) -> str:
    """A ready line for the match report of the person on screen — only
    when no finished-sim line already covered that person."""
    subject = str(mirror_data.get("subject_uid") or "").strip()
    if not subject or subject == uid or subject in done_uids:
        return ""
    name = str(mirror_data.get("subject_name") or "").strip()
    try:
        snap = (
            db.collection("matches")
            .document(pair_key.sorted_pair_key(uid, subject))
            .get()
        )
    except Exception:  # noqa: BLE001 - context is best-effort
        logger.exception("world-state report read failed for %s", uid)
        return ""
    d = snap.to_dict() if getattr(snap, "exists", False) else None
    if not _report_ready(d):
        return ""
    who = name or "the person on screen"
    return f"Match report for {who}: ready (score {d.get('score')}/100)."


def build_world_state_text(
    db, uid: str, *, now: float | None = None
) -> str | None:
    """The standing live-context note for this user right now, or ``None``
    when the world has nothing fresh to say (stale mirror, no recent sims,
    no ready subject report) — the refresher then REMOVES its item rather
    than leaving stale state standing. Sync; callers thread it."""
    if not uid:
        return None
    now = time.time() if now is None else now
    screen, mirror_data = _screen_section(db, uid)
    sim_lines, done_uids = _sims_section(db, uid, now)
    parts = [screen] if screen else []
    parts.extend(sim_lines)
    report = _subject_report_section(db, uid, mirror_data, done_uids)
    if report:
        parts.append(report)
    if not parts:
        return None
    return (_STATE_HEADER + "\n" + "\n".join(parts))[:_STATE_MAX_CHARS]


def is_state_item(item) -> bool:
    """True for the one context item this module owns."""
    try:
        return str(getattr(item, "text_content", "") or "").startswith(
            _STATE_PREFIX
        )
    except Exception:  # noqa: BLE001
        return False


class WorldStateRefresher:
    """Keeps one ``[Live context …]`` item in the running agent's chat
    context synced with the world. ``poke()`` on each final user turn;
    pokes coalesce, and a refresh whose fingerprint matches what is
    already applied never touches the context. SILENT by construction:
    the only agent mutation is ``Agent.update_chat_ctx`` — no ``say``, no
    ``generate_reply``, no published events."""

    def __init__(
        self, *, db_factory: Callable, uid: str, get_agent: Callable
    ) -> None:
        self._db_factory = db_factory
        self._uid = uid
        self._get_agent = get_agent
        # None = never applied; "" = applied-and-empty (item removed).
        self._applied: str | None = None
        self._task: asyncio.Task | None = None
        self._pending = False

    def poke(self) -> None:
        """Schedule a refresh — fire-and-forget, coalescing with an
        in-flight one so a burst of turns costs one trailing re-read."""
        if self._task is not None and not self._task.done():
            self._pending = True
            return
        self._task = asyncio.ensure_future(self._run())

    async def _run(self) -> None:
        try:
            while True:
                self._pending = False
                await self.refresh_once()
                if not self._pending:
                    return
        except Exception:  # noqa: BLE001 - a refresh must never break the call
            logger.exception("world-state refresh failed for %s", self._uid)

    async def refresh_once(self) -> bool:
        """Re-read the world and, iff it changed, replace the state item.
        Returns True when the context was rewritten. A failed read keeps
        the last good state (returns False without clearing ``_applied``);
        a session whose agent is not up yet likewise retries on the next
        poke."""
        try:
            text = await asyncio.to_thread(
                build_world_state_text, self._db_factory(), self._uid
            )
        except Exception:  # noqa: BLE001
            logger.exception("world-state read failed for %s", self._uid)
            return False
        fingerprint = text or ""
        if fingerprint == self._applied:
            return False
        try:
            agent = self._get_agent()
        except Exception:  # noqa: BLE001 - session not started yet
            agent = None
        if agent is None:
            return False
        items = [it for it in agent.chat_ctx.items if not is_state_item(it)]
        if text:
            items.append(llm.ChatMessage(role="system", content=[text]))
        await agent.update_chat_ctx(llm.ChatContext(items))
        self._applied = fingerprint
        return True
