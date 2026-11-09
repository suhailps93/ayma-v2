import 'dart:async';
import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'app_context.dart';

/// Every routed screen tells Ayma what is on it, and Ayma can operate its
/// controls, without per-screen code: [ScreenCapture] reads the live
/// semantics tree of whatever is on screen (route, title, headings, text,
/// and each operable control with a short id, type and state), and
/// [ScreenCapture.perform] runs Ayma's `ui_action` through the same
/// semantics actions a screen reader uses (tap, long press, set text,
/// increase/decrease, scroll, dismiss).
///
/// The rules for what is never sent or never operated mirror the
/// `screen_context` and `ui_action_policy` blocks of
/// `functions/bootstrap/app_registry.json` (test/screen_capture_test.dart
/// fails when they drift):
/// * a subtree wrapped in [NoScreenContext] is never sent or operated;
/// * a control wrapped in [NoAymaAction] is described but never operated;
/// * obscured and secret fields (passwords, codes, payment) never send their
///   value and are never typed into;
/// * delete, purchase, consent and withdraw controls (and every control in a
///   dialog about them, except cancel/close) are listed as "user only" and
///   [perform] refuses them.

/// Semantics identifier of [NoScreenContext].
const String kNoScreenContextId = 'ayma-no-context';

/// Semantics identifier of [NoAymaAction].
const String kNoAymaActionId = 'ayma-no-act';

