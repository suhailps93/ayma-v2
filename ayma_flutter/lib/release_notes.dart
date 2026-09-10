/// Human-readable release notes shown on the "What's new" screen
/// ([ReleaseNotesScreen]), reached by tapping the build tag at the bottom of
/// Settings. Markdown, newest version first. [kReleaseNotesVersion] is the
/// version the current build corresponds to — the heading a fresh install
/// should scroll to.
library;

/// The version whose notes head the list — keep in sync with `pubspec.yaml`.
const String kReleaseNotesVersion = '1.6.0';

const String kReleaseNotes = r'''
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
