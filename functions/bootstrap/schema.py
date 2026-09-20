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
ADMIN_CONFIG_COLLECTION = "admin_config"
LIVEKIT_MANUAL_COST_DOC = "livekit_manual_cost"
"""admin_config/livekit_manual_cost — the founder's hand-entered "LiveKit
spend this month" figure (admin.py / infra_cost.py, §14.3), since LiveKit
Cloud's Analytics API (Scale-plan-only, verified unavailable on this
project's plan — see infra_cost.py) can't be read programmatically."""

# --- users/{uid} sub-collections & the profile doc ------------------------
PROFILE = "profile"
PROFILE_DOC = "main"  # users/{uid}/profile/main
WIKI_PAGES = "wiki_pages"
RAW_TURNS = "raw_turns"
USER_MEDIA = "user_media"
PENDING_QUESTIONS = "pending_questions"
SKILL_RUNS = "skill_runs"  # users/{uid}/skill_runs/{skill} — the skill-run ledger
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

# --- users/{uid}/user_media/{mediaId} fields & moderation status --------
# Written by photo_pipeline.process; read by photo_ops before a media id may
# enter the visible grid. "approved" is the only status that clears
# publication — "flagged"/"pending"/absent all fail closed (§8.4).
MEDIA_MODERATION_STATUS = "moderation_status"
MEDIA_STATUS_APPROVED = "approved"
MEDIA_STATUS_FLAGGED = "flagged"
MEDIA_STATUS_PENDING = "pending"

# --- users/{uid}.face_verification (onboarding/settings verification selfie) --
# A single small record on the user doc itself — deliberately NOT a
# user_media doc and NOT enumerated anywhere photos are: the verification
# selfie must never surface in the gallery, the profile grid, or Explore. It
# exists only to give `deep_dive_images.reference_embeddings_for` a more
# authoritative face-match reference than a profile photo.
FIELD_FACE_VERIFICATION = "face_verification"
FACE_VERIFICATION_EMBEDDING = "embedding"
FACE_VERIFICATION_STORAGE_PATH = "storage_path"
FACE_VERIFICATION_VERIFIED_AT = "verified_at"

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
# The user's own LinkedIn profile URL, given with their consent (§ Your Story
# career timeline) — never scraped, never fetched via an unofficial API. When
# set, a self deep-dive hands it to Gemini's `url_context` tool directly.
PF_LINKEDIN_URL = "linkedin_url"


def user_doc(db, uid: str):
    """``users/{uid}`` DocumentReference."""
    return db.collection(USERS).document(uid)


def profile_doc(db, uid: str):
    """``users/{uid}/profile/main`` DocumentReference."""
    return user_doc(db, uid).collection(PROFILE).document(PROFILE_DOC)


def user_subcollection(db, uid: str, name: str):
    return user_doc(db, uid).collection(name)
