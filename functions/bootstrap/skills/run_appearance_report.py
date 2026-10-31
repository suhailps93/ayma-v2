"""``run_appearance_report`` — run or re-run the user's unified Appearance
report (§ appearance).

The chat/voice counterpart to the app's Appearance screen "Recalculate" button
and ``POST /appearance/report``: one call rebuilds the caller's unified
Appearance report (structured attributes + an honest face and physique read)
over their current profile photos and persists it, then returns a short line
plus an ``[appearance:<id>]`` marker the client renders as the tappable report
card.

This is what "re-run / regenerate / recalculate my appearance report" resolves
to (``app_registry`` ``report_actions.rerun_appearance`` points here). Running
over an unchanged photo set reuses the last report rather than re-billing the
vision passes (see :func:`appearance.run_appearance`).

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import appearance as engine
import media_embed
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Run or re-run the user's own Appearance report (face + physique + "
    "attributes) over their profile photos, and persist it — on an explicit "
    "ask to run / re-run / regenerate / recalculate / refresh their appearance "
    "or looks report. This is the ONLY way to actually (re)run it; open_screen "
    "my_appearance only opens the existing report."
)

DECLARATION = {
    "name": "run_appearance_report",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_PHOTO = (
    "add at least one profile photo and I'll put together your appearance report"
)


def _bind(db, uid: str, *, image_path: str = "") -> Callable[..., Awaitable[str]]:
    async def run_appearance_report() -> str:
        try:
            token_ledger.check(uid)
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(
                token_ledger.CONTEXT_APPEARANCE
            )
        extra: list[tuple[bytes, str, str]] = []
        if image_path:
            try:
                data, mime = media_embed.download_bytes(image_path)
                if data:
                    extra.append((data, mime or "image/jpeg", image_path))
            except Exception:  # noqa: BLE001 - a bad attachment just isn't used
                extra = []
        try:
            report = await engine.run_appearance(
                db, uid, extra_images=extra or None, source="chat_tool"
            )
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(
                token_ledger.CONTEXT_APPEARANCE
            )
        if report is None:
            return _NO_PHOTO
        rid = str(report.get("id") or "")
        line = "Done — I've refreshed your Appearance report."
        return f"{line}\n\n[appearance:{rid}]" if rid else line

    return run_appearance_report


SKILL = Skill(declaration=DECLARATION, bind=_bind)
