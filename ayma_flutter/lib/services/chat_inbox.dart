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

  final String kind;
  final String targetUid;

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
