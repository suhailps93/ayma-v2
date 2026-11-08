import 'dart:convert';

import 'package:ayma_flutter/legal/biometric_consent_text.dart';
import 'package:ayma_flutter/screens/biometric_consent_screen.dart';
import 'package:ayma_flutter/screens/biometric_consent_settings_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/biometric_consent.dart';
import 'package:ayma_flutter/services/legal_links.dart';
import 'package:ayma_flutter/widgets/biometric_consent_panel.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An [ApiClient] over a [MockClient] that records every request.
class _Recorded {
  _Recorded(this.handler);

  final Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];

  ApiClient get api => ApiClient(
    httpClient: MockClient((req) async {
      requests.add(req);
      return handler(req);
    }),
    auth: MockFirebaseAuth(signedIn: true),
  );
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  setUp(BiometricConsentState.instance.clear);
  setUp(RecoveryRequiredState.instance.clear);
  // Presentation is immediate unless gated (the engine never reports
  // rasterization under flutter_test) — see SplashFirstPaint.resetForTest.
  setUp(SplashFirstPaint.resetForTest);

  group('BiometricConsentPanel', () {
    testWidgets(
      'I agree stays disabled until the box is ticked, then records',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 4000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final rec = _Recorded(
          (_) async => _json({'ok': true, 'consented': true}),
        );
        var agreed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: BiometricConsentPanel(
                  api: rec.api,
                  region: 'US',
                  onAgreed: () => agreed = true,
                ),
              ),
            ),
          ),
        );

        final button = find.byKey(const Key('biometric_consent_agree'));
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        await tester.tap(button);
        await tester.pump();
        expect(rec.requests, isEmpty);

        await tester.tap(find.byKey(const Key('biometric_consent_checkbox')));
        await tester.pump();
        await tester.tap(button);
        await tester.pumpAndSettle();

        expect(agreed, isTrue);
        expect(rec.requests.single.url.path, '/biometric-consent');
        expect(jsonDecode(rec.requests.single.body), {
          'agreed': true,
          'consent_version': kBiometricConsentVersion,
          'region': 'US',
        });
      },
    );

    testWidgets('a failed save shows an error and does not continue', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rec = _Recorded((_) async => _json({'detail': 'x'}, 400));
      var agreed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BiometricConsentPanel(
                api: rec.api,
                region: '',
                onAgreed: () => agreed = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('biometric_consent_checkbox')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('biometric_consent_agree')));
      await tester.pumpAndSettle();
      expect(agreed, isFalse);
      expect(find.textContaining("Couldn't save your consent"), findsOneWidget);
    });

    testWidgets(
        'a 409 (recover first) signals recovery, not a connection error (B9)',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 409 without the header: exercises the panel's own statusCode==409
      // branch (the soft-deleted-account consent dead end).
      final rec = _Recorded(
        (_) async => _json({'detail': 'Recover your account first.'}, 409),
      );
      var agreed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BiometricConsentPanel(
                api: rec.api,
                region: '',
                onAgreed: () => agreed = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('biometric_consent_checkbox')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('biometric_consent_agree')));
      await tester.pumpAndSettle();
      expect(agreed, isFalse);
      expect(find.textContaining("Couldn't save your consent"), findsNothing);
      expect(RecoveryRequiredState.instance.required, isTrue);
    });
  });

  group('consent-required signal', () {
    test('a 403 carrying the consent header marks consent required', () async {
      final rec = _Recorded(
        (_) async => http.Response(
          jsonEncode({
            'detail': {'code': 'biometric_consent_required'},
          }),
          403,
          headers: {kConsentRequiredHeader: '1'},
        ),
      );
      await expectLater(
        rec.api.verificationStatus(),
        throwsA(isA<ApiException>()),
      );
      expect(BiometricConsentState.instance.required, isTrue);
    });

    test('an ordinary 403 does not', () async {
      final rec = _Recorded((_) async => http.Response('no', 403));
      await expectLater(
        rec.api.verificationStatus(),
        throwsA(isA<ApiException>()),
      );
      expect(BiometricConsentState.instance.required, isFalse);
    });

    test(
        'a response carrying the recovery header marks recovery, not consent '
        '(B9)', () async {
      // A soft-deleted account's gated call: the server answers 403 recovery-
      // required so the client routes to recovery, never the consent dead end.
      final rec = _Recorded(
        (_) async => http.Response(
          jsonEncode({
            'detail': {'code': 'recovery_required'},
          }),
          403,
          headers: {kRecoveryRequiredHeader: '1'},
        ),
      );
      await expectLater(
        rec.api.verificationStatus(),
        throwsA(isA<ApiException>()),
      );
      expect(RecoveryRequiredState.instance.required, isTrue);
      expect(BiometricConsentState.instance.required, isFalse);
    });

    test('bootstrap reports consent required with the session mode', () async {
      final rec = _Recorded(
        (_) async => _json({
          'biometric_consent_required': true,
          'session_mode': 'active',
          'uid': 'u1',
        }),
      );
      final result = await rec.api.bootstrap(sessionId: '');
      expect(result.biometricConsentRequired, isTrue);
      expect(result.sessionMode, 'active');
      expect(BiometricConsentState.instance.required, isTrue);
    });

    test('accepting clears the signal', () async {
      BiometricConsentState.instance.markRequired();
      final rec = _Recorded((_) async => _json({'ok': true}));
      await rec.api.acceptBiometricConsent(region: 'GB');
      expect(BiometricConsentState.instance.required, isFalse);
    });
  });

  group('splash routing', () {
    late _Recorded rec;

    GoRouter router() {
      var consented = false;
      rec = _Recorded((req) async {
        if (req.url.path == '/biometric-consent') {
          consented = true;
          return _json({'ok': true, 'consented': true});
        }
        if (consented) {
          return _json({
            'session_mode': 'active',
            'uid': 'u1',
            'livekit': {'token': 't', 'url': 'wss://x', 'room': 'r'},
          });
        }
        return _json({
          'biometric_consent_required': true,
          'session_mode': 'active',
          'uid': 'u1',
        });
      });
      return GoRouter(
        initialLocation: '/splash',
        routes: [
          GoRoute(
            path: '/splash',
            builder: (_, __) => SplashScreen(
              apiClient: rec.api,
              auth: MockFirebaseAuth(signedIn: true),
            ),
          ),
          GoRoute(path: '/', builder: (_, __) => const Text('screen:shell')),
          GoRoute(
            path: BiometricConsentScreen.path,
            builder: (_, __) => const Text('screen:consent'),
          ),
        ],
      );
    }

    testWidgets('records the consent ticked at sign-in, then routes on', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await PendingBiometricConsent.save(kBiometricConsentVersion);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router()));
      await tester.pumpAndSettle();
      expect(find.text('screen:shell'), findsOneWidget);
      final post = rec.requests.singleWhere(
        (r) => r.url.path == '/biometric-consent',
      );
      expect(jsonDecode(post.body)['agreed'], isTrue);
      expect(await PendingBiometricConsent.read(), isNull);
      expect(BiometricConsentState.instance.required, isFalse);
    });

    testWidgets('an account with no record gets the one-time consent screen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(MaterialApp.router(routerConfig: router()));
      await tester.pumpAndSettle();
      expect(find.text('screen:consent'), findsOneWidget);
      expect(
        rec.requests.where((r) => r.url.path == '/biometric-consent'),
        isEmpty,
      );
    });
  });

  testWidgets('consent screen has only the I agree button', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final rec = _Recorded((_) async => _json({'ok': true}));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => BiometricConsentScreen(api: rec.api),
        ),
        GoRoute(
          path: SplashScreen.path,
          builder: (_, __) => const Text('screen:splash'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.textContaining('Sign out'), findsNothing);
    expect(find.textContaining('Delete'), findsNothing);

    await tester.tap(find.byKey(const Key('biometric_consent_checkbox')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('biometric_consent_agree')))
          .onPressed,
      isNull,
      reason: 'the updated Terms must be accepted too',
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('consent_terms_checkbox')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('biometric_consent_agree')));
    await tester.pumpAndSettle();
    expect(find.text('screen:splash'), findsOneWidget);
  });

  testWidgets(
    'settings: withdrawing deletes face data + account, then signs out',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rec = _Recorded((req) async {
        if (req.method == 'GET') {
          return _json({
            'consented': true,
            'consent_version': kBiometricConsentVersion,
            'consented_at': '2026-10-25T10:00:00+00:00',
            'region': 'US',
          });
        }
        return _json({'ok': true, 'withdrawn': true});
      });
      final auth = MockFirebaseAuth(signedIn: true);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => BiometricConsentSettingsScreen(
              api: rec.api,
              auth: auth,
              clearPushToken: () async {},
            ),
          ),
          GoRoute(
            path: '/signin',
            builder: (_, __) => const Text('screen:signin'),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('biometric_consent_given')), findsOneWidget);

      await tester.tap(find.byKey(const Key('biometric_withdraw')));
      await tester.pumpAndSettle();
      expect(
        find.text('Withdraw consent and delete your account?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('biometric_withdraw_confirm')));
      await tester.pumpAndSettle();

      expect(rec.requests.last.url.path, '/biometric-consent/withdraw');
      expect(auth.currentUser, isNull);
      expect(find.text('screen:signin'), findsOneWidget);
    },
  );

  group('consent legal links (NOTE 141 tap targets)', () {
    final opened = <Uri>[];

    setUp(() {
      opened.clear();
      LegalLinks.setLauncherForTesting((url) async {
        opened.add(url);
        return true;
      });
    });

    tearDown(() => LegalLinks.setLauncherForTesting(null));

    bool termsChecked(WidgetTester tester) =>
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('consent_terms_checkbox')))
            .value ==
        true;
    bool biometricChecked(WidgetTester tester) =>
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('biometric_consent_checkbox')))
            .value ==
        true;

    // The centre of the link chip, then points just inside each edge and
    // corner. The edge points sit inside the chip's padded hit region but
    // outside the word's glyphs, where a bare text span used to drop the
    // tap onto the row and toggle consent (or fire the neighbouring link).
    List<Offset> spotsFor(WidgetTester tester, Finder link) => [
          tester.getCenter(link),
          tester.getTopLeft(link) + const Offset(2, 2),
          tester.getTopRight(link) + const Offset(-2, 2),
          tester.getBottomLeft(link) + const Offset(2, -2),
          tester.getBottomRight(link) + const Offset(-2, -2),
          tester.getRect(link).centerLeft + const Offset(2, 0),
          tester.getRect(link).centerRight + const Offset(-2, 0),
        ];

    Future<void> pumpPanel(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rec = _Recorded((_) async => _json({'ok': true}));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BiometricConsentPanel(
                api: rec.api,
                requireTerms: true,
                onAgreed: () {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('Terms link opens the Terms page from its centre and edges, '
        'and never toggles a checkbox', (tester) async {
      await pumpPanel(tester);

      final link = find.byKey(const Key('consent_terms_link'));
      expect(link, findsOneWidget);
      // The hit region is a padded chip about 48dp tall, not glyph-tight.
      expect(tester.getSize(link).height, greaterThanOrEqualTo(40));

      for (final spot in spotsFor(tester, link)) {
        await tester.tapAt(spot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(termsChecked(tester), isFalse,
            reason: 'a Terms tap must never tick the Terms checkbox');
        expect(biometricChecked(tester), isFalse,
            reason: 'a Terms tap must never tick the biometric checkbox');
      }
      expect(opened, hasLength(7));
      expect(opened, everyElement(Uri.parse(LegalLinks.termsUrl)));
    });

    testWidgets('Privacy link opens the Privacy page from its centre and '
        'edges, and never toggles a checkbox', (tester) async {
      await pumpPanel(tester);

      final link = find.byKey(const Key('consent_privacy_link'));
      expect(link, findsOneWidget);
      expect(tester.getSize(link).height, greaterThanOrEqualTo(40));

      for (final spot in spotsFor(tester, link)) {
        await tester.tapAt(spot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(termsChecked(tester), isFalse,
            reason: 'a Privacy tap must never tick the Terms checkbox');
        expect(biometricChecked(tester), isFalse,
            reason: 'a Privacy tap must never tick the biometric checkbox');
      }
      expect(opened, hasLength(7));
      expect(opened, everyElement(Uri.parse(LegalLinks.privacyUrl)));
    });

    testWidgets('tapping the checkbox itself still toggles consent, and '
        'opens nothing', (tester) async {
      await pumpPanel(tester);

      final box = find.descendant(
        of: find.byKey(const Key('consent_terms_checkbox')),
        matching: find.byType(Checkbox),
      );
      expect(box, findsOneWidget);

      await tester.tap(box);
      await tester.pump();
      expect(termsChecked(tester), isTrue);
      expect(opened, isEmpty);

      await tester.tap(box);
      await tester.pump();
      expect(termsChecked(tester), isFalse);
      expect(opened, isEmpty);
    });

    testWidgets('tapping elsewhere on the terms row still toggles consent, '
        'and opens nothing', (tester) async {
      await pumpPanel(tester);

      final tile = find.byKey(const Key('consent_terms_checkbox'));
      // Tap near the top-right of the tile, far from the link chips.
      final spot = tester.getTopRight(tile) + const Offset(-10, 10);

      await tester.tapAt(spot);
      await tester.pump();
      expect(termsChecked(tester), isTrue);
      expect(opened, isEmpty);

      await tester.tapAt(spot);
      await tester.pump();
      expect(termsChecked(tester), isFalse);
      expect(opened, isEmpty);
    });
  });
}
