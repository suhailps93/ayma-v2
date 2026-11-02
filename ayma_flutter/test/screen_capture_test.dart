import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The generic screen context + ui_action executor. The policy constants
/// must match `functions/bootstrap/app_registry.json` (the backend enforces
/// the same rules on the label the model passes).
Map<String, dynamic> _registry() => jsonDecode(
        File('../functions/bootstrap/app_registry.json').readAsStringSync())
    as Map<String, dynamic>;

Set<String> _routerPaths(List<RouteBase> routes, [String parent = '']) {
  final out = <String>{};
  for (final r in routes) {
    var path = parent;
    if (r is GoRoute) {
      path = r.path.startsWith('/') ? r.path : '$parent/${r.path}';
      out.add(path);
    }
    out.addAll(_routerPaths(r.routes, path));
  }
  return out;
}

/// A page shaped like Settings / Edit profile / Explore filters.
class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  bool dark = false;
  bool agreed = false;
  bool hiking = false;
  double distance = 5;
  int deletes = 0;
  int subscribes = 0;
  int secretTaps = 0;
  final name = TextEditingController(text: 'Alex');
  final password = TextEditingController(text: 'hunter2');

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          Semantics(header: true, child: const Text('Appearance')),
          const Text('Choose how Ayma looks.'),
          SwitchListTile(
            title: const Text('Dark mode'),
            value: dark,
            onChanged: (v) => setState(() => dark = v),
          ),
          FilterChip(
            label: const Text('Hiking'),
            selected: hiking,
            onSelected: (v) => setState(() => hiking = v),
          ),
          Slider(
            value: distance,
            max: 10,
            divisions: 10,
            label: 'Distance',
            semanticFormatterCallback: (v) => '${v.round()} miles',
            onChanged: (v) => setState(() => distance = v),
          ),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'First name'),
          ),
          TextField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          CheckboxListTile(
            title: const Text('I agree to the Terms of Service'),
            value: agreed,
            onChanged: (v) => setState(() => agreed = v ?? false),
          ),
          TextButton(
            onPressed: () => setState(() => deletes++),
            child: const Text('Delete account'),
          ),
          TextButton(
            onPressed: () => setState(() => subscribes++),
            child: const Text('Subscribe to Pro'),
          ),
          NoAymaAction(
            child: TextButton(
              onPressed: () => setState(() => secretTaps++),
              child: const Text('Report a problem'),
            ),
          ),
          const NoScreenContext(child: Text('Private note: card ending 4242')),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Delete this photo?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () {
                        setState(() => deletes++);
                        Navigator.pop(c);
                      },
                      child: const Text('Delete')),
                ],
              ),
            ),
            child: const Text('Photo options'),
          ),
        ]),
      );
}

/// A long but finite list (overflows the viewport, has a real end).
class _LongList extends StatelessWidget {
  const _LongList({this.controller});
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(
          controller: controller,
          children: [
            for (var i = 0; i < 60; i++)
              SizedBox(height: 120, child: Text('Row $i')),
          ],
        ),
      );
}

/// A paginated list: every time it nears the bottom it grows, so the end is a
/// moving target and scroll-to-bottom can never truly settle.
class _GrowingList extends StatefulWidget {
  const _GrowingList();
  @override
  State<_GrowingList> createState() => _GrowingListState();
}

class _GrowingListState extends State<_GrowingList> {
  final _ctrl = ScrollController();
  int _count = 40;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      if (_ctrl.hasClients &&
          _ctrl.position.pixels >= _ctrl.position.maxScrollExtent - 1) {
        setState(() => _count += 40);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView.builder(
          controller: _ctrl,
          itemCount: _count,
          itemBuilder: (c, i) => SizedBox(height: 120, child: Text('Item $i')),
        ),
      );
}

Future<(ScreenCapture, PopupTracker)> _pump(WidgetTester tester,
    {String route = '/settings'}) async {
  final popups = PopupTracker();
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [popups],
    home: const _Page(),
  ));
  final cap = ScreenCapture(
    routeOf: () => route,
    popupOpen: () => popups.popupOpen,
    settle: () => tester.pumpAndSettle(),
    back: () async => await popups.navigator?.maybePop() ?? false,
  );
  return (cap, popups);
}

ScreenControl _control(ScreenSnapshot s, String label) =>
    s.controls.firstWhere((c) => c.label.contains(label));

_PageState _state(WidgetTester tester) => tester.state(find.byType(_Page));

