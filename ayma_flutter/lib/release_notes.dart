/// Human-readable release notes shown on the "What's new" screen
/// ([ReleaseNotesScreen]), reached by tapping the build tag at the bottom of
/// Settings. Markdown, newest version first. [kReleaseNotesVersion] is the
/// version the current build corresponds to — the heading a fresh install
/// should scroll to.
library;

/// The version whose notes head the list — keep in sync with `pubspec.yaml`.
const String kReleaseNotesVersion = '1.13.0';

const String kReleaseNotes = r'''
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
