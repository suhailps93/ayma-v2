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
  });

  final TurnRole role;
  final String text;
  final TurnSource source;

  /// `false` only for an in-progress streaming voice segment.
  final bool isFinal;
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
  List<Map<String, String>> wireTurns() => [
        for (final t in _turns)
          if (t.isFinal)
            {
              'role': t.role == TurnRole.ayma ? 'ayma' : 'user',
              'text': t.text,
            },
      ];

  /// A completed turn — a typed message, or a finalized voice segment.
  void addTurn(TurnRole role, String text, TurnSource source) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _turns.add(TranscriptTurn(role: role, text: trimmed, source: source));
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
