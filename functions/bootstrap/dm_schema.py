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
MESSAGE_TYPES = (
    MESSAGE_TEXT,
    MESSAGE_PHOTO,
    MESSAGE_VOICE,
    MESSAGE_SHARED_PROFILE,
)


def thread_id(uid_a: str, uid_b: str) -> str:
    """``dm_threads`` doc id — sorted pair, same scheme as ``matches`` (§6.6)."""
    return sorted_pair_key(uid_a, uid_b)
