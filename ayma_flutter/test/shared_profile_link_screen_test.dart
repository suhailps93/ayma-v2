import 'package:ayma_flutter/models/share_link.dart';
import 'package:ayma_flutter/screens/shared_profile_link_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolves the token to a public profile teaser so the signed-out branch
/// (teaser + sign-in button) renders without any network or Firebase app.
class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth());

  @override
  Future<PageShareTarget> pageShareTarget(String token) async =>
      const PageShareTarget(
        kind: 'profile',
        targetId: 'u1',
        title: 'Jane',
        summary: 'A short public teaser.',
      );
}

void main() {
  testWidgets(
      'jobs pass: link-landing sign-in button measures >= 48 tall (defect 35)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: SharedProfileLinkScreen(token: 't', api: _FakeApi()),
      ),
    );
    // Let _resolve()'s future complete and the teaser rebuild.
    await tester.pump();
    await tester.pump();

    final btn =
        find.widgetWithText(FilledButton, 'Sign in to see this profile');
    expect(btn, findsOneWidget);
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(48.0),
        reason: 'the link-landing sign-in button must meet the 48 touch floor');
  });
}
