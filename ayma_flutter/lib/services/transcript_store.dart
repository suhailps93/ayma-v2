import 'dart:io';

import 'package:flutter/foundation.dart';

enum TurnRole { user, ayma }

enum TurnSource { voice, text }

@immutable
class TranscriptTurn {
  const TranscriptTurn({
    required this.role,
    required this.text,
    required this.source,
    this.isFinal = true,
    this.imageUrl,
    this.imageFile,
    this.tools = const [],
    this.subjectImage,
    this.capped = false,
    this.reportKind = '',
    this.reportId = '',
    this.sharedKind = '',
    this.sharedUid = '',
    this.sharedName = '',
    this.sharedPhoto = '',
    this.sharedRefId = '',
    this.createdAt,
  });

  final TurnRole role;
  final String text;
  final TurnSource source;

  /// When this turn happened, for turns loaded from server history — null for
  /// a live typed/voice turn. Used only to jump to a point in history (e.g.
  /// from a Your Story provenance source); never shown in the UI.
  final DateTime? createdAt;

  /// `false` only for an in-progress streaming voice segment.
  final bool isFinal;

  /// A download URL for a photo the user attached to this turn (§2.2), else
  /// null. Rendered above [text] in the bubble.
  final String? imageUrl;

  /// The local file for a just-picked photo, shown immediately in the bubble
  /// while [imageUrl] is still being uploaded — the turn appears the instant
  /// it's sent rather than waiting on the Storage round-trip. Cleared once
  /// [imageUrl] lands (see [TranscriptStore.updateTurnImage]); null for any
  /// turn loaded from history, which only ever has a remote URL.
  final File? imageFile;

  /// User-facing labels for the tools Ayma used to produce this reply
  /// ("Searched the web", "Updated your profile"). Shown as a caption above
  /// the bubble. Empty when she just answered.
  final List<String> tools;

  /// Photo URL of the person a skill in [tools] was run on (Explore deep-dive),
  /// rendered as a small avatar in the kicker. Null when not applicable.
  final String? subjectImage;

  /// `true` when this Ayma turn is an "out of credits" refusal — the chat
  /// renders a "Reload credits" button under it that opens the usage screen.
  final bool capped;

  /// When this Ayma turn carries a face/body report: `'face'` / `'body'` and
  /// the stored report id. The chat renders the report card inline.
  final String reportKind;
  final String reportId;

  /// When this *user* turn shared something into the chat for Ayma to discuss:
  /// `'profile'` / `'conversation'` / `'match'`, plus who/what it points at.
  /// The chat renders a tappable card instead of a plain bubble.
  final String sharedKind;
  final String sharedUid;
  final String sharedName;
  final String sharedPhoto;

  /// A DM thread id (`conversation`) or a match id (`match`) for the card's tap
  /// target. Empty for `profile` (uses [sharedUid]).
  final String sharedRefId;
}

/// The single rolling window of conversation turns, voice and text interleaved
/// through one code path (ARCHITECTURE.md §1.6, §1.7 step 4). Both the chat
/// view and the context window sent to `/bootstrap` / `/chat` read from here.
class TranscriptStore extends ChangeNotifier {
  TranscriptStore({int maxTurns = 100}) : _maxTurns = maxTurns;

  int _maxTurns;
  final List<TranscriptTurn> _turns = [];

  List<TranscriptTurn> get turns => List.unmodifiable(_turns);
  bool get isEmpty => _turns.isEmpty;

  /// The rolling window size passed to the constructor — a caller that seeds
  /// a large batch (e.g. paging far back to reach a target timestamp) needs
  /// this to build a window that survives [_trim] rather than guessing 100.
  int get maxTurns => _maxTurns;

  /// The recent-turns window sent to `/chat` and `/bootstrap` (§1.5). Only
  /// finalized turns; roles as the backend expects (`user` / `ayma`).
  List<Map<String, String>> wireTurns({int skip = 0}) => [
        for (final t in _turns.skip(skip))
          if (t.isFinal &&
              (t.text.isNotEmpty || t.imageUrl != null || t.imageFile != null))
            {
              'role': t.role == TurnRole.ayma ? 'ayma' : 'user',
              'text': () {
                final hasImage = t.imageUrl != null || t.imageFile != null;
                if (!hasImage) return t.text;
                return t.text.isEmpty
                    ? '[shared a photo]'
                    : '${t.text}\n[shared a photo]';
              }(),
            },
      ];

  /// A completed turn — a typed message, or a finalized voice segment. Returns
  /// the turn added, so a caller with a still-uploading [imageFile] can later
  /// swap in the real [imageUrl] (see [updateTurnImage]) or drop the turn
  /// entirely if the upload fails (see [removeTurn]).
  TranscriptTurn addTurn(TurnRole role, String text, TurnSource source,
      {String? imageUrl,
      File? imageFile,
      List<String> tools = const [],
      bool capped = false}) {
    final trimmed = text.trim();
    final turn = TranscriptTurn(
        role: role,
        text: trimmed,
        source: source,
        imageUrl: imageUrl,
        imageFile: imageFile,
        tools: tools,
        capped: capped);
    if (trimmed.isEmpty && imageUrl == null && imageFile == null) return turn;
    _turns.add(turn);
    _trim();
    notifyListeners();
    return turn;
  }

