"""App-control tools: let Ayma *see* (voice) and *drive* (voice and text) the app.

``current_screen`` is voice-only — ``/chat`` already carries the screen the
user is on in its own request context. The five command tools
(:data:`COMMAND_SKILLS`) are registered in both the voice tool set
(:func:`skills.make_livekit_tools`) and the text chat tool set
(:func:`skills.make_session_tool_fns`): the Flutter client watches the command
doc whenever the app is foregrounded, not only during a call.

* ``current_screen`` — read the mirror that ``POST /voice/context`` keeps at
  ``users/{uid}/voice_context/current`` while a call is live, so Ayma knows
  what "them / this / here" refers to.
* ``open_screen`` / ``search_explore`` / ``open_profile`` / ``open_message_thread``
  / ``app_action`` — queue one UI command at ``users/{uid}/app_commands/pending``;
  the Flutter client (``AppCommandService``) watches that doc while the app is
  foregrounded (a live call or the chat page), performs the navigation/action, acks it at
  ``users/{uid}/app_commands/ack`` (``{id, ok}``), then deletes it.

Closing the loop (founder bug, 2026-09-26 — "I've opened your profile" while
the app never left the chat screen): a queued command is *intent*, not fact —
Firestore's watch stream on the phone can be down mid-call while the REST
mirror keeps working, so delivery is not guaranteed. Every command therefore
carries a unique ``id``, and each tool *waits* (bounded,
``_ACK_TIMEOUT_SECONDS``) for the client's ack of that exact id before
returning. Confirmed → ``navigated: …``; no ack in time → an explicit "the
app did NOT navigate" so the model tells the user the truth instead of
claiming success.

Every page and setting comes from ``app_registry.json`` (``app_registry``),
the single source of truth (founder bug, 2026-10-25: asked to open the "Your
profile is 59% complete" card, Ayma said no such page existed). ``open_screen``
opens any registered destination by key or the user's own words and sends the
client the route ``path`` to push; ``app_action`` changes any registered
setting; ``account_action`` runs sign out only after an
explicit confirmation in a later turn. ``ui_action`` operates any visible
control (tap, toggle, pick, slide, type, scroll, back) by the id the live
screen capture gave it, except what the registry's ``ui_action_policy``
denies (checked here on the label and again by the app on the real control).
Pages that need a specific person/record go through ``open_profile``,
``open_message_thread`` and ``open_match_report``. Delete account, withdraw
face-matching consent, every purchase and clearing what Ayma has learned
are navigate-only (founder rules, 2026-10-25 and the ACTION PARITY
exclusions config, 2026-11-06): the tool opens the page and the user acts
there themselves; no tool path here can delete the account, withdraw
consent, buy anything or clear her memory. ``play_voice_clip`` plays a
voice clip in the open chat (``app_control_playback``).
"""

from __future__ import annotations

# Layout (Tier-2 sweep item #8 — the 1,437-line monolith split by action
# family; this module stays the facade so every existing importer keeps
# working): ``app_control_queue`` (command-queue primitives, the shared tool-
# description loader and the honest-failure lines), ``app_control_mirror``
# (screen-mirror reads: current_screen, list_conversations, _describe),
# ``app_control_navigation`` (open_screen, search_explore, open_profile,
# open_message_thread, open_match_report), ``app_control_settings``
# (app_action), ``app_control_account`` (account_action) and
# ``app_control_ui`` (ui_action) and ``app_control_playback``
# (play_voice_clip). The re-exported private names below are the
# backward-compatibility surface: production (``main._describe``,
# ``dm_outreach.queue_command``) and the test suite reach them through this
# module, so they all stay importable from here.
from ._base import Skill
from .app_control_account import (
    _ACCOUNT_ACTION,
    _AFFIRMATIVE,
    _bind_account_action,
    _CONFIRM_TTL_SECONDS,
    _NEGATIVE,
    _pending_doc,
)
from .app_control_mirror import (
    _ago,
    _best_thread,
    _bind_current_screen,
    _bind_list_conversations,
    _CURRENT_SCREEN,
    _describe,
    _describe_screen,
    _dm_threads,
    _epoch,
    _is_fresh,
    _LAST_INTENT,
    _LIST_CONVERSATIONS,
    _mirrored_route,
    _NOTHING_OPEN,
    _STALE_SECONDS,
    _thread_strength,
    _VISIBLE_MAX_CHARS,
    _voice_context_doc,
)
from .app_control_navigation import (
    _bind_open_date_sim,
    _bind_open_match_report,
    _bind_open_message_thread,
    _bind_open_notification,
    _bind_open_practice_date,
    _bind_open_profile,
    _bind_open_screen,
    _bind_search_explore,
    detect_app_command,
    detect_launch_command,
    detect_profile_command,
    launch_clarification,
    run_app_command,
    run_profile_command,
    _FUZZY_NAME_THRESHOLD,
    _navigate,
    _navigate_only,
    _not_a_page,
    _OPEN_DATE_SIM,
    _OPEN_MATCH_REPORT,
    _OPEN_MESSAGE_THREAD,
    _OPEN_NOTIFICATION,
    _OPEN_PRACTICE,
    _OPEN_PROFILE,
    _OPEN_SCREEN,
    _resolve_path,
    _resolve_person,
    _run_report_action,
    _SCREENS,
    _SCREEN_LINES,
    _SEARCH_EXPLORE,
    _story_edit_redirect,
    _unavailable_reply,
)
from .app_control_queue import (
    _ack_doc,
    _await_ack,
    _await_result,
    _command_doc,
    _NOT_APPLIED,
    _NOT_NAVIGATED,
    _PROMPTS,
    _prompt,
    _queue_command,
    _RESULT_MAX_CHARS,
    _server_ts,
    queue_command,
)
from .app_control_settings import (
    _ACCENT_RESET_VALUE,
    _ACCENT_RESET_WORDS,
    _APP_ACTION,
    _apply_server_setting,
    _bind_app_action,
    _current_accent,
    _DEFAULT_ACCENT,
    _DEFAULT_ACCENT_NAME,
    _HEX_DIGITS,
    _LEGACY_ACTIONS,
    _normalise_value,
    _OFF,
    _ON,
    _resolve_accent,
    _setting_line,
)
from .app_control_playback import _bind_play_voice_clip, _PLAY_VOICE_CLIP
from .app_control_ui import (
    _bind_ui_action,
    _UI_ACTION,
    _UI_ID,
    _UI_ID_TYPES,
    _UI_OPS,
)

