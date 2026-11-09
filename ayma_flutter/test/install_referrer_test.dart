import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/services/install_referrer_service.dart';
import 'package:ayma_flutter/services/share_kit.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PendingPageShare.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    PendingPageShare.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('ayma/install_referrer'),
      null,
    );
  });

  group('InstallReferrerService exact shape regression test', () {
    test('referrer with an ayma_page token stashes it', () {
      final service = InstallReferrerService();

      // Plain key-value pair
      expect(service.handleReferrer('ayma_page=TOK_BASIC'), 'TOK_BASIC');
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_BASIC');

      // URL-encoded delimiter
      expect(service.handleReferrer('ayma_page%3DTOK_ENCODED'), 'TOK_ENCODED');
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_ENCODED');

      // Compound query params (campaign metadata + ayma_page)
      expect(
        service.handleReferrer(
          'utm_source=google-play&utm_medium=organic&ayma_page=TOK_CAMPAIGN&utm_campaign=share',
        ),
        'TOK_CAMPAIGN',
      );
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_CAMPAIGN');

      // Fully URL-encoded query string
      expect(
        service.handleReferrer(
          'utm_source%3Dgoogle-play%26ayma_page%3DTOK_URL_ENCODED%26utm_medium%3Dcpc',
        ),
        'TOK_URL_ENCODED',
      );
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_URL_ENCODED');

      // Full store URL containing referrer query
      expect(
        service.handleReferrer(
          'https://play.google.com/store/apps/details?id=com.ayma.ayma_flutter&referrer=ayma_page%3DTOK_PLAY_URL',
        ),
        'TOK_PLAY_URL',
      );
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_PLAY_URL');
    });

    test('absent or malformed referrer stashes nothing', () {
      final service = InstallReferrerService();

      final cases = [
        null,
        '',
        '   ',
        'ayma_page=',
        'ayma_page=%20',
        'ayma_ref=UFV44V3',
        'utm_source=google-play&utm_medium=organic',
        'random_garbage_string_with_no_target',
        '%ZZ%invalid_percent_encoding',
      ];

      for (final raw in cases) {
        PendingPageShare.resetForTest();
        expect(
          service.handleReferrer(raw),
          isNull,
          reason: 'Expected null for referrer: $raw',
        );
        expect(
          PendingPageShare.hasPending,
          isFalse,
          reason: 'Expected nothing stashed for referrer: $raw',
        );
      }
    });

    test('does not overwrite an existing pending route from explicit tap', () {
      final service = InstallReferrerService();

      PendingPageShare.stash('/profile/user/u_existing');
      expect(PendingPageShare.hasPending, isTrue);

      final token = service.handleReferrer('ayma_page=TOK_IGNORE');
      expect(token, 'TOK_IGNORE');
      // Must not overwrite the already-pending user tap route
      expect(PendingPageShare.take(), '/profile/user/u_existing');
    });
  });

  group('InstallReferrerService platform integration', () {
    test('on Android: invokes channel, parses token, and sets prefs gate',
        () async {
      int channelInvocations = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ayma/install_referrer'),
        (call) async {
          if (call.method == 'getInstallReferrer') {
            channelInvocations++;
            return 'ayma_page=TOK_MOCK_ANDROID';
          }
          return null;
        },
      );

      final prefs = await SharedPreferences.getInstance();
      final service = InstallReferrerService(
        prefs: prefs,
        isAndroidOverride: true,
      );

      await service.checkInstallReferrer();

      expect(channelInvocations, 1);
      expect(PendingPageShare.hasPending, isTrue);
      expect(PendingPageShare.take(), '/p/TOK_MOCK_ANDROID');
      expect(prefs.getBool(InstallReferrerService.prefKey), isTrue);

      // Subsequent call skips because prefs gate is set
      await service.checkInstallReferrer();
      expect(channelInvocations, 1);
    });

    test('on non-Android: does not invoke channel and stashes nothing',
        () async {
      int channelInvocations = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ayma/install_referrer'),
        (call) async {
          channelInvocations++;
          return 'ayma_page=TOK_IOS';
        },
      );

      final prefs = await SharedPreferences.getInstance();
      final service = InstallReferrerService(
        prefs: prefs,
        isAndroidOverride: false,
      );

      await service.checkInstallReferrer();

      expect(channelInvocations, 0);
      expect(PendingPageShare.hasPending, isFalse);
    });

    test('gracefully catches platform channel errors without throwing',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('ayma/install_referrer'),
        (call) async {
          throw PlatformException(code: 'UNAVAILABLE', message: 'No play store');
        },
      );

      final prefs = await SharedPreferences.getInstance();
      final service = InstallReferrerService(
        prefs: prefs,
        isAndroidOverride: true,
      );

      await service.checkInstallReferrer();
      expect(PendingPageShare.hasPending, isFalse);
    });
  });

  group('Post-auth stash drain integration', () {
    test('stashed referrer token is drained by auth listener on sign-in',
        () async {
      final mockAuth = MockFirebaseAuth();
      final service = InstallReferrerService();

      service.handleReferrer('ayma_page=TOK_DRAIN_TEST');
      expect(PendingPageShare.hasPending, isTrue);

      String? navigatedPath;
      setupAuthDeepLinkDrain(mockAuth, (path) => navigatedPath = path);

      // Sign in triggers auth state change and drains PendingPageShare
      await mockAuth.signInWithEmailAndPassword(
        email: 'test@example.com',
        password: 'password123',
      );
      await pumpEventQueue();

      expect(navigatedPath, '/p/TOK_DRAIN_TEST');
      expect(PendingPageShare.hasPending, isFalse);
    });
  });
}
