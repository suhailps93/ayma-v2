import 'dart:convert';

import 'package:ayma_flutter/screens/match_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

ApiClient _api(Map<String, dynamic>? report, {int status = 200}) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path.startsWith('/match/')) {
        return http.Response(
            report == null ? 'no' : jsonEncode(report), status);
      }
      return http.Response('no', 404);
    }),
  );
}

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
  });

  testWidgets('renders the score, both breakdown lists and the note',
      (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon', 'love long runs'],
      'tensions': ['she wants city life, he wants a small town'],
      'explanation': 'You two line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('52%'), findsOneWidget);
    expect(find.text('You two line up on the big things.'), findsOneWidget);
    expect(find.text('both want kids soon'), findsOneWidget);
    expect(find.text('she wants city life, he wants a small town'),
        findsOneWidget);
    expect(find.text('Sam'), findsOneWidget); // avatar label = first name
  });

  testWidgets('Share copies a text summary to the clipboard', (tester) async {
    final api = _api({
      'match_id': 'a__me',
      'score': 0.52,
      'shared': ['both want kids soon'],
      'tensions': const [],
      'explanation': 'Line up on the big things.',
      'other': {'uid': 'a', 'name': 'Sam Vale', 'photo': ''},
      'me': {'photo': ''},
    });

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(matchId: 'a__me', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('Match with Sam Vale: 52%'));
    expect(copied, contains('both want kids soon'));
  });

  testWidgets('a never-scored pair shows the empty state', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MatchReportScreen(
          matchId: 'a__me', apiClient: _api(null, status: 404)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("hasn't been scored"), findsOneWidget);
  });
}
