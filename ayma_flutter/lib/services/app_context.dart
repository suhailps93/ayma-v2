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
    this.detail = '',
    this.route = '',
    this.visible = '',
  });

  /// A short slug: `explore`, `profile`, `match_report`, `dm`, `messages`,
  /// `ayma`, `profile_tab`, … Empty means "nothing specific".
  final String screen;
  final String subjectUid;
  final String subjectName;

  /// Free text for anything else worth knowing — e.g. the active Explore query.
  final String note;

  /// What the screen is showing right now (e.g. the people Explore lists after
  /// a search), already size-capped by the screen. Ayma reads it through
  /// `current_screen`; it is not part of the chip [label].
  final String detail;

  /// The route pattern on screen (e.g. `/settings`), from the generic
  /// capture (`screen_capture.dart`); every routed screen has one.
  final String route;

  /// The generic live capture of the screen: title, text and operable
  /// controls (`[id] type "label" = state`), capped and redacted.
  final String visible;

  Map<String, dynamic> toJson() => {
        'screen': screen,
        'subject_uid': subjectUid,
        'subject_name': subjectName,
        'note': note,
        'detail': detail,
        'route': route,
        'visible': visible,
      };

  bool sameAs(ScreenContext o) =>
      screen == o.screen &&
      subjectUid == o.subjectUid &&
      subjectName == o.subjectName &&
      note == o.note &&
      detail == o.detail &&
      route == o.route &&
      visible == o.visible;

  /// A short, human label for this context — the text shown in the "you were
  /// looking at…" chip Ayma's chat surfaces when opened from elsewhere in the
  /// app (the global launcher, the Ayma tab). Mirrors
  /// `skills/app_control.py`'s `_describe` (same screen -> phrase mapping),
  /// trimmed to chip length rather than a full sentence.
  String get label {
    final name = subjectName.trim();
    switch (screen) {
      case 'profile':
        return name.isNotEmpty ? "$name's profile" : 'Their profile';
      case 'match_report':
        return name.isNotEmpty ? 'Match report — $name' : 'Match report';
      case 'dm':
        return name.isNotEmpty ? 'Chat with $name' : 'Messages';
      case 'explore':
        final q = note.trim();
        return q.isNotEmpty ? 'Explore — "$q"' : 'Explore';
      case 'messages':
        return 'Messages';
      case 'profile_tab':
        return 'Your profile';
      case 'story':
        return 'Story';
      case 'matches':
        return 'New matches';
      case 'skills':
        return 'Skills';
      case 'photo_management':
        return 'Your photos';
      case 'deep_dive_report':
        return name.isNotEmpty ? 'Web research — $name' : 'Web research';
      case 'appearance_report':
        return name.isNotEmpty
            ? 'Appearance report — $name'
            : 'Appearance report';
      case 'physical_report':
        return name.isNotEmpty
            ? 'Physical profile — $name'
            : 'Physical profile';
      default:
        if (name.isNotEmpty) return name;
        return screen.isNotEmpty ? screen : 'this page';
    }
  }
}

/// The result of one Explore feed load: the search text it ran for and a
/// size-capped plain-text summary of what the screen then shows.
class ExploreReport {
  ExploreReport({required this.query, required this.summary});
  final String query;
  final String summary;
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

  /// Published by ExploreScreen each time a feed load finishes, so
  /// [AppCommandService] can hand the loaded results back to Ayma's
  /// `search_explore` tool. Each assignment is a new [ExploreReport], so every
  /// load notifies.
  final ValueNotifier<ExploreReport?> exploreReport =
      ValueNotifier<ExploreReport?>(null);

  /// The current route pattern, wired by `ScreenCapture.attach`; null in
  /// tests and before the router exists.
  String Function()? routeOf;

  /// The route a screen's own [set] was made on: once the user is on another
  /// route, that screen-specific part no longer applies ([applyCapture]).
  String _slugRoute = '';

  /// A screen states what it is (its slug, subject, note, own summary). The
  /// generic capture ([applyCapture]) keeps adding the route and what's on it.
  void set({
    required String screen,
    String subjectUid = '',
    String subjectName = '',
    String note = '',
    String detail = '',
  }) {
    _slugRoute = routeOf?.call() ?? '';
    final next = ScreenContext(
      screen: screen,
      subjectUid: subjectUid,
      subjectName: subjectName,
      note: note,
      detail: detail,
      route: current.value.route,
      visible: current.value.visible,
    );
    if (!next.sameAs(current.value)) current.value = next;
  }

  /// Publish a fresh generic capture. A screen-specific part set on another
  /// route is dropped, so a screen with no slug of its own (Settings, Plan,
  /// …) is never described as the previous one.
  void applyCapture({required String route, required String visible}) {
    final c = current.value;
    final stale = route.isNotEmpty &&
        _slugRoute.isNotEmpty &&
        route != _slugRoute;
    final next = stale
        ? ScreenContext(route: route, visible: visible)
        : ScreenContext(
            screen: c.screen,
            subjectUid: c.subjectUid,
            subjectName: c.subjectName,
            note: c.note,
            detail: c.detail,
            route: route,
            visible: visible,
          );
    if (stale) _slugRoute = '';
    if (!next.sameAs(c)) current.value = next;
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
