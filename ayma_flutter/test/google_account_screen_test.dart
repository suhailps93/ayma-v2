import 'package:ayma_flutter/screens/google_account_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/google_account_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake mirroring `instagram_screen_test.dart`'s approach — override just the
/// methods the screen calls, skip the Firebase/HTTP plumbing.
class _FakeGoogle extends GoogleAccountService {
  _FakeGoogle({this.connected = false, this.fail = false});

  final bool connected;
  final bool fail;

  @override
  Future<GoogleAccountStatus> status() async {
    if (fail) throw StateError('boom');
    return GoogleAccountStatus(connected: connected, email: '');
  }
}

Widget _host(GoogleAccountService svc, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? AymaTheme.light,
      home: GoogleAccountScreen(service: svc),
    );

void main() {
  testWidgets('shows a connect button when not connected', (tester) async {
    await tester.pumpWidget(_host(_FakeGoogle()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Connect Google'), findsOneWidget);
    expect(find.text('Google account connected'), findsNothing);
  });

  testWidgets('shows connected status and a disconnect button', (tester) async {
    await tester.pumpWidget(_host(_FakeGoogle(connected: true)));
    await tester.pumpAndSettle();

    expect(find.text('Google account connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  // Defect 11 / V7: the failed-status line uses the bg-safe `errorText` token
  // (4.83/4.68), not the raw `error` token (4.24/4.16, fails the 4.5 text floor).
  testWidgets('the failed-status line uses the contrast-safe errorText token, '
      'in both themes', (tester) async {
    for (final theme in [AymaTheme.light, AymaTheme.dark]) {
      await tester.pumpWidget(_host(_FakeGoogle(fail: true), theme: theme));
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
    await tester.pumpWidget(_host(_FakeGoogle()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Connect Google'));
    await tester.pumpAndSettle();

    for (final label in ['Cancel', 'Continue to Google']) {
      final btn = find.widgetWithText(TextButton, label);
      expect(btn, findsOneWidget);
      // M3 padded tap target renders TextButtons at 48 once the 44 minimumSize
      // lands; assert the floor (>= 44) — the pad bumps it to 48.
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(44.0));
    }
  });
}
