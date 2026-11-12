"""Consolidated Firestore schema (ARCHITECTURE.md §9.1, §9.5 step 1).

Single source of truth for collection paths, document ids and the field names
the backend shares. New code imports names from here rather than repeating
string literals; the per-domain modules (``dm_schema``, ``matching_schema``,
``notifications_schema``, ``wiki_schema``, ``pair_key``) remain and are
re-exported below so one import gives the whole picture.

`docs/SCHEMA.md` is the human-readable companion.
"""

from __future__ import annotations

import os

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
"""Temporary (``CONFIG.account_recovery_days``, default 30) quarantine for a
self-deleted account — ``account_ops.soft_delete``/``recover``. Still
self-service recoverable by the same signed-in session. Moved into
``ARCHIVED_ACCOUNTS`` (permanent) by ``account_purge.purge_expired`` once the
window closes."""
ARCHIVED_ACCOUNTS = "archived_accounts"
"""Permanent, admin-only home for a fully-deleted account (§ founder request
2026-09-20: "all of their info will still be saved ... but only admin should
have access"). Mirrors ``users/{uid}/...`` via ``schema.ACCOUNT_SUBCOLLECTIONS``
plus a few extra admin-audit subcollections (identity_mappings,
matches_snapshot, dm_threads_snapshot, feedback, product_feedback,
bug_reports — see ``account_ops.py``). Populated by
``account_purge.purge_expired`` when the ``DELETED_ACCOUNTS`` recovery window
closes; never auto-purged after that — retained indefinitely. Not reachable
via any user-facing endpoint; only ``admin_lookup.py`` reads it, gated by
``require_admin_password`` same as the rest of ``/admin/*``."""
ARCHIVED_KNOWLEDGE = "archived_knowledge"
"""``archived_knowledge/{uid}/{archive_id}/...`` — a timestamped snapshot
taken each time a *still-active* user runs "delete everything Ayma knows"
(``knowledge_wipe.wipe_knowledge``, ``POST /wiki/reset``). Unlike
``ARCHIVED_ACCOUNTS`` this can happen more than once per uid, hence the extra
``{archive_id}`` level. Admin-only, same access discipline as above."""
DELETED_USERS = "deleted_users"
"""Tiny top-level tombstone collection: ``deleted_users/{uid}`` exists (with
``deleted_at``) once a full account deletion has run. Cheap existence check
so a shared record with another user (matches, dm_threads — see
``account_ops.py``'s module docstring for the point-3 judgment call) can
render "deleted user" for a uid without needing to know whether that uid is
in ``DELETED_ACCOUNTS`` or already moved on to ``ARCHIVED_ACCOUNTS``. Never
cleared, not even by ``account_ops.recover`` during the grace window (a
recovering user simply stops looking deleted once the check also confirms
``users/{uid}`` exists again — see ``public_profile.build``)."""
INSTAGRAM_IDENTITIES = "instagram_identities"
"""Top-level Instagram-numeric-id -> Firebase uid reverse index (doc id = IG
numeric id, field ``uid``) — see ``instagram.py``'s module docstring. The
only custom (non-Firebase-native) identity-provider mapping in this codebase;
Google/Apple/phone/email sign-in rely on Firebase Auth's own built-in
federation instead of a Firestore mirror. Cleared by ``account_ops.soft_delete``
so a later "Sign in with Instagram" for the same IG account creates a brand
new uid + empty profile rather than reconnecting to the deleted one."""
ADMIN_CONFIG_COLLECTION = "admin_config"