void main() {
  test('policy constants match app_registry.json', () {
    final policy = _registry()['ui_action_policy'] as Map<String, dynamic>;
    final deny = (policy['deny'] as List).cast<Map<String, dynamic>>();
    expect(kUiDenyRules.length, deny.length);
    for (var i = 0; i < deny.length; i++) {
      final r = kUiDenyRules[i];
      expect(r.key, deny[i]['key']);
      expect(r.pattern, deny[i]['pattern']);
      expect(r.say, deny[i]['say']);
      expect(r.routes, (deny[i]['routes'] as List?) ?? const []);
      expect(r.types, (deny[i]['types'] as List?) ?? const []);
    }
    expect(kUiDenyRoutes, {
      for (final d in (policy['deny_routes'] as List)) d['route']: d['reason'],
    });
    expect(kUiEscapePattern, policy['escape_pattern']);
    expect(kSecretFieldPattern, policy['secret_field_pattern']);
    expect(kSecretFieldSay, policy['secret_field_say']);
    final ctx = _registry()['screen_context'] as Map<String, dynamic>;
    expect(kScreenContextMaxChars, ctx['max_chars']);
    expect(kNoContextRoutes, {
      for (final n in (ctx['no_context'] as List)) n['route']: n['reason'],
    });
  });

  test('every routed screen sends context, or opts out with a reason', () {
    final routes = _routerPaths(appRouter.configuration.routes);
    final reg = _registry();
    final named = <String>{
      for (final d in reg['destinations'] as List)
        (d['path'] as String).split('?').first,
      for (final p in reg['parameterized'] as List) p['route'] as String,
      for (final n in reg['non_navigable'] as List) n['route'] as String,
    };
    for (final r in routes) {
      final optOut = kNoContextRoutes[r];
      if (optOut != null) {
        expect(optOut.trim(), isNotEmpty, reason: r);
      } else {
        // Captured generically; the backend must be able to name it.
        expect(named, contains(r), reason: '$r has no context provider name');
      }
    }
    expect(routes, containsAll(kNoContextRoutes.keys));
    // The capture is wired into the real router.
    expect(appRouter.configuration.navigatorKey, isNotNull);
  });

  testWidgets('capture lists text, headings and every control with state; '
      'redacts secrets and NoScreenContext', (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, _) = await _pump(tester);
    final s = cap.capture();
    expect(s.route, '/settings');
    expect(s.title, 'Settings');
    expect(s.text, contains('# Appearance'));
    expect(s.text, contains('Choose how Ayma looks.'));
    expect(_control(s, 'Dark mode').type, 'switch');
    expect(_control(s, 'Dark mode').state, 'off');
    expect(_control(s, 'Hiking').state, isNot(contains('selected')));
    expect(_control(s, 'First name').state, '"Alex"');
    expect(_control(s, 'Password').state, '(hidden)');
    expect(_control(s, 'I agree').type, 'checkbox');
    final v = s.visible;
    expect(v, isNot(contains('hunter2')));
    expect(v, isNot(contains('4242')));
    expect(v, contains('"Delete account" (user only)'));
    expect(v, contains('"Subscribe to Pro" (user only)'));
    expect(v, contains('"Report a problem" (user only)'));
    expect(v, contains('"Dark mode" = off'));
    expect(v.contains('Dark mode" = off (user only)'), isFalse);
    handle.dispose();
  });

  testWidgets('capture is capped', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          for (var i = 0; i < 200; i++)
            TextButton(onPressed: () {}, child: Text('Option number $i')),
          for (var i = 0; i < 200; i++) Text('Line of text number $i'),
        ]),
      ),
    ));
    final s = ScreenCapture(routeOf: () => '/explore').capture();
    expect(s.text.length, lessThanOrEqualTo(kScreenContextMaxChars + 1));
    expect(s.visible.length, lessThanOrEqualTo(2 * kScreenContextMaxChars + 80));
    handle.dispose();
  });

  testWidgets('no-context routes send nothing', (tester) async {
    final handle = tester.ensureSemantics();
    final (_, _) = await _pump(tester);
    final s = ScreenCapture(routeOf: () => '/signin').capture();
    expect(s.visible, isEmpty);
    handle.dispose();
  });

  testWidgets('ui_action toggles, picks, slides and types on allowed controls',
      (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, _) = await _pump(tester);
    var s = cap.capture();
    final sw = _control(s, 'Dark mode');
    final r1 = await cap.perform(control: sw.id, label: 'Dark mode', op: 'tap');
    expect(r1.ok, isTrue, reason: r1.reason);
    expect(_state(tester).dark, isTrue);
    expect(r1.result, contains('"Dark mode" = on'));

    s = cap.capture();
    final chip = _control(s, 'Hiking');
    expect((await cap.perform(control: chip.id, label: 'Hiking', op: 'tap')).ok,
        isTrue);
    expect(_state(tester).hiking, isTrue);

    s = cap.capture();
    final slider = s.controls.firstWhere((c) => c.type == 'slider');
    final r3 = await cap.perform(
        control: slider.id, label: slider.label, op: 'increase', value: '2');
    expect(r3.ok, isTrue, reason: r3.reason);
    expect(_state(tester).distance, greaterThan(5));

    s = cap.capture();
    final field = _control(s, 'First name');
    final r4 = await cap.perform(
        control: field.id, label: 'First name', op: 'set_text', value: 'Sam');
    expect(r4.ok, isTrue, reason: r4.reason);
    expect(_state(tester).name.text, 'Sam');
    handle.dispose();
  });

  testWidgets('ui_action refuses delete, purchase, consent, secrets and '
      'NoAymaAction controls', (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, _) = await _pump(tester);
    final s = cap.capture();
    for (final (label, op) in [
      ('Delete account', 'tap'),
      ('Subscribe to Pro', 'tap'),
      ('I agree', 'tap'),
      ('Password', 'set_text'),
      ('Report a problem', 'tap'),
    ]) {
      final c = _control(s, label);
      final r = await cap.perform(
          control: c.id, label: c.label, op: op, value: 'x');
      expect(r.ok, isFalse, reason: label);
      expect(r.reason, isNotEmpty);
    }
    final st = _state(tester);
    expect(st.deletes, 0);
    expect(st.subscribes, 0);
    expect(st.agreed, isFalse);
    expect(st.secretTaps, 0);
    expect(st.password.text, 'hunter2');
    handle.dispose();
  });

  testWidgets('a denied route refuses every control but back', (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, _) = await _pump(tester, route: '/settings/delete-account');
    final s = cap.capture();
    final sw = _control(s, 'Dark mode');
    final r = await cap.perform(control: sw.id, label: 'Dark mode', op: 'tap');
    expect(r.ok, isFalse);
    expect(_state(tester).dark, isFalse);
    handle.dispose();
  });

  testWidgets('in a dialog about a denied action only cancel works; back pops',
      (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, popups) = await _pump(tester);
    var s = cap.capture();
    final opts = _control(s, 'Photo options');
    expect((await cap.perform(control: opts.id, label: 'Photo options', op: 'tap'))
        .ok, isTrue);
    expect(popups.popupOpen, isTrue);
    s = cap.capture();
    expect(s.dialogText, contains('Delete this photo?'));
    final del = s.controls.firstWhere((c) => c.label == 'Delete');
    expect((await cap.perform(control: del.id, label: 'Delete', op: 'tap')).ok,
        isFalse);
    expect(_state(tester).deletes, 0);
    final cancel = _control(s, 'Cancel');
    expect(cancel.denial, isNull);
    final back = await cap.perform(control: '', label: '', op: 'back');
    expect(back.ok, isTrue);
    expect(popups.popupOpen, isFalse);
    handle.dispose();
  });

  testWidgets('a stale id resolves by label; an unknown control is refused',
      (tester) async {
    final handle = tester.ensureSemantics();
    final (cap, _) = await _pump(tester);
    final r = await cap.perform(control: 'b99', label: 'Dark mode', op: 'tap');
    expect(r.ok, isTrue, reason: r.reason);
    final gone =
        await cap.perform(control: 'b99', label: 'No such thing', op: 'tap');
    expect(gone.ok, isFalse);
    handle.dispose();
  });

  testWidgets('scroll_to_bottom reaches the end of a finite list in one op',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: _LongList()));
    final cap = ScreenCapture(
      routeOf: () => '/explore',
      settle: () => tester.pumpAndSettle(),
    );
    final list = cap.capture().controls.firstWhere((c) => c.type == 'list');
    final r = await cap.perform(
        control: list.id, label: list.label, op: 'scroll_to_bottom');
    expect(r.ok, isTrue, reason: r.reason);
    expect(r.result, contains('Reached the bottom.'));
    // Genuinely at the end: a further scroll_down has nothing left to do.
    final again = await cap.perform(
        control: list.id, label: list.label, op: 'scroll_down');
    expect(again.ok, isFalse);
    handle.dispose();
  });

  testWidgets('scroll_to_bottom on a growing list stops at the cap, honestly',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: _GrowingList()));
    final cap = ScreenCapture(
      routeOf: () => '/explore',
      settle: () => tester.pumpAndSettle(),
    );
    final list = cap.capture().controls.firstWhere((c) => c.type == 'list');
    final r = await cap.perform(
        control: list.id, label: list.label, op: 'scroll_to_bottom');
    expect(r.ok, isTrue, reason: r.reason);
    expect(r.result, contains('more content may remain'));
    expect(r.result,
        contains('Stopped after $kScrollToEndMaxSteps scrolls'));
    expect(r.result, isNot(contains('Reached the bottom')));
    handle.dispose();
  });

  testWidgets('scroll_down with a repeat count moves further than one step',
      (tester) async {
    final handle = tester.ensureSemantics();
    final ctrl = ScrollController();
    await tester.pumpWidget(MaterialApp(home: _LongList(controller: ctrl)));
    final cap = ScreenCapture(
      routeOf: () => '/explore',
      settle: () => tester.pumpAndSettle(),
    );
    final list = cap.capture().controls.firstWhere((c) => c.type == 'list');
    final one = await cap.perform(
        control: list.id, label: list.label, op: 'scroll_down');
    expect(one.ok, isTrue, reason: one.reason);
    final afterOne = ctrl.position.pixels;
    ctrl.jumpTo(0);
    await tester.pumpAndSettle();
    final three = await cap.perform(
        control: list.id, label: list.label, op: 'scroll_down', value: '3');
    expect(three.ok, isTrue, reason: three.reason);
    expect(ctrl.position.pixels, greaterThan(afterOne));
    handle.dispose();
  });

  // GW-SCROLL regression: "scroll to the bottom" arrives while the
  // page-context "Ask Ayma" sheet is up. perform() closes that sheet first
  // (`_beforeAct`, wired in startup_nodes.dart) to reveal the page, then runs
  // the scroll. The command handler (AppCommandService.shared) is app-level,
  // not tied to the sheet's widget lifecycle, so the scroll must still run to
  // the end and report the honest result even though the sheet was dismissed
  // mid-command. Covers Scout's two specimens: a pinned profile and Explore,
  // both reached through the chat sheet.
  for (final route in const ['/explore', '/profile/user/u1']) {
    testWidgets(
        'scroll_to_bottom scrolls the page revealed when the Ask Ayma sheet '
        'is dismissed first ($route)', (tester) async {
      final handle = tester.ensureSemantics();
      final ctrl = ScrollController();
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: ListView(controller: ctrl, children: [
            for (var i = 0; i < 60; i++)
              SizedBox(height: 120, child: Text('Row $i')),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      // The page-context "Ask Ayma" sheet sits over the page.
      var sheetOpen = true;
      unawaited(showModalBottomSheet<void>(
        context: navKey.currentContext!,
        builder: (_) => const SizedBox(
            height: 200, child: Center(child: Text('Ask Ayma'))),
      ).whenComplete(() => sheetOpen = false));
      await tester.pumpAndSettle();
      expect(find.text('Ask Ayma'), findsOneWidget);
      expect(ctrl.position.pixels, 0);

      final cap = ScreenCapture(
        routeOf: () => route,
        settle: () => tester.pumpAndSettle(),
        back: () async => await navKey.currentState?.maybePop() ?? false,
        // Exactly as startup_nodes wires it: close the sheet, reveal the page.
        beforeAct: () async {
          if (!sheetOpen) return;
          navKey.currentState?.pop();
          await tester.pumpAndSettle();
        },
      );

      final r =
          await cap.perform(control: '', label: '', op: 'scroll_to_bottom');
      await tester.pumpAndSettle();

      // The sheet was dismissed, the page under it scrolled to the end, and
      // the honest at-end result came back in the one command.
      expect(find.text('Ask Ayma'), findsNothing);
      expect(r.ok, isTrue, reason: r.reason);
      expect(r.result, contains('Reached the bottom.'));
      expect(ctrl.position.pixels, greaterThan(0));
      handle.dispose();
    });
  }

  test('a screen slug set on another route is dropped by the next capture',
      () {
    var route = '/profile';
    final ctx = AppContext.instance;
    ctx.routeOf = () => route;
    ctx.set(screen: 'profile_tab');
    ctx.applyCapture(route: '/profile', visible: 'You');
    expect(ctx.current.value.screen, 'profile_tab');
    expect(ctx.current.value.visible, 'You');
    route = '/settings';
    ctx.applyCapture(route: '/settings', visible: 'Settings');
    expect(ctx.current.value.screen, '');
    expect(ctx.current.value.route, '/settings');
    expect(ctx.current.value.toJson()['visible'], 'Settings');
    ctx.routeOf = null;
    ctx.clear();
  });
}
