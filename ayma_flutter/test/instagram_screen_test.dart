import 'package:ayma_flutter/screens/instagram_screen.dart';
import 'package:ayma_flutter/services/instagram_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake mirroring how `photo_management_screen_test.dart` fakes
/// `PhotoService` — override just the methods the screen calls, skip the
/// Firebase/HTTP plumbing entirely.
class _FakeInstagram extends InstagramService {
  _FakeInstagram({this.connected = false});

  bool connected;
  bool disconnectCalled = false;

  @override
  Future<bool> status() async => connected;

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    connected = false;
  }
}

void main() {
  testWidgets('shows a connect button when not connected', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: InstagramScreen(service: _FakeInstagram()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Connect Instagram'), findsWidgets);
    expect(find.text('Instagram connected'), findsNothing);
  });

  testWidgets('shows connected status and a disconnect button',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: InstagramScreen(service: _FakeInstagram(connected: true)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Instagram connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('disconnect calls through to the service and reloads status',
      (tester) async {
    final svc = _FakeInstagram(connected: true);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: InstagramScreen(service: svc),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(svc.disconnectCalled, isTrue);
    expect(find.text('Connect Instagram'), findsWidgets);
  });

  testWidgets('shows an error state when status fails to load',
      (tester) async {
    final svc = _ErrorInstagram();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: InstagramScreen(service: svc),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load status'), findsOneWidget);
  });

  // Defect 11 / V7: the failed-status line uses the bg-safe `errorText` token
  // (4.83/4.68), not raw `error` (4.24/4.16, fails the 4.5 text floor).
  testWidgets('the failed-status line uses the contrast-safe errorText token, '
      'in both themes', (tester) async {
    for (final theme in [AymaTheme.light, AymaTheme.dark]) {
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: InstagramScreen(service: _ErrorInstagram()),
      ));
      await tester.pumpAndSettle();

      final line = find.textContaining('Could not load status');
      expect(line, findsOneWidget);
      final ctx = tester.element(line);
      expect(tester.widget<Text>(line).style?.color, ctx.ac.errorText);
    }
  });

  // Defect 10 / V6: every consent-dialog TextButton clears the 44 tap floor.
  testWidgets('the consent dialog TextButtons clear the 44 tap floor',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: InstagramScreen(service: _FakeInstagram()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Connect Instagram'));
    await tester.pumpAndSettle();

    for (final label in ['Cancel', 'Continue to Instagram']) {
      final btn = find.widgetWithText(TextButton, label);
      expect(btn, findsOneWidget);
      // M3 padded tap target renders the 44-floor TextButtons at 48; assert >=44.
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(44.0));
    }
  });
}

class _ErrorInstagram extends InstagramService {
  @override
  Future<bool> status() async => throw StateError('boom');
}