/// Keeps [child] out of everything Ayma is told about the screen (and out of
/// her reach). Screen readers still see it: only the capture skips it.
class NoScreenContext extends StatelessWidget {
  const NoScreenContext({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        identifier: kNoScreenContextId,
        child: child,
      );
}

/// Ayma may see [child] but never operate any control inside it.
class NoAymaAction extends StatelessWidget {
  const NoAymaAction({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        identifier: kNoAymaActionId,
        child: child,
      );
}

/// Each half of the capture (text, controls) is capped at this many
/// characters (`screen_context.max_chars` in the registry).
const int kScreenContextMaxChars = 1500;

/// Routes that send no screen context at all (`screen_context.no_context`).
const Map<String, String> kNoContextRoutes = {
  '/splash':
      'start-up bootstrap; there is no signed-in session or content yet',
  '/signin':
      'sign-in screen: credentials and codes only, and Ayma is not running before sign-in',
  '/recover':
      'deleted-account recovery at sign-in; Ayma is not running before sign-in',
  '/s/:token': 'public shared-report link opened outside a session',
  '/p/:token': 'public page-share link opened outside a session',
};

/// One `ui_action_policy.deny` rule.
@immutable
class UiDenyRule {
  const UiDenyRule(this.key, this.pattern, this.say,
      {this.routes = const [], this.types = const []});
  final String key;
  final String pattern;
  final String say;
  final List<String> routes;
  final List<String> types;
}

const List<UiDenyRule> kUiDenyRules = [
  UiDenyRule(
    'delete',
    r'\b(delete|deleting|erase|permanently|close (my )?account|remove (my )?account)\b',
    'Deleting the account or any data for good is something the user does themselves. Open the page (open_screen delete_account for the account) and tell them which button to tap.',
  ),
  UiDenyRule(
    'withdraw_consent',
    r'\b(withdraw|revoke)\b',
    'Withdrawing face matching consent deletes the account, so the user does it themselves on the Face matching consent page (open_screen biometric_consent).',
  ),
  UiDenyRule(
    'purchase',
    r'\b(subscribe|upgrade|buy|purchase|checkout|check out|top up|pay now|get credits|start (your |a )?(free )?trial)\b|[$€£¥₹]\s?\d',
    "Purchases, subscriptions and credits are always the user's own tap. Open the Plan page (open_screen credits) and let them choose there.",
  ),
  UiDenyRule(
    'purchase',
    r'\bswitch to\b',
    'Changing plan is a purchase, so the user does it themselves on the Plan page.',
    routes: ['/profile/plan', '/profile/usage/trial'],
  ),
  UiDenyRule(
    'consent',
    r'\b(i agree|agree|accept|i consent|consent to)\b',
    "Consent is only ever the user's own tap. Tell them where to tap it.",
  ),
  UiDenyRule(
    'consent',
    r'terms|privacy|policy|consent|agree|biometric|18',
    'Consent and terms checkboxes are only ever ticked by the user.',
    types: ['checkbox'],
  ),
  UiDenyRule(
    'account_action',
    r'\b(sign out|log out)\b',
    'Use account_action for this; it asks the user to confirm first.',
  ),
  UiDenyRule(
    'clear_memory',
    r'\b(wipe what ayma has learned|clear (your |ayma )?memory|wipe (your )?memory|forget everything)\b',
    "Clearing what Ayma has learned is something the user does themselves. Open the Privacy settings (open_screen privacy_settings) and tell them which button to tap.",
  ),
  UiDenyRule(
    'block_report',
    r'\bblock\b',
    "Blocking and reporting someone is the user's own call — it affects another person and can't be undone here. Tell them it is in the menu at the top of their message thread, and let them tap it themselves.",
  ),
  UiDenyRule(
    'dismiss_all',
    r'\bdismiss all\b',
    "Dismissing all suggestions at once is the user's own tap — it drops every one of them. Per-suggestion Dismiss is fine. The button is at the top of the profile suggestions (open_screen profile_suggestions).",
  ),
];

/// `ui_action_policy.deny_routes`: every control on these is user-only.
const Map<String, String> kUiDenyRoutes = {
  '/consent':
      'the face-matching consent gate must only be answered by the user',
  '/settings/biometric-consent':
      'withdrawing consent deletes the account; the user acts on this page themselves',
  '/settings/delete-account': "account deletion is the user's own action",
  '/profile/usage/trial': 'the trial paywall is a purchase screen',
};

const String kUiEscapePattern =
    r'^(back|cancel|close|not now|no|no thanks|keep( my)? account|go back|ayma|explore|messages|you)$';

const String kSecretFieldPattern =
    r'password|passcode|\bpin\b|\bcode\b|otp|one-time|verification|card number|card|cvv|cvc|expiry|expiration|iban|account number';

const String kSecretFieldSay =
    'Passwords, codes and payment details are only ever typed by the user.';

bool _matches(String pattern, String text) =>
    RegExp(pattern, caseSensitive: false).hasMatch(text);

/// Why Ayma may not operate this control (the rule's message), or null when
/// she may. Mirrors `app_registry.ui_denial` on the backend.
String? uiDenial({
  required String label,
  String type = '',
  String route = '',
  String dialogText = '',
}) {
  final text = label.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  final escape = RegExp(kUiEscapePattern, caseSensitive: false)
      .hasMatch(text.trim());
  final r = route.split('?').first;
  if (!escape) {
    final reason = kUiDenyRoutes[r];
    if (reason != null) return 'Not on this page: $reason.';
    if (dialogText.isNotEmpty) {
      for (final rule in kUiDenyRules) {
        if (rule.types.isNotEmpty || rule.routes.isNotEmpty) continue;
        if (_matches(rule.pattern, dialogText)) return rule.say;
      }
    }
  }
  for (final rule in kUiDenyRules) {
    if (rule.routes.isNotEmpty && !rule.routes.contains(r)) continue;
    if (rule.types.isNotEmpty && !rule.types.contains(type)) continue;
    if (_matches(rule.pattern, text)) return rule.say;
  }
  if (type == 'field' && _matches(kSecretFieldPattern, text)) {
    return kSecretFieldSay;
  }
  return null;
}

/// One operable control in a capture.
@immutable
class ScreenControl {
  const ScreenControl({
    required this.id,
    required this.nodeId,
    required this.type,
    required this.label,
    required this.state,
    required this.noAct,
    required this.denial,
  });

  /// Short and stable while the screen is unchanged: `<prefix><n>`.
  final String id;
  final int nodeId;

  /// button, switch, checkbox, radio, field, slider, list, link, tab, item.
  final String type;
  final String label;
  final String state;
  final bool noAct;

  /// Why Ayma may not operate it ([uiDenial]), or null.
  final String? denial;

