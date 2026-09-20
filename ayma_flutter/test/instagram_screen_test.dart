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
}

class _ErrorInstagram extends InstagramService {
  @override
  Future<bool> status() async => throw StateError('boom');
}
