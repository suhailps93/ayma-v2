"""``open_replied_photo`` — pull the photo the user replied to in this chat.

Swipe-reply used to quote only text: a reply to a photo message carried
the quote's words and nothing about the photo, so Ayma answered about a
photo she could not see (or from whatever the conversation was about
before). The client half (fleet/swipe-reply-images) now carries the photo
by reference only — a ``[photo ref:<url>]`` marker inside the existing
``[Replying to …: "…"]`` wire prefix (founder's reference-not-content
rule, 2026-11-09) — and this tool is the pull: bound server-side to that
exact reference (``main._prepare_chat`` →
``skills.make_session_tool_fns``'s ``reply_photo_ctx``), never taken from
the model, so it can only ever open the one photo the user actually
replied to in this conversation.

Why a tool at all, when a report (``open_shared_report``) is text the
tool can simply return? A photo is not text, and the tool channel hands
results back as strings — so the fetch returns an
:class:`~tool_media.ImageToolResult`: the loops that know the marker
(``gemini.py``, the LiveKit brains in ``llm_provider.py``) attach the
bytes to the follow-up call as a real image part, the same way a photo
attached to the user's own message is presented. Loops that do not know
the marker degrade to the text line alone.

Access is the app's own rule for chat photos, enforced on the storage
path: a chat photo lives under ``uploads/{uid}/…`` (the user's own
uploads) or ``ayma_generated/{uid}/…`` (images Ayma made for that user) —
both namespaces are keyed by the owner's uid, which is exactly who may
see them. A reference naming any other path — another user's folder, a
different bucket, a foreign host — fails honestly, and so does a photo
that no longer exists: Ayma says she couldn't open it instead of guessing
what it showed.

Text chat only: swipe-reply is a composer affordance; voice already has
the live screen mirror. Mirrors ``open_shared_report``'s binding, gating
and honest-failure shape throughout.
"""

from __future__ import annotations

import logging
import re
from typing import Callable
from urllib.parse import unquote, urlparse

from ._base import Skill

logger = logging.getLogger(__name__)

# The client's reply prefix (transcript_store.replyWirePrefix): the quote
# rides at the head of the message as
# ``[Replying to <subject>: "<snippet>[ [photo ref:<url>]]"]`` followed by
# a newline and the user's own words. The snippet is the replied-to text
# (possibly empty for a photo-only message); the marker, when present, is
# inside the quotes. Same shape the client's own history parser reads.
_PREFIX_RE = re.compile(r'^\[Replying to ([^:]+): "(.*?)"\]', re.DOTALL)
_REF_RE = re.compile(r"\[photo ref:([^\]]+)\]")

_HONEST_FAILURE = (
    "error: I couldn't open that photo — tell the user plainly that you "
    "couldn't open the photo they replied to, and do not guess at what "
    "it shows from other photos or earlier conversation instead."
)

_DECLARATION = {
    "name": "open_replied_photo",
    "description": (
        "Open the photo the user replied to in this conversation (the "
        "quoted photo attached to their message). Call this FIRST, "
        "before answering anything about that photo: it attaches the "
        "actual photo so you can see it. If it says the photo could not "
        "be opened, tell the user plainly that you couldn't open the "
        "photo they replied to — never guess at what it shows from "
        "other photos or earlier conversation instead."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def extract_reply_photo_ref(message: str) -> tuple[str, str] | None:
    """``(subject, url)`` when ``message`` carries a photo reply
    reference, else ``None``. Text-only replies (no marker) and ordinary
    messages both return ``None`` — the historical prefix shape is
    untouched for them."""
    match = _PREFIX_RE.match(message or "")
    if match is None:
        return None
    ref = _REF_RE.search(match.group(2))
    if ref is None:
        return None
    url = ref.group(1).strip()
    if not url:
        return None
    return match.group(1).strip(), url


def storage_path_for_ref(uid: str, ref: str) -> str | None:
    """The storage object path ``ref`` names, when — and only when — it
    is a chat photo of ``uid``'s own conversation; else ``None``.

    Accepts the forms the client can carry: a Firebase Storage download
    URL for this app's bucket, a ``gs://`` URL for it, or a bare object
    path. The ownership rule is the namespace rule the app itself serves
    by: the object must live under ``uploads/{uid}/`` (their uploads) or
    ``ayma_generated/{uid}/`` (images made for them). Anything else —
    another user's folder, another bucket, a foreign host, a path with
    traversal — is not theirs to open through a reply."""
    ref = (ref or "").strip()
    if not ref or not uid:
        return None
    path = ""
    if ref.startswith(("http://", "https://")):
        from config import CONFIG

        parsed = urlparse(ref)
        if parsed.hostname not in (
            "firebasestorage.googleapis.com",
            "storage.googleapis.com",
        ):
            return None
        # …/v0/b/<bucket>/o/<url-encoded path> — the bucket must be the
        # app's own, and the object path is the segment after /o/.
        marker = "/o/"
        idx = parsed.path.find(marker)
        if idx < 0:
            return None
        bucket = parsed.path[:idx].rsplit("/b/", 1)[-1]
        if bucket != CONFIG.storage_bucket:
            return None
        path = unquote(parsed.path[idx + len(marker):])
    elif ref.startswith("gs://"):
        from config import CONFIG

        bucket, _, rest = ref[len("gs://"):].partition("/")
        if bucket != CONFIG.storage_bucket or not rest:
            return None
        path = unquote(rest)
    elif "/" in ref and "://" not in ref:
        path = unquote(ref)
    if not path or ".." in path.split("/"):
        return None
    if path.startswith((f"uploads/{uid}/", f"ayma_generated/{uid}/")):
        return path
    return None


def fetch_replied_photo(uid: str, ref: str):
    """The replied-to photo for caller ``uid`` as an
    :class:`~tool_media.ImageToolResult`, or the honest-failure string.
    The one fetch path — the tool below and the tests both go through
    here."""
    from tool_media import ImageToolResult

    path = storage_path_for_ref(uid, ref)
    if path is None:
        return _HONEST_FAILURE
    try:
        from media_embed import download_bytes

        data, mime = download_bytes(path)
    except Exception:  # noqa: BLE001 - a read failure is a miss, said honestly
        logger.exception("open_replied_photo: fetch failed for %s", path)
        return _HONEST_FAILURE
    if not data:
        return _HONEST_FAILURE
    return ImageToolResult(
        text=(
            "opened the photo the user replied to — it is attached with "
            "this result; look at it and answer about what you actually "
            "see in it."
        ),
        image=(data, mime or "image/jpeg"),
        note="[the photo the user replied to]",
    )


def _bind(
    db,
    uid: str,
    *,
    url: str = "",
    subject: str = "",
) -> Callable[..., object]:
    def open_replied_photo():
        return fetch_replied_photo(uid, url)

    return open_replied_photo


SKILL = Skill(declaration=_DECLARATION, bind=_bind)
