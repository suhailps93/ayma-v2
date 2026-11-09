"""User-facing labels for Ayma's tools — shared between text chat
(``gemini.py``, §1.7 step 2) and voice (``agent.py``, §1.7 step 3) so both
surfaces describe the same tool call the same way instead of drifting.

``TOOL_LABELS`` is the persistent, past-tense label shown once a tool call has
finished ("Researched them online"); ``WORKING_LABELS`` is the live,
present-progressive label shown while it's running ("Researching them
online…"). Every registered skill (``skills.session_tool_declarations(story=
True, profile_edit=True)``) plus the three built-in grounding tools must have
an entry in BOTH maps — ``tests/test_gemini_tools.py`` enforces it — so no
surface ever falls back to a raw "Read dm thread" / "Working…" placeholder.
"""

from __future__ import annotations

# Sentinel outcome for a tool that ran but did NOT do the visible thing its
# chip would claim (e.g. open_message_thread found no conversation, or the app
# never navigated). Returned by :func:`outcome_label`; the callers suppress the
# success chip entirely — voice clears its "…ing" indicator and adds nothing,
# text adds nothing to ``tools_used`` (founder bug 2026-10-28: a false "Opened
# that conversation" chip showed even when the open failed).
NO_CHIP = "\x00no_chip"

# App-control tools whose chip must only show on a real navigation. Each
# returns a result beginning with ``navigated:`` on success and an honest
# failure line otherwise (``skills/app_control.py``).
_NAV_CHIP_TOOLS = frozenset(
    "open_message_thread open_screen open_profile open_match_report "
    "open_date_sim open_practice_date search_explore open_notification "
    "go_back".split()
)

# Public alias: agent.py's command-claim gate scopes its speech suppression
# to exactly the tools whose chips are outcome-gated here.
NAV_CHIP_TOOLS = _NAV_CHIP_TOOLS

# Image tools whose chip claims an image now exists in the chat
# ("Generated an image"). Each skill returns its success line ONLY when the
# image was actually generated and stored; every failure path (model refused,
# out of credits, save failed) returns a plain explanation sentence instead.
# Gate the chip on the exact success marker so a failed generation never
# shows a success chip (founder report 2026-11-09: the "Generated an image"
# chip showed on a reply whose generation had been refused server-side).
_IMAGE_CHIP_SUCCESS = {
    "generate_image": "done — sent the image in the chat",
    "edit_photo": "done — sent the edited photo in the chat",
}

TOOL_LABELS = {
    # Built-in grounding
    "web_search": "Searched the web",
    "url_context": "Read a link",
    "google_maps": "Checked the map",
    # Research / vision
    "deep_dive": "Researched them online",
    "rerun_web_research": "Re-ran your web research",
    "face_report": "Analysed the photo",
    "body_report": "Analysed the photo",
    "analyze_physical_attributes": "Read your photos",
    "run_appearance_report": "Refreshed your appearance report",
    "generate_image": "Generated an image",
    # Notes & profile
    "add_followup_question": "Noted a follow-up",
    "set_profile_field": "Updated your profile",
    "set_voice_preference": "Changed Ayma's voice",
    "record_feedback": "Noted your feedback",
    "report_bug": "Logged that for the team",
    "submit_feedback": "Drafted a feedback card",
    "set_user_steering": "Saved a preference",
    "remember": "Remembered that",
    "recall": "Checked her notes",
    "edit_story_entry": "Updated your story",
    "remove_story_entry": "Removed that from your story",
    "find_fact_source": "Traced where that came from",
    "read_dm_thread": "Read your messages with them",
    "list_conversations": "Checked your conversations",
    "send_dm_message": "Worked on a message",
    # Questionnaire skill
    "next_questions": "Checked what to ask next",
    "record_answer": "Saved your answer",
    "set_relationship_intent": "Set what you're looking for",
    # Your Story passage edits (chat opened from the story editor)
    "set_passage_privacy": "Updated what's private",
    "edit_passage": "Reworded that passage",
    "remove_from_profile": "Removed that from your profile",
    "set_section_privacy": "Updated what's private",
    "edit_career_timeline_entry": "Updated your timeline",
    "delete_career_timeline_entry": "Removed that from your timeline",
    # Public-profile section edits (chat opened to edit the profile)
    "list_profile_sections": "Looked over your profile",
    "edit_profile_section": "Updated your profile",
    "set_profile_section_visibility": "Updated what's public",
    # App-control tools (skills/app_control.py) — voice and text chat
    "current_screen": "Checked what's on your screen",
    "open_screen": "Opened that for you",
    "go_back": "Went back",
    "search_explore": "Searched Explore",
    "open_profile": "Opened their profile",
    "show_profile_photo": "Opened the profile photo",
    "open_message_thread": "Opened that conversation",
    "open_notification": "Opened your notification",
    "mark_all_notifications_read": "Marked all notifications read",
    "clear_all_notifications": "Cleared your notifications",
    "set_notification_filter": "Changed the notification filter",
    "mark_all_conversations_read": "Marked all conversations read",
    "play_voice_clip": "Played the voice clip",
    "open_match_report": "Opened your match report",
    "open_date_sim": "Opened the date simulation",
    "open_practice_date": "Opened your practice date",
    "app_action": "Did that for you",
    "account_action": "Handled your account request",
    "ui_action": "Did that on your screen",
    # Model stack (skills/set_model_stack.py)
    "set_brain": "Switched Ayma's brain",
    "set_voice_brain": "Switched Ayma's voice brain",
    "set_voice_mode": "Changed the voice mode",
    "set_realtime_model": "Changed the voice model",
    "set_stt": "Changed the speech-to-text",
    "set_tts": "Changed the text-to-speech",
    "reconnect_voice": "Reconnected the call",
    # Guided tour (skills/guided_tour.py)
    "start_guided_tour": "Started the tour",
    "explain_this_page": "Explained this page",
    "advance_guided_tour": "Moved to the next step",
    "skip_guided_tour": "Skipped to the next step",
    "stop_guided_tour": "Ended the tour",
    "back_guided_tour": "Moved to the previous step",
}


