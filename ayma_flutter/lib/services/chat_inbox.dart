import 'package:flutter/foundation.dart';

import 'app_context.dart';

/// A one-slot hand-off from anywhere in the app to the Ayma chat screen.
///
/// A screen outside the chat shell (Explore, a public profile, the Profile tab)
/// can ask Ayma to *do* something — run a deep dive, a face report, look at a
/// shared profile — by pushing a [ChatKickoff] here and navigating to the shell.
/// [MainShellScreen] switches to the Ayma tab when one arrives; [ChatScreen]
/// consumes it (shows a "working on it…" turn, runs the skill, drops the
/// result in). This is the pattern for every future "button → background skill
/// in chat" feature.
class ChatKickoff {
  const ChatKickoff._(
    this.kind, {
    this.targetUid = '',
    this.label = '',
    this.attachmentPath = '',
    this.attachmentPaths = const [],
    this.photoSource = '',
    this.conversation = false,
    this.shareKind = '',
    this.photoUrl = '',
    this.refId = '',
    this.editSelf = false,
    this.wantFace = true,
    this.wantBody = true,
    this.faceMediaIds,
    this.bodyMediaIds,
    this.topicPrompt = '',
    this.screenContext,
    this.draftBody = '',
  });

  /// Research a person on the web. [targetUid] empty = the signed-in user.
  factory ChatKickoff.deepDive({String targetUid = '', String label = ''}) =>
      ChatKickoff._('deep_dive', targetUid: targetUid, label: label);

  /// An honest read on a face photo.
  ///
  /// [photoSource] is the choice already made on the Skills screen: `existing`
  /// (analyse the best profile photo — no [attachmentPath]) or `added` (analyse
  /// the uploaded [attachmentPath]). Empty means "ask which photo to use" — the
  /// in-chat fallback for when Ayma calls the tool herself.
  factory ChatKickoff.faceReport({
    String attachmentPath = '',
    String photoSource = '',
  }) =>
      ChatKickoff._('face_report',
          attachmentPath: attachmentPath, photoSource: photoSource);

  /// An honest read on a full-body photo. Same rules as [faceReport].
  factory ChatKickoff.bodyReport({
    String attachmentPath = '',
    String photoSource = '',
  }) =>
      ChatKickoff._('body_report',
          attachmentPath: attachmentPath, photoSource: photoSource);

  /// Rebuild the caller's structured physical-attributes record. Runs over the
  /// whole profile photo grid; [extraPaths] are extra chat-uploaded photos
  /// folded in alongside it.
  factory ChatKickoff.physicalAttributes({
    List<String> extraPaths = const [],
    bool useAllPhotos = true,
  }) =>
      ChatKickoff._('physical_attributes',
          attachmentPaths: extraPaths,
          photoSource: useAllPhotos ? 'existing' : 'added');

  /// One unified "Appearance" read of the user's photos — structured attributes
  /// plus an honest face and physique analysis. Runs over the whole profile
  /// grid; [extraPaths] are extra chat-uploaded photos folded in. [wantFace] /
  /// [wantBody] gate each axis (a skipped axis runs neither). [faceMediaIds] /
  /// [bodyMediaIds] — when non-null — name the exact grid photos the pre-run
  /// sheet chose for each axis; null means auto-pick the first eligible.
  factory ChatKickoff.appearance({
    List<String> extraPaths = const [],
    bool wantFace = true,
    bool wantBody = true,
    List<String>? faceMediaIds,
    List<String>? bodyMediaIds,
    bool useAllPhotos = true,
  }) =>
      ChatKickoff._('appearance',
          attachmentPaths: extraPaths,
          wantFace: wantFace,
          wantBody: wantBody,
          faceMediaIds: faceMediaIds,
          bodyMediaIds: bodyMediaIds,
          photoSource: useAllPhotos ? 'existing' : 'added');

  /// Bring something into the Ayma chat to talk about — it shows as a card and
  /// Ayma gets it as context. [shareKind] is `profile` / `conversation` /
  /// `match`; [refId] is the DM thread id or match id (empty for a bare
  /// profile). [conversation] true also asks Ayma to pull the DM thread.
  factory ChatKickoff.talkAbout({
    required String targetUid,
    String label = '',
    bool conversation = false,
    String shareKind = 'profile',
    String photoUrl = '',
    String refId = '',
    bool editSelf = false,
  }) =>
      ChatKickoff._('talk_about',
          targetUid: targetUid,
          label: label,
          conversation: conversation,
          shareKind: shareKind,
          photoUrl: photoUrl,
          refId: refId,
          editSelf: editSelf);

