import 'dart:async';

/// One playable voice clip on a chat surface, in the form Ayma's
/// `play_voice_clip` command needs (ACTION PARITY pilot, founder
/// 2026-11-06 — docs/APP_ACTION_GRAPH.md GAP-1).
///
/// A surface that renders voice clips (today: the Ayma chat, via
/// `ChatScreen`) publishes its clips here; [AppCommandService] resolves
/// the model's ask ("the latest one", "mine", "hers") against this
/// registry instead of guessing at widget state. Playback itself stays
/// with the surface's own player — [start] is the exact start branch of
/// `VoiceClipRow`'s tap handler, so Ayma-driven playback and a user tap
/// can never diverge (same player, same now-playing key, same icon
/// state).
class VoiceClipHandle {
  const VoiceClipHandle({
    required this.key,
    required this.owner,
    required this.label,
    required this.order,
    required this.start,
    required this.isPlaying,
    required this.stop,
  });

  /// The clip's identity on its surface — the same `clipKey` its
  /// `VoiceClipRow` uses, so now-playing state lines up.
  final String key;

  /// Who the clip belongs to: `user` or `ayma`.
  final String owner;

  /// What Ayma can honestly call it: `your voice message` /
  /// `Ayma's voice message`, with a short transcript snippet when the
  /// turn has one.
  final String label;

  /// Position in the conversation (higher = later). `latest` means the
  /// highest order, `previous` the one before it.
  final int order;

  /// Start this clip from the beginning (stops whatever was playing).
  final Future<void> Function() start;

  /// True while this clip is the one playing.
  final bool Function() isPlaying;

  /// Stop playback of this clip.
  final Future<void> Function() stop;
}

/// The process-wide registry of currently playable voice clips.
///
/// Surfaces sync their clip list under an opaque [token] (the surface's
/// State object) and clear it on dispose, so a clip is only ever offered
/// while its surface is alive. When two surfaces show the same clip
/// (the Ayma tab and a chat popup over it), the later sync wins for that
/// key — it is the surface the user is looking at.
class VoiceClipRegistry {
  VoiceClipRegistry();

  static final VoiceClipRegistry instance = VoiceClipRegistry();

  final Map<Object, Map<String, VoiceClipHandle>> _byToken = {};

  /// Replace [token]'s published clips with [clips].
  void sync(Object token, List<VoiceClipHandle> clips) {
    if (clips.isEmpty) {
      _byToken.remove(token);
      return;
    }
    _byToken[token] = {for (final c in clips) c.key: c};
  }

  /// Withdraw everything [token] published (its surface went away).
  void clear(Object token) => _byToken.remove(token);

  /// Every published clip, oldest first. Duplicate keys collapse to the
  /// most recently synced surface's handle.
  List<VoiceClipHandle> get clips {
    final byKey = <String, VoiceClipHandle>{};
    for (final clips in _byToken.values) {
      byKey.addAll(clips);
    }
    return byKey.values.toList()..sort((a, b) => a.order.compareTo(b.order));
  }

  bool get isEmpty => clips.isEmpty;

  /// Resolve the model's selector to one clip, or null when nothing
  /// matches. Accepted selectors: `` / `latest` / `last` (the most
  /// recent clip), `previous` (the one before the latest), `mine` /
  /// `user` / `my` (the user's latest), `ayma` / `aymas` / `hers` /
  /// `her` (Ayma's latest), or an exact clip [VoiceClipHandle.key].
  VoiceClipHandle? resolve(String which) {
    final all = clips;
    if (all.isEmpty) return null;
    final w = which.trim().toLowerCase();
    if (w.isEmpty || w == 'latest' || w == 'last') return all.last;
    if (w == 'previous' || w == 'prev') {
      return all.length >= 2 ? all[all.length - 2] : null;
    }
    if (w == 'mine' || w == 'user' || w == 'my') {
      final mine = all.where((c) => c.owner == 'user').toList();
      return mine.isEmpty ? null : mine.last;
    }
    if (w == 'ayma' || w == 'aymas' || w == 'hers' || w == 'her') {
      final hers = all.where((c) => c.owner == 'ayma').toList();
      return hers.isEmpty ? null : hers.last;
    }
    for (final c in all) {
      if (c.key == which.trim()) return c;
    }
    return null;
  }
}