  /// Swap in the uploaded download URL for a turn that was shown immediately
  /// with a local [TranscriptTurn.imageFile] (§ chat photo latency). No-op if
  /// [turn] is no longer in the window (e.g. trimmed) — it was already visible
  /// via the local file either way.
  void updateTurnImage(TranscriptTurn turn, String imageUrl) {
    final i = _turns.indexOf(turn);
    if (i == -1) return;
    _turns[i] = TranscriptTurn(
      role: turn.role,
      text: turn.text,
      source: turn.source,
      isFinal: turn.isFinal,
      imageUrl: imageUrl,
      tools: turn.tools,
      subjectImage: turn.subjectImage,
      capped: turn.capped,
      reportKind: turn.reportKind,
      reportId: turn.reportId,
      sharedKind: turn.sharedKind,
      sharedUid: turn.sharedUid,
      sharedName: turn.sharedName,
      sharedPhoto: turn.sharedPhoto,
      sharedRefId: turn.sharedRefId,
    );
    notifyListeners();
  }

  /// Drop a turn that was shown optimistically (see [addTurn]) once its image
  /// upload actually failed — e.g. the "couldn't upload that image" path in
  /// chat's `_send`. No-op if it's no longer in the window.
  void removeTurn(TranscriptTurn turn) {
    final i = _turns.indexOf(turn);
    if (i == -1) return;
    _turns.removeAt(i);
    notifyListeners();
  }

  /// A user turn that shares a person / conversation / match report into the
  /// chat. [text] is the instruction sent to the backend; the view shows a card.
  void addSharedTurn({
    required String kind,
    required String uid,
    required String name,
    required String photo,
    required String refId,
    required String text,
  }) {
    _turns.add(TranscriptTurn(
      role: TurnRole.user,
      text: text.trim(),
      source: TurnSource.text,
      sharedKind: kind,
      sharedUid: uid,
      sharedName: name,
      sharedPhoto: photo,
      sharedRefId: refId,
    ));
    _trim();
    notifyListeners();
  }

  /// Add a non-final Ayma turn — a "working on it…" placeholder for a
  /// background skill (deep dive, face report). [resolvePending] swaps it for
  /// the real reply when it lands. Not sent to the backend (`isFinal:false`).
  void addPending(String text) {
    _turns.add(TranscriptTurn(
      role: TurnRole.ayma,
      text: text.trim(),
      source: TurnSource.text,
      isFinal: false,
    ));
    _trim();
    notifyListeners();
  }

  /// Update the live label on the trailing pending Ayma turn ("Searching the
  /// web…"). No-op if there is no pending turn.
  void updatePendingText(String text) {
    final tail = _turns.isNotEmpty ? _turns.last : null;
    if (tail == null || tail.isFinal || tail.role != TurnRole.ayma) return;
    _turns[_turns.length - 1] = TranscriptTurn(
      role: TurnRole.ayma,
      text: text.trim(),
      source: TurnSource.text,
      isFinal: false,
    );
    notifyListeners();
  }

  /// Drop the trailing pending Ayma turn (e.g. the request failed). No-op if
  /// the tail isn't pending.
  void dropPending() {
    final tail = _turns.isNotEmpty ? _turns.last : null;
    if (tail == null || tail.isFinal || tail.role != TurnRole.ayma) return;
    _turns.removeLast();
    notifyListeners();
  }

  /// Replace the trailing non-final Ayma turn (from [addPending]) with the
  /// finished reply. No-op if there is no pending turn.
  void resolvePending(
    String text, {
    List<String> tools = const [],
    String? subjectImage,
    bool capped = false,
    String reportKind = '',
    String reportId = '',
  }) {
    final tail = _turns.isNotEmpty ? _turns.last : null;
    if (tail == null || tail.isFinal || tail.role != TurnRole.ayma) return;
    _turns[_turns.length - 1] = TranscriptTurn(
      role: TurnRole.ayma,
      text: text.trim(),
      source: TurnSource.text,
      tools: tools,
      subjectImage: subjectImage,
      capped: capped,
      reportKind: reportKind,
      reportId: reportId,
    );
    notifyListeners();
  }

  /// Replace the whole window with a loaded history page (§2.2) — one
  /// notification, not one per message. Oldest-first.
  void seed(Iterable<TranscriptTurn> turns) {
    _turns
      ..clear()
      ..addAll(turns);
    _trim();
    notifyListeners();
  }

  /// Splice an older page of server history (§2.2 "load older on scroll") in
  /// at the front. Grows the window's cap by exactly what's added so this
  /// call never gets immediately undone by [_trim] — the whole point of
  /// paging older is to keep it, not to evict it a moment later.
  void prependOlder(Iterable<TranscriptTurn> older) {
    final list = older.toList();
    if (list.isEmpty) return;
    _maxTurns += list.length;
    _turns.insertAll(0, list);
    notifyListeners();
  }

  /// A streaming voice segment (§1.7 step 12). A non-final segment replaces the
  /// live tail turn for the same role; the final one freezes it. Empty interim
  /// text is ignored so a bubble never flickers blank. [tools] — the
  /// user-facing labels of any skills Ayma used to produce this segment
  /// (§1.7 step 3) — is meaningful only when [isFinal] (an interim segment
  /// is about to be replaced anyway) and renders as the same kicker chip text
  /// chat already shows.
  void applyVoiceSegment(TurnRole role, String text,
      {required bool isFinal, List<String> tools = const []}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final tail = _turns.isNotEmpty ? _turns.last : null;
    final extendsTail = tail != null &&
        !tail.isFinal &&
        tail.role == role &&
        tail.source == TurnSource.voice;

    final turn = TranscriptTurn(
      role: role,
      text: trimmed,
      source: TurnSource.voice,
      isFinal: isFinal,
      tools: tools,
    );
    if (extendsTail) {
      _turns[_turns.length - 1] = turn;
    } else {
      _turns.add(turn);
    }
    _trim();
    notifyListeners();
  }

  void clear() {
    if (_turns.isEmpty) return;
    _turns.clear();
    notifyListeners();
  }

  void _trim() {
    if (_turns.length > _maxTurns) {
      _turns.removeRange(0, _turns.length - _maxTurns);
    }
  }
}