GMAIL_EXCLUDE_DOMAINS_DOC = "gmail_exclude_domains"
"""admin_config/gmail_exclude_domains — a founder-editable ``domains`` list
field (see google_account.py) naming sender domains excluded from Gmail
*body* reading (the metadata-only Subject/From pass still covers them).
Edited directly in the Firestore console (or a future admin-dashboard
field) with no code deploy — same "hand-editable Firestore doc" shape as
``livekit_manual_cost`` above. Falls back to a built-in default list
(banks/payment/gov/OTP domains) when the doc doesn't exist yet."""

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
CHAT_MESSAGES = "chat_messages"  # AI-companion transcript (chat_history.py)
QUESTIONNAIRE = "questionnaire"  # completeness.py onboarding Q&A
COMPLETENESS_CACHE = "completeness_cache"  # completeness.py derived cache
PHOTO_NOTES = "photo_notes"  # photo_notes.py
APPEARANCE = "appearance"  # pointer at the latest unified report (doc "current")
APPEARANCE_REPORTS = "appearance_reports"  # appearance.py immutable reports
PHYSICAL_ATTRIBUTES = "physical_attributes"  # pointer (doc "current")
PHYSICAL_REPORTS = "physical_reports"  # physical_attributes.py immutable reports
FACE_REPORTS = "face_reports"  # legacy, still read/written by /face-report
BODY_REPORTS = "body_reports"  # legacy, still read/written by /body-report
DEEP_DIVES = "deep_dives"  # deep_dive.py — self dives + dives run on others
DEEP_DIVE_RUNS = "deep_dive_runs"  # deep_dive.py — queued-search status per report
OAUTH_TOKENS = "oauth_tokens"  # google_account.py import token
PERSONA = "persona"  # persona_snapshot.py — the AI-avatar snapshot (doc "avatar")
LOCATION_LOG = "location_log"  # location_log.py — opt-in stored visit log
ACTIVE_DATE_PLANS = "active_date_plans"  # date_plan.py — per-user both-approved
# plan index the background arrival geofence reads without opening each thread

# --- archive manifests (account_ops.py, account_purge.py, knowledge_wipe.py,
# admin_lookup.py) -----------------------------------------------------------
# Every subcollection under users/{uid} that makes up "the account" for full
# deletion/archive purposes (§ founder request 2026-09-20). Kept as one list
# so soft_delete/recover, the permanent-archive move in account_purge, and
# admin_lookup's "show me everything live" all agree on what a full account
# consists of — update this list, not each call site, when a new per-user
# subcollection is added elsewhere in the codebase.
ACCOUNT_SUBCOLLECTIONS = (
    PROFILE,
    WIKI_PAGES,
    RAW_TURNS,
    PENDING_QUESTIONS,
    USER_MEDIA,
    CHAT_MESSAGES,
    QUESTIONNAIRE,
    COMPLETENESS_CACHE,
    PHOTO_NOTES,
    APPEARANCE,
    APPEARANCE_REPORTS,
    PHYSICAL_ATTRIBUTES,
    PHYSICAL_REPORTS,
    FACE_REPORTS,
    BODY_REPORTS,
    DEEP_DIVES,
    DEEP_DIVE_RUNS,
    SKILL_RUNS,
    OAUTH_TOKENS,
    NOTIFICATIONS,
    NOTIFICATION_PREFS,
    MATCH_CANDIDATES,
    LIKES,
    EXPLORE_PASSED,
    PERSONA,
    LOCATION_LOG,
    ACTIVE_DATE_PLANS,
)
# One known two-level nesting: users/{uid}/wiki_pages/{pageId}/versions/{id}
# (story.py SECTION_VERSIONS). A plain single-level subcollection copy misses
# this, so archive code must recurse one extra level for these names.
NESTED_SUBCOLLECTIONS = {WIKI_PAGES: ("versions",)}

# The subset of ACCOUNT_SUBCOLLECTIONS that is "what Ayma knows" about a user
# (derived/learned content) as opposed to account/identity plumbing — credits
# (token_ledger fields live on the user doc, not a subcollection, and are
# never touched), oauth_tokens, notification_prefs, matching mechanics
# (match_candidates/likes/explore_passed), and the raw photo/profile content
# itself (user_media, profile) all deliberately excluded so "delete
# everything Ayma knows" resets Ayma's derived understanding of the user
# without breaking the account or forcing a re-upload of photos. See
# knowledge_wipe.py's module docstring for the full line-drawing rationale.
KNOWLEDGE_SUBCOLLECTIONS = (
    WIKI_PAGES,
    RAW_TURNS,
    CHAT_MESSAGES,
    PENDING_QUESTIONS,
    QUESTIONNAIRE,
    COMPLETENESS_CACHE,
    PHOTO_NOTES,
    APPEARANCE,
    APPEARANCE_REPORTS,
    PHYSICAL_ATTRIBUTES,
    PHYSICAL_REPORTS,
    FACE_REPORTS,
    BODY_REPORTS,
    DEEP_DIVES,
    SKILL_RUNS,
    PERSONA,
    # The opt-in location log is derived/learned understanding of the user, so
    # "Wipe what Ayma has learned?" clears it (and the patterns derived live
    # from it) along with the rest.
    LOCATION_LOG,
)
# KNOWLEDGE_FIELDS (small users/{uid} scalar/array fields the knowledge wipe
# also resets) is defined further down, after FIELD_TRUST_FLAGS /
# FIELD_FACE_VERIFICATION exist — see there.

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
MEDIA_EMBEDDING_MISSING = "embedding_missing"

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