def tool_label(name: str) -> str:
    return TOOL_LABELS.get(name, name.replace("_", " ").capitalize())


# The guided-tour tools (skills/guided_tour.py). A turn that ran one of these is
# the Ayma-DRIVEN tour narrating a step — ephemeral guidance that must NOT be
# persisted to the chat history / raw_turns (founder, 2026-11-03: the step line
# "This is where you and I talk. Tap the message box…" was saved as a chat
# turn). Both surfaces detect a tour turn through these.
GUIDED_TOUR_TOOLS = frozenset(
    "start_guided_tour advance_guided_tour skip_guided_tour stop_guided_tour back_guided_tour explain_this_page".split()
)
# The past-tense labels those tools contribute to a turn's ``tools_used`` (what
# the text path sees at the persist point).
GUIDED_TOUR_LABELS = frozenset(TOOL_LABELS[n] for n in GUIDED_TOUR_TOOLS)


def is_guided_tour_turn(tools_used: list[str] | None) -> bool:
    """True when this turn ran a guided-tour tool (by label) — so its narration
    reply is ephemeral tour guidance, not a chat turn to persist."""
    return bool(tools_used) and any(
        label in GUIDED_TOUR_LABELS for label in tools_used
    )


def outcome_label(name: str, result: object) -> str | None:
    """A label read from what the tool actually did, for the tools whose one
    name covers different outcomes; ``None`` means use :func:`tool_label`, and
    :data:`NO_CHIP` means show no chip at all.

    ``send_dm_message`` previews or sends, so a fixed "Sent your message"
    chip showed even when nothing was sent (founder test 2026-10-26). A send
    shows the recipient and the exact text, the chat's "Sent" card.

    The app-control navigation tools (:data:`_NAV_CHIP_TOOLS`) only earn their
    "Opened …" chip on a real navigation — their result starts with
    ``navigated:``. Anything else (not found, the app didn't navigate) returns
    :data:`NO_CHIP` so no false success chip shows (founder bug 2026-10-28).

    The image tools (:data:`_IMAGE_CHIP_SUCCESS`) only earn their chip when
    the skill's result is its success line — the image really was generated
    and sent. Any other result returns :data:`NO_CHIP` (founder report
    2026-11-09)."""
    if name in _NAV_CHIP_TOOLS:
        if isinstance(result, str) and result.startswith("navigated:"):
            return None
        return NO_CHIP
    if name in _IMAGE_CHIP_SUCCESS:
        if isinstance(result, str) and result.startswith(
            _IMAGE_CHIP_SUCCESS[name]
        ):
            return None
        return NO_CHIP
    if name != "send_dm_message" or not isinstance(result, str):
        return None
    if result.startswith("SENT to "):
        return "Sent to " + result[len("SENT to "):].split(" (thread_id=", 1)[0]
    if result.startswith("Already sent"):
        return "Already sent"
    if result.startswith("PREVIEW ONLY"):
        return "Drafted a message"
    return "Message not sent"


