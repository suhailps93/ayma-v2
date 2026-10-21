// Re-tapping the tab you are already on must do nothing: no onSelected call
// for the selected tab, and no second push of Notifications from the
// Notifications screen's own bar.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
    b.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(() {
      b.platformDispatcher.clearAllTestValues();
      b.platformDispatcher.views.first.resetPhysicalSize();
      b.platformDispatcher.views.first.resetDevicePixelRatio();
    });
  });

  Widget host({
    required int index,
    required List<int> selected,
    required List<String> pushed,
    bool notificationsActive = false,
  }) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
            bottomNavigationBar: AymaTabBar(
              index: index,
              voice: null,
              notificationsActive: notificationsActive,
              onSelected: selected.add,
            ),
          ),
        ),
        GoRoute(
          path: '/notifications',
          builder: (_, __) {
            pushed.add('/notifications');
            return const Scaffold(body: Text('NOTIFICATIONS'));
          },
        ),
      ],
    );
    return MaterialApp.router(theme: AymaTheme.light, routerConfig: router);
  }

  testWidgets('tapping the already-selected tab does not fire onSelected', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(index: 1, selected: selected, pushed: []));
    await tester.pump();

    await tester.tap(find.byTooltip('Explore'));
    await tester.pump();
    expect(selected, isEmpty);

    await tester.tap(find.byTooltip('Messages'));
    await tester.pump();
    expect(selected, [2]);
  });

  testWidgets('Notifications tab pushes the screen from elsewhere', (
    tester,
  ) async {
    final pushed = <String>[];
    await tester.pumpWidget(host(index: -1, selected: [], pushed: pushed));
    await tester.pump();

    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(pushed, ['/notifications']);
  });

  testWidgets('Notifications tab is a no-op on the Notifications screen', (
    tester,
  ) async {
    final pushed = <String>[];
    await tester.pumpWidget(host(
      index: -1,
      selected: [],
      pushed: pushed,
      notificationsActive: true,
    ));
    await tester.pump();

    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(pushed, isEmpty);
    expect(find.text('NOTIFICATIONS'), findsNothing);
  });
}
