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

TOOL_LABELS = {
    # Built-in grounding
    "web_search": "Searched the web",
    "url_context": "Read a link",
    "google_maps": "Checked the map",
    # Research / vision
    "deep_dive": "Researched them online",
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
    "search_explore": "Searched Explore",
    "open_profile": "Opened their profile",
    "open_message_thread": "Opened that conversation",
    "open_match_report": "Opened your match report",
    "app_action": "Did that for you",
    "account_action": "Handled your account request",
    "ui_action": "Did that on your screen",
}


def tool_label(name: str) -> str:
    return TOOL_LABELS.get(name, name.replace("_", " ").capitalize())


def outcome_label(name: str, result: object) -> str | None:
    """A label read from what the tool actually did, for the tools whose one
    name covers different outcomes; ``None`` means use :func:`tool_label`.

    ``send_dm_message`` previews or sends, so a fixed "Sent your message"
    chip showed even when nothing was sent (founder test 2026-10-26). A send
    shows the recipient and the exact text, the chat's "Sent" card."""
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
    "send_dm_message": "Working on your message…",
    # App control (skills/app_control.py)
    "open_screen": "Opening that…",
    "search_explore": "Searching Explore…",
    "open_profile": "Opening their profile…",
    "open_message_thread": "Opening the conversation…",
    "open_match_report": "Opening the match report…",
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
}


def working_label(name: str) -> str:
    return WORKING_LABELS.get(name, "Working…")
