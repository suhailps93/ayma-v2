import 'dart:convert';

import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/chatgpt_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted fake of the /auth/chatgpt/* endpoints.
class _Server {
  bool enabled = true;
  bool connected = false;
  int startStatus = 200;
  final List<Map<String, dynamic>> returns = [];
  final List<String> calls = [];
  final List<Map<String, String>> headers = [];

  MockClient get client => MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        headers.add(req.headers);
        switch (req.url.path) {
          case '/auth/chatgpt/config':
            return http.Response(
                jsonEncode({'enabled': enabled, 'mode': 'oidc'}), 200);
          case '/auth/chatgpt/start':
            if (startStatus != 200) return http.Response('{}', startStatus);
            return http.Response(
                jsonEncode({
                  'mode': 'oidc',
                  'state': 'state-abcdefgh',
                  'url': 'https://auth.openai.com/api/accounts/authorize?x=1'
                }),
                200);
          case '/auth/chatgpt/return':
            final next = returns.length > 1 ? returns.removeAt(0) : returns.first;
            return http.Response(jsonEncode(next), 200);
          case '/auth/chatgpt/status':
            return http.Response(
                jsonEncode({
                  'enabled': enabled,
                  'connected': connected,
                  'email': connected ? 'a@b.test' : '',
                }),
                200);
          case '/auth/chatgpt/disconnect':
            connected = false;
            return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 404);
      });

  ApiClient api({bool signedIn = true}) => ApiClient(
      httpClient: client, auth: MockFirebaseAuth(signedIn: signedIn));
}

ChatGptService _service(_Server s, List<Uri> opened,
        {bool signedIn = true, bool openOk = true}) =>
    ChatGptService(
      api: s.api(signedIn: signedIn),
      openUrl: (u) async {
        opened.add(u);
        return openOk;
      },
      pollInterval: Duration.zero,
      timeout: const Duration(seconds: 5),
    );

class _FakeAuth extends AuthService {
  _FakeAuth() : super(auth: MockFirebaseAuth());
  final List<String> tokens = [];

  @override
  Future<UserCredential> signInWithChatGptCustomToken(String t) async {
    tokens.add(t);
    throw StateError('stubbed'); // stop before navigation
  }
}

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'me')));
  @override
  Stream<bool> watchPaused() => Stream.value(false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ChatGptService', () {
    test('isEnabled reflects the server and defaults to off on failure',
        () async {
      final s = _Server();
      expect(await _service(s, []).isEnabled(), isTrue);
      s.enabled = false;
      expect(await _service(s, []).isEnabled(), isFalse);
      final broken = ChatGptService(
        api: ApiClient(
          httpClient: MockClient((_) async => http.Response('x', 500)),
          auth: MockFirebaseAuth(),
        ),
      );
      expect(await broken.isEnabled(), isFalse);
    });

    test('sign-in opens the authorize URL, polls, and returns the token',
        () async {
      final s = _Server()
        ..returns.addAll([
          {'status': 'pending'},
          {'status': 'pending'},
          {'status': 'done', 'customToken': 'CT', 'isNewUser': true},
        ]);
      final opened = <Uri>[];
      final r = await _service(s, opened, signedIn: false).signIn();
      expect(r.customToken, 'CT');
      expect(r.isNewUser, isTrue);
      expect(opened.single.host, 'auth.openai.com');
      expect(s.calls.where((c) => c.endsWith('/return')).length, 3);
      // No user exists yet: neither start nor the polls carry a Bearer.
      expect(s.headers.every((h) => !h.containsKey('Authorization')), isTrue);
    });

    test('linking sends the Bearer token', () async {
      final s = _Server()
        ..returns.add({'status': 'done'});
      await _service(s, []).connect();
      expect(
          s.headers
              .where((h) => h.containsKey('Authorization'))
              .length,
          greaterThanOrEqualTo(2));
    });

    test('a server-reported error surfaces its message', () async {
      final s = _Server()
        ..returns.add({'status': 'error', 'detail': 'Sign-in expired.'});
      await expectLater(
        _service(s, [], signedIn: false).signIn(),
        throwsA(isA<ChatGptException>()
            .having((e) => e.message, 'message', 'Sign-in expired.')),
      );
    });

    test('a sign-in "done" without a custom token is refused', () async {
      final s = _Server()..returns.add({'status': 'done'});
      await expectLater(
          _service(s, [], signedIn: false).signIn(),
          throwsA(isA<ChatGptException>()));
    });

    test('an unavailable feature is a friendly error, not a crash', () async {
      final s = _Server()..startStatus = 404;
      await expectLater(
        _service(s, [], signedIn: false).signIn(),
        throwsA(isA<ChatGptException>().having(
            (e) => e.message, 'message', contains('isn’t available'))),
      );
    });

    test('cancelling stops polling silently', () async {
      final s = _Server()..returns.add({'status': 'pending'});
      await expectLater(
        _service(s, [], signedIn: false).signIn(isCancelled: () => true),
        throwsA(isA<ChatGptException>()
            .having((e) => e.cancelled, 'cancelled', isTrue)),
      );
    });

    test('a browser that will not open is reported', () async {
      final s = _Server()..returns.add({'status': 'pending'});
      await expectLater(
        _service(s, [], signedIn: false, openOk: false).signIn(),
        throwsA(isA<ChatGptException>()),
      );
    });

    test('times out when the browser step never completes', () async {
      final s = _Server()..returns.add({'status': 'pending'});
      final svc = ChatGptService(
        api: s.api(signedIn: false),
        openUrl: (_) async => true,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 30),
      );
      await expectLater(svc.signIn(),
          throwsA(isA<ChatGptException>().having(
              (e) => e.message, 'message', contains('timed out'))));
    });
  });

  group('sign-in screen', () {
    Future<void> pump(WidgetTester tester, _Server s, _FakeAuth auth,
        List<Uri> opened) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(
          auth: auth,
          voiceController: _FakeVoice(),
          chatgpt: _service(s, opened, signedIn: false),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the button is hidden while the feature is off',
        (tester) async {
      final s = _Server()..enabled = false;
      await pump(tester, s, _FakeAuth(), []);
      expect(find.text('Continue with ChatGPT'), findsNothing);
      expect(find.text('Google'), findsOneWidget); // rest unchanged
    });

    testWidgets('the button appears when enabled and redeems the token',
        (tester) async {
      final s = _Server()
        ..returns.add({'status': 'done', 'customToken': 'CT'});
      final auth = _FakeAuth();
      final opened = <Uri>[];
      await pump(tester, s, auth, opened);
      expect(find.text('Continue with ChatGPT'), findsOneWidget);

      await tester.tap(find.text('Continue with ChatGPT'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(auth.tokens, ['CT']);
    });

    testWidgets('a failed sign-in shows the message', (tester) async {
      final s = _Server()
        ..returns.add({'status': 'error', 'detail': 'Sign-in expired.'});
      await pump(tester, s, _FakeAuth(), []);
      await tester.tap(find.text('Continue with ChatGPT'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in expired.'), findsOneWidget);
    });
  });

  group('settings row', () {
    Future<void> pump(WidgetTester tester, _Server s, List<Uri> opened) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.light,
        home: SettingsScreen(
          profileService: _FakeProfiles(),
          api: s.api(),
          chatgpt: _service(s, opened),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('hidden while the feature is off', (tester) async {
      final s = _Server()..enabled = false;
      await pump(tester, s, []);
      expect(find.text('Connect ChatGPT'), findsNothing);
      expect(find.text('ChatGPT connected'), findsNothing);
    });

    testWidgets('connect then disconnect', (tester) async {
      final s = _Server()..returns.add({'status': 'done'});
      final opened = <Uri>[];
      await pump(tester, s, opened);
      expect(find.text('Connect ChatGPT'), findsOneWidget);

      s.connected = true; // what the server does once the callback lands
      await tester.tap(find.text('Connect ChatGPT'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(find.text('ChatGPT connected'), findsOneWidget);

      await tester.tap(find.text('ChatGPT connected'));
      await tester.pumpAndSettle();
      expect(s.calls, contains('POST /auth/chatgpt/disconnect'));
      expect(find.text('Connect ChatGPT'), findsOneWidget);
    });
  });
}
