import 'dart:convert';

import 'package:ayma_flutter/screens/invite_friends_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
const _link = 'https://ayma-ai.web.app/r/AB23CDE';

ApiClient _api({int status = 200}) {
  final mockHttp = MockClient((req) async {
    if (req.url.path == '/referral') {
      return http.Response(
        jsonEncode({'code': 'AB23CDE', 'link': _link}),
        status,
        headers: _jsonUtf8,
      );
    }
    return http.Response('{}', 200, headers: _jsonUtf8);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Future<void> _pump(
  WidgetTester tester, {
  ApiClient? api,
  Future<void> Function(String)? share,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: InviteFriendsScreen(api: api ?? _api(), share: share),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the fetched link, code, and a Share button',
      (tester) async {
    await _pump(tester);

    expect(find.text(_link), findsOneWidget);
    expect(find.text('Code: AB23CDE'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Share your link'),
        findsOneWidget);
  });

  testWidgets('the Share button invokes the share seam with the invite text',
      (tester) async {
    final shared = <String>[];
    await _pump(tester, share: (text) async => shared.add(text));

    await tester.tap(find.widgetWithText(FilledButton, 'Share your link'));
    await tester.pump();

    expect(shared, hasLength(1));
    expect(
      shared.single,
      "I've been using Ayma, an AI that gets to know you and finds people "
      "who actually fit. She finds your person. Join me, my invite is inside: "
      '$_link',
    );
  });

  testWidgets('copy shows a "Link copied" snackbar', (tester) async {
    // Answer Clipboard.setData so the await inside _copy completes.
    final copied = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call.arguments);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester);

    await tester.tap(find.byTooltip('Copy link'));
    await tester.pump();
    await tester.pump();

    expect(copied, hasLength(1));
    expect(find.text('Link copied'), findsOneWidget);
  });

  testWidgets('a fetch failure shows the quiet error state, not a crash',
      (tester) async {
    await _pump(tester, api: _api(status: 500));

    expect(find.textContaining('Couldn’t load your invite link'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Share your link'), findsNothing);
  });
}