  String get line {
    final st = state.isEmpty ? '' : ' = $state';
    final mark = (noAct || denial != null) ? ' (user only)' : '';
    return '[$id] $type "$label"$st$mark';
  }
}

/// What one capture saw.
@immutable
class ScreenSnapshot {
  const ScreenSnapshot({
    required this.route,
    required this.title,
    required this.text,
    required this.controls,
    required this.dialogText,
  });

  static const empty = ScreenSnapshot(
      route: '', title: '', text: '', controls: [], dialogText: '');

  final String route;
  final String title;
  final String text;
  final List<ScreenControl> controls;

  /// Every label in a dialog or sheet on top of the page ('' when none).
  final String dialogText;

  /// The capped text sent to Ayma: title, text, then the controls.
  String get visible {
    final out = StringBuffer();
    if (title.isNotEmpty) out.writeln('Title: $title');
    if (dialogText.isNotEmpty) out.writeln('A dialog or sheet is open.');
    if (text.isNotEmpty) out.writeln(text);
    final lines = <String>[];
    var used = 0;
    for (final c in controls) {
      if (used + c.line.length + 1 > kScreenContextMaxChars) {
        lines.add('…');
        break;
      }
      lines.add(c.line);
      used += c.line.length + 1;
    }
    if (lines.isNotEmpty) out.write('Controls:\n${lines.join('\n')}');
    return out.toString().trim();
  }
}

const _typePrefix = {
  'button': 'b',
  'switch': 's',
  'checkbox': 'c',
  'radio': 'r',
  'field': 'f',
  'slider': 'v',
  'list': 'l',
  'link': 'k',
  'tab': 't',
  'item': 'i',
};

String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String? _typeOf(SemanticsData d) {
  final f = d.flagsCollection;
  if (f.isTextField) return 'field';
  if (f.isSlider) return 'slider';
  if (f.isToggled != Tristate.none) return 'switch';
  if (f.isChecked != CheckedState.none) {
    return f.isInMutuallyExclusiveGroup ? 'radio' : 'checkbox';
  }
  final tap = d.hasAction(SemanticsAction.tap);
  if (f.isLink && tap) return 'link';
  if (f.isSelected != Tristate.none && tap) return 'tab';
  if (f.isButton) return 'button';
  if (tap) return 'item';
  if (d.hasAction(SemanticsAction.scrollUp) ||
      d.hasAction(SemanticsAction.scrollDown)) {
    return 'list';
  }
  return null;
}

/// Reads the semantics tree under [root] into a [ScreenSnapshot]. Pure, so
/// tests drive it with real widgets (`tester.ensureSemantics()`).
ScreenSnapshot captureSemantics(
  SemanticsNode root, {
  String route = '',
  bool dialogOpen = false,
}) {
  final texts = <String>[];
  var textLen = 0;
  var title = '';
  var firstHeader = '';
  // The text just before a control in reading order: the visible caption of
  // a field or slider whose own semantics carry no label.
  var lastText = '';
  final raw = <({int nodeId, String type, String label, String state, bool noAct})>[];

  void addText(String t) {
    if (t.isEmpty || textLen >= kScreenContextMaxChars) return;
    final room = kScreenContextMaxChars - textLen;
    final line = t.length > room ? '${t.substring(0, room)}…' : t;
    texts.add(line);
    textLen += line.length + 1;
  }

  String gatherText(SemanticsNode node) {
    final parts = <String>[];
    void go(SemanticsNode n) {
      final d = n.getSemanticsData();
      if (d.identifier == kNoScreenContextId) return;
      final l = _clean(d.label);
      if (l.isNotEmpty) parts.add(l);
      n.visitChildren((c) {
        go(c);
        return true;
      });
    }

    node.visitChildren((c) {
      go(c);
      return true;
    });
    final s = parts.join(' · ');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  void walk(SemanticsNode node, bool noAct) {
    final d = node.getSemanticsData();
    if (d.identifier == kNoScreenContextId) return;
    final f = d.flagsCollection;
    if (f.isHidden) return;
    final na = noAct || d.identifier == kNoAymaActionId;
    final label = _clean(d.label);
    final type = _typeOf(d);
    if (f.namesRoute && title.isEmpty && label.isNotEmpty) title = label;
    if (type == null) {
      if (label.isNotEmpty) {
        lastText = label;
        addText(f.isHeader ? '# $label' : label);
        if (f.isHeader && firstHeader.isEmpty) firstHeader = label;
      }
      node.visitChildren((c) {
        walk(c, na);
        return true;
      });
      return;
    }
    final hint = _clean(d.hint);
    final value = _clean(d.value);
    final captioned = type == 'field' || type == 'slider';
    var name = label.isNotEmpty
        ? label
        : (captioned && lastText.isNotEmpty ? lastText : hint);
    var descend = true;
    if (name.isEmpty && type != 'list' && type != 'field') {
      name = gatherText(node);
      descend = false;
    }
    if (name.isEmpty && type == 'list') name = 'list';
    final secret = type == 'field' &&
        (f.isObscured || _matches(kSecretFieldPattern, name));
    final state = switch (type) {
      'switch' => f.isToggled == Tristate.isTrue ? 'on' : 'off',
      'checkbox' => switch (f.isChecked) {
          CheckedState.isTrue => 'checked',
          CheckedState.mixed => 'mixed',
          _ => 'unchecked',
        },
      'radio' => f.isChecked == CheckedState.isTrue ? 'selected' : '',
      'field' => secret ? '(hidden)' : '"$value"',
      'slider' => value,
      'tab' => f.isSelected == Tristate.isTrue ? 'selected' : '',
      _ => value,
    };
    final disabled = f.isEnabled == Tristate.isFalse ? ' (disabled)' : '';
    raw.add((
      nodeId: node.id,
      type: type,
      label: name,
      state: '$state$disabled'.trim(),
      noAct: na,
    ));
    if (descend) {
      node.visitChildren((c) {
        walk(c, na);
        return true;
      });
    }
  }

  walk(root, false);
  if (title.isEmpty) title = firstHeader;
  final dialogText = dialogOpen
      ? [...texts, ...raw.map((c) => c.label)].join(' ')
      : '';
  final counts = <String, int>{};
  final controls = [
    for (final c in raw)
      ScreenControl(
        id: '${_typePrefix[c.type]}'
            '${counts.update(c.type, (n) => n + 1, ifAbsent: () => 1)}',
        nodeId: c.nodeId,
        type: c.type,
        label: c.label,
        state: c.state,
        noAct: c.noAct,
        denial: uiDenial(
            label: c.label, type: c.type, route: route, dialogText: dialogText),
      ),
  ];
  return ScreenSnapshot(
    route: route,
    title: title,
    text: texts.join('\n'),
    controls: controls,
    dialogText: dialogText,
  );
}

/// The result of one `ui_action`.
@immutable
class UiActionResult {
  const UiActionResult.done(this.result) : ok = true, reason = '';
  const UiActionResult.refused(this.reason) : ok = false, result = '';
  final bool ok;
  final String reason;
  final String result;
}

const _ops = {
  'tap': SemanticsAction.tap,
  'long_press': SemanticsAction.longPress,
  'increase': SemanticsAction.increase,
  'decrease': SemanticsAction.decrease,
  // "scroll down" = show what is below = the content moves up.
  'scroll_down': SemanticsAction.scrollUp,
  'scroll_up': SemanticsAction.scrollDown,
  'dismiss': SemanticsAction.dismiss,
};

/// Ops that repeat one scroll step until the list reaches the end (handled in
/// [ScreenCapture.perform], not through [_ops]).
const _scrollEndOps = {'scroll_to_bottom', 'scroll_to_top'};

/// How many scroll steps a scroll-to-end op runs before giving up (a growing
/// or paginated list never truly ends).
const int kScrollToEndMaxSteps = 50;

/// How many substantial end-extent growths (a paginated list loading its next
/// page as we approach the bottom) [_scrollToEnd] tolerates before it concludes
/// the list has no reachable end and stops honestly. A finite list's extent is
/// stable, so this never fires for it — only a growing/paginated list (Explore)
/// trips it, well before the step cap, so the op returns inside the backend's
/// ack window instead of grinding all [kScrollToEndMaxSteps] (GW-SCROLL variant
/// B: an Explore scroll overran the ack bound and the whole turn evaporated).
const int kScrollToEndMaxGrowths = 3;

/// The minimum end-extent jump that counts as "the list grew a page" (filters
/// out small reflow from images decoding on a finite list).
const double _kScrollGrowthThreshold = 200;

String _norm(String s) => _clean(s).toLowerCase();

bool _sameLabel(String a, String b) {
  final x = _norm(a), y = _norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
}

/// Tracks dialogs/sheets (popup routes) on the root navigator, so a capture
/// knows a dialog is on top and `back` can pop it.
class PopupTracker extends NavigatorObserver {
  int _popups = 0;
  bool get popupOpen => _popups > 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _popups++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute && _popups > 0) _popups--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute && _popups > 0) _popups--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PopupRoute && _popups > 0) _popups--;
    if (newRoute is PopupRoute) _popups++;
  }
}