# --- users/{uid}.biometric_consent (mandatory face-matching consent) -------
# Backend-authored record {consented_at, consent_version, region, source} —
# see biometric_consent.py. Not "what Ayma knows", so never in
# KNOWLEDGE_FIELDS: a knowledge wipe keeps it.
FIELD_BIOMETRIC_CONSENT = "biometric_consent"

# Small scalar/array fields on the users/{uid} doc itself (not subcollections)
# that are also "what Ayma has learned" and get reset by the knowledge wipe
# (see KNOWLEDGE_SUBCOLLECTIONS above for the subcollection half of the set).
KNOWLEDGE_FIELDS = (FIELD_TRUST_FLAGS, FIELD_FACE_VERIFICATION)

# --- profile/main fields ------------------------------------------------
PF_NAME = "name"
PF_BIRTHDATE = "birthdate"
PF_GENDER = "gender"
PF_INTERESTED_IN = "interested_in"
PF_LOCATION = "location"
PF_PHOTOS = "photos"  # [{media_id, order}] — the public profile grid
# Photos the owner removed from their PUBLIC profile but kept privately
# (§8.3 inline carousel: "remove from public"). Same ``[{media_id, order}]``
# shape as PF_PHOTOS. They vanish from every public reader (explore,
# public_profile, carousel, share page) because those read PF_PHOTOS only,
# but stay in the appearance/physical/attribute analysis pool via
# :func:`analysis_photo_entries`, and their ``user_media`` docs (embedding,
# storage) are untouched — so Ayma's face/body analysis still has them. This
# is the single shared visibility mechanism (the "hidden list"); a permanent
# "delete everywhere" drops the entry from here too and erases the media.
PF_HIDDEN_PHOTOS = "hidden_photos"
PF_PHOTO_ATTRS = "photo_attrs"
PF_PAUSED = "paused"
# "AI Avatar" consent: absent/True = allowed; False = opted out of any AI
# persona built from this user (date simulation, practice, MCP).
PF_AI_AVATAR = "ai_avatar_enabled"
PF_AYMA_VOICE = "ayma_voice_name"
# Voice STACK preference (§13.9, voice_catalog). "" = deploy-time default.
PF_AYMA_VOICE_MODE = "ayma_voice_mode"        # "realtime" | "cascade"
PF_AYMA_REALTIME_MODEL = "ayma_realtime_model"  # realtime-mode model id
PF_AYMA_CASCADE_BRAIN = "ayma_cascade_brain"    # cascade LLM id (synced from the ONE brain; see PF_AYMA_BRAIN_MODEL)
PF_AYMA_CASCADE_STT = "ayma_cascade_stt"        # cascade STT model id
PF_AYMA_CASCADE_TTS = "ayma_cascade_tts"        # cascade TTS model id
# Chosen voice id for a non-Gemini-preset voice (cascade TTS voice, or OpenAI
# realtime voice). Gemini-preset realtime voices use PF_AYMA_VOICE instead.
# "" = the provider's default voice.
PF_AYMA_TTS_VOICE = "ayma_tts_voice"
# Unified Brain preference (§13.10): the ONE user-selectable LLM vendor that
# drives ALL text surfaces (chat, matching, DM coach, translation), with a
# per-capability fallback to Gemini (web/vision always Gemini). ``gemini`` |
# ``meta`` (vendor name, not a model id). "" / absent = fall back to the
# per-surface ``LLM_PROVIDER_*`` env default (``config.brain_default`` is shown
# pre-selected in the UI). ONE BRAIN (founder, 2026-11-06): this selection
# drives the text surfaces AND the voice cascade LLM (mapped to a cascade
# brain id by ``voice_catalog.cascade_brain_for_unified`` and resolved at
# read time by ``voice_catalog.resolved_cascade_brain``, which supersedes
# any stored ``ayma_cascade_brain``). Read/written by ``/brain/preference``
# and the Models screen's one save, ``/models/preference``.
PF_AYMA_BRAIN_MODEL = "ayma_brain_model"
# The user's chosen IMAGE-generation model (Models screen, independent of the
# text Brain and the voice stack). One of ``image_gen`` catalog provider ids
# (``gemini-direct`` by default); "" / absent = the catalog default
# (``image_gen.default_model_id``). Read by ``image_gen.read_image_model_pref``
# and written by ``/image-model/preference``. A provider that is not configured
# on this deploy (e.g. ``xai-direct`` with no ``XAI_API_KEY``) is never offered
# or accepted, so a saved value always resolves to an available provider.
PF_AYMA_IMAGE_MODEL = "ayma_image_model"
# Which cloud hosts the voice agent for THIS user's next call (dual-cloud agent,
# ARCHITECTURE §1.1): "livekit" (LiveKit Cloud Agents — now the default, served
# by the hosted ``ayma-lk`` worker) or "cloudrun" (GCP Cloud Run, opt-out via
# the Developer screen). Read by ``main._voice_agent_cloud`` and threaded into
# the room dispatch; "" / absent = the default below. A user who explicitly set
# "cloudrun" still routes to Cloud Run. Written by ``/voice/agent-cloud``.
# ROLLBACK: flip VOICE_AGENT_CLOUD_DEFAULT back to "cloudrun" and redeploy
# ayma-api (global), or set a user's ``voice_agent_cloud`` pref (instant, no
# deploy). This single constant is the one authoritative default.
PF_AYMA_VOICE_CLOUD = "voice_agent_cloud"
VOICE_AGENT_CLOUDS = ("cloudrun", "livekit")
# Env-overridable so each environment can pick its own default without a code
# change: PROD (env unset) stays "livekit" (the hosted ``ayma-lk`` worker);
# STAGING sets VOICE_AGENT_CLOUD_DEFAULT=cloudrun so rooms route to the staging
# Cloud Run worker (its separate LiveKit project has no ``ayma-lk``). An invalid
# value falls back to "livekit". This is still the one authoritative default.
VOICE_AGENT_CLOUD_DEFAULT = os.getenv(
    "VOICE_AGENT_CLOUD_DEFAULT", "livekit"
).strip().lower()
if VOICE_AGENT_CLOUD_DEFAULT not in VOICE_AGENT_CLOUDS:
    VOICE_AGENT_CLOUD_DEFAULT = "livekit"