# How long a command tool waits for the client's ack before reporting the
# navigation as NOT having happened. The client acks the instant it executes
# (one snapshot delivery + one write), so a healthy round trip is well under
# a second; 6s rides out a watch-stream hiccup on a foregrounded-but-laggy
# app (founder bug 2026-11-01: "open Ayma's settings" resolved but hit the
# old 3s ack cutoff) without stalling the voice turn unnaturally long.
# Module-level so tests can shrink them.
_ACK_TIMEOUT_SECONDS = 6.0
_ACK_POLL_SECONDS = 0.25

# The scroll-to-end ui_action ops (scroll_to_bottom / scroll_to_top) are not a
# single snapshot scroll: the client repeats one scroll step until the list
# settles — up to ScreenCapture.kScrollToEndMaxSteps (50) steps, each waiting a
# settle frame (~0.45s), so a long/paginated list can take ~20-25s to finish
# before it can ack. The flat 6s cutoff above fired long before that ack,
# wrongly reporting the scroll as NOT applied while it was still running — and
# the model's follow-up turn then produced no reply at all (GW-SCROLL, build
# 2249). These ops get their own, still-bounded, wait so the real honest result
# ("Reached the bottom." / "Stopped after N scrolls…") comes back; if even this
# lapses the tool still returns the honest _NOT_APPLIED, never hanging.
_SCROLL_ACK_TIMEOUT_SECONDS = 30.0

# play_voice_clip acks only once playback has actually started; on a live
# call the client first waits out the announcement grace (~1.2s) and
# disconnects the voice session, so its ack legitimately lands later
# than a navigation's. Still bounded, so the turn never hangs.
_PLAYBACK_ACK_TIMEOUT_SECONDS = 15.0

# After a search_explore is acked, how long to wait for the client to report
# the loaded results (the feed is a network call after navigation).
_RESULT_TIMEOUT_SECONDS = 6.0

# Voice (where the tool can't see the transcript) minimum gap between asking
# and the confirmation — so a model can't ask and confirm inside one turn.
_CONFIRM_MIN_GAP_SECONDS = 4.0

# Shared by voice and text chat: each queues one command and waits for the
# client's ack of that exact id (or, for server-held settings, writes them).
COMMAND_SKILLS: list[Skill] = [
    Skill(declaration=_OPEN_SCREEN, bind=_bind_open_screen),
    Skill(declaration=_SEARCH_EXPLORE, bind=_bind_search_explore),
    Skill(declaration=_OPEN_PROFILE, bind=_bind_open_profile),
    Skill(declaration=_LIST_CONVERSATIONS, bind=_bind_list_conversations),
    Skill(declaration=_OPEN_MESSAGE_THREAD, bind=_bind_open_message_thread),
    Skill(declaration=_OPEN_NOTIFICATION, bind=_bind_open_notification),
    Skill(declaration=_OPEN_MATCH_REPORT, bind=_bind_open_match_report),
    Skill(declaration=_OPEN_DATE_SIM, bind=_bind_open_date_sim),
    Skill(declaration=_OPEN_PRACTICE, bind=_bind_open_practice_date),
    Skill(declaration=_APP_ACTION, bind=_bind_app_action),
    Skill(declaration=_ACCOUNT_ACTION, bind=_bind_account_action),
    Skill(declaration=_UI_ACTION, bind=_bind_ui_action),
    Skill(declaration=_PLAY_VOICE_CLIP, bind=_bind_play_voice_clip),
]

VOICE_SKILLS: list[Skill] = [
    Skill(declaration=_CURRENT_SCREEN, bind=_bind_current_screen),
    *COMMAND_SKILLS,
]
