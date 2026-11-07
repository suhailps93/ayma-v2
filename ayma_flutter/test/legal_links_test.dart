import 'package:ayma_flutter/screens/privacy_screen.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/services/legal_links.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A plain home screen with one button per legal page, standing in for
/// every real entry point (sign-in links, the You tab rows, the consent
/// panels, the underage screen): they all call the same two functions.
Widget _home() {
  return MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            const Text('HOME SCREEN'),
            TextButton(
              key: const Key('home_terms'),
              onPressed: () => LegalLinks.openTerms(context),
              child: const Text('Terms of Service'),
            ),
            TextButton(
              key: const Key('home_privacy'),
              onPressed: () => LegalLinks.openPrivacy(context),
              child: const Text('Privacy Policy'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  final launched = <Uri>[];

  setUp(() => launched.clear());
  tearDown(() => LegalLinks.setLauncherForTesting(null));

  void recordSuccess() {
    LegalLinks.setLauncherForTesting((url) async {
      launched.add(url);
      return true;
    });
  }

  test('the canonical URLs are unchanged', () {
    expect(LegalLinks.termsUrl, 'https://ayma-ai.web.app/terms.html');
    expect(LegalLinks.privacyUrl, 'https://ayma-ai.web.app/privacy-policy');
  });

  testWidgets('tapping Terms opens the hosted page directly and stays put',
      (tester) async {
    recordSuccess();
    await tester.pumpWidget(_home());
    await tester.tap(find.byKey(const Key('home_terms')));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(LegalLinks.termsUrl)]);
    // Still on the screen the user tapped from: nothing was pushed, no
    // in-between screen, no error.
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(TermsScreen), findsNothing);
    expect(find.textContaining('Opening the'), findsNothing);
    expect(find.byKey(const Key('legal_link_error_dialog')), findsNothing);
  });

  testWidgets('tapping Privacy opens the hosted page directly and stays put',
      (tester) async {
    recordSuccess();
    await tester.pumpWidget(_home());
    await tester.tap(find.byKey(const Key('home_privacy')));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(LegalLinks.privacyUrl)]);
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(PrivacyScreen), findsNothing);
    expect(find.textContaining('Opening the'), findsNothing);
    expect(find.byKey(const Key('legal_link_error_dialog')), findsNothing);
  });

  testWidgets('a failed open shows a small error on the same screen, '
      'with the address and a close button', (tester) async {
    LegalLinks.setLauncherForTesting((url) async {
      launched.add(url);
      return false;
    });
    await tester.pumpWidget(_home());
    await tester.tap(find.byKey(const Key('home_terms')));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(LegalLinks.termsUrl)]);
    expect(find.byKey(const Key('legal_link_error_dialog')), findsOneWidget);
    expect(find.text('Could not open Terms of Service'), findsOneWidget);
    expect(find.text(LegalLinks.termsUrl), findsOneWidget);
    // The user is still on their own screen behind the dialog.
    expect(find.text('HOME SCREEN'), findsOneWidget);

    await tester.tap(find.byKey(const Key('legal_link_error_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('legal_link_error_dialog')), findsNothing);
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(launched, hasLength(1));
  });

  testWidgets('the error dialog retry tries the browser again',
      (tester) async {
    var attempts = 0;
    LegalLinks.setLauncherForTesting((url) async {
      launched.add(url);
      attempts++;
      return attempts > 1;
    });
    await tester.pumpWidget(_home());
    await tester.tap(find.byKey(const Key('home_privacy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('legal_link_error_dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('legal_link_error_retry')));
    await tester.pumpAndSettle();

    expect(launched, [
      Uri.parse(LegalLinks.privacyUrl),
      Uri.parse(LegalLinks.privacyUrl),
    ]);
    expect(find.byKey(const Key('legal_link_error_dialog')), findsNothing);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });

  testWidgets('a launcher that throws also lands on the in-place error',
      (tester) async {
    LegalLinks.setLauncherForTesting((url) async {
      throw StateError('no browser');
    });
    await tester.pumpWidget(_home());
    await tester.tap(find.byKey(const Key('home_terms')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('legal_link_error_dialog')), findsOneWidget);
    expect(find.text(LegalLinks.termsUrl), findsOneWidget);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });

  testWidgets('arriving on the legacy /terms route opens the browser and '
      'goes straight back', (tester) async {
    recordSuccess();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('go_terms'),
                onPressed: () => context.push(TermsScreen.path),
                child: const Text('HOME SCREEN'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: TermsScreen.path,
          builder: (_, __) => const TermsScreen(),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.light,
      routerConfig: router,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('go_terms')));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(LegalLinks.termsUrl)]);
    // Back on the home screen; the route never settled as a page.
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(TermsScreen), findsNothing);
    expect(find.textContaining('Opening the'), findsNothing);
  });

  testWidgets('arriving on the legacy /privacy route opens the browser and '
      'goes straight back', (tester) async {
    recordSuccess();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('go_privacy'),
                onPressed: () => context.push(PrivacyScreen.path),
                child: const Text('HOME SCREEN'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: PrivacyScreen.path,
          builder: (_, __) => const PrivacyScreen(),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.light,
      routerConfig: router,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('go_privacy')));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(LegalLinks.privacyUrl)]);
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(PrivacyScreen), findsNothing);
    expect(find.textContaining('Opening the'), findsNothing);
  });
}