/// Wired into the app router's `observers` next to `screenRouteObserver`.
final PopupTracker screenPopupTracker = PopupTracker();

/// App-wide capture + executor. [attach] (from `main.dart`) keeps semantics
/// on and refreshes [AppContext] (debounced) whenever the route or the
/// screen slug changes; [setLive] adds a periodic refresh during a voice
/// call so changes inside a screen (a list loading, a toggle) reach Ayma.
class ScreenCapture {
  ScreenCapture({
    this._routeOf,
    bool Function()? popupOpen,
    SemanticsNode? Function()? root,
    Future<void> Function()? settle,
    Future<bool> Function()? back,
    this._beforeAct,
  })  : _popupOpen = popupOpen ?? (() => screenPopupTracker.popupOpen),
        _root = root ?? _defaultRoot,
        _settle = settle ?? _defaultSettle,
        _back = back ?? _defaultBack;

  static final ScreenCapture instance = ScreenCapture();

  String Function()? _routeOf;
  final bool Function() _popupOpen;
  final SemanticsNode? Function() _root;
  final Future<void> Function() _settle;
  final Future<bool> Function() _back;

  /// Runs before an operation (the app closes its own Ayma chat popup, whose
  /// modal barrier hides the page's controls).
  Future<void> Function()? _beforeAct;