  /// Bring something into the Ayma chat as an *un-sent draft attachment*: the
  /// chat opens with a card chip above an empty, focused composer so the user
  /// types their own question with the target attached as context. Unlike
  /// [talkAbout] (which seeds a message and auto-sends), nothing is sent until
  /// the user hits send. [shareKind] is `profile` / `story` / `deep_dive` /
  /// `match` / `appearance`; [refId] the report id or match id.
  factory ChatKickoff.draftAbout({
    required String targetUid,
    String label = '',
    String shareKind = 'deep_dive',
    String photoUrl = '',
    String refId = '',
    bool editSelf = false,
  }) =>
      ChatKickoff._('draft_about',
          targetUid: targetUid,
          label: label,
          shareKind: shareKind,
          photoUrl: photoUrl,
          refId: refId,
          editSelf: editSelf);

  /// Open the Ayma chat with [text] pre-filled (and focused) in the composer
  /// as an un-sent draft — e.g. a shared-report link to discuss with her.
  factory ChatKickoff.draftText(String text) =>
      ChatKickoff._('draft_text', draftBody: text);

  /// Start the Ayma-driven guided tour: the chat seeds a "Walk me through
  /// the app" user turn and sends it; the backend runs the live tour
  /// (rewire, founder 2026-11-07). Used by Settings → "How to use Ayma",
  /// which no longer replays the passive coach-mark tour.
  factory ChatKickoff.guidedTour() => ChatKickoff._('guided_tour');

  /// Route the user into the Ayma chat to talk through one profile-completeness
  /// topic (a questionnaire node). [nodeId] is the question-tree node id,
  /// [label] its human name, [prompt] the one-line hint of what Ayma should
  /// draw out. The chat seeds a short user turn ("Let's talk about {label}.")
  /// and sends it — Ayma's questionnaire skill and the prompt context take over.
  /// An empty [label] means "no specific topic, work the highest-value gap".
  factory ChatKickoff.discussTopic({
    required String nodeId,
    required String label,
    String prompt = '',
  }) =>
      ChatKickoff._('discuss_topic',
          refId: nodeId, label: label, topicPrompt: prompt);

  /// The screen the user was just on, when Ayma was opened from the app-wide
  /// launcher or the Ayma tab itself (not a report's own "Ask Ayma" button —
  /// those already carry more specific context of their own). Shown as a
  /// dismissible chip above the composer and folded into `/chat` the same
  /// way [ChatScreen.pageContext] already is.
  factory ChatKickoff.pageContext(ScreenContext ctx) =>
      ChatKickoff._('page_context', screenContext: ctx);

  final String kind;
  final String targetUid;

  /// [draftText]: the composer text to pre-fill.
  final String draftBody;

  /// [pageContext]: the snapshot of [AppContext.instance] to show/send.
  final ScreenContext? screenContext;

  /// [discussTopic]: the questionnaire node id this chat is seeded to cover
  /// (carried in [refId]).
  String get nodeId => refId;

  /// [talkAbout]: also fold in the DM conversation with this person.
  final bool conversation;

  /// [talkAbout]: `profile` / `conversation` / `match` — picks the card + seed.
  final String shareKind;

  /// [talkAbout]: photo for the card, and the DM thread / match id it opens.
  final String photoUrl;
  final String refId;

  /// [talkAbout] with the user's OWN uid: open the chat in profile-edit mode
  /// (unlocks Ayma's public-profile section-edit tools).
  final bool editSelf;

  /// A human name for the "Searching for <label>…" placeholder, if known.
  final String label;

  /// A storage path for a photo to analyse (face/body reports), if the caller
  /// already picked one.
  final String attachmentPath;

  /// Extra storage paths to fold into a multi-image pass (physical attributes).
  final List<String> attachmentPaths;

  /// The photo-source choice resolved on the Skills screen: `existing`,
  /// `added`, or `` (ask in chat).
  final String photoSource;

  /// [appearance]: gate the face / physique sections (from coverage).
  final bool wantFace;
  final bool wantBody;

  /// [appearance]: the exact grid photos chosen for each axis in the pre-run
  /// sheet, or null to auto-pick the first eligible one.
  final List<String>? faceMediaIds;
  final List<String>? bodyMediaIds;

  /// [discussTopic]: the node's `ayma_prompt` — a one-line hint of what Ayma
  /// should draw out. Carried for context; the seeded turn stays short.
  final String topicPrompt;
}

class ChatInbox {
  ChatInbox._();
  static final ChatInbox instance = ChatInbox._();

  final ValueNotifier<ChatKickoff?> pending = ValueNotifier(null);

  /// Bumped when a skill the app started in the background (a match, a web
  /// search) has finished server-side. The server has already written its
  /// result into the conversation as a report card turn; [ChatScreen] listens
  /// and pulls it in, so the card appears without reopening the chat.
  final ValueNotifier<int> resultsLanded = ValueNotifier(0);

  void push(ChatKickoff k) => pending.value = k;

  void resultLanded() => resultsLanded.value++;

  /// Take and clear the pending kickoff (returns null if none).
  ChatKickoff? take() {
    final k = pending.value;
    pending.value = null;
    return k;
  }
}
