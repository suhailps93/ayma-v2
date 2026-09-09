import 'package:flutter/foundation.dart';

/// What the user is currently looking at in the app — the screen and, where it
/// applies, which person. Only meaningful to Ayma **during a voice call**:
/// [VoiceSessionController] mirrors this to the backend while a session is live
/// (`POST /voice/context`), and the LiveKit agent's `current_screen` tool reads
/// it so "what do you think of them?" resolves. Pure Dart — safe to set from
/// any screen's `initState` / `didChangeDependencies`.
@immutable
class ScreenContext {
  const ScreenContext({
    this.screen = '',
    this.subjectUid = '',
    this.subjectName = '',
    this.note = '',
  });

  /// A short slug: `explore`, `profile`, `match_report`, `dm`, `messages`,
  /// `ayma`, `profile_tab`, … Empty means "nothing specific".
  final String screen;
  final String subjectUid;
  final String subjectName;

  /// Free text for anything else worth knowing — e.g. the active Explore query.
  final String note;

  Map<String, dynamic> toJson() => {
        'screen': screen,
        'subject_uid': subjectUid,
        'subject_name': subjectName,
        'note': note,
      };

  bool sameAs(ScreenContext o) =>
      screen == o.screen &&
      subjectUid == o.subjectUid &&
      subjectName == o.subjectName &&
      note == o.note;
}

/// App-wide singleton holding the current [ScreenContext] plus a one-shot slot
/// for a search Ayma asked us to run on Explore.
class AppContext {
  AppContext._();
  static final AppContext instance = AppContext._();

  final ValueNotifier<ScreenContext> current =
      ValueNotifier<ScreenContext>(const ScreenContext());

  /// Set by [AppCommandService] when Ayma runs `search_explore`; ExploreScreen
  /// consumes it once on build and clears it.
  String? pendingExploreQuery;

  void set({
    required String screen,
    String subjectUid = '',
    String subjectName = '',
    String note = '',
  }) {
    final next = ScreenContext(
      screen: screen,
      subjectUid: subjectUid,
      subjectName: subjectName,
      note: note,
    );
    if (!next.sameAs(current.value)) current.value = next;
  }

  void clear() {
    if (!current.value.sameAs(const ScreenContext())) {
      current.value = const ScreenContext();
    }
  }
}
