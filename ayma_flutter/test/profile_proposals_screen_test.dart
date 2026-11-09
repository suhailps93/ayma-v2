// ProfileProposalsScreen (Ayma's pending public-profile updates). These tests
// pin the Jobs-pass spacing/colour fixes (cluster 8, fleet/jobs-profile-own):
//   - the list and the error/empty states share one 20 screen edge;
//   - every TextButton clears the 44 absolute-minimum touch floor;
//   - removed-change rows read as muted (fgDim/onSurfaceVariant) + strikethrough
//     instead of the raw error red that failed the 4.5 text floor on the card;
//   - the inline error line uses the card/bg-safe `errorText` token.
import 'dart:convert';

import 'package:ayma_flutter/screens/profile_proposals_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/overflow_guards.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One section with a removed and an added change, so the row-colour and
/// per-row button assertions have real rows to read.
String _proposalsJson() => jsonEncode({
      'proposals': [
        {
          'page_id': 'identity',
          'title': 'Identity',
          'changes': [
            {'id': 'c1', 'op': 'remove', 'text': 'Old removed sentence'},
            {'id': 'c2', 'op': 'add', 'text': 'New added sentence'},
          ],
        },
      ],
    });

ApiClient _api(MockClient http) =>
    ApiClient(httpClient: http, auth: MockFirebaseAuth(signedIn: true));

Widget _host(ApiClient api) => MaterialApp(
      theme: AymaTheme.dark,
      home: ProfileProposalsScreen(apiClient: api),
    );

double _minHeight(TextButton b) =>
    b.style!.minimumSize!.resolve(const <WidgetState>{})!.height;

void main() {
  testWidgets('list screen edge is the 20 standard', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.padding, const EdgeInsets.all(20));
  });

  testWidgets('empty state shares the 20 edge', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          jsonEncode({'proposals': []}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.text('No suggestions right now'), findsOneWidget);
    final scroll = tester.widget<CenteredScroll>(find.byType(CenteredScroll));
    expect(scroll.padding, const EdgeInsets.all(20));
  });

  testWidgets('load-failed state shares the 20 edge and its Retry is >= 44',
      (tester) async {
    final api = _api(MockClient((req) async => http.Response('nope', 500)));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load the suggestions."), findsOneWidget);
    final scroll = tester.widget<CenteredScroll>(find.byType(CenteredScroll));
    expect(scroll.padding, const EdgeInsets.all(20));

    final retry =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Retry'));
    expect(_minHeight(retry), 44);
  });

  testWidgets('every TextButton clears the 44 touch floor', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    // Per-row Dismiss (one per change), section Dismiss all + Apply all (the
    // section has >1 change, so the "all" bar renders). Every one must be >=44.
    for (final label in const ['Dismiss', 'Dismiss all', 'Apply all']) {
      final buttons =
          tester.widgetList<TextButton>(find.widgetWithText(TextButton, label));
      expect(buttons, isNotEmpty, reason: 'expected a "$label" TextButton');
      for (final b in buttons) {
        expect(_minHeight(b), 44, reason: '$label must be >= 44 tall');
      }
    }
    // The sibling Apply FilledButtons are the 44 reference they now match.
    for (final apply
        in tester.widgetList<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply'))) {
      expect(
          apply.style!.minimumSize!.resolve(const <WidgetState>{})!.height, 44);
    }
  });

  testWidgets('removed row is muted + strikethrough, not raw error red',
      (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    final removed =
        tester.widget<Text>(find.text('- Old removed sentence'));
    final scheme = AymaTheme.dark.colorScheme;
    expect(removed.style!.color, scheme.onSurfaceVariant);
    expect(removed.style!.color, isNot(scheme.error));
    expect(removed.style!.decoration, TextDecoration.lineThrough);
  });

  testWidgets('inline error line uses the card/bg-safe errorText token',
      (tester) async {
    var applyCalls = 0;
    final api = _api(MockClient((req) async {
      if (req.method == 'POST') {
        applyCalls++;
        return http.Response('fail', 500);
      }
      return http.Response(
        _proposalsJson(),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Apply').first);
    await tester.pumpAndSettle();

    expect(applyCalls, greaterThan(0));
    final errorText = tester
        .widget<Text>(find.textContaining("Couldn't apply that change"));
    expect(errorText.style!.color, AymaTokens.dark.errorText);
  });
}
