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
    # Notes & profile
    "add_followup_question": "Noted a follow-up",
    "set_profile_field": "Updated your profile",
    "set_voice_preference": "Changed Ayma's voice",
    "record_feedback": "Noted your feedback",
    "report_bug": "Logged that for the team",
    "set_user_steering": "Saved a preference",
    "remember": "Remembered that",
    "read_dm_thread": "Read your messages with them",
    "propose_dm_message": "Drafted a message",
    "send_dm_message": "Sent your message",
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
    # Voice-only screen-awareness / navigation tools (skills/app_control.py)
    "current_screen": "Checked what's on your screen",
    "open_screen": "Opened that for you",
    "search_explore": "Searched Explore",
    "open_profile": "Opened their profile",
}


def tool_label(name: str) -> str:
    return TOOL_LABELS.get(name, name.replace("_", " ").capitalize())


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
    # Notes & profile
    "add_followup_question": "Making a note…",
    "set_profile_field": "Updating your profile…",
    "set_voice_preference": "Updating your voice…",
    "record_feedback": "Making a note of your feedback…",
    "report_bug": "Logging that for the team…",
    "set_user_steering": "Saving that…",
    "remember": "Updating her notes…",
    "read_dm_thread": "Pulling up your chat…",
    "propose_dm_message": "Drafting a message…",
    "send_dm_message": "Sending your message…",
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
}


def working_label(name: str) -> str:
    return WORKING_LABELS.get(name, "Working…")
