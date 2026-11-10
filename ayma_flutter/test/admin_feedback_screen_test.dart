import 'dart:convert';

import 'package:ayma_flutter/screens/admin_feedback_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

/// Jobs pass (Wave 1 cluster 9): the Developer → Feedback triage list.
/// Asserts the spacing/colour/alignment fixes — screen edge 20 on both the
/// list and the load-error state, the per-card pills carrying fgDim label text
/// over their tinted fills, the status SegmentedButton clearing the 44 touch
/// floor, and the load-error line using the card-safe errorText token.

ApiClient _api(
  Future<http.Response> Function(http.Request req) handler,
) =>
    ApiClient(
      httpClient: MockClient(handler),
      auth: MockFirebaseAuth(signedIn: true),
    );

Map<String, dynamic> _row({String status = 'new'}) => {
      'id': 'p-1',
      'uid': 'u1',
      'source': 'settings_form',
      'kind': 'bug',
      'title': 'Orb flickers',
      'body': 'the orb flickers on messages',
      'screenshot_paths': const [],
      'screen': 'chat',
      'app_version': '1.30.0',
      'platform': 'android',
      'status': status,
      'created_at': '2026-09-26T10:06:00+00:00',
    };

Future<void> _pump(WidgetTester tester, ApiClient api) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AymaTheme.light,
    home: AdminFeedbackScreen(api: api),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  testWidgets('list uses the 20 screen edge', (tester) async {
    await _pump(
      tester,
      _api((_) async =>
          http.Response(jsonEncode({'feedback': [_row()]}), 200)),
    );
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.fromLTRB(20, 16, 20, 40));
  });

  testWidgets('load-error state uses the 20 edge and the errorText token',
      (tester) async {
    await _pump(
      tester,
      _api((_) async => http.Response('boom', 500)),
    );
    final errorText = find.textContaining("Couldn't load feedback");
    expect(errorText, findsOneWidget);
    // Edge 20: the error Padding matches the list edge.
    final pad = tester.widget<Padding>(
      find.ancestor(of: errorText, matching: find.byType(Padding)).first,
    );
    expect(pad.padding, const EdgeInsets.all(20));
    // Card-safe error colour: errorText, not the raw error token.
    final style = tester.widget<Text>(errorText).style!;
    expect(style.color, AymaTokens.light.errorText);
    expect(style.color, isNot(AymaTokens.light.error));
  });

  testWidgets('status SegmentedButton clears the 44 touch floor',
      (tester) async {
    await _pump(
      tester,
      _api((_) async =>
          http.Response(jsonEncode({'feedback': [_row()]}), 200)),
    );
    final seg = find.byType(SegmentedButton<String>);
    expect(seg, findsOneWidget);
    expect(tester.getSize(seg).height, greaterThanOrEqualTo(44.0));
  });

  testWidgets('pills keep their tinted fill but switch to fgDim label text',
      (tester) async {
    await _pump(
      tester,
      _api((_) async =>
          http.Response(jsonEncode({'feedback': [_row()]}), 200)),
    );
    // The Bug/Feature pill: label text is fgDim, fill is the warning tint.
    final label = find.text('Bug');
    expect(label, findsOneWidget);
    expect(tester.widget<Text>(label).style!.color, AymaTokens.light.fgDim);

    final container = tester.widget<Container>(
      find.ancestor(of: label, matching: find.byType(Container)).first,
    );
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, AymaTokens.light.warning.withValues(alpha: 0.14));
  });

  testWidgets('card inter-block gaps are on the grid (no stray 10s)',
      (tester) async {
    await _pump(
      tester,
      _api((_) async =>
          http.Response(jsonEncode({'feedback': [_row()]}), 200)),
    );
    // Defects 7+8: the three 10-gaps became 8; the pill Wrap runSpacing is 8.
    final strayTens = find
        .byWidgetPredicate((w) => w is SizedBox && w.height == 10)
        .evaluate();
    expect(strayTens, isEmpty);
    final wrap = tester.widget<Wrap>(find.byType(Wrap).first);
    expect(wrap.runSpacing, 8);
  });
}
