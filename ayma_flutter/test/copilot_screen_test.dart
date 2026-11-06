
import 'package:ayma_flutter/screens/copilot_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/copilot_highlight.dart';
import 'package:ayma_flutter/services/copilot_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

class _FakeCopilotService extends CopilotService {
  _FakeCopilotService() : super(debugSupportedOverride: true);

  bool overlay = true;
  int highlightCalls = 0;
  int openSettingsCalls = 0;
  CopilotTarget? lastShown;

  @override
  Future<bool> canDrawOverlays() async => overlay;

  @override
  Future<void> openOverlaySettings() async {
    openSettingsCalls++;
  }

  @override
  Future<bool> requestCaptureAndStart() async {
    await debugHandleNativeCall(const MethodCall('onSharingStarted'));
    // Feed one frame so the ask flow unlocks.
    await debugHandleNativeCall(MethodCall('onFrame', {
      'bytes': Uint8List.fromList([1, 2, 3]),
      'width': 720,
      'height': 1600,
      'displayWidth': 1080,
      'displayHeight': 2400,
      'meanLuminance': 120.0,
    }));
    return true;
  }

  @override
  Future<void> showHighlight(
    CopilotTarget target, {
    required CopilotGeometry geometry,
  }) async {
    highlightCalls++;
    lastShown = target;
  }

  @override
  Future<void> clearHighlight() async {}
}

ApiClient _apiReturning(Map<String, dynamic> json) {
  final mockHttp = MockClient((request) async {
    return http.Response(jsonEncode(json), 200);
  });
  return ApiClient(
    httpClient: mockHttp,
    auth: MockFirebaseAuth(signedIn: true),
  );
}

Widget _host(_FakeCopilotService service, ApiClient api) {
  return MaterialApp(
    home: CopilotScreen(api: api, service: service),
  );
}

void main() {
  // Clipboard.setData rides SystemChannels.platform, which the test binding
  // leaves unanswered unless mocked (same pattern as
  // copy_on_long_press_test.dart). Returns the captured clipboard text.
  String? clipText;
  setUp(() {
    clipText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('explainer + start state render; sharing unlocks the ask flow',
      (tester) async {
    final service = _FakeCopilotService();
    final api = _apiReturning({
      'found': true,
      'x': 0.5,
      'y': 0.9,
      'w': 0.2,
      'h': 0.08,
      'label': 'Reply',
      'kind': 'text_field',
      'confidence': 0.9,
      'draft_text': 'Hi! Thanks for matching.',
      'draft_say':
          "I drafted this: 'Hi! Thanks for matching.' Want me to copy it so you can paste it?",
      'copy_requires_confirmation': true,
      'say': 'Tap the reply box at the bottom.',
    });
    await tester.pumpWidget(_host(service, api));
    await tester.pump();

    expect(find.textContaining('never taps'), findsWidgets);
    expect(find.byKey(const Key('copilot_start_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('copilot_start_button')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('copilot_goal_field')), findsOneWidget);
    expect(find.byKey(const Key('copilot_stop_button')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('copilot_goal_field')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('copilot_goal_field')),
      'reply to this message',
    );
    await tester.ensureVisible(find.byKey(const Key('copilot_ask_button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('copilot_ask_button')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(service.highlightCalls, 1);
    expect(find.textContaining('Tap the reply box'), findsOneWidget);
    // The draft is shown for review and copied — never auto-inserted.
    // (ListView builds lazily: drag it until the draft is in the tree.)
    for (var i = 0;
        i < 12 && find.text('Hi! Thanks for matching.').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
    }
    expect(find.text('Hi! Thanks for matching.'), findsOneWidget);
    await tester.ensureVisible(
        find.byKey(const Key('copilot_copy_draft_button')));
    await tester.pumpAndSettle();
    // The visible action carries its exact label, the voice readback line
    // is on the card, and NOTHING has been copied yet — no silent writes.
    expect(find.text("Copy Ayma's draft"), findsOneWidget);
    expect(find.textContaining('Want me to copy it'), findsWidgets);
    expect(clipText, isNull);
    await tester.tap(find.byKey(const Key('copilot_copy_draft_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    // Several card lines mention pasting (readback, hint, copied note);
    // pin the post-copy instruction itself.
    expect(find.textContaining('Copied. Now tap'), findsOneWidget);
    expect(clipText, 'Hi! Thanks for matching.');
    service.dispose();
  });

  testWidgets('without the overlay grant, the tile routes to system settings',
      (tester) async {
    final service = _FakeCopilotService()..overlay = false;
    final api = _apiReturning({'found': false, 'say': 'x'});
    await tester.pumpWidget(_host(service, api));
    await tester.pump();
    await tester.pump();

    expect(find.text('Draw over other apps'), findsOneWidget);
    await tester.tap(find.text('Draw over other apps'));
    await tester.pump();
    expect(service.openSettingsCalls, 1);
    expect(find.byKey(const Key('copilot_start_button')), findsOneWidget);
    service.dispose();
  });

  testWidgets('secure pause is surfaced while sharing', (tester) async {
    final service = _FakeCopilotService();
    final api = _apiReturning({'found': false, 'say': 'x'});
    await tester.pumpWidget(_host(service, api));
    await tester.pump();
    await tester.tap(find.byKey(const Key('copilot_start_button')));
    await tester.pump();
    await tester.pump();
    await service.debugHandleNativeCall(
      const MethodCall('onSecurePause', {'paused': true}),
    );
    await tester.pump();
    expect(find.textContaining('protected'), findsOneWidget);
    service.dispose();
  });
}
