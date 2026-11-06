"""Direct-messaging shape constants (ARCHITECTURE.md §6.6, §6.10, §6.11 step 1).

Firestore enforces nothing; behaviour is added in Steps 49–52.
"""

from __future__ import annotations

from pair_key import sorted_pair_key

DM_THREADS_COLLECTION = "dm_threads"
DM_MESSAGES_COLLECTION = "messages"  # under dm_threads/{threadId}

MESSAGE_TEXT = "text"
MESSAGE_PHOTO = "photo"
MESSAGE_VOICE = "voice"
MESSAGE_SHARED_PROFILE = "shared_profile"
# Attachment messages (§6.6): an uploaded image or arbitrary file. The storage
# path + download URL live in dedicated fields; ``body`` holds an optional
# caption. ``photo`` predates these and keeps its path-in-``body`` shape.
MESSAGE_IMAGE = "image"
MESSAGE_FILE = "file"
# An animated GIF (§6.6): same attachment shape as ``image`` (url/path/mime/
# name/size, optional ``body`` caption), kept as its own type so the client can
# render it as an animated GIF and label it accordingly. GIFs arrive either from
# the keyboard's GIF button (rich-content insertion) or the attach picker.
MESSAGE_GIF = "gif"
# A shared report snapshot (``POST /share``): the doc carries a ``report_share``
# map ({token, title, summary, card_url}) the app renders as an in-app card.
MESSAGE_SHARED_REPORT = "shared_report"

# Voice-message transcription lifecycle. Delivery is independent of this
# state: a voice message is readable/playable as soon as its message doc is
# written, while transcription runs afterwards in the background.
TRANSCRIPT_PENDING = "pending"
TRANSCRIPT_DONE = "done"
TRANSCRIPT_EMPTY = "empty"
TRANSCRIPT_ERROR = "error"
TRANSCRIPT_STATUSES = (
    TRANSCRIPT_PENDING,
    TRANSCRIPT_DONE,
    TRANSCRIPT_EMPTY,
    TRANSCRIPT_ERROR,
)

MESSAGE_TYPES = (
    MESSAGE_TEXT,
    MESSAGE_PHOTO,
    MESSAGE_VOICE,
    MESSAGE_SHARED_PROFILE,
    MESSAGE_IMAGE,
    MESSAGE_FILE,
    MESSAGE_GIF,
    MESSAGE_SHARED_REPORT,
)

# Message types that carry an attachment (path/url/mime/name/size) rather than
# putting everything in ``body``.
ATTACHMENT_MESSAGE_TYPES = (MESSAGE_IMAGE, MESSAGE_FILE, MESSAGE_GIF)


def thread_id(uid_a: str, uid_b: str) -> str:
    """``dm_threads`` doc id — sorted pair, same scheme as ``matches`` (§6.6)."""
    return sorted_pair_key(uid_a, uid_b)
