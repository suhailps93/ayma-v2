"""Consolidated Firestore schema (ARCHITECTURE.md §9.1, §9.5 step 1).

Single source of truth for collection paths, document ids and the field names
the backend shares. New code imports names from here rather than repeating
string literals; the per-domain modules (``dm_schema``, ``matching_schema``,
``notifications_schema``, ``wiki_schema``, ``pair_key``) remain and are
re-exported below so one import gives the whole picture.

`docs/SCHEMA.md` is the human-readable companion.
"""

from __future__ import annotations

# --- re-exports: the per-domain schema pieces -------------------------------
from dm_schema import (  # noqa: F401
    DM_MESSAGES_COLLECTION,
    DM_THREADS_COLLECTION,
    MESSAGE_TYPES,
    thread_id,
)
from matching_schema import (  # noqa: F401
    BLOCKS_COLLECTION,
    MATCH_CANDIDATES_COLLECTION,
    MATCH_STATUSES,
    MATCH_STATUS_BLOCKED,
    MATCH_STATUS_MUTUAL,
    MATCH_STATUS_SCORED,
    MATCH_STATUS_UNMATCHED,
    MATCHES_COLLECTION,
    TRUST_FLAG_TYPES,
    block_id,
)
from notifications_schema import (  # noqa: F401
    FCM_TOKENS_FIELD,
    LAST_PUSH_AT_FIELD,
    NOTIFICATION_PREFS_DOC,
    NOTIFICATION_TYPES,
    NOTIFICATIONS_COLLECTION,
    default_prefs,
)
from pair_key import sorted_pair_key, uids_from_pair_key  # noqa: F401

# --- top-level collections ------------------------------------------------
USERS = "users"
DELETED_ACCOUNTS = "deleted_accounts"

# --- users/{uid} sub-collections & the profile doc ------------------------
PROFILE = "profile"
PROFILE_DOC = "main"  # users/{uid}/profile/main
WIKI_PAGES = "wiki_pages"
RAW_TURNS = "raw_turns"
USER_MEDIA = "user_media"
PENDING_QUESTIONS = "pending_questions"
MATCH_CANDIDATES = MATCH_CANDIDATES_COLLECTION
LIKES = "likes"
EXPLORE_PASSED = "explore_passed"
NOTIFICATIONS = NOTIFICATIONS_COLLECTION
NOTIFICATION_PREFS = NOTIFICATION_PREFS_DOC  # sub-collection; doc id "main"

# --- account/auth metadata fields on users/{uid} ------------------------
FIELD_COMMUNITY = "community"
FIELD_SESSION_MODE = "session_mode"
FIELD_TRUST_FLAGS = "trust_flags"
FIELD_FCM_TOKENS = FCM_TOKENS_FIELD
FIELD_LAST_PUSH_AT = LAST_PUSH_AT_FIELD
FIELD_LAST_ACTIVE_AT = "last_active_at"
FIELD_INSTAGRAM_TOKEN = "instagram_access_token"
FIELD_REENGAGEMENT = "reengagement"

# --- profile/main fields ------------------------------------------------
PF_NAME = "name"
PF_BIRTHDATE = "birthdate"
PF_GENDER = "gender"
PF_INTERESTED_IN = "interested_in"
PF_LOCATION = "location"
PF_PHOTOS = "photos"  # [{media_id, order}]
PF_PHOTO_ATTRS = "photo_attrs"
PF_PAUSED = "paused"
PF_AYMA_VOICE = "ayma_voice_name"


def user_doc(db, uid: str):
    """``users/{uid}`` DocumentReference."""
    return db.collection(USERS).document(uid)


def profile_doc(db, uid: str):
    """``users/{uid}/profile/main`` DocumentReference."""
    return user_doc(db, uid).collection(PROFILE).document(PROFILE_DOC)


def user_subcollection(db, uid: str, name: str):
    return user_doc(db, uid).collection(name)
