import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// `functions/bootstrap/app_registry.json` is the single source of truth for
/// every page Ayma can open and every setting she can change by voice or text.
/// These tests walk the real [appRouter] so a new route that is neither a
/// registered destination nor listed (with a reason) as parameterized or
/// non-navigable fails the build, and every registered client setting is
/// checked to actually execute here.
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

List<Map<String, dynamic>> _list(String key) =>
    (_registry()[key] as List).cast<Map<String, dynamic>>();

void main() {
  final routes = _routerPaths(appRouter.configuration.routes);

  test('every GoRoute is registered or explicitly non-navigable with a reason',
      () {
    final known = <String>{
      for (final d in _list('destinations'))
        (d['path'] as String).split('?').first,
      for (final p in _list('parameterized')) p['route'] as String,
      for (final n in _list('non_navigable')) n['route'] as String,
    };
    for (final n in [..._list('non_navigable'), ..._list('parameterized')]) {
      expect((n['reason'] as String).trim(), isNotEmpty, reason: '$n');
    }
    final missing = routes.difference(known);
    expect(missing, isEmpty,
        reason: 'add these routes to functions/bootstrap/app_registry.json '
            '(a destination, or non_navigable with a reason)');
    expect(known.difference(routes), isEmpty,
        reason: 'registry lists routes app_router.dart no longer has');
  });

  test('every destination path navigates through the command service', () {
    for (final d in _list('destinations')) {
      final nav = <String>[];
      final ok = AppCommandService(navigate: nav.add).handleCommand({
        'action': 'navigate',
        'screen': d['key'],
        'path': d['path'],
      });
      expect(ok, isTrue, reason: d['key'] as String);
      expect(nav, [d['path']]);
    }
  });

  test('every client-held setting value executes in the app', () {
    // Pause/resume and accent need Firebase-backed services; their dispatch
    // is covered in app_command_service_test.dart.
    const coveredElsewhere = {
      'pause_matching', 'accent_color', 'date_moments',
      // Firebase-backed ProfileService writes — dispatch covered in
      // app_command_service_test.dart with a mock-auth ProfileService.
      'location_log', 'location_master', 'location_background',
    };
    for (final s in _list('settings').where((s) =>
        s['handler'] == 'client' && !coveredElsewhere.contains(s['key']))) {
      final command = s['client_command'];
      final samples = <Map<String, dynamic>>[
        if (command is Map)
          for (final name in command.values)
            {'action': 'app_action', 'name': name}
        else if (s['kind'] == 'hex')
          {'action': 'app_action', 'name': command, 'value': '#2E9E5B'}
        else
          for (final v in ['on', 'off'])
            {'action': 'app_action', 'name': command, 'value': v},
      ];
      for (final cmd in samples) {
        final svc = AppCommandService(
          themeController: ThemeController(),
        );
        expect(svc.handleCommand(cmd), isTrue, reason: '$cmd');
      }
    }
  });

  test('client account actions are handled (they run after the ack)', () {
    for (final a in _list('account_actions')
        .where((a) => a['handler'] == 'client')) {
      expect(
          AppCommandService()
              .handleCommand({'action': 'app_action', 'name': a['key']}),
          isTrue,
          reason: a['key'] as String);
    }
  });
}
