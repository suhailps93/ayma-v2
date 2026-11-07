import 'dart:convert';
import 'dart:typed_data';

import 'package:ayma_flutter/screens/assistant_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/assist_context.dart';
import 'package:ayma_flutter/services/assistant_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAssistantService extends AssistantService {
  FakeAssistantService({this.isDefault = false, this.pending});

  bool isDefault;
  AssistCapture? pending;
  int openSettingsCalls = 0;

  @override
  Future<bool> isDefaultAssistant() async => isDefault;

  @override
  Future<bool> openDefaultAssistantSettings() async {
    openSettingsCalls++;
    return true;
  }

  @override
  Future<AssistCapture?> takePendingAssist() async {
    final p = pending;
    pending = null;
    return p;
  }
}

ApiClient _api(void Function(Map<String, dynamic> body) onChat) {
  final mock = MockClient((req) async {
    if (req.url.path == '/chat') {
      onChat(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({'reply': 'Tap Pay now to check out.'}),
        200,
      );
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

AssistCapture _capture({bool allowed = true}) => AssistCapture(
      snapshot: AssistSnapshot(
        foregroundPackage: 'com.example.shop',
        texts: const ['Checkout', 'Total \$42', 'Pay now'],
        hasScreenshot: true,
        capturedAtMillis: DateTime.now().millisecondsSinceEpoch,
        screenDataAllowed: allowed,
        source: 'voice_interaction',
      ),
      // A 1x1 transparent PNG.
      screenshotBytes: Uint8List.fromList(const [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0,
        0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73,
        68, 65, 84, 120, 156, 98, 0, 0, 0, 2, 0, 1, 229, 39, 222, 252, 0, 0,
        0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
      ]),
    );

Widget _host(AssistantScreen screen) => MaterialApp(
      theme: AymaTheme.light,
      home: screen,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AssistantSessionStore.instance.reset();
  });
  tearDown(() {
    AssistantSessionStore.instance.reset();
    AppContext.instance.clear();
  });

  testWidgets('a captured screen renders app, summary, screenshot, privacy',
      (tester) async {
    await tester.pumpWidget(_host(AssistantScreen(
      api: _api((_) {}),
      service: FakeAssistantService(isDefault: true),
      capture: _capture(),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('assistant_foreground_app')), findsOneWidget);
    expect(find.text('Shop'), findsOneWidget);
    expect(find.byKey(const Key('assistant_screenshot')), findsOneWidget);
    expect(find.textContaining('never stored'), findsWidgets);
    expect(find.text('Ayma is your default assistant'), findsOneWidget);
  });

  testWidgets('asking sends the screen through the /chat screen params',
      (tester) async {
    Map<String, dynamic>? body;
    await tester.pumpWidget(_host(AssistantScreen(
      api: _api((b) => body = b),
      service: FakeAssistantService(isDefault: true),
      capture: _capture(),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('assistant_question_field')),
      'What do I tap?',
    );
    await tester.ensureVisible(find.byKey(const Key('assistant_ask')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assistant_ask')));
    await tester.pumpAndSettle();

    expect(body?['message'], 'What do I tap?');
    expect(body?['screen'], 'external_app');
    expect(body?['screen_subject_name'], 'Shop');
    expect(body?['screen_note'], 'com.example.shop');
    expect(body?['screen_visible'], contains('Pay now'));
    expect(find.byKey(const Key('assistant_reply')), findsOneWidget);
    expect(find.text('Tap Pay now to check out.'), findsOneWidget);
  });

  testWidgets('a summon without screen data explains the toggle',
      (tester) async {
    await tester.pumpWidget(_host(AssistantScreen(
      api: _api((_) {}),
      service: FakeAssistantService(isDefault: true),
      capture: _capture(allowed: false),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Ayma could not see that screen'), findsOneWidget);
    expect(find.textContaining('Use screen and app data'), findsOneWidget);
    expect(find.byKey(const Key('assistant_ask')), findsNothing);
  });

  testWidgets('with no capture the screen is the enable surface',
      (tester) async {
    final service = FakeAssistantService(isDefault: false);
    await tester.pumpWidget(_host(AssistantScreen(
      api: _api((_) {}),
      service: service,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Make Ayma your default assistant'), findsOneWidget);
    await tester.tap(find.byKey(const Key('assistant_open_settings')));
    await tester.pumpAndSettle();
    expect(service.openSettingsCalls, 1);
  });

  testWidgets('Guide me hands the screen to the main chat as AppContext',
      (tester) async {
    final router = GoRouter(
      initialLocation: AssistantScreen.path,
      routes: [
        GoRoute(
          path: AssistantScreen.path,
          builder: (_, __) => AssistantScreen(
            api: _api((_) {}),
            service: FakeAssistantService(isDefault: true),
            capture: _capture(),
          ),
        ),
        GoRoute(
          path: MainShellScreen.path,
          builder: (_, __) => const Scaffold(body: Text('MAIN SHELL')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('assistant_guide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assistant_guide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Flush the toast's dismissal timer before the test ends.
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('MAIN SHELL'), findsOneWidget);
    expect(AppContext.instance.current.value.screen, 'external_app');
    expect(AppContext.instance.current.value.subjectName, 'Shop');
    expect(AppContext.instance.current.value.note, 'com.example.shop');
  });
}
