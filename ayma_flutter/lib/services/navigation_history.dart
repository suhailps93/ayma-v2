import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

/// One page in the session navigation history: the route [path] the user
/// was on and the [label] Ayma can say out loud for it (e.g. "Explore",
/// "the You tab", "their profile").
@immutable
class NavPageEntry {
  const NavPageEntry({required this.path, required this.label});

  final String path;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is NavPageEntry && other.path == path && other.label == label;

  @override
  int get hashCode => Object.hash(path, label);

  @override
  String toString() => 'NavPageEntry($path, "$label")';
}

/// Routes that never enter the history: pre-auth / gate / public-link
/// screens. There is no signed-in session to go back *from* on them, and
/// going back *to* one mid-session (sign-in, the consent gate, splash)
/// would strand the user — the router's own redirects own those flows.
const Set<String> _nonHistoryRoutes = {
  '/splash',
  '/signin',
  '/recover',
  '/consent',
  '/under-18',
  '/preboarding',
  '/chat', // pre-signup marketing chat; the signed-in chat is '/'
};

/// The spoken label for a concrete route [path] (e.g. `/dm/a__b`), or
/// `null` when the route never enters the history. Mirrors the labels in
/// `functions/bootstrap/app_registry.json` (the single source of truth for
/// destinations) so what Ayma says matches what `open_screen` calls them.
String? navPageLabelForPath(String rawPath) {
  var path = rawPath.trim();
  final q = path.indexOf('?');
  if (q >= 0) path = path.substring(0, q);
  if (path.isEmpty || _nonHistoryRoutes.contains(path)) return null;
  if (path.startsWith('/s/')) return null; // public shared-report link
  switch (path) {
    case '/':
      return 'the chat with Ayma';
    case '/explore':
      return 'Explore';
    case '/messages':
      return 'Messages';
    case '/profile':
      return 'the You tab';
    case '/matches':
      return 'New matches';
    case '/notifications':
      return 'Notifications';
    case '/notifications/prefs':
      return 'Notification preferences';
    case '/settings':
      return 'Settings';
    case '/settings/appearance':
      return 'Appearance';
    case '/settings/privacy':
      return 'Privacy';
    case '/settings/voice':
      return "Ayma's models";
    case '/settings/profile':
      return 'Profile details';
    case '/settings/accent-color':
      return 'Accent colour';
    case '/settings/delete-account':
      return 'Delete account';
    case '/settings/biometric-consent':
      return 'Face matching consent';
    case '/settings/connect-agent':
      return 'Connect an agent';
    case '/legal/biometric':
      return 'Biometric information';
    case '/complete-profile':
      return 'Complete your profile';
    case '/profile/me/public':
      return 'My public profile';
    case '/profile/me/updates':
      return 'Public profile updates';
    case '/profile/wiki':
      return 'My story';
    case '/profile/plan':
      return 'Plan';
    case '/profile/feedback':
      return 'Send feedback';
    case '/invite-friends':
      return 'Invite friends';
    case '/skills':
      return 'Skills';
    case '/terms':
      return 'Terms of Service';
    case '/privacy':
      return 'Privacy Policy';
    case '/whats-new':
      return "What's new";
  }
  if (path.startsWith('/profile/user/')) return 'their profile';
  if (path.startsWith('/dm/')) return 'a message thread';
  if (path.startsWith('/match-request/')) return 'a match request';
  if (path.startsWith('/match/')) return 'a match report';
  if (path.startsWith('/deep-dive/')) return 'a web-research report';
  if (path.startsWith('/appearance/')) return 'an Appearance report';
  if (path.startsWith('/physical-attributes/')) return 'an Appearance report';
  if (path.startsWith('/practice/')) return 'a Practice Date';
  if (path.startsWith('/date-sim/')) return 'an AI Date Simulation';
  // Any other routed page: humanise the last segment ("release-notes" ->
  // "Release notes") rather than dropping the visit on the floor.
  final segs = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;
  final seg = segs.last;
  final words = seg.replaceAll('-', ' ').replaceAll('_', ' ').trim();
  if (words.isEmpty) return null;
  return words[0].toUpperCase() + words.substring(1);
}

/// Session-scoped memory of the pages the user has been on — whether THEY
/// navigated there or Ayma took them there by command — so Ayma can take
/// them BACK ("go back", "take me back") one page at a time and can say
/// where they were ("you were on Explore").
///
/// Founder spec (feedback item 15, Nov 6, 2026): remember the previous
/// page and navigate back on request. Deliberately session-only: nothing
/// is persisted, the stack is capped at [defaultMaxDepth], and it clears
/// on sign-out. It is NOT a parallel navigator — entries are plain route
/// paths and going back re-enters them through the app's one navigation
/// surface (`AppCommandService` → `navigateToRoute` / the router).
///
/// Recording has two shapes, because "this page became current" arrives
/// two ways:
/// * [visit] — an explicit forward navigation (a tab tap, an Ayma
///   command): always a new step on the stack.
/// * [record] — the router reporting a new current route, where a *pop*
///   also surfaces as a new current route: when the route is the entry
///   below the top, the top is unwound instead of duplicated, so a
///   system-back / in-app-back shrinks the stack rather than growing
///   `A, B, A`.
class NavigationHistory extends ChangeNotifier {
  NavigationHistory({this.maxDepth = defaultMaxDepth});

