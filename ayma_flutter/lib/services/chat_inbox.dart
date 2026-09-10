import 'package:flutter/foundation.dart';

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
    this.topicPrompt = '',
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
  /// [wantBody] are set from `GET /appearance/coverage` on the Skills screen so
  /// a section with no usable photo is skipped rather than guessed.
  factory ChatKickoff.appearance({
    List<String> extraPaths = const [],
    bool wantFace = true,
    bool wantBody = true,
    bool useAllPhotos = true,
  }) =>
      ChatKickoff._('appearance',
          attachmentPaths: extraPaths,
          wantFace: wantFace,
          wantBody: wantBody,
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
  /// types their own question with the report attached as context. Unlike
  /// [talkAbout] (which seeds a message and auto-sends), nothing is sent until
  /// the user hits send. [shareKind] is `deep_dive` etc.; [refId] the report id.
  factory ChatKickoff.draftAbout({
    required String targetUid,
    String label = '',
    String shareKind = 'deep_dive',
    String photoUrl = '',
    String refId = '',
  }) =>
      ChatKickoff._('draft_about',
          targetUid: targetUid,
          label: label,
          shareKind: shareKind,
          photoUrl: photoUrl,
          refId: refId);

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

  final String kind;
  final String targetUid;

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

  /// [discussTopic]: the node's `ayma_prompt` — a one-line hint of what Ayma
  /// should draw out. Carried for context; the seeded turn stays short.
  final String topicPrompt;
}

class ChatInbox {
  ChatInbox._();
  static final ChatInbox instance = ChatInbox._();

  final ValueNotifier<ChatKickoff?> pending = ValueNotifier(null);

  void push(ChatKickoff k) => pending.value = k;

  /// Take and clear the pending kickoff (returns null if none).
  ChatKickoff? take() {
    final k = pending.value;
    pending.value = null;
    return k;
  }
}
