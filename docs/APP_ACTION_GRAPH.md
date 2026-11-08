# Ayma App Action Graph

**Principle (founder, 2026-11-06): ACTION PARITY.** Any button or activity
the user can tap in the app, Ayma should be able to do too — and she should
know the full map of what exists. This document is that map: every screen,
every tappable control on it, and whether Ayma can do it today (and through
which command), cannot do it by design, or cannot do it yet (a GAP).

This is a living document. **New buttons/controls ship WITH their graph
entries and commands** — see "Keeping this graph alive" at the end.

## Status legend

| Status | Meaning |
|---|---|
| `COVERED <command>` | Ayma has a dedicated command/tool for this exact action. |
| `UI` | No dedicated command, but Ayma can operate the control on the live screen via `ui_action` (the semantics-tree executor in `screen_capture.dart`), subject to the exclusions config below. |
| `EXCLUDED` | User-only by founder rule. No command is wired, and the command layer refuses it. Enforcement is config-driven (see Exclusions). Ayma may open the page and tell the user which button to tap. |
| `AUTO` | Ambient/automatic client behaviour, not a user action Ayma operates (she can explain it). Mirrors the `operated_by_ayma: false` registry blocks. |
| `PRE-AUTH` | Screen exists before/without a signed-in Ayma session (sign-in, consent gate, onboarding). Ayma is not running there. |
| `GAP-n (size)` | User can tap it, Ayma cannot do it yet. Sized in the GAP register at the end. |

## How Ayma's coverage works (the four layers)

1. **Navigation — `open_screen`** opens every registered destination in
   `functions/bootstrap/app_registry.json` (30 destinations; the registry is
   the single source of truth, enforced against the router by
   `tests/test_app_registry.py` + `test/app_registry_test.dart`).
   Parameterized pages go through `open_profile`, `open_message_thread`,
   `open_match_report`, `open_date_sim`, `open_practice_date`,
   `open_notification`, and `search_explore` (Explore with a query).
2. **Settings — `app_action`** changes the registry's client-held settings
   (theme, accent colour, pause/resume matching, orb/nav-bar flutter) plus
   server/notification/partner settings, each calling the exact method its
   screen control calls. Model stack changes go through the
   `set_model_stack` family (`set_brain`, `set_voice_brain`, `set_voice_mode`,
   `set_realtime_model`, `set_stt`, `set_tts`, `reconnect_voice`) and
   `set_voice_preference`.
3. **On-screen controls — `ui_action`** operates any visible control the
   live screen capture lists (`[id] type "label" = state`): tap, long-press,
   set text, increase/decrease, scroll (incl. to top/bottom), dismiss, back.
   This is the parity workhorse for controls without a dedicated command.
4. **Dedicated skills** do the action directly without driving the UI:
   e.g. `send_dm_message`, `read_dm_thread`, `set_profile_field`,
   `edit_profile_section`, `edit_story_entry` / `remove_story_entry`,
   `edit_photo` / `delete_photo` / `update_photo_note`,
   `run_appearance_report`, `deep_dive` / `rerun_web_research`,
   `correct_*` / `remove_*` report-item tools, `next_questions` /
   `record_answer`, `submit_feedback` / `record_feedback`, `report_bug`,
   `generate_image`, the guided-tour family, and `play_voice_clip`
   (the pilot in this branch — see GAP-1).

Ayma's context: the live screen capture (`current_screen` in voice, the
`/chat` screen fields in text) lists the current screen's controls; the
The client command actions `AppCommandService` dispatches (the wire
form of the tools above) are: `navigate`, `search_explore`,
`open_profile`, `open_dm_thread`, `open_notification`, `app_action`,
`reconnect_voice`, `ui_action`, `tour_step`, `tour_end`,
`play_voice_clip`. The `app_action` names it executes are `dark_mode`,
`light_mode`, `system_theme`, `accent_color`, `pause_matching`,
`resume_matching`, `sign_out`.

tool descriptions are generated from `app_registry.json`, so the registry
— and now this graph — are what she knows.

## Exclusions (config-driven, founder 2026-11-06, final form)

Ayma must **NEVER** activate these, no matter how she is asked.
Enforcement lives in a maintained CONFIG + the command layer that
enforces it — never in her system prompt, which must not enumerate
the forbidden buttons (founder ruling, final form 2026-11-06,
superseding a brief same-day belt-and-suspenders prompt version):

* Config: `exclusions` in `functions/bootstrap/app_registry.json`
  (keys: `delete_account`, `purchase`, `clear_memory`), mirrored by the
  `ui_action_policy.deny` rules in the same file and by
  `kUiDenyRules` / `kUiDenyRoutes` in
  `ayma_flutter/lib/services/screen_capture.dart` (a test fails when the
  two drift).
