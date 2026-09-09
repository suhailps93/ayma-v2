import 'package:flutter/widgets.dart';

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

/// Wired into the app router's `observers`. Screens that own a [ScreenContext]
/// (public profile, match report, DM thread, the tab shell) subscribe as
/// [RouteAware] and re-assert their context in `didPopNext`, so popping a child
/// route off the top puts the right screen back on the mirror.
final RouteObserver<PageRoute<dynamic>> screenRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Mixed into a screen's [State] so it re-asserts its [AppContext] on first show
/// and every time a route pushed above it pops back (via [screenRouteObserver]).
/// Implement [reassertScreenContext] with the screen's `AppContext.instance.set`
/// call and invoke it once from `initState` too.
mixin ScreenContextReasserter<T extends StatefulWidget> on State<T>
    implements RouteAware {
  void reassertScreenContext();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) screenRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    screenRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => reassertScreenContext();

  @override
  void didPush() {}

  @override
  void didPop() {}

  @override
  void didPushNext() {}
}
