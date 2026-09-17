/// Human-readable release notes shown on the "What's new" screen
/// ([ReleaseNotesScreen]), reached by tapping the build tag at the bottom of
/// Settings. Markdown, newest version first. [kReleaseNotesVersion] is the
/// version the current build corresponds to — the heading a fresh install
/// should scroll to.
library;

/// The version whose notes head the list — keep in sync with `pubspec.yaml`.
const String kReleaseNotesVersion = '1.29.0';

const String kReleaseNotes = r'''
## 1.29.0 — 17 Sep 2026
- The call notification's logo is back, with a green "call is live" badge
  instead of a stray pink dot.
- Ayma can edit a photo you attach directly in chat, not just from "Chat
  about it".
- Credits page now shows real $ spent, alongside your credit balance.
- Ayma can update your name, birthdate or phone any time you ask, not just
  during sign-up.
- Ayma can draft and send a message to someone from Explore for you — she
  always reads it back and waits for a yes first.
- The questionnaire goes deeper — family, friends, past relationships,
  finances — and a fully answered profile now reads "You're all caught up",
  not a flat 100%.
- Report a bug or crash straight in chat with Ayma, screenshot and all.

## 1.28.0 — 16 Sep 2026
- Fixed the "Out of credits" voice banner sticking around after you'd
  already reloaded — it now clears itself the moment credits come back.
- Sign-in screen: Apple leads as its own button (iPhone/iPad only), Google,
  Email and Phone now sit together in one row.

## 1.27.0 — 16 Sep 2026
- Ask Ayma to edit a photo right from "Chat about it" — "make this a studio
  photo" now actually generates an edited version and sends it back in the
  chat, instead of just text advice.

## 1.26.0 — 16 Sep 2026
- "Search the web about me" now shows your latest result right under the
  card, the same way Appearance shows its past runs — tap it to reopen the
  full report.

## 1.25.0 — 16 Sep 2026
- Completed profiles stop restarting the questionnaire; newly saved answers
  are checked before choosing another question.
- Reload credits stays readable and opens correctly from floating chat.
- Ayma's wings are rounder, start lower, and have stronger contrast.
  The default Cherry Fuchsia is a softer rose.
- Accent Color adds saturation, brightness, and black, gray, and white choices.
  Button text adjusts automatically for contrast. Saved colors stay yours;
  use Reset to Cherry Fuchsia to try the new default.

## 1.24.0 — 15 Sep 2026
- Ayma's default look is now "Cherry Fuchsia" — a vibrant cherry-red-pink
  orb with two overlapping wing/petal shapes, replacing the old peach tone
  everywhere: sign-in, the nav bar, chat, and the app icon.
- The wings now move: they flutter rapidly while Ayma is speaking, and
  slowly swell open-and-closed while she's listening.
- New: Accent Color in Settings — drag across a colour strip to pick your
  own accent, live everywhere in the app, saved as your default.

## 1.23.0 — 15 Sep 2026
- A floating Ayma button now follows you across every screen — tap it to open
  a draggable chat with full history, live voice, and awareness of whatever
  you're looking at.

## 1.22.1 — 13 Sep 2026
- Fixed the app icon's black-ring artifact and refined Ayma's orb toward a
  less-cartoonish, "anime glass" look.
- Voice no longer invents details when asked about someone's profile —
  it now gets the real bio/wiki briefing instead of just a name.
- The Android call notification now shows real Hang Up and Mute buttons and
  a live, always-accurate timer, and shows up as a normal notification
  instead of being silently hidden under "Silent".
- Fixed old conversations not loading further back than the most recent 40
  messages — nothing was ever lost, it just wasn't paginating in.
- A small indicator now lets you jump back to a live call from any tab.
- Removed a stray icon above the message box and fixed a text-rendering bug
  in longer Ayma replies.

## 1.22.0 — 13 Sep 2026
- Ayma has a new look — a liquid, sunrise-colored orb replaces the old spark
  mark everywhere: sign-in, the nav bar, the app icon, and every "Ayma is
  thinking" spinner in the app.
- Fixed several voice skills silently failing mid-call — reading a DM
  thread, seeing your current screen, and about 18 others — caused by a
  real bug where their results were never reaching Ayma; she used to
  improvise a plausible-sounding excuse instead.
- The voice waveform is bigger and livelier — more amplitude, less of a flat
  hum.
- Ayma calls can now run in the background with a real system call
  notification (Hang Up / Mute), replacing the old floating bubble.

## 1.21.1 — 13 Sep 2026
- Voice now actually works in "Edit with Ayma" — tap the mic, talk, and what you say reaches Ayma the same way typing does.
- Tapping a sentence to open "Edit with Ayma" now works the same way on all three Story tabs — Story, Public view, and Ayma's Notes.
- Fixed "why Ayma believes this" always jumping to the same message no matter which one you tapped.
- Fixed a face-match false positive that could flag a non-photo image (like a generic avatar) found online as a match.
- Fixed the out-of-credits message not rendering correctly.
- The voice waveform is now much larger and easier to see.

## 1.21.0 — 13 Sep 2026
- Photos now open the document right at the top, under the cover — grouped
  by where they came from, with the Public view only ever showing your
  profile photos.
- Tapping a sentence now opens "Edit with Ayma" directly — the floating
  toolbar is gone in favour of one focused sheet with quick actions shaped
  like chat bubbles.
- "Delete from profile" no longer erases a passage — it takes it off your
  profile and Public view, but Ayma still remembers it and shows it to you
  (in red) under Ayma's Notes, revertible any time.
- Face analysis, body analysis, and your physical profile are now one
  merged "Appearance analysis" card — in both Your Story and Ayma's Notes —
  instead of three separate ones.
- When you're chatting about a specific photo, that photo now sits right
  above the message box instead of at the top of the sheet.

## 1.20.0 — 13 Sep 2026
- Your Story is now one continuous page you read top to bottom, not tabs of
  cards — cover, narrative sections, a photo interlude, and a web-findings
  interlude, all in one editorial document.
- Tap any sentence to get a small floating toolbar right there — Make public,
  Make private, or Ask Ayma — instead of a separate edit screen.
- "Ask Ayma" now opens as a light overlay over the page itself: ask it to
  change what a section says, watch the sentence update in place with a
  brief highlight, no full chat screen needed.
- Every section has a quiet "Why Ayma believes this" note — which
  conversations taught Ayma that, and when — with no invented confidence
  score.
- Photos and web-research findings show as small teasers right in the
  document, linking out to their full screens — nothing about them is lost.
- Career & Education can now show a real timeline — company, role, dates —
  once Ayma is confident enough in it, built from your conversations and,
  if you add your LinkedIn URL, a direct read of that page.

## 1.19.1 — 13 Sep 2026
- Voice waves now have a soft peach fill inside the composer: bottom for your voice, top for Ayma.
- Removed the gray rectangle inside the text input, including while typing.

## 1.19.0 — 13 Sep 2026
- The chat composer is now one unified pill that morphs between typing,
  listening, and Ayma-speaking — the waveform is animated right into the
  composer's own border instead of a separate element.
- The bottom navigation is now icon-only, no text labels under the tabs.
- A photo's gallery note now describes what's actually in it using your
  confirmed identity and what you said when you shared it, instead of a
  blind visual description.
- Your Story: tap any single sentence — not just drag-select — to open the
  Private/Public/Delete/Chat-with-Ayma toolbar for it.
- Your Story's "Run it" on an unfinished Appearance card now actually runs
  the report inline instead of just sending you to Skills.
- Fixed photos found in your own web search never showing up in "Photos
  Ayma has".

## 1.18.0 — 12 Sep 2026
- Photos you send in chat now show up right away instead of waiting for the upload to finish.
- A photo's note in the gallery now shows what Ayma actually knows about it from its caption, not a blank note.
- A failed face verification now offers a Retry right in the message, instead of a raw error.
- Notification center now confirms before "Mark all read" or "Clear all", so a stray tap can't wipe your notifications.
- Web research reports have a "Mark incorrect" action on any fact — it removes that fact and Ayma won't bring it back on a re-search.
- Your Story's face analysis, body analysis, appearance, and web-findings sections now show a summary card with a "View full report" link instead of repeating the whole report inline.

## 1.17.0 — 12 Sep 2026
- New pre-boarding step: a quick front-camera selfie to verify it's really you. It's never shown on your profile — it's used only to confirm your other photos are actually you.
- Settings has a "Verify your face" action for any account that skipped it — with an unverified badge until you do.
- Appearance scores now show a running median across every photo Ayma has read for you, not just your latest one, so one unusually good or bad shot doesn't swing your score.
- Ayma's automatic face/body read of your photos is now smarter about *whose* photo it's reading — it skips group shots and any photo that doesn't look like you, and only runs the read an unverified photo actually supports (face-only, body-only, or both).
- Photos you share in chat now go through the same moderation/tagging pipeline as profile and DM photos, so Ayma's private notes on them are as accurate as everywhere else.
- The Appearance photo nudge now also suggests a photo without loose or baggy clothing, for a more accurate body read.

## 1.16.0 — 12 Sep 2026
- "AI notes" now shows everything Ayma has — public, private, and anything still AI-only — colour-coded by the same public/private/AI key, instead of a fixed handful of pages. A private or public section there is fully editable, same as under Everything.

## 1.15.0 — 12 Sep 2026
- Deleting a photo no longer erases it from Ayma's memory — it moves to a "deleted by you" group under AI notes instead of disappearing, and "photos Ayma has" is now filtered per tab, so a chat photo no longer shows under What's public.
- "Is this you?" is gone — Ayma now shows her own face-match read of a photo (yes / no / hasn't checked yet) instead of asking you to tell her.
- A photo's note is now what Ayma already knows about it — from her own caption or a chat correction — instead of a text box; correcting it means chatting with Ayma about the photo.
- Fixed duplicate photos showing in the gallery when the same picture appeared under two different URLs (e.g. sent in chat and also on your profile).
- "Make public" now shows a "Publishing…" state in the sheet instead of the screen appearing to freeze while it moderates and re-embeds the photo.

## 1.14.0 — 12 Sep 2026
- Your Story now colour-codes text instead of showing lock icons: black is public, grey is private, red is AI only — a key at the top spells it out.
- Sections you've edited carry an "edited" tag; a section's history now labels each version (edited, made public/private, deleted, reverted, or something Ayma learned) instead of a plain visibility line.
- "Photos Ayma has" is grouped by where each photo came from — your profile, chat & skills, or the open web — with a coloured edge matching the same public/private/AI key.
- Tap a photo to see what it is, say whether it's really you, delete it (Ayma keeps it AI-only), add it to your public profile, or chat with Ayma about it.
- Deep dive: searches further and also tries your bare name (not just name + location) when looking for photos of you online, so a real match isn't missed.

## 1.13.0 — 12 Sep 2026
- Your Story now has a third tab, **AI notes** — the physical profile, facial/physique analysis, your interaction history, and Ayma's standing instructions, all in the same place instead of a separate hidden screen.
- "Photos Ayma has" now shows above every tab in Your Story, not just its own screen.

## 1.12.0 — 12 Sep 2026
- Fixed the screen turning off during a voice call.
- Voice: fixed an intermittent case where Ayma couldn't see what screen you were on, or navigate for you, for the rest of that call.
- Out-of-credits in a voice call now shows the same Reload button chat already has, instead of a plain error message.
- Your Story now reads as one continuous page instead of separate boxed sections, and properly formats headings and bullet lists.
- Voice calls: leaving the app now either shows a small floating control (if you've allowed "display over other apps" for Ayma) or ends the call — it no longer holds the microphone silently in the background.

## 1.11.0 — 11 Sep 2026
- Voice calls now show what Ayma is doing while she's doing it — "Researching…" while a tool runs, then a small caption on her reply once it lands, the same as chat already does.

## 1.10.1 — 11 Sep 2026
- "Search me" and web research on someone else now always run fresh — the reuse cache only ever kicks in for someone else looking *you* up, or reopening a saved report.
- Added a "Search again" refresh action on any Web research report — yours or someone else's — that starts a new search without waiting for the cache to expire.

## 1.10.0 — 10 Sep 2026
- "Complete your profile" now opens up section by section: it's tuned to whether you're after something casual or long-term, and deeper questions unlock once the basics of each section are in. A "Tuned for…" line up top shows which.
- Match reports carry a score-confidence note — it goes up when both people's profiles are well filled in. Match scores are now deterministic: the same two profiles always produce the same number.
- Ran out of credits? There's now a one-tap **Reload** button wherever it happens — in chat, on a match report, on someone's profile, and always on the Skills screen.
- You can un-like a profile now (with a heads-up first if you'd already matched).
- On someone's profile the match % and "View report" are one button.
- Deep dive: finds photos of the person from the web even without a search key set, and surfaces social profiles it's reasonably sure are them (matched on face or name). Tap a photo to open its source.
- "Ask Ayma" on a web-research report opens the chat with the report attached as a draft — nothing sent until you do.
- Links you get in chat are tappable. Tapping the name/photo at the top of a DM opens that person's profile.
- Ayma matches your register — playful if you're playful, casual if you're casual, formal if you're formal — instead of a flat "no".
- You can see when Ayma is using a tool or skill, and what it did.

## 1.8.0 — 10 Sep 2026
- Face, Physique and Physical-attributes reports are now one **Appearance** report.
- Photos are tagged by shot type on upload, so Ayma knows whether she has a face shot and a full-body shot — with a gentle inline nudge to add the missing one (never a block).
- Bolder, slower waveform while Ayma is speaking.

## 1.7.0 — 10 Sep 2026
- This "What's new" screen — reach it by tapping the build tag at the bottom of Settings.
- Ayma checks a photo you share is actually you before responding as if it were a selfie.
- Ayma keeps a per-skill record of what she's run for you and fills in the gaps automatically.

## 1.6.0 — 10 Sep 2026
- Notification centre: multiple messages from the same person now collapse into one row with their photo, name and an unread count. Tapping it opens that conversation and marks those messages read.
- Read vs unread is shown clearly, and opening the centre no longer marks everything read — there's a "Mark all read" button instead.

## 1.5.0 — 9 Sep 2026
- "Physical attributes" is now a proper saved report — its own screen, a tappable card in chat, and a history list under Skills. It runs in the background so the Skills screen no longer hangs, and the result is written into your private story / AI notes.
- Voice: Ayma answers "what page am I on?" reliably now.

## 1.4.0 — 9 Sep 2026
- Skills: new "Physical attributes" card; all three photo skills now ask "use the photos I have" or "add photos" first; fixed the Facial/Physique report doing nothing when tapped.
- AI notes screen: formatted (markdown) with a gallery of every photo Ayma has of you (profile + chat).
- Voice: fuller waveform on the composer bar — the bottom edge flattens when you're muted, the top when Ayma is quiet; removed the duplicate status caption.
- Direct messages: attach a photo, camera shot, or file.
- Notifications: swipe a row to dismiss, or "Clear all".

## 1.3.0 — 9 Sep 2026
- Deep dive is now a saved, re-openable report with a card in chat — and it finds and face-matches photos of the person from the web.
- Match report: a "what'd sharpen this score" section listing what Ayma still needs to know.
- Edit your public profile by chatting with Ayma.
- Direct message threads show the person's name and photo in the header.
- Voice: "make it a female/male voice" now actually switches; accent changes apply mid-call.
- Explore search understands build, hair, eye colour, skin tone, height and weight.
- Full Terms of Service and a new Privacy Policy.

## 1.2.0 — 9 Sep 2026
- In a voice call, Ayma can see what screen you're on and can navigate the app for you ("open Explore and search for hikers").

## 1.1.0 — 9 Sep 2026
- Share a person, a conversation, or a match report into the Ayma chat as a card to talk it over.
- Rebuilt match scoring on a fixed 7-dimension weighted rubric; your stated profile now beats stale web info.
- Explore: filter chips (your likes / mutual / scored) and natural-language search.
- The back button now walks back through your tabs instead of quitting.
''';
