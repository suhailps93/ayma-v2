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
    this.tools = const [],
    this.subjectImage,
    this.reportKind = '',
    this.reportId = '',
    this.sharedKind = '',
    this.sharedUid = '',
    this.sharedName = '',
    this.sharedPhoto = '',
    this.sharedRefId = '',
  });

  final TurnRole role;
  final String text;
  final TurnSource source;

  /// `false` only for an in-progress streaming voice segment.
  final bool isFinal;

  /// A download URL for a photo the user attached to this turn (§2.2), else
  /// null. Rendered above [text] in the bubble.
  final String? imageUrl;

  /// User-facing labels for the tools Ayma used to produce this reply
  /// ("Searched the web", "Updated your profile"). Shown as a caption above
  /// the bubble. Empty when she just answered.
  final List<String> tools;

  /// Photo URL of the person a skill in [tools] was run on (Explore deep-dive),
  /// rendered as a small avatar in the kicker. Null when not applicable.
  final String? subjectImage;

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

  final int _maxTurns;
  final List<TranscriptTurn> _turns = [];

  List<TranscriptTurn> get turns => List.unmodifiable(_turns);
  bool get isEmpty => _turns.isEmpty;

  /// The recent-turns window sent to `/chat` and `/bootstrap` (§1.5). Only
  /// finalized turns; roles as the backend expects (`user` / `ayma`).
  List<Map<String, String>> wireTurns({int skip = 0}) => [
        for (final t in _turns.skip(skip))
          if (t.isFinal && (t.text.isNotEmpty || t.imageUrl != null))
            {
              'role': t.role == TurnRole.ayma ? 'ayma' : 'user',
              'text': t.imageUrl != null && t.text.isEmpty
                  ? '[shared a photo]'
                  : (t.imageUrl != null ? '${t.text}\n[shared a photo]' : t.text),
            },
      ];

  /// A completed turn — a typed message, or a finalized voice segment.
  void addTurn(TurnRole role, String text, TurnSource source,
      {String? imageUrl, List<String> tools = const []}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty && imageUrl == null) return;
    _turns.add(TranscriptTurn(
        role: role,
        text: trimmed,
        source: source,
        imageUrl: imageUrl,
        tools: tools));
    _trim();
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

  /// A streaming voice segment (§1.7 step 12). A non-final segment replaces the
  /// live tail turn for the same role; the final one freezes it. Empty interim
  /// text is ignored so a bubble never flickers blank.
  void applyVoiceSegment(TurnRole role, String text, {required bool isFinal}) {
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