# The user's own LinkedIn profile URL, given with their consent (§ Your Story
# career timeline) — never scraped, never fetched via an unofficial API. When
# set, a self deep-dive hands it to Gemini's `url_context` tool directly.
PF_LINKEDIN_URL = "linkedin_url"


def analysis_photo_entries(prof: dict) -> list[dict]:
    """Every photo the appearance / physical-attributes / photo-attribute
    analysis should see for ``prof``: the public grid (:data:`PF_PHOTOS`)
    first, then the removed-from-public ones (:data:`PF_HIDDEN_PHOTOS`), each
    renumbered 0..n-1 so public photos always lead. Removing a photo from the
    public profile therefore never drops it from analysis (§8.3)."""

    def _clean(key: str) -> list[dict]:
        return [p for p in (prof.get(key) or []) if isinstance(p, dict)]

    pub = sorted(_clean(PF_PHOTOS), key=lambda p: p.get("order", 0))
    hidden = sorted(_clean(PF_HIDDEN_PHOTOS), key=lambda p: p.get("order", 0))
    out: list[dict] = []
    for i, p in enumerate(pub + hidden):
        entry = dict(p)
        entry["order"] = i
        out.append(entry)
    return out


def user_doc(db, uid: str):
    """``users/{uid}`` DocumentReference."""
    return db.collection(USERS).document(uid)


def profile_doc(db, uid: str):
    """``users/{uid}/profile/main`` DocumentReference."""
    return user_doc(db, uid).collection(PROFILE).document(PROFILE_DOC)


def user_subcollection(db, uid: str, name: str):
    return user_doc(db, uid).collection(name)