  SemanticsHandle? _semantics;
  Timer? _debounce;
  Timer? _live;
  String _lastKey = '';

  static const _debounceDelay = Duration(milliseconds: 400);
  static const _liveInterval = Duration(seconds: 2);

  static SemanticsNode? _defaultRoot() {
    for (final view in RendererBinding.instance.renderViews) {
      final node = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (node != null) return node;
    }
    return null;
  }

  static SemanticsOwner? _owner() {
    for (final view in RendererBinding.instance.renderViews) {
      final owner = view.owner?.semanticsOwner;
      if (owner != null) return owner;
    }
    return null;
  }

  static Future<void> _defaultSettle() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  }

  static Future<bool> _defaultBack() async =>
      await screenPopupTracker.navigator?.maybePop() ?? false;

  /// The current route pattern (e.g. `/dm/:threadId`), '' when unknown.
  String currentRoute() {
    try {
      return _routeOf?.call() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Closes Ayma's own chat popup if it is open (the `beforeAct` hook given
  /// to [attach]), so an Ayma-driven navigation lands on a visible page.
  Future<void> closeAymaPopup() async {
    final before = _beforeAct;
    if (before != null) await before();
  }

  /// Start capturing for [router]'s screens. Keeps the semantics tree built
  /// (what screen readers use) for the app's lifetime.
  void attach(GoRouter router, {Future<void> Function()? beforeAct}) {
    _routeOf = () {
      final s = router.state;
      return s.fullPath ?? s.matchedLocation;
    };
    _beforeAct = beforeAct;
    AppContext.instance.routeOf = currentRoute;
    _semantics ??= SemanticsBinding.instance.ensureSemantics();
    router.routerDelegate.addListener(schedule);
    AppContext.instance.current.addListener(_onContext);
  }

  void _onContext() {
    final c = AppContext.instance.current.value;
    final key = '${c.screen}|${c.subjectUid}|${c.note}';
    if (key == _lastKey) return;
    _lastKey = key;
    schedule();
  }

  /// Debounced [refreshNow].
  void schedule() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, refreshNow);
  }

  /// While a voice call is live, refresh every couple of seconds.
  void setLive(bool live) {
    _live?.cancel();
    _live = live ? Timer.periodic(_liveInterval, (_) => refreshNow()) : null;
    if (live) refreshNow();
  }

  /// Capture now and publish it on [AppContext] (a no-op when unchanged).
  void refreshNow() {
    final snap = capture();
    AppContext.instance.applyCapture(route: snap.route, visible: snap.visible);
  }

  /// Read what is on screen now. Empty on a no-context route, or when
  /// semantics isn't built (no binding, tests without semantics).
  ScreenSnapshot capture() {
    final route = currentRoute();
    if (kNoContextRoutes.containsKey(route)) {
      return ScreenSnapshot(
          route: route, title: '', text: '', controls: const [], dialogText: '');
    }
    SemanticsNode? root;
    try {
      root = _root();
    } catch (_) {
      root = null;
    }
    if (root == null) {
      return ScreenSnapshot(
          route: route, title: '', text: '', controls: const [], dialogText: '');
    }
    return captureSemantics(root, route: route, dialogOpen: _popupOpen());
  }

  /// Run one `ui_action`: [control] is the id from the capture Ayma read,
  /// [label] the label she saw (checked against the live control), [op] one
  /// of tap, long_press, set_text, increase, decrease, scroll_down,
  /// scroll_up, dismiss, back.
  Future<UiActionResult> perform({
    required String control,
    required String label,
    required String op,
    String value = '',
  }) async {
    if (op == 'back') {
      final popped = await _back();
      if (!popped) {
        return const UiActionResult.refused(
            'there is nothing to go back to from this screen');
      }
      await _settle();
      return UiActionResult.done(capture().visible);
    }
    if (op != 'set_text' && !_ops.containsKey(op) && !_scrollEndOps.contains(op)) {
      return UiActionResult.refused("'$op' isn't something Ayma can do here");
    }
    final before = _beforeAct;
    if (before != null) await before();
    final snap = capture();
    if (kNoContextRoutes.containsKey(snap.route)) {
      return const UiActionResult.refused(
          'this screen is never operated by Ayma');
    }
    final target = _resolve(snap, control, label, op);
    if (target == null) {
      // A scroll with nothing scrollable on the page isn't a failure: the page
      // already fits on screen (a short Explore grid, a short list). Say so
      // honestly rather than refusing — a refusal tells the model to "read the
      // screen again", so it retries and its follow-up produces no reply at all
      // (GW-SCROLL: the short Explore grid surfaced the generic "I couldn't
      // finish that"). A named control that is genuinely gone still refuses.
      final nothingScrollable = !snap.controls.any((c) => c.type == 'list');
      if (op.startsWith('scroll') && nothingScrollable) {
        final where = op == 'scroll_to_top' ? 'the top' : 'the bottom';
        final head = _scrollEndOps.contains(op)
            ? 'Reached $where — the whole page already fits on screen.'
            : 'Nothing to scroll — the whole page already fits on screen.';
        return UiActionResult.done('$head\n${snap.visible}');
      }
      return const UiActionResult.refused(
          "that control isn't on screen any more; read the screen again");
    }
    if (target.noAct) {
      return const UiActionResult.refused(
          'the app keeps that control for the user to tap themselves');
    }
    if (target.denial != null) return UiActionResult.refused(target.denial!);
    if (op == 'set_text' && target.type != 'field') {
      return const UiActionResult.refused('set_text only works on a field');
    }
    final owner = _owner();
    if (owner == null) {
      return const UiActionResult.refused('the screen could not be read');
    }
    if (op == 'set_text') {
      if (!_hasAction(target.nodeId, SemanticsAction.setText)) {
        owner.performAction(target.nodeId, SemanticsAction.tap);
        await _settle();
      }
      if (!_hasAction(target.nodeId, SemanticsAction.setText)) {
        return const UiActionResult.refused("that field can't be typed into");
      }
      owner.performAction(target.nodeId, SemanticsAction.setText, value);
    } else if (_scrollEndOps.contains(op)) {
      // "to the bottom" = reveal what is below = content moves up.
      final action = op == 'scroll_to_bottom'
          ? SemanticsAction.scrollUp
          : SemanticsAction.scrollDown;
      final end = await _scrollToEnd(owner, target.nodeId, action);
      final where = op == 'scroll_to_bottom' ? 'the bottom' : 'the top';
      final head = end.reachedEnd
          ? 'Reached $where.'
          : 'Stopped after ${end.steps} scrolls — more content may remain.';
      return UiActionResult.done('$head\n${capture().visible}');
    } else {
      final action = _ops[op]!;
      if (!_hasAction(target.nodeId, action)) {
        return UiActionResult.refused(
            "'${target.label}' doesn't support $op");
      }
      // increase/decrease/scroll may repeat: `value` is a 1–20 count.
      final times = (op == 'increase' ||
              op == 'decrease' ||
              op == 'scroll_down' ||
              op == 'scroll_up')
          ? (int.tryParse(value.trim()) ?? 1).clamp(1, 20)
          : 1;
      for (var i = 0; i < times; i++) {
        owner.performAction(target.nodeId, action);
      }
    }
    await _settle();
    return UiActionResult.done(capture().visible);
  }

  ScreenControl? _resolve(
      ScreenSnapshot snap, String control, String label, String op) {
    final id = control.trim().toLowerCase();
    if (id.isEmpty && op.startsWith('scroll')) {
      for (final c in snap.controls) {
        if (c.type == 'list') return c;
      }
      return null;
    }
    for (final c in snap.controls) {
      if (c.id == id && (label.trim().isEmpty || _sameLabel(c.label, label))) {
        return c;
      }
    }
    final byLabel = [
      for (final c in snap.controls)
        if (_sameLabel(c.label, label)) c,
    ];
    return byLabel.length == 1 ? byLabel.single : null;
  }

  bool _hasAction(int nodeId, SemanticsAction action) =>
      _nodeData(nodeId)?.hasAction(action) ?? false;

  /// The live [SemanticsData] of node [nodeId], or null if it is gone.
  SemanticsData? _nodeData(int nodeId) {
    final root = _root();
    if (root == null) return null;
    SemanticsNode? found;
    bool find(SemanticsNode n) {
      if (n.id == nodeId) {
        found = n;
        return false;
      }
      n.visitChildren(find);
      return found == null;
    }

    find(root);
    return found?.getSemanticsData();
  }

  /// Repeats one scroll [action] on node [nodeId] until the list stops moving
  /// — the action drops off (nothing left in that direction) or the scroll
  /// offset settles — capped at [kScrollToEndMaxSteps]. A list already at the
  /// end runs zero steps and still counts as reached. Returns whether the end
  /// was reached and how many scrolls ran (settling between each).
  Future<({bool reachedEnd, int steps})> _scrollToEnd(
      SemanticsOwner owner, int nodeId, SemanticsAction action) async {
    var steps = 0;
    var growths = 0;
    double? lastMax;
    for (var i = 0; i < kScrollToEndMaxSteps; i++) {
      final before = _nodeData(nodeId);
      if (before == null || !before.hasAction(action)) {
        return (reachedEnd: true, steps: steps);
      }
      owner.performAction(nodeId, action);
      await _settle();
      steps++;
      final after = _nodeData(nodeId);
      if (after == null || !after.hasAction(action)) {
        return (reachedEnd: true, steps: steps);
      }
      final a = before.scrollPosition, b = after.scrollPosition;
      if (a != null && b != null && (a - b).abs() < 0.5) {
        return (reachedEnd: true, steps: steps);
      }
      // A paginated list extends its end as we approach it, so it never settles
      // and would grind the full step cap — long enough to overrun the backend
      // ack bound and lose the turn. Count the page-loads; once the end has run
      // away this many times, stop honestly ("more may remain") well in time. A
      // finite list's extent is stable, so this never fires for it.
      final mx = after.scrollExtentMax;
      if (mx != null) {
        if (lastMax != null && mx > lastMax + _kScrollGrowthThreshold) {
          growths++;
          if (growths >= kScrollToEndMaxGrowths) {
            return (reachedEnd: false, steps: steps);
          }
        }
        lastMax = mx;
      }
    }
    return (reachedEnd: false, steps: steps);
  }
}
