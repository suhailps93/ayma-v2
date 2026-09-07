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
  });

  /// Research a person on the web. [targetUid] empty = the signed-in user.
  factory ChatKickoff.deepDive({String targetUid = '', String label = ''}) =>
      ChatKickoff._('deep_dive', targetUid: targetUid, label: label);

  /// An honest read on a face photo. [attachmentPath] (a chat upload under
  /// `uploads/{you}/`) wins; empty means "ask which photo to use".
  factory ChatKickoff.faceReport({String attachmentPath = ''}) =>
      ChatKickoff._('face_report', attachmentPath: attachmentPath);

  /// An honest read on a full-body photo. Same rules as [faceReport].
  factory ChatKickoff.bodyReport({String attachmentPath = ''}) =>
      ChatKickoff._('body_report', attachmentPath: attachmentPath);

  final String kind;
  final String targetUid;

  /// A human name for the "Searching for <label>…" placeholder, if known.
  final String label;

  /// A storage path for a photo to analyse (face/body reports), if the caller
  /// already picked one.
  final String attachmentPath;
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
