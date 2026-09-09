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
MESSAGE_TYPES = (
    MESSAGE_TEXT,
    MESSAGE_PHOTO,
    MESSAGE_VOICE,
    MESSAGE_SHARED_PROFILE,
    MESSAGE_IMAGE,
    MESSAGE_FILE,
)

# Message types that carry an attachment (path/url/mime/name/size) rather than
# putting everything in ``body``.
ATTACHMENT_MESSAGE_TYPES = (MESSAGE_IMAGE, MESSAGE_FILE)


def thread_id(uid_a: str, uid_b: str) -> str:
    """``dm_threads`` doc id — sorted pair, same scheme as ``matches`` (§6.6)."""
    return sorted_pair_key(uid_a, uid_b)