# Live "…ing" status shown while a tool actually runs (streamed to the client).
WORKING_LABELS = {
    # Built-in grounding
    "web_search": "Searching the web…",
    "url_context": "Reading the page…",
    "google_maps": "Checking the map…",
    # Research / vision
    "deep_dive": "Searching the web…",
    "rerun_web_research": "Re-running your web research…",
    "face_report": "Analysing the photo…",
    "body_report": "Analysing the photo…",
    "analyze_physical_attributes": "Reading your photos…",
    "run_appearance_report": "Refreshing your appearance report…",
    "generate_image": "Generating an image…",
    # Notes & profile
    "add_followup_question": "Making a note…",
    "set_profile_field": "Updating your profile…",
    "set_voice_preference": "Updating your voice…",
    "record_feedback": "Making a note of your feedback…",
    "report_bug": "Logging that for the team…",
    "submit_feedback": "Drafting a feedback card…",
    "set_user_steering": "Saving that…",
    "remember": "Updating her notes…",
    "recall": "Checking her notes…",
    "edit_story_entry": "Updating your story…",
    "remove_story_entry": "Updating your story…",
    "find_fact_source": "Tracing where that came from…",
    "read_dm_thread": "Pulling up your chat…",
    "list_conversations": "Checking your conversations…",
    "send_dm_message": "Working on your message…",
    # App control (skills/app_control.py)
    "open_screen": "Opening that…",
    "go_back": "Going back…",
    "search_explore": "Searching Explore…",
    "open_profile": "Opening their profile…",
    "show_profile_photo": "Opening the profile photo…",
    "open_message_thread": "Opening the conversation…",
    "open_notification": "Opening your notification…",
    "mark_all_notifications_read": "Marking all notifications read…",
    "clear_all_notifications": "Clearing your notifications…",
    "set_notification_filter": "Changing the notification filter…",
    "mark_all_conversations_read": "Marking all conversations read…",
    "play_voice_clip": "Playing the voice clip…",
    "open_match_report": "Opening the match report…",
    "open_date_sim": "Opening the date simulation…",
    "open_practice_date": "Opening your practice date…",
    "app_action": "Changing that…",
    "account_action": "Checking your account request…",
    "ui_action": "Doing that on your screen…",
    # Questionnaire skill
    "next_questions": "Thinking what to ask…",
    "record_answer": "Noting that down…",
    "set_relationship_intent": "Noting what you want…",
    # Your Story passage edits
    "set_passage_privacy": "Updating your story…",
    "edit_passage": "Editing your story…",
    "remove_from_profile": "Editing your story…",
    "set_section_privacy": "Updating your story…",
    "edit_career_timeline_entry": "Updating your timeline…",
    "delete_career_timeline_entry": "Removing that from your timeline…",
    # Public-profile section edits
    "list_profile_sections": "Reading your profile…",
    "edit_profile_section": "Editing your profile…",
    "set_profile_section_visibility": "Updating your profile…",
    # Voice-only screen-awareness / navigation tools
    "current_screen": "Checking your screen…",
    "open_screen": "Opening that…",
    "search_explore": "Searching Explore…",
    "open_profile": "Opening their profile…",
    "open_message_thread": "Opening that conversation…",
    "app_action": "Doing that…",
    # Model stack (skills/set_model_stack.py)
    "set_brain": "Switching Ayma's brain…",
    "set_voice_brain": "Switching Ayma's voice brain…",
    "set_voice_mode": "Changing the voice mode…",
    "set_realtime_model": "Changing the voice model…",
    "set_stt": "Changing the speech-to-text…",
    "set_tts": "Changing the text-to-speech…",
    "reconnect_voice": "Reconnecting the call…",
    # Guided tour (skills/guided_tour.py)
    "start_guided_tour": "Starting the tour…",
    "explain_this_page": "Explaining this page…",
    "advance_guided_tour": "Moving to the next step…",
    "skip_guided_tour": "Skipping to the next step…",
    "stop_guided_tour": "Ending the tour…",
    "back_guided_tour": "Moving to the previous step…",
}


def working_label(name: str) -> str:
    return WORKING_LABELS.get(name, "Working…")