  /// The app-wide session history. Tests and the command service's
  /// injectable seams use their own instances; production shares this one.
  static final NavigationHistory instance = NavigationHistory();

  static const int defaultMaxDepth = 20;

  /// The oldest entries are dropped once the stack passes this depth —
  /// deep wandering shouldn't grow the session state without bound, and
  /// nobody means "go back" thirty pages.
  final int maxDepth;

  final List<NavPageEntry> _stack = [];

  /// The remembered pages, oldest first; the last entry is the current
  /// page. Unmodifiable — mutate through [visit]/[record]/[takeBackTarget].
  List<NavPageEntry> get stack => List<NavPageEntry>.unmodifiable(_stack);

  /// The page the user is on now (the top of the stack), or null before
  /// the first recorded navigation.
  NavPageEntry? get current => _stack.isEmpty ? null : _stack.last;

  /// The page a "go back" would return to, or null at the root.
  NavPageEntry? get previous =>
      _stack.length < 2 ? null : _stack[_stack.length - 2];

  bool get canGoBack => _stack.length >= 2;

  String _clean(String path) {
    var p = path.trim();
    final q = p.indexOf('?');
    if (q >= 0) p = p.substring(0, q);
    return p;
  }

  /// Record an explicit forward navigation to [path] (a tab tap or an
  /// Ayma-driven open). Consecutive duplicates collapse (re-opening the
  /// page you are on is not a step). Non-history routes are ignored.
  void visit(String path, {String? label}) {
    final p = _clean(path);
    if (p.isEmpty) return;
    final resolved = label ?? navPageLabelForPath(p);
    if (resolved == null) return;
    if (current?.path == p) return;
    _stack.add(NavPageEntry(path: p, label: resolved));
    while (_stack.length > maxDepth) {
      _stack.removeAt(0);
    }
    notifyListeners();
  }

  /// Record that [path] became the current route by any means (the router
  /// listener). A route equal to [previous] is a back-pop landing: unwind
  /// the top entry instead of pushing a duplicate. Anything else is a
  /// forward [visit].
  void record(String path, {String? label}) {
    final p = _clean(path);
    if (p.isEmpty) return;
    if (current?.path == p) return;
    if (previous?.path == p) {
      _stack.removeLast();
      notifyListeners();
      return;
    }
    visit(p, label: label);
  }

  /// Mark [path] as current after an external back that may land deeper
  /// than one step (the shell's tab-history pop): truncate the stack to
  /// that entry when it is present, otherwise fall back to [record].
  void markCurrent(String path, {String? label}) {
    final p = _clean(path);
    final idx = _stack.lastIndexWhere((e) => e.path == p);
    if (idx < 0) {
      record(p, label: label);
      return;
    }
    if (idx == _stack.length - 1) return;
    _stack.removeRange(idx + 1, _stack.length);
    notifyListeners();
  }

  /// Pop the current page and return the one to go back to, or null when
  /// there is nowhere to go back to (the stack is left untouched then —
  /// being at the root is a sayable outcome, not a failure to hide).
  NavPageEntry? takeBackTarget() {
    if (!canGoBack) return null;
    _stack.removeLast();
    notifyListeners();
    return current;
  }

  /// Forget the whole session history (sign-out; a new session starts
  /// with no previous page).
  void clear() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }

  GoRouter? _router;
  VoidCallback? _routerListener;

  /// Follow [router]'s current route into the history (user-driven pushes
  /// and pops alike, via [record]). Called once at startup next to
  /// `ScreenCapture.attach`; safe to call again with a new router.
  void attachToRouter(GoRouter router) {
    detachFromRouter();
    _router = router;
    void listener() {
      try {
        record(router.state.uri.path);
      } catch (_) {
        // Router not ready yet / already disposed — the next navigation
        // records itself; a missed beat must never crash the app.
      }
    }

    _routerListener = listener;
    router.routerDelegate.addListener(listener);
    listener(); // the page the session starts on is the first entry
  }

  void detachFromRouter() {
    final router = _router;
    final listener = _routerListener;
    if (router != null && listener != null) {
      router.routerDelegate.removeListener(listener);
    }
    _router = null;
    _routerListener = null;
  }
}