* Prompt context: none of this is hardcoded into prompt text —
  `prompt.compose_system_prompt` renders the permitted-action context
  from this same registry at build time (`action_facts.py` +
  `prompts/action_facts.md`, the plan_facts pattern): the pages,
  settings and runnable account actions she may use, with the
  exclusions applied as a filter so a user-only action never appears
  as permitted. The block teaches the refusal behaviour generically;
  it never names an excluded button.
* Command layer: the config is load-bearing. Each item names the
  surfaces it blocks (`account_actions`, `deny_keys`); `account_action`
  checks `excluded_account_action_keys()` BEFORE dispatch and refuses
  a listed action however its handler field reads (opening the page
  and handing the user the exact button instead); `ui_action` refuses
  via the deny rules on both sides (backend `app_registry.ui_denial`
  and client `uiDenial`); purchase asks land on the navigate-only
  unavailable entry. A refusal always declines WITH an explanation
  (the entry's say line), never a silent failure.
* System prompt: `persona.md` ("Driving the app") carries only a
  generic line — Ayma acts only within her permitted action set, and
  a refused action is handed to the user with the page opened. The
  forbidden buttons are never named there.

| Excluded control | Where it lives | Ayma may |
|---|---|---|
| Delete account | Settings → Delete account (`/settings/delete-account`) | Open the page only |
| Subscribe / buy / upgrade / start trial / buy credits / switch plan (any purchase control) | Plan (`/profile/plan`), trial paywall (`/profile/usage/trial`), out-of-credits upsells | Open the Plan page only |
| Clear Ayma memory ("Wipe what Ayma has learned") | Ayma's settings (`/settings/ayma`) | Open the page only |
| Delete everywhere (photo) | Photo viewer → Remove dialog (`/profile/photos`) | Nothing — she may only soft-hide via `delete_photo` (the Remove from public path) |
| Block & report | Message thread menu | Nothing — she tells the user where it is |
| Dismiss all (profile suggestions) | Profile suggestions (`/profile/suggestions`) | Dismiss suggestions one by one only |

Also user-only by the same policy (pre-existing): withdrawing face-matching
consent, any consent/terms checkbox or "I agree", typing passwords, codes
or payment details.

**Founder-confirmed additions (2026-11-06, 19:41 PT):** the three
proposals formerly listed here are now wired exclusions in the table
above — "Delete everywhere" for a photo (irreversible delete; "Remove
from public" is reversible and stays operable), Block & report in a DM
thread (affects another person), and "Dismiss all" profile suggestions
(bulk-destructive). ("Clear all notifications" was on this list until
the founder ruled on 2026-11-06 that it is a priority gap to CLOSE,
not an exclusion — it is COVERED below via `clear_all_notifications`,
with Ayma confirming in conversation first because it cannot be
undone.)

---

## 1. App shell / nav bar (always visible)

| Control | Does | Ayma |
|---|---|---|
| Ayma tab | Go to the chat with Ayma (`/`) | COVERED `open_screen ayma` |
| Explore tab | Go to Explore (`/explore`) | COVERED `open_screen explore` |
| Messages tab | Go to Messages (`/messages`) | COVERED `open_screen messages` |
| You tab | Go to the You/Profile hub (`/profile`) | COVERED `open_screen profile` |
| Orb (tap / press-and-hold) | Start a live voice call with Ayma | COVERED — she *is* the call; starting one is user-initiated by definition (voice entry degrade is `AUTO`) |
| Notification bell | Open Notifications | COVERED `open_screen notifications` / `open_notification` |
| Connection banner | Shows offline/weak state; not tappable to change anything | `AUTO` (registry `connection_banner`) |
| Back (system / in-app) | Return to the previous page | COVERED `go_back` — one step of the session navigation history per ask (founder feedback item 15, staging): a modal or sheet is dismissed first, an active tour is never fought, and at the root she says why instead of failing silently |

## 2. Ayma chat (`/`) — `chat_screen.dart`, `chat_composer.dart`, `voice_note_composer.dart`

| Control | Does | Ayma |
|---|---|---|
| Composer text field | Type a message to Ayma | COVERED — it is addressed to her |
| Send button (with text/attachment) | Send the typed message | COVERED — addressed to her |
| Mic (tap) | Start/stop the live voice call | COVERED — she is the call |
| Mic (hold) / slide-left cancel / slide-up lock / pause / delete / send (voice-note composer) | Record and send a voice note | Recording is the user's voice: `AUTO` flow (registry `async_voice`); Ayma cannot record as the user |
| **Voice clip play/pause button (transcript turns)** | **Play a voice message in this chat** | **COVERED `play_voice_clip` — GAP-1 pilot, this branch.** During a live call: announce → disconnect → play → reconnect with context (see the pilot note under the GAP register) |
| Attachment / photo pick (library / camera / upload a photo) | Attach a photo to the chat | `UI` for the picker entry; the OS picker itself is the user's |
| Photo in a turn (tap) | Full-screen image viewer | `UI` |
| Photo in a turn (long-press) | Copy text / bubble long-press actions | `UI` (long_press) |
| Thumbs-down on an Ayma turn | Flag the reply for review | `UI` |
| Shared card in a turn (profile / conversation / match / report) | Open the shared thing | `UI`; also `open_profile` / `open_message_thread` / `open_match_report` |
| "Ask Ayma" on a shared/photo context, page-context chip (dismiss) | Scope the chat / clear the scope | `UI` |
| Scroll / scroll-to-bottom affordance | Read history | COVERED `ui_action` scroll ops |
| Out-of-credits card: Upgrade | Open Plan | `EXCLUDED` purchase control — open Plan only |
| Out-of-credits card: Keep exploring / dismiss | Dismiss the upsell | `UI` |
| Voice-call bar (live call): mute, end call, open full-screen call | Mute mic / hang up / expand | Mute + end: COVERED in-call (`end_call` voice action; mute is a call control she can be asked about — the toggle itself is `UI` on the call screen); expand is presentation-only |
| Guided-tour spotlight tap / "Skip tour" | Advance / end the Ayma-driven tour | COVERED — tour commands (`tour_step` acks, `tour_event`); starting one is `start_guided_tour` |

## 3. Voice call screen — `voice_call_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Close (X) | Collapse to chat (call keeps running) | `UI` (dismiss/back) |
| Mute toggle | Mute/unmute the mic | `UI` |
| "Unmute Ayma" quiet chip | End a user-requested quiet | COVERED `ui_action` — only when the user asks (prompt-guarded) |

## 4. Explore (`/explore`) — `explore_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Search field | Text-search people (server-parsed) | COVERED `search_explore`; also `ui_action` set_text |
| Filter chips (All / Liked / Mutual / Scored) and hair-colour filter dropdowns | Filter the feed | `UI` |
| Person card (tap) | Open their public profile | COVERED `open_profile`; also `UI` |
| "Ask Ayma about <name>" on a card | Open a scoped chat about them | `UI`; the chat itself is hers |
| Card photo carousel arrows/dots | Cycle their photos | `UI` |
| Load-more / "could not load more — tap to retry" | Page the feed / retry | `UI` (scroll triggers paging) |
| Retry (load error) | Reload the feed | `UI` |

## 5. Messages (`/messages`) and Matches

| Control | Does | Ayma |
|---|---|---|
| Conversation row (tap) | Open that DM thread | COVERED `open_message_thread` / `list_conversations` |
| Match row (tap) | Open the match report | COVERED `open_match_report` |
| Match request: Accept / Pass | Accept or pass a match request | `UI` |
| "New from Ayma" section rows | Open the suggested match | `UI` / `open_match_report` |
| Mark all read (header button, + confirm) — **added with the priority-gaps work** | Mark every conversation read | **COVERED `mark_all_conversations_read`** — founder feedback item 9's sibling ask on this list; the button appears only while a shown conversation is unread |

## 6. DM thread (`/dm/:threadId`) — `dm_thread_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Composer field + Send | Message the person | COVERED `send_dm_message` (one-confirmation flow) — she drafts/sends as the user only through that guarded tool, never via raw `ui_action` typing |
| Mic: hold-to-record voice note, slide cancel/lock, pause/delete/send | Send a voice note to the person | Recording is the user's voice: `AUTO` flow |
| **Voice note play/pause in a DM bubble** | **Play a voice note in the thread** | **GAP-2 (S)** — playback exists for the user; Ayma's `play_voice_clip` covers the Ayma chat only (the DM bubble resolves its clip URL in per-bubble state, which no registry can see yet) |
| Attachment button: Photo / Camera / File | Attach media | `UI` for the entry; OS picker is the user's |
| Photo bubble (tap) | Image viewer | `UI` |
| "Share this chat with Ayma" | Bring the thread into the Ayma chat | `UI` |
| Auto-translate toggles ("Auto-translate their messages", "Translate what I send") | Translate the thread | `UI` |
| "Show translation" / "Translate" / "Your original" on a bubble | Reveal translation/original | `UI` |
| "Send in their language?" sheet: Send / Cancel | Confirm translated send | `UI` |
| Coach chips ("Things to talk about") | Insert a suggested line | `UI`; suggestions themselves come from her `dm_assist` |
| "Heads up from Ayma" tip dismiss (X) | Dismiss the coach tip | `UI` |
| Block & report / Block (menu) | Block the person | EXCLUDED — founder-confirmed 2026-11-06; refused by the `block_report` deny rule (see Exclusions) |
| Retry (failed message) | Resend | `UI` |

## 7. Public profile (`/profile/user/:uid`) — `public_profile_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Like / Unlike button | Like (or remove a like on) this person | `UI` |
| Chat button | Open the DM thread | COVERED `open_message_thread` |
| Run match / match-report entry | Open the match report | COVERED `open_match_report` |
| Practice Date entry | Open a Practice Date with them | COVERED `open_practice_date` |
| Agent Date / sim entry | Open the date sim with them | COVERED `open_date_sim` |
| Photo carousel | Cycle photos / show a numbered photo ("show the third picture") | COVERED `show_profile_photo`; also `UI` |
| Ask Ayma (page-context) | Chat about this person | `UI` — opens her own chat |

## 8. Match report (`/match/:matchId`), match request (`/match-request/:matchId`)

| Control | Does | Ayma |
|---|---|---|
| Score / summary sections, "You vs them" rows | Read the report | COVERED — content is in her screen context |
| Message / open thread entry | Go to the DM | COVERED `open_message_thread` |
| Practice / sim entries | Launch practice or sim | COVERED `open_practice_date` / `open_date_sim` |
| Accept / Pass (request) | Decide the request | `UI` |
| Retry | Reload | `UI` |

## 9. Date sim (`/date-sim/:uid`) — `date_sim_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| "Simulate a conversation" | Run the Agent Date | `UI` (opening is `open_date_sim`); the sim result returns to her |
| Messages-to-exchange selector (+N messages, credit estimate) | Choose sim length | `UI` |
| "Keep the conversation going" | Extend the sim | `UI` |
| "Start over" (+ confirm dialog) | Restart the sim | `UI` |
| "Turn on AI Avatar" | Enable the avatar feature | `UI` |
| Done | Leave the sim | `UI` (back) |

## 10. Practice Date (`/practice/:uid`, voice variant, debrief)

| Control | Does | Ayma |
|---|---|---|
| Send a practice message (composer) | Talk to the match's avatar | The practice partner is an agent, not Ayma herself; starting is COVERED `open_practice_date` |
| Mic / voice practice entry | Start practice voice | `UI` |
| End | End the practice session | `UI` |
| Restart simulation (+ confirm) | Restart practice | `UI` |
| Practice voice screen: mute, End | Mute / end the practice call | `UI` |
| Debrief: Done | Close the debrief | `UI` |

## 11. You tab / Profile hub (`/profile`) — `profile_tab_screen.dart`

Every row navigates; all are COVERED by `open_screen` with the listed key,
and also `UI`:

| Row | Destination key |
|---|---|
| Completeness card ("Your profile is N% complete") | `complete_profile` |
| My public profile | `my_public_profile` |
| My story | `story` |
| Profile details | `profile_details` |
| Search the web about me | `my_web_research` |
| Appearance | `my_appearance` |
| Settings | `settings` |
| Connect Instagram | (screen exists; connecting is `unavailable` in this version — registry says so honestly) |
| Ayma's settings | `ayma_settings` |
| Plan | `credits` |
| Invite friends | `invite_friends` |
| Send feedback | `feedback` |
| Terms of Service / Privacy Policy | `terms` / `privacy` |
| Sign out | COVERED `account_action sign_out` (explicit confirmation first; never via `ui_action`) |

## 12. Complete profile (`/complete-profile`)

| Control | Does | Ayma |
|---|---|---|
| Section rows (unlocked) | Open/talk through that section | `UI`; content changes go through `set_profile_field` / `record_answer` / questionnaire tools |
| "Talk it through with Ayma" / "Talk to Ayma about this" | Open the scoped chat | `UI` — her own chat |
| Locked sections | Not tappable yet | — |

## 13. My public profile (`/profile/me/public`) — `my_public_profile_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Photo: remove (Remove from public / Delete everywhere dialog) | Hide or delete a photo | COVERED `delete_photo` (skill) / `UI` for remove-from-public; **"Delete everywhere" EXCLUDED** — founder-confirmed 2026-11-06, refused by the `delete` deny rule |
| "Review" (suggested updates entry) | Open profile proposals | COVERED `open_screen profile_suggestions` |
| Story/passage rows, "Chat about it" (photo gallery) | Discuss/edit | COVERED `edit_profile_section`, story tools, `update_photo_note` |
| Undo (snackbar) | Undo a removal | `UI` |

## 14. Profile proposals (`/profile/me/updates`)

| Control | Does | Ayma |
|---|---|---|
| Apply (per suggestion) | Apply one suggested update | `UI` |
| Dismiss (per suggestion) | Drop one suggestion | `UI` |
| Apply all | Apply every suggestion | `UI` |
| Dismiss all | Drop every suggestion | EXCLUDED — founder-confirmed 2026-11-06 (bulk); refused by the `dismiss_all` deny rule |

## 15. My story / wiki (`/profile/wiki`) — `story_editor_screen.dart`, `manual_profile_edit_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Passage/section rows (tap) | Open the passage | `UI`; edits are COVERED directly: `edit_story_entry`, `remove_story_entry`, `edit_passage`, `set_passage_privacy`, `set_section_privacy`, career-timeline edit/delete tools |
| "Why Ayma believes this" / sources | Show provenance | `UI`; she knows it via `find_fact_source` |
| Add LinkedIn / sources rows | Add a source | `UI` |
| Photos strip / web findings entries ("VIEW WEB FINDINGS", "VIEW FULL REPORT") | Open the linked report/photo | `UI` / `open_screen` |
| Edit manually: text field + Save | Hand-edit the public profile text | COVERED `edit_profile_section` (same content, no UI driving needed) |
| Appearance analysis / topics rows | Open the linked section | `UI` |

## 16. Profile details (`/settings/profile`) — `profile_settings_screen.dart`, `partner_preferences_fields.dart`

| Control | Does | Ayma |
|---|---|---|
| Name / birthdate / basic fields | Edit profile fields | COVERED `set_profile_field` / `ui_action` set_text |
| Partner preferences: age-range slider, distance, who-I-want-to-meet fields | Set partner preferences | COVERED `app_action` (`partner_age_range`, `distance_preference` handlers) / `UI` |
| Save | Persist edits | `UI` |

## 17. Skills (`/skills`) — `skills_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| "Search the web about me": Search (+ name confirm dialog) | Run web research on the user | COVERED `deep_dive` / `rerun_web_research` |
| Appearance: Add photo / Upload photo | Add a photo for analysis | `UI` for entry; OS picker is the user's; analysis itself COVERED `run_appearance_report` |
| Appearance: "Run analysis" | Run the appearance report | COVERED `run_appearance_report` |
| "View my report" | Open the appearance report | COVERED `open_screen my_appearance` |
| Upgrade (out of credits) | Open Plan | `EXCLUDED` purchase control — open Plan only |

## 18. Reports: Appearance (`/appearance/:id`), Physical (`/physical-attributes/:id`), Web research (`/deep-dive/:id`)

| Control | Does | Ayma |
|---|---|---|
| Share (report card) | Open the share sheet | `UI` (share sheet targets are the user's) |
| "Tap to correct" on a face/body finding | Correct that finding | COVERED `correct_appearance_item` / `clear_appearance_item` (Ask-Ayma scoped) |
| Finding rows in web research | Discuss/correct/remove a finding | COVERED `correct_deep_dive_item` / `remove_deep_dive_item` / `find_fact_source` |
| "Search again" / "Run web search" (empty state) | Re-run web research | COVERED `rerun_web_research` |
| Report photo rows (tap) | Open photo / chat about it | `UI` |
| Undo (correction snackbar) | Undo a correction | `UI` |
| Progress card: Try again | Retry a failed run | `UI` |

## 19. Settings (`/settings`) — `settings_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Plan row | Open Plan | COVERED `open_screen credits` |
| Accent Color row | Open accent picker | COVERED `open_screen accent_color`; setting it is `app_action accent_color` |
| Pause matching switch | Pause/resume matching | COVERED `app_action pause_matching` / `resume_matching` |
| Notification preferences row | Open notification prefs | COVERED `open_screen notification_settings` |
| Face verified / Verify your face | Start face verification | `UI` for entry; the selfie + consent are the user's |
| Face matching consent row | Open consent settings | COVERED `open_screen biometric_consent` (page only — withdrawing is `EXCLUDED`-class user-only) |
| "How to use Ayma" / replay tour row | Start the guided tour | COVERED `start_guided_tour` |
| Theme (in Ayma's settings / appearance area) | Light/dark/system | COVERED `app_action` theme commands |
| Build stamp (×7 taps) | Unlock the developer panel | `unavailable` by design (registry says how the user does it) |

## 20. Ayma's settings (`/settings/ayma`) — `ayma_settings_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Models row | Open Ayma's models | COVERED `open_screen voice_preference` |
| Connect an agent (MCP) row | Open Connect-agent | COVERED `open_screen connect_agent` |
| **"Wipe what Ayma has learned" (+ confirm dialog)** | **Clear her memory** | **`EXCLUDED` clear_memory — user-only; she opens this page only** |

## 21. Ayma's models (`voice_preference_screen.dart`, `brain_selector_control.dart`, `voice_engine_control.dart`)

| Control | Does | Ayma |
|---|---|---|
| Brain picker (ONE picker — brain drives text + voice) | Choose the brain | COVERED `set_brain` / `set_voice_brain` (+ `reconnect_voice` to apply mid-call) |
| Voice engine / voice list + preview play buttons | Choose + preview her voice | COVERED `set_voice_preference`; **preview playback GAP-3 (XS)** |
| STT / TTS engine pickers | Choose speech engines | COVERED `set_stt` / `set_tts` |
| Voice mode (cascade / realtime) + realtime model pickers | Choose voice mode/model | COVERED `set_voice_mode` / `set_realtime_model` |
| Save / "Save and reconnect" | Save the stack (reconnects a live call) | COVERED — the save is the `set_model_stack` tools' own completion; the button is `UI` |

## 22. Accent colour (`/accent-color` area) — `accent_color_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Colour wheel drag | Pick a colour | COVERED `app_action accent_color` (hex) — the drag is `UI`-equivalent via the hex command |
| Saturation / Brightness sliders | Tune the colour | COVERED via `app_action accent_color` (resulting hex) |
| Reset to default | Restore the default accent | COVERED `app_action accent_color` = default |

## 23. Plan (`/profile/plan`) and trial paywall — `plan_screen.dart`, `trial_paywall_screen.dart`

| Control | Does | Ayma |
|---|---|---|
| Plan cards / price buttons / Start free trial / Continue | Subscribe or start a trial | **`EXCLUDED` purchase — user-only** |
| Continue with free plan | Stay on free | `UI` |
| Restore purchases | Restore store purchases | `UI` (store flow is the user's) |
| Manage subscription / Manage in store | Open store subscription page | `UI` (leaves the app) |
| Usage rows / credits display | Read usage | COVERED — in her screen context + `plan_facts` |

## 24. Notifications centre + preferences

| Control | Does | Ayma |
|---|---|---|
| Notification row (tap) | Open its destination | COVERED `open_notification` (latest unread) / `UI` per row |
| Mark read (per row) | Mark that notification read | `UI` |
| Mark all read (app-bar button, + confirm) | Mark every notification read | **COVERED `mark_all_notifications_read`** — priority gap, founder feedback item 9 |
| Clear all (app-bar button, + confirm) | Remove every notification from the list | **COVERED `clear_all_notifications`** — founder feedback item 10. Destructive and not undoable: Ayma confirms with the user in conversation before calling it (her tool description carries the rule), the same check the button's dialog performs |
| Filter chips (All / Unread / Matches / Ayma / Reports / Suggestions) | Show only that kind of notification | **COVERED `set_notification_filter`** (on staging, the tool + chips land via the self-check port, fleet/self-check-staging) — founder feedback item 11. The chips and Ayma's command write the same shared filter state (`NotificationFilterState`); the buckets cover the types the centre lists (DM notifications never appear here — they live on the Messages tab) |
| Preference switches (per category) | Toggle notification categories | COVERED `app_action` notification_pref settings |
| "Manage in system settings" | Open OS settings | `UI` (leaves the app; OS side is the user's) |

## 25. Invite friends (`/invite`)

| Control | Does | Ayma |
|---|---|---|
| Share your link | Open the OS share sheet | `UI` for entry; the share target is the user's |
| Copy code | Copy the invite code | `UI` (long-press copy pattern) |

## 26. Feedback (`feedback_screen.dart`, `feedback_draft_card.dart`)

| Control | Does | Ayma |
|---|---|---|
| Bug / Feature chips | Choose feedback kind | COVERED `submit_feedback` (drafts the card; user sends) |
| Text field + Send | Write + send feedback | COVERED `submit_feedback` / `record_feedback`; the draft card's Send tap is the user's confirmation |
| Draft card: Edit / Remove / Add screenshot / Not now | Refine the drafted feedback | `UI` |

## 27. Terms / Privacy / legal screens

| Control | Does | Ayma |
|---|---|---|
| Legal links, "Open <title>" rows | Read the legal text | COVERED `open_screen terms` / `privacy`; checkboxes/consent are `EXCLUDED`-class user-only |

## 28. Delete account (`/settings/delete-account`)

| Control | Does | Ayma |
|---|---|---|
| Type-to-confirm field + "Delete my account" | Delete the account | **`EXCLUDED` delete_account — user-only, page is deny-routed for `ui_action`** |
| Cancel | Back out | `UI` (escape pattern always allowed) |

## 29. Biometric consent / info / consent settings

| Control | Does | Ayma |
|---|---|---|
| "I agree" consent panel | Give face-matching consent | User-only (consent rule) — `PRE-AUTH` at the gate; in settings, page only |
| Withdraw consent and delete my account (+ confirm) | Withdraw + delete | User-only (withdraw rule; deny-routed page) |
| Sign out instead | Sign out | COVERED `account_action sign_out` |

## 30. Connect an agent (`connect_agent_screen.dart`)

| Control | Does | Ayma |
|---|---|---|
| Code field + Review | Enter an MCP pairing code | `UI` set_text (not a secret field) |
| Approve / Deny a connection request | Authorise an external agent | `UI` — approving grants access; flagged **GAP-4 (XS, policy)**: should Ayma ever approve an agent connection herself? Proposed: stay user-only |
| Disconnect | Remove a connected agent | `UI` |

## 31. Google account / Instagram screens

Routes exist (`/settings/google-account`, `/settings/instagram`) but the
registry lists both connections under `unavailable` for this version, and
the routes are `non_navigable`. Their Continue/Cancel buttons are the
user's; Ayma answers honestly from the registry instead of claiming she
can connect them. Status: by design, not a GAP.

## 32. Developer panel (`/settings/developer`, feedback triage, Ayma notes)

Hidden behind the build-stamp unlock; registry `unavailable`
(`developer_panel`). Its controls (triage status chips, tour reset,
money-tracker reset, free reload) are operator tooling, not product
surface. Status: by design, not a GAP.

## 33. Pre-auth & public screens — `PRE-AUTH`

Splash (Retry), Sign-in (Apple / Google / Email / Phone, code entry,
forgot-password — credentials are user-only and Ayma is not running),
critical-consent dialog ("Got it", Terms/Privacy links — consent is the
user's), Preboarding (birthdate, phone, Continue/Save — the user's own
data entry before Ayma exists), Under-18 (Terms, Sign out), Consent gate,
Recovery (deleted-account restore), and the public shared-report link
(`/s/:token`). No Ayma coverage is possible or wanted; the registry lists
each as `non_navigable` with its reason.

## 34. Global widgets & dialogs

| Control | Does | Ayma |
|---|---|---|
| Ask-Ayma overlay: expand/collapse, close, scoped chips | Page-context chat | Her own surface; open/close is `UI` + the popup-close step inside navigation commands |
| Share report sheet: Share to Ayma / Send to a user / matched list / Send | Share a report card | `UI`; sending to a user goes through the user's tap |
| Image viewer: Close / Share / Save | Inspect a photo | `UI` (Share/Save complete in OS surfaces) |
| Photo gallery: Delete / Make public / Chat about it | Manage a story photo | COVERED `delete_photo` / story tools; "Chat about it" opens her chat |
| Push primer: Turn on notifications / Not now | OS push permission | `UI` for Not now; the OS prompt is the user's |
| OAuth code dialog: Connect / Cancel | Finish an OAuth link | `UI` for Cancel; Connect completes a credential flow — user's |
| Coach-mark (passive tour): Skip tour / tap-through | Passive walkthrough | COVERED family — the driven tour is `start_guided_tour`; passive overlay controls are `UI` |
| Out-of-credits sheet: Upgrade / Keep exploring | Upsell | Upgrade `EXCLUDED`; Keep exploring `UI` |
| Toasts (Done / Heads up / Error) | Transient notices | `AUTO` |
| Unmute Ayma chip (global) | End quiet mode | COVERED `ui_action`, user-ask only |

---

## GAP register (sized; Astro sequences these with the founder)

| # | GAP | Size | Notes |
|---|---|---|---|
| GAP-1 | Voice-clip playback in the Ayma chat ("play it" → "I can't play it") | M | **PILOT — wired in this branch** (`play_voice_clip`). Live-call pattern: she announces, the client disconnects the voice session, plays the clip, then reconnects the same session (same transcript store → `/bootstrap` recent-turns carry the context, plus an explicit resume note: "you disconnected to play a voice message; it has finished"). No live session: just plays. The old silent-call-death mode is gone because playback never runs inside the LiveKit room. |
| GAP-2 | Voice-note playback in DM threads | S | Lift the per-bubble clip-URL resolution (`_DmVoiceBubble`) into thread-level state and register DM clips in the same `VoiceClipRegistry`; the command + sequence already exist. |
| GAP-3 | Voice-preset preview playback on the Models screen | XS | A `play_voice_preview` variant reusing the playback orchestrator with `VoicePreviewPlayer`; no session interaction needed (previews are short and the call is not in the room — verify ducking behaviour on device). |
| GAP-4 | Policy: approving an MCP agent connection via Ayma | XS | Decide user-only vs confirmed-action; today it is `UI`-operable, which grants a third party access — proposed user-only. |
| GAP-5 | Carousel/photo-swipe gestures generally | S | `ui_action` has no horizontal-swipe op; carousels are reachable only where they expose tappable arrows/dots. Add a `swipe` op to `ScreenCapture.perform` + `ui_action` if the founder wants full parity here. |
| GAP-6 | OS-level surfaces (share sheet target choice, system pickers, store pages) | — | Not closable from inside the app; Ayma can open the entry point only. Listed for honesty, not scheduled. |
| GAP-7 | Notifications bulk controls + filters (feedback items 9, 10, 11) | S | **WIRED** (`mark_all_notifications_read`, `clear_all_notifications` in this branch; `set_notification_filter` lands on staging via the self-check port, fleet/self-check-staging). Inventory found Mark all read and Clear all already existed as app-bar buttons; the filter buttons did NOT exist — a chips row was added to the page, and the chips and Ayma's command share one filter state. Clear all moved OFF the proposed-exclusions list by founder ruling (see Exclusions). |
| GAP-8 | Conversations-list mark-all-read (feedback item 9, sibling ask) | S | **WIRED in this branch** (`mark_all_conversations_read`). The control did NOT exist on the Messages list — a header button was added (shown only while a shown conversation is unread, confirm dialog like the Notifications page); `DmService.markAllThreadsRead` pages past the live top tier so below-fold threads count too. |

## Keeping this graph alive

1. **A new screen/route** must be added to
   `functions/bootstrap/app_registry.json` (`destinations`,
   `parameterized`, or `non_navigable` with a reason) — the existing
   registry tests fail otherwise — **and** get a section in this doc in
   the same change.
2. **A new tappable control** on an existing screen gets a row in that
   screen's table here, in the same PR that adds the control, with its
   status: a dedicated command (name it), `UI`, `EXCLUDED` (only via the
   exclusions config, below), or a new GAP entry with a size.
3. **A new Ayma command** is registered in the owning skill module and
   added to its registry list (e.g. `COMMAND_SKILLS` in
   `functions/bootstrap/skills/app_control.py` for app commands) — the
   coverage test (`test_app_action_graph.py` /
   `app_action_graph_test.dart`) mechanically checks that every command
   named in this doc exists in the command surface and that every
   command in the surface is named in this doc, so drift fails CI on
   both sides.
4. **A new exclusion** is added to `exclusions` in
   `functions/bootstrap/app_registry.json` (with its `account_actions`
   / `deny_keys` enforcement refs), to `ui_action_policy.deny`
   (same file), and to `kUiDenyRules` in `screen_capture.dart` — never
   to the system prompt, and never as a one-off check in a single
   tool.
5. Reviewers: a PR touching `ayma_flutter/lib/screens/` or
   `lib/widgets/` without touching this doc should be asked for the
   graph entry — the same discipline as the registry rule in (1).

## Appendix — Ayma's full tool surface (the command names used above)

Every tool Ayma can be given, grouped by family. The coverage test
(`tests/test_app_action_graph.py`) checks this doc against the live
registries: a tool that exists but is not named here fails, and a
backticked name here that is neither a tool nor a listed registry /
client identifier fails.

* **App control** (`skills/app_control.py` — voice + text):
  `current_screen`, `list_conversations`, `open_screen`,
  `search_explore`, `open_profile`, `open_message_thread`,
  `open_notification`, `open_match_report`, `open_date_sim`,
  `open_practice_date`, `app_action`, `account_action`, `ui_action`,
  `play_voice_clip`, `mark_all_notifications_read`,
  `clear_all_notifications`, `set_notification_filter`,
  `mark_all_conversations_read`.
* **Guided tour**: `start_guided_tour`, `advance_guided_tour`,
  `back_guided_tour`, `stop_guided_tour`.
* **Her own stack & voice**: `set_brain`, `set_voice_brain`,
  `set_voice_mode`, `set_realtime_model`, `set_stt`, `set_tts`,
  `reconnect_voice`, `set_voice_preference`.
* **Profile & story**: `set_profile_field`, `list_profile_sections`,
  `edit_profile_section`, `set_profile_section_visibility`,
  `edit_story_entry`, `remove_story_entry`, `edit_passage`,
  `remove_from_profile`, `set_passage_privacy`, `set_section_privacy`,
  `edit_career_timeline_entry`, `delete_career_timeline_entry`,
  `next_questions`, `record_answer`, `set_relationship_intent`,
  `add_followup_question`, `remember`, `recall`, `set_user_steering`,
  `find_fact_source`.
* **Photos & reports**: `edit_photo`, `delete_photo`,
  `update_photo_note`, `run_appearance_report`, `face_report`,
  `body_report`, `analyze_physical_attributes`,
  `correct_appearance_item`, `clear_appearance_item`, `deep_dive`,
  `rerun_web_research`, `correct_deep_dive_item`,
  `remove_deep_dive_item`.
* **Messages**: `send_dm_message`, `read_dm_thread`.
* **Feedback & misc**: `submit_feedback`, `record_feedback`,
  `report_bug`, `generate_image`.
