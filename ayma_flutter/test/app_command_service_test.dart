import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppContext.instance.pendingExploreQuery = null;
    AppContext.instance.clear();
  });

  test('navigate command routes to the mapped path', () {
    final nav = <String>[];
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'navigate', 'screen': 'matches'});
    expect(nav, ['/matches']);
  });

  test('search_explore stashes the trimmed query and opens Explore', () {
    final nav = <String>[];
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'search_explore', 'query': '  hiking  '});
    expect(AppContext.instance.pendingExploreQuery, 'hiking');
    expect(nav, ['/explore']);
  });

  test('open_profile routes to that user', () {
    final nav = <String>[];
    AppCommandService(navigate: nav.add)
        .handleCommand({'action': 'open_profile', 'uid': 'u-9'});
    expect(nav, ['/profile/user/u-9']);
  });

  test('unknown screen / action / empty uid are ignored', () {
    final nav = <String>[];
    final svc = AppCommandService(navigate: nav.add)
      ..handleCommand({'action': 'navigate', 'screen': 'bogus'})
      ..handleCommand({'action': 'frobnicate'})
      ..handleCommand({'action': 'open_profile', 'uid': ''});
    expect(nav, isEmpty);
    expect(svc, isNotNull);
  });
}
