import 'package:ayma_flutter/screens/credential_picker_screen.dart';
import 'package:ayma_flutter/services/auth_link_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('the sign-in Terms link routes to /terms', (tester) async {
    final router = GoRouter(
      initialLocation: CredentialPickerScreen.path,
      routes: [
        GoRoute(
          path: CredentialPickerScreen.path,
          builder: (_, __) => CredentialPickerScreen(
            linkService: AuthLinkService(auth: MockFirebaseAuth()),
          ),
        ),
        GoRoute(
          path: '/terms',
          builder: (_, __) => const Text('TERMS PAGE'),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('By continuing you agree to our'),
        findsOneWidget);

    // Fire the tap recognizer on the "Terms" span.
    TapGestureRecognizer? terms;
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan &&
            span.text == 'Terms' &&
            span.recognizer is TapGestureRecognizer) {
          terms = span.recognizer as TapGestureRecognizer;
          return false;
        }
        return true;
      });
    }
    expect(terms, isNotNull);

    terms!.onTap!();
    await tester.pumpAndSettle();

    expect(find.text('TERMS PAGE'), findsOneWidget);
  });
}
